import Foundation

// MARK: - Models

/// One entry of a remote directory listing. `path` is always absolute (the
/// listing protocol resolves `~` and symlinked parents server-side).
struct RemoteFileEntry: Identifiable, Hashable {
    enum Kind: String {
        case file
        case directory
        case symlink
        case other
    }

    let name: String
    let path: String            // absolute
    let kind: Kind
    let size: Int64?
    let modifiedAt: Date?
    let owner: String?
    let permissions: String?    // e.g. "rwxr-xr-x"
    let linkTarget: String?
    /// For symlinks: whether the link resolves to a directory (nil for
    /// non-symlinks; false for broken links). Drives download gating —
    /// scp-over-SFTP cannot fetch a directory through a link.
    let linkIsDir: Bool?

    var id: String { path }
}

struct RemoteDirectoryListing {
    let requestedPath: String
    let resolvedPath: String    // after symlink/~ resolution
    let entries: [RemoteFileEntry]
    let truncated: Bool         // listing capped (cap at 4000 entries)
}

enum RemoteFilePreview {
    case text(String)
    case binary(mimeType: String)
    case tooLarge(bytes: Int64)
}

// MARK: - Wire payloads

/// JSON bridge for the remote python listing protocol. Directory contents are
/// NEVER parsed from `ls` output: the remote script emits one JSON object and
/// these structs decode it.
private struct ListingPayload: Decodable {
    struct Entry: Decodable {
        let name: String
        let kind: String
        let size: Int64?
        let mtime: Double?
        let owner: String?
        let mode: String?
        let link: String?
        let linkIsDir: Bool?

        enum CodingKeys: String, CodingKey {
            case name
            case kind
            case size
            case mtime
            case owner
            case mode
            case link
            case linkIsDir = "link_is_dir"
        }
    }

    let requested: String
    let resolved: String
    let truncated: Bool
    let entries: [Entry]
}

private struct RemoteErrorPayload: Decodable {
    let error: String
}

// MARK: - Service

/// Remote file operations over the app's existing SSH session. Every remote
/// path is untrusted data: all interpolation into shell commands goes through
/// `shellQuote`, `--` precedes every path argument so leading-dash names can
/// never become flags, and listings use a remote-python JSON protocol (the
/// target path travels as a python argv element, never inside the script).
///
/// All operations run through `MonitorService.runRemoteCommand` /
/// `runTransfer`, which pre-flight the explicit-mode ControlMaster with
/// `ssh -O check` so a dead session throws "SSH session expired — use Login
/// to reconnect." instantly instead of hanging.
struct RemoteFileService: Sendable {
    private let monitor = MonitorService()

    private static let entryCap = 4000

    // MARK: Listing protocol

    /// Runs remotely as `python3 -c <script> <path> <showHidden>`. The target
    /// path and the hidden flag arrive via sys.argv — they are never
    /// interpolated into the script body. Emits exactly one JSON object on
    /// stdout; on failure emits {"error": "..."} and exits 3. Names with
    /// invalid UTF-8 are sanitized (U+FFFD) so the JSON always parses.
    private static let listingScript = """
    import json, os, pwd, stat, sys

    def clean(value):
        if value is None:
            return None
        return os.fsencode(value).decode("utf-8", "replace")

    def fail(message):
        sys.stdout.write(json.dumps({"error": message}))
        sys.exit(3)

    raw = sys.argv[1]
    show_hidden = sys.argv[2] == "1"
    expanded = os.path.expanduser(raw)
    if not os.path.isabs(expanded):
        expanded = os.path.join(os.path.expanduser("~"), expanded)
    resolved = os.path.realpath(expanded)
    if not os.path.exists(resolved):
        fail("No such directory: " + clean(resolved))
    if not os.path.isdir(resolved):
        fail("Not a directory: " + clean(resolved))
    cap = \(entryCap)
    entries = []
    truncated = False
    owner_names = {}
    try:
        with os.scandir(resolved) as it:
            for entry in it:
                name = entry.name
                if not show_hidden and name.startswith("."):
                    continue
                if len(entries) >= cap:
                    truncated = True
                    break
                try:
                    st = os.lstat(entry.path)
                except OSError:
                    continue
                mode = st.st_mode
                if stat.S_ISLNK(mode):
                    kind = "symlink"
                elif stat.S_ISDIR(mode):
                    kind = "directory"
                elif stat.S_ISREG(mode):
                    kind = "file"
                else:
                    kind = "other"
                link = None
                link_is_dir = None
                if kind == "symlink":
                    try:
                        link = clean(os.readlink(entry.path))
                    except OSError:
                        link = None
                    link_is_dir = os.path.isdir(entry.path)
                owner = owner_names.get(st.st_uid)
                if owner is None:
                    try:
                        owner = pwd.getpwuid(st.st_uid).pw_name
                    except (KeyError, OSError):
                        owner = str(st.st_uid)
                    owner_names[st.st_uid] = owner
                entries.append({
                    "name": clean(name),
                    "kind": kind,
                    "size": st.st_size,
                    "mtime": st.st_mtime,
                    "owner": owner,
                    "mode": stat.filemode(mode)[1:],
                    "link": link,
                    "link_is_dir": link_is_dir,
                })
    except PermissionError:
        fail("Permission denied: " + clean(resolved))
    except OSError as exc:
        fail(clean(str(exc)))
    entries.sort(key=lambda item: (item["kind"] != "directory", item["name"].lower()))
    sys.stdout.write(json.dumps({
        "requested": clean(raw),
        "resolved": clean(resolved),
        "truncated": truncated,
        "entries": entries,
    }))
    """

