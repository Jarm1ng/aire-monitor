import HPCCore
import AppKit
import Foundation
import SwiftTerm
import Testing
@testable import AIREMonitorApp

// Terminal: ssh argv (a security boundary), exit-status wording,
// quick-command routing and reuse, the per-cluster session budget, the
// connecting state, and the Quota chip generated from the storage specs.
// Nothing here starts ssh: sessions run on a fake backend.

// MARK: - SSH arguments

@Suite("Terminal ssh arguments")
struct TerminalSSHArgumentTests {
    @Test("Never prompts, never becomes a master, fails fast", arguments: catalogIDs)
    func noPromptNoMaster(id: ClusterID) {
        let settings = makeSettings(catalogProfile(id))
        let arguments = SSHTerminalCommand.terminalArguments(settings: settings)
        for option in [
            "BatchMode=yes",
            "ControlMaster=no",
            "ConnectTimeout=5",
            "PasswordAuthentication=no",
            "KbdInteractiveAuthentication=no",
            "User=\(testUsername)"
        ] {
            #expect(arguments.contains(option), "missing -o \(option)")
        }
        #expect(arguments.first == "-tt")
        #expect(value(after: "-S", in: arguments) == settings.controlPath)
        #expect(arguments.last == settings.hostname)
    }

    @Test("Each cluster rides only its own master")
    func perClusterSocket() {
        let aire = SSHTerminalCommand.terminalArguments(settings: makeSettings(.aire))
        let calder = SSHTerminalCommand.terminalArguments(settings: makeSettings(.calder))
        #expect(value(after: "-S", in: aire) != value(after: "-S", in: calder))
        #expect(aire.contains("aire.leeds.ac.uk"))
        #expect(calder.contains("calder.leeds.ac.uk"))
    }

    @Test("A remote command comes last, after the host, behind the connection handshake")
    func remoteCommand() {
        let settings = makeSettings(.aire)
        let arguments = SSHTerminalCommand.terminalArguments(settings: settings, remoteCommand: "squeue --me")
        #expect(arguments.last == "\(SSHTerminalCommand.connectionHandshake); squeue --me")
        #expect(arguments[arguments.count - 2] == settings.hostname)
        // Invisible SGR reset: a quiet command still proves the connection.
        #expect(SSHTerminalCommand.connectionHandshake == #"printf '\033[0m'"#)
    }

    @Test("scp options carry the same invariants through ControlPath")
    func scpOptions() {
        let settings = makeSettings(.calder)
        let options = SSHMuxOptions.scpOptions(settings: settings)
        #expect(options.contains("ControlPath=\(settings.controlPath)"))
        #expect(options.contains("ControlMaster=no"))
        #expect(options.contains("BatchMode=yes"))
        #expect(!options.contains("-S"))
    }

    /// Built from `MonitorService.childEnvironment()` (no exported
    /// password), plus only the locale and terminal type.
    @Test("The terminal environment is the scrubbed child environment plus locale and TERM")
    func environment() {
        var expected = MonitorService.childEnvironment()
        expected["LANG"] = "en_US.UTF-8"
        expected["TERM"] = "xterm-256color"
        expected["COLORTERM"] = "truecolor"
        let environment = SSHTerminalCommand.environment()
        #expect(Set(environment) == Set(expected.map { "\($0.key)=\($0.value)" }))
        for name in ["HPC_PASSWORD", "HPC_ASKPASS_PASSWORD", "AIRE_PASSWORD", "AIRE_ASKPASS_PASSWORD"] {
            #expect(!environment.contains { $0.hasPrefix(name + "=") })
        }
    }

    @Test("Shell quoting")
    func quoting() {
        #expect(SSHTerminalCommand.shellQuote("it's") == #"'it'\''s'"#)
        #expect(SSHTerminalCommand.shellWord("calder-gpu-hopper") == "calder-gpu-hopper")
        #expect(SSHTerminalCommand.shellWord("gpu; rm -rf ~") == "'gpu; rm -rf ~'")
    }
}

// MARK: - Exit status

