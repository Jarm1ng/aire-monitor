import AppKit
import Combine
import Foundation

/// What the dashboard window shows: the cross-cluster overview, or one
/// cluster's tabbed dashboard.
enum SidebarSelection: Hashable {
    case overview
    case cluster(ClusterID)

    var storageKey: String {
        switch self {
        case .overview: return "overview"
        case .cluster(let id): return "cluster:\(id.rawValue)"
        }
    }

    init?(storageKey: String?) {
        guard let storageKey else {
            return nil
        }
        if storageKey == "overview" {
            self = .overview
        } else if storageKey.hasPrefix("cluster:") {
            self = .cluster(ClusterID(String(storageKey.dropFirst("cluster:".count))))
        } else {
            return nil
        }
    }
}

/// App-wide coordinator. Owns the shared sign-in state (one university
/// account, one route, one Keychain item), the per-cluster sessions, the
/// serialized login chain and persistence. Everything cluster-specific
/// lives in `ClusterSession`.
@MainActor
final class AppModel: ObservableObject, ClusterSessionHost {
    @Published var username: String
    /// Transient: never persisted, cleared after a successful sign-in.
    @Published var password: String = ""
    @Published var connectionRoute: ConnectionRoute
    @Published var jumpHostname: String
    @Published var duoOption: String
    @Published var rememberPassword = true
    @Published private(set) var hasSavedPassword = false
    @Published var keychainWarning: String?
    @Published var projectRoot: String
    @Published var selection: SidebarSelection
    /// App-level problems (bad project root, widget launch failure). Cluster
    /// problems live on each session's own `errorMessage`.
    @Published var errorMessage: String?

    /// Human-readable notification permission state for the sidebar
    /// ("Allowed", "Denied — …", …). Re-queried asynchronously at startup,
    /// whenever the app becomes active (which catches the user answering the
    /// initial permission dialog and later changes made in System Settings),
    /// and after every refresh attempt, successful or failed.
    @Published var notificationAuthorizationSummary = "Checking…"

    /// User preference: alert when a cluster goes from zero idle GPUs to at
    /// least one. Persisted in UserDefaults; default off.
    @Published var notifyWhenGPUFrees: Bool = UserDefaults.standard.bool(forKey: AppModel.notifyWhenGPUFreesKey) {
        didSet {
            UserDefaults.standard.set(notifyWhenGPUFrees, forKey: AppModel.notifyWhenGPUFreesKey)
        }
    }

    private static let notifyWhenGPUFreesKey = "notifyWhenGPUFrees"
    static let keychainAccountPrefix = "leeds:"

    let sessions: [ClusterSession]
    let notificationService = JobNotificationService()

    /// Tail of the serialized login chain. Each sign-in request appends one
    /// link that awaits the previous one, so Duo pushes arrive one at a
    /// time and two logins never race to build the shared rash jump master.
    private var loginChain: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let root = Self.defaultProjectRoot()
        let preferences = PreferencesStore(projectRoot: root).load()
        projectRoot = root
        username = preferences.username
        connectionRoute = preferences.route
        jumpHostname = preferences.jumpHostname
        duoOption = preferences.duoOption
        selection = SidebarSelection(storageKey: preferences.selection) ?? .overview
        sessions = ClusterCatalog.all.map { profile in
            let saved = preferences.clusters[profile.id.rawValue]
            return ClusterSession(
                profile: profile,
                isEnabled: saved?.enabled ?? true,
                hostname: saved?.hostname
            )
        }
        if case .cluster(let id) = selection, session(for: id) == nil {
            selection = .overview
        }

        notificationService.configure()
        refreshNotificationAuthorizationStatus()
        for session in sessions {
            session.host = self
            // Forward session changes so views observing only the
            // coordinator (menu bar, overview) repaint too.
            session.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
        refreshSavedPasswordStatus()
        startSavedPasswordMonitoring()
        startActivationMonitoring()
        startPreferencePersistence()
        startRouteMonitoring()
        warnIfProjectRootInvalid()
        for session in sessions {
            session.start()
        }
    }

    // MARK: - Sessions

    func session(for id: ClusterID) -> ClusterSession? {
        sessions.first { $0.id == id }
    }

    var selectedSession: ClusterSession? {
        guard case .cluster(let id) = selection else {
            return nil
        }
        return session(for: id)
    }

    var enabledSessions: [ClusterSession] {
        sessions.filter(\.isEnabled)
    }

    var isAnyLoginActive: Bool {
        sessions.contains { $0.isLoggingIn || $0.isLoginQueued }
    }

    var isAnyRefreshing: Bool {
        sessions.contains { $0.isRefreshing }
    }

    var signInConfiguration: SignInConfiguration {
        SignInConfiguration(
            username: username,
            route: connectionRoute,
            jumpHostname: jumpHostname,
            duoOption: duoOption,
            projectRoot: projectRoot
        )
    }

    // MARK: - Sign-in

    /// Signs in to one cluster (forced re-login when it is already live).
    func connect(_ id: ClusterID) {
        guard let session = session(for: id) else {
            return
        }
        enqueueLogins(for: [session])
    }

