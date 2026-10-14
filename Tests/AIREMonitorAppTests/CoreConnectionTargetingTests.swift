import HPCCore
import Foundation
import Testing
@testable import AIREMonitorApp

// Which clusters "Connect all" signs in to, and how each cluster's state is
// named. Connect must never re-authenticate a live cluster (a forced login
// replaces its ControlMaster and kills every terminal riding on it), and
// every surface reads one mapping from session flags to a phase.

/// How one preview cluster starts.
private enum Start {
    case disabled(cached: Bool)
    case notSignedIn(cached: Bool)
    case signingIn
    case live(snapshot: Bool)
}

@MainActor
private func makeModel(_ starts: [ClusterID: Start]) -> AppModel {
    let sessions = ClusterCatalog.all.map { profile -> ClusterSession in
        let start = starts[profile.id] ?? .notSignedIn(cached: false)
        let enabled: Bool
        if case .disabled = start {
            enabled = false
        } else {
            enabled = true
        }
        // Enabled state is set at construction: toggling it afterwards runs
        // the real suspend/resume path.
        return ClusterSession(profile: profile, isEnabled: enabled, hostname: nil)
    }
    let model = AppModel(
        previewSessions: sessions,
        projectRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent("hpc-targeting-\(UUID().uuidString)").path
    )
    for session in sessions {
        let fixture = CoreFixtures.snapshot(for: session.id)
        switch starts[session.id] ?? .notSignedIn(cached: false) {
        case .disabled(let cached):
            session.installPreviewState(snapshot: cached ? fixture : nil, isLoggedIn: false)
        case .notSignedIn(let cached):
            session.installPreviewState(snapshot: cached ? fixture : nil, isLoggedIn: false)
        case .signingIn:
            session.installPreviewState(
                snapshot: nil, isLoggedIn: false, isLoggingIn: true,
                loginProgress: "waiting for Duo approval on your phone (\(session.displayName))"
            )
        case .live(let hasSnapshot):
            session.installPreviewState(snapshot: hasSnapshot ? fixture : nil, isLoggedIn: true, statusMessage: "Last refresh 11:49:50")
        }
    }
    return model
}

@MainActor
@Suite("Core · sign-in targeting")
struct CoreSignInTargetingTests {
    @Test("Connect all skips live clusters")
    func skipsLive() {
        let model = makeModel([.aire: .live(snapshot: true), .calder: .notSignedIn(cached: true)])
        #expect(model.sessionsNeedingSignIn.map(\.id) == [.calder])
    }

    @Test("Connect all skips disabled clusters and sign-ins already running")
    func skipsDisabledAndBusy() {
        #expect(makeModel([.aire: .disabled(cached: true), .calder: .notSignedIn(cached: false)]).sessionsNeedingSignIn.map(\.id) == [.calder])
        #expect(makeModel([.aire: .signingIn, .calder: .notSignedIn(cached: false)]).sessionsNeedingSignIn.map(\.id) == [.calder])
        #expect(makeModel([.aire: .live(snapshot: true), .calder: .live(snapshot: false)]).sessionsNeedingSignIn.isEmpty)
    }

    @Test("Every enabled cluster that is not signed in is a target, in catalog order")
    func allTargets() {
        let model = makeModel([.aire: .notSignedIn(cached: true), .calder: .notSignedIn(cached: false)])
        #expect(model.sessionsNeedingSignIn.map(\.id) == [.aire, .calder])
        #expect(model.connectAllTitle == "Connect all")
    }

    @Test("A single enabled cluster is offered plain Connect")
    func singleCluster() {
        let model = makeModel([.aire: .notSignedIn(cached: false), .calder: .disabled(cached: false)])
        #expect(model.connectAllTitle == "Connect")
        #expect(model.enabledSessions.map(\.id) == [.aire])
    }
}

