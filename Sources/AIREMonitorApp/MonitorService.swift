import HPCCore
import CryptoKit
import Foundation
import Darwin

/// Everything needed to reach one cluster over SSH. Built by `ClusterSession`
/// from the shared sign-in configuration plus the cluster's own profile.
struct ConnectionSettings: Sendable, Equatable {
    let clusterID: ClusterID
    let clusterName: String
    var username: String
    /// Login host of this cluster, e.g. calder.leeds.ac.uk.
    var hostname: String
    var route: ConnectionRoute
    var jumpHostname: String
    var duoOption: String
    var projectRoot: String
    var storage: [StorageVolumeSpec]

    var useJumpHost: Bool { route == .rashJump }

    /// Per-cluster runtime directory: snapshot cache, history, login logs,
    /// the master's pid file. Nothing in it is shared between clusters.
    var runtimeDirectory: String {
        "\(projectRoot)/.runtime/clusters/\(clusterID.rawValue)"
    }

    // Unix domain socket paths are limited to 104 bytes on macOS, and ssh
    // appends a ~18-char random suffix while establishing a master. Sockets
    // therefore live in a short home-anchored directory with hashed names,
    // independent of how deeply the project itself is nested.
    var controlDirectory: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/ctl")
    }

    /// The cluster's own ControlMaster. The key format predates multi-cluster
    /// support and is kept byte-for-byte, so an AIRE master started by an
    /// older build (aire-<hash>.sock) is still found after an upgrade.
    var controlPath: String {
        let routeKey = useJumpHost ? "via-\(jumpHostname)" : "direct"
        return shortControlPath(prefix: clusterID.rawValue, key: "\(username)@\(hostname):\(routeKey)")
    }

    /// The rash jump master. Deliberately independent of the cluster: every
    /// cluster on the rash route tunnels through the same authenticated
    /// jump session, so rash costs one Duo approval in total, not one per
    /// cluster.
    var jumpControlPath: String {
        guard useJumpHost else {
            return ""
        }
        return shortControlPath(prefix: "jump", key: "\(username)@\(jumpHostname)")
    }

    private func shortControlPath(prefix: String, key: String) -> String {
        let digest = SHA256.hash(data: Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        let hash = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(controlDirectory)/\(prefix)-\(hash).sock"
    }
}

struct ProcessResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum MonitorError: LocalizedError {
    case missingFile(String)
    case processFailed(String)
    /// A login helper exited 13: the server rejected the password.
    case passwordRejected(String)
    /// A login helper exited 14: the server demanded a password change.
    case passwordExpired(String)
    /// The shared rash jump leg failed for another reason. Every other
    /// queued cluster would retry the same rash authentication, so the
    /// coordinator stops the queue.
    case jumpHostFailed(String)
    /// A login helper hit the caller's watchdog: nobody answered the Duo
    /// push in time (or the network stalled). The coordinator stops the
    /// queue rather than pushing the next cluster at an absent user.
    case loginTimedOut(String)
    /// A login helper exited 15 (either leg): the password was ACCEPTED,
    /// then the one Duo push was declined, timed out on the phone, or the
    /// connection dropped while waiting. Nothing is wrong with the saved
    /// password, so it must never be flagged as rejected; the coordinator
    /// still stops the queue, since the next push would go unanswered too.
    case duoNotApproved(String)
    /// The target starter exited 5 on a plain sign-in: a master answers on
    /// the cluster's socket but did not run the check command in time. It
    /// was left running — it may be slow rather than dead, and still carry
    /// terminals — so only the confirmed Reconnect may replace it. No
    /// password was sent.
    case existingSessionUnresponsive(String)
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let path):
            return "Missing file: \(path)"
        case .processFailed(let message), .passwordRejected(let message),
             .passwordExpired(let message), .jumpHostFailed(let message),
             .loginTimedOut(let message), .duoNotApproved(let message),
             .existingSessionUnresponsive(let message):
            return message
        case .invalidJSON(let message):
            return "Could not parse snapshot JSON: \(message)"
        }
    }
}

/// Accumulates raw pipe output and optionally emits each complete stdout line
/// as it arrives. Reader threads append concurrently, so all state is guarded.
private final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var pendingLine = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)? = nil) {
        self.onLine = onLine
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else {
            return
        }
        var completedLines: [String] = []
        lock.lock()
        buffer.append(chunk)
        if onLine != nil {
            pendingLine.append(chunk)
            while let newlineIndex = pendingLine.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = pendingLine.subdata(in: pendingLine.startIndex..<newlineIndex)
                pendingLine.removeSubrange(pendingLine.startIndex...newlineIndex)
                if var line = String(data: lineData, encoding: .utf8) {
                    if line.hasSuffix("\r") {
                        line.removeLast()
                    }
                    completedLines.append(line)
                }
            }
        }
        lock.unlock()
        if let onLine {
            for line in completedLines {
                onLine(line)
            }
        }
    }

    func finish() {
        var trailing: String?
        lock.lock()
        if onLine != nil, !pendingLine.isEmpty {
            trailing = String(data: pendingLine, encoding: .utf8)
        }
        pendingLine.removeAll()
        lock.unlock()
        if let onLine,
           let trailing,
           !trailing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onLine(trailing)
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        // Lossy decode: a strict decode returns nil for the WHOLE buffer when
        // any byte sequence is invalid (e.g. `head -c` truncating mid-codepoint
        // or latin-1 bytes in a remote log), silently blanking real output.
        // Invalid bytes become U+FFFD instead; valid UTF-8 is unchanged.
        return String(decoding: buffer, as: UTF8.self)
    }
}