@Suite("Terminal exit status")
struct TerminalExitStatusTests {
    @Test("Raw wait statuses decode", arguments: [
        (Int32(0), TerminalExitStatus.code(0)),
        (256, .code(1)),
        (65280, .code(255)),
        (9, .signal(9)),
        (15, .signal(15))
    ])
    func decoding(raw: Int32, expected: TerminalExitStatus) {
        #expect(TerminalExitStatus(rawWaitStatus: raw) == expected)
    }

    @Test("A finished quick command reads as done, not as a failure")
    func successIsNeutral() {
        let command = TerminalSession.Status.exited(.code(0)).presentation(kind: .command("squeue --me"), clusterName: "AIRE")
        #expect(command.label == "done")
        #expect(command.tone == .neutral)
        #expect(command.actionTitle == "Run again")

        let shell = TerminalSession.Status.exited(.code(0)).presentation(kind: .shell, clusterName: "AIRE")
        #expect(shell.label == "closed")
        #expect(shell.actionTitle == "Reopen")
    }

    @Test("ssh's 255 is explained as a connection problem")
    func sshFailure() {
        let presentation = TerminalSession.Status.exited(.code(255)).presentation(kind: .shell, clusterName: "Calder")
        #expect(presentation.label == "SSH connection closed")
        #expect(presentation.tone == .warning)
        #expect(presentation.actionTitle == "Restart")
        #expect(presentation.help.contains("Calder"))
    }

    @Test("Other outcomes", arguments: [
        (TerminalSession.Status.exited(.code(2)), "exited (2)", TerminalStatusPresentation.Tone.failure, "Run again" as String?),
        (.exited(.signal(9)), "killed (signal 9)", .failure, "Restart"),
        (.exited(.code(130)), "interrupted", .neutral, "Run again"),
        (.connecting, "connecting…", .progress, nil),
        (.running, "running", .live, nil),
        (.sessionUnavailable, "AIRE not connected", .warning, "Retry")
    ])
    func mapping(status: TerminalSession.Status, label: String, tone: TerminalStatusPresentation.Tone, action: String?) {
        let presentation = status.presentation(kind: .tail(jobId: "1"), clusterName: "AIRE")
        #expect(presentation.label == label)
        #expect(presentation.tone == tone)
        #expect(presentation.actionTitle == action)
    }

    @Test("Only a live or launching ssh counts as running")
    func runningStates() {
        #expect(TerminalSession.Status.connecting.isRunning)
        #expect(TerminalSession.Status.running.isRunning)
        #expect(!TerminalSession.Status.sessionUnavailable.isRunning)
        #expect(!TerminalSession.Status.exited(.code(0)).isRunning)
    }
}

// MARK: - Quick commands and quota

@Suite("Quick commands")
struct TerminalQuickCommandTests {
    @Test("The Quota chip tries every Lustre candidate of the profile, in order", arguments: catalogIDs)
    func quotaCoversCandidates(id: ClusterID) throws {
        let profile = catalogProfile(id)
        let quota = try #require(TerminalQuickCommand.items(for: profile).first { $0.title == "Quota" })
        #expect(quota.command.hasPrefix("quota -s; "))
        for spec in profile.storage where spec.quota == .lustre {
            var previous = quota.command.startIndex
            for path in spec.paths {
                let quoted = TerminalQuotaCommand.doubleQuotedPath(path)
                let range = try #require(quota.command.range(of: quoted), "\(spec.label) candidate \(path) missing")
                #expect(range.lowerBound >= previous, "\(path) out of order")
                previous = range.lowerBound
            }
        }
        // The collector's rule: project quota for a non-zero project id.
        #expect(quota.command.contains(#"lfs quota -h -p "$hpc_p""#))
        #expect(quota.command.contains(#"lfs quota -h -u "$USER""#))
    }

    @Test("Chips follow the profile: no GPU partition, no GPU chip; no quota spaces, no Quota chip")
    func chipsFollowProfile() {
        let bare = TerminalQuickCommand.items(storage: [], gpuPartition: nil)
        #expect(bare.map(\.title) == ["My jobs", "Cluster", "htop"])
        let gpu = TerminalQuickCommand.items(storage: [], gpuPartition: " calder-gpu-hopper ")
        #expect(gpu.first { $0.title == "GPU nodes" }?.command == "sinfo -N -p calder-gpu-hopper")
        #expect(gpu.first { $0.title == "htop" }?.opensDedicatedSession == true)
    }