    private static let homeScript = """
    import os, sys
    sys.stdout.write(os.path.realpath(os.path.expanduser("~")))
    """

    // MARK: Public API

    func homeDirectory(settings: ServerSettings) async throws -> String {
        let command = "python3 -c \(shellQuote(Self.homeScript))"
        let result = try await monitor.runRemoteCommand(
            settings: settings,
            command: command,
            timeout: 20
        )
        let home = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, home.hasPrefix("/") else {
            throw Self.failure("Could not determine the remote home directory", result)
        }
        return home
    }

    func listDirectory(
        settings: ServerSettings,
        path: String,
        showHidden: Bool
    ) async throws -> RemoteDirectoryListing {
        let target = path.isEmpty ? "~" : path
        let command = "python3 -c \(shellQuote(Self.listingScript))"
            + " \(shellQuote(target)) \(showHidden ? "1" : "0")"
        let result = try await monitor.runRemoteCommand(
            settings: settings,
            command: command,
            timeout: 45
        )
        let data = Data(result.stdout.utf8)

        if result.exitCode != 0 {
            if let payload = try? JSONDecoder().decode(RemoteErrorPayload.self, from: data) {
                throw MonitorError.processFailed(payload.error)
            }
            throw Self.failure("Could not list \(target)", result)
        }

        let payload: ListingPayload
        do {
            payload = try JSONDecoder().decode(ListingPayload.self, from: data)
        } catch {
            throw MonitorError.invalidJSON(
                "Directory listing was not valid JSON: \(error.localizedDescription)"
            )
        }

        let parent = payload.resolved == "/" ? "" : payload.resolved
        let entries = payload.entries.map { entry in
            RemoteFileEntry(
                name: entry.name,
                path: "\(parent)/\(entry.name)",
                kind: RemoteFileEntry.Kind(rawValue: entry.kind) ?? .other,
                size: entry.size,
                modifiedAt: entry.mtime.map { Date(timeIntervalSince1970: $0) },
                owner: entry.owner,
                permissions: entry.mode,
                linkTarget: entry.link,
                linkIsDir: entry.linkIsDir
            )
        }
        return RemoteDirectoryListing(
            requestedPath: payload.requested,
            resolvedPath: payload.resolved,
            entries: entries,
            truncated: payload.truncated
        )
    }

    func createDirectory(settings: ServerSettings, path: String) async throws {
        let target = try requireNonEmptyPath(path, operation: "Create folder")
        let result = try await monitor.runRemoteCommand(
            settings: settings,
            command: "mkdir -p -- \(shellQuote(target))",
            timeout: 20
        )
        guard result.exitCode == 0 else {
            throw Self.failure("Could not create \(target)", result)
        }
    }

