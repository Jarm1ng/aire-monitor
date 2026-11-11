import HPCCore
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

/// A credential store with nothing in it (previews).
struct EmptyCredentialStore: CredentialStore {
    func password(for account: String) -> Result<String?, KeychainError> { .success(nil) }
    func save(_ password: String, for account: String) throws {}
    func delete(account: String) throws {}
    func exists(account: String) -> Bool { false }
}

/// App-wide coordinator. Owns the shared sign-in state (one university
/// account, one route, one Keychain item), the per-cluster sessions, the
/// serialized login chain and persistence. Everything cluster-specific
/// lives in `ClusterSession`.
///
/// Construction has no side effects (no Keychain, notification, SSH or
/// timer activity), so tests and previews can build one freely;
/// `start()`, called from applicationDidFinishLaunching, begins monitoring.
@MainActor
final class AppModel: ObservableObject, ClusterSessionHost {
    @Published var username: String
    /// Transient: never persisted, cleared after a successful sign-in.
    @Published var password: String = ""
    @Published var connectionRoute: ConnectionRoute
    @Published var jumpHostname: String
    @Published var duoOption: String
    /// "Remember in Keychain". Persisted with the other preferences, so an
    /// opt-out survives relaunch.
    @Published var rememberPassword: Bool {
        didSet {
            guard rememberPassword != oldValue else {
                return
            }
            // Unticking does not delete anything by itself; the sidebar asks
            // whether the item that is already saved should go too.
            set(\.offerToForgetSavedPassword, !rememberPassword && hasSavedPassword)
        }
    }
    /// Set when Remember was just switched off while a password is saved:
    /// the sidebar should ask "Also remove the saved password from
    /// Keychain?" and call `forgetSavedPassword()` or
    /// `dismissForgetSavedPasswordOffer()`.
    @Published private(set) var offerToForgetSavedPassword = false
    @Published private(set) var hasSavedPassword = false
    /// The server rejected the saved password (or demanded a change) the
    /// last time it was sent; it is not sent again until the user types a
    /// password that works, or forgets the saved one. Persisted per account.
    @Published private(set) var savedPasswordRejected = false
    @Published var keychainWarning: String?
    /// The Advanced "Project root" field. Edits are validated and applied
    /// after a short pause in typing (or at once via `commitProjectRoot`);
    /// sessions only ever see `appliedProjectRoot`, never a half-typed path.
    @Published var projectRoot: String
    @Published var selection: SidebarSelection
    /// App-level problems (bad project root, widget build failure, a cache
    /// that cannot be written, sign-in input errors). Cluster problems live
    /// on each session's own `errorMessage`. Dismiss with `dismissError()`.
    @Published var errorMessage: String?

    /// Human-readable notification permission state for the sidebar
    /// ("Allowed", "Denied — …", "Request failed: …").
    @Published private(set) var notificationAuthorizationSummary = "Checking…"
    /// What a button next to the summary should offer ("Request permission"
    /// while undetermined or failed, "Open System Settings" when denied).
    @Published private(set) var notificationPermissionAction: NotificationPermissionAction?

    /// User preference: alert when a cluster goes from zero idle GPUs to at
    /// least one. Persisted in UserDefaults; default off.
    @Published var notifyWhenGPUFrees: Bool {
        didSet {
            defaults.set(notifyWhenGPUFrees, forKey: Self.notifyWhenGPUFreesKey)
        }
    }

    /// The desktop widget is being built and launched (a few seconds).
    @Published private(set) var isPreparingDesktopWidget = false

    /// "Show what running jobs use": sample GPU, CPU and memory on the
    /// compute nodes about once a minute (see ClusterSession.wantsJobUsage).
    @Published var sampleJobUsage: Bool {
        didSet {
            guard sampleJobUsage != oldValue else {
                return
            }
            for session in sessions {
                session.jobUsageSamplingChanged(isOn: sampleJobUsage)
            }
        }
    }

    /// What the menu bar item shows next to its icon ("Show in Menu Bar").
    @Published var menuBarTitleMode: StatusTitleMode

    /// "Share sessions with Terminal": link the live masters into ~/.ssh so
    /// `ssh aire`, scp, rsync and Claude sessions ride them.
    @Published var shareSessions: Bool
    /// "Sign in again after a drop" (see `AutoReconnectPolicy`).
    @Published var reconnectAutomatically: Bool {
        didSet {
            if !reconnectAutomatically {
                autoReconnect.reset()
            }
        }
    }
    /// The last sharing pass: each live master's age, its stable link and
    /// what happened to every matching ~/.ssh/config alias.
    @Published private(set) var sharingReport = SessionSharingReport()
    /// The most recent drop of each cluster, for the Sessions card.
    @Published private(set) var lastDrops: [ClusterID: SessionDrop] = [:]
    @Published private(set) var autoReconnect = AutoReconnectPolicy()

    private static let notifyWhenGPUFreesKey = "notifyWhenGPUFrees"
    private static let projectRootKey = "projectRoot"
    private static let rejectedPasswordKeyPrefix = "savedPasswordRejected:"
    static let keychainAccountPrefix = "leeds:"

    let sessions: [ClusterSession]
    let notificationService: JobNotificationService

    private let defaults: UserDefaults
    private let credentials: CredentialStore
    /// The validated project root sessions use for scripts and caches.
    private(set) var appliedProjectRoot: String

    /// Tail of the serialized login chain. Each sign-in request appends one
    /// link that awaits the previous one, so Duo pushes arrive one at a
    /// time and two logins never race to build the shared rash jump master.
    private var loginChain: Task<Void, Never>?
    /// Bumped by `cancelLogins()`; every link stops once it no longer
    /// matches the generation it was created under — without touching any
    /// session's queued state, which by then may belong to a newer link.
    private var loginChainGeneration = 0
    private var cancellables: Set<AnyCancellable> = []
    private var heartbeat: Timer?
    private var widgetLauncher: Process?
    private var errorSource: ErrorSource?
    private var persistenceProblems: [ClusterID: String] = [:]
    private var hasStarted = false
    /// nil in tests and previews: they must never touch the real ~/.ssh.
    private let sharingService: SessionSharingService?
    private var sharingTask: Task<Void, Never>?
    private var sharingPassRequested = false
    private var continuityTimer: Timer?
    private var connectivity: ConnectivityMonitor?
    private var connectivityTask: Task<Void, Never>?
    /// Each shared master's start time from the last pass, kept so a drop
    /// can say how long the session lasted once its socket is gone.
    private var lastKnownSessionStart: [String: Date] = [:]

