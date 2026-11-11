import HPCCore
import Foundation
import Testing
import UserNotifications
@testable import AIREMonitorApp

// Fakes for driving ClusterSession and AppModel without processes, timers,
// the Keychain or the notification center. Everything a session writes goes
// to a TemporaryProjectRoot.

struct TestTimeout: Error {}

/// Polls `condition` on the main actor until it holds, yielding so the
/// session's tasks can run. Fails the test after `timeout`.
///
/// The timeout is generous on purpose: conditions normally hold within
/// milliseconds, but the whole suite runs in parallel and other suites
/// (offscreen window layout, terminal views) can hold the main actor for
/// seconds, during which neither this poll nor the code under test runs.
@MainActor
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(60),
    _ condition: @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        if clock.now > deadline {
            Issue.record("Timed out waiting for \(description)")
            throw TestTimeout()
        }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
}

/// Lets queued main-actor work (tasks spawned by the code under test) run.
@MainActor
func settle(_ iterations: Int = 20) async {
    for _ in 0..<iterations {
        await Task.yield()
    }
    try? await Task.sleep(nanoseconds: 10_000_000)
}

/// One suspension point a test releases (or a cancellation fails).
final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var outcome: Result<Void, Error>?

    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(with: outcome)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = result
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }
}

final class FakeBackend: ClusterBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var collectResults: [Result<ClusterSnapshot, Error>] = []
    private var fallbackCollect: Result<ClusterSnapshot, Error>
    private var holdCollections = false
    private var collectGates: [TestGate] = []
    private var _collectCalls: [ConnectionSettings] = []
    private var _skipStorageFlags: [Bool] = []
    private var _jobUsageFlags: [Bool] = []
    private var _completedCollections = 0

    private var loginResults: [Result<LoginResult, Error>] = []
    private var holdLogins = false
    private var loginGates: [TestGate] = []
    private var _loginCalls: [(settings: ConnectionSettings, password: String, forceReplace: Bool, renewJumpHost: Bool)] = []
    private var _stopMasterCalls: [(settings: ConnectionSettings, stopJumpIfUnused: Bool)] = []
    private var stopMasterResult: Result<StopMasterReport, Error> = .success(StopMasterReport(statusLines: ["stopped the session"]))
    private var _adoptCalls: [ConnectionSettings] = []
    private var adoption: MasterAdoption = .adopted
    private var remoteCommandResult = ProcessResult(stdout: "", stderr: "", exitCode: 0)
    private var _remoteCommands: [String] = []

    init(snapshot: ClusterSnapshot) {
        fallbackCollect = .success(snapshot)
    }

    init(failure: Error) {
        fallbackCollect = .failure(failure)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var collectCalls: [ConnectionSettings] { locked { _collectCalls } }
    /// `skipStorage` of every collector run, in order.
    var skipStorageFlags: [Bool] { locked { _skipStorageFlags } }
    var jobUsageFlags: [Bool] { locked { _jobUsageFlags } }
    var completedCollections: Int { locked { _completedCollections } }
    var loginCalls: [(settings: ConnectionSettings, password: String, forceReplace: Bool, renewJumpHost: Bool)] { locked { _loginCalls } }
    var stopMasterCalls: [ConnectionSettings] { locked { _stopMasterCalls.map(\.settings) } }
    var stopJumpFlags: [Bool] { locked { _stopMasterCalls.map(\.stopJumpIfUnused) } }
    var adoptCalls: [ConnectionSettings] { locked { _adoptCalls } }
    var remoteCommands: [String] { locked { _remoteCommands } }

    func setStopMasterResult(_ result: Result<StopMasterReport, Error>) {
        locked { stopMasterResult = result }
    }

    func setAdoption(_ outcome: MasterAdoption) {
        locked { adoption = outcome }
    }

    func setRemoteCommandResult(_ result: ProcessResult) {
        locked { remoteCommandResult = result }
    }

    func setFallback(_ result: Result<ClusterSnapshot, Error>) {
        locked { fallbackCollect = result }
    }

    func enqueueCollect(_ result: Result<ClusterSnapshot, Error>) {
        locked { collectResults.append(result) }
    }

    func enqueueLogin(_ result: Result<LoginResult, Error>) {
        locked { loginResults.append(result) }
    }

    /// A sign-in that succeeds by reusing masters that were already up: the
    /// password is never sent anywhere.
    func enqueueReusedLogin() {
        enqueueLogin(.success(LoginResult(
            output: "HPC-STATUS: reusing the existing session\nHPC-STATUS: connected",
            passwordVerified: false
        )))
    }

    /// Collections started from now on wait for `releaseCollections()`.
    func holdCollections(_ hold: Bool) {
        locked { holdCollections = hold }
    }

    func releaseCollections() {
        let gates = locked { () -> [TestGate] in
            holdCollections = false
            defer { collectGates.removeAll() }
            return collectGates
        }
        gates.forEach { $0.finish(.success(())) }
    }

    func holdLogins(_ hold: Bool) {
        locked { holdLogins = hold }
    }

    func releaseLogins() {
        let gates = locked { () -> [TestGate] in
            holdLogins = false
            defer { loginGates.removeAll() }
            return loginGates
        }
        gates.forEach { $0.finish(.success(())) }
    }

    func collectSnapshot(settings: ConnectionSettings, skipStorage: Bool, jobUsage: Bool) async throws -> ClusterSnapshot {
        let gate = locked { () -> TestGate? in
            _collectCalls.append(settings)
            _skipStorageFlags.append(skipStorage)
            _jobUsageFlags.append(jobUsage)
            guard holdCollections else {
                return nil
            }
            let gate = TestGate()
            collectGates.append(gate)
            return gate
        }
        if let gate {
            try? await gate.wait()
        }
        let result = locked { () -> Result<ClusterSnapshot, Error> in
            _completedCollections += 1
            return collectResults.isEmpty ? fallbackCollect : collectResults.removeFirst()
        }
        return try result.get()
    }

    func login(
        settings: ConnectionSettings,
        password: String,
        forceReplace: Bool,
        renewJumpHost: Bool,
        onStatus: (@Sendable (String) -> Void)?
    ) async throws -> LoginResult {
        let gate = locked { () -> TestGate? in
            _loginCalls.append((settings, password, forceReplace, renewJumpHost))
            guard holdLogins else {
                return nil
            }
            let gate = TestGate()
            loginGates.append(gate)
            return gate
        }
        onStatus?("waiting for Duo approval on your phone (\(settings.clusterName))")
        if let gate {
            try await withTaskCancellationHandler {
                try await gate.wait()
            } onCancel: {
                gate.finish(.failure(CancellationError()))
            }
        }
        // By default a fresh sign-in: the password was sent and accepted.
        let result = locked {
            loginResults.isEmpty
                ? .success(LoginResult(output: "HPC-STATUS: Connected to login1", passwordVerified: true))
                : loginResults.removeFirst()
        }
        return try result.get()
    }

    func runRemoteCommand(settings: ConnectionSettings, command: String, timeout: TimeInterval) async throws -> ProcessResult {
        locked {
            _remoteCommands.append(command)
            return remoteCommandResult
        }
    }

    func stopMaster(settings: ConnectionSettings, stopJumpIfUnused: Bool) async throws -> StopMasterReport {
        let result = locked { () -> Result<StopMasterReport, Error> in
            _stopMasterCalls.append((settings, stopJumpIfUnused))
            return stopMasterResult
        }
        return try result.get()
    }

    func adoptMaster(settings: ConnectionSettings) async -> MasterAdoption {
        locked {
            _adoptCalls.append(settings)
            return adoption
        }
    }

    func isMasterAlive(settings: ConnectionSettings) async -> Bool {
        true
    }
}

