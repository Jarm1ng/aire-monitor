import CryptoKit
import Foundation
import Darwin

struct ServerSettings {
    var useSSHAlias: Bool
    var sshAlias: String
    var username: String
    var aireHostname: String
    var useJumpHost: Bool
    var jumpHostname: String
    var duoOption: String
    var projectRoot: String

    var runtimeDirectory: String {
        "\(projectRoot)/.runtime"
    }

    // Unix domain socket paths are limited to 104 bytes on macOS, and ssh
    // appends a ~18-char random suffix while establishing a master. Sockets
    // therefore live in a short home-anchored directory with hashed names,
    // independent of how deeply the project itself is nested.
    var controlDirectory: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/ctl")
    }

    var controlPath: String {
        if useSSHAlias {
            return ""
        }
        let route = useJumpHost ? "via-\(jumpHostname)" : "direct"
        return shortControlPath(prefix: "aire", key: "\(username)@\(aireHostname):\(route)")
    }

    var jumpControlPath: String {
        if useSSHAlias || !useJumpHost {
            return ""
        }
        return shortControlPath(prefix: "jump", key: "\(username)@\(jumpHostname)")
    }

    private func shortControlPath(prefix: String, key: String) -> String {
        let digest = SHA256.hash(data: Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        let hash = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(controlDirectory)/\(prefix)-\(hash).sock"
    }

    var keychainAccount: String {
        if useSSHAlias {
            let alias = sshAlias.trimmingCharacters(in: .whitespacesAndNewlines)
            return "alias:\(alias.isEmpty ? "aire" : alias)"
        }

        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = aireHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let route = useJumpHost
            ? "via:\(jumpHostname.trimmingCharacters(in: .whitespacesAndNewlines))"
            : "direct"
        return "explicit:\(user)@\(host):\(route)"
    }

    var legacyKeychainAccount: String? {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !useSSHAlias && !user.isEmpty else {
            return nil
        }
        return "\(user)@leeds"
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
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let path):
            return "Missing file: \(path)"
        case .processFailed(let message):
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
    static let statusLinePrefix = "AIRE-STATUS: "

    func login(
        settings: ServerSettings,
        password: String,
        onStatus: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        try prepareRuntime(settings: settings)
        let helper = "\(settings.projectRoot)/scripts/aire_ssh_login.expect"
        try requireFile(helper)

        var environment = ProcessInfo.processInfo.environment
        environment["AIRE_CONNECTION_MODE"] = settings.useSSHAlias ? "alias" : "explicit"
        environment["AIRE_SSH_ALIAS"] = settings.sshAlias
        environment["AIRE_USERNAME"] = settings.username
        environment["AIRE_HOSTNAME"] = settings.aireHostname
        environment["AIRE_USE_JUMP_HOST"] = settings.useJumpHost ? "1" : "0"
        environment["AIRE_JUMP_HOSTNAME"] = settings.jumpHostname
        environment["AIRE_DUO_OPTION"] = settings.duoOption
        if !settings.controlPath.isEmpty {
            environment["AIRE_CONTROL_PATH"] = settings.controlPath
        }
        if !settings.jumpControlPath.isEmpty {
            environment["AIRE_JUMP_CONTROL_PATH"] = settings.jumpControlPath
        }
        environment["AIRE_FORCE_RELOGIN"] = "1"
        environment["AIRE_LOGIN_DEBUG_LOG"] = "\(settings.runtimeDirectory)/login_debug.log"
        environment["AIRE_TIMEOUT"] = "180"
        if !settings.useSSHAlias {
            environment["AIRE_SKIP_TARGET"] = "1"
        }

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

        let helperResult = try await runProcess(
            executable: "/usr/bin/expect",
            arguments: [helper],
            currentDirectory: settings.projectRoot,
            environment: environment,
            stdin: password + "\n",
            timeout: 190,
            onOutputLine: statusLineHandler
        )

        if helperResult.exitCode != 0 {
            let message = helperResult.stderr.isEmpty ? helperResult.stdout : helperResult.stderr
            try? writeLoginDebug(settings: settings, result: helperResult)
            throw MonitorError.processFailed(
                Self.explainSSHFailure(message, exitCode: helperResult.exitCode)
            )
        }

        guard !settings.useSSHAlias else {
            try? writeLoginDebug(settings: settings, result: helperResult)
            return helperResult.stdout
        }

        let targetStarter = "\(settings.projectRoot)/scripts/aire_start_target_master.zsh"
        try requireFile(targetStarter)
        var targetEnvironment = environment
        targetEnvironment["AIRE_PROJECT_ROOT"] = settings.projectRoot
        // The password is handed to the starter as the first line of stdin
        // (read via `read -rs`); it must never appear in any child environment
        // or argv.
        let targetResult = try await runProcess(
            executable: "/bin/zsh",
            arguments: [targetStarter],
            currentDirectory: settings.projectRoot,
            environment: targetEnvironment,
            stdin: password + "\n",
            timeout: 190,
            onOutputLine: statusLineHandler
        )
        let combinedResult = ProcessResult(
            stdout: [helperResult.stdout, targetResult.stdout]
                .filter { !$0.isEmpty }
                .joined(separator: "\n"),
            stderr: [helperResult.stderr, targetResult.stderr]
                .filter { !$0.isEmpty }
                .joined(separator: "\n"),
            exitCode: targetResult.exitCode
        )
        if targetResult.exitCode != 0 {
            let message = targetResult.stderr.isEmpty ? targetResult.stdout : targetResult.stderr
            try? writeLoginDebug(settings: settings, result: combinedResult)
            throw MonitorError.processFailed(
                Self.explainSSHFailure(message, exitCode: targetResult.exitCode)
            )
        }
        try? writeLoginDebug(settings: settings, result: combinedResult)
        return combinedResult.stdout
    }

    func collectSnapshot(settings: ServerSettings) async throws -> ClusterSnapshot {
        try prepareRuntime(settings: settings)
        let script = "\(settings.projectRoot)/scripts/aire_monitor_snapshot.py"
        try requireFile(script)

        let result = try await runProcess(
            executable: "/usr/bin/python3",
            arguments: snapshotArguments(settings: settings, script: script),
            currentDirectory: settings.projectRoot,
            environment: ProcessInfo.processInfo.environment,
            stdin: nil,
            timeout: 40
        )

        guard !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let detail = result.stderr.isEmpty
                ? "snapshot script produced no output"
                : Self.explainSSHFailure(result.stderr, exitCode: result.exitCode)
            throw MonitorError.invalidJSON(detail)
        }
        let data = Data(result.stdout.utf8)

        do {
            let snapshot = try JSONDecoder().decode(ClusterSnapshot.self, from: data)
            if result.exitCode != 0 && snapshot.errors.isEmpty {
                let message = result.stderr.isEmpty ? result.stdout : result.stderr
                throw MonitorError.processFailed(Self.explainSSHFailure(message, exitCode: result.exitCode))
            }
            return snapshot
        } catch let error as MonitorError {
            throw error
        } catch {
            let detail = result.stderr.isEmpty ? error.localizedDescription : result.stderr
            throw MonitorError.invalidJSON(Self.explainSSHFailure(detail))
        }
    }

    /// One-shot remote command over the existing SSH session (ControlMaster
    /// socket in explicit mode, the alias's own config in alias mode). Never
    /// touches a password: BatchMode suppresses every prompt. A dead master
    /// does NOT fail fast on its own — OpenSSH silently falls back to a
    /// direct, un-jumped connection — so explicit mode pre-flights the master
    /// with `ssh -O check` and throws a readable error instead.
    func runRemoteCommand(
        settings: ServerSettings,
        command: String,
        timeout: TimeInterval = 30
    ) async throws -> ProcessResult {
        var arguments = ["-o", "BatchMode=yes"]
        if settings.useSSHAlias {
            arguments.append(settings.sshAlias)
        } else {
            try await requireLiveMaster(settings: settings)
            arguments.append(contentsOf: [
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
                settings.aireHostname
            ])
        }
        arguments.append(command)
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
    /// so argv elements need no quoting. Explicit mode pre-flights the
    /// ControlMaster exactly like `runRemoteCommand`, so a dead session
    /// throws a readable error instantly instead of scp silently dialing the
    /// host directly (bypassing the jump host) and hanging.
    func runTransfer(
        settings: ServerSettings,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        if !settings.useSSHAlias {
            try await requireLiveMaster(settings: settings)
        }
        return try await runProcess(
            executable: "/usr/bin/scp",
            arguments: arguments,
            currentDirectory: settings.projectRoot,
            environment: ProcessInfo.processInfo.environment,
            stdin: nil,
            timeout: timeout
        )
    }

    /// Verifies the explicit-mode ControlMaster with `ssh -O check`, which
    /// fails in milliseconds for both a missing and a dead socket. Without
    /// this, a dead master makes ssh silently dial the host directly
    /// (bypassing the jump host) and the eventual timeout surfaces as a
    /// misleading login/Duo-flavored error.
    private func requireLiveMaster(settings: ServerSettings) async throws {
        let check = try await runProcess(
            executable: "/usr/bin/ssh",
            arguments: ["-S", settings.controlPath, "-O", "check", settings.aireHostname],
            currentDirectory: settings.projectRoot,
            environment: ProcessInfo.processInfo.environment,
            stdin: nil,
            timeout: 5
        )
        guard check.exitCode == 0 else {
            throw MonitorError.processFailed("SSH session expired — use Login to reconnect.")
        }
    }

    private func snapshotArguments(settings: ServerSettings, script: String) -> [String] {
        if settings.useSSHAlias {
            return [
                script,
                "--host", settings.sshAlias,
                "--timeout", "30"
            ]
        }
        var arguments = [
            script,
            "--username", settings.username,
            "--aire-hostname", settings.aireHostname,
            "--jump-hostname", settings.jumpHostname,
            settings.useJumpHost ? "--use-jump-host" : "--no-jump-host",
            "--control-path", settings.controlPath,
            "--timeout", "30"
        ]
        if !settings.jumpControlPath.isEmpty {
            arguments.append(contentsOf: ["--jump-control-path", settings.jumpControlPath])
        }
        return arguments
    }

    private func prepareRuntime(settings: ServerSettings) throws {
        if settings.controlPath.isEmpty && settings.jumpControlPath.isEmpty {
            return
        }
        try FileManager.default.createDirectory(
            atPath: settings.controlDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func requireFile(_ path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            throw MonitorError.missingFile(path)
        }
    }

    private func writeLoginDebug(settings: ServerSettings, result: ProcessResult) throws {
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
        }
    }

    static func explainSSHFailure(_ rawMessage: String, exitCode: Int32? = nil) -> String {
        let raw = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        let prefix: String

        if exitCode == 13 {
            prefix = """
            Password was rejected — re-enter it (and check for a pending Duo lockout).

            The server asked for the password a second time, which normally means the password is wrong. Update the saved password and try again; repeated wrong attempts can temporarily lock the account.
            """
        } else if lower.contains("connection timed out during banner exchange")
            || lower.contains("connection to unknown port 65535 timed out") {
            prefix = """
            SSH timed out while opening the connection to AIRE.

            If you are on the University VPN, use the "Direct (VPN)" route. If you are off-VPN, use the "Via rash jump host" route. Then check the AIRE host, the jump host (rash route only), network access, and that your username is valid on both hosts.
            """
        } else if lower.contains("permission denied") {
            prefix = """
            SSH authentication was rejected.

            Check the password, Duo approval, and username. If Duo sends a push, approve it before the login timeout expires.
            """
        } else if lower.contains("timed out while waiting") || lower.contains("process timed out") {
            prefix = """
            The login process timed out.

            This usually means the app was waiting for a password, Duo prompt, Duo approval, or SSH banner. Try again and watch for a Duo push notification.
            """
        } else if lower.contains("could not resolve hostname") {
            prefix = """
            SSH could not resolve one of the hostnames.

            Check the AIRE host and, on the rash route, the jump host in Advanced.
            """
        } else if lower.contains("no such file or directory") && lower.contains("ssh-askpass") {
            prefix = """
            SSH attempted to ask for a password outside the app.

            Use Login in the app first so the expect helper can handle the password and Duo prompts.
            """
        } else {
            prefix = "SSH command failed."
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
        let drainQueue = DispatchQueue(label: "AIREMonitor.process-pipes", attributes: .concurrent)

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