/// Holds the child pid so the timeout watchdog and Task cancellation can signal
/// it without capturing the (non-Sendable) Process object. Signals target the
/// process group first (best effort) and fall back to the direct pid.
private final class ProcessSignalState: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = -1
    private var cancelled = false
    private var timedOutFlag = false
    private var exited = false
    private var watchdogs: [DispatchWorkItem] = []

    func registerRunning(_ pid: pid_t) {
        lock.lock()
        self.pid = pid
        let shouldSignal = cancelled
        lock.unlock()
        if shouldSignal {
            signalTree(SIGTERM)
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        signalTree(SIGTERM)
    }

    /// Tracks a timeout watchdog so markExited() can cancel it once the child
    /// is reaped. Returns false when the child has already exited, in which
    /// case the item must not be scheduled.
    func registerWatchdog(_ item: DispatchWorkItem) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !exited else {
            return false
        }
        watchdogs.append(item)
        return true
    }

    /// Called from the termination handler at reap time: cancels any pending
    /// watchdog (and SIGKILL follow-up) so a finished run cannot be
    /// misreported as timed out and a recycled pid cannot be signalled.
    func markExited() {
        lock.lock()
        exited = true
        let pending = watchdogs
        watchdogs.removeAll()
        lock.unlock()
        for item in pending {
            item.cancel()
        }
    }

    /// Records the timeout unless the child has already been reaped. Returns
    /// whether it took effect so the watchdog can skip signalling a process
    /// tree that no longer exists.
    func markTimedOut() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !exited else {
            return false
        }
        timedOutFlag = true
        return true
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOutFlag
    }

    var isChildAlive: Bool {
        lock.lock()
        let current = pid
        lock.unlock()
        guard current > 0 else {
            return false
        }
        return Darwin.kill(current, 0) == 0
    }

    func signalTree(_ signal: Int32) {
        lock.lock()
        let current = pid
        lock.unlock()
        guard current > 0 else {
            return
        }
        if Darwin.kill(-current, signal) != 0 {
            _ = Darwin.kill(current, signal)
        }
    }
}

/// What `MonitorService.stopMaster` did, read from the stop helper's
/// `HPC-STATUS:` lines.
struct StopMasterReport: Sendable, Equatable {
    /// e.g. "stopped the AIRE session", "no Calder session was running",
    /// "kept the shared jump-host session (rash.leeds.ac.uk): another
    /// connection still uses it".
    var statusLines: [String] = []

    /// HPC_STOP_JUMP_IF_UNUSED was asked for, but another tunnel, sign-in
    /// or collector still rides the shared jump master, so the helper kept
    /// it. Expected whenever another cluster is live on the rash route: an
    /// ordinary outcome, never an error.
    var keptSharedJumpSession: Bool {
        statusLines.contains { $0.hasPrefix("kept the shared jump-host session") }
    }

    var stoppedSharedJumpSession: Bool {
        statusLines.contains { $0.hasPrefix("stopped the shared jump-host session") }
    }
}

/// What a successful `MonitorService.login` did.
struct LoginResult: Sendable, Equatable {
    /// Both legs' stdout (HPC-STATUS lines and the `auth_ok|…` line).
    var output: String
    /// A server checked the password during this sign-in and accepted it:
    /// at least one leg authenticated afresh. False when every leg reused
    /// a master that was already up (the starter's "reusing the existing
    /// <cluster> session", the expect helper's "reusing the shared
    /// jump-host session"): then the password was never sent anywhere, and
    /// a typed one must not be saved, nor clear a "rejected" flag, as if it
    /// had worked.
    var passwordVerified: Bool
}

/// What the reuse-only starter run (`HPC_REUSE_ONLY=1`) found. See
/// `MonitorService.adoptMaster(settings:)`.
enum MasterAdoption: Sendable, Equatable {
    /// A healthy master was there; anything an older release left next to
    /// it (keepalive, permanent remote `sleep` session) has been ended.
    case adopted
    /// Exit 4: no healthy master on this path, so nothing to adopt.
    case nothingToAdopt
    /// The helper is missing, timed out or failed. Logged only: adoption is
    /// housekeeping, and the session works either way.
    case unavailable(String)
}

struct MonitorService: Sendable {
    static let statusLinePrefix = "HPC-STATUS: "

    static let loginHelperScript = "scripts/hpc_ssh_login.expect"
    static let targetStarterScript = "scripts/hpc_start_target_master.zsh"
    static let collectorScript = "scripts/hpc_snapshot.py"
    static let stopMasterScript = "scripts/hpc_stop_master.zsh"
    /// Exit code `runProcess` reports when its watchdog killed the child
    /// (the same convention as coreutils `timeout`).
    static let processTimedOutExitCode: Int32 = 124

    /// The environment for every child process (login helpers, collector,
    /// remote commands, transfers, terminals): the app's own, minus any
    /// password a user may have exported for the old command-line helpers.
    /// The helpers read the password from stdin; an inherited HPC_PASSWORD
    /// would otherwise reach every ssh and every terminal's shell.
    static func childEnvironment() -> [String: String] {
        childEnvironment(from: ProcessInfo.processInfo.environment)
    }

    /// `environment` minus the password variables (testable form).
    static func childEnvironment(from environment: [String: String]) -> [String: String] {
        var environment = environment
        for name in passwordEnvironmentNames {
            environment.removeValue(forKey: name)
        }
        return environment
    }

