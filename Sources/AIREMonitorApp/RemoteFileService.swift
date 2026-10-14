import HPCCore
import Darwin
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
    /// non-symlinks; false for broken links). Drives navigation, preview
    /// and download gating — scp-over-SFTP cannot fetch a directory through
    /// a link.
    let linkIsDir: Bool?
    /// The remote name is not valid UTF-8. It is shown with U+FFFD, so
    /// `path` does not spell the real file: acting on it could miss it — or
    /// hit a different file whose name really contains U+FFFD — and the app
    /// refuses every action except Copy Path.
    let nameIsLossy: Bool

    init(
        name: String,
        path: String,
        kind: Kind,
        size: Int64? = nil,
        modifiedAt: Date? = nil,
        owner: String? = nil,
        permissions: String? = nil,
        linkTarget: String? = nil,
        linkIsDir: Bool? = nil,
        nameIsLossy: Bool = false
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.owner = owner
        self.permissions = permissions
        self.linkTarget = linkTarget
        self.linkIsDir = linkIsDir
        self.nameIsLossy = nameIsLossy
    }

    var id: String { path }
}

struct RemoteDirectoryListing {
    let requestedPath: String
    let resolvedPath: String    // after symlink/~ resolution
    /// At most `RemoteFileService.entryCap` entries: the first ones in
    /// folders-first natural name order, never an arbitrary subset.
    let entries: [RemoteFileEntry]
    /// More entries matched than the cap allowed.
    let truncated: Bool
    /// Entries in the folder after the hidden-file rule, before `filter`.
    let totalCount: Int
    /// Entries that matched `filter` (equals `totalCount` without one).
    let matchedCount: Int
    /// The server-side, case-insensitive name filter this listing was made
    /// with; "" for none.
    let filter: String

    init(
        requestedPath: String,
        resolvedPath: String,
        entries: [RemoteFileEntry],
        truncated: Bool = false,
        totalCount: Int? = nil,
        matchedCount: Int? = nil,
        filter: String = ""
    ) {
        self.requestedPath = requestedPath
        self.resolvedPath = resolvedPath
        self.entries = entries
        self.truncated = truncated
        self.totalCount = totalCount ?? entries.count
        self.matchedCount = matchedCount ?? totalCount ?? entries.count
        self.filter = filter
    }
}

/// Which end of a file a text preview shows.
enum RemotePreviewMode: String, Sendable, CaseIterable {
    case head
    case tail

    /// Logs are read from the end: what a job printed last is what matters,
    /// and a Slurm log is routinely far larger than the preview window.
    static func preferred(forFileName name: String) -> RemotePreviewMode {
        let lowered = name.lowercased()
        return [".out", ".err", ".log"].contains(where: lowered.hasSuffix) ? .tail : .head
    }
}

/// A text preview and how much of the file it covers, so the sheet can say
/// "Showing the last 256 KB of 912 KB" instead of silently cutting off.
struct RemoteTextPreview: Equatable, Sendable {
    let text: String
    let totalBytes: Int64
    let shownBytes: Int
    let truncated: Bool
    let fromEnd: Bool
}

enum RemoteFilePreview: Equatable {
    case text(RemoteTextPreview)
    case binary(mimeType: String)
}

/// Bytes moved so far; `totalBytes` is nil when the size is unknown.
struct TransferProgress: Sendable, Equatable {
    let transferredBytes: Int64
    let totalBytes: Int64?
}

typealias TransferProgressHandler = @Sendable (TransferProgress) -> Void

/// What an in-flight transfer has created so far: the local placeholder and
/// `.part` file of a download, or the remote `.part` file of an upload.
/// Readable from any thread, because the app's quit handler cleans up
/// synchronously — the transfer's own async cleanup never gets to run once
/// the process is exiting.
final class TransferScratch: @unchecked Sendable {
    private let lock = NSLock()
    private var localFiles: [URL] = []
    private var remotePart: (settings: ConnectionSettings, path: String)?

    func recordLocalFiles(_ urls: [URL]) {
        lock.lock()
        localFiles = urls
        lock.unlock()
    }

    func recordRemotePart(settings: ConnectionSettings, path: String) {
        lock.lock()
        remotePart = (settings, path)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        localFiles = []
        remotePart = nil
        lock.unlock()
    }

    /// Quit-time cleanup: deletes local leftovers now and asks the login
    /// node to delete a remote `.part` file without waiting for the answer.
    func cleanUpForTermination() {
        lock.lock()
        let files = localFiles
        let remote = remotePart
        localFiles = []
        remotePart = nil
        lock.unlock()
        for url in files {
            try? FileManager.default.removeItem(at: url)
        }
        if let remote {
            RemoteFileService.launchDetachedCleanup(
                settings: remote.settings,
                command: "rm -f -- \(RemoteFileService.shellQuote(remote.path))"
            )
        }
    }
}

/// A long remote operation (permanent delete, or a confirmed quota copy
/// into the home trash) running detached on the login node: it survives
/// timeouts, a dropped connection and quitting the app, and is followed by
/// polling `RemoteFileService.pollJob`.
struct RemoteJob: Sendable, Hashable {
    enum Kind: String, Sendable {
        case delete
        case copy
    }

    /// The job's private status folder on the login node (`mkdtemp`).
    let directory: String
    let pid: Int32
    let kind: Kind
    let paths: [String]
    /// For `.copy`: the home-trash run folder receiving the items.
    let destination: String?
}

struct RemoteJobStatus: Equatable {
    enum State: Equatable {
        case running
        case finished
        /// The worker died without finishing (killed, or the node rebooted).
        case crashed
        /// No status folder: already collected, or never started.
        case missing
    }

    let state: State
    let total: Int
    let done: Int
    let failed: [TrashOutcome.Failure]
    let moved: [String]
    let cancelled: Bool
    let current: String?
    let detail: String
}

/// What one Move to Trash did. Every group is attempted and reported, so a
/// partial failure still says where the moved items went.
struct TrashOutcome: Equatable {
    struct Move: Equatable {
        let directory: String
        var paths: [String]
    }

    struct Failure: Equatable, Sendable {
        let path: String
        let reason: String
    }

    var moved: [Move] = []
    var failed: [Failure] = []
    /// A user-confirmed copy into the home trash, still running.
    var copyJob: RemoteJob?

    var movedCount: Int { moved.reduce(0) { $0 + $1.paths.count } }
}

/// One trash run folder (`…/.aire-trash/<timestamp>-<id>`).
struct TrashRun: Identifiable, Equatable {
    struct Item: Identifiable, Equatable {
        let name: String
        let path: String
        let isDirectory: Bool
        /// Where it came from (from the run's manifest); nil for items
        /// trashed by older versions, which cannot be restored by the app.
        let originalPath: String?
        let nameIsLossy: Bool
        var id: String { path }
    }

    enum Location: Equatable {
        /// The shared home trash: the same folder on every cluster.
        case home
        /// Beside items on another filesystem (scratch, flash).
        case beside(parent: String)
    }