    /// Renames/moves a single entry. Fails when the target already exists
    /// (checked server-side with `test -e`/`test -L` in the same command, so
    /// broken symlinks are also refused).
    func rename(settings: ServerSettings, from: String, to: String) async throws {
        let source = try requireNonEmptyPath(from, operation: "Rename")
        let target = try requireNonEmptyPath(to, operation: "Rename")
        let command = "if [ -e \(shellQuote(target)) ] || [ -L \(shellQuote(target)) ]; "
            + "then exit 41; fi; "
            + "mv -- \(shellQuote(source)) \(shellQuote(target))"
        let result = try await monitor.runRemoteCommand(
            settings: settings,
            command: command,
            timeout: 30
        )
        if result.exitCode == 41 {
            throw MonitorError.processFailed("Cannot rename: \(target) already exists.")
        }
        guard result.exitCode == 0 else {
            throw Self.failure("Could not rename \(source)", result)
        }
    }

    /// Thrown by `moveToTrash` when cross-filesystem items cannot get a
    /// `.aire-trash` folder on their own filesystem: proceeding would COPY
    /// the data into the home-quota trash (small on HPC). Callers confirm
    /// with the user, then retry with `allowQuotaCopy: true` — or offer
    /// permanent delete instead. Nothing has been moved when this is thrown.
    struct QuotaCopyConfirmationRequired: Error, LocalizedError {
        let paths: [String]

        var errorDescription: String? {
            "Moving \(paths.count) item\(paths.count == 1 ? "" : "s") to trash "
                + "would copy data into your home quota."
        }
    }

    /// Moves paths into fresh, per-operation server-side trash directories
    /// (`<…>/.aire-trash/<timestamp>-<uuid8>/`) and returns every trash
    /// directory used. This is the default "delete": recoverable with a
    /// plain `mv` back.
    ///
    /// Same-filesystem sources go to `~/.aire-trash` (atomic rename).
    /// Cross-filesystem sources (e.g. scratch) get a trash directory next to
    /// the source (`<parent>/.aire-trash/…`) so the `mv` is still a rename
    /// and never copies data into the home quota. Only when that directory
    /// cannot be created does the move fall back to a copy into
    /// `~/.aire-trash` — gated on `allowQuotaCopy` (see
    /// `QuotaCopyConfirmationRequired`) and run with a size-scaled timeout.
    func moveToTrash(
        settings: ServerSettings,
        paths: [String],
        allowQuotaCopy: Bool = false
    ) async throws -> [String] {
        let home = try await homeDirectory(settings: settings)
        let targets = try validatedTargets(paths, home: home, operation: "Move to trash")
        let runName = Self.trashRunName()
        let homeTrash = "\(home)/.aire-trash/\(runName)"

        // The device of each source vs. the home filesystem decides whether
        // `mv` into ~/.aire-trash is an atomic rename (same device) or a
        // copy+unlink (cross-device). When devices cannot be determined the
        // sources are treated as same-device — prior behavior.
        let devices = await deviceIDs(settings: settings, paths: [home] + targets)
        let homeDevice = devices?.first ?? nil

        var homeFilesystemTargets: [String] = []
        var crossDeviceGroups: [String: [String]] = [:]     // parent dir -> targets
        if let devices, devices.count == targets.count + 1, homeDevice != nil {
            for (index, target) in targets.enumerated() {
                let device = devices[index + 1]
                if device == nil || device == homeDevice {
                    homeFilesystemTargets.append(target)
                } else {
                    let parent = Self.parentDirectory(of: target)
                    crossDeviceGroups[parent, default: []].append(target)
                }
            }
        } else {
            homeFilesystemTargets = targets
        }

        // Pre-flight the per-mount trash directories BEFORE moving anything
        // so a needed quota-copy confirmation can be surfaced with zero
        // partial state.
        var perMountMoves: [(trashDirectory: String, targets: [String])] = []
        var quotaCopyTargets: [String] = []
        for (parent, group) in crossDeviceGroups.sorted(by: { $0.key < $1.key }) {
            let trashDirectory = "\(parent)/.aire-trash/\(runName)"
            let mkdir = try await monitor.runRemoteCommand(
                settings: settings,
                command: "mkdir -p -- \(shellQuote(trashDirectory))",
                timeout: 20
            )
            if mkdir.exitCode == 0 {
                perMountMoves.append((trashDirectory, group))
            } else {
                quotaCopyTargets.append(contentsOf: group)
            }
        }

        if !quotaCopyTargets.isEmpty, !allowQuotaCopy {
            // Best effort: remove the still-empty per-mount directories the
            // pre-flight created; nothing has been moved yet.
            if !perMountMoves.isEmpty {
                let quoted = perMountMoves
                    .map { shellQuote($0.trashDirectory) }
                    .joined(separator: " ")
                _ = try? await monitor.runRemoteCommand(
                    settings: settings,
                    command: "rmdir -- \(quoted) 2>/dev/null; true",
                    timeout: 20
                )
            }
            throw QuotaCopyConfirmationRequired(paths: quotaCopyTargets)
        }

        var usedTrashDirectories: [String] = []

        if !homeFilesystemTargets.isEmpty {
            let quotedTargets = homeFilesystemTargets.map(shellQuote).joined(separator: " ")
            let command = "mkdir -p -- \(shellQuote(homeTrash)) && "
                + "mv -- \(quotedTargets) \(shellQuote(homeTrash + "/"))"
            let result = try await monitor.runRemoteCommand(
                settings: settings,
                command: command,
                timeout: 60
            )
            guard result.exitCode == 0 else {
                throw Self.failure("Could not move items to trash", result)
            }
            usedTrashDirectories.append(homeTrash)
        }

        for move in perMountMoves {
            let quotedTargets = move.targets.map(shellQuote).joined(separator: " ")
            let command = "mv -- \(quotedTargets) \(shellQuote(move.trashDirectory + "/"))"
            let result = try await monitor.runRemoteCommand(
                settings: settings,
                command: command,
                timeout: 60
            )
            guard result.exitCode == 0 else {
                throw Self.failure("Could not move items to trash", result)
            }
            usedTrashDirectories.append(move.trashDirectory)
        }

        if !quotaCopyTargets.isEmpty {
            // User-confirmed cross-device copy into the home trash: `mv` is
            // copy+unlink here, so scale the timeout with the data size the
            // way transfers do instead of the flat 60s.
            let bytes = await totalSizeBytes(settings: settings, paths: quotaCopyTargets)
            let quotedTargets = quotaCopyTargets.map(shellQuote).joined(separator: " ")
            let command = "mkdir -p -- \(shellQuote(homeTrash)) && "
                + "mv -- \(quotedTargets) \(shellQuote(homeTrash + "/"))"
            let result = try await monitor.runRemoteCommand(
                settings: settings,
                command: command,
                timeout: Self.transferTimeout(forBytes: bytes)
            )
            guard result.exitCode == 0 else {
                throw Self.failure("Could not move items to trash", result)
            }
            if !usedTrashDirectories.contains(homeTrash) {
                usedTrashDirectories.append(homeTrash)
            }
        }

        return usedTrashDirectories
    }

