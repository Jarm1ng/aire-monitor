import AppKit
import HPCCore
import Foundation
import SwiftUI
import Testing
@testable import AIREMonitorApp

// The cluster dashboard's status strip (ShellStatusStrip.swift), the
// connect hero's steps (ContentView.swift), the Files footer's legibility,
// the plain vs forced sign-in entry points and the reconnect / route /
// disconnect confirmations (ClusterViews.swift), and the window size
// constants the layout tests share with ContentView. Pure wording tests build `ClusterStatusInput`
// directly; the AppModel tests use preview sessions or `ModelHarness`
// fakes and never reach a helper process.

// MARK: - Status strip

private func failure(
    _ kind: RefreshFailure.Kind,
    message: String = "Calder did not answer",
    detail: String = "ssh: connect to host calder port 22: Operation timed out",
    count: Int = 1
) -> RefreshFailure {
    RefreshFailure(kind: kind, message: message, detail: detail, consecutiveCount: count, date: Date(timeIntervalSince1970: 1_791_892_185))
}

private func input(
    phase: ClusterPresentation.Phase = .live,
    primaryAction: ClusterPresentation.Action? = nil,
    isPaused: Bool = false,
    errorMessage: String? = nil,
    failure: RefreshFailure? = nil,
    schedulerIssue: String? = nil,
    warnings: [String] = []
) -> ClusterStatusInput {
    ClusterStatusInput(
        displayName: "Calder",
        phase: phase,
        presentationDetail: "Background refreshes are paused; the last snapshot stays on screen.",
        primaryAction: primaryAction,
        isPaused: isPaused,
        hasSnapshot: true,
        statusMessage: "Cached snapshot offline • retrying every 40s",
        errorMessage: errorMessage,
        failure: failure,
        schedulerIssue: schedulerIssue,
        warnings: warnings,
        refreshIntervalText: "10s"
    )
}

@Suite("Cluster status strip")
struct ClusterStatusContentTests {
    @Test("The first automatic failure shows at once, not only after the backoff grows")
    func firstFailureShows() throws {
        let content = try #require(ClusterStatusContent.make(input(failure: failure(.transport))))
        #expect(content.text == "Calder did not answer")
        #expect(content.tone == .warning)
        #expect(content.systemImage == "wifi.exclamationmark")
        #expect(content.hint?.contains("Retrying every 10s") == true)
        #expect(content.hint?.contains("in a row") == false)
        #expect(content.actions == [.pause])
        let details = try #require(content.details)
        #expect(details.contains("First failure"))
        #expect(details.contains("Operation timed out"))
    }