@MainActor
final class ManualScheduler: RefreshScheduling {
    private(set) var interval: TimeInterval?
    private var tick: (@MainActor () -> Void)?

    var isScheduled: Bool { tick != nil }

    func schedule(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.tick = tick
    }

    func cancel() {
        interval = nil
        tick = nil
    }

    func fire() {
        tick?()
    }
}

@MainActor
final class RecordingNotifier: ClusterEventNotifying {
    var jobChanges: [JobStateChanges] = []
    var gpuAlerts: [Int] = []
    var gpuAlertResult = true

    func notifyJobChanges(_ changes: JobStateChanges, cluster: ClusterProfile) {
        jobChanges.append(changes)
    }

    func notifyGPUBecameAvailable(cluster: ClusterProfile, idleCount: Int, gpuModel: String?, partitions: [String]) async -> Bool {
        gpuAlerts.append(idleCount)
        return gpuAlertResult
    }
}

@MainActor
final class FakeHost: ClusterSessionHost {
    var signInConfiguration: SignInConfiguration
    var notifyWhenGPUFrees = false
    var sampleJobUsage = false
    let notifier = RecordingNotifier()
    var persistenceProblems: [String?] = []

    init(projectRoot: String, route: ConnectionRoute = .directVPN, username: String = testUsername) {
        signInConfiguration = SignInConfiguration(
            username: username,
            route: route,
            jumpHostname: HPCDefaults.jumpHostname,
            duoOption: HPCDefaults.duoOption,
            projectRoot: projectRoot
        )
    }

