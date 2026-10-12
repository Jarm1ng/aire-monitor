import CryptoKit
import Foundation
import Darwin

/// Everything needed to reach one cluster over SSH. Built by `ClusterSession`
/// from the shared sign-in configuration plus the cluster's own profile.
struct ConnectionSettings: Sendable {
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
    /// master/keepalive pid files. Nothing in it is shared between clusters.
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

struct ProcessResult {
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
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let path):
            return "Missing file: \(path)"
        case .processFailed(let message), .passwordRejected(let message),
             .passwordExpired(let message), .jumpHostFailed(let message):
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

struct MonitorService: Sendable {
    static let statusLinePrefix = "HPC-STATUS: "

    static let loginHelperScript = "scripts/hpc_ssh_login.expect"
    static let targetStarterScript = "scripts/hpc_start_target_master.zsh"
    static let collectorScript = "scripts/hpc_snapshot.py"

    /// Authenticates one cluster: on the rash route the expect helper first
    /// makes sure the shared jump master is up (reusing a healthy one, so
    /// logging into a second cluster never tears down the first), then the
    /// target starter launches this cluster's own ControlMaster. The
    /// password travels only as the first line of each helper's stdin.
    func login(
        settings: ConnectionSettings,
        password: String,
        onStatus: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        try requireFile("\(settings.projectRoot)/\(Self.targetStarterScript)")
        try prepareRuntime(settings: settings)

        var environment = ProcessInfo.processInfo.environment
        environment["HPC_PROJECT_ROOT"] = settings.projectRoot
        environment["HPC_RUNTIME_DIR"] = settings.runtimeDirectory
        environment["HPC_TARGET_LABEL"] = settings.clusterName
        environment["HPC_USERNAME"] = settings.username
        environment["HPC_HOSTNAME"] = settings.hostname
        environment["HPC_USE_JUMP_HOST"] = settings.useJumpHost ? "1" : "0"
        environment["HPC_JUMP_HOSTNAME"] = settings.jumpHostname
        environment["HPC_DUO_OPTION"] = settings.duoOption
        environment["HPC_CONTROL_PATH"] = settings.controlPath
        if !settings.jumpControlPath.isEmpty {
            environment["HPC_JUMP_CONTROL_PATH"] = settings.jumpControlPath
        }
        environment["HPC_FORCE_RELOGIN"] = "1"
        environment["HPC_LOGIN_DEBUG_LOG"] = "\(settings.runtimeDirectory)/login_debug.log"
        environment["HPC_TIMEOUT"] = "180"

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
                timeout: 190,
                onOutputLine: statusLineHandler
            )
            transcript = helperResult
            if helperResult.exitCode != 0 {
                let message = helperResult.stderr.isEmpty ? helperResult.stdout : helperResult.stderr
                try? writeLoginDebug(settings: settings, result: helperResult)
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
            timeout: 190,
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
        try? writeLoginDebug(settings: settings, result: combinedResult)
        if targetResult.exitCode != 0 {
            let message = targetResult.stderr.isEmpty ? targetResult.stdout : targetResult.stderr
            throw Self.loginError(message, exitCode: targetResult.exitCode, clusterName: settings.clusterName)
        }
        return combinedResult.stdout
    }

    private static func loginError(
        _ message: String,
        exitCode: Int32,
        clusterName: String,
        isJumpLeg: Bool = false
    ) -> MonitorError {
        let explanation = explainSSHFailure(message, exitCode: exitCode, clusterName: clusterName)
        switch exitCode {
        case 13:
            return .passwordRejected(explanation)
        case 14:
            return .passwordExpired(explanation)
        default:
            return isJumpLeg ? .jumpHostFailed(explanation) : .processFailed(explanation)
        }
    }

    func collectSnapshot(settings: ConnectionSettings) async throws -> ClusterSnapshot {
        // Check the script first: the project root is a free-text field, and
        // creating runtime directories under a half-typed path would litter
        // the disk (and turn "missing file" into a confusing mkdir error).
        let script = "\(settings.projectRoot)/\(Self.collectorScript)"
        try requireFile(script)
        try prepareRuntime(settings: settings)

        let result = try await runProcess(
            executable: "/usr/bin/python3",
            arguments: [script] + Self.collectorArguments(settings: settings),
            currentDirectory: settings.projectRoot,
            environment: ProcessInfo.processInfo.environment,
            stdin: nil,
            timeout: 40
        )

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
        let arguments = [
            "-o", "BatchMode=yes",
            "-S", settings.controlPath,
            "-o", "User=\(settings.username)",
            "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no",
            // Defense in depth behind the pre-flight: if ssh still falls
            // back to a direct connection, fail within seconds instead of
            // hanging into the watchdog timeout, and never let a stray
            // ~/.ssh/config ControlMaster=auto spawn a new master.
            "-o", "ConnectTimeout=5",
            "-o", "ControlMaster=no",
            settings.hostname,
            command
        ]
        return try await runProcess(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            currentDirectory: settings.projectRoot,
            environment: ProcessInfo.processInfo.environment,
            stdin: nil,
            timeout: timeout
        )
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
            environment: ProcessInfo.processInfo.environment,
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
            environment: ProcessInfo.processInfo.environment,
            stdin: nil,
            timeout: 5
        )
        guard check.exitCode == 0 else {
            throw MonitorError.processFailed(
                "\(settings.clusterName) SSH session expired — use Connect to sign in to \(settings.clusterName) again."
            )
        }
    }

    /// The collector's argument list (without the script path). Also written,
    /// password-free, to the cluster's runtime directory so the desktop
    /// widget can run the identical collection when the app is not running.
    static func collectorArguments(settings: ConnectionSettings) -> [String] {
        var arguments = [
            "--cluster-id", settings.clusterID.rawValue,
            "--cluster-name", settings.clusterName,
            "--username", settings.username,
            "--hostname", settings.hostname,
            "--jump-hostname", settings.jumpHostname,
            settings.useJumpHost ? "--use-jump-host" : "--no-jump-host",
            "--control-path", settings.controlPath,
            "--storage-spec", storageSpecJSON(settings.storage),
            "--timeout", "30"
        ]
        if !settings.jumpControlPath.isEmpty {
            arguments.append(contentsOf: ["--jump-control-path", settings.jumpControlPath])
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

        if exitCode == 13 {
            prefix = """
            Password was rejected by \(clusterName) — re-enter it (and check for a pending Duo lockout).

            The server asked for the password a second time, which normally means the password is wrong. Update the saved password and try again; repeated wrong attempts can temporarily lock the account.
            """
        } else if exitCode == 14 {
            prefix = """
            \(clusterName) asked for a password change — the university password has expired.

            Change it through the University's password service, then sign in again with the new password. The app never answers password-change prompts.
            """
        } else if lower.contains("not allowed at this time")
            || lower.contains("kex_exchange_identification")
            || lower.contains("connection reset by")
            || lower.contains("session open refused by peer") {
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
                exitCode: 124
            )
        }
        return ProcessResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }
}