    @Test("A setup problem says signing in will not help, in red, with the count in Details")
    func configuration() throws {
        let content = try #require(ClusterStatusContent.make(input(failure: failure(
            .configuration,
            message: "Collector script missing at ~/hpc/scripts/hpc_snapshot.py",
            detail: "python3: can't open file",
            count: 3
        ))))
        #expect(content.tone == .critical)
        #expect(content.systemImage == "wrench.and.screwdriver.fill")
        #expect(content.text == "Collector script missing at ~/hpc/scripts/hpc_snapshot.py")
        #expect(content.hint?.hasPrefix("Failed 3 times in a row.") == true)
        #expect(content.hint?.contains("Signing in again will not help") == true)
        #expect(content.details?.contains("3 failures in a row") == true)
        #expect(content.details?.contains("python3: can't open file") == true)
        #expect(!content.actions.contains(.connect))
    }

    @Test("A setup problem on a cluster that is not connected never says signing in 'again'")
    func configurationNotConnected() throws {
        let setup = failure(.configuration, message: "Collector script missing at ~/hpc/scripts/hpc_snapshot.py")
        let notConnected = try #require(ClusterStatusContent.make(input(phase: .notConnected, primaryAction: .connect, failure: setup)))
        #expect(notConnected.hint?.hasSuffix("Signing in will not fix it.") == true)
        #expect(notConnected.hint?.contains("again") == false)
        #expect(!notConnected.actions.contains(.connect))

        // Cached data from an earlier session: there was a sign-in to repeat.
        let stale = try #require(ClusterStatusContent.make(input(phase: .stale, primaryAction: .connect, failure: setup)))
        #expect(stale.hint?.hasSuffix("Signing in again will not help.") == true)
    }

    @Test("Slurm trouble stays calm: the session is live, signing in would not help")
    func clusterSide() throws {
        let content = try #require(ClusterStatusContent.make(input(failure: failure(
            .clusterSide,
            message: "Slurm error on Calder: Section 'jobs' failed with exit 1",
            detail: "squeue: error: Socket timed out"
        ))))
        #expect(content.tone == .warning)
        #expect(content.systemImage == "server.rack")
        #expect(content.hint?.contains("still live") == true)
        #expect(content.actions == [.pause])
    }

    @Test("A lost connection on cached data offers Connect, then Pause")
    func transportStale() throws {
        let content = try #require(ClusterStatusContent.make(input(
            phase: .stale,
            primaryAction: .connect,
            failure: failure(.transport, count: 4)
        )))
        #expect(content.actions == [.connect, .pause])
        #expect(content.hint?.contains("No connection to Calder. Sign in again to refresh.") == true)
        #expect(content.hint?.contains("The last snapshot stays on screen.") == true)
    }

    @Test("Paused: Resume first, the failure that led there kept as a hint")
    func pausedKeepsReason() throws {
        let content = try #require(ClusterStatusContent.make(input(
            phase: .paused,
            primaryAction: .resume,
            isPaused: true,
            failure: failure(.transport, count: 6)
        )))
        #expect(content.actions == [.resume])
        #expect(content.tone == .unavailable)
        #expect(content.hint == "Before the pause: Calder did not answer")
        #expect(content.details?.contains("6 failures in a row") == true)
    }

    @Test("A manual refresh that failed is shown once, with the failure's wording")
    func manualRefreshDeduplicated() throws {
        let raw = "ssh: connect to host calder port 22: Operation timed out"
        let content = try #require(ClusterStatusContent.make(input(
            errorMessage: raw,
            failure: failure(.transport, detail: raw)
        )))
        #expect(content.text == "Calder did not answer")
        #expect(content.tone == .critical)
        #expect(content.details?.components(separatedBy: "Operation timed out").count == 2)
    }

    @Test("A different error (a failed sign-in) keeps its own line over an older failure")
    func unrelatedErrorWins() throws {
        let content = try #require(ClusterStatusContent.make(input(
            phase: .stale,
            primaryAction: .connect,
            errorMessage: "Calder rejected the password.\nTry again.",
            failure: failure(.transport)
        )))
        #expect(content.text == "Calder rejected the password.")
        #expect(content.tone == .critical)
        #expect(content.details == "Calder rejected the password.\nTry again.")
        #expect(content.actions == [.connect, .pause])
    }

    @Test("A sign-in in progress wins: progress and Cancel, nothing else")
    func signingInWins() throws {
        let content = try #require(ClusterStatusContent.make(input(phase: .signingIn, failure: failure(.transport))))
        #expect(content.showsProgress)
        #expect(content.actions == [.cancelSignIn])
    }

    @Test("Cancel sign-in says what else it stops: never 'nothing else is affected' for the running sign-in")
    func cancelSignInHelp() throws {
        let running = try #require(ClusterStatusContent.make(input(phase: .signingIn)))
        let runningHelp = try #require(running.cancelSignInHelp)
        #expect(runningHelp.contains("clusters queued by the same Connect or Reconnect are skipped too"))
        #expect(!runningHelp.contains("nothing else"))
        // A cluster queued by a separate Connect is its own chain link and
        // still signs in (and pushes Duo) after this cancel; only the
        // sidebar's Cancel sign-in stops every link.
        #expect(!runningHelp.contains("no further Duo push"))
        #expect(runningHelp.contains("the sidebar's Cancel sign-in stops every queued sign-in"))

        let queued = try #require(ClusterStatusContent.make(input(phase: .queued)))
        #expect(queued.actions == [.cancelSignIn])
        #expect(queued.cancelSignInHelp == "Take Calder out of the sign-in queue; the other sign-ins go ahead")
    }

    @Test("Nothing to say: no strip")
    func quiet() {
        #expect(ClusterStatusContent.make(input()) == nil)
        #expect(ClusterStatusContent.make(input(phase: .off(hasCache: true), failure: failure(.configuration))) == nil)
    }

    @Test("Without a failure record, a scheduler issue and collector warnings still show")
    func fallbacks() {
        let issue = ClusterStatusContent.make(input(schedulerIssue: "Slurm error on Calder: Section 'nodes' failed", warnings: ["w1"]))
        #expect(issue?.systemImage == "server.rack")
        #expect(issue?.details == "w1")
        let warnings = ClusterStatusContent.make(input(warnings: ["a", "b"]))
        #expect(warnings?.text == "2 collector warnings; the rest of the Calder snapshot is fine")
    }

    @Test("Same-report detection does not swallow unrelated errors")
    func describes() {
        let record = failure(.transport, message: "Calder did not answer", detail: "ssh: timeout")
        #expect(record.describes("Calder did not answer"))
        #expect(record.describes("ssh: timeout"))
        #expect(record.describes("Refresh failed\n\nssh: timeout"))
        #expect(!record.describes("Could not cancel Calder job 42 — permission denied"))
    }
}