    var eventNotifier: ClusterEventNotifying? { notifier }

    func session(_ session: ClusterSession, persistenceProblem: String?) {
        persistenceProblems.append(persistenceProblem)
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_791_000_000)) {
        current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

final class FakeCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String]
    private let readFailure: KeychainError?
    private var _reads: [String] = []
    /// While set, reads wait for `releaseReads` — like a read sitting
    /// behind a SecurityAgent prompt nobody has answered yet.
    private var readGate: DispatchSemaphore?
    private var heldReads = 0
    private var releasedFailure: KeychainError?

    init(items: [String: String] = [:], readFailure: KeychainError? = nil) {
        self.items = items
        self.readFailure = readFailure
    }

    var reads: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _reads
    }

    var storedItems: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    func password(for account: String) -> Result<String?, KeychainError> {
        lock.lock()
        _reads.append(account)
        let gate = readGate
        if gate != nil {
            heldReads += 1
        }
        lock.unlock()
        gate?.wait()
        lock.lock()
        defer { lock.unlock() }
        if let failure = releasedFailure ?? readFailure {
            return .failure(failure)
        }
        return .success(items[account])
    }

    /// Reads from now on wait for `releaseReads(answering:)`.
    func holdReads() {
        lock.lock()
        readGate = DispatchSemaphore(value: 0)
        lock.unlock()
    }

    /// Lets every held read finish; `failure` (e.g. a denied prompt)
    /// answers them and every later read.
    func releaseReads(answering failure: KeychainError? = nil) {
        lock.lock()
        let gate = readGate
        let waiting = heldReads
        readGate = nil
        heldReads = 0
        releasedFailure = failure
        lock.unlock()
        for _ in 0..<waiting {
            gate?.signal()
        }
    }

    func save(_ password: String, for account: String) throws {
        lock.lock()
        items[account] = password
        lock.unlock()
    }

    func delete(account: String) throws {
        lock.lock()
        items[account] = nil
        lock.unlock()
    }

    func exists(account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return items[account] != nil
    }
}

@MainActor
final class FakeNotificationPoster: NotificationPosting {
    var status: UNAuthorizationStatus = .notDetermined
    var requestError: Error?
    var grantOnRequest = true
    private(set) var requestCount = 0
    private(set) var posted: [LocalNotification] = []

    func install(delegate: UNUserNotificationCenterDelegate) {}

    func authorizationStatus() async -> UNAuthorizationStatus {
        status
    }

    func requestAuthorization() async throws -> Bool {
        requestCount += 1
        if let requestError {
            throw requestError
        }
        status = grantOnRequest ? .authorized : .denied
        return grantOnRequest
    }

    func post(_ notification: LocalNotification) {
        posted.append(notification)
    }
}

/// A complete, error-free snapshot of a tiny cluster. `storage: nil` is a
/// refresh that did not collect storage (`--skip-storage`).
func makeSnapshot(
    cluster: ClusterID = .aire,
    collectedAt: String = "2026-10-13T12:00:00Z",
    jobs: [Job] = [],
    nodes: [NodeSummary] = [],
    storage: [StorageSummary]? = [],
    errors: [String] = [],
    remoteHostname: String = "login1.example"
) -> ClusterSnapshot {
    ClusterSnapshot(
        collectedAt: collectedAt,
        storageSkipped: storage == nil,
        cluster: SnapshotClusterInfo(id: cluster.rawValue, name: cluster.rawValue.capitalized),
        remote: RemoteInfo(host: "\(cluster.rawValue).leeds.ac.uk", hostname: remoteHostname, user: testUsername),
        jobs: jobs,
        partitions: [PartitionSummary(partition: "gpu", nodeCount: 2, state: "idle")],
        nodes: nodes,
        storage: storage,
        errors: errors
    )
}