    private enum ErrorSource {
        case projectRoot
        case signIn
        case widget
        case persistence
    }

    /// The app's model: preferences from the detected project root, one
    /// session per catalogued cluster, the real Keychain and notification
    /// center.
    convenience init() {
        let defaults = UserDefaults.standard
        let root = Self.defaultProjectRoot(defaults: defaults)
        let preferences = PreferencesStore(projectRoot: root).load()
        let sessions = ClusterCatalog.all.map { profile in
            let saved = preferences.clusters[profile.id.rawValue]
            return ClusterSession(
                profile: profile,
                isEnabled: saved?.enabled ?? true,
                hostname: saved?.hostname
            )
        }
        self.init(
            sessions: sessions,
            preferences: preferences,
            projectRoot: root,
            defaults: defaults,
            credentials: KeychainCredentialStore(),
            notificationService: JobNotificationService(),
            sharingService: SessionSharingService()
        )
    }

    /// Designated initializer with every dependency injected (tests).
    init(
        sessions: [ClusterSession],
        preferences: AppPreferences,
        projectRoot: String,
        defaults: UserDefaults,
        credentials: CredentialStore,
        notificationService: JobNotificationService,
        sharingService: SessionSharingService? = nil
    ) {
        self.sessions = sessions
        self.sharingService = sharingService
        self.defaults = defaults
        self.credentials = credentials
        self.notificationService = notificationService
        self.projectRoot = projectRoot
        self.appliedProjectRoot = projectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        username = preferences.username
        connectionRoute = preferences.route
        jumpHostname = preferences.jumpHostname
        duoOption = preferences.duoOption
        rememberPassword = preferences.rememberPassword
        shareSessions = preferences.shareSessions
        sampleJobUsage = preferences.sampleJobUsage
        menuBarTitleMode = preferences.menuBarTitleMode
        reconnectAutomatically = preferences.reconnectAutomatically
        notifyWhenGPUFrees = defaults.bool(forKey: Self.notifyWhenGPUFreesKey)
        selection = SidebarSelection(storageKey: preferences.selection) ?? .overview
        if case .cluster(let id) = selection, !sessions.contains(where: { $0.id == id }) {
            selection = .overview
        }
        notificationAuthorizationSummary = notificationService.authorization.summary
        notificationPermissionAction = notificationService.authorization.permissionAction
        notificationService.onAuthorizationChange = { [weak self] authorization in
            self?.applyNotificationAuthorization(authorization)
        }
        for session in sessions {
            session.host = self
            // Forward session changes so views observing only the
            // coordinator (menu bar, overview) repaint too. Sessions publish
            // only real changes, so this stays cheap.
            session.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }

    #if DEBUG
    /// Preview/test model: wires the given sessions to this coordinator but
    /// starts nothing — no preferences or Keychain access, no notification
    /// prompt, no refresh timers, no SSH. Used by the offscreen preview
    /// renderer (scripts/render_previews.sh).
    convenience init(previewSessions: [ClusterSession], projectRoot: String, username: String = "preview-user") {
        var preferences = AppPreferences()
        preferences.username = username
        self.init(
            sessions: previewSessions,
            preferences: preferences,
            projectRoot: projectRoot,
            defaults: UserDefaults(suiteName: "local.aire.monitor.previews") ?? .standard,
            credentials: EmptyCredentialStore(),
            notificationService: JobNotificationService(poster: nil)
        )
        notificationAuthorizationSummary = "Allowed"
        notificationPermissionAction = nil
    }
    #endif

    /// Begins monitoring: notification permission, Keychain status,
    /// preference persistence, every session's cache and probe, and the
    /// widget-lease heartbeat. Called once, from applicationDidFinishLaunching
    /// (a notification request made while the app is still launching fails).
    func start() {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        Log.app.info("Starting with project root \(self.appliedProjectRoot, privacy: .private)")
        notificationService.configure()
        refreshSavedPasswordStatus()
        startSavedPasswordMonitoring()
        startActivationMonitoring()
        startPreferencePersistence()
        startRouteMonitoring()
        startProjectRootMonitoring()
        validateProjectRoot()
        for session in sessions {
            session.start()
        }
        startHeartbeat()
        startSessionContinuity()
    }

    /// App termination: cancels sign-ins (their helper process groups get
    /// SIGTERM synchronously, so a late Duo approval cannot build a master
    /// after the app is gone), flushes each session's cache and removes the
    /// widget leases, and saves preferences.
    func prepareForTermination() {
        cancelLogins()
        heartbeat?.invalidate()
        heartbeat = nil
        // The masters outlive the app, and so do their shared links.
        continuityTimer?.invalidate()
        continuityTimer = nil
        connectivity?.stop()
        for session in sessions {
            session.prepareForTermination()
        }
        if hasStarted {
            savePreferences()
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
            projectRoot: appliedProjectRoot
        )
    }

    var eventNotifier: ClusterEventNotifying? {
        notificationService
    }

    func session(_ session: ClusterSession, persistenceProblem: String?) {
        if let persistenceProblem {
            persistenceProblems[session.id] = persistenceProblem
            report(.persistence, persistenceProblem)
        } else {
            persistenceProblems[session.id] = nil
            if let remaining = persistenceProblems.values.first {
                report(.persistence, remaining)
            } else {
                clearError([.persistence])
            }
        }
    }

    // MARK: - Sign-in

    /// Plain sign-in to one cluster (the menu bar's Connect). Like every
    /// plain sign-in it reuses a healthy ControlMaster — no teardown, no
    /// Duo push — so it is safe even if the cluster turns out to be live.
    func connect(_ id: ClusterID) {
        guard let session = session(for: id) else {
            return
        }
        enqueueLogins(for: [session], forceReplace: false)
    }

    /// Enabled clusters that are not live, not already signing in, and not
    /// still on their startup / route-change probe — the only ones "Connect
    /// all" may touch. A probing cluster may be about to confirm a live
    /// master; signing it in now would race that probe for nothing.
    var sessionsNeedingSignIn: [ClusterSession] {
        enabledSessions.filter {
            !$0.isLoggedIn && !$0.isLoggingIn && !$0.isLoginQueued && $0.presentation.phase != .checking
        }
    }

    /// Signs in to every enabled cluster that is not live yet (plain
    /// sign-in: a healthy master is reused). It never touches a live
    /// cluster: replacing a ControlMaster kills every terminal, tail and vim
    /// multiplexed over it, so re-authenticating live sessions is a
    /// separate, confirmed action (`reconnect(_:)`), never a side effect of
    /// Connect or Return.
    func connectAll() {
        enqueueLogins(for: sessionsNeedingSignIn, forceReplace: false)
    }

    var connectAllTitle: String {
        enabledSessions.count > 1 ? "Connect all" : "Connect"
    }

    /// Plain sign-in for clusters that are not live (Connect, Connect all,
    /// Return in the password field). A healthy ControlMaster found on the
    /// way is reused — no teardown, no Duo push (HPC_FORCE_RELOGIN is not
    /// set).
    func signIn(_ ids: [ClusterID]) {
        enqueueLogins(for: ids.compactMap { session(for: $0) }, forceReplace: false)
    }

    /// Deliberately re-authenticates clusters: replaces each ControlMaster
    /// even when it is healthy (HPC_FORCE_RELOGIN=1, one Duo push each).
    /// Callers must confirm first: open terminals on those clusters close.
    func reconnect(_ ids: [ClusterID]) {
        enqueueLogins(for: ids.compactMap { session(for: $0) }, forceReplace: true)
    }

    /// "Renew all": signs in to `ids` again from scratch — on the rash
    /// route the shared jump master first — so every session's age starts
    /// over (the bedtime refresh before a long unattended stretch). Like
    /// Reconnect it replaces healthy masters, one Duo push per leg, so
    /// callers confirm first (`renewConfirmation()`).
    func renew(_ ids: [ClusterID]) {
        enqueueLogins(
            for: ids.compactMap { session(for: $0) },
            forceReplace: true,
            renewJumpHost: connectionRoute == .rashJump
        )
    }

    /// Signs out of one cluster: closes its ControlMaster, which ends every
    /// terminal and transfer on it — callers confirm first
    /// (`runningTerminalCount(on:)`). The last snapshot stays on screen.
    /// When this leaves nothing else on the rash route, the shared jump
    /// master is offered for closing too (the stop helper still keeps it if
    /// anything rides on it).
    func disconnect(_ id: ClusterID) {
        guard let session = session(for: id) else {
            return
        }
        let stopJump = Self.disconnectLeavesJumpHostUnused(session, among: sessions)
        autoReconnect.forget(id)
        Task {
            await session.disconnect(stopJumpIfUnused: stopJump)
        }
    }

    /// True when `leaving` is on the rash route and no other enabled
    /// cluster is live, signing in or queued through the same jump master.
    static func disconnectLeavesJumpHostUnused(_ leaving: ClusterSession, among sessions: [ClusterSession]) -> Bool {
        let target = leaving.settings
        guard target.useJumpHost, !target.jumpControlPath.isEmpty else {
            return false
        }
        return !sessions.contains { other in
            other !== leaving
                && other.isEnabled
                && (other.isLoggedIn || other.isLoggingIn || other.isLoginQueued)
                && other.settings.useJumpHost
                && other.settings.jumpControlPath == target.jumpControlPath
        }
    }

    /// Stops every queued and running sign-in. The running helper's process
    /// group is signalled at once, and no queued cluster sends a Duo push.
    func cancelLogins() {
        for id in autoReconnect.states.keys {
            autoReconnect.record(.cancelled, for: id, automatic: true, at: Date())
        }
        loginChainGeneration += 1
        // The tail link stops as soon as it resumes. It is deliberately kept
        // as `loginChain`: a sign-in requested right after this waits for
        // the cancelled chain to unwind instead of racing it.
        loginChain?.cancel()
        for session in sessions {
            session.cancelLogin()
        }
    }

    /// Terminal tabs whose ssh is still running on `ids` — what a reconnect
    /// or disconnect would end.
    func runningTerminalCount(on ids: [ClusterID]) -> Int {
        ids.compactMap { session(for: $0) }
            .reduce(0) { $0 + $1.terminals.sessions.filter(\.isRunning).count }
    }

    /// `automatic` marks a sign-in the app started by itself after a
    /// dropped session (`AutoReconnectPolicy`); its outcomes are recorded
    /// there so a declined or unanswered push is never followed by another.
    private func enqueueLogins(
        for targets: [ClusterSession],
        forceReplace: Bool,
        renewJumpHost: Bool = false,
        automatic: Bool = false
    ) {
        let candidates = targets.filter { $0.isEnabled && !$0.isLoggingIn && !$0.isLoginQueued }
        guard !candidates.isEmpty else {
            return
        }
        let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty else {
            report(.signIn, "Username is required.")
            return
        }
        if connectionRoute == .rashJump,
           jumpHostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            report(.signIn, "Jump host is required for the rash jump route.")
            return
        }
        let typedPassword = password
        let useSavedPassword = typedPassword.isEmpty && rememberPassword && !savedPasswordRejected
        guard !typedPassword.isEmpty || useSavedPassword else {
            report(.signIn, missingPasswordMessage)
            return
        }
        clearError([.signIn, .widget])
        for session in candidates {
            session.markLoginQueued()
        }

        let previous = loginChain
        let ids = candidates.map(\.id)
        let configuration = signInConfiguration
        let generation = loginChainGeneration
        let accounts = useSavedPassword ? [keychainAccount(for: account)] + legacyKeychainAccounts(for: account) : []
        let credentials = self.credentials
        loginChain = Task { [weak self] in
            var loginPassword: String? = typedPassword
            if useSavedPassword {
                // Off the main actor: a Keychain read can sit behind a
                // SecurityAgent prompt for as long as the user leaves it
                // (and awaiting it is not interrupted by a cancel).
                let lookup = await Task.detached(priority: .userInitiated) {
                    Self.lookUpSavedPassword(accounts: accounts, in: credentials)
                }.value
                loginPassword = self?.savedPassword(from: lookup, for: ids, generation: generation)
            }
            // Finish only after the link ahead, even with nothing to sign
            // in: the next link awaits this one, and must never overtake a
            // sign-in still running — or still unwinding from a cancel —
            // ahead of it.
            await previous?.value
            guard let loginPassword else {
                return
            }
            await self?.runLoginChain(
                ids: ids,
                password: loginPassword,
                typedPassword: typedPassword,
                usedSavedPassword: useSavedPassword,
                account: account,
                configuration: configuration,
                forceReplace: forceReplace,
                renewJumpHost: renewJumpHost,
                automatic: automatic,
                generation: generation
            )
        }
    }