// MARK: - Connect hero steps

@MainActor
@Suite("Connect hero steps")
struct ConnectHeroStepsTests {
    @Test("The usual steps lead to a sign-in, and the cadence line is honest about storage")
    func usualSteps() {
        for kind in [nil, RefreshFailure.Kind.transport, .clusterSide] {
            let guide = ConnectHeroSteps.make(clusterName: "Calder", route: .directVPN, failureKind: kind)
            #expect(guide.steps.map(\.title) == ["Enter your university password", "Approve the Duo push", "Watch the live dashboard"])
            #expect(guide.connectIsPrimary)
            #expect(guide.steps[1].detail == "One approval on your phone keeps the Calder session alive.")
        }
        let cadence = ConnectHeroSteps.make(clusterName: "Calder", route: .directVPN, failureKind: nil).steps[2].detail
        // Storage is not collected every 10 s: most refreshes pass
        // --skip-storage (ClusterSession.wantsStorage).
        #expect(cadence == "Jobs, GPUs and nodes refresh every 10s; storage every 5 min, and on every refresh while the Storage tab is open.")
        #expect(!cadence.contains("nodes and storage refresh"))
        #expect(ConnectHeroSteps.refreshCadenceText.contains("every \(Int(HPCDefaults.refreshInterval))s"))
        #expect(ConnectHeroSteps.refreshCadenceText.contains("storage every \(Int(ClusterSession.storageRefreshInterval / 60)) min"))
    }

    @Test("The rash route names both approvals")
    func rashRoute() {
        let guide = ConnectHeroSteps.make(clusterName: "AIRE", route: .rashJump, failureKind: nil)
        #expect(guide.steps[1].detail == "One approval for rash (skipped if it is already open), then one for AIRE.")
    }

    @Test("A setup problem puts the fix first and demotes Connect: no sign-in fixes it, and one still costs a push")
    func setupProblem() {
        let guide = ConnectHeroSteps.make(clusterName: "Calder", route: .rashJump, failureKind: .configuration)
        #expect(guide.steps.first?.title == "Fix the setup on this Mac")
        #expect(guide.steps.first?.detail.contains("Project root") == true)
        #expect(!guide.connectIsPrimary)
        #expect(guide.steps.count == 3)
        #expect(guide.steps[1].detail.contains("rash"))
        #expect(guide.steps[1].detail.contains("still costs a push, and no snapshot loads"))
        // Nothing promises a dashboard that cannot load while the failure stands.
        #expect(guide.steps[2].detail == "It loads once the setup problem below is fixed.")
        #expect(!guide.steps.contains { $0.detail.contains("refresh every") })
        #expect(guide.connectHelp.contains("No snapshot loads until the setup problem below is fixed"))
    }
}

// MARK: - Files footer legibility

