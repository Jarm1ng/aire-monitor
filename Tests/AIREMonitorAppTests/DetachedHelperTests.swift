import Darwin
import Foundation
import Testing
@testable import AIREMonitorApp

// The sign-in helpers run as one-shot launchd jobs (DetachedHelper), so the
// SSH masters they start are not in the app's coalition and survive a
// Force Quit of the app. These tests run real jobs in the user's GUI
// launchd domain, with plain shell commands instead of ssh; they are
// skipped where there is no such domain (a headless session).

@Suite("Sign-in helpers outside the app (launchd jobs)", .serialized, .timeLimit(.minutes(2)))
struct DetachedHelperTests {
    static let launchdAvailable: Bool = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }()

    private static func makeJobRoot() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hpc-detached-\(UUID().uuidString.prefix(8))").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }

    @Test("The job definition keeps the password out of argv and the environment, and leaves started processes alone")
    func jobDefinition() throws {
        let files = DetachedHelper.JobFiles(directory: "/tmp/job")
        let definition = DetachedHelper.jobDefinition(
            label: DetachedHelper.labelPrefix + "x",
            files: files,
            executable: "/bin/zsh",
            arguments: ["/repo/scripts/hpc_start_target_master.zsh"],
            currentDirectory: "/repo",
            environment: ["HPC_USERNAME": "abcd1234", "PATH": "/usr/bin:/bin"],
            hasStdin: true
        )
        let arguments = try #require(definition["ProgramArguments"] as? [String])
        #expect(Array(arguments.suffix(2)) == ["/bin/zsh", "/repo/scripts/hpc_start_target_master.zsh"])
        let environment = try #require(definition["EnvironmentVariables"] as? [String: String])
        #expect(environment["HPC_HELPER_JOB_DIR"] == "/tmp/job")
        #expect(environment["HPC_USERNAME"] == "abcd1234")
        // The password only ever travels through the stdin FIFO.
        #expect(definition["StandardInPath"] as? String == files.stdin)
        #expect(definition["AbandonProcessGroup"] as? Bool == true)
        #expect(definition["KeepAlive"] as? Bool == false)
        #expect(definition["WorkingDirectory"] as? String == "/repo")

        let noInput = DetachedHelper.jobDefinition(
            label: "l", files: files, executable: "/bin/sh", arguments: [], currentDirectory: "/",
            environment: [:], hasStdin: false
        )
        #expect(noInput["StandardInPath"] as? String == "/dev/null")
    }

    @Test("stdin reaches the helper; stdout streams by line; stderr and the exit status come back",
          .enabled(if: DetachedHelperTests.launchdAvailable))
    func plumbing() async throws {
        let root = try Self.makeJobRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let lines = LockedLines()
        let result = try #require(await DetachedHelper.run(
            executable: "/bin/sh",
            arguments: ["-c", #"IFS= read -r line; echo "HPC-STATUS: got $line"; echo oops >&2; exit 7"#],
            currentDirectory: root,
            environment: ["PATH": "/usr/bin:/bin"],
            stdin: "secret\n",
            timeout: 60,
            jobRoot: root,
            onOutputLine: { lines.append($0) }
        ))
        #expect(result.exitCode == 7)
        #expect(result.stdout.contains("HPC-STATUS: got secret"))
        #expect(lines.all == ["HPC-STATUS: got secret"])
        #expect(result.stderr.contains("oops"))
        // The job directory, with its FIFOs and plist, is gone.
        #expect((try FileManager.default.contentsOfDirectory(atPath: root)).isEmpty)
    }

    /// The point of the whole exercise: what a helper leaves running (an
    /// SSH master, or a master's ProxyCommand on the rash route) is not in
    /// this process's coalition, so a Force Quit of the app cannot take it
    /// down, and it survives the job being booted out.
    @Test("A process the helper leaves running is outside our coalition and outlives the job",
          .enabled(if: DetachedHelperTests.launchdAvailable))
    func leftoverProcessOutlivesTheJob() async throws {
        let root = try Self.makeJobRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let childFile = root + "/child.pid"
        let result = try #require(await DetachedHelper.run(
            executable: "/bin/sh",
            arguments: ["-c", #"( exec sleep 60 ) >/dev/null 2>&1 & echo $! > "$0""#, childFile],
            currentDirectory: root,
            environment: ["PATH": "/usr/bin:/bin"],
            stdin: nil,
            timeout: 60,
            jobRoot: root
        ))
        #expect(result.exitCode == 0)
        let child = try #require(pid_t(String(contentsOfFile: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(child, SIGKILL) }
        #expect(kill(child, 0) == 0, "the leftover process died with the job")
        let ours = try #require(Self.coalitionID(of: getpid()))
        let theirs = try #require(Self.coalitionID(of: child))
        #expect(theirs != ours, "the leftover process is in the caller's coalition")
    }

    @Test("The watchdog stops a helper that runs too long (exit 124)",
          .enabled(if: DetachedHelperTests.launchdAvailable))
    func timeout() async throws {
        let root = try Self.makeJobRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let started = Date()
        let result = try #require(await DetachedHelper.run(
            executable: "/bin/sh", arguments: ["-c", "sleep 30"], currentDirectory: root,
            environment: ["PATH": "/usr/bin:/bin"], stdin: nil, timeout: 1, jobRoot: root
        ))
        #expect(result.exitCode == MonitorService.processTimedOutExitCode)
        #expect(result.stderr.contains("timed out"))
        #expect(Date().timeIntervalSince(started) < 15)
    }

    @Test("A helper that ignores TERM is killed 2 s after the watchdog's TERM",
          .enabled(if: DetachedHelperTests.launchdAvailable))
    func killAfterIgnoredTerm() async throws {
        let root = try Self.makeJobRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let started = Date()
        // An ignored signal stays ignored across exec, so sleep ignores it too.
        let result = try #require(await DetachedHelper.run(
            executable: "/bin/sh", arguments: ["-c", "trap '' TERM; sleep 30"], currentDirectory: root,
            environment: ["PATH": "/usr/bin:/bin"], stdin: nil, timeout: 1, jobRoot: root
        ))
        #expect(result.exitCode == MonitorService.processTimedOutExitCode)
        #expect(Date().timeIntervalSince(started) < 15)
    }

    /// On the rash route a finished starter's process group still holds the
    /// new master's ProxyCommand: a cancel that arrives after the helper
    /// finished (while the app collects its last output) must not touch it.
    @Test("A cancel after the helper finished leaves what it started running",
          .enabled(if: DetachedHelperTests.launchdAvailable))
    func lateCancelSparesLeftovers() async throws {
        let root = try Self.makeJobRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let childFile = root + "/child.pid"
        // The child keeps stdout open, so the run waits for late output
        // for about 3 s after the helper exits: the cancel lands then.
        let task = Task {
            await DetachedHelper.run(
                executable: "/bin/sh",
                arguments: ["-c", #"( exec sleep 60 ) & echo $! > "$0"; exit 0"#, childFile],
                currentDirectory: root, environment: ["PATH": "/usr/bin:/bin"], stdin: nil, timeout: 60, jobRoot: root
            )
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        task.cancel()
        let result = try #require(await task.value)
        #expect(result.exitCode == 0)
        let child = try #require(pid_t(String(contentsOfFile: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(child, SIGKILL) }
        #expect(kill(child, 0) == 0, "a late cancel killed the finished helper's leftover")
    }

    @Test("A sign-in cancelled before its helper starts never starts it",
          .enabled(if: DetachedHelperTests.launchdAvailable))
    func cancelBeforeStart() async throws {
        let root = try Self.makeJobRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let marker = root + "/ran"
        let task = Task {
            await DetachedHelper.run(
                executable: "/bin/sh", arguments: ["-c", #"touch "$0""#, marker], currentDirectory: root,
                environment: ["PATH": "/usr/bin:/bin"], stdin: nil, timeout: 60, jobRoot: root
            )
        }
        task.cancel()
        let result = try #require(await task.value)
        #expect(result.exitCode != 0)
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test("Checkouts in privacy-protected folders keep running the helpers from the app")
    func protectedFolders() {
        let home = "/Users/someone"
        #expect(DetachedHelper.canRunOutsideApp(projectRoot: "/Users/someone/projects/aire_server_app", home: home))
        #expect(DetachedHelper.canRunOutsideApp(projectRoot: "/Users/someone/DocumentsArchive/app", home: home))
        #expect(!DetachedHelper.canRunOutsideApp(projectRoot: "/Users/someone/Documents/GitHub/app", home: home))
        #expect(!DetachedHelper.canRunOutsideApp(projectRoot: "/Users/someone/Desktop/app", home: home))
        #expect(!DetachedHelper.canRunOutsideApp(projectRoot: "/Users/someone/Downloads/app", home: home))
        #expect(!DetachedHelper.canRunOutsideApp(projectRoot: "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/app", home: home))
        #expect(!DetachedHelper.canRunOutsideApp(projectRoot: "/Users/someone/Library/CloudStorage/Dropbox/app", home: home))
        #expect(!DetachedHelper.canRunOutsideApp(projectRoot: "/Volumes/External/app", home: home))
    }

    @Test("Cancelling the task stops the helper promptly",
          .enabled(if: DetachedHelperTests.launchdAvailable))
    func cancellation() async throws {
        let root = try Self.makeJobRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let started = Date()
        let task = Task {
            await DetachedHelper.run(
                executable: "/bin/sh", arguments: ["-c", "sleep 30"], currentDirectory: root,
                environment: ["PATH": "/usr/bin:/bin"], stdin: nil, timeout: 60, jobRoot: root
            )
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        task.cancel()
        let result = try #require(await task.value)
        #expect(result.exitCode != 0)
        #expect(Date().timeIntervalSince(started) < 15)
    }

    /// XNU's PROC_PIDCOALITIONINFO (private): the resource coalition id.
    private static func coalitionID(of pid: pid_t) -> UInt64? {
        var info: (UInt64, UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0, 0)
        let size = Int32(MemoryLayout.size(ofValue: info))
        let count = withUnsafeMutablePointer(to: &info) { proc_pidinfo(pid, 20, 0, $0, size) }
        return count > 0 ? info.0 : nil
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