    /// Irreversible `rm -rf`. Callers must double-confirm in the UI; this
    /// method independently refuses `/`, `~`, the home directory itself,
    /// anything that is not an absolute path, and any path with `.`/`..`/
    /// empty components (dot-segment aliases of protected locations) —
    /// defense in depth.
    func deletePermanently(settings: ServerSettings, paths: [String]) async throws {
        let home = try await homeDirectory(settings: settings)
        let targets = try validatedTargets(paths, home: home, operation: "Delete")
        let quotedTargets = targets.map(shellQuote).joined(separator: " ")
        let result = try await monitor.runRemoteCommand(
            settings: settings,
            command: "rm -rf -- \(quotedTargets)",
            timeout: 120
        )
        guard result.exitCode == 0 else {
            throw Self.failure("Could not delete items", result)
        }
    }

    func preview(
        settings: ServerSettings,
        path: String,
        maxBytes: Int
    ) async throws -> RemoteFilePreview {
        let target = try requireNonEmptyPath(path, operation: "Preview")
        let cap = max(1, maxBytes)

        let mimeResult = try await monitor.runRemoteCommand(
            settings: settings,
            command: "file -b --mime-type -- \(shellQuote(target))",
            timeout: 20
        )
        guard mimeResult.exitCode == 0 else {
            throw Self.failure("Could not inspect \(target)", mimeResult)
        }
        let mime = mimeResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mime.hasPrefix("text/") || mime == "inode/x-empty" else {
            return .binary(mimeType: mime.isEmpty ? "application/octet-stream" : mime)
        }

        let size = try await fileSize(settings: settings, path: target)
        if let size, size > Int64(cap) * 4 {
            return .tooLarge(bytes: size)
        }

        let headResult = try await monitor.runRemoteCommand(
            settings: settings,
            command: "head -c \(cap) -- \(shellQuote(target))",
            timeout: 30
        )
        guard headResult.exitCode == 0 else {
            throw Self.failure("Could not read \(target)", headResult)
        }
        var text = headResult.stdout
        // When the byte cap truncated the file mid-codepoint, the lossy
        // decode ends the text with a replacement character that is purely a
        // truncation artifact — drop it. Untruncated files keep theirs.
        if let size, size > Int64(cap), text.hasSuffix("\u{FFFD}") {
            text.removeLast()
        }
        return .text(text)
    }