@MainActor
@Suite("Files footer legibility")
struct FilesFooterLegibilityTests {
    /// WCAG relative luminance of an sRGB colour.
    private func luminance(_ color: NSColor) -> Double {
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.redComponent) + 0.7152 * channel(color.greenComponent) + 0.0722 * channel(color.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    @Test("The capped-listing warning reads at 4.5:1 or better on the light window background")
    func cappedListingLegible() throws {
        // Sampled from the light Files render behind the footer.
        let background = NSColor(srgbRed: 246 / 255, green: 252 / 255, blue: 253 / 255, alpha: 1)
        let light = try #require(NSColor(FilesDashboard.itemsSummaryColor(truncated: true, in: .light)).usingColorSpace(.sRGB))
        #expect(contrast(light, background) >= 4.5)
        // Plain system orange, which the footer used before, measures about 2:1.
        let plain = try #require(NSColor(Color.orange).usingColorSpace(.sRGB))
        #expect(contrast(plain, background) < 3)
        // Dark mode keeps the bright tint; an uncapped listing is quiet
        // secondary text, in its legible light-mode shade.
        #expect(FilesDashboard.itemsSummaryColor(truncated: true, in: .dark) == Color.orange)
        #expect(FilesDashboard.itemsSummaryColor(truncated: false, in: .dark) == Color.secondary)
        #expect(FilesDashboard.itemsSummaryColor(truncated: false, in: .light) == Color.secondary.legibleText(in: .light))
        #expect(FilesDashboard.itemsSummaryColor(truncated: false, in: .light) != Color.secondary)
    }
}

// MARK: - Confirmation wording

private func sessionWork(
    _ id: ClusterID,
    live: Bool = true,
    terminals: Int = 0,
    transfers: Int = 0
) -> SessionWork {
    SessionWork(
        clusterID: id,
        clusterName: id == .aire ? "AIRE" : "Calder",
        isLive: live,
        runningTerminals: terminals,
        activeTransfers: transfers
    )
}

@Suite("Session confirmation wording")
struct SessionConfirmationWordingTests {
    @Test("The terminal line never claims kinds of work it did not count")
    func terminalKindsAreExamples() {
        let two = SessionActionConfirmation(kind: .reconnect, work: [sessionWork(.aire, terminals: 2), sessionWork(.calder)], usesJumpHost: false)
        #expect(two.message.contains(
            "Open terminals there close: 2 running sessions (2 on AIRE), including whatever runs in them, "
                + "such as a shell, a job-log tail, unsaved edits or an srun allocation."
        ))
        #expect(!two.message.contains("including shells"))
        let one = SessionActionConfirmation(kind: .disconnect, work: [sessionWork(.calder, terminals: 1)], usesJumpHost: false)
        #expect(one.message.contains("1 running session, including whatever runs in it, such as"))
    }

    @Test("A reconnect says a missed push leaves the cluster signed out: the old session closes first")
    func reconnectFailureConsequence() {
        let single = SessionActionConfirmation(kind: .reconnect, work: [sessionWork(.calder)], usesJumpHost: false)
        #expect(single.message.hasPrefix(
            "Reconnecting replaces the Calder SSH session with a fresh sign-in: one Duo push. "
                + "The old session closes first: if the push is missed or declined, Calder stays signed out."
        ))
        let both = SessionActionConfirmation(kind: .reconnect, work: [sessionWork(.aire), sessionWork(.calder, live: false)], usesJumpHost: true)
        #expect(both.message.contains(
            "plus one for the rash jump host if its session has closed. "
                + "Each old session closes first: a cluster whose push is missed or declined stays signed out."
        ))
        // Nothing open to lose: no claim about an old session.
        let idle = SessionActionConfirmation(kind: .reconnect, work: [sessionWork(.calder, live: false)], usesJumpHost: false)
        #expect(!idle.message.contains("old session"))
        // Only a reconnect forces a teardown before signing in.
        let disconnect = SessionActionConfirmation(kind: .disconnect, work: [sessionWork(.calder, terminals: 1)], usesJumpHost: false)
        #expect(!disconnect.message.contains("old session"))
    }

    @Test("A disconnect that closes the rash jump master too says so, with both approvals to get back")
    func disconnectClosingJumpHost() {
        let closing = SessionActionConfirmation(
            kind: .disconnect,
            work: [sessionWork(.aire, transfers: 1)],
            usesJumpHost: true,
            closesJumpHost: true
        )
        #expect(closing.message.hasPrefix(
            "This ends the SSH session to AIRE and the rash jump host session, which no other cluster uses now. "
                + "Signing in again needs two Duo approvals: one for rash, then one for AIRE."
        ))
        // On rash but still shared with another cluster: rash stays open.
        let shared = SessionActionConfirmation(kind: .disconnect, work: [sessionWork(.aire, transfers: 1)], usesJumpHost: true)
        #expect(shared.message.hasPrefix("This ends the SSH session to AIRE. Signing in again needs a new Duo approval."))
        #expect(!shared.message.contains("rash"))
    }
}

