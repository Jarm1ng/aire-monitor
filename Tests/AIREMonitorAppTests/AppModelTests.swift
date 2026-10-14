import HPCCore
import Foundation
import Testing
@testable import AIREMonitorApp

/// The coordinator: the serialized login chain (stopping, cancelling),
/// saved-password handling, persisted preferences, the project root and
/// the notification permission — all through fakes.
@MainActor
final class ModelHarness {
    let root: TemporaryProjectRoot
    let suiteName = "hpc-monitor-tests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let credentials: FakeCredentialStore
    let poster = FakeNotificationPoster()
    let backends: [ClusterID: FakeBackend]
    let model: AppModel

    init(credentials: FakeCredentialStore = FakeCredentialStore(), preferences: AppPreferences? = nil) throws {
        root = try TemporaryProjectRoot()
        try root.write("# collector stub\n", to: MonitorService.collectorScript)
        defaults = UserDefaults(suiteName: suiteName)!
        self.credentials = credentials
        var backends: [ClusterID: FakeBackend] = [:]
        let sessions = [ClusterID.aire, .calder].map { id -> ClusterSession in
            let backend = FakeBackend(snapshot: makeSnapshot(cluster: id))
            backends[id] = backend
            return ClusterSession(
                profile: catalogProfile(id),
                isEnabled: true,
                hostname: nil,
                backend: backend,
                scheduler: ManualScheduler()
            )
        }
        self.backends = backends
        // As if each startup probe had already found no master: a session
        // that was never started presents as "checking", and Connect all
        // (rightly) leaves probing clusters alone. `start()` resets this.
        for session in sessions {
            session.installPreviewState(snapshot: nil, isLoggedIn: false)
        }
        var resolved = preferences ?? AppPreferences()
        if resolved.username.isEmpty {
            resolved.username = testUsername
        }
        model = AppModel(
            sessions: sessions,
            preferences: resolved,
            projectRoot: root.path,
            defaults: defaults,
            credentials: credentials,
            notificationService: JobNotificationService(poster: poster)
        )
    }

    func backend(_ id: ClusterID) -> FakeBackend {
        backends[id]!
    }

    func session(_ id: ClusterID) -> ClusterSession {
        model.session(for: id)!
    }

    func waitForLoginsToFinish() async throws {
        try await waitUntil("login chain finished") {
            !self.model.isAnyLoginActive && self.model.sessions.allSatisfy { !$0.refreshInFlight }
        }
        await settle()
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
        root.remove()
    }
}

@MainActor
@Suite("AppModel")
struct AppModelTests {
    private let sharedAccount = "\(AppModel.keychainAccountPrefix)\(testUsername)"

    @Test("Building the model has no side effects")
    func initIsInert() throws {
        let harness = try ModelHarness()
        #expect(harness.poster.requestCount == 0)
        #expect(harness.credentials.reads.isEmpty)
        #expect(harness.model.sessions.allSatisfy { !$0.hasStarted })
    }

    @Test("A rejected saved password stops the queue and is never sent again")
    func rejectedSavedPassword() async throws {
        let harness = try ModelHarness(credentials: FakeCredentialStore(items: ["leeds:\(testUsername)": "old-password"]))
        harness.backend(.aire).enqueueLogin(.failure(MonitorError.passwordRejected("Password was rejected by AIRE")))

        harness.model.connectAll()
        try await harness.waitForLoginsToFinish()

        #expect(harness.backend(.aire).loginCalls.map(\.password) == ["old-password"])
        #expect(harness.backend(.calder).loginCalls.isEmpty, "the queue stops on a rejected password")
        #expect(harness.session(.calder).statusMessage.hasPrefix("Skipped"))
        #expect(harness.model.savedPasswordRejected)
        #expect(harness.model.keychainWarning?.contains("rejected") == true)

        // The next Connect with an empty field asks for the new password
        // instead of resending the known-bad one.
        harness.model.connectAll()
        #expect(harness.model.errorMessage == "The saved password was rejected — type the new password.")
        #expect(harness.backend(.aire).loginCalls.count == 1)
        #expect(!harness.model.isAnyLoginActive)

        // A typed password that works replaces it and clears the flag.
        harness.model.password = "new-password"
        harness.model.connectAll()
        try await harness.waitForLoginsToFinish()
        try await waitUntil("password saved") { harness.credentials.storedItems[sharedAccount] == "new-password" }
        try await waitUntil("flag cleared") { !harness.model.savedPasswordRejected }
        #expect(harness.model.password.isEmpty)
    }