    @Test("Spec paths keep $USER/$HOME live and everything else literal", arguments: [
        ("$HOME", #""$HOME""#),
        ("/mnt/scratch/$USER", #""/mnt/scratch/$USER""#),
        ("/x/${USER}/y", #""/x/${USER}/y""#),
        ("/x/$USERdata", #""/x/${USER}data""#),
        ("/x/$(rm -rf ~)", #""/x/\$(rm -rf ~)""#),
        ("/x/`id`\"q\\", #""/x/\`id\`\"q\\""#)
    ])
    func pathQuoting(path: String, expected: String) {
        #expect(TerminalQuotaCommand.doubleQuotedPath(path) == expected)
    }

    @Test("The generated command runs in sh, bash and zsh with the collector's project rule",
          arguments: ["/bin/sh", "/bin/bash", "/bin/zsh"])
    func quotaCommandRuns(shell: String) throws {
        guard FileManager.default.isExecutableFile(atPath: shell) else {
            return
        }
        let root = try TemporaryProjectRoot()
        defer { root.remove() }
        let user = "hpcuser"
        try FileManager.default.createDirectory(atPath: "\(root.path)/scratch-b/\(user)", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(root.path)/flash-a/\(user)", withIntermediateDirectories: true)
        // Stubs: df reports a mount named after the space; lfs gives the
        // scratch directory project 4242 and flash project 0 (the shared
        // bucket of unassigned files, never the user's quota).
        try root.write("echo QUOTA-NFS\n", to: "bin/quota")
        try root.write(
            #"""
            space=$(basename "$(dirname "$2")")
            printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
            printf 'fs 1 1 1 1%% /mnt/%s\n' "$space"
            """# + "\n",
            to: "bin/df"
        )
        try root.write(
            #"""
            if [ "$1" = project ]; then
                case $3 in *scratch*) echo "4242 P $3" ;; *) echo "0 - $3" ;; esac
                exit 0
            fi
            echo "LFS $*"
            """# + "\n",
            to: "bin/lfs"
        )
        for stub in ["quota", "df", "lfs"] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(root.path)/bin/\(stub)")
        }
        let specs = [
            StorageVolumeSpec(label: "Home", paths: ["$HOME"], quota: .nfs),
            StorageVolumeSpec(label: "Scratch", paths: ["\(root.path)/scratch-a/$USER", "\(root.path)/scratch-b/$USER"], quota: .lustre),
            StorageVolumeSpec(label: "Flash", paths: ["\(root.path)/flash-a/$USER", "\(root.path)/flash-b/$USER"], quota: .lustre, optional: true),
            StorageVolumeSpec(label: "Missing", paths: ["\(root.path)/nowhere/$USER"], quota: .lustre, optional: true)
        ]
        let command = try #require(TerminalQuotaCommand.build(from: specs))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
        process.environment = ["USER": user, "HOME": root.path, "PATH": "\(root.path)/bin:/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        #expect(text.contains("QUOTA-NFS"))
        #expect(text.contains("== Scratch: \(root.path)/scratch-b/\(user)"))
        #expect(text.contains("LFS quota -h -p 4242 /mnt/scratch-b"))
        #expect(text.contains("== Flash: \(root.path)/flash-a/\(user)"))
        #expect(text.contains("LFS quota -h -u \(user) /mnt/flash-a"))
        #expect(!text.contains("Missing"))
        // First existing candidate wins: exactly one report per space.
        #expect(text.components(separatedBy: "LFS quota").count - 1 == 2)
    }
}

// MARK: - Routing

@MainActor
private struct FakeTarget: TerminalRoutingTarget {
    var id = UUID()
    var kind: TerminalSession.Kind = .shell
    var clusterID: ClusterID = .aire
    var status: TerminalSession.Status = .running
    var acceptsInput = true
    var isShowingFullScreenProgram = false
}

@MainActor
@Suite("Quick-command routing")
struct TerminalRoutingTests {
    private func route(
        _ command: String = "squeue --me",
        dedicated: Bool = false,
        cluster: ClusterID = .aire,
        active: FakeTarget?,
        sessions: [FakeTarget] = []
    ) -> TerminalQuickCommandRoute {
        TerminalQuickCommandRouter.route(
            command: command,
            prefersDedicatedSession: dedicated,
            clusterID: cluster,
            active: active,
            sessions: sessions
        )
    }

    @Test("Types into a connected shell at its prompt")
    func typesIntoShell() {
        let shell = FakeTarget()
        #expect(route(active: shell, sessions: [shell]) == .type(into: shell.id))
    }

    @Test("Never types into a full-screen program (vim, less, htop)")
    func skipsAlternateScreen() {
        let shell = FakeTarget(isShowingFullScreenProgram: true)
        #expect(route(active: shell, sessions: [shell]) == .open)
    }

    @Test("Never types into another cluster's shell, a connecting shell, or a dead child")
    func gates() {
        #expect(route(active: FakeTarget(clusterID: .calder)) == .open)
        #expect(route(active: FakeTarget(status: .connecting)) == .open)
        #expect(route(active: FakeTarget(acceptsInput: false)) == .open)
        #expect(route(active: FakeTarget(kind: .command("vim x"))) == .open)
        #expect(route(dedicated: true, active: FakeTarget()) == .open)
    }

    @Test("Repeated clicks reuse the chip's own tab instead of piling up")
    func reuse() {
        let finished = FakeTarget(kind: .command("squeue --me"), status: .exited(.code(0)))
        #expect(route(active: finished, sessions: [finished]) == .restart(finished.id))

        let htop = FakeTarget(kind: .command("htop || top"), status: .running)
        let shell = FakeTarget()
        #expect(route("htop || top", dedicated: true, active: shell, sessions: [htop, shell]) == .focus(htop.id))

        let otherCluster = FakeTarget(kind: .command("squeue --me"), clusterID: .calder, status: .exited(.code(0)))
        #expect(route(active: nil, sessions: [otherCluster]) == .open)
    }

    @Test("Typed text first clears a half-typed command line")
    func keystrokes() {
        #expect(TerminalQuickCommandRouter.keystrokes(for: "sinfo") == "\u{05}\u{15}sinfo\n")
    }
}

// MARK: - Manager

@MainActor
private final class LaunchRecorder {
    var launches: [[String]] = []
}

@MainActor
@Suite("Terminal manager", .serialized)
struct TerminalManagerTests {
    private let settings = makeSettings(.aire)

    private func makeManager(
        masterAlive: Bool = true,
        recorder: LaunchRecorder = LaunchRecorder(),
        stallHintDelay: TimeInterval = 60
    ) -> TerminalManager {
        _ = NSApplication.shared
        let backend = TerminalSessionBackend(
            masterIsAlive: { _ in masterAlive },
            launch: { _, arguments, _ in recorder.launches.append(arguments) },
            stallHintDelay: stallHintDelay
        )
        return TerminalManager(backend: backend)
    }

    @Test("A connection that never delivers a byte is flagged as stalled, and the flag clears on data")
    func stalledConnection() async throws {
        let recorder = LaunchRecorder()
        let manager = makeManager(recorder: recorder, stallHintDelay: 0.05)
        let session = try #require(manager.openShell(settings: settings))
        try await waitUntil("the stall hint") { session.isConnectionStalled }
        #expect(session.isConnectionStalled)
        #expect(session.status == .connecting)
        session.terminalView.dataReceived(slice: Array("$ ".utf8)[...])
        #expect(!session.isConnectionStalled)
        #expect(session.status == .running)
    }

    @Test("Connecting until ssh delivers a byte, then running; exit is decoded")
    func connectingState() async throws {
        let recorder = LaunchRecorder()
        let manager = makeManager(recorder: recorder)
        let session = try #require(manager.openShell(settings: settings))
        #expect(session.status == .connecting)
        try await waitUntil("ssh to launch") { !recorder.launches.isEmpty }
        let argv = try #require(recorder.launches.first)
        #expect(argv.contains("ControlMaster=no"))
        #expect(session.status == .connecting)
        #expect(!session.isLiveShell)

        session.terminalView.dataReceived(slice: Array("$ ".utf8)[...])
        #expect(session.status == .running)
        #expect(session.isLiveShell)

        session.processDidExit(rawWaitStatus: 65280)
        #expect(session.status == .exited(.code(255)))
        #expect(!session.isRunning)
    }

    @Test("No live master: ssh is never launched and the tab says not connected")
    func noMaster() async throws {
        let recorder = LaunchRecorder()
        let manager = makeManager(masterAlive: false, recorder: recorder)
        let session = try #require(manager.openShell(settings: settings))
        try await waitUntil("the pre-flight to finish") { session.status != .connecting }
        #expect(session.status == .sessionUnavailable)
        #expect(recorder.launches.isEmpty)
        #expect(manager.runningSessionCount == 0)
    }

    @Test("At most six running tabs per cluster; the seventh explains instead of starting ssh")
    func sessionBudget() throws {
        let manager = makeManager()
        for _ in 0..<TerminalManager.maxConcurrentSessions {
            #expect(manager.openShell(settings: settings) != nil)
        }
        #expect(manager.openShell(settings: settings) == nil)
        #expect(manager.open(command: "vim x", title: "vim x", settings: settings) == nil)
        #expect(manager.sessions.count == TerminalManager.maxConcurrentSessions)
        #expect(manager.notice == .sessionLimit(limit: TerminalManager.maxConcurrentSessions))

        manager.close(try #require(manager.sessions.first))
        #expect(manager.notice == nil)
        #expect(manager.openShell(settings: settings) != nil)
    }

    /// The cap is what sshd's MaxSessions leaves once the collector, one
    /// file-browser command and the transfer queue have their sessions.
    @Test("The tab cap leaves MaxSessions room for the collector, the file browser and transfers")
    func sessionBudgetDerivation() {
        #expect(TerminalManager.serverSessionLimit == 10)
        #expect(TerminalManager.reservedAppSessions == 2 + FileActivity.maxConcurrentTransfers)
        #expect(TerminalManager.maxConcurrentSessions + TerminalManager.reservedAppSessions == TerminalManager.serverSessionLimit)
        #expect(TerminalManager.maxConcurrentSessions == 6)
    }

    @Test("A finished chip tab is re-run in place, not duplicated")
    func chipReuse() async throws {
        let recorder = LaunchRecorder()
        let manager = makeManager(recorder: recorder)
        manager.runQuickCommand("squeue --me", title: "My jobs", settings: settings)
        let first = try #require(manager.sessions.first)
        try await waitUntil("the first launch") { recorder.launches.count == 1 }
        first.processDidExit(rawWaitStatus: 0)

        manager.runQuickCommand("squeue --me", title: "My jobs", settings: settings)
        #expect(manager.sessions.count == 1)
        #expect(first.status == .connecting)
        try await waitUntil("the second launch") { recorder.launches.count == 2 }
        #expect(recorder.launches.count == 2)
    }

    @Test("Tailing: the same job reuses its tab; an array remainder has no log to tail")
    func tails() {
        let manager = makeManager()
        let job = Job(jobId: "123", state: "RUNNING", stdoutPath: "/scratch/out.log")
        manager.openTail(job: job, settings: settings)
        manager.openTail(job: job, settings: settings)
        #expect(manager.sessions.count == 1)

        let remainder = Job(
            jobId: "8248307",
            state: "PENDING",
            stdoutPath: "/scratch/out_8248307_4294967294.log",
            arrayJobID: 8248307,
            arrayPendingTasks: "2-5",
            pendingTaskCount: 4
        )
        manager.openTail(job: remainder, settings: settings)
        #expect(manager.sessions.count == 1)
    }

    @Test("Closing asks first only when work could be lost")
    func closeConfirmationRule() async throws {
        let recorder = LaunchRecorder()
        let manager = makeManager(recorder: recorder)
        let shell = try #require(manager.openShell(settings: settings))
        #expect(!shell.closingEndsWork)
        try await waitUntil("the first launch") { recorder.launches.count == 1 }
        shell.terminalView.dataReceived(slice: Array("$ ".utf8)[...])
        #expect(shell.closingEndsWork)

        manager.openTail(job: Job(jobId: "7", state: "RUNNING", stdoutPath: "/x.log"), settings: settings)
        let tail = try #require(manager.sessions.last)
        try await waitUntil("the second launch") { recorder.launches.count == 2 }
        tail.terminalView.dataReceived(slice: Array("log".utf8)[...])
        #expect(tail.status == .running)
        #expect(!tail.closingEndsWork)
    }
}