    /// The saved password a link's Keychain lookup found, or nil after
    /// abandoning the link's queue with the reason. A link cancelled while
    /// its lookup waited (behind a SecurityAgent prompt, say) returns nil
    /// without touching any session: `cancelLogins()` already un-queued its
    /// clusters, and whatever is queued on them now belongs to a newer link.
    private func savedPassword(from lookup: SavedPasswordLookup, for ids: [ClusterID], generation: Int) -> String? {
        guard loginChainGeneration == generation, !Task.isCancelled else {
            return nil
        }
        switch lookup {
        case .found(let saved):
            return saved
        case .notFound:
            abandonQueuedLogins(ids, error: missingPasswordMessage)
        case .denied:
            abandonQueuedLogins(
                ids,
                error: "Keychain access was denied — type your password, or allow access when macOS asks."
            )
        case .failed(let reason):
            abandonQueuedLogins(
                ids,
                error: "Could not read the saved password from Keychain (\(reason)) — type your password."
            )
        }
        return nil
    }

    private func runLoginChain(
        ids: [ClusterID],
        password loginPassword: String,
        typedPassword: String,
        usedSavedPassword: Bool,
        account: String,
        configuration: SignInConfiguration,
        forceReplace: Bool,
        renewJumpHost: Bool,
        automatic: Bool,
        generation: Int
    ) async {
        // Only the first cluster that actually signs in renews the shared
        // jump master; the others ride the new one.
        var jumpRenewalPending = renewJumpHost
        for (index, id) in ids.enumerated() {
            // A cancelled link stops without touching any session:
            // `cancelLogins()` already un-queued every cluster it held, and
            // a cluster queued again since belongs to a newer link (maybe
            // with a newly typed password) that must not be dropped.
            guard loginChainGeneration == generation, !Task.isCancelled else {
                return
            }
            guard let session = session(for: id) else {
                continue
            }
            let outcome = await session.performLogin(
                password: loginPassword,
                configuration: configuration,
                forceReplace: forceReplace,
                renewJumpHost: jumpRenewalPending
            )
            if outcome != .skipped {
                jumpRenewalPending = false
            }
            autoReconnect.record(outcome, for: id, automatic: automatic, at: Date())
            // Cancelled while this cluster signed in: its own outcome is
            // still handled below, but the clusters after it are left alone,
            // as above.
            let isCurrent = loginChainGeneration == generation
            switch outcome {
            case .succeeded(let passwordVerified):
                // Only a password a server just accepted may replace the
                // saved one or lift its "rejected" flag. A sign-in that
                // merely reused open sessions never sent it.
                if passwordVerified {
                    persistPasswordIfNeeded(typedPassword: typedPassword, loginPassword: loginPassword, account: account)
                }
                if !typedPassword.isEmpty, password == typedPassword {
                    password = ""
                }
            case .passwordRejected, .passwordExpired, .jumpHostFailed, .duoNotApproved:
                if usedSavedPassword, outcome == .passwordRejected || outcome == .passwordExpired {
                    // Never send a known-bad saved password again (each
                    // attempt counts toward the account lockout). A Duo
                    // push that was not approved says nothing about the
                    // password — it was accepted — so it is never flagged.
                    flagSavedPasswordRejected(account: account)
                }
                // Every queued login was about to send the same password,
                // retry the same shared rash leg, or push another Duo
                // request nobody is approving; stop them all rather than
                // pushing the account towards a lockout or sending
                // pointless Duo pushes.
                let reason: String
                switch outcome {
                case .passwordExpired:
                    reason = "Skipped — the password has expired (seen while signing in to \(session.displayName))"
                case .jumpHostFailed:
                    reason = "Skipped — the rash jump host sign-in failed"
                case .duoNotApproved:
                    reason = "Skipped — Duo approval was not completed for \(session.displayName)"
                default:
                    reason = "Skipped — the password was rejected while signing in to \(session.displayName)"
                }
                // Deliberately not limited to this link's clusters, even when
                // it was cancelled meanwhile: a newer link may be about to
                // send the very password that was just refused.
                for other in sessions {
                    other.cancelQueuedLogin(reason: reason)
                }
                return
            case .timedOut, .cancelled:
                // Nobody is answering Duo (or the user said stop): do not
                // push the next cluster at them.
                let reason = outcome == .cancelled
                    ? "Sign-in cancelled"
                    : "Skipped — the sign-in to \(session.displayName) timed out waiting for Duo"
                if isCurrent {
                    for remaining in ids[(index + 1)...] {
                        self.session(for: remaining)?.cancelQueuedLogin(reason: reason)
                    }
                }
                return
            case .failed, .skipped:
                continue
            }
        }
    }