// MARK: - Plain vs forced sign-in

@MainActor
@Suite("Plain sign-in and confirmed reconnect")
struct SignInEntryPointTests {
    private func model() -> AppModel {
        PreviewModels.fixtureModel { session, snapshot in
            session.installPreviewState(snapshot: snapshot, isLoggedIn: session.id == .aire)
        }
    }

    @Test("Reconnect… always asks, live or not, and starts nothing by itself")
    func reconnectAlwaysConfirms() throws {
        let model = model()
        let live = try #require(model.reconnectConfirmation([.aire]))
        #expect(live.kind == .reconnect)
        #expect(live.clusterIDs == [.aire])
        let notLive = try #require(model.reconnectConfirmation([.calder]))
        #expect(notLive.kind == .reconnect)
        #expect(model.sessions.allSatisfy { !$0.isLoginQueued && !$0.isLoggingIn })
    }

    @Test("Connect on a live cluster cannot replace it silently: it becomes a confirmed reconnect")
    func connectOnLiveConfirms() throws {
        let model = model()
        let confirmation = try #require(model.signInOrConfirm([.aire]))
        #expect(confirmation.kind == .reconnect)
        #expect(model.sessions.allSatisfy { !$0.isLoginQueued && !$0.isLoggingIn })
    }

    @Test("Connect on a cluster that is not live signs in plainly, with no dialog")
    func connectSignsInPlainly() {
        let model = model()
        // No username: the plain sign-in stops at its first check, which
        // proves the path taken without starting any helper.
        model.username = ""
        #expect(model.signInOrConfirm([.calder]) == nil)
        #expect(model.errorMessage == "Username is required.")
        #expect(model.sessions.allSatisfy { !$0.isLoginQueued && !$0.isLoggingIn })
    }

    @Test("Switched-off clusters are never targets")
    func disabledIgnored() throws {
        let model = model()
        let calder = try #require(model.session(for: .calder))
        calder.isEnabled = false
        #expect(model.reconnectConfirmation([.calder]) == nil)
        #expect(model.signInOrConfirm([.calder]) == nil)
        #expect(model.errorMessage == nil)
    }
}

// MARK: - Route change and disconnect

/// The route picker and Disconnect through fakes: no helper process, no
/// SSH (`ModelHarness` gives every session a `FakeBackend`).
@MainActor
@Suite("Route change and disconnect confirmations")
struct RouteChangeConfirmationTests {
    private func otherRoute(than route: ConnectionRoute) -> ConnectionRoute {
        route == .directVPN ? .rashJump : .directVPN
    }

    @Test("With live sessions the route switch asks first and closes nothing until confirmed")
    func liveSessionsConfirm() async throws {
        let harness = try ModelHarness()
        harness.model.start()
        try await waitUntil("both live") { harness.model.sessions.allSatisfy { $0.isLoggedIn && !$0.refreshInFlight } }
        let original = harness.model.connectionRoute
        let target = otherRoute(than: original)

        let confirmation = try #require(harness.model.changeRouteOrConfirm(to: target))
        #expect(confirmation.kind == .changeRoute(target))
        #expect(confirmation.clusterIDs == [.aire, .calder])
        #expect(confirmation.work.allSatisfy { $0.isLive && !$0.hasRunningWork })
        await settle()
        #expect(harness.model.connectionRoute == original)
        #expect(harness.backend(.aire).stopMasterCalls.isEmpty && harness.backend(.calder).stopMasterCalls.isEmpty)

        harness.model.perform(confirmation)
        #expect(harness.model.connectionRoute == target)
        try await waitUntil("previous masters closed") {
            harness.backend(.aire).stopMasterCalls.count == 1 && harness.backend(.calder).stopMasterCalls.count == 1
        }
        harness.model.prepareForTermination()
    }

