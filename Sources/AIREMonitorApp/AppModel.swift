import AppKit
import Combine
import Foundation

/// The two supported ways of reaching AIRE. `directVPN` connects straight to
/// the AIRE host (requires the Ivanti VPN, one Duo approval); `rashJump`
/// tunnels through the rash.leeds.ac.uk jump host (works off-VPN, password +
/// Duo on both legs).
enum ConnectionRoute: String, CaseIterable, Identifiable {
    case directVPN
    case rashJump

    var id: String { rawValue }

    var title: String {
        switch self {
        case .directVPN: return "Direct (VPN)"
        case .rashJump: return "Via rash jump host"
        }
    }

    /// Compact label for the segmented picker.
    var shortTitle: String {
        switch self {
        case .directVPN: return "Direct (VPN)"
        case .rashJump: return "rash jump"
        }
    }

    var detail: String {
        switch self {
        case .directVPN:
            return "Connect straight to AIRE over the Ivanti VPN — one Duo approval."
        case .rashJump:
            return "Tunnel through rash.leeds.ac.uk; works off-VPN — two Duo approvals."
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var connectionRoute: ConnectionRoute = .directVPN
    @Published var username: String = ""
    @Published var password: String = ""
    @Published var aireHostname: String = "aire.leeds.ac.uk"
    @Published var jumpHostname: String = "rash.leeds.ac.uk"
    @Published var duoOption: String = "1"
    @Published var rememberPassword: Bool = true
    @Published var hasSavedPassword: Bool = false
    @Published var projectRoot: String = AppModel.defaultProjectRoot()

    @Published var isLoggingIn = false
    @Published var isRefreshing = false
    @Published var isLoggedIn = false
    @Published var hasCachedSnapshot = false
    @Published var statusMessage = "Not connected"
    @Published var errorMessage: String?
    @Published var loginProgress: String?
    @Published var keychainWarning: String?
    @Published var snapshot: ClusterSnapshot?
    @Published var history: [TrendPoint] = []

    /// True while the background refresh timer is suspended by the user.
    /// Login always clears it; resume triggers an immediate refresh.
    @Published var isPaused = false

    /// Human-readable notification permission state for the sidebar
    /// ("Allowed", "Denied — …", …). Re-queried asynchronously at startup,
    /// whenever the app becomes active (which catches the user answering the
    /// initial permission dialog and later changes made in System Settings),
    /// and after every refresh attempt, successful or failed.
    @Published var notificationAuthorizationSummary = "Checking…"

    /// User preference: alert when the fleet goes from zero idle GPUs to at
    /// least one. Persisted in UserDefaults; default off.
    @Published var notifyWhenGPUFrees: Bool = UserDefaults.standard.bool(forKey: AppModel.notifyWhenGPUFreesKey) {
        didSet {
            UserDefaults.standard.set(notifyWhenGPUFrees, forKey: AppModel.notifyWhenGPUFreesKey)
        }
    }

    private static let notifyWhenGPUFreesKey = "notifyWhenGPUFrees"
    /// Minimum spacing between GPU-free alerts so a flapping idle count
    /// (0 → 1 → 0 → 1…) cannot spam notifications.
    private let gpuFreeNotificationCooldown: TimeInterval = 600
    /// Fleet-wide idle GPU count from the previous successful refresh.
    /// Kept in memory only; a relaunch re-seeds it from the first snapshot.
    private var previousFleetIdleGPUs: Int?
    private var lastGPUFreeNotificationAt: Date?

    private let service = MonitorService()
    private let notificationService = JobNotificationService()
    private var backgroundTimer: Timer?
    private let backgroundRefreshInterval: TimeInterval = 10
    private let maximumRefreshInterval: TimeInterval = 60
    private let consecutiveFailuresBeforeLogout = 3
    @Published private var currentRefreshInterval: TimeInterval = 10
    private var consecutiveRefreshFailures = 0
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    /// Set by refreshAfterMutation() when a refresh cannot start right away;
    /// consumed exactly once by a refresh completion path (success or
    /// failure) to launch one follow-up refresh, so a post-mutation refresh
    /// request is never silently dropped.
    private var pendingRefresh = false
    private var cancellables: Set<AnyCancellable> = []

    /// The effective background refresh cadence, e.g. "10s". Grows with
    /// exponential backoff while refreshes keep failing.
    var refreshIntervalText: String {
        "\(Int(currentRefreshInterval))s"
    }

    init() {
        notificationService.configure()
        refreshNotificationAuthorizationStatus()
        let cache = SnapshotCache(projectRoot: projectRoot)
        if let profile = cache.loadConnectionProfile() {
            applyConnectionProfile(profile)
        }
        refreshSavedPasswordStatus()
        startSavedPasswordMonitoring()
        startActivationMonitoring()
        history = cache.loadHistory()
        if let cachedSnapshot = cache.loadLatestSnapshot() {
            snapshot = cachedSnapshot
            hasCachedSnapshot = true
            statusMessage = "Cached snapshot available • auto-refreshing every \(refreshIntervalText)"
            history = (try? cache.recordHistory(from: cachedSnapshot)) ?? history
            if cache.loadJobStateSnapshot() == nil {
                try? cache.saveJobStates(from: cachedSnapshot.jobs)
            }
        }
        warnIfProjectRootInvalid()
        startBackgroundRefresh()
        refresh(reason: .startupProbe)
    }

    private static func nonEmpty(_ value: String, default fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    var settings: ServerSettings {
        // Both routes use explicit (username-based) SSH; the rash route adds the
        // jump host. Alias mode is no longer surfaced, so useSSHAlias is always
        // false. The keychain account key and control-socket names derive from
        // these fields, so the rash route keeps the same identity it had when it
        // was reached via the old "explicit + jump host" toggles.
        ServerSettings(
            useSSHAlias: false,
            sshAlias: "aire",
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            // Default a blank host to aire.leeds.ac.uk so the app's snapshot
            // args, control-socket hash, and keychain account all agree with
            // the master the shell scripts build (they default it the same way).
            aireHostname: Self.nonEmpty(aireHostname, default: "aire.leeds.ac.uk"),
            useJumpHost: connectionRoute == .rashJump,
            jumpHostname: Self.nonEmpty(jumpHostname, default: "rash.leeds.ac.uk"),
            duoOption: duoOption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "1" : duoOption,
            projectRoot: projectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func login() {
        // Reentrancy guard: the password field's onSubmit path (and a racing
        // Login click) must not start a second concurrent SSH login, which
        // would tear down the first attempt's ControlMaster mid-auth and
        // trigger duplicate Duo pushes.
        guard !isLoggingIn else {
            return
        }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Username is required."
            return
        }
        if connectionRoute == .rashJump {
            guard !jumpHostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errorMessage = "Jump host is required for the rash jump route."
                return
            }
        }
        let loginSettings = settings
        let typedPassword = password
        let loginPassword: String
        if rememberPassword,
           typedPassword.isEmpty,
           let savedPassword = savedPassword(for: loginSettings) {
            loginPassword = savedPassword
        } else {
            loginPassword = typedPassword
        }
        guard !loginPassword.isEmpty else {
            errorMessage = rememberPassword
                ? "Password is required, or save it once in Keychain by logging in with Remember enabled."
                : "Password is required because Remember in Keychain is disabled."
            return
        }
        isLoggingIn = true
        // Logging in implicitly resumes monitoring: the completion paths
        // below restart the background timer, which stays disabled while
        // paused, so clear the pause first.
        isPaused = false
        stopBackgroundRefresh()
        errorMessage = nil
        loginProgress = nil
        statusMessage = connectionRoute == .rashJump
            ? "Logging in through jump host \(loginSettings.jumpHostname)"
            : "Logging in directly to \(loginSettings.aireHostname)"

        // Invalidate and stop any in-flight refresh so it cannot run over the
        // same ControlMaster socket while the login rebuilds the session, and
        // so its completion cannot clobber post-login state.
        refreshGeneration += 1
        let inFlightRefresh = refreshTask
        inFlightRefresh?.cancel()

        Task {
            if let inFlightRefresh {
                await inFlightRefresh.value
            }
            isRefreshing = false
            do {
                let output = try await service.login(
                    settings: loginSettings,
                    password: loginPassword
                ) { [weak self] status in
                    Task { @MainActor in
                        guard let self, self.isLoggingIn else {
                            return
                        }
                        self.loginProgress = status
                        self.statusMessage = status
                    }
                }
                persistPasswordIfNeeded(
                    typedPassword: typedPassword,
                    loginPassword: loginPassword,
                    loginSettings: loginSettings
                )
                try? SnapshotCache(projectRoot: loginSettings.projectRoot)
                    .saveConnectionProfile(ConnectionProfile(settings: loginSettings))
                isLoggedIn = true
                consecutiveRefreshFailures = 0
                updateRefreshInterval(to: backgroundRefreshInterval)
                password = ""
                statusMessage = loginSummary(from: output)
                loginProgress = nil
                isLoggingIn = false
                refresh(reason: .login)
            } catch {
                isLoggedIn = false
                isLoggingIn = false
                loginProgress = nil
                errorMessage = error.localizedDescription
                statusMessage = "Login failed"
                startBackgroundRefresh()
            }
        }
    }

    func refresh() {
        refresh(reason: .manual)
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
    /// from both refresh completion paths (success and failure) after the
    /// generation check; a refresh superseded by a login returns before the
    /// check and leaves the flag set for the login's own refresh to consume.
    /// Routing back through refreshAfterMutation() re-arms the flag if yet
    /// another refresh or login is somehow already running.
    private func consumePendingRefresh() {
        guard pendingRefresh else {
            return
        }
        pendingRefresh = false
        refreshAfterMutation()
    }

    private func refresh(reason: RefreshReason) {
        guard !isRefreshing && !isLoggingIn else {
            return
        }
        isRefreshing = true
        if reason.showsErrors {
            errorMessage = nil
        }
        if reason == .startupProbe && snapshot != nil {
            statusMessage = "Cached snapshot available • checking SSH session"
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
                // A login superseded this refresh; discard its outcome.
                return
            }
            isRefreshing = false
            switch result {
            case .success(let nextSnapshot):
                guard nextSnapshot.errors.isEmpty else {
                    handleRefreshFailure(
                        message: nextSnapshot.errors.joined(separator: "\n"),
                        settings: currentSettings,
                        showsErrors: reason.showsErrors
                    )
                    return
                }

                let cache = SnapshotCache(projectRoot: currentSettings.projectRoot)
                var previousJobState = cache.loadJobStateSnapshot()
                if let baseline = previousJobState, Self.isJobStateBaselineStale(baseline) {
                    // The baseline stopped advancing (e.g. notifications were
                    // unavailable for a long stretch, or the app was not
                    // running); diffing against it would replay long-resolved
                    // jobs as a burst of bogus started/ended notifications.
                    // Re-seed it from this snapshot and skip the diff.
                    previousJobState = nil
                    try? cache.saveJobStates(from: nextSnapshot.jobs)
                }
                try? cache.saveLatestSnapshot(nextSnapshot)
                history = (try? cache.recordHistory(from: nextSnapshot)) ?? cache.loadHistory()
                let processedJobDiff = await notificationService.notifyChanges(
                    previous: previousJobState,
                    current: nextSnapshot.jobs
                )
                if processedJobDiff {
                    try? cache.saveJobStates(from: nextSnapshot.jobs)
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
                    : "Last refresh \(Date().formatted(date: .omitted, time: .standard)) • cache updated"
                startBackgroundRefresh()
                refreshNotificationAuthorizationStatus()
                await handleGPUAvailabilityTransition(for: nextSnapshot)
                consumePendingRefresh()
            case .failure(let error):
                handleRefreshFailure(
                    message: error.localizedDescription,
                    settings: currentSettings,
                    showsErrors: reason.showsErrors
                )
            }
        }
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

    // MARK: - Monitoring pause

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
        if isPaused {
            resumeMonitoring()
        } else {
            pauseMonitoring()
        }
    }

    /// Status line shown while paused. Deliberately age-free: while paused
    /// no timer fires and no @Published property changes, so a relative age
    /// here would freeze at whatever it said when last rendered (or when
    /// pauseMonitoring snapshotted it into statusMessage). The adjacent
    /// StalenessBadge already ticks the snapshot age live via its own
    /// TimelineView.
    var pausedStatusText: String {
        guard let collectedAt = snapshot?.collectedAt, !collectedAt.isEmpty else {
            return "Paused — no snapshot collected yet"
        }
        return "Paused — last snapshot shown"
    }

    // MARK: - GPU-free alert

    /// Detects the fleet-wide 0 → >0 idle GPU transition (counting only
    /// available GPU nodes) and posts a local notification, subject to the
    /// user preference and a cooldown. The baseline normally advances to the
    /// current idle count so enabling the preference later starts from fresh
    /// data — except on the cooldown-suppressed path, where it stays at 0 so
    /// the transition re-fires once the cooldown expires (spacing the alert)
    /// instead of being dropped until the fleet next drains to zero.
    private func handleGPUAvailabilityTransition(for snapshot: ClusterSnapshot) async {
        let availableGPUNodes = snapshot.nodes.filter { gpuTotal($0) > 0 && isAvailable($0) }
        let idleGPUs = availableGPUNodes.reduce(0) { $0 + gpuIdle($1) }
        // The defer runs after any statements on an early-return path, so
        // the cooldown branch communicates its baseline through this local
        // override rather than assigning previousFleetIdleGPUs directly
        // (which the defer would immediately overwrite).
        var baselineOverride: Int?
        defer {
            previousFleetIdleGPUs = baselineOverride ?? idleGPUs
        }
        guard notifyWhenGPUFrees,
              let previousIdleGPUs = previousFleetIdleGPUs,
              previousIdleGPUs == 0,
              idleGPUs > 0 else {
            return
        }
        if let lastFired = lastGPUFreeNotificationAt,
           Date().timeIntervalSince(lastFired) < gpuFreeNotificationCooldown {
            // Suppressed by the cooldown: keep the baseline at 0 so this
            // 0 → >0 transition is re-detected on the first refresh after
            // the cooldown expires, not permanently swallowed.
            baselineOverride = 0
            return
        }
        let partitions = Array(
            Set(availableGPUNodes.filter { gpuIdle($0) > 0 }.flatMap(\.partitions))
        ).sorted()
        let fired = await notificationService.notifyGPUBecameAvailable(
            idleCount: idleGPUs,
            partitions: partitions
        )
        if fired {
            lastGPUFreeNotificationAt = Date()
        }
    }

    /// Refreshes the sidebar's notification-permission summary off the main
    /// thread (the authorization query is async under the hood).
    func refreshNotificationAuthorizationStatus() {
        let notificationService = notificationService
        Task { [weak self] in
            let summary = await notificationService.authorizationSummary()
            self?.notificationAuthorizationSummary = summary
        }
    }

    /// Re-queries the permission summary whenever the app becomes active.
    /// Dismissing the system authorization dialog re-activates the app, so
    /// this catches the user's answer to the prompt fired by configure() at
    /// startup, and it picks up grants or revocations made in System
    /// Settings even while refreshes are failing or monitoring is paused.
    private func startActivationMonitoring() {
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refreshNotificationAuthorizationStatus()
                }
            }
            .store(in: &cancellables)
    }

    private func startBackgroundRefresh() {
        // Never restart the timer while paused: failure handlers and late
        // completions route through here too.
        guard backgroundTimer == nil, !isPaused else {
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

    private func handleRefreshFailure(message: String, settings: ServerSettings, showsErrors: Bool) {
        consecutiveRefreshFailures += 1
        let backoff = backgroundRefreshInterval * pow(2, Double(max(consecutiveRefreshFailures - 1, 0)))
        updateRefreshInterval(to: min(backoff, maximumRefreshInterval))

        let cache = SnapshotCache(projectRoot: settings.projectRoot)
        if let cachedSnapshot = cache.loadLatestSnapshot() {
            snapshot = cachedSnapshot
            hasCachedSnapshot = true
            statusMessage = "Cached snapshot offline • retrying every \(refreshIntervalText)"
        } else if snapshot != nil {
            hasCachedSnapshot = true
            statusMessage = "Previous snapshot offline • retrying every \(refreshIntervalText)"
        } else {
            hasCachedSnapshot = false
            statusMessage = "Offline • retrying every \(refreshIntervalText)"
        }
        // A single failed refresh is usually a transient blip (VPN hiccup,
        // expect timeout); keep the session shown as connected-but-stale until
        // failures persist.
        if consecutiveRefreshFailures >= consecutiveFailuresBeforeLogout {
            isLoggedIn = false
        }
        if showsErrors {
            errorMessage = message
        }
        // Failed refreshes must also feed the permission summary; otherwise
        // an off-VPN launch would show "Not requested yet" until the first
        // successful refresh, which requires a login.
        refreshNotificationAuthorizationStatus()
        startBackgroundRefresh()
        consumePendingRefresh()
    }

    func openDesktopWidget() {
        let widgetApp = "\(settings.projectRoot)/.runtime/AIREDesktopWidget.app"
        let launcher = "\(settings.projectRoot)/scripts/run_desktop_widget.sh"

        if FileManager.default.fileExists(atPath: widgetApp) {
            statusMessage = "Opening desktop widget"
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: widgetApp),
                configuration: NSWorkspace.OpenConfiguration()
            ) { [weak self] _, error in
                guard let error else {
                    return
                }
                Task { @MainActor in
                    self?.errorMessage = "Could not open the desktop widget: \(error.localizedDescription)"
                }
            }
            return
        }

        guard FileManager.default.fileExists(atPath: launcher) else {
            errorMessage = "Desktop widget launcher is missing: \(launcher)"
            return
        }

        if runDetached(executable: "/bin/bash", arguments: [launcher]) {
            statusMessage = "Building desktop widget"
        }
    }

    func forgetSavedPassword() {
        let currentSettings = settings
        do {
            try KeychainPasswordStore.delete(account: currentSettings.keychainAccount)
            if let legacyAccount = currentSettings.legacyKeychainAccount {
                try KeychainPasswordStore.delete(account: legacyAccount)
            }
            keychainWarning = nil
            statusMessage = "Removed the saved password from Keychain"
        } catch {
            keychainWarning = "Could not remove the saved password: \(error.localizedDescription)"
        }
        refreshSavedPasswordStatus()
    }

    private func persistPasswordIfNeeded(
        typedPassword: String,
        loginPassword: String,
        loginSettings: ServerSettings
    ) {
        guard rememberPassword else {
            return
        }
        // Overwrite only when the user typed a new password or nothing is
        // readable for this account. load() distinguishes a locked keychain
        // from a genuinely missing item better than exists() did.
        let shouldSave = !typedPassword.isEmpty
            || KeychainPasswordStore.load(account: loginSettings.keychainAccount) == nil
        guard shouldSave else {
            refreshSavedPasswordStatus()
            return
        }
        do {
            try KeychainPasswordStore.save(loginPassword, account: loginSettings.keychainAccount)
            keychainWarning = nil
            // Complete the migration: the credential now lives under the new
            // account, so drop the legacy '<user>@leeds' entry.
            if let legacyAccount = loginSettings.legacyKeychainAccount {
                try? KeychainPasswordStore.delete(account: legacyAccount)
            }
        } catch {
            keychainWarning = "Password was not saved to Keychain: \(error.localizedDescription)"
        }
        refreshSavedPasswordStatus()
    }

    private func loginSummary(from output: String) -> String {
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
            return host.isEmpty ? "Connected" : "Connected to \(host)"
        }
        return "Connected"
    }

    /// Called when the user picks a different connection route. Each route has
    /// its own ControlMaster socket + keychain identity, so the current session
    /// (built for the previous route) is no longer "connected" under the new
    /// one. Drop the connected state and probe the new route's socket: if a
    /// master for it is already alive (e.g. switching back within the 24h
    /// window) the probe reconnects instantly; otherwise the user logs in.
    func handleRouteChange() {
        guard !isLoggingIn else {
            return
        }
        isLoggedIn = false
        consecutiveRefreshFailures = 0
        updateRefreshInterval(to: backgroundRefreshInterval)
        errorMessage = nil
        loginProgress = nil
        refreshSavedPasswordStatus()
        statusMessage = "Switched to \(connectionRoute.title) — checking for a live session…"
        refresh(reason: .automatic)
    }

    private func applyConnectionProfile(_ profile: ConnectionProfile) {
        // Map any saved profile — including legacy alias-mode ones — onto the two
        // supported routes: a saved jump-host profile restores the rash route,
        // everything else restores the direct/VPN route.
        connectionRoute = (!profile.useSSHAlias && profile.useJumpHost) ? .rashJump : .directVPN
        if !profile.username.isEmpty {
            username = profile.username
        }
        if !profile.aireHostname.isEmpty {
            aireHostname = profile.aireHostname
        }
        if !profile.jumpHostname.isEmpty {
            jumpHostname = profile.jumpHostname
        }
    }

    private func startSavedPasswordMonitoring() {
        Publishers.CombineLatest(
            Publishers.CombineLatest($connectionRoute, $username),
            Publishers.CombineLatest($aireHostname, $jumpHostname)
        )
        .dropFirst()
        .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            Task { @MainActor in
                self?.refreshSavedPasswordStatus()
            }
        }
        .store(in: &cancellables)
    }