    @Test("A typed password that a reused sign-in never sent is not saved, and does not lift the rejected flag")
    func reusedSignInLeavesKeychainAlone() async throws {
        let harness = try ModelHarness(credentials: FakeCredentialStore(items: [sharedAccount: "good-password"]))
        // The saved password gets flagged (say the server refused it once).
        harness.backend(.aire).enqueueLogin(.failure(MonitorError.passwordRejected("Password was rejected by AIRE")))
        harness.model.connectAll()
        try await harness.waitForLoginsToFinish()
        #expect(harness.model.savedPasswordRejected)

        // A plain sign-in with a typo succeeds by reusing AIRE's open
        // session: the typed text never reached any server.
        harness.backend(.aire).enqueueReusedLogin()
        harness.model.password = "good-pasword"
        harness.model.signIn([.aire])
        try await harness.waitForLoginsToFinish()
        await settle()

        #expect(harness.backend(.aire).loginCalls.last?.password == "good-pasword")
        #expect(harness.credentials.storedItems[sharedAccount] == "good-password", "an unchecked password replaced the saved one")
        #expect(harness.model.savedPasswordRejected, "an unchecked password lifted the rejected flag")
        #expect(harness.model.password.isEmpty, "the sign-in itself worked, so the field is cleared")
    }

    @Test("A sign-in cancelled while its Keychain read waits never drops the sign-in queued after it", arguments: [false, true])
    func cancelledKeychainWaitLeavesNewerLinkAlone(denied: Bool) async throws {
        let credentials = FakeCredentialStore(items: [sharedAccount: "saved-password"])
        credentials.holdReads()
        let harness = try ModelHarness(credentials: credentials)

        // Empty field: the saved password, behind a prompt nobody answers yet.
        harness.model.connectAll()
        try await waitUntil("Keychain read waiting") { !credentials.reads.isEmpty }
        harness.model.cancelLogins()
        #expect(harness.model.sessions.allSatisfy { !$0.isLoginQueued })

        harness.model.password = "typed-password"
        harness.model.connectAll()
        #expect(harness.session(.aire).isLoginQueued && harness.session(.calder).isLoginQueued)

        // The stale prompt is answered at last, either way.
        credentials.releaseReads(answering: denied ? .accessDenied(-128) : nil)
        try await harness.waitForLoginsToFinish()

        #expect(harness.backend(.aire).loginCalls.map(\.password) == ["typed-password"])
        #expect(harness.backend(.calder).loginCalls.map(\.password) == ["typed-password"])
        #expect(harness.model.errorMessage == nil, "the cancelled link reported its Keychain answer over the newer sign-in")
        #expect(harness.session(.aire).isLoggedIn && harness.session(.calder).isLoggedIn)
    }

    @Test("Cancelling stops the running sign-in and everything queued behind it")
    func cancelLogins() async throws {
        let harness = try ModelHarness()
        harness.backend(.aire).holdLogins(true)
        harness.model.password = "secret"
        harness.model.connectAll()
        try await waitUntil("AIRE helper running") { harness.backend(.aire).loginCalls.count == 1 }
        #expect(harness.session(.calder).isLoginQueued)

        harness.model.cancelLogins()
        try await harness.waitForLoginsToFinish()

        #expect(harness.backend(.calder).loginCalls.isEmpty)
        // Cancelled, not failed: no error. (The quiet probe that follows may
        // find the previous master still alive and go live again.)
        #expect(harness.session(.aire).errorMessage == nil)
        #expect(harness.session(.calder).statusMessage == "Sign-in cancelled")

        // A new request afterwards works normally.
        harness.backend(.aire).holdLogins(false)
        harness.model.connect(.calder)
        try await harness.waitForLoginsToFinish()
        #expect(harness.session(.calder).isLoggedIn)
    }