    /// Signs in to every enabled cluster that is not live yet; when all are
    /// live it re-authenticates all of them.
    func connectAll() {
        let idle = enabledSessions.filter { !$0.isLoggedIn && !$0.isLoggingIn && !$0.isLoginQueued }
        let targets = idle.isEmpty
            ? enabledSessions.filter { !$0.isLoggingIn && !$0.isLoginQueued }
            : idle
        enqueueLogins(for: targets)
    }

    var connectAllTitle: String {
        let enabled = enabledSessions
        if !enabled.isEmpty, enabled.allSatisfy(\.isLoggedIn) {
            return "Reconnect all"
        }
        return enabled.count > 1 ? "Connect all" : "Connect"
    }

    private func enqueueLogins(for targets: [ClusterSession]) {
        let candidates = targets.filter { $0.isEnabled && !$0.isLoggingIn && !$0.isLoginQueued }
        guard !candidates.isEmpty else {
            return
        }
        let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty else {
            errorMessage = "Username is required."
            return
        }
        if connectionRoute == .rashJump,
           jumpHostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorMessage = "Jump host is required for the rash jump route."
            return
        }
        let typedPassword = password
        let loginPassword: String
        if rememberPassword, typedPassword.isEmpty, let saved = savedPassword(for: account) {
            loginPassword = saved
        } else {
            loginPassword = typedPassword
        }
        guard !loginPassword.isEmpty else {
            errorMessage = rememberPassword
                ? "Password is required, or save it once in Keychain by signing in with Remember enabled."
                : "Password is required because Remember in Keychain is disabled."
            return
        }
        errorMessage = nil
        for session in candidates {
            session.markLoginQueued()
        }