/// A terminal manager that never starts ssh: its pre-flight always finds
/// a master, and "launching" does nothing. An opened shell stays
/// `connecting`, which counts as running (what a reconnect would end).
/// Opening one needs `NSApplication.shared` (a terminal view).
@MainActor
func makeTestTerminalManager() -> TerminalManager {
    TerminalManager(backend: TerminalSessionBackend(
        masterIsAlive: { _ in true },
        launch: { _, _, _ in },
        stallHintDelay: 3600
    ))
}

/// A file browser whose transfers hang in their first remote step (the
/// size probe) until `release()`, then fail — an scp in flight over the
/// master of the settings it was queued under, with no process behind it.
/// Downloads would land in a private temp folder; the failed size probe
/// means none is ever written.
@MainActor
final class HeldTransfers {
    private let gate = TestGate()
    let files: FileBrowserModel

    init(downloadsDirectory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("hpc-monitor-tests-downloads-\(UUID().uuidString)", isDirectory: true)) {
        let gate = self.gate
        let runner = FakeRemoteRunner { _, _, _ in
            try? await gate.wait()
            return ProcessResult(stdout: "", stderr: "lost connection", exitCode: 1)
        }
        files = FileBrowserModel(service: RemoteFileService(runner: runner))
        files.activity.downloadsDirectory = downloadsDirectory
        files.activity.revealDownloads = { _ in }
    }

    var activity: FileActivity { files.activity }

    /// Queues one download under `settings` and waits until it runs.
    func startDownload(settings: ConnectionSettings) async throws {
        activity.enqueueDownloads(
            [RemoteFileEntry(name: "results.tar", path: "/users/\(settings.username)/results.tar", kind: .file, size: 50_000_000_000)],
            settings: settings,
            clusterName: settings.clusterName
        )
        try await waitUntil("transfer running") { self.activity.transfers.contains { $0.phase == .running } }
    }

    /// Lets the held transfer finish (as failed) and waits until none is
    /// waiting or running.
    func release() async throws {
        gate.finish(.success(()))
        try await waitUntil("transfer ended") { !self.activity.hasActiveTransfers }
    }
}

/// One session wired to fakes, rooted in a private temp directory.
@MainActor
final class SessionHarness {
    let root: TemporaryProjectRoot
    let backend: FakeBackend
    let scheduler = ManualScheduler()
    let host: FakeHost
    let clock = TestClock()
    let session: ClusterSession

    /// `files`: the session's file browser (default: one whose service is
    /// never used by these tests).
    init(
        cluster: ClusterID = .aire,
        backend: FakeBackend? = nil,
        route: ConnectionRoute = .directVPN,
        files: FileBrowserModel? = nil
    ) throws {
        root = try TemporaryProjectRoot()
        self.backend = backend ?? FakeBackend(snapshot: makeSnapshot(cluster: cluster))
        host = FakeHost(projectRoot: root.path, route: route)
        let clock = self.clock
        session = ClusterSession(
            profile: catalogProfile(cluster),
            isEnabled: true,
            hostname: nil,
            backend: self.backend,
            scheduler: scheduler,
            terminals: makeTestTerminalManager(),
            files: files ?? FileBrowserModel(),
            now: { clock.now }
        )
        session.host = host
    }

    var cache: SnapshotCache {
        SnapshotCache(projectRoot: root.path, clusterID: session.id)
    }

    /// Starts the session and waits for its startup probe to finish.
    func startAndSettle() async throws {
        session.start()
        try await waitUntil("startup probe") { self.session.hasCompletedFirstProbe && !self.session.refreshInFlight }
    }

    /// Fires one background tick and waits until that refresh completed.
    func tick() async throws {
        let before = backend.completedCollections
        scheduler.fire()
        try await waitUntil("background refresh") {
            self.backend.completedCollections > before && !self.session.refreshInFlight
        }
    }

    func appState() -> ClusterAppState? {
        session.flushCacheWrites()
        return cache.loadAppState()
    }

    deinit {
        root.remove()
    }
}