    /// Every name a password was ever exported under, current and legacy.
    static let passwordEnvironmentNames = ["HPC_PASSWORD", "HPC_ASKPASS_PASSWORD", "AIRE_PASSWORD", "AIRE_ASKPASS_PASSWORD"]

    /// The environment both login helpers (and the reuse-only adoption run)
    /// share: the scrubbed app environment plus this identity. Mode flags an
    /// old shell might have exported (HPC_FORCE_RELOGIN, HPC_REUSE_ONLY) are
    /// always set explicitly by the callers, never inherited.
    private func helperEnvironment(settings: ConnectionSettings) -> [String: String] {
        var environment = Self.childEnvironment()
        environment["HPC_PROJECT_ROOT"] = settings.projectRoot
        environment["HPC_RUNTIME_DIR"] = settings.runtimeDirectory
        environment["HPC_TARGET_LABEL"] = settings.clusterName
        environment["HPC_USERNAME"] = settings.username
        environment["HPC_HOSTNAME"] = settings.hostname
        environment["HPC_USE_JUMP_HOST"] = settings.useJumpHost ? "1" : "0"
        environment["HPC_JUMP_HOSTNAME"] = settings.jumpHostname
        environment["HPC_DUO_OPTION"] = settings.duoOption
        environment["HPC_CONTROL_PATH"] = settings.controlPath
        environment.removeValue(forKey: "HPC_JUMP_CONTROL_PATH")
        if !settings.jumpControlPath.isEmpty {
            environment["HPC_JUMP_CONTROL_PATH"] = settings.jumpControlPath
        }
        environment["HPC_FORCE_RELOGIN"] = "0"
        environment["HPC_REUSE_ONLY"] = "0"
        environment["HPC_LOGIN_DEBUG_LOG"] = "\(settings.runtimeDirectory)/login_debug.log"
        // Per-prompt expect timeout; the watchdogs below derive from it.
        environment["HPC_TIMEOUT"] = String(HPCDefaults.loginPromptTimeout)
        return environment
    }

