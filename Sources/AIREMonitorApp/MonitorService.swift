import Foundation
import Darwin

struct ServerSettings {
    var useSSHAlias: Bool
    var sshAlias: String
    var username: String
    var aireHostname: String
    var jumpHostname: String
    var duoOption: String
    var projectRoot: String

    var runtimeDirectory: String {
        "\(projectRoot)/.runtime"
    }

    var controlDirectory: String {
        "\(runtimeDirectory)/ssh-control"
    }

    var controlPath: String {
        if useSSHAlias {
            return ""
        }
        return ".runtime/ssh-control/%C"
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

struct MonitorService: Sendable {
    func login(settings: ServerSettings, password: String) async throws -> String {
        try prepareRuntime(settings: settings)
        let helper = "\(settings.projectRoot)/scripts/aire_ssh_login.expect"
        try requireFile(helper)

        var environment = ProcessInfo.processInfo.environment
        environment["AIRE_CONNECTION_MODE"] = settings.useSSHAlias ? "alias" : "explicit"
        environment["AIRE_SSH_ALIAS"] = settings.sshAlias
        environment["AIRE_USERNAME"] = settings.username
        environment["AIRE_HOSTNAME"] = settings.aireHostname
        environment["AIRE_JUMP_HOSTNAME"] = settings.jumpHostname
        environment["AIRE_DUO_OPTION"] = settings.duoOption
        if !settings.controlPath.isEmpty {
            environment["AIRE_CONTROL_PATH"] = settings.controlPath
        }
        environment["AIRE_TIMEOUT"] = "180"

        let result = try await runProcess(
            executable: "/usr/bin/expect",
            arguments: [helper],
            currentDirectory: settings.projectRoot,
            environment: environment,
            stdin: password + "\n",
            timeout: 190
        )

        if result.exitCode != 0 {
            let message = result.stderr.isEmpty ? result.stdout : result.stderr
            throw MonitorError.processFailed(Self.explainSSHFailure(message))
        }
        return result.stdout
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

        guard let data = result.stdout.data(using: .utf8) else {
            throw MonitorError.invalidJSON("empty output")
        }

        do {
            let snapshot = try JSONDecoder().decode(ClusterSnapshot.self, from: data)
            if result.exitCode != 0 && snapshot.errors.isEmpty {
                let message = result.stderr.isEmpty ? result.stdout : result.stderr
                throw MonitorError.processFailed(Self.explainSSHFailure(message))
            }
            return snapshot
        } catch {
            let detail = result.stderr.isEmpty ? error.localizedDescription : result.stderr
            throw MonitorError.invalidJSON(Self.explainSSHFailure(detail))
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
        return [
            script,
            "--username", settings.username,
            "--aire-hostname", settings.aireHostname,
            "--jump-hostname", settings.jumpHostname,
            "--control-path", settings.controlPath,
            "--timeout", "30"
        ]
    }

    private func prepareRuntime(settings: ServerSettings) throws {
        if settings.controlPath.isEmpty {
            return
        }
        let manager = FileManager.default
        try manager.createDirectory(
            atPath: settings.controlDirectory,
            withIntermediateDirectories: true
        )
    }

    private func requireFile(_ path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            throw MonitorError.missingFile(path)
        }
    }

    static func explainSSHFailure(_ rawMessage: String) -> String {
        let raw = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        let prefix: String

        if lower.contains("connection timed out during banner exchange")
            || lower.contains("connection to unknown port 65535 timed out") {
            prefix = """
            SSH reached the jump host but timed out while opening the AIRE connection through it.

            Try using "Use local SSH alias" with alias "aire" first, because your Terminal SSH config already knows the working jump-host path. If explicit mode is required, check the AIRE host, jump host, VPN/network access, and whether the same username is valid on both hosts.
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

            Check the AIRE host, jump host, or local SSH alias.
            """
        } else if lower.contains("no such file or directory") && lower.contains("ssh-askpass") {
            prefix = """
            SSH attempted to ask for a password outside the app.

            Use Login in the app first so the expect helper can handle password and Duo prompts, or use the local SSH alias mode after establishing a terminal SSH session.
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
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        try await Task.detached(priority: .userInitiated) {
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

            try process.run()

            if let stdin {
                if let data = stdin.data(using: .utf8) {
                    stdinPipe.fileHandleForWriting.write(data)
                }
                try? stdinPipe.fileHandleForWriting.close()
            }

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                usleep(50_000)
            }
            if process.isRunning {
                process.terminate()
                throw MonitorError.processFailed("Process timed out: \(executable)")
            }

            let stdout = String(
                data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            let stderr = String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""

            return ProcessResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
        }.value
    }
}