    private func abandonQueuedLogins(_ ids: [ClusterID], error: String) {
        for id in ids {
            session(for: id)?.cancelQueuedLogin(reason: "Sign-in needs your password")
        }
        report(.signIn, error)
    }

    private var missingPasswordMessage: String {
        if !rememberPassword {
            return "Password is required because Remember in Keychain is disabled."
        }
        if savedPasswordRejected {
            return "The saved password was rejected — type the new password."
        }
        return "Password is required, or save it once in Keychain by signing in with Remember enabled."
    }

    /// Refreshes every enabled cluster. Each session decides how: clusters
    /// with no master (never signed in, signed out) or still on their first
    /// probe are probed quietly instead of painting a red "control master
    /// is not running" error (see ClusterSession.refresh()).
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
            let host = session.configuredSettings.hostname
            accounts.append("explicit:\(user)@\(host):direct")
            if !jump.isEmpty {
                accounts.append("explicit:\(user)@\(host):via:\(jump)")
            }
        }
        accounts.append("\(user)@leeds")
        return accounts
    }

    private enum SavedPasswordLookup: Sendable {
        case found(String)
        case notFound
        case denied
        case failed(String)
    }

    /// Shared account first, then the legacy ones. Runs off the main actor.
    nonisolated private static func lookUpSavedPassword(accounts: [String], in credentials: CredentialStore) -> SavedPasswordLookup {
        var failure: KeychainError?
        for account in accounts {
            switch credentials.password(for: account) {
            case .success(let password?):
                return .found(password)
            case .success(nil):
                continue
            case .failure(let error):
                if case .accessDenied = error {
                    // One denied prompt answers for every item: do not raise
                    // six more.
                    Log.keychain.error("Keychain access denied while reading the saved password")
                    return .denied
                }
                failure = failure ?? error
            }
        }
        if let failure {
            Log.keychain.error("Keychain read failed: \(failure.localizedDescription, privacy: .public)")
            return .failed(failure.localizedDescription)
        }
        return .notFound
    }

    private func persistPasswordIfNeeded(typedPassword: String, loginPassword: String, account user: String) {
        guard rememberPassword else {
            return
        }
        let account = keychainAccount(for: user)
        let legacy = legacyKeychainAccounts(for: user)
        let credentials = self.credentials
        let typed = !typedPassword.isEmpty
        Task { [weak self] in
            let outcome: Result<Bool, Error> = await Task.detached(priority: .utility) {
                // Overwrite only when the user typed a new password or
                // nothing is readable under the shared account yet (first
                // run after upgrading).
                if !typed, case .success(.some) = credentials.password(for: account) {
                    return .success(false)
                }
                do {
                    try credentials.save(loginPassword, for: account)
                    // Complete the migration: the credential now lives under
                    // the shared account, so drop the per-host legacy entries.
                    for legacyAccount in legacy {
                        do {
                            try credentials.delete(account: legacyAccount)
                        } catch {
                            Log.keychain.error("Could not remove a legacy Keychain item: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                    return .success(true)
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else {
                return
            }
            switch outcome {
            case .success(let saved):
                if saved {
                    self.keychainWarning = nil
                    if typed {
                        // A typed password just worked and is now the saved
                        // one: the old rejection no longer applies.
                        self.clearSavedPasswordRejected(account: user)
                    }
                }
            case .failure(let error):
                Log.keychain.error("Saving the password failed: \(error.localizedDescription, privacy: .public)")
                self.keychainWarning = "Password was not saved to Keychain: \(error.localizedDescription)"
            }
            self.refreshSavedPasswordStatus()
        }
    }

    func forgetSavedPassword() {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let accounts = [keychainAccount(for: user)] + legacyKeychainAccounts(for: user)
        let credentials = self.credentials
        set(\.offerToForgetSavedPassword, false)
        clearSavedPasswordRejected(account: user)
        Task { [weak self] in
            let failure: String? = await Task.detached(priority: .userInitiated) {
                for account in accounts {
                    do {
                        try credentials.delete(account: account)
                    } catch {
                        return error.localizedDescription
                    }
                }
                return nil
            }.value
            guard let self else {
                return
            }
            self.keychainWarning = failure.map { "Could not remove the saved password: \($0)" }
            self.refreshSavedPasswordStatus()
        }
    }

    func dismissForgetSavedPasswordOffer() {
        set(\.offerToForgetSavedPassword, false)
    }

    /// Whether an empty password field will fall back to the saved password.
    var savedPasswordWillBeUsed: Bool {
        rememberPassword && hasSavedPassword && !savedPasswordRejected
    }

    func refreshSavedPasswordStatus() {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        set(\.savedPasswordRejected, !user.isEmpty && defaults.bool(forKey: Self.rejectedPasswordKeyPrefix + user))
        guard !user.isEmpty else {
            set(\.hasSavedPassword, false)
            return
        }
        let accounts = [keychainAccount(for: user)] + legacyKeychainAccounts(for: user)
        let credentials = self.credentials
        Task { [weak self] in
            let exists = await Task.detached(priority: .utility) {
                accounts.contains { credentials.exists(account: $0) }
            }.value
            self?.set(\.hasSavedPassword, exists)
        }
    }

    private func flagSavedPasswordRejected(account user: String) {
        defaults.set(true, forKey: Self.rejectedPasswordKeyPrefix + user)
        set(\.savedPasswordRejected, true)
        keychainWarning = "The saved password was rejected — type the new password."
        Log.keychain.info("The saved password was rejected; it will not be sent again")
    }

    private func clearSavedPasswordRejected(account user: String) {
        defaults.removeObject(forKey: Self.rejectedPasswordKeyPrefix + user)
        set(\.savedPasswordRejected, false)
    }

    private func startSavedPasswordMonitoring() {
        Publishers.CombineLatest($username, $jumpHostname)
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
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
        preferences.rememberPassword = rememberPassword
        preferences.shareSessions = shareSessions
        preferences.sampleJobUsage = sampleJobUsage
        preferences.menuBarTitleMode = menuBarTitleMode
        preferences.reconnectAutomatically = reconnectAutomatically
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
            $rememberPassword.map { _ in () }.eraseToAnyPublisher(),
            $shareSessions.map { _ in () }.eraseToAnyPublisher(),
            $sampleJobUsage.map { _ in () }.eraseToAnyPublisher(),
            $menuBarTitleMode.map { _ in () }.eraseToAnyPublisher(),
            $reconnectAutomatically.map { _ in () }.eraseToAnyPublisher(),
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
                MainActor.assumeIsolated {
                    self?.savePreferences()
                }
            }
            .store(in: &cancellables)
    }

    func savePreferences() {
        let root = appliedProjectRoot
        guard !root.isEmpty else {
            return
        }
        do {
            try PreferencesStore(projectRoot: root).save(currentPreferences)
        } catch {
            Log.cache.error("Could not save preferences: \(String(describing: error), privacy: .public)")
            report(.persistence, "Could not save preferences under \(root)/.runtime: \(error.localizedDescription)")
        }
    }

    /// Each route has its own ControlMaster sockets, so a route change
    /// closes the previous route's masters and re-probes every cluster under
    /// the new route.
    private func startRouteMonitoring() {
        $connectionRoute
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                // @Published emits from willSet: read the new value on the
                // next turn, once the property holds it.
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

    private func applyNotificationAuthorization(_ authorization: NotificationAuthorization) {
        set(\.notificationAuthorizationSummary, authorization.summary)
        set(\.notificationPermissionAction, authorization.permissionAction)
    }

    /// Re-reads the notification permission (no prompt).
    func refreshNotificationAuthorizationStatus() {
        notificationService.refreshAuthorization(requestIfUndetermined: false)
    }

    /// The sidebar's permission button: request again, or open System
    /// Settings when denied.
    func performNotificationPermissionAction() {
        notificationService.performPermissionAction()
    }

    /// Whenever the app becomes active: picks up grants or revocations made
    /// in System Settings, and asks again while the permission is still
    /// undetermined (e.g. the launch-time request failed).
    private func startActivationMonitoring() {
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.notificationService.refreshAuthorization(requestIfUndetermined: true)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Shared sessions, drops and automatic sign-in

    /// Every live master other programs may ride: each live cluster's own,
    /// and on the rash route the shared jump master (as "rash").
    var sharedMasters: [SharedMaster] {
        var masters: [SharedMaster] = []
        for session in enabledSessions where session.isLoggedIn {
            guard let live = session.activeConnection else {
                continue
            }
            masters.append(SharedMaster(
                name: session.id.rawValue,
                displayName: session.displayName,
                hostname: live.hostname,
                username: live.username,
                socketPath: live.controlPath
            ))
            if live.useJumpHost, !live.jumpControlPath.isEmpty,
               !masters.contains(where: { $0.socketPath == live.jumpControlPath }) {
                let label = live.jumpHostname.split(separator: ".").first.map(String.init) ?? ""
                let usable = SessionSharing.isLiteralAlias(label) && !masters.contains { $0.name == label }
                masters.append(SharedMaster(
                    name: usable ? label : "jump",
                    displayName: label.isEmpty ? live.jumpHostname : label,
                    hostname: live.jumpHostname,
                    username: live.username,
                    socketPath: live.jumpControlPath
                ))
            }
        }
        return masters
    }

    private func startSessionContinuity() {
        var sharingTriggers: [AnyPublisher<Void, Never>] = [
            $shareSessions.map { _ in () }.eraseToAnyPublisher(),
            $connectionRoute.map { _ in () }.eraseToAnyPublisher()
        ]
        for session in sessions {
            sharingTriggers.append(session.$isLoggedIn.map { _ in () }.eraseToAnyPublisher())
            sharingTriggers.append(session.$activeConnection.map { _ in () }.eraseToAnyPublisher())
            sharingTriggers.append(session.$hasCompletedFirstProbe.map { _ in () }.eraseToAnyPublisher())
            session.$droppedAt
                .dropFirst()
                .compactMap { $0 }
                .removeDuplicates()
                .sink { [weak self, weak session] date in
                    MainActor.assumeIsolated {
                        guard let self, let session else {
                            return
                        }
                        self.sessionDropped(session, at: date)
                    }
                }
                .store(in: &cancellables)
        }
        Publishers.MergeMany(sharingTriggers)
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleSharingPass()
                }
            }
            .store(in: &cancellables)

        // Sharing passes pick up aliases freed by masters that ended on
        // their own (the user's own `ssh aire-rash`, say) and the timers in
        // the Sessions card; the policy checks whether a dropped cluster
        // may be signed in again now that the user is back at the Mac.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleSharingPass()
                self?.considerAutomaticSignIn()
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        continuityTimer = timer

        let monitor = ConnectivityMonitor { [weak self] change in
            self?.connectivityChanged(change)
        }
        monitor.start()
        connectivity = monitor
    }

    /// Runs a sharing pass soon; passes requested while one runs coalesce
    /// into one more.
    func scheduleSharingPass() {
        guard let sharingService, hasStarted else {
            return
        }
        sharingPassRequested = true
        guard sharingTask == nil else {
            return
        }
        sharingTask = Task { [weak self] in
            while let self, self.sharingPassRequested {
                self.sharingPassRequested = false
                // Until every cluster's startup probe has answered, "not
                // live" may only mean "not checked yet": a pass now would
                // remove links to masters that are fine.
                guard self.enabledSessions.allSatisfy(\.hasCompletedFirstProbe) else {
                    break
                }
                let report = await sharingService.reconcile(masters: self.sharedMasters, share: self.shareSessions)
                self.applySharingReport(report)
            }
            self?.sharingTask = nil
        }
    }

    private func applySharingReport(_ report: SessionSharingReport) {
        for status in report.sessions {
            lastKnownSessionStart[status.name] = status.since
        }
        set(\.sharingReport, report)
    }

    /// How long `id`'s session has been up, from its master's socket.
    func sessionAge(of id: ClusterID, now: Date = Date()) -> TimeInterval? {
        sharingReport.session(named: id.rawValue)?.since.map { now.timeIntervalSince($0) }
    }

    private func sessionDropped(_ session: ClusterSession, at date: Date) {
        let lasted = lastKnownSessionStart[session.id.rawValue].map { date.timeIntervalSince($0) }
        lastDrops[session.id] = SessionDrop(at: date, lasted: lasted)
        let willSignIn = reconnectAutomatically && canSignInAutomatically
        Log.sharing.info(
            "\(session.id.rawValue, privacy: .public): dropped after \(lasted.map { SessionAge.text($0) } ?? "an unknown time", privacy: .public); automatic sign-in \(willSignIn ? "allowed" : "off or not possible", privacy: .public)"
        )
        if reconnectAutomatically {
            autoReconnect.sessionDropped(session.id, at: date)
        }
        notificationService.notifySessionDropped(cluster: session.profile, lasted: lasted, signingInAgain: willSignIn)
        scheduleSharingPass()
        considerAutomaticSignIn()
    }

    #if DEBUG
    /// Preview/test hook: shows these sessions, drops and automatic sign-in
    /// states without touching ~/.ssh.
    func installPreviewSharing(
        _ report: SessionSharingReport,
        drops: [ClusterID: SessionDrop] = [:],
        dropped: [ClusterID] = [],
        hasSavedPassword: Bool = false
    ) {
        sharingReport = report
        self.hasSavedPassword = hasSavedPassword
        lastDrops = drops
        for id in dropped {
            autoReconnect.sessionDropped(id, at: Date())
        }
    }
    #endif

    /// A saved password the app may send without asking.
    private var canSignInAutomatically: Bool {
        rememberPassword && hasSavedPassword && !savedPasswordRejected
    }

    /// Signs dropped clusters in again when the policy says one is due and
    /// the user is at the Mac with a working network. A plain sign-in: a
    /// master that survived is reused without a push.
    func considerAutomaticSignIn(now: Date = Date()) {
        guard reconnectAutomatically, !autoReconnect.isEmpty else {
            return
        }
        // Back on its own (a probe found the master answering again).
        for id in autoReconnect.states.keys where session(for: id).map({ $0.isLoggedIn || !$0.isEnabled }) ?? true {
            autoReconnect.forget(id)
        }
        autoReconnect.sweepLostAttempts(at: now)
        guard !isAnyLoginActive, canSignInAutomatically,
              connectivity?.isNetworkAvailable ?? true,
              UserPresence.isActive() else {
            return
        }
        let due = autoReconnect.due(at: now).compactMap { session(for: $0) }
        guard !due.isEmpty else {
            return
        }
        for session in due {
            autoReconnect.attemptStarted(session.id, at: now)
        }
        Log.sharing.info("Signing in again automatically: \(due.map(\.id.rawValue).joined(separator: ", "), privacy: .public)")
        enqueueLogins(for: due, forceReplace: false, automatic: true)
        for session in due where !session.isLoginQueued && !session.isLoggingIn {
            autoReconnect.record(.skipped, for: session.id, automatic: true, at: now)
        }
    }

    /// Wake or a new network: look at every session now rather than at the
    /// next (possibly backed-off) refresh, once the network had a moment.
    private func connectivityChanged(_ change: ConnectivityMonitor.Change) {
        Log.sharing.info("Connectivity changed (\(change.rawValue, privacy: .public)); checking every session")
        connectivityTask?.cancel()
        connectivityTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(change == .wake ? 5 : 3))
            guard let self, !Task.isCancelled else {
                return
            }
            self.refreshAllQuietly()
            await self.sharingService?.invalidateAliases()
            self.scheduleSharingPass()
            self.considerAutomaticSignIn()
        }
    }

    // MARK: - Widget lease heartbeat

    /// Paused and switched-off clusters never refresh, so their lease would
    /// expire and the widget would start collecting behind the user's back.
    private func startHeartbeat() {
        heartbeat?.invalidate()
        let timer = Timer(timeInterval: ClusterAppState.heartbeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                for session in self?.sessions ?? [] {
                    session.writeAppState()
                }
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    // MARK: - Desktop widget

    /// The launcher's own build log, relative to the project root. The
    /// script truncates and writes it itself, so the Process must never be
    /// pointed at it.
    nonisolated static let widgetBuildLog = ".runtime/swift-widget-build.log"
    /// Where the launcher's stdout/stderr go instead: a file rather than a
    /// pipe, because the script may start the widget binary directly and
    /// the widget inherits these descriptors — a pipe the app stopped
    /// reading would block or SIGPIPE the widget.
    nonisolated static let widgetLauncherOutput = ".runtime/widget-launcher.log"
    /// scripts/build_bundle.sh: another build of this checkout held the
    /// build lock for too long.
    nonisolated static let widgetBuildBusyExitCode: Int32 = 75

    /// Builds (incrementally) and relaunches the desktop widget through
    /// scripts/run_desktop_widget.sh. The script is always run, never
    /// skipped because a bundle already exists: opening an existing bundle
    /// launched a months-old single-cluster build that nothing ever
    /// rebuilt. When the bundle is current it only brings the widget
    /// forward. A second click while it runs is ignored; a failure shows
    /// the tail of the build log.
    func openDesktopWidget() {
        guard widgetLauncher == nil else {
            return
        }
        let root = appliedProjectRoot
        let launcher = "\(root)/scripts/run_desktop_widget.sh"
        guard FileManager.default.fileExists(atPath: launcher) else {
            report(.widget, "Desktop widget launcher is missing: \(launcher)")
            return
        }

        var environment = MonitorService.childEnvironment()
        // The widget validates this against scripts/hpc_snapshot.py, so a
        // bundle that was moved or copied still finds the checkout.
        environment["HPC_PROJECT_ROOT"] = root

        // stdout is a few status lines; stderr carries the script's own
        // error summary, for a failure before the build log was written.
        let outputURL = URL(fileURLWithPath: root).appendingPathComponent(Self.widgetLauncherOutput)
        let outputHandle: FileHandle
        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            outputHandle = try FileHandle(forWritingTo: outputURL)
        } catch {
            report(.widget, "Could not prepare \(Self.widgetLauncherOutput): \(error.localizedDescription)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [launcher]
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        let launchedAt = Date()
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            try? outputHandle.close()
            Task { @MainActor in
                self?.desktopWidgetLauncherFinished(status: status, root: root, launchedAt: launchedAt)
            }
        }
        do {
            try process.run()
            widgetLauncher = process
            set(\.isPreparingDesktopWidget, true)
            Log.app.info("Building and launching the desktop widget")
        } catch {
            try? outputHandle.close()
            report(.widget, "Could not launch the desktop widget builder: \(error.localizedDescription)")
        }
    }

    private func desktopWidgetLauncherFinished(status: Int32, root: String, launchedAt: Date) {
        widgetLauncher = nil
        set(\.isPreparingDesktopWidget, false)
        guard status != 0 else {
            clearError([.widget])
            return
        }
        Log.app.error("Desktop widget launcher exited \(status, privacy: .public)")
        if status == Self.widgetBuildBusyExitCode {
            report(.widget, "Another build of this checkout is still running, so the desktop widget was not opened. Try again once it has finished.")
            return
        }
        report(.widget, Self.widgetFailureMessage(
            status: status,
            buildLog: Self.freshLog(Self.widgetBuildLog, root: root, since: launchedAt),
            launcherOutput: Self.freshLog(Self.widgetLauncherOutput, root: root, since: launchedAt) ?? ""
        ))
    }

    /// A log's text, only if this run wrote it (an older build log would
    /// describe a different failure).
    private static func freshLog(_ relativePath: String, root: String, since launchedAt: Date) -> String? {
        let path = "\(root)/\(relativePath)"
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date,
              modified >= launchedAt.addingTimeInterval(-1) else {
            return nil
        }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// The error for a failed launcher run: the last few lines of the build
    /// log (the script ends it with the compiler errors and a final
    /// `build_bundle.sh: error:` line), else of the launcher's own output.
    nonisolated static func widgetFailureMessage(status: Int32, buildLog: String?, launcherOutput: String) -> String {
        func tail(_ text: String) -> String {
            text.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .suffix(5)
                .joined(separator: "\n")
        }
        let logTail = buildLog.map(tail) ?? ""
        let details = logTail.isEmpty ? tail(launcherOutput) : logTail
        return "The desktop widget could not be built or launched (exit \(status))."
            + (details.isEmpty ? "" : "\n\n\(details)")
            + (buildLog == nil ? "" : "\n\nFull log: \(widgetBuildLog)")
    }

    // MARK: - Errors

    private func report(_ source: ErrorSource, _ message: String) {
        errorSource = source
        set(\.errorMessage, message)
    }

    private func clearError(_ sources: Set<ErrorSource>) {
        guard let errorSource, sources.contains(errorSource) else {
            return
        }
        self.errorSource = nil
        set(\.errorMessage, nil)
    }

    /// The ✕ on the app-level error box.
    func dismissError() {
        errorSource = nil
        set(\.errorMessage, nil)
    }

    private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    // MARK: - Project root

    /// Applies a project root at once (the field's submit action).
    func commitProjectRoot(_ value: String) {
        if projectRoot != value {
            projectRoot = value
        }
        applyProjectRoot(value)
    }

    private func startProjectRootMonitoring() {
        $projectRoot
            .dropFirst()
            .debounce(for: .milliseconds(800), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] value in
                MainActor.assumeIsolated {
                    self?.applyProjectRoot(value)
                }
            }
            .store(in: &cancellables)
    }

    /// Validates the root; a valid new one becomes the applied root: it is
    /// remembered (UserDefaults, outside the root itself), every session
    /// re-reads its cache there, and preferences are saved there. An
    /// invalid one only shows the warning — nothing ever runs against a
    /// half-typed path.
    private func applyProjectRoot(_ raw: String) {
        let root = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidProjectRoot(root) else {
            reportInvalidProjectRoot(root)
            return
        }
        clearError([.projectRoot])
        guard root != appliedProjectRoot else {
            return
        }
        let oldRoot = appliedProjectRoot
        appliedProjectRoot = root
        defaults.set(root, forKey: Self.projectRootKey)
        Log.app.info("Project root changed to \(root, privacy: .private)")
        for session in sessions {
            session.projectRootDidChange(from: oldRoot)
        }
        savePreferences()
    }

    private func validateProjectRoot() {
        if Self.isValidProjectRoot(appliedProjectRoot) {
            clearError([.projectRoot])
        } else {
            reportInvalidProjectRoot(appliedProjectRoot)
        }
    }

    private func reportInvalidProjectRoot(_ root: String) {
        report(.projectRoot, """
        Project root \(root.isEmpty ? "(empty)" : "'\(root)'") does not contain \(MonitorService.collectorScript). \
        Set "Project root" under Advanced to your checkout of this repository, or export HPC_PROJECT_ROOT before launching.
        """)
    }

    nonisolated static func isValidProjectRoot(_ root: String) -> Bool {
        !root.isEmpty && FileManager.default.fileExists(atPath: "\(root)/\(MonitorService.collectorScript)")
    }

    /// `ProjectRootLocator`'s rule (environment, the bundle's HPCProjectRoot
    /// Info.plist key, working directory, the checkout this bundle lives in),
    /// then the root the user last set by hand — which therefore survives a
    /// relaunch exactly when auto-detection fails, the case the "set Project
    /// root" message is about.
    private static func defaultProjectRoot(defaults: UserDefaults) -> String {
        defaultProjectRoot(
            environment: ProcessInfo.processInfo.environment,
            infoPlistValue: Bundle.main.object(forInfoDictionaryKey: ProjectRootLocator.infoPlistKey),
            currentDirectory: FileManager.default.currentDirectoryPath,
            bundlePath: Bundle.main.bundleURL.path,
            savedRoot: defaults.string(forKey: projectRootKey)
        )
    }

    /// The same with every input given (tests). Falls back to the working
    /// directory, whose error message then tells the user what to set.
    nonisolated static func defaultProjectRoot(
        environment: [String: String],
        infoPlistValue: Any?,
        currentDirectory: String,
        bundlePath: String,
        savedRoot: String?
    ) -> String {
        if let root = ProjectRootLocator.locate(
            environment: environment,
            infoPlistValue: infoPlistValue,
            currentDirectory: currentDirectory,
            bundlePath: bundlePath,
            isValid: isValidProjectRoot
        ) {
            return root
        }
        if let savedRoot, isValidProjectRoot(savedRoot) {
            return savedRoot
        }
        return currentDirectory
    }
}