    /// Whether the login node could reach a run the home trash's index
    /// records (see `RemoteFileScripts.trashList`). A run that cannot be
    /// reached is still listed, so trashed scratch data that keeps using
    /// quota never silently drops out of the sheet; nothing can act on it
    /// (its contents are unknown) until it is back.
    enum Reachability: Equatable {
        case reachable
        /// The run folder is not at its path: it, its `.aire-trash` or the
        /// folder that held them was renamed, moved or trashed (renaming it
        /// back brings it back), or it was deleted outside the app. The
        /// login node cannot tell these apart, so the entry is never dropped
        /// on its own; `pointer` names the index entry, so the user can
        /// forget it.
        case missing(pointer: String)
        /// The run folder could not be examined (an I/O error, a mount
        /// missing on this login node); usually transient.
        case unavailable
    }

    let directory: String
    let location: Location
    /// Cluster the items were trashed from, when the manifest records it.
    let clusterID: String?
    let createdAt: Date?
    let itemCount: Int
    /// The first items (capped); `itemCount` is the real count.
    let items: [Item]
    let hasManifest: Bool
    let error: String?
    var reachability: Reachability = .reachable

    var id: String { directory }
    var isReachable: Bool { reachability == .reachable }
    var restorableItems: [Item] { items.filter { $0.originalPath != nil && !$0.nameIsLossy } }
}

struct RestoreOutcome: Equatable {
    var restored: [String] = []
    var failed: [TrashOutcome.Failure] = []
    var removedRun = false
}

// MARK: - Runner

/// The two process primitives the file manager needs. `MonitorService`
/// provides them over the cluster's ControlMaster; tests substitute a fake
/// that answers by script, so the destructive paths can be exercised
/// without a cluster.
protocol RemoteCommandRunning: Sendable {
    func runRemoteCommand(
        settings: ConnectionSettings,
        command: String,
        timeout: TimeInterval
    ) async throws -> ProcessResult

    func runTransfer(
        settings: ConnectionSettings,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> ProcessResult
}

extension MonitorService: RemoteCommandRunning {}

// MARK: - Service

/// Remote file operations over the app's existing SSH session. Every remote
/// path is untrusted data: shell interpolation goes through `shellQuote`,
/// `--` precedes every path operand, and everything non-trivial runs as one
/// of the `RemoteFileScripts` Python programs, which take paths in argv and
/// answer in JSON.
///
/// The service is stateless and cluster-agnostic: every call takes the
/// `ConnectionSettings` of the cluster it targets, and all operations run
/// through the runner (`MonitorService.runRemoteCommand` / `runTransfer`)
/// over THAT cluster's ControlMaster. Both pre-flight the master with
/// `ssh -O check`, so a dead session throws "<Cluster> SSH session expired"
/// instantly instead of hanging.
///
/// Every remote command is bounded ON THE SERVER with `timeout -k 5 <s>`
/// as well as locally. Killing the local ssh client alone does not stop a
/// remote command without a pty — sshd only closes its pipes, and `du`,
/// `rm -rf` or a cross-device `mv` print nothing until they finish — so
/// without the remote bound a "timed out" operation would keep running on
/// the login node. Work that may legitimately take hours (permanent delete,
/// a confirmed copy into the home trash) is not bounded but detached
/// instead, as a `RemoteJob` with progress and Cancel.
///
/// Remote environment contract (holds on AIRE and on Calder's Rocky 9 login
/// nodes): an sh-compatible login shell, GNU coreutils (`timeout`, `stat
/// -c`, `du`, `mkdir`/`mv`/`ln`/`rm` with `--`) and Python 3.6 or newer.
/// `file(1)` is optional: previews fall back to sniffing the content.
struct RemoteFileService: Sendable {
    let runner: any RemoteCommandRunning

    init(runner: any RemoteCommandRunning = MonitorService()) {
        self.runner = runner
    }

    /// Most entries one listing returns.
    static let entryCap = 4000

    /// Name of the server-side trash folder. It keeps the `.aire-trash`
    /// name from the single-cluster app so everything trashed by earlier
    /// versions stays exactly where users expect to find it.
    ///
    /// Home (/users/$USER) is ONE NFS export mounted on every Leeds cluster,
    /// so `~/.aire-trash` is the same folder whether an item was trashed from
    /// AIRE or from Calder. Items on another filesystem (scratch, flash) get
    /// a folder of this name beside them instead — see `moveToTrash`.
    static let trashDirectoryName = ".aire-trash"

    /// `~/.aire-trash`, for user-facing text — one folder, whichever
    /// cluster's Files tab is showing it.
    static var homeTrashDisplayPath: String {
        "~/\(trashDirectoryName)"
    }

    /// Longest remote command line sent as-is. sshd hands the command to
    /// the login shell as ONE argv string, which Linux caps at 128 KiB
    /// (MAX_ARG_STRLEN); bigger argument lists — a select-all of thousands
    /// of logs — are staged in a file instead (`stageArguments`).
    static let commandBudget = 96_000

    // MARK: Command plumbing

    /// Remote command running one of the embedded scripts, bounded on the
    /// server by `seconds`.
    ///
    /// Prefers the system interpreter `/usr/bin/python3` (3.9 on Calder's
    /// Rocky 9 login nodes) over whatever `python3` a user's conda or module
    /// initialisation puts first on PATH, and falls back to the PATH lookup
    /// where no system interpreter exists. `-I` (isolated mode) ignores
    /// PYTHONPATH/PYTHONHOME and user site-packages and, crucially for `-c`,
    /// keeps the remote working directory — the home directory — off
    /// sys.path, so a stray ~/json.py or ~/stat.py can never shadow the
    /// standard modules the scripts import.
    static func pythonCommand(script: String, arguments: [String], seconds: Int) -> String {
        let quotedArguments = arguments.map { " " + shellQuote($0) }.joined()
        return "hpc_python=python3; "
            + "if [ -x /usr/bin/python3 ]; then hpc_python=/usr/bin/python3; fi; "
            + "\(boundPrefix(seconds: seconds))\"$hpc_python\" -I -c \(shellQuote(script))\(quotedArguments)"
    }

    /// `timeout -k 5 <s> ` — GNU timeout sends TERM after `seconds` and KILL
    /// five seconds later. The local watchdog is set beyond both
    /// (`localTimeout`) so the server's verdict normally arrives first.
    static func boundPrefix(seconds: Int) -> String {
        "timeout -k 5 \(max(1, seconds)) "
    }

    static func bounded(_ command: String, seconds: Int) -> String {
        boundPrefix(seconds: seconds) + command
    }

    static func localTimeout(forRemoteBound seconds: Int) -> TimeInterval {
        TimeInterval(max(1, seconds) + 10)
    }

    /// GNU timeout's exit for TERM (124) and, after `-k`, KILL (137) — and
    /// the local watchdog's 124.
    static func isTimeout(_ result: ProcessResult) -> Bool {
        result.exitCode == 124 || result.exitCode == 137
    }

    private func runScript(
        _ script: String,
        arguments: [String],
        settings: ConnectionSettings,
        seconds: Int
    ) async throws -> ProcessResult {
        var finalArguments = arguments
        let length = Self.pythonCommand(script: script, arguments: arguments, seconds: seconds).utf8.count
        if length > Self.commandBudget {
            finalArguments = [try await stageArguments(arguments, settings: settings)]
        }
        return try await runner.runRemoteCommand(
            settings: settings,
            command: Self.pythonCommand(script: script, arguments: finalArguments, seconds: seconds),
            timeout: Self.localTimeout(forRemoteBound: seconds)
        )
    }

    private func runShell(
        _ command: String,
        settings: ConnectionSettings,
        seconds: Int
    ) async throws -> ProcessResult {
        try await runner.runRemoteCommand(
            settings: settings,
            command: Self.bounded(command, seconds: seconds),
            timeout: Self.localTimeout(forRemoteBound: seconds)
        )
    }