        let previous = loginChain
        let ids = candidates.map(\.id)
        let configuration = signInConfiguration
        loginChain = Task { [weak self] in
            await previous?.value
            for id in ids {
                guard let self, let session = self.session(for: id) else {
                    return
                }
                let outcome = await session.performLogin(password: loginPassword, configuration: configuration)
                switch outcome {
                case .succeeded:
                    self.persistPasswordIfNeeded(
                        typedPassword: typedPassword,
                        loginPassword: loginPassword,
                        account: account
                    )
                    if !typedPassword.isEmpty, self.password == typedPassword {
                        self.password = ""
                    }
                case .passwordRejected, .passwordExpired, .jumpHostFailed:
                    // Every queued login was about to send the same password
                    // (or retry the same shared rash leg); stop them all
                    // rather than pushing the account towards a lockout or
                    // sending pointless Duo pushes.
                    let reason: String
                    switch outcome {
                    case .passwordExpired:
                        reason = "Skipped — the password has expired (seen while signing in to \(session.displayName))"
                    case .jumpHostFailed:
                        reason = "Skipped — the rash jump host sign-in failed"
                    default:
                        reason = "Skipped — the password was rejected while signing in to \(session.displayName)"
                    }
                    for other in self.sessions {
                        other.cancelQueuedLogin(reason: reason)
                    }
                    return
                case .failed, .skipped:
                    continue
                }
            }
        }
    }

    func refreshAll() {
        for session in enabledSessions {
            session.refresh()
        }
    }

    /// See ClusterSession.refreshQuietly().
    func refreshAllQuietly() {
        for session in enabledSessions {
            session.refreshQuietly()
        }
    }

    /// Refreshes the selected cluster, or every cluster on the overview.
    func refreshSelection() {
        if let session = selectedSession {
            session.refresh()
        } else {
            refreshAll()
        }
    }

    // MARK: - Keychain

    /// One Keychain item for the university account: the same password
    /// unlocks rash, AIRE and Calder.
    private func keychainAccount(for user: String) -> String {
        "\(Self.keychainAccountPrefix)\(user)"
    }

    /// Accounts written by single-cluster releases: one per host and route,
    /// plus the original '<user>@leeds'. Read as a fallback and removed once
    /// the password is saved under the shared account.
    private func legacyKeychainAccounts(for user: String) -> [String] {
        var accounts: [String] = []
        let jump = jumpHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        for session in sessions {
            let host = session.settings.hostname
            accounts.append("explicit:\(user)@\(host):direct")
            if !jump.isEmpty {
                accounts.append("explicit:\(user)@\(host):via:\(jump)")
            }
        }
        accounts.append("\(user)@leeds")
        return accounts
    }

    private func savedPassword(for user: String) -> String? {
        if let password = KeychainPasswordStore.load(account: keychainAccount(for: user)) {
            return password
        }
        for legacy in legacyKeychainAccounts(for: user) {
            if let password = KeychainPasswordStore.load(account: legacy) {
                return password
            }
        }
        return nil
    }

    private func persistPasswordIfNeeded(typedPassword: String, loginPassword: String, account user: String) {
        guard rememberPassword else {
            return
        }
        let account = keychainAccount(for: user)
        // Overwrite only when the user typed a new password or nothing is
        // readable under the shared account yet (first run after upgrading).
        let shouldSave = !typedPassword.isEmpty || KeychainPasswordStore.load(account: account) == nil
        guard shouldSave else {
            refreshSavedPasswordStatus()
            return
        }
        do {
            try KeychainPasswordStore.save(loginPassword, account: account)
            keychainWarning = nil
            // Complete the migration: the credential now lives under the
            // shared account, so drop the per-host legacy entries.
            for legacy in legacyKeychainAccounts(for: user) {
                try? KeychainPasswordStore.delete(account: legacy)
            }
        } catch {
            keychainWarning = "Password was not saved to Keychain: \(error.localizedDescription)"
        }
        refreshSavedPasswordStatus()
    }

    func forgetSavedPassword() {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try KeychainPasswordStore.delete(account: keychainAccount(for: user))
            for legacy in legacyKeychainAccounts(for: user) {
                try KeychainPasswordStore.delete(account: legacy)
            }
            keychainWarning = nil
        } catch {
            keychainWarning = "Could not remove the saved password: \(error.localizedDescription)"
        }
        refreshSavedPasswordStatus()
    }

    func refreshSavedPasswordStatus() {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty else {
            hasSavedPassword = false
            return
        }
        let accounts = [keychainAccount(for: user)] + legacyKeychainAccounts(for: user)
        Task { [weak self] in
            let exists = await Task.detached(priority: .utility) {
                accounts.contains { KeychainPasswordStore.exists(account: $0) }
            }.value
            self?.hasSavedPassword = exists
        }
    }

    private func startSavedPasswordMonitoring() {
        Publishers.CombineLatest($username, $jumpHostname)
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refreshSavedPasswordStatus()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Preferences

    private var currentPreferences: AppPreferences {
        var preferences = AppPreferences()
        preferences.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        preferences.route = connectionRoute
        preferences.jumpHostname = jumpHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        preferences.duoOption = duoOption.trimmingCharacters(in: .whitespacesAndNewlines)
        preferences.selection = selection.storageKey
        for session in sessions {
            preferences.clusters[session.id.rawValue] = .init(
                enabled: session.isEnabled,
                hostname: session.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return preferences
    }

    /// Persists the password-free preferences shortly after any of them
    /// changes, coalescing keystrokes in the text fields.
    private func startPreferencePersistence() {
        var triggers: [AnyPublisher<Void, Never>] = [
            $username.map { _ in () }.eraseToAnyPublisher(),
            $connectionRoute.map { _ in () }.eraseToAnyPublisher(),
            $jumpHostname.map { _ in () }.eraseToAnyPublisher(),
            $duoOption.map { _ in () }.eraseToAnyPublisher(),
            $selection.map { _ in () }.eraseToAnyPublisher()
        ]
        for session in sessions {
            triggers.append(session.$isEnabled.map { _ in () }.eraseToAnyPublisher())
            triggers.append(session.$hostname.map { _ in () }.eraseToAnyPublisher())
        }
        Publishers.MergeMany(triggers)
            .dropFirst(triggers.count)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.savePreferences()
                }
            }
            .store(in: &cancellables)
    }

    func savePreferences() {
        let root = projectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else {
            return
        }
        try? PreferencesStore(projectRoot: root).save(currentPreferences)
    }

    /// Each route has its own ControlMaster sockets, so a route change
    /// re-probes every cluster under the new route.
    private func startRouteMonitoring() {
        $connectionRoute
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else {
                        return
                    }
                    for session in self.sessions {
                        session.connectionSettingsDidChange()
                    }
                    self.refreshSavedPasswordStatus()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Notifications

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

    // MARK: - Desktop widget

    func openDesktopWidget() {
        let root = projectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let widgetApp = "\(root)/.runtime/AIREDesktopWidget.app"
        let launcher = "\(root)/scripts/run_desktop_widget.sh"

        if FileManager.default.fileExists(atPath: widgetApp) {
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [launcher]
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        do {
            try process.run()
        } catch {
            errorMessage = "Could not launch the desktop widget builder: \(error.localizedDescription)"
        }
    }

    // MARK: - Project root

    private func warnIfProjectRootInvalid() {
        let root = projectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !FileManager.default.fileExists(atPath: "\(root)/\(MonitorService.collectorScript)") else {
            return
        }
        errorMessage = """
        Project root \(root.isEmpty ? "(empty)" : "'\(root)'") does not contain \(MonitorService.collectorScript). \
        Set "Project root" under Advanced to your checkout of this repository, or export HPC_PROJECT_ROOT before launching.
        """
    }

    private static func defaultProjectRoot() -> String {
        let marker = MonitorService.collectorScript
        let environment = ProcessInfo.processInfo.environment
        // AIRE_PROJECT_ROOT is the pre-multi-cluster name, still honoured.
        for key in ["HPC_PROJECT_ROOT", "AIRE_PROJECT_ROOT"] {
            if let root = environment[key], FileManager.default.fileExists(atPath: "\(root)/\(marker)") {
                return root
            }
        }

        let current = FileManager.default.currentDirectoryPath
        if FileManager.default.fileExists(atPath: "\(current)/\(marker)") {
            return current
        }

        let bundleRoot = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        if FileManager.default.fileExists(atPath: "\(bundleRoot)/\(marker)") {
            return bundleRoot
        }

        return current
    }
}