    /// Human-readable recursive size, e.g. "1.2G".
    func diskUsage(settings: ServerSettings, path: String) async throws -> String {
        let target = try requireNonEmptyPath(path, operation: "Disk usage")
        let result = try await monitor.runRemoteCommand(
            settings: settings,
            command: "du -sh -- \(shellQuote(target))",
            timeout: 180
        )
        // du can exit non-zero on partially unreadable trees while still
        // printing a usable total; accept output whenever it parses.
        let firstLine = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        let size = firstLine
            .split(whereSeparator: { $0 == "\t" || $0 == " " })
            .first
            .map(String.init) ?? ""
        guard !size.isEmpty else {
            throw Self.failure("Could not measure \(target)", result)
        }
        return size
    }

    func download(
        settings: ServerSettings,
        remotePath: String,
        toLocalDirectory: URL
    ) async throws -> URL {
        var source = try requireNonEmptyPath(remotePath, operation: "Download")
        if source.hasPrefix("~") {
            source = try await expandTilde(source, settings: settings)
        }
        let name = source
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? ""
        guard !name.isEmpty, name != ".", name != ".." else {
            throw MonitorError.processFailed("Cannot download \(source): not a file path.")
        }

        try FileManager.default.createDirectory(
            at: toLocalDirectory,
            withIntermediateDirectories: true
        )
        let destination = Self.uniquifiedURL(in: toLocalDirectory, preferredName: name)

        let remoteSize = try? await fileSize(settings: settings, path: source)
        let result = try await monitor.runTransfer(
            settings: settings,
            arguments: scpArguments(
                settings: settings,
                remotePath: source,
                localPath: destination.path,
                direction: .download
            ),
            timeout: Self.transferTimeout(forBytes: remoteSize ?? nil)
        )
        guard result.exitCode == 0 else {
            // A failed scp can leave a zero-byte placeholder behind.
            try? FileManager.default.removeItem(at: destination)
            throw Self.failure("Download of \(name) failed", result)
        }
        return destination
    }

