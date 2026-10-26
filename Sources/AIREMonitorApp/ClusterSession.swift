import HPCCore
import AppKit
import Combine
import SwiftUI

/// Shared sign-in inputs. Every cluster combines them with its own profile
/// and host to build `ConnectionSettings`; the university account, route
/// and Duo choice are the same for all clusters.
struct SignInConfiguration: Sendable, Equatable {
    var username: String
    var route: ConnectionRoute
    var jumpHostname: String
    var duoOption: String
    var projectRoot: String
}

/// What a session needs from the app-wide coordinator. Kept as a narrow
/// protocol so sessions never reach into the coordinator's other state, and
/// so tests can host a session without an AppModel.
@MainActor
protocol ClusterSessionHost: AnyObject {
    var signInConfiguration: SignInConfiguration { get }
    var notifyWhenGPUFrees: Bool { get }
    /// Sample what running jobs use on their compute nodes (GPU, CPU,
    /// memory) about once a minute.
    var sampleJobUsage: Bool { get }
    /// Where job and GPU alerts go; nil disables them.
    var eventNotifier: ClusterEventNotifying? { get }
    /// A cache write kind keeps failing for this session (nil: it recovered).
    func session(_ session: ClusterSession, persistenceProblem: String?)
}

/// One-glance connection state of a cluster, for badges, sidebar rows, the
/// overview, the menu bar and notifications.
enum ClusterConnectionState: Equatable {
    case disabled
    case notConnected
    case queued
    case connecting
    case live
    case paused
    /// A snapshot is on screen but the session is not confirmed live
    /// (startup before the first probe, or repeated refresh failures).
    case cached

    var label: String {
        switch self {
        case .disabled: return "Off"
        case .notConnected: return "Not connected"
        case .queued: return "Waiting"
        case .connecting: return "Signing in"
        case .live: return "Live"
        case .paused: return "Paused"
        case .cached: return "Cached"
        }
    }

    var color: Color {
        switch self {
        case .disabled, .notConnected: return .gray
        case .queued, .connecting, .paused, .cached: return .orange
        case .live: return .green
        }
    }

    var isBusy: Bool {
        self == .queued || self == .connecting
    }
}

enum LoginOutcome: Equatable {
    /// Signed in. `passwordVerified` is false when every leg reused a
    /// master that was already up: the password was never sent, so it
    /// proves nothing and must not be saved or clear a "rejected" flag.
    case succeeded(passwordVerified: Bool)
    /// The server rejected the password. The coordinator stops any queued
    /// logins: retrying the same wrong password on the next cluster would
    /// only move the account closer to a lockout.
    case passwordRejected
    /// The server demanded a password change; the same applies everywhere.
    case passwordExpired
    /// The shared rash leg failed; every queued cluster would retry it.
    case jumpHostFailed
    /// Nobody answered the Duo push before the watchdog: the next cluster's
    /// push would go unanswered too.
    case timedOut
    /// The password was accepted, then the Duo push was declined or timed
    /// out on the phone (helper exit 15). The coordinator stops the queue,
    /// but the saved password is fine and is never flagged as rejected.
    case duoNotApproved
    /// The user cancelled (or the app is quitting).
    case cancelled
    case failed
    case skipped
}

/// Per-cluster dashboard UI state. Lives on the session (not in view
/// @State) so switching between clusters in the sidebar keeps each
/// cluster's tab, filters and open sheet exactly where the user left them.
@MainActor
final class ClusterDashboardState: ObservableObject {
    @Published var selectedTab: DashboardTab = .jobs
    @Published var jobsShowDetails = false
    @Published var selectedJob: Job?
    @Published var partitionsShowDetails = false
    @Published var nodesFilter: NodeFilter = .all
    @Published var nodesShowDetails = false
}

/// The most recent failed refresh, kept until the next success. Set on every
/// failure — automatic, startup probe or manual — unlike `errorMessage`,
/// which only user actions raise, so the status strip can say why a cluster
/// is not updating even when nobody pressed Refresh.
struct RefreshFailure: Equatable {
    enum Kind: Equatable {
        /// Local setup: collector script missing, project root wrong, no
        /// username. Signing in again cannot fix it.
        case configuration
        /// The round trip worked but Slurm failed (scheduler down or
        /// overloaded). The session stays live.
        case clusterSide
        /// No usable round trip: master gone, network, VPN.
        case transport
    }

    let kind: Kind
    /// One line for the status strip.
    let message: String
    /// Full collector / ssh output for a Details disclosure; may be empty.
    let detail: String
    /// Failures in a row, 1 for the first.
    let consecutiveCount: Int
    let date: Date
}

/// Everything about one monitored cluster: its SSH session, refresh loop,
/// snapshot cache, history, job notifications, GPU alerts, terminals and
/// file browser. Sessions are fully independent — a failing or paused
/// Calder never affects AIRE, and vice versa.
///
/// Rendering budget: every refresh applies its results in one synchronous
/// block (no await between state changes), and every published property is
/// assigned only when its value actually changes. A background refresh that
/// brings identical data publishes nothing; one with new data costs one
/// render pass. Disk writes go to a background queue (ClusterCacheWriter).
@MainActor
final class ClusterSession: ObservableObject, Identifiable {
    let profile: ClusterProfile
    nonisolated var id: ClusterID { profile.id }