    func refreshSavedPasswordStatus() {
        let currentSettings = settings
        Task { [weak self] in
            let hasPassword = await Self.savedPasswordExists(for: currentSettings)
            self?.hasSavedPassword = hasPassword
        }
    }

    private nonisolated static func savedPasswordExists(for settings: ServerSettings) async -> Bool {
        await Task.detached(priority: .utility) {
            let hasCurrentPassword = KeychainPasswordStore.exists(account: settings.keychainAccount)
            let hasLegacyPassword = settings.legacyKeychainAccount
                .map { KeychainPasswordStore.exists(account: $0) } ?? false
            return hasCurrentPassword || hasLegacyPassword
        }.value
    }

    private func savedPassword(for settings: ServerSettings) -> String? {
        if let password = KeychainPasswordStore.load(account: settings.keychainAccount) {
            return password
        }
        if let legacyAccount = settings.legacyKeychainAccount {
            return KeychainPasswordStore.load(account: legacyAccount)
        }
        return nil
    }

    @discardableResult
    private func runDetached(executable: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: settings.projectRoot)
        do {
            try process.run()
            return true
        } catch {
            errorMessage = "Could not launch \(executable): \(error.localizedDescription)"
            return false
        }
    }

    private func warnIfProjectRootInvalid() {
        let root = settings.projectRoot
        guard !FileManager.default.fileExists(atPath: "\(root)/scripts/aire_monitor_snapshot.py") else {
            return
        }
        errorMessage = """
        Project root \(root.isEmpty ? "(empty)" : "'\(root)'") does not contain scripts/aire_monitor_snapshot.py. \
        Set "Path to this project" to your checkout of this repository, or export AIRE_PROJECT_ROOT before launching.
        """
    }

    private static func defaultProjectRoot() -> String {
        if let environmentRoot = ProcessInfo.processInfo.environment["AIRE_PROJECT_ROOT"],
           FileManager.default.fileExists(atPath: "\(environmentRoot)/scripts/aire_monitor_snapshot.py") {
            return environmentRoot
        }

        let current = FileManager.default.currentDirectoryPath
        if FileManager.default.fileExists(atPath: "\(current)/scripts/aire_monitor_snapshot.py") {
            return current
        }

        let bundleRoot = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        if FileManager.default.fileExists(atPath: "\(bundleRoot)/scripts/aire_monitor_snapshot.py") {
            return bundleRoot
        }

        return current
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