    @Test("A sign-in that times out waiting for Duo does not push the next cluster")
    func timeoutStopsQueue() async throws {
        let harness = try ModelHarness()
        harness.backend(.aire).enqueueLogin(.failure(MonitorError.loginTimedOut("The AIRE login timed out.")))
        harness.model.password = "secret"
        harness.model.connectAll()
        try await harness.waitForLoginsToFinish()

        #expect(harness.backend(.calder).loginCalls.isEmpty)
        #expect(harness.session(.calder).statusMessage.contains("timed out"))
    }

    @Test("Keychain access denied is reported as such, not as a missing password")
    func keychainDenied() async throws {
        let harness = try ModelHarness(credentials: FakeCredentialStore(readFailure: .accessDenied(-128)))
        harness.model.connectAll()
        try await waitUntil("lookup finished") { !harness.model.isAnyLoginActive }
        #expect(harness.model.errorMessage?.contains("Keychain access was denied") == true)
        #expect(harness.backend(.aire).loginCalls.isEmpty)
        // One denied prompt answers for every item.
        #expect(harness.credentials.reads.count == 1)
    }

    @Test("Unticking Remember survives a relaunch and offers to forget the saved password")
    func rememberPasswordPersists() async throws {
        let harness = try ModelHarness(credentials: FakeCredentialStore(items: ["leeds:\(testUsername)": "pw"]))
        harness.model.refreshSavedPasswordStatus()
        try await waitUntil("saved password found") { harness.model.hasSavedPassword }

        harness.model.rememberPassword = false
        #expect(harness.model.offerToForgetSavedPassword)
        harness.model.savePreferences()

        let reloaded = PreferencesStore(projectRoot: harness.root.path).load()
        #expect(reloaded.rememberPassword == false)

        harness.model.forgetSavedPassword()
        #expect(!harness.model.offerToForgetSavedPassword)
        try await waitUntil("item removed") { harness.credentials.storedItems.isEmpty && !harness.model.hasSavedPassword }
    }

