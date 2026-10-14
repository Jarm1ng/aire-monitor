import HPCCore
import Darwin
import Foundation

// MARK: - Trash planning types

/// One target as the trash pre-flight saw it on the login node.
struct TrashProbe: Equatable {
    let path: String
    /// `lstat` device id (a string: dev_t is an unsigned 64-bit value);
    /// nil when the path could not be statted.
    let device: String?
    let error: String?
    let parent: String
    let parentWritable: Bool
}

/// A per-mount trash folder the pre-flight tried to create beside items on
/// another filesystem than home.
struct MountTrashDirectory: Equatable {
    let parent: String
    let directory: String
    /// Why it could not be created; nil on success.
    let error: String?
    let createdBase: Bool

    var createdDirectory: String? { error == nil ? directory : nil }
}

struct TrashInspection: Equatable {
    let home: String
    let homeDevice: String?
    let targets: [TrashProbe]
    let mountTrash: [MountTrashDirectory]
}

/// What `moveToTrash` will do, decided before anything moves.
struct TrashPlan: Equatable {
    struct Group: Equatable {
        let directory: String
        let isHome: Bool
        var paths: [String]
    }

    /// Rename groups: the home trash first, then per-mount folders.
    var groups: [Group]
    /// Items that could only be trashed by copying them into home.
    var quotaCopyTargets: [String]
    /// `~/.aire-trash/<run>`, for home items and confirmed quota copies.
    let homeTrashDirectory: String
    /// Per-mount folders the pre-flight created.
    var preparedDirectories: [String]
    /// Prepared folders no group uses (removed by the execute step).
    var unusedDirectories: [String]
}

// MARK: - Rules

/// Pure rules behind the file manager, kept apart from the I/O so they can
/// be unit-tested: path validation for destructive operations, trash
/// planning, transfer naming and limits, and scp argv.
extension RemoteFileService {

    // MARK: Quoting

    /// Wraps a value in single quotes for safe interpolation into a remote
    /// shell command (`'` becomes `'\''`) — same algorithm as
    /// `SSHTerminalCommand.shellQuote`. EVERY remote path interpolated into
    /// a shell command in the file manager must go through it.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Validation

