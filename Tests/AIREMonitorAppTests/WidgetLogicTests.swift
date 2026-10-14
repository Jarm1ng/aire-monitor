import Foundation
import HPCCore
import Testing

// The desktop widget's decisions, tested through HPCCore (the widget is an
// executable target with SwiftUI views; everything that decides whether it
// may collect, what it may execute and how a child process is bounded lives
// in HPCCore so it can be tested here). No network, no ssh: processes are
// /bin/sh one-liners and files go to private temp directories.

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func iso(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

/// A private temp directory, removed by the caller's `defer`.
private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("hpc-widget-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - app_state.json

@Suite("Widget app_state lease")
struct WidgetAppStateTests {
    @Test("The contract's JSON decodes")
    func decodesContract() throws {
        let json = #"{"updatedAt":"2027-01-15T08:00:00Z","enabled":true,"paused":false,"live":true,"refreshInterval":10}"#
        let state = try #require(WidgetAppState.decode(Data(json.utf8)))
        #expect(state.enabled)
        #expect(!state.paused)
        #expect(state.live)
        #expect(state.refreshInterval == 10)
        #expect(state.writtenAt(fileModificationDate: nil) == SlurmTimestamp.parse("2027-01-15T08:00:00Z"))
    }

    @Test("Missing flags take the values that never let the widget collect behind the app")
    func lenientDefaults() throws {
        let state = try #require(WidgetAppState.decode(Data("{}".utf8)))
        #expect(state.enabled)
        #expect(!state.paused)
        #expect(!state.live)
        #expect(state.refreshInterval == HPCDefaults.refreshInterval)
    }

    @Test("Not an object is no lease", arguments: ["", "[]", "garbage", "\"text\""])
    func garbage(text: String) {
        #expect(WidgetAppState.decode(Data(text.utf8)) == nil)
    }

    @Test("Absurd intervals are sanitised", arguments: [
        (0.0, HPCDefaults.refreshInterval),
        (-5, HPCDefaults.refreshInterval),
        (60, 60),
        (1_000_000, 3600)
    ] as [(Double, TimeInterval)])
    func intervals(raw: Double, expected: Double) throws {
        let json = #"{"refreshInterval":\#(raw)}"#
        let state = try #require(WidgetAppState.decode(Data(json.utf8)))
        #expect(state.refreshInterval == expected)
    }

    @Test("The lease lasts three refresh periods, at least 90 s")
    func leaseWindow() {
        #expect(WidgetAppState(refreshInterval: 10).leaseWindow == 90)
        #expect(WidgetAppState(refreshInterval: 60).leaseWindow == 180)
    }

    @Test("No record: the widget's stale-snapshot fallback applies")
    func noRecord() {
        #expect(WidgetAppOwnership.resolve(nil, fileModificationDate: nil, now: now) == .none)
    }

    @Test("A fresh record means the app owns collection")
    func freshRecord() {
        let live = WidgetAppState(updatedAt: iso(now.addingTimeInterval(-20)), live: true)
        let failing = WidgetAppState(updatedAt: iso(now.addingTimeInterval(-20)), live: false, refreshInterval: 40)
        #expect(WidgetAppOwnership.resolve(live, fileModificationDate: nil, now: now) == .live(refreshInterval: 10))
        #expect(WidgetAppOwnership.resolve(failing, fileModificationDate: nil, now: now) == .retrying(refreshInterval: 40))
        #expect(WidgetAppOwnership.live(refreshInterval: 10).appOwnsCollection)
        #expect(WidgetAppOwnership.retrying(refreshInterval: 40).appOwnsCollection)
    }

    @Test("An app in backoff keeps its lease for three of its (longer) periods")
    func backoffStretchesLease() {
        let state = WidgetAppState(updatedAt: iso(now.addingTimeInterval(-150)), live: false, refreshInterval: 60)
        #expect(WidgetAppOwnership.resolve(state, fileModificationDate: nil, now: now) == .retrying(refreshInterval: 60))
    }

    @Test("A record older than the lease means the app is gone")
    func staleRecord() {
        let state = WidgetAppState(updatedAt: iso(now.addingTimeInterval(-91)), live: true)
        #expect(WidgetAppOwnership.resolve(state, fileModificationDate: nil, now: now) == .none)
    }

    @Test("Paused and off hold whatever the age: the app writes nothing while paused")
    func pausedNeverExpires() {
        let paused = WidgetAppState(updatedAt: iso(now.addingTimeInterval(-86_400)), paused: true)
        let off = WidgetAppState(updatedAt: iso(now.addingTimeInterval(-86_400)), enabled: false)
        #expect(WidgetAppOwnership.resolve(paused, fileModificationDate: nil, now: now) == .paused)
        #expect(WidgetAppOwnership.resolve(off, fileModificationDate: nil, now: now) == .off)
        #expect(WidgetAppOwnership.paused.appOwnsCollection)
        #expect(WidgetAppOwnership.off.appOwnsCollection)
    }

    @Test("A record from the future proves nothing")
    func futureRecord() {
        let state = WidgetAppState(updatedAt: iso(now.addingTimeInterval(600)), live: true)
        #expect(WidgetAppOwnership.resolve(state, fileModificationDate: nil, now: now) == .none)
        let slightSkew = WidgetAppState(updatedAt: iso(now.addingTimeInterval(30)), live: true)
        #expect(WidgetAppOwnership.resolve(slightSkew, fileModificationDate: nil, now: now) == .live(refreshInterval: 10))
    }

    @Test("An unparsable updatedAt falls back to the file's mtime")
    func mtimeFallback() {
        let state = WidgetAppState(updatedAt: "yesterday", live: true)
        #expect(WidgetAppOwnership.resolve(state, fileModificationDate: now.addingTimeInterval(-5), now: now) == .live(refreshInterval: 10))
        #expect(WidgetAppOwnership.resolve(state, fileModificationDate: now.addingTimeInterval(-500), now: now) == .none)
        #expect(WidgetAppOwnership.resolve(state, fileModificationDate: nil, now: now) == .none)
    }
}

// MARK: - Collection decision

@Suite("Widget collection decision")
struct WidgetCollectionDecisionTests {
    @Test("While the app owns the cluster the widget never collects", arguments: [
        WidgetAppOwnership.live(refreshInterval: 10),
        .retrying(refreshInterval: 60),
        .paused,
        .off
    ])
    func appOwned(ownership: WidgetAppOwnership) {
        for manual in [false, true] {
            for age in [nil, 5.0, 3_600] as [TimeInterval?] {
                let facts = WidgetFeedFacts(ownership: ownership, snapshotAge: age, manual: manual)
                #expect(WidgetFeedPolicy.decide(facts, now: now) == .deferToApp)
            }
        }
    }

    @Test("An unreadable file someone else wrote is reported, not overwritten")
    func unreadableForeignFile() {
        let facts = WidgetFeedFacts(snapshotAge: nil, unreadableForeignFile: true, manual: true)
        #expect(WidgetFeedPolicy.decide(facts, now: now) == .blockedByUnreadableFile)
    }

    @Test("A missing or stale snapshot is collected")
    func staleCollects() {
        #expect(WidgetFeedPolicy.decide(WidgetFeedFacts(snapshotAge: nil), now: now) == .collect)
        #expect(WidgetFeedPolicy.decide(WidgetFeedFacts(snapshotAge: 31), now: now) == .collect)
    }

    @Test("Fresh data the widget did not collect is left alone, even on Refresh")
    func freshForeignData() {
        // Protects an app build that predates app_state.json.
        #expect(WidgetFeedPolicy.decide(WidgetFeedFacts(snapshotAge: 5), now: now) == .notNeeded)
        #expect(WidgetFeedPolicy.decide(WidgetFeedFacts(snapshotAge: 5, manual: true), now: now) == .notNeeded)
    }

    @Test("A self-fed row keeps the refresh cadence")
    func selfFeedCadence() {
        #expect(WidgetFeedPolicy.decide(WidgetFeedFacts(snapshotAge: 11, feedingItself: true), now: now) == .collect)
        #expect(WidgetFeedPolicy.decide(WidgetFeedFacts(snapshotAge: 5, feedingItself: true), now: now) == .notNeeded)
    }

    @Test("Attempts are a refresh period apart, manual ones too")
    func minimumSpacing() {
        let lastAttempt = now.addingTimeInterval(-3)
        let auto = WidgetFeedFacts(snapshotAge: 40, lastAttempt: lastAttempt)
        let manual = WidgetFeedFacts(snapshotAge: 5, feedingItself: true, manual: true, lastAttempt: lastAttempt)
        let expected = WidgetCollectionDecision.wait(until: lastAttempt.addingTimeInterval(HPCDefaults.refreshInterval))
        #expect(WidgetFeedPolicy.decide(auto, now: now) == expected)
        #expect(WidgetFeedPolicy.decide(manual, now: now) == expected)
    }

    @Test("Backoff holds automatic attempts; a manual Refresh skips it")
    func backoff() {
        let nextAllowed = now.addingTimeInterval(120)
        let lastAttempt = now.addingTimeInterval(-60)
        let auto = WidgetFeedFacts(snapshotAge: 400, lastAttempt: lastAttempt, nextAllowed: nextAllowed)
        #expect(WidgetFeedPolicy.decide(auto, now: now) == .wait(until: nextAllowed))
        var manual = auto
        manual.manual = true
        #expect(WidgetFeedPolicy.decide(manual, now: now) == .collect)
        let expired = WidgetFeedFacts(snapshotAge: 400, lastAttempt: lastAttempt, nextAllowed: now.addingTimeInterval(-1))
        #expect(WidgetFeedPolicy.decide(expired, now: now) == .collect)
    }

    @Test("Backoff doubles from the refresh interval up to five minutes", arguments: [
        (0, 10), (1, 10), (2, 20), (3, 40), (4, 80), (5, 160), (6, 300), (100, 300)
    ] as [(Int, TimeInterval)])
    func retryDelays(failures: Int, delay: TimeInterval) {
        #expect(WidgetFeedPolicy.retryDelay(afterConsecutiveFailures: failures) == delay)
    }

    @Test("Cluster directory names", arguments: [
        ("aire", true), ("calder", true), ("bessemer-2", true), ("a_b", true),
        ("", false), (".hidden", false), ("Aire", false), ("2aire", false),
        ("../x", false), ("a b", false), (String(repeating: "a", count: 33), false)
    ] as [(String, Bool)])
    func directoryNames(name: String, valid: Bool) {
        #expect(WidgetFeedPolicy.isValidClusterDirectoryName(name) == valid)
    }
}

// MARK: - Collector record

@Suite("Widget collector record")
struct WidgetCollectorRecordTests {
    @Test("Argument values", arguments: [
        (["--timeout", "30"], "30"),
        (["--timeout=45"], "45"),
        (["--cluster-id", "aire", "--timeout"], nil),
        (["--cluster-id", "aire"], nil),
        ([], nil)
    ] as [([String], String?)])
    func argumentValue(arguments: [String], expected: String?) {
        #expect(WidgetCollector.argumentValue("--timeout", in: arguments) == expected)
    }

    @Test("Watchdog deadline is the recorded budget plus headroom", arguments: [
        ([], 50.0),
        (["--timeout", "30"], 50),
        (["--timeout=45"], 65),
        (["--timeout", "0"], 21),
        (["--timeout", "1000"], 320),
        (["--timeout", "soon"], 50)
    ] as [([String], TimeInterval)])
    func deadline(arguments: [String], expected: TimeInterval) {
        #expect(WidgetCollector.processDeadline(arguments: arguments) == expected)
    }

    @Test("Only a relative path to a file inside the checkout may run")
    func scriptPathGate() throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try Data("print()".utf8).write(to: scripts.appendingPathComponent("hpc_snapshot.py"))
        try Data("print()".utf8).write(to: outside.appendingPathComponent("evil.py"))
        try FileManager.default.createSymbolicLink(
            at: scripts.appendingPathComponent("escape.py"),
            withDestinationURL: outside.appendingPathComponent("evil.py")
        )

        let valid = try WidgetCollector.validatedScriptPath("scripts/hpc_snapshot.py", projectRoot: root.path)
        #expect(valid.hasSuffix("/scripts/hpc_snapshot.py"))
        for refused in ["", "  ", "/usr/bin/python3", "~/x.py", "../x.py", "scripts/../../x.py",
                        "scripts/escape.py", "scripts/missing.py", "scripts"] {
            #expect(throws: WidgetCollectorError.self, "\(refused)") {
                try WidgetCollector.validatedScriptPath(refused, projectRoot: root.path)
            }
        }
    }

    @Test("Loading collector.json")
    func load() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try Data("print()".utf8).write(to: scripts.appendingPathComponent("hpc_snapshot.py"))
        let directory = root.appendingPathComponent(".runtime/clusters/aire", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let recordURL = directory.appendingPathComponent("collector.json")

        #expect(WidgetCollector.load(clusterID: "aire", directory: directory.path, projectRoot: root.path) == .missing)

        try Data("not json".utf8).write(to: recordURL)
        guard case .invalid = WidgetCollector.load(clusterID: "aire", directory: directory.path, projectRoot: root.path) else {
            Issue.record("an unreadable record must be invalid")
            return
        }

        try Data(#"{"script":"scripts/hpc_snapshot.py","arguments":["--cluster-id","calder"]}"#.utf8).write(to: recordURL)
        guard case .invalid(let message) = WidgetCollector.load(clusterID: "aire", directory: directory.path, projectRoot: root.path) else {
            Issue.record("another cluster's record must be invalid")
            return
        }
        #expect(message.contains("calder"))

        try Data(#"{"updatedAt":"x","script":"scripts/hpc_snapshot.py","arguments":["--cluster-id","aire","--timeout","30","--control-path","/tmp/s"]}"#.utf8).write(to: recordURL)
        guard case .ready(let collector) = WidgetCollector.load(clusterID: "aire", directory: directory.path, projectRoot: root.path) else {
            Issue.record("a valid record must load")
            return
        }
        #expect(collector.deadline == 50)
        #expect(collector.controlPath == "/tmp/s")
        #expect(collector.scriptPath.hasSuffix("/scripts/hpc_snapshot.py"))
    }

    @Test("A missing control socket is caught before python starts")
    func missingSocket() {
        let collector = WidgetValidatedCollector(scriptPath: "/x", arguments: ["--control-path", "/tmp/hpc.sock"], deadline: 50)
        #expect(WidgetCollector.missingControlSocket(for: collector, fileExists: { _ in false }) == "/tmp/hpc.sock")
        #expect(WidgetCollector.missingControlSocket(for: collector, fileExists: { _ in true }) == nil)
        let aliasMode = WidgetValidatedCollector(scriptPath: "/x", arguments: ["--host", "aire"], deadline: 50)
        #expect(WidgetCollector.missingControlSocket(for: aliasMode, fileExists: { _ in false }) == nil)
    }

    @Test("The collector's missing-master error is recognised")
    func missingMasterMessage() {
        #expect(WidgetCollector.isMissingMasterMessage("connection lost: SSH control master is not running (log in again from the app)"))
        #expect(!WidgetCollector.isMissingMasterMessage("connection lost: SSH control master did not answer the socket probe"))
    }
}

// MARK: - Collection results

@Suite("Widget collection results")
struct WidgetCollectionResultTests {
    private func outcome(_ stdout: String, stderr: String = "", status: Int32 = 0, timedOut: Bool = false) -> WidgetProcessOutcome {
        WidgetProcessOutcome(
            terminationStatus: status,
            stdout: Data(stdout.utf8),
            stderr: Data(stderr.utf8),
            timedOut: timedOut,
            forcedCompletion: false
        )
    }

    private let snapshotJSON = #"{"schema_version":1,"collected_at":"2026-07-19T12:34:56.789012+00:00","cluster":{"id":"aire","name":"AIRE"},"jobs":[],"nodes":[],"errors":[]}"#

    @Test("Exit 0 with a decodable snapshot and no errors is clean")
    func clean() {
        let result = WidgetCollector.interpret(outcome(snapshotJSON), deadline: 50)
        #expect(result.isClean)
        #expect(result.failureMessage == nil)
        #expect(result.snapshot?.cluster?.id == "aire")
    }

    @Test("Collector errors make a result unclean and become the message")
    func collectorErrors() {
        let json = #"{"collected_at":"2026-07-19T12:34:56+00:00","errors":["connection lost: SSH control master is not running (log in again from the app)"]}"#
        let result = WidgetCollector.interpret(outcome(json, stderr: "noise", status: 1), deadline: 50)
        #expect(!result.isClean)
        #expect(result.isMissingMaster)
        #expect(result.failureMessage?.contains("noise") == false)
    }

    @Test("Undecodable output reports stderr, or the exit status")
    func undecodable() {
        let withStderr = WidgetCollector.interpret(outcome("Traceback", stderr: "ImportError: x", status: 1), deadline: 50)
        #expect(!withStderr.isClean)
        #expect(withStderr.failureMessage == "ImportError: x")
        let silent = WidgetCollector.interpret(outcome("", status: 2), deadline: 50)
        #expect(silent.failureMessage == "Refresh failed (collector exited with status 2).")
    }

    @Test("A timed-out run is never clean, even with complete JSON")
    func timedOut() {
        let result = WidgetCollector.interpret(outcome(snapshotJSON, status: 15, timedOut: true), deadline: 50)
        #expect(!result.isClean)
        #expect(result.failureMessage?.contains("timed out after 50 seconds") == true)
    }

    @Test("The collector's microsecond timestamps parse")
    func microsecondTimestamps() {
        #expect(SlurmTimestamp.parse("2026-07-19T12:34:56.789012+00:00") != nil)
        #expect(SlurmTimestamp.parse("2026-07-19T12:34:56+00:00") != nil)
        #expect(SlurmTimestamp.parse("garbage") == nil)
    }

    @Test("A stranded GPU (idle on a node whose CPUs are full) is not free")
    func strandedGPU() {
        // Live AIRE gpu018: state alloc, 24/24 CPUs, 2 of 3 L40S allocated.
        let gpu018 = NodeSummary(
            node: "gpu018", partitions: ["gpu"], state: "alloc",
            cpuAllocated: 24, cpuIdle: 0, cpuOther: 0, cpuTotal: 24,
            gres: "gpu:l40s:3(S:0-1)", gpuTotal: 3, gpuAllocated: 2, gpuIdle: 1
        )
        let fleet = GPUFleet(nodes: [gpu018])
        #expect(fleet.idle == 0)
        #expect(fleet.stranded == 1)
        #expect(fleet.modelLabel == "L40S")
    }
}

// MARK: - Process runner

@Suite("Widget process runner")
struct WidgetProcessRunnerTests {
    @Test("Exit then EOF completes once, with the output")
    func exitThenEOF() async {
        let state = WidgetRunnerState(outputLimit: 1024)
        let outcome = await withCheckedContinuation { continuation in
            state.install(continuation)
            state.processExited(status: 0)
            state.received(Data("{}".utf8), on: .stdout)
            state.received(Data(), on: .stdout)
            state.received(Data(), on: .stderr)
            // Later events are no-ops (a second resume would trap).
            state.forceFinish()
            state.processExited(status: 3)
        }
        #expect(outcome.terminationStatus == 0)
        #expect(outcome.stdout == Data("{}".utf8))
        #expect(!outcome.timedOut)
        #expect(!outcome.forcedCompletion)
        #expect(state.isFinished)
    }

    @Test("EOF then exit completes once")
    func eofThenExit() async {
        let state = WidgetRunnerState(outputLimit: 1024)
        let outcome = await withCheckedContinuation { continuation in
            state.install(continuation)
            state.received(Data("out".utf8), on: .stdout)
            state.received(Data("err".utf8), on: .stderr)
            state.received(Data(), on: .stderr)
            state.received(Data(), on: .stdout)
            #expect(!state.isFinished)
            state.processExited(status: 1)
        }
        #expect(outcome.terminationStatus == 1)
        #expect(outcome.stderr == Data("err".utf8))
    }

    @Test("A pipe held open after exit is force-completed, not waited on")
    func forcedAfterExit() async {
        let state = WidgetRunnerState(outputLimit: 1024)
        let outcome = await withCheckedContinuation { continuation in
            state.install(continuation)
            state.received(Data("{}".utf8), on: .stdout)
            state.processExited(status: 0)
            #expect(!state.markTimedOutIfRunning())
            state.forceFinish()
        }
        #expect(outcome.terminationStatus == 0)
        #expect(outcome.forcedCompletion)
        #expect(!outcome.timedOut)
    }

    @Test("Output beyond the limit is dropped")
    func outputLimit() async {
        let state = WidgetRunnerState(outputLimit: 4)
        let outcome = await withCheckedContinuation { continuation in
            state.install(continuation)
            state.received(Data("abcdef".utf8), on: .stdout)
            state.received(Data("gh".utf8), on: .stdout)
            state.received(Data(), on: .stdout)
            state.received(Data(), on: .stderr)
            state.processExited(status: 0)
        }
        #expect(outcome.stdout == Data("abcd".utf8))
    }

    @Test("A real child's output and status are captured")
    func capturesOutput() async throws {
        let outcome = try await WidgetProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf hello; printf oops >&2; exit 3"],
            deadline: 20,
            killGracePeriod: 0.5
        )
        #expect(outcome.terminationStatus == 3)
        #expect(String(decoding: outcome.stdout, as: UTF8.self) == "hello")
        #expect(String(decoding: outcome.stderr, as: UTF8.self) == "oops")
        #expect(!outcome.timedOut)
        #expect(!outcome.forcedCompletion)
    }

    /// The orphans below sleep far longer than any plausible scheduling
    /// delay on a loaded 3-core CI runner, so the checks rest on
    /// `forcedCompletion` (the run stopped waiting for a pipe the orphan
    /// still held) instead of a tight wall-clock bound; each prints its pid
    /// so the test can reap it afterwards.
    private func reapOrphan(printedIn data: Data) {
        let digits = String(decoding: data, as: UTF8.self).filter(\.isNumber)
        if let pid = Int32(digits), pid > 1 {
            kill(pid, SIGKILL)
        }
    }

    @Test("A child that exits while a descendant holds its pipe still completes promptly")
    func descendantHoldsPipe() async throws {
        let started = Date()
        let outcome = try await WidgetProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf done; sleep 60 & echo $! >&2; exit 0"],
            deadline: 120,
            killGracePeriod: 0.5
        )
        reapOrphan(printedIn: outcome.stderr)
        #expect(Date().timeIntervalSince(started) < 30)
        #expect(outcome.terminationStatus == 0)
        #expect(String(decoding: outcome.stdout, as: UTF8.self) == "done")
        #expect(outcome.forcedCompletion)
        #expect(!outcome.timedOut)
    }

    @Test("A hung child is terminated at the deadline")
    func hungChild() async throws {
        let started = Date()
        let outcome = try await WidgetProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec sleep 30"],
            deadline: 0.5,
            killGracePeriod: 0.5
        )
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(outcome.timedOut)
        #expect(outcome.terminationStatus != 0)
    }

    @Test("A child ignoring SIGTERM is killed, and its orphan cannot wedge the run")
    func ignoresTerm() async throws {
        let started = Date()
        let outcome = try await WidgetProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; sleep 60 & echo $!; wait; exit 0"],
            deadline: 0.5,
            killGracePeriod: 0.5
        )
        reapOrphan(printedIn: outcome.stdout)
        #expect(Date().timeIntervalSince(started) < 30)
        #expect(outcome.timedOut)
        #expect(outcome.terminationStatus != 0)
        #expect(outcome.forcedCompletion)
    }
}