    /// Authenticates one cluster: on the rash route the expect helper first
    /// makes sure the shared jump master is up (reusing a healthy one, so
    /// logging into a second cluster never tears down the first), then the
    /// target starter brings up this cluster's own ControlMaster. The
    /// password travels only as the first line of each helper's stdin.
    ///
    /// By default the starter reuses a healthy master: no teardown, no Duo
    /// push, the terminals riding on it survive; one that answers its
    /// socket but not a command is left running too (exit 5,
    /// `existingSessionUnresponsive`). `forceReplace` (the confirmed
    /// Reconnect only) sets HPC_FORCE_RELOGIN=1, which tears the existing
    /// master down and authenticates afresh.
    ///
    /// The result says whether any leg actually had the password checked
    /// (`LoginResult.passwordVerified`): a sign-in that only reused masters
    /// succeeds without ever sending it.
    func login(
        settings: ConnectionSettings,
        password: String,
        forceReplace: Bool = false,
        onStatus: (@Sendable (String) -> Void)? = nil
    ) async throws -> LoginResult {
        try requireFile("\(settings.projectRoot)/\(Self.targetStarterScript)")
        try prepareRuntime(settings: settings)

        var environment = helperEnvironment(settings: settings)
        environment["HPC_FORCE_RELOGIN"] = forceReplace ? "1" : "0"

        var statusLineHandler: (@Sendable (String) -> Void)?
        if let onStatus {
            statusLineHandler = { line in
                guard line.hasPrefix(Self.statusLinePrefix) else {
                    return
                }
                let message = String(line.dropFirst(Self.statusLinePrefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !message.isEmpty {
                    onStatus(message)
                }
            }
        }

        var transcript = ProcessResult(stdout: "", stderr: "", exitCode: 0)
        var jumpLegOutput: String?
        if settings.useJumpHost {
            let helper = "\(settings.projectRoot)/\(Self.loginHelperScript)"
            try requireFile(helper)
            var jumpEnvironment = environment
            // The expect helper only owns the jump leg; the target master is
            // started by the zsh starter below for both routes.
            jumpEnvironment["HPC_SKIP_TARGET"] = "1"
            let helperResult = try await runProcess(
                executable: "/usr/bin/expect",
                arguments: [helper],
                currentDirectory: settings.projectRoot,
                environment: jumpEnvironment,
                stdin: password + "\n",
                timeout: HPCDefaults.loginWatchdog,
                onOutputLine: statusLineHandler
            )
            transcript = helperResult
            jumpLegOutput = helperResult.stdout
            if helperResult.exitCode != 0 {
                let message = helperResult.stderr.isEmpty ? helperResult.stdout : helperResult.stderr
                recordLoginDebug(settings: settings, result: helperResult)
                // This helper only handles the shared jump leg, so its
                // failures (including a rejected password) belong to rash,
                // not to the cluster being signed in to.
                throw Self.loginError(
                    message,
                    exitCode: helperResult.exitCode,
                    clusterName: "\(settings.jumpHostname) (jump host)",
                    isJumpLeg: true
                )
            }
        }

        let targetStarter = "\(settings.projectRoot)/\(Self.targetStarterScript)"
        try requireFile(targetStarter)
        // The password is handed to the starter as the first line of stdin
        // (read via `read -rs`); it must never appear in any child environment
        // or argv.
        let targetResult = try await runProcess(
            executable: "/bin/zsh",
            arguments: [targetStarter],
            currentDirectory: settings.projectRoot,
            environment: environment,
            stdin: password + "\n",
            timeout: HPCDefaults.loginWatchdog,
            onOutputLine: statusLineHandler
        )
        let combinedResult = ProcessResult(
            stdout: [transcript.stdout, targetResult.stdout]
                .filter { !$0.isEmpty }
                .joined(separator: "\n"),
            stderr: [transcript.stderr, targetResult.stderr]
                .filter { !$0.isEmpty }
                .joined(separator: "\n"),
            exitCode: targetResult.exitCode
        )
        recordLoginDebug(settings: settings, result: combinedResult)
        if targetResult.exitCode != 0 {
            let message = targetResult.stderr.isEmpty ? targetResult.stdout : targetResult.stderr
            throw Self.loginError(message, exitCode: targetResult.exitCode, clusterName: settings.clusterName)
        }
        return LoginResult(
            output: combinedResult.stdout,
            passwordVerified: Self.passwordWasVerified(
                jumpLegOutput: jumpLegOutput,
                targetLegOutput: targetResult.stdout,
                clusterName: settings.clusterName
            )
        )
    }

    /// Whether a SUCCESSFUL sign-in had the password checked by a server.
    /// Each leg announces the moment it hands the password over — the
    /// starter "password sent (<cluster>)", the expect helper "password
    /// sent (jump host)" — and a leg that then exits 0 got it accepted
    /// (both legs fail with 13 when it is not). A leg that reused its
    /// master prints "reusing …" instead and never sends it. Positive
    /// evidence on purpose: if a line ever went missing, the cost is a
    /// typed password not being saved, never an unchecked one being saved
    /// over a good one.
    static func passwordWasVerified(jumpLegOutput: String?, targetLegOutput: String, clusterName: String) -> Bool {
        if statusLines(in: targetLegOutput).contains("password sent (\(clusterName))") {
            return true
        }
        guard let jumpLegOutput else {
            return false
        }
        return statusLines(in: jumpLegOutput).contains("password sent (jump host)")
    }

    /// Exit status of the target starter when a plain sign-in finds a
    /// master that answers on its socket but did not run the check command
    /// within 15 s. It is left running; see `existingSessionUnresponsive`.
    static let existingSessionUnresponsiveExitCode: Int32 = 5

    /// Maps a helper's exit code to the error the session classifies by.
    static func loginError(
        _ message: String,
        exitCode: Int32,
        clusterName: String,
        isJumpLeg: Bool = false
    ) -> MonitorError {
        if exitCode == existingSessionUnresponsiveExitCode, !isJumpLeg {
            return .existingSessionUnresponsive(
                existingSessionUnresponsiveExplanation(message, clusterName: clusterName)
            )
        }
        let explanation = explainSSHFailure(message, exitCode: exitCode, clusterName: clusterName)
        switch exitCode {
        case 13:
            return .passwordRejected(explanation)
        case 14:
            return .passwordExpired(explanation)
        case 15:
            // Both legs: on the jump leg `clusterName` already reads
            // "<jump host> (jump host)", so the message names the right host.
            return .duoNotApproved(explanation)
        case processTimedOutExitCode:
            return .loginTimedOut(explanation)
        default:
            return isJumpLeg ? .jumpHostFailed(explanation) : .processFailed(explanation)
        }
    }

    /// The message for the starter's exit 5. Kept out of
    /// `explainSSHFailure`, which also explains collector and `scancel`
    /// failures: a remote command exiting 5 means nothing of the sort.
    /// Says what was (not) done — nothing closed, no password sent — and
    /// the two ways on: the confirmed Reconnect, or waiting for a dead
    /// connection to close itself.
    static func existingSessionUnresponsiveExplanation(_ rawMessage: String, clusterName: String) -> String {
        let prefix = """
        The existing \(clusterName) session did not answer in time, so it was left running.

        It still answers on this Mac, but a quick check command through it did not come back within 15 seconds: the login node may be slow, or the connection may have died. Nothing on it was closed and no password was sent. Choose Reconnect… to replace it now (one Duo push; terminals open there close), or wait: a dead connection closes by itself within about five minutes, and Connect then signs in normally.
        """
        let raw = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? prefix : "\(prefix)\n\nRaw SSH output:\n\(raw)"
    }

    /// Exit status of the starter's reuse-only mode when no healthy master
    /// exists on the path.
    static let nothingToAdoptExitCode: Int32 = 4

    /// Adopts a ControlMaster the app found alive but did not start (one
    /// from the previous run, the command line, or an older release): runs
    /// the target starter once in reuse-only mode (HPC_REUSE_ONLY=1) with
    /// an EMPTY stdin and no password anywhere. The starter verifies the
    /// master, ends what older releases left beside it — the 5 s keepalive
    /// and the permanent remote `sleep` session that kept ControlPersist
    /// from ever expiring — and exits 0, or exits 4 when nothing healthy is
    /// there. Reuse-only never tears down, never prompts and never pushes
    /// Duo. Bounded: the starter's own health check is capped at 15 s.
    func adoptMaster(settings: ConnectionSettings) async -> MasterAdoption {
        let starter = "\(settings.projectRoot)/\(Self.targetStarterScript)"
        guard FileManager.default.fileExists(atPath: starter) else {
            return .unavailable("\(Self.targetStarterScript) is missing")
        }
        var environment = helperEnvironment(settings: settings)
        environment["HPC_REUSE_ONLY"] = "1"
        environment["HPC_FORCE_RELOGIN"] = "0"
        do {
            let result = try await runProcess(
                executable: "/bin/zsh",
                arguments: [starter],
                currentDirectory: settings.projectRoot,
                environment: environment,
                // Closed at once: the starter reads EOF, so there is
                // nothing it could ever send as a password.
                stdin: "",
                timeout: 40
            )
            switch result.exitCode {
            case 0:
                return .adopted
            case Self.nothingToAdoptExitCode:
                return .nothingToAdopt
            default:
                let detail = (result.stderr.isEmpty ? result.stdout : result.stderr)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .unavailable("exit \(result.exitCode)" + (detail.isEmpty ? "" : ": \(detail)"))
            }
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    /// The flag that makes the collector leave out the storage section
    /// (df, quota, lfs). The app passes it on most refreshes; it is never
    /// part of `collectorArguments`, which collector.json hands to the
    /// widget verbatim — the widget would otherwise never collect storage.
    static let skipStorageFlag = "--skip-storage"

    func collectSnapshot(settings: ConnectionSettings, skipStorage: Bool = false) async throws -> ClusterSnapshot {
        // Check the script first: the project root is a free-text field, and
        // creating runtime directories under a half-typed path would litter
        // the disk (and turn "missing file" into a confusing mkdir error).
        let script = "\(settings.projectRoot)/\(Self.collectorScript)"
        try requireFile(script)
        try prepareRuntime(settings: settings)

        let result = try await runProcess(
            executable: "/usr/bin/python3",
            arguments: [script] + Self.collectorArguments(settings: settings, skipStorage: skipStorage),
            currentDirectory: settings.projectRoot,
            environment: Self.childEnvironment(),
            stdin: nil,
            // Always above the collector's own --timeout budget, so a
            // healthy (if slow) collection is never killed.
            timeout: HPCDefaults.collectorWatchdog
        )

        if result.exitCode == Self.processTimedOutExitCode,
           result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The watchdog, not ssh: explainSSHFailure's timeout wording is
            // about signing in, which this is not.
            throw MonitorError.processFailed(
                "Collecting the \(settings.clusterName) snapshot took longer than \(Int(HPCDefaults.collectorWatchdog)) s and was stopped. The login node or a filesystem may be slow; the app keeps retrying."
                    + (result.stderr.isEmpty ? "" : "\n\n\(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            )
        }

        guard !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let detail = result.stderr.isEmpty
                ? "snapshot script produced no output"
                : Self.explainSSHFailure(result.stderr, exitCode: result.exitCode, clusterName: settings.clusterName)
            throw MonitorError.invalidJSON(detail)
        }
        let data = Data(result.stdout.utf8)

        do {
            let snapshot = try JSONDecoder().decode(ClusterSnapshot.self, from: data)
            if result.exitCode != 0 && snapshot.errors.isEmpty {
                let message = result.stderr.isEmpty ? result.stdout : result.stderr
                throw MonitorError.processFailed(
                    Self.explainSSHFailure(message, exitCode: result.exitCode, clusterName: settings.clusterName)
                )
            }
            return snapshot
        } catch let error as MonitorError {
            throw error
        } catch {
            let detail = result.stderr.isEmpty ? error.localizedDescription : result.stderr
            throw MonitorError.invalidJSON(Self.explainSSHFailure(detail, clusterName: settings.clusterName))
        }
    }

    /// One-shot remote command over the cluster's ControlMaster. Never
    /// touches a password: BatchMode suppresses every prompt. A dead master
    /// does NOT fail fast on its own — OpenSSH silently falls back to a
    /// direct, un-jumped connection — so the master is pre-flighted with
    /// `ssh -O check` and a readable error is thrown instead.
    func runRemoteCommand(
        settings: ConnectionSettings,
        command: String,
        timeout: TimeInterval = 30
    ) async throws -> ProcessResult {
        try await requireLiveMaster(settings: settings)
        return try await runProcess(
            executable: "/usr/bin/ssh",
            arguments: Self.remoteCommandArguments(settings: settings, command: command),
            currentDirectory: settings.projectRoot,
            environment: Self.childEnvironment(),
            stdin: nil,
            timeout: timeout
        )
    }

    /// The ssh argv for `runRemoteCommand`. The client options come from
    /// SSHMuxOptions, the one place that encodes "never prompt, never
    /// become a master, fail fast" for every client riding a master (the
    /// terminal and scp use the same helper).
    static func remoteCommandArguments(settings: ConnectionSettings, command: String) -> [String] {
        SSHMuxOptions.sshArguments(settings: settings) + [settings.hostname, command]
    }

    /// File-transfer entry point for `RemoteFileService`: executes
    /// `/usr/bin/scp` with pre-built arguments — no shell is ever involved,
    /// so argv elements need no quoting. The ControlMaster is pre-flighted
    /// exactly like `runRemoteCommand`, so a dead session throws a readable
    /// error instantly instead of scp silently dialing the host directly
    /// (bypassing the jump host) and hanging.
    func runTransfer(
        settings: ConnectionSettings,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        try await requireLiveMaster(settings: settings)
        return try await runProcess(
            executable: "/usr/bin/scp",
            arguments: arguments,
            currentDirectory: settings.projectRoot,
            environment: Self.childEnvironment(),
            stdin: nil,
            timeout: timeout
        )
    }

    /// Verifies the cluster's ControlMaster with `ssh -O check`, which fails
    /// in milliseconds for both a missing and a dead socket. Without this, a
    /// dead master makes ssh silently dial the host directly (bypassing the
    /// jump host) and the eventual timeout surfaces as a misleading
    /// login/Duo-flavored error.
    func requireLiveMaster(settings: ConnectionSettings) async throws {
        let check = try await runProcess(
            executable: "/usr/bin/ssh",
            arguments: ["-S", settings.controlPath, "-O", "check", settings.hostname],
            currentDirectory: settings.projectRoot,
            environment: Self.childEnvironment(),
            stdin: nil,
            timeout: 5
        )
        guard check.exitCode == 0 else {
            throw MonitorError.processFailed(
                "\(settings.clusterName) SSH session expired — use Connect to sign in to \(settings.clusterName) again."
            )
        }
    }

    /// True when `ssh -O check` finds a usable master for this identity.
    func isMasterAlive(settings: ConnectionSettings) async -> Bool {
        do {
            try await requireLiveMaster(settings: settings)
            return true
        } catch {
            return false
        }
    }

    /// Closes one identity's ControlMaster: the master the starter recorded
    /// for this control path (and any keepalive an older release left
    /// beside it), nothing else — never another cluster's master. Used when
    /// the identity a session was signed in under stops being the one in
    /// use (route, username or host change) and for an explicit Disconnect.
    ///
    /// Runs scripts/hpc_stop_master.zsh (contract 2), which also kills the
    /// verified master pids and removes their pid files; exit 0 means
    /// stopped or nothing was running. The shared rash jump master is left
    /// alone unless `stopJumpIfUnused` (HPC_STOP_JUMP_IF_UNUSED=1): then the
    /// helper also closes it, but only when no other tunnel, sign-in or
    /// collector rides on it — otherwise it reports that it kept it.
    ///
    /// If the script is not there (an older checkout), `ssh -O exit` on the
    /// socket still closes the master.
    func stopMaster(settings: ConnectionSettings, stopJumpIfUnused: Bool = false) async throws -> StopMasterReport {
        let script = "\(settings.projectRoot)/\(Self.stopMasterScript)"
        let result: ProcessResult
        if FileManager.default.fileExists(atPath: script) {
            result = try await runProcess(
                executable: "/bin/zsh",
                arguments: [script],
                currentDirectory: settings.projectRoot,
                environment: Self.stopMasterEnvironment(settings: settings, stopJumpIfUnused: stopJumpIfUnused),
                stdin: nil,
                // `-O exit` is capped at 10 s and the verified kill waits
                // about 3 s before SIGKILL; the optional jump-master step
                // has its own 10 s caps.
                timeout: 30
            )
        } else {
            guard FileManager.default.fileExists(atPath: settings.controlPath) else {
                return StopMasterReport()
            }
            result = try await runProcess(
                executable: "/usr/bin/ssh",
                arguments: ["-S", settings.controlPath, "-O", "exit", settings.hostname],
                currentDirectory: settings.projectRoot,
                environment: Self.childEnvironment(),
                stdin: nil,
                timeout: 10
            )
        }
        guard result.exitCode == 0 else {
            let detail = (result.stderr.isEmpty ? result.stdout : result.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw MonitorError.processFailed(
                "Could not close the \(settings.clusterName) SSH session (exit \(result.exitCode))"
                    + (detail.isEmpty ? "." : ": \(detail)")
            )
        }
        return StopMasterReport(statusLines: Self.statusLines(in: result.stdout))
    }

    /// hpc_stop_master.zsh's environment (contract 2). Internal for tests.
    static func stopMasterEnvironment(settings: ConnectionSettings, stopJumpIfUnused: Bool) -> [String: String] {
        var environment = childEnvironment()
        environment["HPC_PROJECT_ROOT"] = settings.projectRoot
        environment["HPC_RUNTIME_DIR"] = settings.runtimeDirectory
        environment["HPC_CONTROL_PATH"] = settings.controlPath
        environment["HPC_HOSTNAME"] = settings.hostname
        environment["HPC_USERNAME"] = settings.username
        environment["HPC_TARGET_LABEL"] = settings.clusterName
        environment["HPC_USE_JUMP_HOST"] = settings.useJumpHost ? "1" : "0"
        environment["HPC_JUMP_HOSTNAME"] = settings.jumpHostname
        environment.removeValue(forKey: "HPC_JUMP_CONTROL_PATH")
        if !settings.jumpControlPath.isEmpty {
            // A guard first: the script refuses to treat the shared jump
            // master as this cluster's. It stops the jump master only on
            // explicit request, below.
            environment["HPC_JUMP_CONTROL_PATH"] = settings.jumpControlPath
        }
        // Never inherited from a shell the app was launched from.
        environment["HPC_STOP_JUMP_IF_UNUSED"] = stopJumpIfUnused && settings.useJumpHost ? "1" : "0"
        return environment
    }

    /// The `HPC-STATUS:` payloads in a helper's stdout, in order.
    static func statusLines(in output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(statusLinePrefix) else {
                return nil
            }
            let message = String(trimmed.dropFirst(statusLinePrefix.count)).trimmingCharacters(in: .whitespaces)
            return message.isEmpty ? nil : message
        }
    }

    /// The collector's argument list (without the script path). Also written,
    /// password-free, to the cluster's runtime directory so the desktop
    /// widget can run the identical collection when the app is not running.
    /// `skipStorage` is for the app's own runs only; collector.json is
    /// always written from the default (storage collected).
    static func collectorArguments(settings: ConnectionSettings, skipStorage: Bool = false) -> [String] {
        var arguments = [
            "--cluster-id", settings.clusterID.rawValue,
            "--cluster-name", settings.clusterName,
            "--username", settings.username,
            "--hostname", settings.hostname,
            "--jump-hostname", settings.jumpHostname,
            settings.useJumpHost ? "--use-jump-host" : "--no-jump-host",
            "--control-path", settings.controlPath,
            "--storage-spec", storageSpecJSON(settings.storage),
            "--timeout", String(HPCDefaults.collectorTimeout)
        ]
        if !settings.jumpControlPath.isEmpty {
            arguments.append(contentsOf: ["--jump-control-path", settings.jumpControlPath])
        }
        if skipStorage {
            arguments.append(skipStorageFlag)
        }
        return arguments
    }

    private static func storageSpecJSON(_ storage: [StorageVolumeSpec]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(storage),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    private func prepareRuntime(settings: ConnectionSettings) throws {
        try FileManager.default.createDirectory(
            atPath: settings.controlDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            atPath: settings.runtimeDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func requireFile(_ path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            throw MonitorError.missingFile(path)
        }
    }

    /// Appends the helpers' transcript (never the password: it only travels
    /// on stdin) to the cluster's login_debug.log; a failure to do so is
    /// logged, never fatal to the sign-in.
    private func recordLoginDebug(settings: ConnectionSettings, result: ProcessResult) {
        do {
            try writeLoginDebug(settings: settings, result: result)
        } catch {
            Log.login.error(
                "\(settings.clusterID.rawValue, privacy: .public): could not write login_debug.log: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func writeLoginDebug(settings: ConnectionSettings, result: ProcessResult) throws {
        try FileManager.default.createDirectory(
            atPath: settings.runtimeDirectory,
            withIntermediateDirectories: true
        )
        let url = URL(fileURLWithPath: settings.runtimeDirectory)
            .appendingPathComponent("login_debug.log")
        let body = """
        ---- \(Date().formatted(date: .numeric, time: .standard)) ----
        exitCode=\(result.exitCode)
        stdout:
        \(result.stdout)
        stderr:
        \(result.stderr)

        """
        let data = Data(body.utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    static func explainSSHFailure(
        _ rawMessage: String,
        exitCode: Int32? = nil,
        clusterName: String = "the cluster"
    ) -> String {
        let raw = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        let prefix: String

        if exitCode == 15 {
            // First: the helpers exit 15 only after the password was
            // accepted and the server asked for Duo. Any wording about a
            // wrong password or a lockout here would send the user to
            // retype a correct password.
            prefix = """
            \(clusterName): the Duo push was declined or timed out. Your password was accepted. Approve the push on your phone and connect again.

            Each sign-in sends one push; nothing else arrives until you connect again.
            """
        } else if exitCode == processTimedOutExitCode {
            // The helpers' own deadline (before Duo) and the app's watchdog
            // both exit 124. Matched on the code, not on whatever partial
            // ssh output preceded it.
            prefix = """
            The \(clusterName) login timed out.

            This usually means the app was waiting for a password, Duo prompt, Duo approval, or SSH banner. Nothing was rejected. Try again and watch for a Duo push notification.
            """
        } else if exitCode == 13 {
            prefix = """
            Password was rejected by \(clusterName) — re-enter it (and check for a pending Duo lockout).

            The server asked for the password a second time, which normally means the password is wrong. Update the saved password and try again; repeated wrong attempts can temporarily lock the account.
            """
        } else if exitCode == 14 {
            prefix = """
            \(clusterName) asked for a password change — the university password has expired.

            Change it through the University's password service, then sign in again with the new password. The app never answers password-change prompts.
            """
        } else if isSessionRefusal(raw) {
            // Checked before the "closed before authentication" markers: a
            // mux refusal is the existing, authenticated master declining
            // one more channel (sshd's MaxSessions, 10 by default, is shared
            // by every terminal, transfer, file listing and the collector),
            // not the server turning the connection away.
            prefix = """
            \(clusterName) refused to open another session on the existing connection.

            Too many terminals or file transfers may be open at once — each one uses one of the connection's limited sessions. Close some and try again. If none are open, the login node itself is refusing new sessions: wait a minute and connect again, and if it persists report the time and the raw output below to Research Computing.
            """
        } else if lower.contains("not allowed at this time")
            || lower.contains("kex_exchange_identification")
            || lower.contains("connection reset by") {
            // Checked before the "UNKNOWN port 65535" tunnel case: through
            // rash OpenSSH has no peer address, so a login node refusing us
            // ALSO reads "... by UNKNOWN port 65535". These markers prove
            // the far end answered, so rash itself was fine.
            prefix = """
            \(clusterName) closed the connection before authentication.

            This is a server-side refusal, not a wrong password. Busy or newly opened login nodes (Calder's round-robin DNS has shown this) sometimes drop new connections — wait a minute and connect again. If it persists, report the time and the raw output below to Research Computing.
            """
        } else if lower.contains("unknown port 65535") {
            // OpenSSH reports a ProxyCommand failure as "UNKNOWN port 65535":
            // the rash tunnel, not the cluster, is what broke.
            prefix = """
            The rash jump tunnel to \(clusterName) failed.

            The jump-host session has probably expired or the network changed. Connect again — the app re-authenticates rash only when its session is no longer healthy. If you are on the University VPN, the "Direct (VPN)" route avoids rash entirely.
            """
        } else if lower.contains("connection closed by") && !lower.contains("permission denied") {
            prefix = """
            \(clusterName) closed the connection before authentication.

            This is a server-side refusal, not a wrong password. Busy or newly opened login nodes (Calder's round-robin DNS has shown this) sometimes drop new connections — wait a minute and connect again. If it persists, report the time and the raw output below to Research Computing.
            """
        } else if lower.contains("connection timed out during banner exchange")
            || lower.contains("operation timed out") {
            prefix = """
            SSH timed out while opening the connection to \(clusterName).

            If you are on the University VPN or campus network, use the "Direct (VPN)" route. If you are off-VPN, use the "Via rash jump host" route. Then check the host names in Advanced, network access, and that your username is valid on both hosts.
            """
        } else if lower.contains("permission denied") {
            prefix = """
            SSH authentication to \(clusterName) was rejected.

            Check the password, Duo approval, and username. If Duo sends a push, approve it before the login timeout expires.
            """
        } else if lower.contains("timed out while waiting") || lower.contains("process timed out") {
            prefix = """
            The \(clusterName) login timed out.

            This usually means the app was waiting for a password, Duo prompt, Duo approval, or SSH banner. Try again and watch for a Duo push notification.
            """
        } else if lower.contains("could not resolve hostname") {
            prefix = """
            SSH could not resolve one of the hostnames.

            Check the \(clusterName) host and, on the rash route, the jump host in Advanced.
            """
        } else if lower.contains("no such file or directory") && lower.contains("ssh-askpass") {
            prefix = """
            SSH attempted to ask for a password outside the app.

            Use Connect in the app first so the helper can handle the password and Duo prompts.
            """
        } else {
            prefix = "SSH command to \(clusterName) failed."
        }

        if raw.isEmpty {
            return prefix
        }
        return "\(prefix)\n\nRaw SSH output:\n\(raw)"
    }

    /// The server-side refusal of a new channel on a healthy master, as
    /// OpenSSH's mux client reports it ("mux_client_request_session: session
    /// request failed: Session open refused by peer", "channel 1: open
    /// failed: administratively prohibited: open failed"). The master is
    /// alive, so this must never count as a lost connection.
    static func isSessionRefusal(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("session open refused")
            || lower.contains("administratively prohibited")
            || lower.contains("session request failed")
            || (lower.contains("channel") && lower.contains("open failed"))
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        currentDirectory: String,
        environment: [String: String],
        stdin: String?,
        timeout: TimeInterval,
        onOutputLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe = Pipe()
        if stdin != nil {
            process.standardInput = stdinPipe
        } else {
            // Never the app's own stdin: launched from a terminal (the run
            // script's fallback), that is a tty, and ssh would forward the
            // user's keystrokes to a remote command.
            process.standardInput = FileHandle.nullDevice
        }

        let stdoutCollector = PipeCollector(onLine: onOutputLine)
        let stderrCollector = PipeCollector()
        let signalState = ProcessSignalState()

        let drainGroup = DispatchGroup()
        let drainQueue = DispatchQueue(label: "HPCMonitor.process-pipes", attributes: .concurrent)

        func startDraining(_ handle: FileHandle, into collector: PipeCollector) {
            drainGroup.enter()
            drainQueue.async {
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        break
                    }
                    collector.append(chunk)
                }
                collector.finish()
                drainGroup.leave()
            }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Set before run() so a fast-exiting child cannot slip past.
                process.terminationHandler = { _ in
                    // The child is reaped: stop the timeout watchdog first so
                    // it cannot fire against a finished run or a recycled pid.
                    signalState.markExited()
                    // Wait (bounded) for both pipes to reach EOF so late output
                    // is not lost, then resume the async caller.
                    drainQueue.async {
                        _ = drainGroup.wait(timeout: .now() + 3)
                        continuation.resume()
                    }
                }

                startDraining(stdoutPipe.fileHandleForReading, into: stdoutCollector)
                startDraining(stderrPipe.fileHandleForReading, into: stderrCollector)

                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    // Unblock the drain readers with EOF.
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                    continuation.resume(throwing: error)
                    return
                }

                if let stdin {
                    let writer = stdinPipe.fileHandleForWriting
                    try? writer.write(contentsOf: Data(stdin.utf8))
                    try? writer.close()
                }

                signalState.registerRunning(process.processIdentifier)

                let timeoutWatchdog = DispatchWorkItem {
                    guard signalState.isChildAlive, signalState.markTimedOut() else {
                        return
                    }
                    signalState.signalTree(SIGTERM)
                    let killFollowUp = DispatchWorkItem {
                        guard signalState.isChildAlive else {
                            return
                        }
                        signalState.signalTree(SIGKILL)
                    }
                    if signalState.registerWatchdog(killFollowUp) {
                        drainQueue.asyncAfter(deadline: .now() + 2, execute: killFollowUp)
                    }
                }
                if signalState.registerWatchdog(timeoutWatchdog) {
                    drainQueue.asyncAfter(deadline: .now() + timeout, execute: timeoutWatchdog)
                }
            }
        } onCancel: {
            signalState.cancel()
        }

        let stdout = stdoutCollector.text
        let stderr = stderrCollector.text
        // The watchdog can still fire inside the exit-to-reap zombie window,
        // before the termination handler cancels it; trust the timeout verdict
        // only when the process did not in fact exit cleanly.
        if signalState.timedOut && !(process.terminationReason == .exit && process.terminationStatus == 0) {
            return ProcessResult(
                stdout: stdout,
                stderr: stderr + "\nProcess timed out after \(Int(timeout))s: \(executable)",
                exitCode: Self.processTimedOutExitCode
            )
        }
        return ProcessResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }
}