    /// Rejects blank paths but returns the path UNCHANGED. Remote names may
    /// legitimately be, start with, or end in whitespace or a newline
    /// (Linux allows any byte but "/" and NUL): trimming "/users/u/proj/ "
    /// would turn "delete the file named ' '" into "delete /users/u/proj".
    /// Names the user types are trimmed and validated by the callers.
    static func requireNonEmptyPath(_ path: String, operation: String) throws -> String {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MonitorError.processFailed("\(operation): no path given.")
        }
        return path
    }

    /// Shared guard for trash and permanent delete. Refuses:
    /// - anything not absolute (a `~` path included — every caller passes
    ///   listing paths, which are absolute), and any path with `.`/`..`/
    ///   empty components, so dot-segment and double-slash aliases
    ///   (`/users/u/../u`, `//users/u`) can never dodge the checks below;
    /// - top-level folders (`/`, `/users`, `/mnt`, `/scratch-calder`):
    ///   deleting `/users` would recurse into the user's own home;
    /// - every protected root itself (home and each storage space) and
    ///   every ANCESTOR of one (`/mnt/scratch`, `/scratch-calder/users`),
    ///   which would take the root with it.
    /// Ordinary paths inside a root (`/users/u/proj`) and elsewhere
    /// (`/tmp/x`) are allowed. Trailing slashes are dropped; nothing else
    /// about the path is changed. The job and trash scripts repeat the
    /// check on the login node against realpath'd roots, catching aliases
    /// only the server can resolve (a symlinked parent such as /home).
    static func validatedTargets(
        _ paths: [String],
        protectedRoots: [String],
        operation: String
    ) throws -> [String] {
        guard !paths.isEmpty else {
            throw MonitorError.processFailed("\(operation): no items selected.")
        }
        let roots = protectedRoots
            .filter { $0.hasPrefix("/") }
            .map(trimTrailingSlashes)
        return try paths.map { raw in
            let trimmed = try requireNonEmptyPath(raw, operation: operation)
            let normalized = trimTrailingSlashes(trimmed)
            guard normalized.hasPrefix("/") else {
                throw MonitorError.processFailed(
                    "\(operation) refused for \(trimmed): only absolute paths are allowed."
                )
            }
            // Segment-wise: the first component of an absolute path is the
            // empty string before the leading "/" — every later one must be
            // a real name (this correctly allows names like "..foo").
            let components = normalized
                .split(separator: "/", omittingEmptySubsequences: false)
                .dropFirst()
            guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw MonitorError.processFailed(
                    "\(operation) refused for \(trimmed): "
                        + "paths with '.', '..', or empty components are not allowed."
                )
            }
            guard components.count >= 2 else {
                throw MonitorError.processFailed(
                    "\(operation) refused for \(normalized): it is a top-level folder."
                )
            }
            if roots.contains(where: { $0 == normalized || $0.hasPrefix(normalized + "/") }) {
                throw MonitorError.processFailed(
                    "\(operation) refused for \(normalized): it contains your home or a storage root."
                )
            }
            return normalized
        }
    }

    /// True for a trash folder itself or anything inside one.
    static func isInsideTrash(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0 == Substring(trashDirectoryName) }
    }

    /// Trashing a trash folder or its contents would only nest it into a
    /// new run; emptying is done with Delete Permanently or the Trash sheet.
    static func refuseTrashingTrash(_ targets: [String]) throws {
        if let inTrash = targets.first(where: isInsideTrash) {
            let name = (inTrash as NSString).lastPathComponent
            throw MonitorError.processFailed(
                "“\(name)” is already in the trash. Use Delete Permanently (or Empty in the Trash sheet) to remove it for good."
            )
        }
    }

    /// Decides where every target goes. Fails CLOSED: when the home device
    /// or any target's device is unknown nothing moves — guessing "same
    /// filesystem" could copy scratch data into the home quota without the
    /// quota-copy confirmation. A target whose parent is not writable stops
    /// the operation too: renaming needs it, and a cross-device `mv` would
    /// copy everything first and only then fail to unlink.
    static func planTrash(_ inspection: TrashInspection, runName: String) throws -> TrashPlan {
        let homeTrash = joinPath(
            trimTrailingSlashes(inspection.home),
            "\(trashDirectoryName)/\(runName)"
        )
        guard let homeDevice = inspection.homeDevice else {
            throw MonitorError.processFailed(
                "Could not determine which filesystem these items are on — nothing was moved. Try again."
            )
        }
        if let missing = inspection.targets.first(where: { $0.device == nil }) {
            let detail = missing.error.map { " (\($0))" } ?? ""
            throw MonitorError.processFailed(
                "Could not find \(missing.path)\(detail) — nothing was moved. Refresh the folder and try again."
            )
        }
        if let locked = inspection.targets.first(where: { !$0.parentWritable }) {
            throw MonitorError.processFailed(
                "You don't have permission to move items out of \(locked.parent) — nothing was moved."
            )
        }

        var homeGroup = TrashPlan.Group(directory: homeTrash, isHome: true, paths: [])
        var mountGroups: [TrashPlan.Group] = []
        var quotaCopy: [String] = []
        let prepared = inspection.mountTrash.compactMap(\.createdDirectory)
        for probe in inspection.targets {
            if probe.device == homeDevice {
                homeGroup.paths.append(probe.path)
                continue
            }
            if let mount = inspection.mountTrash.first(where: { $0.parent == probe.parent }),
               let directory = mount.createdDirectory {
                if let index = mountGroups.firstIndex(where: { $0.directory == directory }) {
                    mountGroups[index].paths.append(probe.path)
                } else {
                    mountGroups.append(TrashPlan.Group(directory: directory, isHome: false, paths: [probe.path]))
                }
            } else {
                quotaCopy.append(probe.path)
            }
        }
        let used = Set(mountGroups.map(\.directory))
        return TrashPlan(
            groups: (homeGroup.paths.isEmpty ? [] : [homeGroup]) + mountGroups,
            quotaCopyTargets: quotaCopy,
            homeTrashDirectory: homeTrash,
            preparedDirectories: prepared,
            unusedDirectories: prepared.filter { !used.contains($0) }
        )
    }

    // MARK: Paths

    static func expandLeadingTilde(_ path: String, home: String) -> String {
        if path == "~" {
            return home
        }
        if path.hasPrefix("~/") {
            return home + path.dropFirst(1)
        }
        return path
    }

    static func trimTrailingSlashes(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    /// Joins without doubling the slash when `directory` is the root.
    static func joinPath(_ directory: String, _ relative: String) -> String {
        directory == "/" ? "/\(relative)" : "\(directory)/\(relative)"
    }

    // MARK: Transfers

    enum TransferDirection {
        case download
        case upload
    }

    /// scp argv. scp-over-SFTP (OpenSSH 9+) does NOT shell-expand remote
    /// paths, so the remote spec travels as ONE argv element with no shell
    /// quoting layer — spaces and shell metacharacters are safe as-is. It
    /// DOES glob the source of a download (remote_glob with GLOB_NOCHECK), so
    /// for downloads `\ * ? [` are backslash-escaped: otherwise fetching
    /// "data[1].csv" would silently deliver data1.csv under that name.
    ///
    /// The client options come from `SSHMuxOptions`: never prompt (a dead
    /// master fails fast instead of asking for a password or Duo push),
    /// never become a master, and ride only this cluster's ControlPath.
    /// `--` ends option parsing before the path operands.
    static func scpArguments(
        settings: ConnectionSettings,
        remotePath: String,
        localPath: String,
        direction: TransferDirection
    ) -> [String] {
        var arguments = ["-q"] + SSHMuxOptions.scpOptions(settings: settings) + ["--"]
        switch direction {
        case .download:
            arguments.append(contentsOf: ["\(settings.hostname):\(downloadGlobEscaped(remotePath))", localPath])
        case .upload:
            // Upload targets are not globbed.
            arguments.append(contentsOf: [localPath, "\(settings.hostname):\(remotePath)"])
        }
        return arguments
    }

    static func downloadGlobEscaped(_ remotePath: String) -> String {
        remotePath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "?", with: "\\?")
            .replacingOccurrences(of: "[", with: "\\[")
    }

    /// Absolute ceiling for one transfer, on top of the stall watchdog:
    /// ten minutes plus the time at 50 KB/s — slow enough for any working
    /// link through rash, uncapped, so large files are never killed for
    /// being large. Unknown sizes get a day.
    static func transferCeiling(forBytes bytes: Int64?) -> TimeInterval {
        guard let bytes, bytes >= 0 else {
            return 86_400
        }
        return 600 + TimeInterval(bytes) / 50_000
    }

    /// Compound archive extensions kept whole when uniquifying a name, so a
    /// second "data.tar.gz" becomes "data (2).tar.gz", not "data.tar (2).gz".
    static let compoundExtensions = [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst"]

    static func splitExtension(_ name: String) -> (stem: String, ext: String) {
        let lowered = name.lowercased()
        if let compound = compoundExtensions.first(where: { lowered.hasSuffix($0) && lowered.count > $0.count }) {
            return (String(name.dropLast(compound.count)), String(name.suffix(compound.count)))
        }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, name.count > ext.count + 1 else {
            return (name, "")
        }
        return (String(name.dropLast(ext.count + 1)), "." + ext)
    }

    /// Reserves a free local name by creating it (O_CREAT|O_EXCL, so two
    /// concurrent downloads can never both get "name"): "name", then
    /// "name (2)", "name (3)"… The empty placeholder is replaced atomically
    /// by the finished download.
    static func reserveLocalURL(in directory: URL, preferredName: String) throws -> URL {
        let (stem, ext) = splitExtension(preferredName)
        for counter in 1...10_000 {
            let name = counter == 1 ? preferredName : "\(stem) (\(counter))\(ext)"
            let candidate = directory.appendingPathComponent(name)
            let descriptor = Darwin.open(candidate.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if descriptor >= 0 {
                Darwin.close(descriptor)
                return candidate
            }
            if errno != EEXIST {
                throw MonitorError.processFailed(
                    "Could not create \(candidate.path): \(String(cString: strerror(errno)))"
                )
            }
        }
        throw MonitorError.processFailed("Could not find a free name for \(preferredName) in \(directory.path).")
    }

    /// Hidden sibling a transfer writes before the rename into place.
    static func partName(for name: String) -> String {
        ".\(name).part-\(UUID().uuidString.prefix(8).lowercased())"
    }

    // MARK: Trash naming

    /// The run-name stamp is written, and read back, in the clusters' own
    /// zone (`SlurmTimestamp.clusterTimeZone`, Europe/London), like every
    /// other time on the cluster: the folder lives there, sits next to
    /// `ls -l` times and Slurm times in that zone, and must sort by when it
    /// was made whatever zone the Mac is set to. For a Mac in the UK (where
    /// every older run was named) this is the same as its local time.
    private static func trashStampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = SlurmTimestamp.clusterTimeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }

    /// Trash run folder name: time-sortable for manual recovery, with a UUID
    /// suffix so two trash operations in the same second (or the repeated
    /// DST hour) can never share a folder and silently overwrite each
    /// other's same-named files.
    static func trashRunName(_ date: Date = Date()) -> String {
        "\(trashStampFormatter().string(from: date))-\(UUID().uuidString.prefix(8).lowercased())"
    }

    static func isoTimestamp(_ date: Date = Date()) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// When a run was trashed: the manifest's ISO time, else the stamp at
    /// the start of the run folder's name (cluster time, see
    /// `trashStampFormatter`).
    static func parseTrashDate(created: String?, directory: String) -> Date? {
        if let created, let date = ISO8601DateFormatter().date(from: created) {
            return date
        }
        let name = (directory as NSString).lastPathComponent
        guard name.count >= 15 else {
            return nil
        }
        return trashStampFormatter().date(from: String(name.prefix(15)))
    }

    // MARK: Errors

    /// User-readable error carrying trimmed remote stderr (falling back to
    /// stdout). Never includes the command line itself — paths only.
    static func failure(_ operation: String, _ result: ProcessResult) -> MonitorError {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = stderr.isEmpty ? stdout : stderr
        if detail.isEmpty {
            return .processFailed("\(operation) (exit \(result.exitCode)).")
        }
        return .processFailed("\(operation): \(detail)")
    }
}