// MARK: - Opening the app

@Suite("Widget app launcher")
struct WidgetAppLauncherTests {
    private let root = "/Users/u/aire_server_app"

    @Test("A running app is brought forward, never rebuilt or started twice")
    func activatesRunningApp() {
        let plan = WidgetAppLauncher.plan(projectRoot: root, runningBundlePaths: [nil], fileExists: { _ in true })
        #expect(plan == .activate(index: 0))
    }

    @Test("Of several running copies, the one from this checkout wins")
    func prefersOwnBundle() {
        let plan = WidgetAppLauncher.plan(
            projectRoot: root,
            runningBundlePaths: ["/Users/u/other/.runtime/AIREMonitorApp.app", root + "/.runtime/AIREMonitorApp.app/"],
            fileExists: { _ in true }
        )
        #expect(plan == .activate(index: 1))
    }

    @Test("Not running: always the launcher, even when a bundle exists (it may be stale)")
    func runsLauncherWhenNotRunning() {
        let existing: Set<String> = [root + "/.runtime/AIREMonitorApp.app", root + "/scripts/run_macos_app.sh"]
        let plan = WidgetAppLauncher.plan(projectRoot: root, runningBundlePaths: [], fileExists: { existing.contains($0) })
        #expect(plan == .runLauncher(script: root + "/scripts/run_macos_app.sh"))
        let bare = WidgetAppLauncher.plan(projectRoot: root, runningBundlePaths: [], fileExists: { _ in false })
        #expect(bare == .missingLauncher(script: root + "/scripts/run_macos_app.sh"))
    }

    @Test("Launcher exit statuses read as the build script means them")
    func failureMessages() {
        #expect(WidgetAppLauncher.failureMessage(status: 0) == nil)
        #expect(WidgetAppLauncher.failureMessage(status: 75)?.contains("Another build of this checkout") == true)
        #expect(WidgetAppLauncher.failureMessage(status: 1)?.contains(".runtime/swift-build.log") == true)
    }

    @Test("The bundle identifier is the one build_bundle.sh stamps on the app")
    func bundleIdentifierMatchesBuildScript() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/build_bundle.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        #expect(text.contains("BUNDLE_ID=\"\(WidgetAppLauncher.appBundleIdentifier)\""))
        #expect(text.contains("75 when another"))
    }
}