    /// User preference: monitor this cluster at all. A disabled cluster
    /// never refreshes and never takes part in "Connect all".
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else {
                return
            }
            isEnabled ? resumeAfterEnable() : suspendAfterDisable()
            writeAppState()
        }
    }

    /// Login host as typed under Advanced; defaults to the profile's. Takes
    /// effect at the next sign-in, never on the live session (see
    /// `activeConnection`).
    @Published var hostname: String

    @Published private(set) var isLoggingIn = false
    @Published private(set) var isLoginQueued = false
    /// A refresh the user should see is running: the startup or
    /// route-change probe, the refresh after sign-in, or one they asked for.
    /// Background ticks run silently (`refreshInFlight`), so a 10 s refresh
    /// does not flip spinners and repaint the window twice.
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoggedIn = false {
        didSet {
            guard isLoggedIn != oldValue else {
                return
            }
            if !isLoggedIn {
                // Not signed in: the next sign-in (or probe) uses whatever
                // the form says now.
                activeConnection = nil
            }
            writeAppState()
        }
    }
    @Published private(set) var hasCachedSnapshot = false
    @Published var statusMessage = "Not connected"
    @Published var errorMessage: String?
    @Published private(set) var loginProgress: String?
    @Published private(set) var snapshot: ClusterSnapshot? {
        didSet {
            // Computed once per snapshot, not once per view body.
            gpuFleet = GPUFleet(nodes: snapshot?.nodes ?? [])
        }
    }
    /// GPU pools of the current snapshot — the one source for every idle /
    /// allocated / unavailable GPU figure the app shows.
    private(set) var gpuFleet = GPUFleet(nodes: [])
    /// True once a refresh (the startup probe included) has finished, either
    /// way. Before that a cached cluster is "checking", not "not connected".
    /// Reset when the route changes or monitoring is switched back on.
    @Published private(set) var hasCompletedFirstProbe = false
    /// The last refresh failed because no ControlMaster exists (only a
    /// sign-in can fix that, so refreshing again is pointless).
    private(set) var lastFailureWasMissingMaster = false
    /// Set while Slurm itself is failing over a healthy connection, e.g.
    /// "Slurm error on Calder: Section 'jobs' failed with exit 1". The
    /// session stays live (there is nothing to sign in again for); the
    /// sections that failed show the previous data, and the snapshot's
    /// warnings say which. Cleared by the next complete refresh.
    @Published private(set) var schedulerIssue: String?
    /// See `RefreshFailure`. nil after a successful refresh (and after a
    /// sign-in, route change or switching monitoring off or on, which make
    /// the old failure moot).
    @Published private(set) var lastRefreshFailure: RefreshFailure?
    /// `collected_at` of the snapshot the storage rows on screen came from.
    /// Storage is collected only every few minutes (see
    /// `wantsStorage(for:)`); in between, refreshes keep the previous rows,
    /// so the rows can be older than the snapshot. nil before any rows.
    @Published private(set) var storageCollectedAt: String?
    @Published private(set) var history: [TrendPoint] = []
    /// What each running job used at the last sample, keyed by `Job.jobId`
    /// (see `wantsJobUsage`). Jobs that stopped running drop out.
    @Published private(set) var jobUsage: [String: JobUsageSummary] = [:]
    /// Recent samples per running job, for the trend in its details.
    @Published private(set) var jobUsageHistory = JobUsageHistory()
    /// True while the background refresh timer is suspended by the user.
    /// Login always clears it; resume triggers an immediate refresh.
    @Published private(set) var isPaused = false {
        didSet {
            if isPaused != oldValue {
                writeAppState()
            }
        }
    }
    @Published private(set) var currentRefreshInterval: TimeInterval
    /// The identity (account, host, route, jump host) the live session was
    /// established under — by a sign-in, or by a probe that found a master.
    /// Refreshes, terminals, file operations and Cancel job all use it, so
    /// typing in the sign-in form or a host field never re-targets a live
    /// session; edits apply at the next sign-in. Nil while not signed in.
    @Published private(set) var activeConnection: ConnectionSettings?
    /// When a live session was lost without the user asking — the master
    /// vanished or stopped answering (sleep, a network change, the VPN
    /// ending) — as opposed to a Disconnect. The coordinator uses it to
    /// report the drop and, if allowed, sign in again. Cleared once the
    /// session is live again, signed out, or re-targeted.
    @Published private(set) var droppedAt: Date?

    let dashboard = ClusterDashboardState()
    let terminals: TerminalManager
    let files: FileBrowserModel

    weak var host: ClusterSessionHost?

    private let backend: ClusterBackend
    private let scheduler: RefreshScheduling
    private let now: () -> Date
    private lazy var cacheWriter = ClusterCacheWriter(clusterID: profile.id) { [weak self] operation, problem in
        Task { @MainActor in
            self?.cacheWriteProblemChanged(operation, problem)
        }
    }

    static let consecutiveFailuresBeforeLogout = 3
    private var backgroundRefreshInterval: TimeInterval { HPCDefaults.refreshInterval }
    private var maximumRefreshInterval: TimeInterval { HPCDefaults.maximumRefreshInterval }
    /// The job baseline is rewritten whenever job states change, and at
    /// least this often otherwise so its `updatedAt` stays an honest "last
    /// observed" across a relaunch.
    private static let jobBaselineRewriteInterval: TimeInterval = 60

    /// Any refresh in flight, visible or not.
    private(set) var refreshInFlight = false
    private var inFlightShowsErrors = false
    /// Failed refreshes of any kind in a row: drives the backoff.
    private var consecutiveFailedRefreshes = 0
    /// Transport failures in a row that leave the master's health unknown:
    /// drive the 3-strikes logout. Slurm errors and refused sessions prove
    /// the master is alive and do not count.
    private var transportFailuresTowardLogout = 0
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    /// Set by refreshAfterMutation() when a refresh cannot start right away;
    /// consumed exactly once by a refresh completion path (success or
    /// failure) to launch one follow-up refresh, so a post-mutation refresh
    /// request is never silently dropped.
    private var pendingRefresh = false
    private var lastCollectorArguments: [String]?
    private var gpuAlerts = GPUFreeAlertTracker()
    private var jobBaseline: JobStateSnapshot?
    private var lastJobBaselineWrite: Date?
    private var historyTimestamps = Set<String>()
    /// Lines in snapshot_history.jsonl; compaction rewrites it to `history`.
    private var historyLinesInLog = 0
    /// The last identity this session was live under, kept after a logout
    /// so its master can still be retired when the identity changes.
    private var lastActiveConnection: ConnectionSettings?
    /// Earlier identities (account, host or route) whose masters are still
    /// up after the session moved to a new one, kept because terminals or
    /// file transfers were running — any of them may ride on such a master
    /// (a transfer keeps the settings it was queued under), and a plain
    /// Connect never closes running work. Closed once no terminal of this
    /// cluster runs and no transfer is waiting or running
    /// (`retireSupersededIfIdle`), by a later sign-in that finds none, or by
    /// the next Disconnect, whose confirmation counts every terminal and
    /// transfer of the cluster. Never holds the identity the session is live
    /// on: going live on one drops it from here (`markLive`).
    private var supersededConnections: [ConnectionSettings] = []
    /// Set by a successful Disconnect (to the calm status line it showed),
    /// cleared by the next sign-in, a refresh that finds a master, a route
    /// change or switching monitoring back on. While set, the background
    /// timer stays off — the app knows the master is gone, so probing it
    /// every minute would only turn the calm "Signed out" status into a
    /// failure count that keeps climbing — and a probe the user asks for
    /// that finds no master puts that status back instead of reporting a
    /// failure.
    private var signedOutStatusLine: String?
    private var signedOutByUser: Bool { signedOutStatusLine != nil }
    /// Cache write kinds currently failing, with the reason each reported.
    /// The coordinator keeps one persistence message per session, so it is
    /// cleared only when every kind has recovered.
    private var failingCacheWrites: [CacheWriteOperation: String] = [:]
    /// `jobIdentity` of the last successful refresh, to notice that the
    /// session now watches another account (see `processJobChanges`).
    private var observedIdentity: String?
    private var activeLoginTask: Task<LoginResult, Error>?
    private var loginCancelRequested = false
    private(set) var hasStarted = false

    /// Control paths whose master this session has already adopted (or
    /// built by signing in) during this run: the reuse-only cleanup runs at
    /// most once per master.
    private var adoptedControlPaths = Set<String>()
    private var adoptionTask: Task<Void, Never>?

    /// Storage (df, quota, lfs) changes slowly and is the slowest, most
    /// hang-prone part of a collection, so most refreshes skip it. It is
    /// collected when due (the first refresh after start or sign-in), on a
    /// manual Refresh, while the Storage tab is open, and otherwise once the
    /// rows are older than this.
    static let storageRefreshInterval: TimeInterval = 300
    /// After a refresh asked for storage and got none (an earlier
    /// df/quota/lfs still stuck, or the budget ran out before the section),
    /// automatic refreshes wait this long before asking again.
    static let storageRetryAfterMiss: TimeInterval = 60
    /// How long after the last complete storage collection a row cut short
    /// may still show its previous figures (see `mergeStorage`). Long
    /// enough to ride out a retry or two; after that a volume that keeps
    /// failing shows as unreadable instead of as stale figures.
    static let storageCarryLimit: TimeInterval = 600
    private var storageDue = true
    /// When the last refresh that asked for job usage started.
    private var lastJobUsageRequest: Date?
    /// Job usage costs an ssh to each node running one of the user's jobs,
    /// so it is sampled about once a minute, not on every 10 s refresh.
    static let jobUsageInterval: TimeInterval = 60
    private var lastStorageCollection: Date?
    private var lastStorageMiss: Date?
    /// Labels that have had a row with real figures: an optional volume
    /// whose row was cut short ("not-collected") is shown only for these,
    /// so AIRE's absent Flash never appears as an unreadable row.
    private var storageLabelsWithFigures = Set<String>()
    /// The account the storage rows on screen, and the bookkeeping above,
    /// belong to: the username of the refresh that last merged them, or the
    /// collector's `remote.user` for rows read back from the cache. nil
    /// while unknown. See `claimStorageRows(for:)`.
    private var storageAccount: String?

    private static let iso8601 = ISO8601DateFormatter()

    init(
        profile: ClusterProfile,
        isEnabled: Bool,
        hostname: String?,
        backend: ClusterBackend = MonitorService(),
        scheduler: RefreshScheduling = TimerRefreshScheduler(),
        terminals: TerminalManager = TerminalManager(),
        files: FileBrowserModel = FileBrowserModel(),
        now: @escaping () -> Date = Date.init
    ) {
        self.profile = profile
        self.terminals = terminals
        self.files = files
        self.isEnabled = isEnabled
        let trimmed = hostname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.hostname = trimmed.isEmpty ? profile.defaultHostname : trimmed
        self.currentRefreshInterval = HPCDefaults.refreshInterval
        self.backend = backend
        self.scheduler = scheduler
        self.now = now
        files.attach(session: self)
    }

    // MARK: - Derived state

    var displayName: String { profile.displayName }

    var connectionState: ClusterConnectionState {
        if !isEnabled {
            return .disabled
        }
        if isLoggingIn {
            return .connecting
        }
        if isLoginQueued {
            return .queued
        }
        if isPaused {
            return .paused
        }
        if isLoggedIn {
            return .live
        }
        if hasCachedSnapshot {
            return .cached
        }
        return .notConnected
    }

    /// The effective background refresh cadence, e.g. "10s". Grows with
    /// exponential backoff while refreshes keep failing.
    var refreshIntervalText: String {
        "\(Int(currentRefreshInterval))s"
    }

    /// The connection to use for remote work right now: the live session's
    /// identity when signed in, otherwise what the next sign-in would use.
    /// The project root always follows the current setting (it locates
    /// scripts and runtime files, not the remote identity).
    var settings: ConnectionSettings {
        let configured = configuredSettings
        guard var active = activeConnection else {
            return configured
        }
        active.projectRoot = configured.projectRoot
        return active
    }

    /// What the sign-in form and host field describe now — the identity the
    /// next sign-in will use.
    var configuredSettings: ConnectionSettings {
        settings(using: host?.signInConfiguration ?? SignInConfiguration(
            username: "",
            route: .directVPN,
            jumpHostname: HPCDefaults.jumpHostname,
            duoOption: HPCDefaults.duoOption,
            projectRoot: FileManager.default.currentDirectoryPath
        ))
    }

    func settings(using configuration: SignInConfiguration) -> ConnectionSettings {
        ConnectionSettings(
            clusterID: profile.id,
            clusterName: profile.displayName,
            username: configuration.username.trimmingCharacters(in: .whitespacesAndNewlines),
            // A blank host falls back to the profile default so the
            // collector args, control-socket hash and starter scripts agree.
            hostname: Self.nonEmpty(hostname, default: profile.defaultHostname),
            route: configuration.route,
            jumpHostname: Self.nonEmpty(configuration.jumpHostname, default: HPCDefaults.jumpHostname),
            duoOption: Self.nonEmpty(configuration.duoOption, default: HPCDefaults.duoOption),
            projectRoot: configuration.projectRoot.trimmingCharacters(in: .whitespacesAndNewlines),
            storage: profile.storage
        )
    }

    /// True when the form (account, host, route or jump host) no longer
    /// matches the live session: the change applies at the next sign-in.
    var signInChangesPending: Bool {
        guard let activeConnection else {
            return false
        }
        return activeConnection.controlPath != configuredSettings.controlPath
    }

    private var cache: SnapshotCache {
        SnapshotCache(projectRoot: settings.projectRoot, clusterID: profile.id)
    }

    /// Status line shown while paused. Deliberately age-free: while paused
    /// no timer fires and no @Published property changes, so a relative age
    /// here would freeze at whatever it said when last rendered. The
    /// adjacent StalenessBadge ticks the snapshot age live on its own.
    var pausedStatusText: String {
        guard let collectedAt = snapshot?.collectedAt, !collectedAt.isEmpty else {
            return "Paused — no snapshot collected yet"
        }
        return "Paused — last snapshot shown"
    }

    /// Legacy one-line GPU summary: startable idle GPUs and all configured
    /// GPUs across every model, plus the model label ("H200 + L40"). Views
    /// that show per-model figures should use `gpuFleet.pools` instead.
    var gpuAvailability: (idle: Int, total: Int, model: String?) {
        (gpuFleet.idle, gpuFleet.total, gpuFleet.modelLabel)
    }

    #if DEBUG
    /// Preview/test hook: shows the given state without touching SSH, the
    /// cache directory or timers. The state counts as settled (the first
    /// probe has completed), so presentations do not read "Checking".
    func installPreviewState(
        snapshot: ClusterSnapshot?,
        history: [TrendPoint] = [],
        isLoggedIn: Bool,
        isLoggingIn: Bool = false,
        loginProgress: String? = nil,
        statusMessage: String? = nil,
        errorMessage: String? = nil,
        hasCompletedFirstProbe: Bool = true,
        lastRefreshFailure: RefreshFailure? = nil,
        isPaused: Bool = false
    ) {
        self.lastRefreshFailure = lastRefreshFailure
        self.isPaused = isPaused
        self.snapshot = snapshot
        self.storageCollectedAt = snapshot?.storage == nil ? nil : snapshot?.collectedAt
        setHistory(history)
        self.hasCachedSnapshot = snapshot != nil
        self.isLoggedIn = isLoggedIn
        self.isLoggingIn = isLoggingIn
        self.loginProgress = loginProgress
        self.errorMessage = errorMessage
        self.hasCompletedFirstProbe = hasCompletedFirstProbe
        if let statusMessage {
            self.statusMessage = statusMessage
        }
    }
    #endif

    // MARK: - Lifecycle

    /// Loads this cluster's cache and starts monitoring. Called once by the
    /// coordinator (from applicationDidFinishLaunching) after `host` is set.
    func start() {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        let cache = self.cache
        loadHistory(from: cache)
        jobBaseline = cache.loadJobStateSnapshot()
        if let cachedSnapshot = cache.loadLatestSnapshot() {
            snapshot = cachedSnapshot
            hasCachedSnapshot = true
            // The rows may predate the cached snapshot by up to the storage
            // interval; the first refresh collects storage anyway.
            noteCachedStorageRows(of: cachedSnapshot)
            statusMessage = "Cached snapshot available • checking SSH session"
            if jobBaseline == nil, let observed = SlurmTimestamp.parse(cachedSnapshot.collectedAt) {
                // Seed with the true observation time, so the first refresh
                // diffs (or summarises) against what was last seen.
                jobBaseline = JobStateSnapshot(jobs: cachedSnapshot.jobs, observedAt: Self.iso8601.string(from: observed))
            }
        }
        guard isEnabled else {
            statusMessage = "Monitoring is off for \(displayName)"
            writeAppState()
            return
        }
        set(\.hasCompletedFirstProbe, false)
        startBackgroundRefresh()
        refresh(reason: .probe)
        // Now, not only on a change: a paused/off record a previous run left
        // behind must be replaced as soon as this run owns the cluster.
        writeAppState()
    }

    /// Re-reads history and the cached snapshot after the project root (and
    /// with it the runtime directory) changed, carries the in-memory state
    /// into the new root when it has none, and moves the widget lease.
    func projectRootDidChange(from oldRoot: String) {
        lastCollectorArguments = nil
        guard hasStarted else {
            return
        }
        cacheWriter.removeAppStateNow(from: SnapshotCache(projectRoot: oldRoot, clusterID: profile.id))
        let cache = self.cache
        let log = cache.loadHistoryLog()
        if log.points.isEmpty {
            if !history.isEmpty {
                cacheWriter.rewriteHistory(history, to: cache)
                historyLinesInLog = history.count
            }
        } else {
            setHistory(log.points)
            historyLinesInLog = log.lineCount
            if log.needsCompaction {
                cacheWriter.rewriteHistory(history, to: cache)
                historyLinesInLog = history.count
            }
        }
        if let snapshot {
            cacheWriter.saveSnapshot(snapshot, to: cache)
        } else if let cached = cache.loadLatestSnapshot() {
            noteCachedStorageRows(of: cached)
            snapshot = cached
            set(\.hasCachedSnapshot, true)
        }
        if let jobBaseline {
            cacheWriter.saveJobStates(jobBaseline, to: cache)
        }
        if isLoggedIn {
            saveCollectorArgumentsIfChanged(settings)
        }
        writeAppState()
    }

    /// Stops everything and flushes state for app termination: the history
    /// log is compacted if it grew and the job baseline saved. The widget
    /// lease of a plain monitored cluster is removed so the widget can take
    /// over collection immediately; a paused or switched-off cluster keeps
    /// (a final copy of) its record instead, because the widget honours
    /// paused/off at any age — deleting it would let the widget start
    /// polling a cluster the user paused the moment the app quits.
    func prepareForTermination() {
        stopBackgroundRefresh()
        refreshGeneration += 1
        refreshTask?.cancel()
        adoptionTask?.cancel()
        guard hasStarted else {
            return
        }
        let cache = self.cache
        if let jobBaseline {
            cacheWriter.saveJobStates(jobBaseline, to: cache)
        }
        if historyLinesInLog > history.count {
            cacheWriter.rewriteHistory(history, to: cache)
        }
        // Both synchronous: they wait for every write queued above.
        if isPaused || !isEnabled {
            // Not live any more: nothing feeds the cluster once the app
            // is gone.
            cacheWriter.saveAppStateNow(appState(live: false), to: cache)
        } else {
            cacheWriter.removeAppStateNow(from: cache)
        }
    }

    /// Rewrites the widget lease (app_state.json). Called when the session
    /// starts (replacing a paused/off record a previous run left behind),
    /// on every state change the widget cares about, after every refresh
    /// attempt — the first probe included — and on the coordinator's
    /// heartbeat while nothing else happens (paused or switched-off
    /// clusters never refresh).
    func writeAppState() {
        guard hasStarted else {
            return
        }
        cacheWriter.saveAppState(appState(live: isEnabled && isLoggedIn), to: cache)
    }

    private func appState(live: Bool) -> ClusterAppState {
        ClusterAppState(
            updatedAt: now(),
            enabled: isEnabled,
            paused: isPaused,
            live: live,
            refreshInterval: currentRefreshInterval
        )
    }

    /// Waits until every queued cache write has landed. Tests only.
    func flushCacheWrites() {
        cacheWriter.sync()
    }

    private func resumeAfterEnable() {
        signedOutStatusLine = nil
        consecutiveFailedRefreshes = 0
        transportFailuresTowardLogout = 0
        updateRefreshInterval(to: backgroundRefreshInterval)
        set(\.hasCompletedFirstProbe, false)
        set(\.lastRefreshFailure, nil)
        set(\.statusMessage, "Checking for a live \(displayName) session…")
        startBackgroundRefresh()
        refresh(reason: .probe)
    }

    private func suspendAfterDisable() {
        stopBackgroundRefresh()
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshInFlight = false
        inFlightShowsErrors = false
        set(\.isRefreshing, false)
        set(\.isLoginQueued, false)
        set(\.isLoggedIn, false)
        set(\.errorMessage, nil)
        set(\.schedulerIssue, nil)
        set(\.lastRefreshFailure, nil)
        set(\.statusMessage, "Monitoring is off for \(displayName)")
    }

    /// One cache write kind started failing (`problem`) or recovered (nil).
    /// The writer reports each kind once, so the session keeps the set: the
    /// coordinator holds a single message per session, and one kind
    /// recovering (the small app_state.json still fits on a nearly full
    /// disk) must not clear the warning while another still fails — that
    /// one would never be reported again. Internal for tests.
    func cacheWriteProblemChanged(_ operation: CacheWriteOperation, _ problem: String?) {
        failingCacheWrites[operation] = problem
        host?.session(self, persistenceProblem: Self.persistenceProblemMessage(
            failing: failingCacheWrites,
            clusterName: displayName,
            clusterID: id
        ))
    }

    /// The one persistence warning for every failing kind, most important
    /// first (what the widget shows, then history, then the rest); nil when
    /// nothing fails. With a single kind it reads "Cannot write AIRE's
    /// latest_snapshot.json (reason) — consequence. Check …".
    nonisolated static func persistenceProblemMessage(
        failing: [CacheWriteOperation: String],
        clusterName: String,
        clusterID: ClusterID
    ) -> String? {
        let order: [CacheWriteOperation] = [.snapshot, .history, .jobState, .appState, .collectorArguments]
        let operations = order.filter { failing[$0] != nil }
        guard let first = operations.first, let reason = failing[first] else {
            return nil
        }
        var consequences: [String] = []
        for operation in operations {
            let consequence: String
            switch operation {
            case .snapshot, .appState, .collectorArguments:
                consequence = "the desktop widget and the cached snapshot are not updating"
            case .history:
                consequence = "Trends history is not being saved"
            case .jobState:
                consequence = "job start/end tracking cannot survive a relaunch"
            }
            if !consequences.contains(consequence) {
                consequences.append(consequence)
            }
        }
        let names = operations.map(\.rawValue)
        let files = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1] : first.rawValue
        return "Cannot write \(clusterName)'s \(files) (\(reason)) — \(consequences.joined(separator: "; ")). Check free disk space and the permissions of .runtime/clusters/\(clusterID.rawValue)."
    }

    // MARK: - Login

    /// Shows the session as waiting behind another cluster's sign-in. The
    /// coordinator serializes logins so Duo pushes arrive one at a time and
    /// two logins never race to build the shared rash jump master.
    func markLoginQueued() {
        guard !isLoggingIn else {
            return
        }
        set(\.isLoginQueued, true)
        set(\.errorMessage, nil)
        set(\.loginProgress, nil)
        set(\.statusMessage, "Waiting for the previous sign-in to finish…")
        // Background refreshes would overwrite the waiting status with
        // "Not signed in…" while the user is still approving another
        // cluster's Duo push; performLogin restarts the timer either way.
        stopBackgroundRefresh()
    }

    func cancelQueuedLogin(reason: String) {
        guard isLoginQueued else {
            return
        }
        set(\.isLoginQueued, false)
        set(\.statusMessage, reason)
        startBackgroundRefresh()
    }

    /// Cancels this cluster's sign-in: a queued one is dropped; a running
    /// one has its helper processes' group sent SIGTERM right away (through
    /// the login task's cancellation handler), so a late Duo approval can no
    /// longer build a master.
    func cancelLogin() {
        if isLoginQueued {
            cancelQueuedLogin(reason: "Sign-in cancelled")
            return
        }
        guard isLoggingIn, !loginCancelRequested else {
            return
        }
        loginCancelRequested = true
        set(\.statusMessage, "Cancelling sign-in…")
        Log.login.info("\(self.id.rawValue, privacy: .public): sign-in cancelled by the user")
        activeLoginTask?.cancel()
    }

    /// Runs one interactive login for this cluster. Only the coordinator's
    /// serialized login chain calls this. `configuration` is the sign-in
    /// state captured when the login was queued, so the account the password
    /// was resolved for is the account it is sent to, even if the form is
    /// edited while earlier clusters wait for Duo.
    ///
    /// A plain sign-in reuses a healthy ControlMaster (no teardown, no Duo
    /// push); `forceReplace` — only the confirmed Reconnect and Renew all —
    /// replaces it, and `renewJumpHost` the shared rash master as well.
    func performLogin(
        password: String,
        configuration: SignInConfiguration,
        forceReplace: Bool = false,
        renewJumpHost: Bool = false
    ) async -> LoginOutcome {
        guard isLoginQueued, isEnabled, !isLoggingIn else {
            set(\.isLoginQueued, false)
            startBackgroundRefresh()
            return .skipped
        }
        isLoginQueued = false
        loginCancelRequested = false
        let loginSettings = settings(using: configuration)
        guard !loginSettings.username.isEmpty else {
            errorMessage = "Username is required."
            startBackgroundRefresh()
            return .failed
        }

        isLoggingIn = true
        // Logging in implicitly resumes monitoring: the completion paths
        // below restart the background timer, which stays disabled while
        // paused or signed out, so clear both first.
        set(\.isPaused, false)
        signedOutStatusLine = nil
        stopBackgroundRefresh()
        set(\.errorMessage, nil)
        set(\.loginProgress, nil)
        set(\.schedulerIssue, nil)
        statusMessage = loginSettings.useJumpHost
            ? "Signing in to \(displayName) through \(loginSettings.jumpHostname)"
            : "Signing in to \(loginSettings.hostname)"
        Log.login.info(
            "\(self.id.rawValue, privacy: .public): signing in as \(loginSettings.username, privacy: .private)@\(loginSettings.hostname, privacy: .private) via \(loginSettings.useJumpHost ? "rash" : "direct", privacy: .public)"
        )
        let startedAt = now()

        // Invalidate and stop any in-flight refresh so it cannot run over the
        // same ControlMaster socket while the login rebuilds the session, and
        // so its completion cannot clobber post-login state.
        refreshGeneration += 1
        let inFlightRefresh = refreshTask
        inFlightRefresh?.cancel()
        if let inFlightRefresh {
            await inFlightRefresh.value
        }
        refreshTask = nil
        refreshInFlight = false
        inFlightShowsErrors = false
        set(\.isRefreshing, false)
        // Likewise a reuse-only adoption still checking the old master: it
        // must not race the starter over the same socket.
        if let adoption = adoptionTask {
            adoption.cancel()
            await adoption.value
            adoptionTask = nil
        }

        // A sign-in under a different identity (account, host or route)
        // retires the previous identity's master — but only once the new
        // sign-in has succeeded (see `retireEarlierIdentities`). Closing it
        // first would end every terminal on it before knowing whether the
        // new login works, and a failed, cancelled or Duo-less attempt
        // would leave no session at all. The two control paths differ, so
        // the masters never contend for one socket meanwhile.
        let previousIdentity = (activeConnection ?? lastActiveConnection)
            .flatMap { $0.controlPath == loginSettings.controlPath ? nil : $0 }
        if loginCancelRequested {
            return finishCancelledLogin()
        }

        let backend = self.backend
        let loginTask = Task<LoginResult, Error> {
            try await backend.login(
                settings: loginSettings,
                password: password,
                forceReplace: forceReplace,
                renewJumpHost: renewJumpHost
            ) { [weak self] status in
                Task { @MainActor in
                    guard let self, self.isLoggingIn, !self.loginCancelRequested else {
                        return
                    }
                    self.set(\.loginProgress, status)
                    self.set(\.statusMessage, status)
                }
            }
        }
        activeLoginTask = loginTask

        do {
            let result = try await withTaskCancellationHandler {
                try await loginTask.value
            } onCancel: {
                loginTask.cancel()
            }
            activeLoginTask = nil
            consecutiveFailedRefreshes = 0
            transportFailuresTowardLogout = 0
            updateRefreshInterval(to: backgroundRefreshInterval)
            lastFailureWasMissingMaster = false
            set(\.isLoggedIn, true)
            set(\.droppedAt, nil)
            set(\.activeConnection, loginSettings)
            lastActiveConnection = loginSettings
            // The starter itself just cleaned up anything older releases
            // left beside this master; no separate adoption is needed.
            adoptedControlPaths.insert(loginSettings.controlPath)
            storageDue = true
            set(\.lastRefreshFailure, nil)
            set(\.statusMessage, Self.loginSummary(from: result.output, clusterName: displayName))
            set(\.loginProgress, nil)
            set(\.hasCompletedFirstProbe, true)
            isLoggingIn = false
            Log.login.info(
                "\(self.id.rawValue, privacy: .public): signed in after \(Int(self.now().timeIntervalSince(startedAt)), privacy: .public)s (password \(result.passwordVerified ? "checked" : "not needed: existing sessions reused", privacy: .public))"
            )
            saveCollectorArgumentsIfChanged(loginSettings)
            // A sign-in under a different account or host must not leave the
            // previous identity's folder listing on screen.
            files.reconcileConnectionIdentity()
            retireEarlierIdentities(previousIdentity, current: loginSettings, replacedByForce: forceReplace)
            refresh(reason: .login)
            return .succeeded(passwordVerified: result.passwordVerified)
        } catch {
            activeLoginTask = nil
            if loginCancelRequested || Task.isCancelled {
                return finishCancelledLogin()
            }
            set(\.isLoggedIn, false)
            isLoggingIn = false
            set(\.loginProgress, nil)
            set(\.hasCompletedFirstProbe, true)
            errorMessage = error.localizedDescription
            switch error {
            case MonitorError.duoNotApproved:
                set(\.statusMessage, "Duo approval was not completed for \(displayName)")
            case MonitorError.existingSessionUnresponsive:
                // Left running on purpose (it may still carry terminals);
                // replacing it is the confirmed Reconnect's job.
                set(\.statusMessage, "\(displayName)'s existing session did not answer — Reconnect… replaces it")
            default:
                set(\.statusMessage, "Sign-in to \(displayName) failed")
            }
            Log.login.error(
                "\(self.id.rawValue, privacy: .public): sign-in failed after \(Int(self.now().timeIntervalSince(startedAt)), privacy: .public)s: \(error.localizedDescription, privacy: .public)"
            )
            startBackgroundRefresh()
            switch error {
            case MonitorError.passwordRejected:
                return .passwordRejected
            case MonitorError.passwordExpired:
                return .passwordExpired
            case MonitorError.jumpHostFailed:
                return .jumpHostFailed
            case MonitorError.loginTimedOut:
                return .timedOut
            case MonitorError.duoNotApproved:
                return .duoNotApproved
            default:
                return .failed
            }
        }
    }

    private func finishCancelledLogin() -> LoginOutcome {
        loginCancelRequested = false
        isLoggingIn = false
        set(\.loginProgress, nil)
        set(\.errorMessage, nil)
        // A forced re-login may already have closed the previous master;
        // the quiet probe below finds out (and goes live again if it
        // survived).
        set(\.isLoggedIn, false)
        set(\.hasCompletedFirstProbe, true)
        set(\.statusMessage, "Sign-in cancelled")
        startBackgroundRefresh()
        refresh(reason: .automatic)
        return .cancelled
    }

    /// After a successful sign-in as `current`: closes the master of the
    /// identity it replaced (`previous`) and of any identity kept earlier.
    /// Nothing returns to them, and left alone each would linger until
    /// ControlPersist's 24 h idle limit.
    ///
    /// Running work is the exception: terminals, and transfers waiting or
    /// running (each scp rides the master of the settings it was queued
    /// under, and a waiting one would start over a closed master and fail).
    /// A plain sign-in promises that nothing running closes without a
    /// confirmation, and the session does not track which master each one
    /// rides on, so while any runs the old masters are kept
    /// (`supersededConnections`) and retired once none does
    /// (`retireSupersededIfIdle`). The confirmed Reconnect
    /// (`replacedByForce`) already said its terminals and transfers close.
    private func retireEarlierIdentities(_ previous: ConnectionSettings?, current: ConnectionSettings, replacedByForce: Bool) {
        var earlier: [ConnectionSettings] = []
        for candidate in supersededConnections + [previous].compactMap({ $0 })
        where candidate.controlPath != current.controlPath
            && !earlier.contains(where: { $0.controlPath == candidate.controlPath }) {
            earlier.append(candidate)
        }
        guard !earlier.isEmpty else {
            supersededConnections = []
            return
        }
        let work = workThatMayRideEarlierMasters
        if !replacedByForce, work.terminals > 0 || work.transfers > 0 {
            supersededConnections = earlier
            Log.login.info(
                "\(self.id.rawValue, privacy: .public): kept \(earlier.count, privacy: .public) earlier identity master(s): \(work.terminals, privacy: .public) terminal(s) and \(work.transfers, privacy: .public) transfer(s) still running"
            )
            return
        }
        supersededConnections = []
        Task {
            for target in earlier {
                await self.stopMaster(target, reason: "the sign-in identity changed")
            }
        }
    }

    /// Running terminals, and transfers waiting or running, of this
    /// cluster: the work an earlier identity's master may still carry. The
    /// same work the Disconnect and Reconnect confirmations count
    /// (`SessionWork`).
    private var workThatMayRideEarlierMasters: (terminals: Int, transfers: Int) {
        (terminals.runningSessionCount, files.activity.transfers.filter(\.isActive).count)
    }

    /// Retires the masters `retireEarlierIdentities` kept for their running
    /// work once no terminal of this cluster runs and no transfer waits or
    /// runs any more. Checked after every successful refresh, so an old
    /// identity's master outlives its last terminal or transfer by one
    /// refresh, not by ControlPersist's 24 h.
    ///
    /// Never the master the session is live on: `markLive` already drops
    /// that identity from the list, and this checks again, because closing
    /// it would cut every terminal and transfer of the live session without
    /// a word and cost a new Duo sign-in.
    private func retireSupersededIfIdle() {
        if let live = activeConnection?.controlPath {
            supersededConnections.removeAll { $0.controlPath == live }
        }
        let work = workThatMayRideEarlierMasters
        guard !supersededConnections.isEmpty, work.terminals == 0, work.transfers == 0 else {
            return
        }
        let earlier = supersededConnections
        supersededConnections = []
        Task {
            for target in earlier {
                await self.stopMaster(target, reason: "the sign-in identity changed; its last terminal or transfer has ended")
            }
        }
    }

    /// Called when the route changes. Each route has its own ControlMaster
    /// socket, so the session built for the previous route is no longer
    /// "connected" under the new one: its master is closed, the connected
    /// state dropped and the new route's socket probed. A master that is
    /// already alive there reconnects instantly; otherwise the user signs in.
    func connectionSettingsDidChange() {
        guard !isLoggingIn, isEnabled else {
            return
        }
        let previous = activeConnection ?? lastActiveConnection
        set(\.isLoggedIn, false)
        set(\.droppedAt, nil)
        lastActiveConnection = nil
        // A new route is a fresh question ("is a master there?"), probed
        // and then watched like any other.
        signedOutStatusLine = nil
        consecutiveFailedRefreshes = 0
        transportFailuresTowardLogout = 0
        updateRefreshInterval(to: backgroundRefreshInterval)
        lastFailureWasMissingMaster = false
        set(\.errorMessage, nil)
        set(\.loginProgress, nil)
        set(\.schedulerIssue, nil)
        set(\.lastRefreshFailure, nil)
        set(\.hasCompletedFirstProbe, false)
        set(\.statusMessage, "Route changed — checking for a live \(displayName) session…")
        adoptionTask?.cancel()
        adoptionTask = nil
        files.reconcileConnectionIdentity()
        // Drop any refresh still running over the previous route's master:
        // its success would otherwise mark the session live under a route
        // that has no master yet.
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshInFlight = false
        inFlightShowsErrors = false
        set(\.isRefreshing, false)
        if let previous, previous.controlPath != configuredSettings.controlPath {
            Task {
                await self.stopMaster(previous, reason: "the route changed")
            }
        }
        refresh(reason: .probe)
    }

    /// Signs out of this cluster: closes its ControlMaster (ending every
    /// terminal and transfer multiplexed over it — callers confirm first),
    /// keeps the last snapshot on screen as cached data.
    ///
    /// `stopJumpIfUnused` (the coordinator passes it when no other cluster
    /// is live or signing in on the rash route) also closes the shared jump
    /// master — but the stop helper keeps it whenever anything else still
    /// rides on it, which is reported as an ordinary outcome.
    func disconnect(stopJumpIfUnused: Bool = false) async {
        if isLoggingIn || isLoginQueued {
            cancelLogin()
            return
        }
        let target = activeConnection ?? lastActiveConnection ?? settings
        // Masters kept for their running work under an earlier identity go
        // too: the Disconnect confirmation counted every running terminal
        // and active transfer of this cluster, theirs included.
        let superseded = supersededConnections.filter { $0.controlPath != target.controlPath }
        supersededConnections = []
        // No timer tick may probe the master while it is being closed (a
        // probe that won the race would mark the session live again), nor
        // afterwards: see `signedOutByUser`.
        stopBackgroundRefresh()
        supersedeRefresh()
        adoptionTask?.cancel()
        adoptionTask = nil
        set(\.isLoggedIn, false)
        set(\.droppedAt, nil)
        lastActiveConnection = nil
        set(\.schedulerIssue, nil)
        set(\.errorMessage, nil)
        set(\.lastRefreshFailure, nil)
        lastFailureWasMissingMaster = true
        set(\.hasCompletedFirstProbe, true)
        set(\.statusMessage, "Signing out of \(displayName)…")
        for earlier in superseded {
            await stopMaster(earlier, reason: "Disconnect (earlier identity)")
        }
        let outcome = await stopMaster(target, reason: "Disconnect", stopJumpIfUnused: stopJumpIfUnused)
        if isLoggingIn || isLoginQueued {
            // A sign-in started while the master was closing: it owns the
            // session's state from here on.
            return
        }
        // Anything the user started meanwhile ran against a master that was
        // going away: its result means nothing now.
        supersedeRefresh()
        switch outcome {
        case .success(let report):
            let status = Self.signedOutStatus(
                clusterName: displayName,
                hasSnapshot: snapshot != nil,
                report: report,
                jumpHostname: target.jumpHostname
            )
            signedOutStatusLine = status
            // A probe that finished before the master went may have marked
            // the session live again.
            set(\.isLoggedIn, false)
            lastFailureWasMissingMaster = true
            consecutiveFailedRefreshes = 0
            transportFailuresTowardLogout = 0
            updateRefreshInterval(to: backgroundRefreshInterval)
            set(\.statusMessage, status)
        case .failure(let error):
            // The user asked for this, so a master that would not die is
            // worth saying (exit 1: a verified master survived SIGKILL).
            // It is still there, so monitoring carries on as usual.
            set(\.statusMessage, "Could not sign out of \(displayName)")
            set(\.errorMessage, error.localizedDescription)
            startBackgroundRefresh()
        }
    }

    /// Drops whatever refresh is in flight: its completion is ignored
    /// (generation check) and the spinner stops.
    private func supersedeRefresh() {
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshInFlight = false
        inFlightShowsErrors = false
        set(\.isRefreshing, false)
    }

    /// The status line after a Disconnect. Keeping the shared jump-host
    /// session is the normal case while anything else uses it, so it reads
    /// as information, not as a failure.
    nonisolated static func signedOutStatus(
        clusterName: String,
        hasSnapshot: Bool,
        report: StopMasterReport,
        jumpHostname: String
    ) -> String {
        var status = hasSnapshot ? "Signed out — showing the last snapshot" : "Signed out of \(clusterName)"
        if report.keptSharedJumpSession {
            status += " • \(jumpHostname) stays signed in for another connection"
        } else if report.stoppedSharedJumpSession {
            status += " • \(jumpHostname) signed out too"
        }
        return status
    }

    /// `ssh -O check` on the live identity's socket.
    func isMasterAlive() async -> Bool {
        await backend.isMasterAlive(settings: settings)
    }

    /// Closes `target`'s master and logs what happened. Callers decide
    /// whether a failure is worth showing (only an explicit Disconnect is).
    @discardableResult
    private func stopMaster(
        _ target: ConnectionSettings,
        reason: String,
        stopJumpIfUnused: Bool = false
    ) async -> Result<StopMasterReport, Error> {
        Log.login.info(
            "\(self.id.rawValue, privacy: .public): closing the master for \(target.username, privacy: .private)@\(target.hostname, privacy: .private) (\(reason, privacy: .public))"
        )
        do {
            let report = try await backend.stopMaster(settings: target, stopJumpIfUnused: stopJumpIfUnused)
            for line in report.statusLines {
                Log.login.info("\(self.id.rawValue, privacy: .public): \(line, privacy: .public)")
            }
            return .success(report)
        } catch {
            Log.login.error(
                "\(self.id.rawValue, privacy: .public): could not close the master: \(error.localizedDescription, privacy: .public)"
            )
            return .failure(error)
        }
    }

    /// The reuse-only cleanup for a master this session found alive but did
    /// not sign in to (see `MonitorService.adoptMaster`). Runs at most once
    /// per control path per run, in the background; whatever it finds is
    /// logged and never shown — the session works either way.
    private func adoptIfNeeded(_ target: ConnectionSettings) {
        guard adoptedControlPaths.insert(target.controlPath).inserted else {
            return
        }
        let backend = self.backend
        let id = self.id
        adoptionTask = Task {
            let outcome = await backend.adoptMaster(settings: target)
            switch outcome {
            case .adopted:
                Log.login.info("\(id.rawValue, privacy: .public): adopted the existing master (any leftovers of older releases ended)")
            case .nothingToAdopt:
                Log.login.info("\(id.rawValue, privacy: .public): no healthy master to adopt")
            case .unavailable(let reason):
                Log.login.error("\(id.rawValue, privacy: .public): master adoption skipped: \(reason, privacy: .public)")
            }
        }
    }

    // MARK: - Refresh

    /// The Refresh button. When a refresh cannot help — no master is known
    /// to exist, or the first probe is still running — it probes quietly
    /// instead of painting a red "control master is not running" error.
    func refresh() {
        refresh(reason: ClusterPresentation(session: self).allowsRefresh ? .manual : .automatic)
    }

    /// Opportunistic refresh (e.g. the menu bar opening): honours pause,
    /// skips clusters that were never signed in, and never surfaces errors,
    /// so merely glancing at the menu cannot paint a red error or bump the
    /// failure backoff of a cluster the user is not using.
    func refreshQuietly() {
        guard !isPaused, !signedOutByUser, isLoggedIn || hasCachedSnapshot else {
            return
        }
        refresh(reason: .automatic)
    }

    /// Requests a snapshot guaranteed to be collected after a state-mutating
    /// remote action (e.g. scancel). Unlike refresh(), this is never a
    /// silent no-op: when a refresh is already in flight (its data may
    /// predate the mutation) or a login is running, a pending flag makes the
    /// next refresh completion start one follow-up refresh instead of
    /// dropping the request.
    func refreshAfterMutation() {
        guard !refreshInFlight && !isLoggingIn else {
            pendingRefresh = true
            return
        }
        refresh(reason: .manual)
    }

    /// Consumes the pending post-mutation refresh request, if any. Called
    /// from both refresh completion paths after the generation check; a
    /// refresh superseded by a login returns before the check and leaves the
    /// flag set for the login's own refresh to consume.
    private func consumePendingRefresh() {
        guard pendingRefresh else {
            return
        }
        pendingRefresh = false
        refreshAfterMutation()
    }

    private func refresh(reason: RefreshReason) {
        guard isEnabled, !isLoggingIn, !isLoginQueued else {
            return
        }
        if refreshInFlight {
            // A request the user can see while a background refresh runs:
            // adopt the running one (its data is seconds old at most) and
            // let it show its spinner and errors.
            if reason.isVisible {
                set(\.isRefreshing, true)
            }
            if reason.showsErrors {
                inFlightShowsErrors = true
                set(\.errorMessage, nil)
            }
            return
        }
        refreshInFlight = true
        inFlightShowsErrors = reason.showsErrors
        if reason.isVisible {
            set(\.isRefreshing, true)
        }
        if reason.showsErrors {
            set(\.errorMessage, nil)
        }
        let requestSettings = settings
        let collectStorage = wantsStorage(for: reason)
        let collectJobUsage = wantsJobUsage(for: reason)
        if collectJobUsage {
            lastJobUsageRequest = now()
        }
        refreshGeneration += 1
        let generation = refreshGeneration
        let startedAt = now()
        let backend = self.backend
        refreshTask = Task { [weak self] in
            let result: Result<ClusterSnapshot, Error>
            do {
                result = .success(try await backend.collectSnapshot(
                    settings: requestSettings,
                    skipStorage: !collectStorage,
                    jobUsage: collectJobUsage
                ))
            } catch {
                result = .failure(error)
            }
            self?.completeRefresh(
                result,
                reason: reason,
                settings: requestSettings,
                requestedStorage: collectStorage,
                generation: generation,
                startedAt: startedAt
            )
        }
    }

    /// Whether this refresh should also sample job usage: only while one
    /// of the user's jobs runs, at most once a `jobUsageInterval` (a manual
    /// refresh always), and only when the user has it on.
    private func wantsJobUsage(for reason: RefreshReason) -> Bool {
        guard host?.sampleJobUsage == true,
              snapshot?.jobs.contains(where: { $0.jobState.occupiesNodes }) == true else {
            return false
        }
        if reason == .manual {
            return true
        }
        guard let lastJobUsageRequest else {
            return true
        }
        return now().timeIntervalSince(lastJobUsageRequest) >= Self.jobUsageInterval
    }

    /// The "Sample" switch moved: on samples at the next refresh (started
    /// now); off forgets the figures, which would only go stale.
    func jobUsageSamplingChanged(isOn: Bool) {
        objectWillChange.send()
        if isOn {
            lastJobUsageRequest = nil
            refreshQuietly()
        } else {
            set(\.jobUsage, [:])
            set(\.jobUsageHistory, JobUsageHistory())
        }
    }

    /// Takes a new job usage sample, if the refresh brought one, and drops
    /// jobs that are no longer running either way.
    private func applyJobUsage(from incoming: ClusterSnapshot, jobs: [Job]) {
        let running = Set(jobs.filter { $0.jobState.occupiesNodes }.map(\.jobId))
        var usage = jobUsage.filter { running.contains($0.key) }
        if let rows = incoming.jobUsage {
            let sampledAt = SlurmTimestamp.parse(incoming.collectedAt) ?? now()
            usage = JobUsageSummary.summaries(from: rows, sampledAt: sampledAt).filter { running.contains($0.key) }
            var history = jobUsageHistory
            history.record(usage, running: running)
            set(\.jobUsageHistory, history)
        } else if jobUsageHistory.points.keys.contains(where: { !running.contains($0) }) {
            var history = jobUsageHistory
            history.record([:], running: running)
            set(\.jobUsageHistory, history)
        }
        set(\.jobUsage, usage)
    }

    /// Whether this refresh should collect storage (see
    /// `storageRefreshInterval`). Everything else skips it with
    /// `--skip-storage`, and the previous rows stay on screen.
    private func wantsStorage(for reason: RefreshReason) -> Bool {
        if reason == .manual || reason == .login || storageDue {
            return true
        }
        let current = now()
        if let miss = lastStorageMiss, current.timeIntervalSince(miss) < Self.storageRetryAfterMiss {
            // An earlier df/quota/lfs is probably still stuck: asking again
            // every 10 s would only add the collector's probe to each run.
            return false
        }
        if dashboard.selectedTab == .storage {
            return true
        }
        guard let lastStorageCollection else {
            return true
        }
        return current.timeIntervalSince(lastStorageCollection) >= Self.storageRefreshInterval
    }

    /// Applies one refresh result. Entirely synchronous: every state change
    /// lands in the same main-actor turn, so SwiftUI renders it once.
    private func completeRefresh(
        _ result: Result<ClusterSnapshot, Error>,
        reason: RefreshReason,
        settings requestSettings: ConnectionSettings,
        requestedStorage: Bool,
        generation: Int,
        startedAt: Date
    ) {
        let duration = now().timeIntervalSince(startedAt)
        guard generation == refreshGeneration else {
            // A login, pause, disable or route change superseded it.
            Log.refresh.info(
                "\(self.id.rawValue, privacy: .public): \(reason.rawValue, privacy: .public) refresh superseded after \(duration, format: .fixed(precision: 1), privacy: .public)s"
            )
            return
        }
        refreshInFlight = false
        refreshTask = nil
        let showsErrors = inFlightShowsErrors
        inFlightShowsErrors = false
        set(\.isRefreshing, false)
        set(\.hasCompletedFirstProbe, true)

        let outcome: String
        switch result {
        case .success(let nextSnapshot):
            switch RefreshClassification.classify(nextSnapshot) {
            case .success:
                claimStorageRows(for: requestSettings.username)
                noteStorageAttempt(nextSnapshot, requested: requestedStorage)
                handleRefreshSuccess(nextSnapshot, settings: requestSettings)
                outcome = "ok"
            case .schedulerError(let failedSections, let message):
                claimStorageRows(for: requestSettings.username)
                noteStorageAttempt(nextSnapshot, requested: requestedStorage)
                handleSchedulerError(nextSnapshot, failedSections: failedSections, message: message, settings: requestSettings, showsErrors: showsErrors)
                outcome = "slurm error (\(failedSections.sorted().joined(separator: ",")))"
            case .transport(let message):
                handleTransportFailure(message: message, showsErrors: showsErrors)
                outcome = "failed"
            }
        case .failure(let error):
            if RefreshFailure.isConfigurationError(error) {
                handleConfigurationFailure(error, showsErrors: showsErrors)
                outcome = "configuration error"
            } else {
                handleTransportFailure(message: error.localizedDescription, showsErrors: showsErrors)
                outcome = "failed"
            }
        }
        Log.refresh.info(
            "\(self.id.rawValue, privacy: .public): \(reason.rawValue, privacy: .public) refresh \(outcome, privacy: .public) in \(duration, format: .fixed(precision: 1), privacy: .public)s (storage \(requestedStorage ? "requested" : "skipped", privacy: .public)); failures \(self.consecutiveFailedRefreshes, privacy: .public), next in \(Int(self.currentRefreshInterval), privacy: .public)s"
        )
        startBackgroundRefresh()
        writeAppState()
        consumePendingRefresh()
    }

    /// Called before a refresh signed in as `account` merges its storage.
    /// When the rows on screen belong to another account — a sign-in, or a
    /// master found, under another username — they and their bookkeeping
    /// are dropped first: the merge keeps the previous rows when this
    /// refresh brought none, and carries a previous row over one cut short,
    /// and either would show the other account's usage, quota and resolved
    /// paths (which the Files tab's shortcuts follow) as this account's,
    /// collected at the other account's time. The new account's rows start
    /// from its own first collection, which the next refresh asks for if
    /// this one did not. A change of login host alone keeps the account,
    /// and so the rows: storage is per account, not per login node.
    ///
    /// The job list is per account too (`squeue -u $USER`): a Slurm-error
    /// refresh whose jobs section failed would otherwise keep the previous
    /// account's queue on screen — and offer Cancel on jobs this account
    /// cannot touch — so it goes with the storage rows. Partitions and nodes
    /// are cluster-wide and stay.
    private func claimStorageRows(for account: String) {
        defer {
            storageAccount = account
        }
        guard let storageAccount, storageAccount != account else {
            return
        }
        lastStorageCollection = nil
        lastStorageMiss = nil
        storageDue = true
        storageLabelsWithFigures = []
        set(\.storageCollectedAt, nil)
        if let snapshot, snapshot.storage != nil || !snapshot.jobs.isEmpty {
            applySnapshot(Self.withoutAccountData(in: snapshot))
        }
        Log.refresh.info("\(self.id.rawValue, privacy: .public): jobs and storage rows of the previous account dropped")
    }

    /// `noteStorageRows` for a snapshot read back from the cache: its rows
    /// belong to the account the collector reported.
    private func noteCachedStorageRows(of cached: ClusterSnapshot) {
        let user = cached.remote.user.trimmingCharacters(in: .whitespacesAndNewlines)
        storageAccount = user.isEmpty ? nil : user
        noteStorageRows(of: cached)
    }

    /// Storage bookkeeping for a refresh whose round trip worked: a
    /// requested section that came back complete is the new baseline. One
    /// that did not come back (BUSY guard, budget ran out) or came back
    /// with rows cut short (the budget ran out inside the section, a
    /// df/lfs stalled) is a miss, retried a minute later — a cut section is
    /// not a collection, or its empty rows would stand for five minutes.
    private func noteStorageAttempt(_ incoming: ClusterSnapshot, requested: Bool) {
        if let rows = incoming.storage, !rows.contains(where: \.isCutShort) {
            lastStorageCollection = now()
            lastStorageMiss = nil
            storageDue = false
        } else if requested || incoming.storage != nil {
            lastStorageMiss = now()
            storageDue = false
        }
    }

    /// Whether a storage row cut short may still show its label's previous
    /// figures: only for a while after the last complete collection (see
    /// `storageCarryLimit`).
    private var mayCarryCutStorageRows: Bool {
        guard let lastStorageCollection else {
            return false
        }
        return now().timeIntervalSince(lastStorageCollection) < Self.storageCarryLimit
    }

    /// Remembers which labels have had real figures and when the rows on
    /// screen were collected. When some rows on screen were carried over
    /// from an earlier refresh (`carriedEarlierRows`), the collection time
    /// stays at the older one, so it never claims the carried figures are
    /// fresh.
    private func noteStorageRows(of snapshot: ClusterSnapshot, carriedEarlierRows: Bool = false) {
        guard let rows = snapshot.storage else {
            return
        }
        for row in rows where row.source != "unavailable" {
            storageLabelsWithFigures.insert(row.label)
        }
        if !carriedEarlierRows {
            set(\.storageCollectedAt, snapshot.collectedAt)
        }
    }

    private func handleRefreshSuccess(_ incoming: ClusterSnapshot, settings requestSettings: ConnectionSettings) {
        let cache = self.cache
        let storage = Self.mergeStorage(
            previous: snapshot?.storage,
            incoming: incoming.storage,
            labelsWithFigures: storageLabelsWithFigures,
            carryCutRows: mayCarryCutStorageRows
        )
        noteStorageRows(
            of: incoming,
            carriedEarlierRows: Self.storageCarriesEarlierRows(incoming: incoming.storage, merged: storage)
        )
        let nextSnapshot = Self.withStorage(storage, in: incoming)
        applySnapshot(nextSnapshot)
        applyJobUsage(from: incoming, jobs: nextSnapshot.jobs)
        set(\.hasCachedSnapshot, true)
        lastFailureWasMissingMaster = false
        markLive(using: requestSettings)
        consecutiveFailedRefreshes = 0
        transportFailuresTowardLogout = 0
        updateRefreshInterval(to: backgroundRefreshInterval)
        set(\.errorMessage, nil)
        set(\.schedulerIssue, nil)
        set(\.lastRefreshFailure, nil)
        set(\.statusMessage, isPaused ? pausedStatusText : liveStatusText(for: nextSnapshot))

        // From the merged snapshot: a refresh that skipped storage carries
        // the last known figures forward instead of a gap (a missing value
        // breaks the Trends line) or a fake drop to zero.
        appendToHistory(TrendPoint(snapshot: nextSnapshot), cache: cache)
        // Still rewritten every refresh: the desktop widget shows this file.
        cacheWriter.saveSnapshot(nextSnapshot, to: cache)
        saveCollectorArgumentsIfChanged(requestSettings)
        let identity = Self.jobIdentity(of: requestSettings)
        if let observedIdentity, observedIdentity != identity {
            // Another account: the GPU-free baseline describes what the
            // previous account saw, so start from fresh data.
            gpuAlerts = GPUFreeAlertTracker()
        }
        observedIdentity = identity
        processJobChanges(nextSnapshot.jobs, identity: identity, cache: cache)
        evaluateGPUAlert()
        retireSupersededIfIdle()
    }

    /// Whose job list a refresh shows: the account, as "user@cluster". The
    /// login host and route are left out on purpose: the collector lists
    /// `squeue -u $USER`, which the controller answers the same from every
    /// login node and over rash or direct, so switching Calder from its
    /// round-robin name to one login node (its guide's workaround for a bad
    /// node) must not drop the start/end alerts of jobs that changed
    /// meanwhile. Baselines from earlier builds recorded "user@host";
    /// `JobStateDiff.plan` compares accounts only, so they still match.
    nonisolated static func jobIdentity(of settings: ConnectionSettings) -> String {
        "\(settings.username)@\(settings.clusterID.rawValue)"
    }

    /// Slurm failed over a healthy master: stay live, keep what the failed
    /// sections cannot replace, say what happened, back off — but never
    /// count it toward the logout or offer a destructive re-login.
    private func handleSchedulerError(
        _ incoming: ClusterSnapshot,
        failedSections: Set<String>,
        message: String,
        settings requestSettings: ConnectionSettings,
        showsErrors: Bool
    ) {
        let merged = Self.merge(
            previous: snapshot,
            incoming: incoming,
            failedSections: failedSections,
            labelsWithFigures: storageLabelsWithFigures,
            carryCutStorageRows: mayCarryCutStorageRows
        )
        noteStorageRows(
            of: incoming,
            carriedEarlierRows: Self.storageCarriesEarlierRows(incoming: incoming.storage, merged: merged.storage)
        )
        applySnapshot(merged)
        set(\.hasCachedSnapshot, true)
        lastFailureWasMissingMaster = false
        markLive(using: requestSettings)
        transportFailuresTowardLogout = 0
        consecutiveFailedRefreshes += 1
        applyBackoff()
        let summary = "Slurm error on \(displayName): \(RefreshFailure.firstLine(of: message))"
        set(\.schedulerIssue, summary)
        recordRefreshFailure(.clusterSide, message: summary, detail: message)
        set(\.statusMessage, isPaused ? pausedStatusText : "\(summary) • retrying every \(refreshIntervalText)")
        if showsErrors {
            set(\.errorMessage, """
            Slurm on \(displayName) did not answer. The SSH connection is fine, so signing in again would not help; anything that could not be refreshed shows the previous data. The app keeps retrying.

            \(message)
            """)
        }
        // The widget shows what the app shows.
        cacheWriter.saveSnapshot(merged, to: cache)
    }

    private func handleTransportFailure(message: String, showsErrors: Bool) {
        // The collector checks the ControlMaster locally before touching the
        // network. A missing master is definitive — only a sign-in brings it
        // back — so say so instead of "offline, retrying", which suggests a
        // network blip that will heal by itself.
        let masterMissing = Self.isMissingMasterMessage(message)
        if masterMissing, let signedOutStatusLine {
            // The user signed out and a probe confirmed it: exactly what the
            // "Signed out" status says (put back, in case "Resuming
            // monitoring" replaced it). Not a failure to count, back off
            // from or report.
            restoreCachedSnapshotIfNeeded()
            lastFailureWasMissingMaster = true
            set(\.isLoggedIn, false)
            set(\.schedulerIssue, nil)
            set(\.statusMessage, isPaused ? pausedStatusText : signedOutStatusLine)
            return
        }
        // The master refused one more channel (MaxSessions): it is alive.
        let sessionRefused = MonitorService.isSessionRefusal(message)
        consecutiveFailedRefreshes += 1
        if !sessionRefused {
            transportFailuresTowardLogout += 1
        }
        applyBackoff()
        lastFailureWasMissingMaster = masterMissing
        restoreCachedSnapshotIfNeeded()
        let status: String
        let summary: String
        if masterMissing {
            summary = "No \(displayName) SSH session — sign in to refresh"
            status = snapshot != nil
                ? "Showing cached data • sign in to \(displayName) to refresh"
                : "Not signed in to \(displayName)"
        } else if sessionRefused {
            summary = "\(displayName) refused another SSH session"
            status = "\(summary) • retrying every \(refreshIntervalText)"
        } else {
            summary = RefreshFailure.firstLine(of: message)
            status = snapshot != nil
                ? "Cached snapshot offline • retrying every \(refreshIntervalText)"
                : "Offline • retrying every \(refreshIntervalText)"
        }
        recordRefreshFailure(.transport, message: summary, detail: message)
        set(\.statusMessage, isPaused ? pausedStatusText : status)
        set(\.schedulerIssue, nil)
        // A single failed refresh is usually a transient blip (VPN hiccup,
        // expect timeout); keep the session shown as connected-but-stale
        // until failures persist — unless the master is known to be gone.
        if masterMissing || transportFailuresTowardLogout >= Self.consecutiveFailuresBeforeLogout {
            if isLoggedIn {
                set(\.droppedAt, now())
                Log.sharing.info("\(self.id.rawValue, privacy: .public): session dropped (\(masterMissing ? "master gone" : "not answering", privacy: .public))")
            }
            set(\.isLoggedIn, false)
        }
        if showsErrors {
            set(\.errorMessage, sessionRefused
                ? MonitorService.explainSSHFailure(message, clusterName: displayName)
                : message)
        }
    }

    /// The collector could not even start: script missing, runtime folder
    /// not writable, no python3. Signing in again cannot fix that, and it
    /// says nothing about the master, so the session's connection state is
    /// left alone; the status line names the problem.
    private func handleConfigurationFailure(_ error: Error, showsErrors: Bool) {
        consecutiveFailedRefreshes += 1
        applyBackoff()
        restoreCachedSnapshotIfNeeded()
        let summary = RefreshFailure.configurationSummary(error)
        recordRefreshFailure(.configuration, message: summary, detail: error.localizedDescription)
        set(\.statusMessage, isPaused ? pausedStatusText : summary)
        set(\.schedulerIssue, nil)
        if showsErrors {
            set(\.errorMessage, "\(summary). Check \"Project root\" under Advanced — it must be your checkout of this repository.\n\n\(error.localizedDescription)")
        }
    }

    /// A failed refresh with nothing on screen still shows the cached
    /// snapshot, if there is one.
    private func restoreCachedSnapshotIfNeeded() {
        if snapshot == nil, let cachedSnapshot = cache.loadLatestSnapshot() {
            noteCachedStorageRows(of: cachedSnapshot)
            applySnapshot(cachedSnapshot)
        }
        set(\.hasCachedSnapshot, snapshot != nil)
    }

    private func recordRefreshFailure(_ kind: RefreshFailure.Kind, message: String, detail: String) {
        set(\.lastRefreshFailure, RefreshFailure(
            kind: kind,
            message: message,
            detail: detail,
            consecutiveCount: max(consecutiveFailedRefreshes, 1),
            date: now()
        ))
    }

    private func markLive(using requestSettings: ConnectionSettings) {
        // A master answered (started from a terminal after a Disconnect,
        // say): the session is simply live again.
        signedOutStatusLine = nil
        set(\.isLoggedIn, true)
        set(\.droppedAt, nil)
        if activeConnection == nil {
            // Live without a sign-in in this run: a master from before (the
            // previous run, the command line, an older release).
            set(\.activeConnection, requestSettings)
            adoptIfNeeded(requestSettings)
        }
        // Live again on an identity kept earlier for its running work (the
        // form was set back after the newer identity's session failed): it
        // is the live session now, never one to retire.
        supersededConnections.removeAll { $0.controlPath == requestSettings.controlPath }
        if let earlier = lastActiveConnection,
           earlier.controlPath != requestSettings.controlPath,
           !supersededConnections.contains(where: { $0.controlPath == earlier.controlPath }) {
            // Live under another identity than the one remembered — the
            // form was edited after a failed sign-in, and a master turned up
            // for the new one. Nothing returns to the earlier master, so it
            // is retired like any replaced identity's (once no terminal or
            // transfer runs; see `retireSupersededIfIdle`).
            supersededConnections.append(earlier)
        }
        lastActiveConnection = activeConnection
    }

    private func applyBackoff() {
        let backoff = backgroundRefreshInterval * pow(2, Double(max(consecutiveFailedRefreshes - 1, 0)))
        updateRefreshInterval(to: min(backoff, maximumRefreshInterval))
    }

    private func applySnapshot(_ next: ClusterSnapshot) {
        if snapshot != next {
            snapshot = next
        }
    }

    /// "Last refresh 14:05:20", timed by when the data was collected (so an
    /// unchanged snapshot does not repaint the status line).
    private func liveStatusText(for snapshot: ClusterSnapshot) -> String {
        let collected = SlurmTimestamp.parse(snapshot.collectedAt) ?? now()
        return "Last refresh \(collected.formatted(date: .omitted, time: .standard))"
    }

    // MARK: - History

    private func setHistory(_ points: [TrendPoint]) {
        historyTimestamps = Set(points.map(\.collectedAt))
        if history != points {
            history = points
        }
    }

    private func loadHistory(from cache: SnapshotCache) {
        let log = cache.loadHistoryLog()
        setHistory(log.points)
        historyLinesInLog = log.lineCount
        if log.needsCompaction {
            // One-time migration from the legacy JSON array, or a cleanup of
            // malformed / excess lines.
            cacheWriter.rewriteHistory(log.points, to: cache)
            historyLinesInLog = log.points.count
        }
    }

    /// In-memory history is the source of truth; the log gets one appended
    /// line per new point and an occasional compaction.
    private func appendToHistory(_ point: TrendPoint, cache: SnapshotCache) {
        guard historyTimestamps.insert(point.collectedAt).inserted else {
            return
        }
        var updated = history
        updated.append(point)
        let excess = updated.count - SnapshotCache.historyCapacity
        if excess > 0 {
            for dropped in updated.prefix(excess) {
                historyTimestamps.remove(dropped.collectedAt)
            }
            updated.removeFirst(excess)
        }
        history = updated
        historyLinesInLog += 1
        if historyLinesInLog > SnapshotCache.historyCapacity + SnapshotCache.historyCompactionSlack {
            cacheWriter.rewriteHistory(updated, to: cache)
            historyLinesInLog = updated.count
        } else {
            cacheWriter.appendHistory(point, to: cache)
        }
    }

    // MARK: - Job events

    /// Diffs against the last observation (see JobStateDiff for the gap
    /// rules), advances the baseline after every successful refresh whether
    /// or not notifications are allowed, and hands any events to the
    /// notifier.
    ///
    /// `identity` (`jobIdentity`, "user@cluster") is recorded with the
    /// baseline: after a sign-in under another account the first diff is
    /// skipped (re-seeded silently) instead of announcing every job of the
    /// old account as ended — in this run and after a relaunch alike. A
    /// change of login host alone keeps the account, so it diffs as usual.
    private func processJobChanges(_ jobs: [Job], identity: String, cache: SnapshotCache) {
        let observedAt = now()
        let changes = JobStateDiff.plan(previous: jobBaseline, current: jobs, now: observedAt, identity: identity)
        let baseline = JobStateSnapshot(jobs: jobs, observedAt: Self.iso8601.string(from: observedAt), identity: identity)
        let statesChanged = jobBaseline.map { !$0.hasSameStates(as: baseline) || $0.identity != identity } ?? true
        jobBaseline = baseline
        if statesChanged
            || lastJobBaselineWrite.map({ observedAt.timeIntervalSince($0) >= Self.jobBaselineRewriteInterval }) ?? true {
            cacheWriter.saveJobStates(baseline, to: cache)
            lastJobBaselineWrite = observedAt
        }
        guard let changes else {
            return
        }
        Log.notifications.info(
            "\(self.id.rawValue, privacy: .public): \(changes.started.count, privacy: .public) started, \(changes.ended.count, privacy: .public) ended (\(String(describing: changes.delivery), privacy: .public))"
        )
        host?.eventNotifier?.notifyJobChanges(changes, cluster: profile)
    }

    // MARK: - GPU-free alert

    private func evaluateGPUAlert() {
        let fleet = gpuFleet
        let idle: Int? = fleet.hasUnknownAllocation ? nil : fleet.idle
        guard gpuAlerts.evaluate(idleGPUs: idle, alertsEnabled: host?.notifyWhenGPUFrees == true, now: now()),
              let notifier = host?.eventNotifier else {
            return
        }
        let freePools = fleet.poolsWithIdle
        let partitions = Array(Set(freePools.flatMap(\.partitions))).sorted()
        let models = freePools.map(\.label)
        let profile = self.profile
        let idleCount = fleet.idle
        Task { [weak self] in
            let fired = await notifier.notifyGPUBecameAvailable(
                cluster: profile,
                idleCount: idleCount,
                gpuModel: models.isEmpty ? nil : models.joined(separator: " + "),
                partitions: partitions
            )
            if fired, let self {
                self.gpuAlerts.recordFired(at: self.now())
            }
        }
    }

    // MARK: - Collector invocation

    private func saveCollectorArgumentsIfChanged(_ settings: ConnectionSettings) {
        let arguments = MonitorService.collectorArguments(settings: settings)
        guard arguments != lastCollectorArguments else {
            return
        }
        lastCollectorArguments = arguments
        cacheWriter.saveCollectorArguments(arguments, to: cache) { [weak self] saved in
            guard !saved else {
                return
            }
            Task { @MainActor in
                // Retry on the next refresh.
                self?.lastCollectorArguments = nil
            }
        }
    }

    // MARK: - Pause

    /// Suspends background refreshing: stops the timer and invalidates any
    /// in-flight refresh so its late completion cannot repaint state or
    /// restart the timer. A manual Refresh still works while paused (as a
    /// one-shot; the `startBackgroundRefresh` guard keeps the timer off).
    func pauseMonitoring() {
        guard !isPaused, !isLoggingIn else {
            return
        }
        isPaused = true
        stopBackgroundRefresh()
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshInFlight = false
        inFlightShowsErrors = false
        set(\.isRefreshing, false)
        set(\.statusMessage, pausedStatusText)
    }

    /// Re-enables background refreshing and kicks off an immediate refresh.
    func resumeMonitoring() {
        guard isPaused else {
            return
        }
        isPaused = false
        set(\.statusMessage, "Resuming monitoring")
        startBackgroundRefresh()
        refresh()
    }

    func togglePause() {
        isPaused ? resumeMonitoring() : pauseMonitoring()
    }

    // MARK: - Remote actions

    /// The scancel command for one Jobs-tab row.
    ///
    /// The pending remainder of an array ("123", tasks 2-58 queued) shares
    /// its id with the whole array, and `scancel 123` would kill the running
    /// tasks too. `--state=PENDING` restricts it to elements still pending
    /// when scancel runs — safer than an explicit `123_[2-58]`, which would
    /// also kill a task that started after this snapshot was taken.
    nonisolated static func cancelCommand(for job: Job) -> String {
        if job.isArrayRemainder {
            let arrayID = job.arrayJobID.map(String.init) ?? job.jobId
            return "scancel --state=PENDING \(shellQuote(arrayID))"
        }
        return "scancel \(shellQuote(job.jobId))"
    }

    /// Runs `scancel` for one of this cluster's jobs, then asks for a fresh
    /// snapshot so the queue reflects the cancellation. Job ids are only
    /// unique within a cluster, which is why cancel lives on the session.
    func cancelJob(_ job: Job) async throws {
        let command = Self.cancelCommand(for: job)
        Log.refresh.info("\(self.id.rawValue, privacy: .public): \(command, privacy: .public)")
        do {
            let result = try await backend.runRemoteCommand(settings: settings, command: command)
            if result.exitCode == MonitorService.processTimedOutExitCode {
                // Not a login timeout (explainSSHFailure's 124 wording):
                // scancel may still have acted, so look again.
                refreshAfterMutation()
                throw MonitorError.processFailed(
                    "scancel did not answer in time; the next refresh shows whether the job was cancelled."
                )
            }
            guard result.exitCode == 0 else {
                let message = result.stderr.isEmpty ? result.stdout : result.stderr
                throw MonitorError.processFailed(
                    message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "scancel exited with code \(result.exitCode)"
                        : MonitorService.explainSSHFailure(
                            message,
                            exitCode: result.exitCode,
                            clusterName: displayName
                        )
                )
            }
        } catch {
            errorMessage = "Could not cancel \(displayName) job \(job.displayJobID) — \(error.localizedDescription)"
            throw error
        }
        // Non-droppable: a plain refresh() silently no-ops while another
        // refresh is in flight, which would leave the cancelled job showing
        // as RUNNING (indefinitely so while monitoring is paused).
        refreshAfterMutation()
    }

    // MARK: - Timer

    private func startBackgroundRefresh() {
        // Never restart the timer while paused, disabled or signed out by
        // the user: failure handlers and late completions route through
        // here too.
        guard !scheduler.isScheduled, !isPaused, isEnabled, !signedOutByUser else {
            return
        }
        scheduler.schedule(every: currentRefreshInterval) { [weak self] in
            self?.refresh(reason: .automatic)
        }
    }

    private func stopBackgroundRefresh() {
        scheduler.cancel()
    }

    private func updateRefreshInterval(to interval: TimeInterval) {
        guard abs(currentRefreshInterval - interval) > 0.1 else {
            return
        }
        currentRefreshInterval = interval
        if scheduler.isScheduled {
            stopBackgroundRefresh()
            startBackgroundRefresh()
        }
    }

    // MARK: - Helpers

    /// Assigns only when the value differs: @Published fires
    /// objectWillChange even for an identical value, and every change is
    /// forwarded app-wide.
    private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<ClusterSession, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    /// Matches the collector's local ControlMaster probe failure
    /// ("connection lost: SSH control master is not running …") and
    /// MonitorService's pre-flight ("… SSH session expired …"). A probe that
    /// merely timed out is deliberately not included: a wedged master may
    /// still recover, so it gets the ordinary retry/backoff treatment.
    nonisolated static func isMissingMasterMessage(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("control master is not running")
            || lowered.contains("ssh session expired")
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func nonEmpty(_ value: String, default fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func loginSummary(from output: String, clusterName: String) -> String {
        let lines = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if let statusLine = lines.last(where: { $0.hasPrefix(MonitorService.statusLinePrefix) }) {
            let message = String(statusLine.dropFirst(MonitorService.statusLinePrefix.count))
                .trimmingCharacters(in: .whitespaces)
            if !message.isEmpty {
                return message
            }
        }
        if let authLine = lines.last(where: { $0.hasPrefix("auth_ok|") }) {
            let host = authLine.dropFirst("auth_ok|".count)
                .split(separator: "|")
                .first
                .map(String.init) ?? ""
            return host.isEmpty ? "Connected to \(clusterName)" : "Connected to \(host)"
        }
        return "Connected to \(clusterName)"
    }
}

private enum RefreshReason: String {
    /// Startup, route change, monitoring switched back on: is a master there?
    case probe
    case login
    case manual
    case automatic

    var showsErrors: Bool {
        self == .login || self == .manual
    }

    /// Whether the UI shows a spinner for it (`isRefreshing`).
    var isVisible: Bool {
        self != .automatic
    }
}