    /// Uploads an oversized argument list as a NUL-separated file in the
    /// login node's /tmp (a random name; the scripts accept it only as a
    /// regular file owned by the user, and delete it once read) and returns
    /// the `@<path>` argument that stands for it. Every later command of
    /// the same operation runs over the same ControlMaster, so it reaches
    /// the same login node.
    private func stageArguments(_ arguments: [String], settings: ConnectionSettings) async throws -> String {
        let token = UUID().uuidString.lowercased()
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("hpc-monitor-args-\(token)")
        let remote = "/tmp/hpc-monitor-args-\(token)"
        var data = Data()
        for argument in arguments {
            data.append(Data(argument.utf8))
            data.append(0)
        }
        try data.write(to: local, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: local)
        }
        let result = try await runner.runTransfer(
            settings: settings,
            arguments: Self.scpArguments(
                settings: settings,
                remotePath: remote,
                localPath: local.path,
                direction: .upload
            ),
            timeout: 120
        )
        guard result.exitCode == 0 else {
            throw Self.failure("Could not send the list of \(arguments.count) items to \(settings.clusterName)", result)
        }
        return "@\(remote)"
    }

    /// The first JSON object line of a script's output. Scripts print one
    /// object per line; a chatty login shell (a .bashrc that echoes) may add
    /// other lines, which are skipped rather than failing the decode.
    private static func jsonObjects(_ output: String) -> [[String: Any]] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> [String: Any]? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else {
                    return nil
                }
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        from result: ProcessResult,
        operation: String,
        settings: ConnectionSettings
    ) throws -> T {
        let lines = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("{") }
        for line in lines {
            let data = Data(line.utf8)
            if let error = try? JSONDecoder().decode(RemoteErrorPayload.self, from: data) {
                throw MonitorError.processFailed(error.error)
            }
        }
        if isTimeout(result) {
            throw MonitorError.processFailed(
                "\(operation) timed out on \(settings.clusterName) — the filesystem may be slow. Try again in a moment."
            )
        }
        guard result.exitCode == 0 else {
            throw failure(operation, result)
        }
        for line in lines {
            if let value = try? JSONDecoder().decode(T.self, from: Data(line.utf8)) {
                return value
            }
        }
        throw MonitorError.invalidJSON("\(operation): the login node's reply could not be read.")
    }

    // MARK: Home & roots

    /// realpath(~) and realpath of each given path on the login node.
    func resolveHome(settings: ConnectionSettings, roots: [String] = []) async throws -> (home: String, roots: [String]) {
        let result = try await runScript(
            RemoteFileScripts.roots,
            arguments: roots.filter { $0.hasPrefix("/") },
            settings: settings,
            seconds: 20
        )
        let payload = try Self.decode(RootsPayload.self, from: result, operation: "Finding your home directory", settings: settings)
        guard payload.home.hasPrefix("/") else {
            throw MonitorError.processFailed("Could not determine the remote home directory on \(settings.clusterName).")
        }
        return (payload.home, payload.roots)
    }

    func homeDirectory(settings: ConnectionSettings) async throws -> String {
        try await resolveHome(settings: settings).home
    }

    // MARK: Listing

    func listDirectory(
        settings: ConnectionSettings,
        path: String,
        showHidden: Bool,
        filter: String = ""
    ) async throws -> RemoteDirectoryListing {
        let target = path.isEmpty ? "~" : path
        var arguments = [target, showHidden ? "1" : "0", String(Self.entryCap)]
        if !filter.isEmpty {
            arguments.append(filter)
        }
        let result = try await runScript(RemoteFileScripts.listing, arguments: arguments, settings: settings, seconds: 40)
        let payload = try Self.decode(ListingPayload.self, from: result, operation: "Listing \(target)", settings: settings)
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
                linkIsDir: entry.linkIsDir,
                nameIsLossy: entry.lossy ?? false
            )
        }
        return RemoteDirectoryListing(
            requestedPath: payload.requested,
            resolvedPath: payload.resolved,
            entries: entries,
            truncated: payload.truncated,
            totalCount: payload.total ?? entries.count,
            matchedCount: payload.matched ?? entries.count,
            filter: payload.filter ?? filter
        )
    }

    // MARK: Simple mutations

    /// Plain `mkdir` (no `-p`): the name was validated not to contain "/",
    /// so `-p` would only turn "that name already exists" into a silent
    /// success that looks like a new folder.
    func createDirectory(settings: ConnectionSettings, path: String) async throws {
        let target = try Self.requireNonEmptyPath(path, operation: "Create folder")
        // The existence test makes the answer independent of the remote
        // locale's wording; "File exists" still covers a racing creation.
        let script = "if [ -e \"$1\" ] || [ -L \"$1\" ]; then exit 41; fi; mkdir -- \"$1\""
        let result = try await runShell(
            "sh -c \(Self.shellQuote(script)) sh \(Self.shellQuote(target))",
            settings: settings,
            seconds: 20
        )
        guard result.exitCode == 0 else {
            if result.exitCode == 41 || result.stderr.contains("File exists") {
                let name = (target as NSString).lastPathComponent
                throw MonitorError.processFailed("A file or folder named “\(name)” already exists.")
            }
            if Self.isTimeout(result) {
                throw MonitorError.processFailed("Creating \(target) timed out on \(settings.clusterName).")
            }
            throw Self.failure("Could not create \(target)", result)
        }
    }

    /// Renames a single entry within its folder. Fails when the target
    /// already exists (checked server-side with `test -e`/`test -L` in the
    /// same command, so broken symlinks are also refused).
    func rename(settings: ConnectionSettings, from: String, to: String) async throws {
        let source = try Self.requireNonEmptyPath(from, operation: "Rename")
        let target = try Self.requireNonEmptyPath(to, operation: "Rename")
        let script = "if [ -e \"$2\" ] || [ -L \"$2\" ]; then exit 41; fi; mv -- \"$1\" \"$2\""
        let command = "sh -c \(Self.shellQuote(script)) sh \(Self.shellQuote(source)) \(Self.shellQuote(target))"
        let result = try await runShell(command, settings: settings, seconds: 30)
        if result.exitCode == 41 {
            throw MonitorError.processFailed("Cannot rename: \(target) already exists.")
        }
        guard result.exitCode == 0 else {
            throw Self.failure("Could not rename \(source)", result)
        }
    }

    // MARK: Trash

    /// Thrown by `moveToTrash` when cross-filesystem items cannot get a
    /// trash folder on their own filesystem: proceeding would COPY the data
    /// into the home trash, and home is a small quota (65 GiB) shared by
    /// every cluster. Callers confirm with the user — showing `bytes`, and
    /// only offering the copy when it fits — then retry with
    /// `allowQuotaCopy: true`, or offer permanent delete instead. Nothing
    /// has been moved when this is thrown.
    struct QuotaCopyConfirmationRequired: Error, LocalizedError {
        let paths: [String]
        /// Measured with a bounded `du`; nil when it did not finish in time.
        let bytes: Int64?

        var errorDescription: String? {
            "Moving \(paths.count) item\(paths.count == 1 ? "" : "s") to trash "
                + "would copy data into your home quota."
        }
    }

    /// Moves paths into fresh per-operation trash folders
    /// (`<…>/<trashDirectoryName>/<timestamp>-<uuid8>/`). This is the
    /// default "delete": recoverable from the Trash sheet or with `mv`.
    ///
    /// Items on the home filesystem go to `~/<trashDirectoryName>` — the
    /// shared home, so the same folder on every cluster. Items on another
    /// filesystem (AIRE /mnt/scratch, Calder /scratch-calder and
    /// /flash-calder) go to a trash folder beside them, so the move is
    /// still a rename and never copies data into the home quota; they keep
    /// counting toward that filesystem's quota until the trash is emptied.
    /// Only when that folder cannot be created does the move fall back to a
    /// copy into the home trash — gated on `allowQuotaCopy` (see
    /// `QuotaCopyConfirmationRequired`) and run as a detached `RemoteJob`.
    ///
    /// Safety, in order: the app-side `validatedTargets` check; a refusal
    /// to re-trash anything already inside a trash folder; a server-side
    /// re-check against realpath'd roots; a fail-closed device probe (an
    /// undeterminable filesystem moves nothing); a writable-parent check
    /// (without it a cross-device `mv` copies everything and only then
    /// fails to unlink). The moves themselves are `os.rename` calls, which
    /// cannot copy across filesystems at all. Every group is attempted and
    /// reported in the returned outcome, including partial failures.
    func moveToTrash(
        settings: ConnectionSettings,
        paths: [String],
        protectedRoots: [String],
        allowQuotaCopy: Bool = false
    ) async throws -> TrashOutcome {
        let targets = try Self.validatedTargets(paths, protectedRoots: protectedRoots, operation: "Move to trash")
        try Self.refuseTrashingTrash(targets)
        let runName = Self.trashRunName()
        let createdAt = Self.isoTimestamp()

        let inspection = try await inspectTrash(
            settings: settings,
            targets: targets,
            protectedRoots: protectedRoots,
            runName: runName
        )
        let plan: TrashPlan
        do {
            plan = try Self.planTrash(inspection, runName: runName)
        } catch {
            await removeEmptyDirectories(inspection.mountTrash.compactMap(\.createdDirectory), settings: settings)
            throw error
        }

        if !plan.quotaCopyTargets.isEmpty, !allowQuotaCopy {
            let bytes = await totalSizeBytes(settings: settings, paths: plan.quotaCopyTargets)
            await removeEmptyDirectories(plan.preparedDirectories, settings: settings)
            throw QuotaCopyConfirmationRequired(paths: plan.quotaCopyTargets, bytes: bytes)
        }

        var outcome = TrashOutcome()
        if !plan.groups.isEmpty || !plan.unusedDirectories.isEmpty {
            outcome = try await executeTrash(
                plan,
                runName: runName,
                createdAt: createdAt,
                settings: settings
            )
        }
        if !plan.quotaCopyTargets.isEmpty {
            do {
                outcome.copyJob = try await startJob(
                    kind: .copy,
                    settings: settings,
                    targets: plan.quotaCopyTargets,
                    protectedRoots: protectedRoots,
                    destination: plan.homeTrashDirectory,
                    runName: runName,
                    createdAt: createdAt
                )
            } catch {
                // The renames above already happened: throwing now would
                // drop the outcome that says where those items went, and the
                // user would see "failed" while most of the selection has
                // left the folder. Report the copy as failed items instead.
                // With nothing renamed or reported yet, the plain error is
                // the whole truth.
                if outcome.moved.isEmpty, outcome.failed.isEmpty {
                    throw error
                }
                let reason = "the copy into the home trash could not be started, so it is still in place: "
                    + error.localizedDescription
                outcome.failed += plan.quotaCopyTargets.map { TrashOutcome.Failure(path: $0, reason: reason) }
            }
        }
        return outcome
    }

    private func inspectTrash(
        settings: ConnectionSettings,
        targets: [String],
        protectedRoots: [String],
        runName: String
    ) async throws -> TrashInspection {
        let arguments = ["--run", runName, "--trash-name", Self.trashDirectoryName, "--roots"]
            + protectedRoots.filter { $0.hasPrefix("/") }
            + ["--targets"] + targets
        let result = try await runScript(RemoteFileScripts.trashInspect, arguments: arguments, settings: settings, seconds: 45)
        let payload = try Self.decode(
            TrashInspectPayload.self,
            from: result,
            operation: "Preparing the trash",
            settings: settings
        )
        if let refused = payload.refused?.first {
            throw MonitorError.processFailed(
                "Move to trash refused for \(refused.path): \(refused.reason). Nothing was moved."
            )
        }
        return TrashInspection(
            home: payload.home,
            homeDevice: payload.homeDevice,
            targets: (payload.targets ?? []).map {
                TrashProbe(
                    path: $0.path,
                    device: $0.device,
                    error: $0.error,
                    parent: $0.parent,
                    parentWritable: $0.parentWritable
                )
            },
            mountTrash: (payload.mountTrash ?? []).map {
                MountTrashDirectory(
                    parent: $0.parent,
                    directory: $0.directory,
                    error: $0.error,
                    createdBase: $0.createdBase ?? false
                )
            }
        )
    }

    private func executeTrash(
        _ plan: TrashPlan,
        runName: String,
        createdAt: String,
        settings: ConnectionSettings
    ) async throws -> TrashOutcome {
        var arguments = [
            "--run", runName,
            "--cluster", settings.clusterID.rawValue,
            "--created", createdAt,
            "--trash-name", Self.trashDirectoryName
        ]
        for group in plan.groups {
            arguments += ["--group", group.directory, group.isHome ? "home" : "mount"] + group.paths
        }
        if !plan.unusedDirectories.isEmpty {
            arguments += ["--cleanup"] + plan.unusedDirectories
        }
        let allTargets = plan.groups.flatMap(\.paths)
        // Renames are metadata operations; even thousands finish in
        // seconds. The bound only guards a hung filesystem.
        let seconds = 60 + allTargets.count / 20
        let result = try await runScript(RemoteFileScripts.trashExecute, arguments: arguments, settings: settings, seconds: seconds)
        return try Self.trashOutcome(from: result, targets: allTargets, settings: settings)
    }

    /// Builds the outcome from the execute script's per-item lines. When the
    /// final `done` line is missing (the bound or the connection cut the
    /// run short), every item not reported is listed as not attempted, so
    /// the user is never told less than what happened.
    static func trashOutcome(
        from result: ProcessResult,
        targets: [String],
        settings: ConnectionSettings
    ) throws -> TrashOutcome {
        let objects = jsonObjects(result.stdout)
        if let error = objects.first(where: { $0["error"] != nil && $0["failed"] == nil })?["error"] as? String {
            throw MonitorError.processFailed(error)
        }
        var outcome = TrashOutcome()
        var reported = Set<String>()
        var finished = false
        for object in objects {
            if let source = object["moved"] as? String, let directory = object["directory"] as? String {
                reported.insert(source)
                if let index = outcome.moved.firstIndex(where: { $0.directory == directory }) {
                    outcome.moved[index].paths.append(source)
                } else {
                    outcome.moved.append(TrashOutcome.Move(directory: directory, paths: [source]))
                }
            } else if let source = object["failed"] as? String {
                reported.insert(source)
                outcome.failed.append(TrashOutcome.Failure(path: source, reason: object["error"] as? String ?? "unknown error"))
            } else if object["done"] as? Bool == true {
                finished = true
            }
        }
        if !finished {
            if outcome.moved.isEmpty, outcome.failed.isEmpty, !isTimeout(result) {
                throw failure("Could not move items to trash on \(settings.clusterName)", result)
            }
            let reason = isTimeout(result)
                ? "not attempted — the trash operation timed out; refresh to check"
                : "not attempted — the trash operation stopped early; refresh to check"
            for target in targets where !reported.contains(target) {
                outcome.failed.append(TrashOutcome.Failure(path: target, reason: reason))
            }
        }
        return outcome
    }

    /// Best effort: removes still-empty per-mount trash folders created by
    /// a pre-flight whose move did not happen (and their `.aire-trash`
    /// parent when that is empty too).
    private func removeEmptyDirectories(_ directories: [String], settings: ConnectionSettings) async {
        guard !directories.isEmpty else {
            return
        }
        let arguments = ["--run", "", "--trash-name", Self.trashDirectoryName, "--cleanup"] + directories
        _ = try? await runScript(RemoteFileScripts.trashExecute, arguments: arguments, settings: settings, seconds: 20)
    }

    // MARK: Permanent delete & background jobs

    /// Starts an irreversible `rm -rf` as a detached job and returns it for
    /// polling. Callers must double-confirm in the UI; this method
    /// independently refuses everything `validatedTargets` refuses, and the
    /// job starter re-checks the targets against realpath'd roots on the
    /// login node before anything is deleted.
    func startPermanentDelete(
        settings: ConnectionSettings,
        paths: [String],
        protectedRoots: [String]
    ) async throws -> RemoteJob {
        let targets = try Self.validatedTargets(paths, protectedRoots: protectedRoots, operation: "Delete")
        return try await startJob(
            kind: .delete,
            settings: settings,
            targets: targets,
            protectedRoots: protectedRoots,
            destination: nil,
            runName: nil,
            createdAt: nil
        )
    }

    private func startJob(
        kind: RemoteJob.Kind,
        settings: ConnectionSettings,
        targets: [String],
        protectedRoots: [String],
        destination: String?,
        runName: String?,
        createdAt: String?
    ) async throws -> RemoteJob {
        // Every job names the trash folder: a copy files into it, and a
        // delete that removes a trash run folder (Empty) drops that run's
        // index pointer, so an emptied run is not listed as missing.
        var arguments = ["--worker", RemoteFileScripts.jobWorker, "--mode", kind.rawValue, "--roots"]
            + protectedRoots.filter { $0.hasPrefix("/") }
            + ["--targets"] + targets
            + ["--trash-name", Self.trashDirectoryName]
        if let destination {
            arguments += [
                "--destination", destination,
                "--run", runName ?? "",
                "--cluster", settings.clusterID.rawValue,
                "--created", createdAt ?? ""
            ]
        }
        let operation = kind == .delete ? "Starting the delete" : "Starting the copy into the home trash"
        let result = try await runScript(RemoteFileScripts.jobStart, arguments: arguments, settings: settings, seconds: 30)
        let payload = try Self.decode(JobStartPayload.self, from: result, operation: operation, settings: settings)
        if let refused = payload.refused?.first {
            let verb = kind == .delete ? "Delete" : "Move to trash"
            throw MonitorError.processFailed("\(verb) refused for \(refused.path): \(refused.reason). Nothing was changed.")
        }
        guard let directory = payload.job, let pid = payload.pid else {
            throw MonitorError.invalidJSON("\(operation): the login node's reply could not be read.")
        }
        return RemoteJob(directory: directory, pid: pid, kind: kind, paths: targets, destination: destination)
    }

    func pollJob(settings: ConnectionSettings, job: RemoteJob) async throws -> RemoteJobStatus {
        let result = try await runScript(
            RemoteFileScripts.jobPoll,
            arguments: [job.directory, String(job.pid), "poll"],
            settings: settings,
            seconds: 20
        )
        let payload = try Self.decode(JobPollPayload.self, from: result, operation: "Checking progress", settings: settings)
        let state: RemoteJobStatus.State
        switch payload.state {
        case "running":
            state = .running
        case "finished":
            state = .finished
        case "crashed":
            state = .crashed
        default:
            state = .missing
        }
        let status = payload.status
        return RemoteJobStatus(
            state: state,
            total: status?.total ?? job.paths.count,
            done: status?.done ?? 0,
            failed: (status?.failed ?? []).map { TrashOutcome.Failure(path: $0.path, reason: $0.error) },
            moved: status?.moved ?? [],
            cancelled: status?.cancelled ?? false,
            current: status?.current,
            detail: payload.detail ?? ""
        )
    }

    /// Sends SIGTERM to the job's process group (verified to be this job's
    /// worker first). The next poll reports the job as cancelled.
    func cancelJob(settings: ConnectionSettings, job: RemoteJob) async throws {
        let result = try await runScript(
            RemoteFileScripts.jobPoll,
            arguments: [job.directory, String(job.pid), "cancel"],
            settings: settings,
            seconds: 20
        )
        _ = try Self.decode(JobPollPayload.self, from: result, operation: "Cancelling", settings: settings)
    }

    // MARK: Preview

    /// One round trip: type, size and up to `maxBytes` from the head or the
    /// tail. Text is anything `file(1)` gives a non-binary charset (so JSON
    /// and notebooks count) — re-checked on the bytes themselves whenever
    /// the type is not text/* — or, without file(1), anything that sniffs
    /// as text.
    func preview(
        settings: ConnectionSettings,
        path: String,
        maxBytes: Int,
        mode: RemotePreviewMode
    ) async throws -> RemoteFilePreview {
        let target = try Self.requireNonEmptyPath(path, operation: "Preview")
        let result = try await runScript(
            RemoteFileScripts.preview,
            arguments: [target, String(max(1, maxBytes)), mode.rawValue],
            settings: settings,
            seconds: 30
        )
        let payload = try Self.decode(PreviewPayload.self, from: result, operation: "Preview of \(target)", settings: settings)
        let data = Data(base64Encoded: payload.data) ?? Data()
        return Self.classifyPreview(payload: payload, data: data)
    }

    static func classifyPreview(payload: PreviewPayload, data: Data) -> RemoteFilePreview {
        var text = String(decoding: data, as: UTF8.self)
        let mime = payload.mime?.lowercased()
        if payload.hasFile, let mime {
            let isEmpty = mime == "inode/x-empty"
            let charsetSaysText = payload.charset.map { $0 != "binary" } ?? false
            guard isEmpty || charsetSaysText else {
                return .binary(mimeType: mime)
            }
            if !isEmpty, !mime.hasPrefix("text/"), looksBinary(text) {
                return .binary(mimeType: mime)
            }
        } else if looksBinary(text) {
            return .binary(mimeType: mime ?? "application/octet-stream")
        }
        // A head cut mid-codepoint ends in a replacement character that is
        // purely a truncation artifact — drop it. Untruncated files keep
        // theirs.
        if payload.truncated, !payload.fromEnd, text.hasSuffix("\u{FFFD}") {
            text.removeLast()
        }
        return .text(RemoteTextPreview(
            text: text,
            totalBytes: payload.size,
            shownBytes: data.count,
            truncated: payload.truncated,
            fromEnd: payload.fromEnd
        ))
    }

    /// NUL bytes, or more than one in twenty characters failing UTF-8
    /// decoding (they arrive as U+FFFD), mean binary.
    static func looksBinary(_ text: String) -> Bool {
        var scalars = 0
        var replacements = 0
        for scalar in text.unicodeScalars {
            if scalar == "\0" {
                return true
            }
            scalars += 1
            if scalar == "\u{FFFD}" {
                replacements += 1
            }
        }
        return replacements > max(8, scalars / 20)
    }

    // MARK: Folder size

    /// Human-readable recursive size, e.g. "1.2G". Bounded on the server so
    /// an abandoned Folder Size never leaves a `du` loading the Lustre
    /// metadata server.
    ///
    /// `-H` follows the path itself when it is a symlink — Folder Size is
    /// offered for links to folders, above all the `~/scratch` link into
    /// scratch, and plain `du -s` (GNU and BSD alike) would measure the link
    /// (0) — but not the links inside the tree, which `-L` would also follow
    /// (counting other trees, or looping).
    func diskUsage(settings: ConnectionSettings, path: String) async throws -> String {
        let target = try Self.requireNonEmptyPath(path, operation: "Disk usage")
        let result = try await runShell("du -shH -- \(Self.shellQuote(target))", settings: settings, seconds: 170)
        if Self.isTimeout(result) {
            throw MonitorError.processFailed(
                "This folder is too large to measure quickly — run du -sh in the terminal instead."
            )
        }
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

    /// Total size in bytes of the given paths via a bounded `du -sk`. du
    /// prints each argument's total as it finishes, so a timeout still
    /// yields the totals measured so far — but then the sum is incomplete,
    /// and nil is returned rather than an underestimate.
    func totalSizeBytes(settings: ConnectionSettings, paths: [String]) async -> Int64? {
        guard !paths.isEmpty else {
            return nil
        }
        let quoted = paths.map(Self.shellQuote).joined(separator: " ")
        guard let result = try? await runShell("du -sk -- \(quoted)", settings: settings, seconds: 60),
              !Self.isTimeout(result) else {
            return nil
        }
        let totals = Self.parseDiskUsageKiB(result.stdout)
        guard !totals.isEmpty else {
            return nil
        }
        return totals.values.reduce(0, +)
    }

    /// `du -sk` lines ("<KiB>\t<path>") as bytes by path.
    static func parseDiskUsageKiB(_ output: String) -> [String: Int64] {
        var totals: [String: Int64] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let kibibytes = Int64(parts[0].trimmingCharacters(in: .whitespaces)) else {
                continue
            }
            totals[String(parts[1]), default: 0] += kibibytes * 1024
        }
        return totals
    }

    // MARK: Transfers

    func download(
        settings: ConnectionSettings,
        remotePath: String,
        toLocalDirectory: URL,
        scratch: TransferScratch? = nil,
        progress: TransferProgressHandler? = nil
    ) async throws -> URL {
        var source = try Self.requireNonEmptyPath(remotePath, operation: "Download")
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
        let size = try await remoteRegularFileSize(settings: settings, path: source)

        try FileManager.default.createDirectory(at: toLocalDirectory, withIntermediateDirectories: true)
        // The final name is reserved (created empty, O_EXCL) before scp
        // starts, so two downloads of "results.csv" can never pick — and
        // write into — the same file; scp writes a hidden sibling that is
        // renamed over the placeholder only once complete, so a partial
        // file never sits under the real name.
        let reserved = try Self.reserveLocalURL(in: toLocalDirectory, preferredName: name)
        let part = toLocalDirectory.appendingPathComponent(Self.partName(for: reserved.lastPathComponent))
        scratch?.recordLocalFiles([part, reserved])
        progress?(TransferProgress(transferredBytes: 0, totalBytes: size))

        do {
            let result = try await runWatchedTransfer(
                settings: settings,
                arguments: Self.scpArguments(
                    settings: settings,
                    remotePath: source,
                    localPath: part.path,
                    direction: .download
                ),
                name: name,
                totalBytes: size,
                pollInterval: 1,
                sample: { Self.localFileSize(part) ?? 0 },
                progress: progress
            )
            guard result.exitCode == 0 else {
                if Task.isCancelled {
                    throw CancellationError()
                }
                throw Self.failure("Download of \(name) failed", result)
            }
            guard Darwin.rename(part.path, reserved.path) == 0 else {
                throw MonitorError.processFailed(
                    "Downloaded \(name), but could not move it into place: \(String(cString: strerror(errno)))"
                )
            }
            scratch?.clear()
            let finalSize = Self.localFileSize(reserved) ?? size ?? 0
            progress?(TransferProgress(transferredBytes: finalSize, totalBytes: size ?? finalSize))
            return reserved
        } catch {
            try? FileManager.default.removeItem(at: part)
            try? FileManager.default.removeItem(at: reserved)
            scratch?.clear()
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    /// Uploads into `<dir>/.<name>.part-<id>` and only then links the part
    /// to the real name with `ln`, which fails atomically if that name
    /// appeared meanwhile — a failed or cancelled upload never leaves a
    /// truncated file under the real name for a job to read as complete,
    /// and never replaces someone's file.
    func upload(
        settings: ConnectionSettings,
        localFile: URL,
        toRemoteDirectory: String,
        scratch: TransferScratch? = nil,
        progress: TransferProgressHandler? = nil
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
        var directory = try Self.requireNonEmptyPath(toRemoteDirectory, operation: "Upload")
        if directory.hasPrefix("~") {
            directory = try await expandTilde(directory, settings: settings)
        }
        directory = Self.trimTrailingSlashes(directory)
        let name = localFile.lastPathComponent
        let destination = Self.joinPath(directory, name)
        let part = Self.joinPath(directory, Self.partName(for: name))
        let localSize = Self.localFileSize(localFile)

        // Fail before sending gigabytes: the folder must exist and be
        // writable, and the name must be free (`-L` catches broken links).
        let precheck = "if [ ! -d \"$1\" ]; then exit 43; fi; "
            + "if [ -e \"$2\" ] || [ -L \"$2\" ]; then exit 41; fi; "
            + "if [ ! -w \"$1\" ]; then exit 42; fi"
        let check = try await runShell(
            "sh -c \(Self.shellQuote(precheck)) sh \(Self.shellQuote(directory)) \(Self.shellQuote(destination))",
            settings: settings,
            seconds: 20
        )
        switch check.exitCode {
        case 0:
            break
        case 41:
            throw MonitorError.processFailed("Cannot upload: \(name) already exists in \(directory).")
        case 42:
            throw MonitorError.processFailed("Cannot upload: you don't have permission to write to \(directory).")
        case 43:
            throw MonitorError.processFailed("Cannot upload: \(directory) no longer exists.")
        default:
            throw Self.failure("Could not check \(destination) before upload", check)
        }

        scratch?.recordRemotePart(settings: settings, path: part)
        progress?(TransferProgress(transferredBytes: 0, totalBytes: localSize))
        do {
            let result = try await runWatchedTransfer(
                settings: settings,
                arguments: Self.scpArguments(
                    settings: settings,
                    remotePath: part,
                    localPath: localFile.path,
                    direction: .upload
                ),
                name: name,
                totalBytes: localSize,
                pollInterval: 10,
                sample: { [self] in await self.remoteFileSize(settings: settings, path: part) },
                progress: progress
            )
            guard result.exitCode == 0 else {
                if Task.isCancelled {
                    throw CancellationError()
                }
                throw Self.failure("Upload of \(name) failed", result)
            }
            // `ln` refuses an existing name atomically. Where hard links are
            // not supported, `mv -n` (no-clobber) is the fallback, and the
            // part file still being there afterwards tells "the name was
            // taken" (41) from any other failure (44).
            let finalize = "if ln -- \"$1\" \"$2\" 2>/dev/null; then rm -f -- \"$1\"; exit 0; fi; "
                + "if [ -e \"$2\" ] || [ -L \"$2\" ]; then rm -f -- \"$1\"; exit 41; fi; "
                + "mv -n -- \"$1\" \"$2\"; "
                + "if [ -e \"$1\" ]; then "
                + "if [ -e \"$2\" ] || [ -L \"$2\" ]; then rm -f -- \"$1\"; exit 41; fi; exit 44; fi"
            let finished = try await runShell(
                "sh -c \(Self.shellQuote(finalize)) sh \(Self.shellQuote(part)) \(Self.shellQuote(destination))",
                settings: settings,
                seconds: 30
            )
            if finished.exitCode == 41 {
                scratch?.clear()
                throw MonitorError.processFailed(
                    "Uploaded \(name), but a file of that name appeared in \(directory) meanwhile — the upload was discarded."
                )
            }
            guard finished.exitCode == 0 else {
                throw Self.failure("Uploaded \(name), but could not move it into place", finished)
            }
            scratch?.clear()
            progress?(TransferProgress(transferredBytes: localSize ?? 0, totalBytes: localSize))
        } catch {
            // Detached from this task: a cancelled task would SIGTERM the
            // cleanup's own ssh at launch.
            let service = self
            await Task {
                _ = try? await service.runShell("rm -f -- \(Self.shellQuote(part))", settings: settings, seconds: 20)
            }.value
            scratch?.clear()
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    /// No data for this long ends a transfer. A stall check rather than a
    /// size-scaled deadline: a slow link through rash is fine as long as
    /// bytes keep moving.
    static let transferStallTimeout: TimeInterval = 120

    struct TransferStalled: Error, LocalizedError {
        let name: String
        var errorDescription: String? {
            "Transfer of \(name) stopped: no data moved for "
                + "\(Int(RemoteFileService.transferStallTimeout / 60)) minutes. Check the connection and try again."
        }
    }

    /// Runs scp with a generous absolute ceiling plus a stall watchdog that
    /// samples progress every `pollInterval`. A failed sample (nil) never
    /// counts as a stall: it only means the probe could not tell.
    private func runWatchedTransfer(
        settings: ConnectionSettings,
        arguments: [String],
        name: String,
        totalBytes: Int64?,
        pollInterval: TimeInterval,
        sample: @escaping @Sendable () async -> Int64?,
        progress: TransferProgressHandler?
    ) async throws -> ProcessResult {
        let runner = self.runner
        let ceiling = Self.transferCeiling(forBytes: totalBytes)
        let stallLimit = Duration.seconds(Self.transferStallTimeout)
        return try await withThrowingTaskGroup(of: WatchedTransferOutcome.self) { group in
            group.addTask {
                .finished(try await runner.runTransfer(settings: settings, arguments: arguments, timeout: ceiling))
            }
            group.addTask {
                var best: Int64 = -1
                var lastAdvance = ContinuousClock.now
                while true {
                    try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                    let now = ContinuousClock.now
                    guard let value = await sample() else {
                        lastAdvance = now
                        continue
                    }
                    if value > best {
                        best = value
                        lastAdvance = now
                        progress?(TransferProgress(transferredBytes: value, totalBytes: totalBytes))
                    } else if now - lastAdvance > stallLimit {
                        return .stalled
                    }
                }
            }
            while let outcome = try await group.next() {
                group.cancelAll()
                switch outcome {
                case .finished(let result):
                    return result
                case .stalled:
                    throw TransferStalled(name: name)
                }
            }
            throw CancellationError()
        }
    }

    private enum WatchedTransferOutcome: Sendable {
        case finished(ProcessResult)
        case stalled
    }

    /// Size of a remote regular file (following links). Throws a readable
    /// error for folders, FIFOs, sockets and devices — scp would block on a
    /// FIFO until killed — and for paths that do not exist.
    private func remoteRegularFileSize(settings: ConnectionSettings, path: String) async throws -> Int64? {
        let result = try await runShell("stat -L -c '%s %F' -- \(Self.shellQuote(path))", settings: settings, seconds: 20)
        guard result.exitCode == 0 else {
            if Self.isTimeout(result) {
                throw MonitorError.processFailed("Checking \(path) timed out on \(settings.clusterName).")
            }
            throw Self.failure("Could not find \(path)", result)
        }
        let line = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let type = parts.count > 1 ? parts[1] : ""
        if type == "directory" {
            throw MonitorError.processFailed("\(path) is a folder — compress it on the cluster first to download it.")
        }
        if !type.isEmpty, !type.contains("regular") {
            throw MonitorError.processFailed("\(path) is not a regular file (\(type)), so it cannot be downloaded.")
        }
        return parts.first.flatMap { Int64($0) }
    }

    /// Size of a remote file for upload progress: 0 when it does not exist
    /// yet, nil when the probe itself failed.
    private func remoteFileSize(settings: ConnectionSettings, path: String) async -> Int64? {
        let script = "if [ -e \"$1\" ]; then stat -c %s -- \"$1\"; else echo 0; fi"
        guard let result = try? await runShell(
            "sh -c \(Self.shellQuote(script)) sh \(Self.shellQuote(path))",
            settings: settings,
            seconds: 10
        ), result.exitCode == 0 else {
            return nil
        }
        return Int64(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func localFileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Fire-and-forget remote command for quit time, when nothing can be
    /// awaited: the shared `SSHMuxOptions` (never prompt, never become a
    /// master, this cluster's socket only), but the app does not wait for
    /// it. The ssh child outlives the app and exits on its own.
    static func launchDetachedCleanup(settings: ConnectionSettings, command: String) {
        try? detachedCleanupProcess(settings: settings, command: command).run()
    }

    /// The quit-time cleanup's ssh, configured but not started. Like every
    /// child, it gets `MonitorService.childEnvironment()`, so a password
    /// exported for the old command-line helpers never reaches it.
    static func detachedCleanupProcess(settings: ConnectionSettings, command: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = SSHMuxOptions.sshArguments(settings: settings)
            + [settings.hostname, bounded(command, seconds: 20)]
        process.environment = MonitorService.childEnvironment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    // MARK: Trash management

    /// Every trash run of this cluster. `storageRoots` lets the login node
    /// tell a run on a filesystem that is not mounted there ("unavailable")
    /// from one whose folder was renamed ("missing"). `forgetting` names
    /// index entries of missing runs (`TrashRun.Reachability.missing`) to
    /// remove first; the script drops one only if its run is still missing
    /// at that moment.
    func listTrash(
        settings: ConnectionSettings,
        storageRoots: [String] = [],
        forgetting pointers: [String] = []
    ) async throws -> [TrashRun] {
        var arguments = [
            "--cluster", settings.clusterID.rawValue,
            "--trash-name", Self.trashDirectoryName,
            "--item-cap", "300"
        ]
        let roots = storageRoots.filter { $0.hasPrefix("/") }
        if !roots.isEmpty {
            arguments += ["--roots"] + roots
        }
        if !pointers.isEmpty {
            arguments += ["--forget"] + pointers
        }
        let result = try await runScript(RemoteFileScripts.trashList, arguments: arguments, settings: settings, seconds: 40)
        let payload = try Self.decode(TrashListPayload.self, from: result, operation: "Listing the trash", settings: settings)
        return payload.runs
            .map { run in
                let parent = ((run.directory as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
                let reachability: TrashRun.Reachability
                switch run.state {
                case "missing":
                    // Without its index entry's name the user could not
                    // forget it; it is still listed as unreachable.
                    reachability = run.pointer.map { .missing(pointer: $0) } ?? .unavailable
                case "unavailable":
                    reachability = .unavailable
                default:
                    reachability = .reachable
                }
                return TrashRun(
                    directory: run.directory,
                    location: run.location == "home" ? .home : .beside(parent: parent),
                    clusterID: run.cluster,
                    createdAt: Self.parseTrashDate(created: run.created, directory: run.directory)
                        ?? run.modified.map { Date(timeIntervalSince1970: $0) },
                    itemCount: run.count,
                    items: run.entries.map { entry in
                        TrashRun.Item(
                            name: entry.name,
                            path: Self.joinPath(run.directory, entry.name),
                            isDirectory: entry.isDir,
                            originalPath: entry.original,
                            nameIsLossy: entry.lossy ?? false
                        )
                    },
                    hasManifest: run.hasManifest ?? false,
                    error: run.error,
                    reachability: reachability
                )
            }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    /// Bytes per trash run folder, from one bounded `du -sk`.
    func trashSizes(settings: ConnectionSettings, directories: [String]) async throws -> [String: Int64] {
        guard !directories.isEmpty else {
            return [:]
        }
        let quoted = directories.map(Self.shellQuote).joined(separator: " ")
        let result = try await runShell("du -sk -- \(quoted)", settings: settings, seconds: 60)
        let totals = Self.parseDiskUsageKiB(result.stdout)
        if totals.isEmpty, Self.isTimeout(result) {
            throw MonitorError.processFailed("Measuring the trash timed out on \(settings.clusterName) — it may be very large.")
        }
        return totals
    }

    func restore(settings: ConnectionSettings, run: TrashRun, items: [TrashRun.Item]) async throws -> RestoreOutcome {
        let pairs = items.compactMap { item -> [String]? in
            guard let original = item.originalPath, !item.nameIsLossy else {
                return nil
            }
            return [item.path, original]
        }
        guard !pairs.isEmpty else {
            throw MonitorError.processFailed("Nothing to restore: these items have no recorded original location.")
        }
        let arguments = ["--run", run.directory, "--trash-name", Self.trashDirectoryName, "--pairs"] + pairs.flatMap { $0 }
        let result = try await runScript(RemoteFileScripts.trashRestore, arguments: arguments, settings: settings, seconds: 60)
        let objects = Self.jsonObjects(result.stdout)
        if let error = objects.first(where: { $0["error"] != nil && $0["failed"] == nil })?["error"] as? String {
            throw MonitorError.processFailed(error)
        }
        var outcome = RestoreOutcome()
        var finished = false
        for object in objects {
            if let source = object["restored"] as? String {
                outcome.restored.append(source)
            } else if let source = object["failed"] as? String {
                outcome.failed.append(TrashOutcome.Failure(path: source, reason: object["error"] as? String ?? "unknown error"))
            } else if object["done"] as? Bool == true {
                finished = true
                outcome.removedRun = object["removed_run"] as? Bool ?? false
            }
        }
        if !finished, outcome.restored.isEmpty, outcome.failed.isEmpty {
            throw Self.failure("Could not restore from \(run.directory)", result)
        }
        return outcome
    }

    // MARK: Helpers

    private func expandTilde(_ path: String, settings: ConnectionSettings) async throws -> String {
        let home = try await homeDirectory(settings: settings)
        return Self.expandLeadingTilde(path, home: Self.trimTrailingSlashes(home))
    }
}

// MARK: - Wire payloads

private struct RemoteErrorPayload: Decodable {
    let error: String
}

private struct RootsPayload: Decodable {
    let home: String
    let roots: [String]
}

/// JSON bridge for the remote listing protocol. Directory contents are
/// NEVER parsed from `ls` output.
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
        let lossy: Bool?

        enum CodingKeys: String, CodingKey {
            case name, kind, size, mtime, owner, mode, link, lossy
            case linkIsDir = "link_is_dir"
        }
    }

    let requested: String
    let resolved: String
    let truncated: Bool
    let total: Int?
    let matched: Int?
    let filter: String?
    let entries: [Entry]
}

struct PreviewPayload: Decodable {
    let mime: String?
    let charset: String?
    let hasFile: Bool
    let size: Int64
    let truncated: Bool
    let fromEnd: Bool
    let data: String

    enum CodingKeys: String, CodingKey {
        case mime, charset, size, truncated, data
        case hasFile = "has_file"
        case fromEnd = "from_end"
    }

    init(mime: String?, charset: String?, hasFile: Bool, size: Int64, truncated: Bool, fromEnd: Bool, data: String) {
        self.mime = mime
        self.charset = charset
        self.hasFile = hasFile
        self.size = size
        self.truncated = truncated
        self.fromEnd = fromEnd
        self.data = data
    }
}

private struct RefusalPayload: Decodable {
    let path: String
    let reason: String
}

private struct TrashInspectPayload: Decodable {
    struct Target: Decodable {
        let path: String
        let device: String?
        let error: String?
        let parent: String
        let parentWritable: Bool

        enum CodingKeys: String, CodingKey {
            case path, device, error, parent
            case parentWritable = "parent_writable"
        }
    }

    struct Mount: Decodable {
        let parent: String
        let directory: String
        let createdBase: Bool?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case parent, directory, error
            case createdBase = "created_base"
        }
    }

    let home: String
    let homeDevice: String?
    let refused: [RefusalPayload]?
    let targets: [Target]?
    let mountTrash: [Mount]?

    enum CodingKeys: String, CodingKey {
        case home, refused, targets
        case homeDevice = "home_device"
        case mountTrash = "mount_trash"
    }
}

private struct JobStartPayload: Decodable {
    let job: String?
    let pid: Int32?
    let refused: [RefusalPayload]?
}

private struct JobPollPayload: Decodable {
    struct Status: Decodable {
        struct Failure: Decodable {
            let path: String
            let error: String
        }

        let total: Int?
        let done: Int?
        let failed: [Failure]?
        let moved: [String]?
        let current: String?
        let cancelled: Bool?
    }

    let state: String
    let status: Status?
    let detail: String?
}

private struct TrashListPayload: Decodable {
    struct Run: Decodable {
        struct Entry: Decodable {
            let name: String
            let isDir: Bool
            let original: String?
            let lossy: Bool?

            enum CodingKeys: String, CodingKey {
                case name, original, lossy
                case isDir = "is_dir"
            }
        }

        let directory: String
        let location: String
        let cluster: String?
        let created: String?
        let modified: Double?
        let hasManifest: Bool?
        let count: Int
        let entries: [Entry]
        let error: String?
        /// "present" (or absent), "missing" or "unavailable".
        let state: String?
        /// Index entry name, sent only for a missing run.
        let pointer: String?

        enum CodingKeys: String, CodingKey {
            case directory, location, cluster, created, modified, count, entries, error, state, pointer
            case hasManifest = "has_manifest"
        }
    }

    let runs: [Run]
}