@MainActor
@Suite("Core · connection states")
struct CoreConnectionStateTests {
    @Test("Session flags map to one connection state")
    func states() throws {
        let model = makeModel([.aire: .live(snapshot: true), .calder: .signingIn])
        #expect(try #require(model.session(for: .aire)).connectionState == .live)
        #expect(try #require(model.session(for: .calder)).connectionState == .connecting)

        let offline = makeModel([.aire: .notSignedIn(cached: true), .calder: .disabled(cached: true)])
        #expect(try #require(offline.session(for: .aire)).connectionState == .cached)
        #expect(try #require(offline.session(for: .calder)).connectionState == .disabled)

        let fresh = makeModel([.aire: .notSignedIn(cached: false)])
        #expect(try #require(fresh.session(for: .aire)).connectionState == .notConnected)
    }

    @Test("Only queued and signing-in clusters are busy")
    func busy() {
        #expect(ClusterConnectionState.connecting.isBusy)
        #expect(ClusterConnectionState.queued.isBusy)
        for state in [ClusterConnectionState.disabled, .notConnected, .live, .paused, .cached] {
            #expect(!state.isBusy)
        }
    }

    @Test("Presentation: a disabled cluster offers Turn on and never refreshes")
    func disabledPresentation() throws {
        let model = makeModel([.calder: .disabled(cached: true)])
        let presentation = try #require(model.session(for: .calder)).presentation
        #expect(presentation.phase == .off(hasCache: true))
        #expect(presentation.primaryAction == .turnOn)
        #expect(!presentation.allowsRefresh)
    }

    @Test("Presentation: signing in shows progress without the cluster name repeated")
    func signingInPresentation() throws {
        let model = makeModel([.calder: .signingIn])
        let presentation = try #require(model.session(for: .calder)).presentation
        #expect(presentation.phase == .signingIn)
        #expect(presentation.primaryAction == nil)
        #expect(!presentation.allowsRefresh)
        #expect(presentation.showsProgress)
        #expect(presentation.detail == "Waiting for Duo approval on your phone")
    }

    @Test("Presentation: signed in without a snapshot is loading, not an empty live card")
    func loadingPresentation() throws {
        let model = makeModel([.aire: .live(snapshot: false), .calder: .live(snapshot: true)])
        let loading = try #require(model.session(for: .aire)).presentation
        #expect(loading.phase == .loadingFirstSnapshot)
        #expect(loading.showsProgress)
        #expect(loading.primaryAction == nil)

        let live = try #require(model.session(for: .calder)).presentation
        #expect(live.phase == .live)
        #expect(live.allowsRefresh)
        #expect(live.primaryAction == nil)
    }

    @Test("Presentation: a cluster that is not signed in offers Connect only once the startup probe is done")
    func notSignedInPresentation() throws {
        // Before the probe finishes a Connect would force a login that tears
        // down the master the probe is about to confirm, so the cluster reads
        // "Checking". After it, a cached snapshot is "stale" and no snapshot
        // is "not connected", both with Connect. Which branch a preview
        // session lands in depends on whether installPreviewState marks the
        // probe as done, so the expectation follows the session's flag.
        let model = makeModel([.aire: .notSignedIn(cached: true), .calder: .notSignedIn(cached: false)])
        for (id, cached) in [(ClusterID.aire, true), (.calder, false)] {
            let session = try #require(model.session(for: id))
            let presentation = session.presentation
            if session.hasCompletedFirstProbe {
                #expect(presentation.phase == (cached ? .stale : .notConnected))
                #expect(presentation.primaryAction == .connect)
                // Without a snapshot there is nothing to refresh into.
                if !cached {
                    #expect(!presentation.allowsRefresh)
                }
            } else {
                #expect(presentation.phase == .checking)
                #expect(presentation.primaryAction == nil)
                #expect(!presentation.allowsRefresh)
                #expect(presentation.showsProgress)
            }
        }
    }

    @Test("Login progress loses its trailing cluster name and gains a capital", arguments: [
        ("waiting for Duo approval on your phone (Calder)", "Waiting for Duo approval on your phone" as String?),
        ("  sending password  ", "Sending password"),
        ("Approve on your phone (AIRE)", "Approve on your phone (AIRE)"),
        ("", nil),
        ("   ", nil)
    ])
    func progressText(raw: String, expected: String?) {
        #expect(ClusterPresentation.normalizedProgress(raw, clusterName: "Calder") == expected)
    }
}