    @Test("Preferences written before Remember was persisted decode as remembering")
    func rememberDefaultsToTrue() throws {
        let preferences = try decode(AppPreferences.self, from: #"{"username": "abcd1234"}"#)
        #expect(preferences.rememberPassword)
    }

    @Test("A project root applies only once it is valid, and is remembered outside it")
    func projectRootValidation() async throws {
        let harness = try ModelHarness()
        harness.model.start()
        #expect(harness.model.errorMessage == nil)

        harness.model.commitProjectRoot("/definitely/not/a/checkout")
        #expect(harness.model.errorMessage?.contains("does not contain") == true)
        #expect(harness.model.appliedProjectRoot == harness.root.path, "nothing runs against an invalid root")
        #expect(harness.model.signInConfiguration.projectRoot == harness.root.path)

        let other = try TemporaryProjectRoot()
        defer { other.remove() }
        try other.write("# collector stub\n", to: MonitorService.collectorScript)
        harness.model.commitProjectRoot(other.path)
        #expect(harness.model.errorMessage == nil)
        #expect(harness.model.appliedProjectRoot == other.path)
        #expect(harness.defaults.string(forKey: "projectRoot") == other.path)
        #expect(other.exists(".runtime/preferences.json"))
        harness.model.prepareForTermination()
    }

    @Test("A failing permission request is shown, with a way to ask again")
    func notificationRequestFailure() async throws {
        let harness = try ModelHarness()
        harness.poster.requestError = NSError(
            domain: "UNErrorDomain",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Notifications are not allowed for this application"]
        )
        harness.model.start()
        try await waitUntil("request answered") { harness.poster.requestCount == 1 && harness.model.notificationPermissionAction != nil }
        #expect(harness.model.notificationAuthorizationSummary == "Request failed: Notifications are not allowed for this application")
        #expect(harness.model.notificationPermissionAction == .request)

        harness.poster.requestError = nil
        harness.model.performNotificationPermissionAction()
        try await waitUntil("granted") { harness.model.notificationAuthorizationSummary == "Allowed" }
        #expect(harness.model.notificationPermissionAction == nil)
        harness.model.prepareForTermination()
    }

    @Test("A Duo push that was not approved stops the queue but never flags the saved password")
    func duoNotApprovedStopsQueue() async throws {
        let harness = try ModelHarness(credentials: FakeCredentialStore(items: [sharedAccount: "good-password"]))
        harness.backend(.aire).enqueueLogin(.failure(MonitorError.duoNotApproved(
            MonitorService.explainSSHFailure("duo-denied", exitCode: 15, clusterName: "AIRE")
        )))

        harness.model.connectAll()
        try await harness.waitForLoginsToFinish()

        #expect(harness.backend(.aire).loginCalls.map(\.password) == ["good-password"])
        #expect(harness.backend(.calder).loginCalls.isEmpty, "the next push would go unanswered too")
        #expect(harness.session(.calder).statusMessage == "Skipped — Duo approval was not completed for AIRE")
        #expect(!harness.model.savedPasswordRejected, "the password was accepted")
        #expect(harness.model.keychainWarning == nil)

        // The saved password is still used on the next Connect.
        harness.model.connectAll()
        try await harness.waitForLoginsToFinish()
        #expect(harness.backend(.aire).loginCalls.map(\.password) == ["good-password", "good-password"])
    }

    @Test("Plain sign-ins reuse a healthy master; only Reconnect forces a replacement")
    func forceReplaceOnlyOnReconnect() async throws {
        let harness = try ModelHarness()
        for id in [ClusterID.aire, .calder] {
            harness.backend(id).setFallback(.failure(MonitorError.processFailed(
                "connection lost: SSH control master is not running (log in again from the app)"
            )))
        }
        harness.model.password = "secret"

        harness.model.connectAll()
        try await harness.waitForLoginsToFinish()
        harness.model.password = "secret"
        harness.model.connect(.aire)
        try await harness.waitForLoginsToFinish()
        harness.model.password = "secret"
        harness.model.signIn([.calder])
        try await harness.waitForLoginsToFinish()
        #expect(harness.backend(.aire).loginCalls.map(\.forceReplace) == [false, false])
        #expect(harness.backend(.calder).loginCalls.map(\.forceReplace) == [false, false])

        harness.model.password = "secret"
        harness.model.reconnect([.aire, .calder])
        try await harness.waitForLoginsToFinish()
        #expect(harness.backend(.aire).loginCalls.last?.forceReplace == true)
        #expect(harness.backend(.calder).loginCalls.last?.forceReplace == true)
    }

    @Test("Connect all never signs in a cluster whose startup probe is still running")
    func connectAllSkipsChecking() async throws {
        let harness = try ModelHarness()
        for id in [ClusterID.aire, .calder] {
            harness.backend(id).setFallback(.failure(MonitorError.processFailed(
                "connection lost: SSH control master is not running (log in again from the app)"
            )))
            harness.backend(id).holdCollections(true)
        }
        harness.model.start()
        #expect(harness.model.sessions.allSatisfy { $0.presentation.phase == .checking })
        #expect(harness.model.sessionsNeedingSignIn.isEmpty)
        harness.model.password = "secret"
        harness.model.connectAll()
        #expect(!harness.model.isAnyLoginActive)

        for id in [ClusterID.aire, .calder] {
            harness.backend(id).releaseCollections()
        }
        try await waitUntil("probes finished") {
            harness.model.sessions.allSatisfy { $0.hasCompletedFirstProbe && !$0.refreshInFlight }
        }
        #expect(harness.model.sessionsNeedingSignIn.map(\.id) == [.aire, .calder])
        #expect(harness.backend(.aire).loginCalls.isEmpty)
        harness.model.prepareForTermination()
    }

    @Test("Disconnecting the last cluster on the rash route offers the jump master for closing")
    func disconnectStopsJumpOnlyWhenUnused() async throws {
        var preferences = AppPreferences()
        preferences.route = .rashJump
        let harness = try ModelHarness(preferences: preferences)
        harness.model.start()
        try await waitUntil("both live") { harness.model.sessions.allSatisfy { $0.isLoggedIn && !$0.refreshInFlight } }

        harness.model.disconnect(.aire)
        try await waitUntil("AIRE stopped") { harness.backend(.aire).stopMasterCalls.count == 1 && !harness.session(.aire).isLoggedIn }
        #expect(harness.backend(.aire).stopJumpFlags == [false], "Calder still rides the jump master")

        harness.model.disconnect(.calder)
        try await waitUntil("Calder stopped") { harness.backend(.calder).stopMasterCalls.count == 1 }
        #expect(harness.backend(.calder).stopJumpFlags == [true])
        harness.model.prepareForTermination()
    }

    @Test("Refresh all never paints errors on clusters with no master")
    func refreshAllIsQuietWithoutMaster() async throws {
        let harness = try ModelHarness()
        for id in [ClusterID.aire, .calder] {
            harness.backend(id).setFallback(.failure(MonitorError.processFailed(
                "connection lost: SSH control master is not running (log in again from the app)"
            )))
        }
        harness.model.start()
        try await waitUntil("startup probes") { harness.model.sessions.allSatisfy { $0.hasCompletedFirstProbe && !$0.refreshInFlight } }

        harness.model.refreshAll()
        try await waitUntil("refreshes done") { harness.model.sessions.allSatisfy { !$0.refreshInFlight } }
        #expect(harness.model.sessions.allSatisfy { $0.errorMessage == nil })
        harness.model.prepareForTermination()
    }
}

@Suite("Desktop widget launcher")
struct DesktopWidgetLauncherTests {
    @Test("A failure shows the build log's last lines, else the launcher's output")
    func failureMessage() {
        let log = (1...8).map { "line \($0)" }.joined(separator: "\n") + "\nbuild_bundle.sh: error: swift build failed\n"
        let message = AppModel.widgetFailureMessage(status: 1, buildLog: log, launcherOutput: "ignored")
        #expect(message.hasPrefix("The desktop widget could not be built or launched (exit 1)."))
        #expect(message.contains("line 5\nline 6\nline 7\nline 8\nbuild_bundle.sh: error: swift build failed"))
        #expect(!message.contains("line 4"))
        #expect(message.hasSuffix("Full log: .runtime/swift-widget-build.log"))

        let early = AppModel.widgetFailureMessage(status: 2, buildLog: nil, launcherOutput: "bash: build_bundle.sh: No such file or directory\n")
        #expect(early.hasSuffix("bash: build_bundle.sh: No such file or directory"))
        #expect(!early.contains("Full log"))
    }
}

@Suite("Quit confirmation")
struct QuitConfirmationTests {
    @Test("Nothing running: quit without asking")
    func nothingRunning() {
        let work = QuitConfirmation.Work(terminals: [("AIRE", 0), ("Calder", 0)], transfers: [("AIRE", 0)], signingIn: false)
        #expect(QuitConfirmation.informativeText(for: work) == nil)
    }

    @Test("Terminals, transfers and a sign-in share one alert")
    func combined() throws {
        let work = QuitConfirmation.Work(
            terminals: [("AIRE", 2), ("Calder", 0)],
            transfers: [("AIRE", 0), ("Calder", 1)],
            signingIn: true
        )
        let text = try #require(QuitConfirmation.informativeText(for: work))
        #expect(text.contains("2 terminal sessions are still running (2 on AIRE)"))
        #expect(text.contains("A file transfer is not finished (1 on Calder). Quitting cancels it and removes the partial file."))
        #expect(text.hasSuffix("A sign-in in progress will be cancelled."))
    }

    @Test("Transfers alone still ask")
    func transfersAlone() throws {
        let work = QuitConfirmation.Work(terminals: [], transfers: [("AIRE", 2), ("Calder", 1)], signingIn: false)
        let text = try #require(QuitConfirmation.informativeText(for: work))
        #expect(text == "3 file transfers are not finished (2 on AIRE, 1 on Calder). Quitting cancels them and removes the partial files.")
    }
}