    func upload(
        settings: ServerSettings,
        localFile: URL,
        toRemoteDirectory: String
    ) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: localFile.path, isDirectory: &isDirectory) else {
            throw MonitorError.missingFile(localFile.path)
        }
        guard !isDirectory.boolValue else {
            throw MonitorError.processFailed(
                "Uploading folders is not supported — compress \(localFile.lastPathComponent) first."
            )
        }

        var target = try requireNonEmptyPath(toRemoteDirectory, operation: "Upload")
        if target.hasPrefix("~") {
            target = try await expandTilde(target, settings: settings)
        }
        if !target.hasSuffix("/") {
            target += "/"
        }

        // scp opens the destination create+truncate, silently replacing an
        // existing remote file — refuse first (same `test -e`/`test -L`
        // pattern as rename, so broken symlinks are also caught). The
        // check-then-scp window is acceptable for an interactive app.
        let destination = target + localFile.lastPathComponent
        let existsCheck = try await monitor.runRemoteCommand(
            settings: settings,
            command: "if [ -e \(shellQuote(destination)) ] || [ -L \(shellQuote(destination)) ]; "
                + "then exit 41; fi",
            timeout: 20
        )
        if existsCheck.exitCode == 41 {
            throw MonitorError.processFailed(
                "Cannot upload: \(localFile.lastPathComponent) already exists in "
                    + "\(Self.trimTrailingSlashes(target))."
            )
        }
        guard existsCheck.exitCode == 0 else {
            throw Self.failure("Could not check \(destination) before upload", existsCheck)
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: localFile.path)
        let localSize = (attributes?[.size] as? NSNumber)?.int64Value
        let result = try await monitor.runTransfer(
            settings: settings,
            arguments: scpArguments(
                settings: settings,
                remotePath: target,
                localPath: localFile.path,
                direction: .upload
            ),
            timeout: Self.transferTimeout(forBytes: localSize)
        )
        guard result.exitCode == 0 else {
            throw Self.failure("Upload of \(localFile.lastPathComponent) failed", result)
        }
    }

    // MARK: Quoting & validation

    /// Wraps a value in single quotes for safe interpolation into a remote
    /// shell command (`'` becomes `'\''`) — same algorithm as
    /// `SSHTerminalCommand.shellQuote`. EVERY remote path interpolation in
    /// this file must go through it.
    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func requireNonEmptyPath(_ path: String, operation: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MonitorError.processFailed("\(operation): no path given.")
        }
        return trimmed
    }

    /// Shared guard for trash/delete: expands a leading `~`, then refuses
    /// `/`, `~`, the home directory itself, anything not absolute, and any
    /// path containing `.`/`..`/empty components — so dot-segment and
    /// double-slash aliases (`/users/u/../u`, `//users/u`) can never dodge
    /// the protected-location checks.
    private func validatedTargets(
        _ paths: [String],
        home: String,
        operation: String
    ) throws -> [String] {
        guard !paths.isEmpty else {
            throw MonitorError.processFailed("\(operation): no items selected.")
        }
        let normalizedHome = Self.trimTrailingSlashes(home)
        return try paths.map { raw in
            let trimmed = try requireNonEmptyPath(raw, operation: operation)
            let expanded = Self.expandLeadingTilde(trimmed, home: normalizedHome)
            let normalized = Self.trimTrailingSlashes(expanded)
            guard normalized.contains("/") else {
                throw MonitorError.processFailed(
                    "\(operation) refused for \(trimmed): not an absolute path."
                )
            }
            guard normalized.hasPrefix("/") else {
                throw MonitorError.processFailed(
                    "\(operation) refused for \(trimmed): only absolute paths are allowed."
                )
            }
            guard normalized != "/", normalized != normalizedHome else {
                throw MonitorError.processFailed(
                    "\(operation) refused for \(trimmed): protected location."
                )
            }
            // Segment-wise check: the first component of an absolute path is
            // the empty string before the leading "/" — every later one must
            // be a real name (this correctly allows names like "..foo").
            let components = normalized
                .split(separator: "/", omittingEmptySubsequences: false)
                .dropFirst()
            guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw MonitorError.processFailed(
                    "\(operation) refused for \(trimmed): "
                        + "paths with '.', '..', or empty components are not allowed."
                )
            }
            return normalized
        }
    }

    private static func expandLeadingTilde(_ path: String, home: String) -> String {
        if path == "~" {
            return home
        }
        if path.hasPrefix("~/") {
            return home + path.dropFirst(1)
        }
        return path
    }

    private static func trimTrailingSlashes(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    // MARK: Helpers

    private func expandTilde(_ path: String, settings: ServerSettings) async throws -> String {
        let home = try await homeDirectory(settings: settings)
        return Self.expandLeadingTilde(path, home: Self.trimTrailingSlashes(home))
    }

    /// Size in bytes via GNU `stat -L` (dereferences symlinks — plain `stat`
    /// would report the link string's own length, wrecking transfer-timeout
    /// scaling for symlinked files). Returns nil when the output is not a
    /// number; throws for broken symlinks (`stat -L` fails), which callers
    /// treat as unknown size via `try?`.
    private func fileSize(settings: ServerSettings, path: String) async throws -> Int64? {
        let result = try await monitor.runRemoteCommand(
            settings: settings,
            command: "stat -Lc %s -- \(shellQuote(path))",
            timeout: 20
        )
        guard result.exitCode == 0 else {
            throw Self.failure("Could not stat \(path)", result)
        }
        return Int64(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Filesystem device id (`stat -c %d`, lstat semantics — for a symlink
    /// the link itself, matching what `mv` moves) for each path, in order.
    /// A nil element means that path could not be statted; a nil return
    /// means the device probe as a whole failed and callers should fall
    /// back to same-device behavior.
    private func deviceIDs(
        settings: ServerSettings,
        paths: [String]
    ) async -> [String?]? {
        guard !paths.isEmpty else {
            return []
        }
        let command = paths
            .map { "stat -c %d -- \(shellQuote($0)) 2>/dev/null || echo '?'" }
            .joined(separator: "; ")
        guard let result = try? await monitor.runRemoteCommand(
            settings: settings,
            command: command,
            timeout: 30
        ) else {
            return nil
        }
        let lines = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count == paths.count else {
            return nil
        }
        return lines.map { $0 == "?" || $0.isEmpty ? nil : $0 }
    }

    /// Total size in bytes of the given paths via `du -sk` (KiB blocks).
    /// Used only to scale the cross-filesystem trash-copy timeout, so it
    /// tolerates partial failures (du exits non-zero on unreadable subtrees
    /// while still printing usable totals) and returns nil when nothing
    /// parses.
    private func totalSizeBytes(
        settings: ServerSettings,
        paths: [String]
    ) async -> Int64? {
        guard !paths.isEmpty else {
            return nil
        }
        let quoted = paths.map(shellQuote).joined(separator: " ")
        guard let result = try? await monitor.runRemoteCommand(
            settings: settings,
            command: "du -sk -- \(quoted)",
            timeout: 180
        ) else {
            return nil
        }
        var total: Int64 = 0
        var parsedAny = false
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let first = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).first,
                  let kibibytes = Int64(first) else {
                continue
            }
            total += kibibytes * 1024
            parsedAny = true
        }
        return parsedAny ? total : nil
    }

    private static func parentDirectory(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    private enum TransferDirection {
        case download
        case upload
    }

    /// scp argv. scp-over-SFTP (OpenSSH 9+) does NOT shell-expand remote
    /// paths, so the remote spec travels as ONE argv element with no extra
    /// quoting layer — spaces and metacharacters are safe as-is.
    private func scpArguments(
        settings: ServerSettings,
        remotePath: String,
        localPath: String,
        direction: TransferDirection
    ) -> [String] {
        // BatchMode in BOTH modes, matching runRemoteCommand's no-prompt
        // contract: a dead alias-side master must fail fast instead of
        // prompting for a password/Duo push (or stalling on SSH_ASKPASS).
        var arguments = ["-q", "-o", "BatchMode=yes"]
        let remoteSpec: String
        if settings.useSSHAlias {
            remoteSpec = "\(settings.sshAlias):\(remotePath)"
        } else {
            arguments.append(contentsOf: [
                "-o", "ControlPath=\(settings.controlPath)",
                "-o", "ConnectTimeout=5",
                "-o", "User=\(settings.username)"
            ])
            remoteSpec = "\(settings.aireHostname):\(remotePath)"
        }
        switch direction {
        case .download:
            arguments.append(contentsOf: [remoteSpec, localPath])
        case .upload:
            arguments.append(contentsOf: [localPath, remoteSpec])
        }
        return arguments
    }

    /// Min 60s, +1s per MB, capped at one hour; 10 minutes when the size is
    /// unknown.
    private static func transferTimeout(forBytes bytes: Int64?) -> TimeInterval {
        guard let bytes, bytes >= 0 else {
            return 600
        }
        let megabytes = Double(bytes) / 1_048_576
        return min(3600, max(60, 60 + megabytes.rounded(.up)))
    }

    /// "name.ext" -> "name (2).ext" -> "name (3).ext" until free.
    private static func uniquifiedURL(in directory: URL, preferredName: String) -> URL {
        let manager = FileManager.default
        var candidate = directory.appendingPathComponent(preferredName)
        guard manager.fileExists(atPath: candidate.path) else {
            return candidate
        }
        let base = (preferredName as NSString).deletingPathExtension
        let ext = (preferredName as NSString).pathExtension
        var counter = 2
        repeat {
            let name = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = directory.appendingPathComponent(name)
            counter += 1
        } while manager.fileExists(atPath: candidate.path)
        return candidate
    }

    private static func trashTimestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// Trash directory name: time-sortable for manual recovery, with a UUID
    /// suffix so two trash operations in the same second (or the repeated
    /// DST hour) can never share a directory and silently overwrite each
    /// other's same-named files.
    private static func trashRunName(_ date: Date = Date()) -> String {
        "\(trashTimestamp(date))-\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// User-readable error carrying trimmed remote stderr (falling back to
    /// stdout). Never includes the command line itself — paths only.
    private static func failure(_ operation: String, _ result: ProcessResult) -> MonitorError {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = stderr.isEmpty ? stdout : stderr
        if detail.isEmpty {
            return .processFailed("\(operation) (exit \(result.exitCode)).")
        }
        return .processFailed("\(operation): \(detail)")
    }
}