    @Test("With nothing live, running or transferring the route switches at once")
    func nothingToLoseSwitches() throws {
        let harness = try ModelHarness()
        let target = otherRoute(than: harness.model.connectionRoute)
        #expect(harness.model.changeRouteOrConfirm(to: target) == nil)
        #expect(harness.model.connectionRoute == target)
        // Picking the current route is no change at all.
        #expect(harness.model.changeRouteOrConfirm(to: target) == nil)
    }

    @Test("A switched-off cluster keeps its master on a route change, so it is not named")
    func disabledNotNamed() async throws {
        let harness = try ModelHarness()
        harness.model.start()
        try await waitUntil("both live") { harness.model.sessions.allSatisfy { $0.isLoggedIn && !$0.refreshInFlight } }
        harness.session(.calder).isEnabled = false
        let confirmation = try #require(harness.model.changeRouteOrConfirm(to: otherRoute(than: harness.model.connectionRoute)))
        #expect(confirmation.clusterIDs == [.aire])
        harness.model.prepareForTermination()
    }

    @Test("The disconnect dialog closes the rash jump master exactly when disconnect() would")
    func disconnectJumpHostFollowsModel() async throws {
        var preferences = AppPreferences()
        preferences.route = .rashJump
        let harness = try ModelHarness(preferences: preferences)
        harness.model.start()
        try await waitUntil("both live") { harness.model.sessions.allSatisfy { $0.isLoggedIn && !$0.refreshInFlight } }

        let shared = try #require(harness.model.disconnectConfirmation(.aire))
        #expect(shared.kind == .disconnect)
        #expect(shared.usesJumpHost)
        #expect(!shared.closesJumpHost, "Calder still rides the jump master")

        harness.model.disconnect(.calder)
        try await waitUntil("Calder stopped") { harness.backend(.calder).stopMasterCalls.count == 1 && !harness.session(.calder).isLoggedIn }
        let last = try #require(harness.model.disconnectConfirmation(.aire))
        #expect(last.closesJumpHost)
        #expect(last.message.contains("two Duo approvals"))
        harness.model.prepareForTermination()
    }

    @Test("On the direct route a disconnect never mentions the jump host")
    func disconnectDirectRoute() async throws {
        var preferences = AppPreferences()
        preferences.route = .directVPN
        let harness = try ModelHarness(preferences: preferences)
        harness.model.start()
        try await waitUntil("both live") { harness.model.sessions.allSatisfy { $0.isLoggedIn && !$0.refreshInFlight } }
        let confirmation = try #require(harness.model.disconnectConfirmation(.calder))
        #expect(!confirmation.usesJumpHost && !confirmation.closesJumpHost)
        #expect(!confirmation.message.contains("rash"))
        harness.model.prepareForTermination()
    }

    @Test("Disconnect with no terminal or transfer runs at once; the session's work is read from the model")
    func disconnectWithoutWork() async throws {
        let harness = try ModelHarness()
        harness.model.start()
        try await waitUntil("both live") { harness.model.sessions.allSatisfy { $0.isLoggedIn && !$0.refreshInFlight } }
        let work = try #require(harness.model.sessionWork(on: [.aire]).first)
        #expect(work == SessionWork(clusterID: .aire, clusterName: "AIRE", isLive: true, runningTerminals: 0, activeTransfers: 0))

        #expect(harness.model.disconnectOrConfirm(.aire) == nil)
        try await waitUntil("AIRE stopped") { harness.backend(.aire).stopMasterCalls.count == 1 }
        // A reconnect always asks, and its message now covers transfers too.
        let reconnect = try #require(harness.model.reconnectConfirmation([.calder]))
        #expect(reconnect.work.map(\.clusterID) == [.calder])
        harness.model.prepareForTermination()
    }
}

// MARK: - Window size

@Suite("Window size constants")
struct WindowSizeTests {
    @Test("The detail column minimum is the window minimum less the sidebar")
    @MainActor
    func detailSize() {
        #expect(ContentView.minimumWindowSize == CGSize(width: 1000, height: 680))
        #expect(ContentView.minimumDetailSize.width == ContentView.minimumWindowSize.width - ContentView.sidebarMinimumWidth)
        #expect(MinimumWindowLayoutTests.detailWidth == ContentView.minimumDetailSize.width)
        #expect(MinimumWindowLayoutTests.detailHeight == ContentView.minimumWindowSize.height)
    }
}
