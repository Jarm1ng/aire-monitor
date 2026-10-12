import AppKit
import Combine
import SwiftUI

/// Shared sign-in inputs. Every cluster combines them with its own profile
/// and host to build `ConnectionSettings`; the university account, route
/// and Duo choice are the same for all clusters.
struct SignInConfiguration: Sendable {
    var username: String
    var route: ConnectionRoute
    var jumpHostname: String
    var duoOption: String
    var projectRoot: String
}

/// What a session needs from the app-wide coordinator. Kept as a narrow
/// protocol so sessions never reach into the coordinator's other state.
@MainActor
protocol ClusterSessionHost: AnyObject {
    var signInConfiguration: SignInConfiguration { get }
    var notifyWhenGPUFrees: Bool { get }
    var notificationService: JobNotificationService { get }
    func refreshNotificationAuthorizationStatus()
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

enum LoginOutcome {
    case succeeded
    /// The server rejected the password. The coordinator stops any queued
    /// logins: retrying the same wrong password on the next cluster would
    /// only move the account closer to a lockout.
    case passwordRejected
    /// The server demanded a password change; the same applies everywhere.
    case passwordExpired
    /// The shared rash leg failed; every queued cluster would retry it.
    case jumpHostFailed
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

/// Everything about one monitored cluster: its SSH session, refresh loop,
/// snapshot cache, history, job notifications, GPU alerts, terminals and
/// file browser. Sessions are fully independent — a failing or paused
/// Calder never affects AIRE, and vice versa.
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
        }
    }

    /// Login host; defaults to the profile's. Editable under Advanced.
    @Published var hostname: String

    @Published private(set) var isLoggingIn = false
    @Published private(set) var isLoginQueued = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoggedIn = false
    @Published private(set) var hasCachedSnapshot = false
    @Published var statusMessage = "Not connected"
    @Published var errorMessage: String?
    @Published private(set) var loginProgress: String?
    @Published private(set) var snapshot: ClusterSnapshot?
    @Published private(set) var history: [TrendPoint] = []
    /// True while the background refresh timer is suspended by the user.
    /// Login always clears it; resume triggers an immediate refresh.
    @Published private(set) var isPaused = false
    @Published private(set) var currentRefreshInterval: TimeInterval

    let dashboard = ClusterDashboardState()
    let terminals = TerminalManager()
    let files = FileBrowserModel()

    weak var host: ClusterSessionHost?

    private let service = MonitorService()
    private var backgroundTimer: Timer?
    private let backgroundRefreshInterval: TimeInterval = 10
    private let maximumRefreshInterval: TimeInterval = 60
    private let consecutiveFailuresBeforeLogout = 3
    private var consecutiveRefreshFailures = 0
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    /// Set by refreshAfterMutation() when a refresh cannot start right away;
    /// consumed exactly once by a refresh completion path (success or
    /// failure) to launch one follow-up refresh, so a post-mutation refresh
    /// request is never silently dropped.
    private var pendingRefresh = false
    private var lastCollectorArguments: [String]?

    /// Minimum spacing between GPU-free alerts so a flapping idle count
    /// (0 → 1 → 0 → 1…) cannot spam notifications.
    private let gpuFreeNotificationCooldown: TimeInterval = 600
    /// Idle GPU count from the previous successful refresh. Kept in memory
    /// only; a relaunch re-seeds it from the first snapshot.
    private var previousIdleGPUs: Int?
    private var lastGPUFreeNotificationAt: Date?

    init(profile: ClusterProfile, isEnabled: Bool, hostname: String?) {
        self.profile = profile
        self.isEnabled = isEnabled
        let trimmed = hostname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.hostname = trimmed.isEmpty ? profile.defaultHostname : trimmed
        self.currentRefreshInterval = backgroundRefreshInterval
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

    var settings: ConnectionSettings {
        settings(using: host?.signInConfiguration ?? SignInConfiguration(
            username: "",
            route: .directVPN,
            jumpHostname: "rash.leeds.ac.uk",
            duoOption: "1",
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
            jumpHostname: Self.nonEmpty(configuration.jumpHostname, default: "rash.leeds.ac.uk"),
            duoOption: Self.nonEmpty(configuration.duoOption, default: "1"),
            projectRoot: configuration.projectRoot.trimmingCharacters(in: .whitespacesAndNewlines),
            storage: profile.storage
        )
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

    /// Idle GPUs on available nodes, all configured GPUs, and the model(s)
    /// they are. A cluster can host more than one GPU type — Calder's
    /// scheduler also carries `aire-gpu-lovelace` L40 nodes next to its
    /// H200s — so the label names every type ("H200 + L40") rather than
    /// passing a mixed total off as one model.
    var gpuAvailability: (idle: Int, total: Int, model: String?) {
        guard let nodes = snapshot?.nodes else {
            return (0, 0, nil)
        }
        let gpuNodes = nodes.filter { gpuTotal($0) > 0 }
        let idle = gpuNodes.filter(isAvailable).reduce(0) { $0 + gpuIdle($1) }
        let total = gpuNodes.reduce(0) { $0 + gpuTotal($1) }
        return (idle, total, Self.gpuModelSummary(gpuNodes))
    }

    /// GPU models of `nodes`, largest pool first ("H200", "H200 + L40"),
    /// at most two named. Same rule as the desktop widget's label.
    static func gpuModelSummary(_ nodes: [NodeSummary]) -> String? {
        var totals: [String: Int] = [:]
        var firstSeen: [String] = []
        for node in nodes {
            guard let model = slurmGPUModelDisplayName(from: node.gres) else {
                continue
            }
            if totals[model] == nil {
                firstSeen.append(model)
            }
            totals[model, default: 0] += gpuTotal(node)
        }
        let ranked = firstSeen.enumerated()
            .sorted { lhs, rhs in
                let left = totals[lhs.element] ?? 0
                let right = totals[rhs.element] ?? 0
                return left == right ? lhs.offset < rhs.offset : left > right
            }
            .map(\.element)
        guard !ranked.isEmpty else {
            return nil
        }
        let named = ranked.prefix(2).joined(separator: " + ")
        return ranked.count > 2 ? named + " + more" : named
    }

    // MARK: - Lifecycle

    /// Loads this cluster's cache and starts monitoring. Called once by the
    /// coordinator after `host` is set.
    func start() {
        let cache = self.cache
        history = cache.loadHistory()
        if let cachedSnapshot = cache.loadLatestSnapshot() {
            snapshot = cachedSnapshot
            hasCachedSnapshot = true
            statusMessage = "Cached snapshot available • checking SSH session"
            history = (try? cache.recordHistory(from: cachedSnapshot)) ?? history
            if cache.loadJobStateSnapshot() == nil {
                try? cache.saveJobStates(from: cachedSnapshot.jobs)
            }
        }
        guard isEnabled else {
            statusMessage = "Monitoring is off for \(displayName)"
            return
        }
        startBackgroundRefresh()
        refresh(reason: .startupProbe)
    }

    private func resumeAfterEnable() {
        consecutiveRefreshFailures = 0
        updateRefreshInterval(to: backgroundRefreshInterval)
        statusMessage = "Checking for a live \(displayName) session…"
        startBackgroundRefresh()
        refresh(reason: .automatic)
    }

    private func suspendAfterDisable() {
        stopBackgroundRefresh()
        refreshGeneration += 1
        refreshTask?.cancel()
        isRefreshing = false
        isLoginQueued = false
        isLoggedIn = false
        errorMessage = nil
        statusMessage = "Monitoring is off for \(displayName)"
    }

    // MARK: - Login

    /// Shows the session as waiting behind another cluster's sign-in. The
    /// coordinator serializes logins so Duo pushes arrive one at a time and
    /// two logins never race to build the shared rash jump master.
    func markLoginQueued() {
        guard !isLoggingIn else {
            return
        }
        isLoginQueued = true
        errorMessage = nil
        loginProgress = nil
        statusMessage = "Waiting for the previous sign-in to finish…"
        // Background refreshes would overwrite the waiting status with
        // "Not signed in…" while the user is still approving another
        // cluster's Duo push; performLogin restarts the timer either way.
        stopBackgroundRefresh()
    }

    func cancelQueuedLogin(reason: String) {
        guard isLoginQueued else {
            return
        }
        isLoginQueued = false
        statusMessage = reason
        startBackgroundRefresh()
    }

    /// Runs one interactive login for this cluster. Only the coordinator's
    /// serialized login chain calls this. `configuration` is the sign-in
    /// state captured when the login was queued, so the account the password
    /// was resolved for is the account it is sent to, even if the form is
    /// edited while earlier clusters wait for Duo.
    func performLogin(password: String, configuration: SignInConfiguration) async -> LoginOutcome {
        guard isLoginQueued, isEnabled, !isLoggingIn else {
            isLoginQueued = false
            startBackgroundRefresh()
            return .skipped
        }
        isLoginQueued = false
        let loginSettings = settings(using: configuration)
        guard !loginSettings.username.isEmpty else {
            errorMessage = "Username is required."
            startBackgroundRefresh()
            return .failed
        }

        isLoggingIn = true
        // Logging in implicitly resumes monitoring: the completion paths
        // below restart the background timer, which stays disabled while
        // paused, so clear the pause first.
        isPaused = false
        stopBackgroundRefresh()
        errorMessage = nil
        loginProgress = nil
        statusMessage = loginSettings.useJumpHost
            ? "Signing in to \(displayName) through \(loginSettings.jumpHostname)"
            : "Signing in to \(loginSettings.hostname)"

        // Invalidate and stop any in-flight refresh so it cannot run over the
        // same ControlMaster socket while the login rebuilds the session, and
        // so its completion cannot clobber post-login state.
        refreshGeneration += 1
        let inFlightRefresh = refreshTask
        inFlightRefresh?.cancel()
        if let inFlightRefresh {
            await inFlightRefresh.value
        }
        isRefreshing = false

        do {
            let output = try await service.login(settings: loginSettings, password: password) { [weak self] status in
                Task { @MainActor in
                    guard let self, self.isLoggingIn else {
                        return
                    }
                    self.loginProgress = status
                    self.statusMessage = status
                }
            }
            isLoggedIn = true
            consecutiveRefreshFailures = 0
            updateRefreshInterval(to: backgroundRefreshInterval)
            statusMessage = Self.loginSummary(from: output, clusterName: displayName)
            loginProgress = nil
            isLoggingIn = false
            saveCollectorArgumentsIfChanged(loginSettings)
            // A sign-in under a different account or host must not leave the
            // previous identity's folder listing on screen.
            files.reconcileConnectionIdentity()
            refresh(reason: .login)
            return .succeeded
        } catch {
            isLoggedIn = false
            isLoggingIn = false
            loginProgress = nil
            errorMessage = error.localizedDescription
            statusMessage = "Sign-in to \(displayName) failed"
            startBackgroundRefresh()
            switch error {
            case MonitorError.passwordRejected:
                return .passwordRejected
            case MonitorError.passwordExpired:
                return .passwordExpired
            case MonitorError.jumpHostFailed:
                return .jumpHostFailed
            default:
                return .failed
            }
        }
    }

    /// Called when the route changes. Each route has its own ControlMaster
    /// socket, so the session built for the previous route is no longer
    /// "connected" under the new one. Drop the connected state and probe the
    /// new route's socket: a master that is already alive reconnects
    /// instantly; otherwise the user signs in.
    func connectionSettingsDidChange() {
        guard !isLoggingIn, isEnabled else {
            return
        }
        isLoggedIn = false
        consecutiveRefreshFailures = 0
        updateRefreshInterval(to: backgroundRefreshInterval)
        errorMessage = nil
        loginProgress = nil
        statusMessage = "Route changed — checking for a live \(displayName) session…"
        files.reconcileConnectionIdentity()
        // Drop any refresh still running over the previous route's master:
        // its success would otherwise mark the session live under a route
        // that has no master yet.
        refreshGeneration += 1
        refreshTask?.cancel()
        isRefreshing = false
        refresh(reason: .automatic)
    }

    // MARK: - Refresh

    func refresh() {
        refresh(reason: .manual)
    }

    /// Opportunistic refresh (e.g. the menu bar opening): honours pause,
    /// skips clusters that were never signed in, and never surfaces errors,
    /// so merely glancing at the menu cannot paint a red error or bump the
    /// failure backoff of a cluster the user is not using.
    func refreshQuietly() {
        guard !isPaused, isLoggedIn || hasCachedSnapshot else {
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
        guard !isRefreshing && !isLoggingIn else {
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
        guard isEnabled, !isRefreshing, !isLoggingIn, !isLoginQueued else {
            return
        }
        isRefreshing = true
        if reason.showsErrors {
            errorMessage = nil
        }
        let currentSettings = settings
        refreshGeneration += 1
        let generation = refreshGeneration

        refreshTask = Task {
            let result: Result<ClusterSnapshot, Error>
            do {
                result = .success(try await service.collectSnapshot(settings: currentSettings))
            } catch {
                result = .failure(error)
            }
            guard generation == refreshGeneration else {
                // A login (or pause/disable) superseded this refresh.
                return
            }
            isRefreshing = false
            switch result {
            case .success(let nextSnapshot):
                guard nextSnapshot.errors.isEmpty else {
                    handleRefreshFailure(
                        message: nextSnapshot.errors.joined(separator: "\n"),
                        showsErrors: reason.showsErrors
                    )
                    return
                }
                await handleRefreshSuccess(nextSnapshot, settings: currentSettings, generation: generation)
            case .failure(let error):
                handleRefreshFailure(message: error.localizedDescription, showsErrors: reason.showsErrors)
            }
        }
    }

    private func handleRefreshSuccess(
        _ nextSnapshot: ClusterSnapshot,
        settings currentSettings: ConnectionSettings,
        generation: Int
    ) async {
        let cache = SnapshotCache(projectRoot: currentSettings.projectRoot, clusterID: profile.id)
        var previousJobState = cache.loadJobStateSnapshot()
        if let baseline = previousJobState, Self.isJobStateBaselineStale(baseline) {
            // The baseline stopped advancing (notifications unavailable for a
            // long stretch, or the app was not running); diffing against it
            // would replay long-resolved jobs as a burst of bogus
            // started/ended notifications. Re-seed it and skip the diff.
            previousJobState = nil
            try? cache.saveJobStates(from: nextSnapshot.jobs)
        }
        try? cache.saveLatestSnapshot(nextSnapshot)
        history = (try? cache.recordHistory(from: nextSnapshot)) ?? cache.loadHistory()
        saveCollectorArgumentsIfChanged(currentSettings)

        if let notificationService = host?.notificationService {
            let processedJobDiff = await notificationService.notifyChanges(
                cluster: profile,
                previous: previousJobState,
                current: nextSnapshot.jobs
            )
            if processedJobDiff {
                try? cache.saveJobStates(from: nextSnapshot.jobs)
            }
        }
        guard generation == refreshGeneration else {
            // A login started while notifyChanges was suspended. The
            // baseline stays saved (its notifications were already
            // delivered), but this superseded refresh must not clobber
            // login state or restart the background timer mid-login.
            return
        }

        snapshot = nextSnapshot
        hasCachedSnapshot = true
        isLoggedIn = true
        consecutiveRefreshFailures = 0
        updateRefreshInterval(to: backgroundRefreshInterval)
        errorMessage = nil
        statusMessage = isPaused
            ? pausedStatusText
            : "Last refresh \(Date().formatted(date: .omitted, time: .standard))"
        startBackgroundRefresh()
        host?.refreshNotificationAuthorizationStatus()
        await handleGPUAvailabilityTransition(for: nextSnapshot)
        consumePendingRefresh()
    }

    private func handleRefreshFailure(message: String, showsErrors: Bool) {
        consecutiveRefreshFailures += 1
        let backoff = backgroundRefreshInterval * pow(2, Double(max(consecutiveRefreshFailures - 1, 0)))
        updateRefreshInterval(to: min(backoff, maximumRefreshInterval))

        // The collector checks the ControlMaster locally before touching the
        // network. A missing master is definitive — only a sign-in brings it
        // back — so say so instead of "offline, retrying", which suggests a
        // network blip that will heal by itself.
        let masterMissing = Self.isMissingMasterMessage(message)
        if let cachedSnapshot = cache.loadLatestSnapshot() {
            snapshot = cachedSnapshot
            hasCachedSnapshot = true
            statusMessage = masterMissing
                ? "Showing cached data • sign in to \(displayName) to refresh"
                : "Cached snapshot offline • retrying every \(refreshIntervalText)"
        } else if snapshot != nil {
            hasCachedSnapshot = true
            statusMessage = masterMissing
                ? "Showing the previous snapshot • sign in to \(displayName) to refresh"
                : "Previous snapshot offline • retrying every \(refreshIntervalText)"
        } else {
            hasCachedSnapshot = false
            statusMessage = masterMissing
                ? "Not signed in to \(displayName)"
                : "Offline • retrying every \(refreshIntervalText)"
        }
        // A single failed refresh is usually a transient blip (VPN hiccup,
        // expect timeout); keep the session shown as connected-but-stale
        // until failures persist — unless the master is known to be gone.
        if masterMissing || consecutiveRefreshFailures >= consecutiveFailuresBeforeLogout {
            isLoggedIn = false
        }
        if showsErrors {
            errorMessage = message
        }
        // Failed refreshes must also feed the permission summary; otherwise
        // an off-VPN launch would show "Not requested yet" until the first
        // successful refresh, which requires a login.
        host?.refreshNotificationAuthorizationStatus()
        startBackgroundRefresh()
        consumePendingRefresh()
    }

    /// Job-state baselines older than this are never diffed. The baseline only
    /// advances when notifyChanges can process a diff, so it freezes while
    /// notifications are unavailable (denied, or a bare `swift run` binary
    /// without a bundle identifier) and while the app is not running; diffing
    /// against a frozen baseline would notify about long-gone jobs.
    private static let jobStateBaselineMaxAge: TimeInterval = 300

    private static let iso8601Formatter = ISO8601DateFormatter()

    private static func isJobStateBaselineStale(_ baseline: JobStateSnapshot) -> Bool {
        guard let updatedAt = iso8601Formatter.date(from: baseline.updatedAt) else {
            // An unreadable timestamp gives no drift bound; re-seed rather
            // than risk diffing against an arbitrarily old baseline.
            return true
        }
        return Date().timeIntervalSince(updatedAt) > jobStateBaselineMaxAge
    }

    private func saveCollectorArgumentsIfChanged(_ settings: ConnectionSettings) {
        let arguments = MonitorService.collectorArguments(settings: settings)
        guard arguments != lastCollectorArguments else {
            return
        }
        if (try? SnapshotCache(projectRoot: settings.projectRoot, clusterID: profile.id)
            .saveCollectorArguments(arguments)) != nil {
            lastCollectorArguments = arguments
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
        isRefreshing = false
        statusMessage = pausedStatusText
    }

    /// Re-enables background refreshing and kicks off an immediate refresh;
    /// its completion path restarts the timer.
    func resumeMonitoring() {
        guard isPaused else {
            return
        }
        isPaused = false
        statusMessage = "Resuming monitoring"
        refresh(reason: .manual)
    }

    func togglePause() {
        isPaused ? resumeMonitoring() : pauseMonitoring()
    }

    // MARK: - Remote actions

    /// Runs `scancel` for one of this cluster's jobs, then asks for a fresh
    /// snapshot so the queue reflects the cancellation. Job ids are only
    /// unique within a cluster, which is why cancel lives on the session.
    func cancelJob(_ job: Job) async throws {
        do {
            let result = try await service.runRemoteCommand(
                settings: settings,
                command: "scancel \(SSHTerminalCommand.shellQuote(job.jobId))"
            )
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
            errorMessage = "Could not cancel \(displayName) job \(job.jobId) — \(error.localizedDescription)"
            throw error
        }
        // Non-droppable: a plain refresh() silently no-ops while another
        // refresh is in flight, which would leave the cancelled job showing
        // as RUNNING (indefinitely so while monitoring is paused).
        refreshAfterMutation()
    }

    // MARK: - GPU-free alert

    /// Detects this cluster's 0 → >0 idle GPU transition (counting only
    /// available GPU nodes) and posts a local notification, subject to the
    /// user preference and a cooldown. The baseline normally advances to the
    /// current idle count so enabling the preference later starts from fresh
    /// data — except on the cooldown-suppressed path, where it stays at 0 so
    /// the transition re-fires once the cooldown expires instead of being
    /// dropped until the pool next drains to zero.
    private func handleGPUAvailabilityTransition(for snapshot: ClusterSnapshot) async {
        let availableGPUNodes = snapshot.nodes.filter { gpuTotal($0) > 0 && isAvailable($0) }
        let idleGPUs = availableGPUNodes.reduce(0) { $0 + gpuIdle($1) }
        // The defer runs after any statements on an early-return path, so
        // the cooldown branch communicates its baseline through this local
        // override rather than assigning previousIdleGPUs directly.
        var baselineOverride: Int?
        defer {
            previousIdleGPUs = baselineOverride ?? idleGPUs
        }
        guard host?.notifyWhenGPUFrees == true,
              let previous = previousIdleGPUs,
              previous == 0,
              idleGPUs > 0 else {
            return
        }
        if let lastFired = lastGPUFreeNotificationAt,
           Date().timeIntervalSince(lastFired) < gpuFreeNotificationCooldown {
            baselineOverride = 0
            return
        }
        let partitions = Array(
            Set(availableGPUNodes.filter { gpuIdle($0) > 0 }.flatMap(\.partitions))
        ).sorted()
        let fired = await host?.notificationService.notifyGPUBecameAvailable(
            cluster: profile,
            idleCount: idleGPUs,
            gpuModel: Self.gpuModelSummary(availableGPUNodes.filter { gpuIdle($0) > 0 }),
            partitions: partitions
        ) ?? false
        if fired {
            lastGPUFreeNotificationAt = Date()
        }
    }

    // MARK: - Timer

    private func startBackgroundRefresh() {
        // Never restart the timer while paused or disabled: failure handlers
        // and late completions route through here too.
        guard backgroundTimer == nil, !isPaused, isEnabled else {
            return
        }
        let timer = Timer(timeInterval: currentRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(reason: .automatic)
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        backgroundTimer = timer
    }

    private func stopBackgroundRefresh() {
        backgroundTimer?.invalidate()
        backgroundTimer = nil
    }

    private func updateRefreshInterval(to interval: TimeInterval) {
        guard abs(currentRefreshInterval - interval) > 0.1 else {
            return
        }
        currentRefreshInterval = interval
        if backgroundTimer != nil {
            stopBackgroundRefresh()
            startBackgroundRefresh()
        }
    }

    // MARK: - Helpers

    /// Matches the collector's local ControlMaster probe failure
    /// ("connection lost: SSH control master is not running …") and
    /// MonitorService's pre-flight ("… SSH session expired …"). A probe that
    /// merely timed out is deliberately not included: a wedged master may
    /// still recover, so it gets the ordinary retry/backoff treatment.
    static func isMissingMasterMessage(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("control master is not running")
            || lowered.contains("ssh session expired")
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

private enum RefreshReason {
    case startupProbe
    case login
    case manual
    case automatic

    var showsErrors: Bool {
        self == .login || self == .manual
    }
}
