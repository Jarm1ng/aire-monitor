import HPCCore
import AppKit
import Foundation
import Testing
@testable import AIREMonitorApp

/// The session state machine, driven through fakes: refresh outcomes,
/// backoff, the logout rules, supersession, pause, sign-in cancellation,
/// identity changes and the widget lease. No processes, timers or network.
@MainActor
@Suite("ClusterSession")
struct SessionTests {
    private let transportFailure = MonitorError.processFailed("Command failed with exit 255: snapshot collection")
    private let missingMaster = MonitorError.processFailed(
        "connection lost: SSH control master is not running (log in again from the app)"
    )

    @Test("A probe that finds a master goes live and writes cache, history and the widget lease")
    func probeGoesLive() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()

        #expect(harness.session.isLoggedIn)
        #expect(harness.session.activeConnection?.username == testUsername)
        #expect(harness.session.presentation.phase == .live)
        #expect(harness.session.history.count == 1)

        let lease = try #require(harness.appState())
        #expect(lease.enabled)
        #expect(lease.live)
        #expect(!lease.paused)
        #expect(lease.refreshInterval == HPCDefaults.refreshInterval)
        #expect(lease.isFresh(now: harness.clock.now))

        // The snapshot is compact (rewritten every refresh) and the history
        // is a one-line-per-point log.
        let snapshotJSON = try harness.root.contents(of: ".runtime/clusters/aire/latest_snapshot.json")
        #expect(!snapshotJSON.contains("\n  "))
        let historyLog = try harness.root.contents(of: ".runtime/clusters/aire/snapshot_history.jsonl")
        #expect(historyLog.split(separator: "\n").count == 1)
        #expect(!harness.root.exists(".runtime/clusters/aire/snapshot_history.json"))
    }

    @Test("Three transport failures sign out, with the backoff doubling on the way")
    func threeFailuresSignOut() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        harness.backend.setFallback(.failure(transportFailure))

        try await harness.tick()
        #expect(harness.session.isLoggedIn, "one failure is a blip")
        #expect(harness.session.currentRefreshInterval == 10)
        try await harness.tick()
        #expect(harness.session.isLoggedIn)
        #expect(harness.session.currentRefreshInterval == 20)
        #expect(harness.scheduler.interval == 20)
        try await harness.tick()
        #expect(!harness.session.isLoggedIn)
        #expect(harness.session.activeConnection == nil)
        #expect(harness.session.currentRefreshInterval == 40)
        #expect(harness.appState()?.live == false)
    }

    @Test("A missing master signs out at once, and Refresh then probes quietly")
    func missingMasterSignsOutAtOnce() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        harness.backend.setFallback(.failure(missingMaster))

        try await harness.tick()

        #expect(!harness.session.isLoggedIn)
        #expect(harness.session.lastFailureWasMissingMaster)
        #expect(harness.session.presentation.allowsRefresh == false)
        #expect(harness.session.presentation.primaryAction == .connect)

        // A Refresh click must not paint "control master is not running".
        let before = harness.backend.completedCollections
        harness.session.refresh()
        try await waitUntil("quiet probe") {
            harness.backend.completedCollections > before && !harness.session.refreshInFlight
        }
        #expect(harness.session.errorMessage == nil)
        #expect(!harness.session.isRefreshing)
    }

    @Test("Backoff doubles up to 60 s and resets after a success")
    func backoffValues() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        harness.backend.setFallback(.failure(missingMaster))
        var intervals: [TimeInterval] = []
        for _ in 0..<5 {
            try await harness.tick()
            intervals.append(harness.session.currentRefreshInterval)
        }
        #expect(intervals == [10, 20, 40, 60, 60])
        #expect(harness.scheduler.interval == 60)

        harness.backend.setFallback(.success(makeSnapshot(collectedAt: "2026-10-13T12:05:00Z")))
        try await harness.tick()
        #expect(harness.session.currentRefreshInterval == 10)
        #expect(harness.scheduler.interval == 10)
        #expect(harness.session.isLoggedIn)
    }

    @Test("Slurm errors over a healthy connection keep the session live and keep the previous data")
    func schedulerErrorsStayLive() async throws {
        let job = Job(jobId: "101", partition: "gpu", name: "train", state: "RUNNING")
        let harness = try SessionHarness(backend: FakeBackend(snapshot: makeSnapshot(jobs: [job])))
        try await harness.startAndSettle()

        harness.backend.setFallback(.success(makeSnapshot(
            collectedAt: "2026-10-13T12:01:00Z",
            jobs: [],
            errors: ["Section 'jobs' failed with exit 1"]
        )))
        for _ in 0..<4 {
            try await harness.tick()
        }

        #expect(harness.session.isLoggedIn, "the round trip proved the master is alive")
        #expect(harness.session.presentation.phase == .live)
        #expect(harness.session.presentation.primaryAction == nil, "no destructive Connect")
        #expect(harness.session.schedulerIssue?.contains("Slurm error on AIRE") == true)
        #expect(harness.session.snapshot?.jobs.map(\.jobId) == ["101"])
        #expect(harness.session.snapshot?.errors.isEmpty == true)
        #expect(harness.session.snapshot?.warnings.contains { $0.contains("previous job list") } == true)
        #expect(harness.session.currentRefreshInterval == 60, "Slurm trouble still backs off")

        harness.backend.setFallback(.success(makeSnapshot(collectedAt: "2026-10-13T12:09:00Z", jobs: [])))
        try await harness.tick()
        #expect(harness.session.schedulerIssue == nil)
        #expect(harness.session.snapshot?.jobs.isEmpty == true)
        #expect(harness.session.currentRefreshInterval == 10)
    }

    @Test("A session the server refuses (MaxSessions) is never signed out")
    func refusedSessionsNeverSignOut() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        harness.backend.setFallback(.success(makeSnapshot(
            collectedAt: "2026-10-13T12:01:00Z",
            errors: ["Command failed with exit 255: snapshot collection\nmux_client_request_session: session request failed: Session open refused by peer"],
            remoteHostname: ""
        )))
        for _ in 0..<4 {
            try await harness.tick()
        }
        #expect(harness.session.isLoggedIn)
        #expect(harness.session.statusMessage.contains("refused another SSH session"))
    }

    @Test("A refresh superseded by Pause is ignored; the post-mutation refresh request survives")
    func pauseSupersedesAndPendingSurvives() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        let shown = harness.session.snapshot

        harness.backend.holdCollections(true)
        harness.backend.enqueueCollect(.success(makeSnapshot(collectedAt: "2026-10-13T12:02:00Z")))
        let callsBefore = harness.backend.collectCalls.count
        harness.scheduler.fire()
        try await waitUntil("refresh in flight") { harness.backend.collectCalls.count == callsBefore + 1 }
        harness.session.refreshAfterMutation()
        harness.session.pauseMonitoring()
        #expect(!harness.scheduler.isScheduled)
        harness.backend.releaseCollections()
        try await waitUntil("collector returned") { harness.backend.completedCollections == callsBefore + 1 }
        await settle()

        #expect(harness.session.snapshot == shown, "a superseded result must not repaint")
        #expect(!harness.scheduler.isScheduled, "nor restart the timer while paused")
        #expect(harness.appState()?.paused == true)

        harness.session.resumeMonitoring()
        // Resume refreshes once, and its completion consumes the pending
        // post-mutation request with one more refresh.
        try await waitUntil("resume + follow-up refresh") {
            harness.backend.completedCollections == callsBefore + 3 && !harness.session.refreshInFlight
        }
        #expect(harness.scheduler.isScheduled)
        #expect(harness.appState()?.paused == false)
    }

    @Test("A manual refresh adopts a background refresh already in flight")
    func manualAdoptsInFlight() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        harness.backend.holdCollections(true)
        let before = harness.backend.collectCalls.count
        harness.scheduler.fire()
        try await waitUntil("in flight") { harness.backend.collectCalls.count == before + 1 }
        #expect(!harness.session.isRefreshing, "background refreshes are silent")

        harness.session.refresh()
        #expect(harness.session.isRefreshing)
        #expect(harness.backend.collectCalls.count == before + 1, "no second collector run")

        harness.backend.releaseCollections()
        try await waitUntil("done") { !harness.session.refreshInFlight }
        #expect(!harness.session.isRefreshing)
    }

    @Test("Cancelling a running sign-in stops it and reports it as cancelled, not failed")
    func cancelRunningLogin() async throws {
        let harness = try SessionHarness(backend: FakeBackend(failure: missingMaster))
        try await harness.startAndSettle()
        harness.backend.holdLogins(true)
        harness.session.markLoginQueued()
        let configuration = harness.host.signInConfiguration
        let login = Task { await harness.session.performLogin(password: "secret", configuration: configuration) }
        try await waitUntil("helper running") {
            harness.backend.loginCalls.count == 1 && harness.session.loginProgress != nil
        }
        #expect(harness.session.presentation.phase == .signingIn)
        #expect(harness.session.presentation.detail == "Waiting for Duo approval on your phone")

        // Hold the follow-up probe so the cancelled state can be inspected.
        harness.backend.holdCollections(true)
        harness.session.cancelLogin()
        let outcome = await login.value

        #expect(outcome == .cancelled)
        #expect(!harness.session.isLoggingIn)
        #expect(harness.session.errorMessage == nil)
        #expect(harness.session.statusMessage == "Sign-in cancelled")
        #expect(harness.scheduler.isScheduled, "monitoring resumes after a cancelled sign-in")
        harness.backend.releaseCollections()
        try await waitUntil("probe after cancel") { !harness.session.refreshInFlight }
    }

    @Test("Cancelling a queued sign-in drops it")
    func cancelQueuedLogin() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        harness.session.markLoginQueued()
        harness.session.cancelLogin()
        #expect(!harness.session.isLoginQueued)
        #expect(harness.session.statusMessage == "Sign-in cancelled")
        let outcome = await harness.session.performLogin(password: "x", configuration: harness.host.signInConfiguration)
        #expect(outcome == .skipped)
        #expect(harness.backend.loginCalls.isEmpty)
    }

    @Test("Typing in the sign-in form never re-targets the live session")
    func formEditsApplyAtNextSignIn() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        let liveSocket = try #require(harness.session.activeConnection?.controlPath)

        harness.host.signInConfiguration.username = "efgh5678"
        harness.session.hostname = "login2.aire.leeds.ac.uk"

        #expect(harness.session.settings.controlPath == liveSocket)
        #expect(harness.session.signInChangesPending)
        try await harness.tick()
        #expect(harness.backend.collectCalls.last?.controlPath == liveSocket)
        #expect(harness.session.isLoggedIn)
    }

    @Test("Signing in under a new identity closes the previous identity's master once the new sign-in worked")
    func identityChangeStopsOldMaster() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        let oldSocket = try #require(harness.session.activeConnection?.controlPath)

        harness.host.signInConfiguration.username = "efgh5678"
        harness.backend.holdLogins(true)
        harness.session.markLoginQueued()
        let configuration = harness.host.signInConfiguration
        let login = Task { await harness.session.performLogin(password: "secret", configuration: configuration) }
        try await waitUntil("helper running") { harness.backend.loginCalls.count == 1 }
        #expect(harness.backend.stopMasterCalls.isEmpty, "the old master stays up until the new sign-in has worked")
        harness.backend.releaseLogins()
        let outcome = await login.value

        #expect(outcome == .succeeded(passwordVerified: true))
        try await waitUntil("old master closed") { harness.backend.stopMasterCalls.count == 1 }
        #expect(harness.backend.stopMasterCalls.map(\.controlPath) == [oldSocket])
        #expect(harness.session.activeConnection?.username == "efgh5678")
        #expect(!harness.session.signInChangesPending)
        try await waitUntil("post-login refresh") { !harness.session.refreshInFlight }
    }

    @Test("A sign-in under a new identity that fails leaves the previous master running")
    func failedIdentityChangeKeepsOldMaster() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        let old = try #require(harness.session.activeConnection)

        harness.host.signInConfiguration.username = "efgh5678"
        harness.backend.enqueueLogin(.failure(MonitorError.loginTimedOut("The AIRE login timed out.")))
        harness.session.markLoginQueued()
        let outcome = await harness.session.performLogin(password: "secret", configuration: harness.host.signInConfiguration)
        await settle()

        #expect(outcome == .timedOut)
        #expect(harness.backend.stopMasterCalls.isEmpty, "the old session is not given up for a sign-in that did not work")
        #expect(!harness.session.isLoggedIn)

        // Probes now ask the identity the form describes, which has no
        // master yet; the old one is still remembered, and still running.
        harness.backend.setFallback(.failure(missingMaster))
        try await harness.tick()
        await settle()
        #expect(harness.backend.stopMasterCalls.isEmpty)

        // Disconnect signs out of what is actually running: the old master.
        await harness.session.disconnect()
        #expect(harness.backend.stopMasterCalls.map(\.controlPath) == [old.controlPath])
    }

    @Test("A master that turns up for the new identity after a failed sign-in retires the old identity's master")
    func adoptedNewIdentityRetiresOldMaster() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        let old = try #require(harness.session.activeConnection)
        harness.host.signInConfiguration.username = "efgh5678"
        harness.backend.enqueueLogin(.failure(MonitorError.passwordRejected("Password was rejected by AIRE")))
        harness.session.markLoginQueued()
        #expect(await harness.session.performLogin(password: "secret", configuration: harness.host.signInConfiguration) == .passwordRejected)

        // Signed in from a terminal, say: the probe finds the new identity's master.
        try await harness.tick()
        #expect(harness.session.isLoggedIn)
        #expect(harness.session.activeConnection?.username == "efgh5678")
        try await waitUntil("old master closed") { harness.backend.stopMasterCalls.count == 1 }
        #expect(harness.backend.stopMasterCalls.map(\.controlPath) == [old.controlPath])
    }

    @Test("A plain sign-in under a new identity keeps the old master while a terminal runs, and closes it once none does")
    func identityChangeKeepsMasterForRunningTerminals() async throws {
        _ = NSApplication.shared
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        let old = try #require(harness.session.activeConnection)
        let shell = try #require(harness.session.terminals.openShell(settings: old))
        #expect(shell.isRunning)

        harness.host.signInConfiguration.username = "efgh5678"
        harness.session.markLoginQueued()
        let outcome = await harness.session.performLogin(password: "secret", configuration: harness.host.signInConfiguration)
        try await waitUntil("post-login refresh") { !harness.session.refreshInFlight }
        await settle()

        #expect(outcome == .succeeded(passwordVerified: true))
        #expect(harness.session.activeConnection?.username == "efgh5678")
        #expect(harness.backend.stopMasterCalls.isEmpty, "a plain Connect never closes a master a running terminal may ride on")
        try await harness.tick()
        await settle()
        #expect(harness.backend.stopMasterCalls.isEmpty, "kept while the terminal runs")

        shell.processDidExit(rawWaitStatus: 0)
        #expect(!shell.isRunning)
        try await harness.tick()
        try await waitUntil("old master closed") { harness.backend.stopMasterCalls.count == 1 }
        #expect(harness.backend.stopMasterCalls.map(\.controlPath) == [old.controlPath])
    }

    @Test("Going live again on an identity kept for its terminals never closes the master the session is live on")
    func liveAgainOnKeptIdentityIsNeverRetired() async throws {
        _ = NSApplication.shared
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        let first = try #require(harness.session.activeConnection)
        let shell = try #require(harness.session.terminals.openShell(settings: first))

        // A plain sign-in as another identity while the terminal runs keeps
        // the first identity's master.
        harness.host.signInConfiguration.username = "efgh5678"
        harness.session.markLoginQueued()
        #expect(await harness.session.performLogin(password: "pw", configuration: harness.host.signInConfiguration) == .succeeded(passwordVerified: true))
        try await waitUntil("post-login refresh") { !harness.session.refreshInFlight }
        let second = try #require(harness.session.activeConnection)
        #expect(second.controlPath != first.controlPath)

        // The new identity's session fails; the form is set back, and the
        // first master (kept up by the terminal) answers the next probe.
        harness.backend.setFallback(.failure(missingMaster))
        try await harness.tick()
        #expect(!harness.session.isLoggedIn)
        harness.host.signInConfiguration.username = testUsername
        harness.backend.setFallback(.success(makeSnapshot(collectedAt: "2026-10-13T12:01:00Z")))
        try await harness.tick()
        #expect(harness.session.isLoggedIn)
        #expect(harness.session.activeConnection?.controlPath == first.controlPath)

        // Once the terminal ends, only the abandoned identity is retired.
        shell.processDidExit(rawWaitStatus: 0)
        try await harness.tick()
        try await waitUntil("abandoned master closed") { !harness.backend.stopMasterCalls.isEmpty }
        try await harness.tick()
        await settle()
        #expect(harness.backend.stopMasterCalls.map(\.controlPath) == [second.controlPath],
                "the master the session is live on was closed")
        #expect(harness.session.isLoggedIn)
    }

    @Test("A plain sign-in under a new identity keeps the old master while a transfer runs on it")
    func identityChangeKeepsMasterForRunningTransfers() async throws {
        let transfers = HeldTransfers()
        let harness = try SessionHarness(files: transfers.files)
        try await harness.startAndSettle()
        let old = try #require(harness.session.activeConnection)
        try await transfers.startDownload(settings: old)

        harness.host.signInConfiguration.username = "efgh5678"
        harness.session.markLoginQueued()
        #expect(await harness.session.performLogin(password: "pw", configuration: harness.host.signInConfiguration) == .succeeded(passwordVerified: true))
        try await waitUntil("post-login refresh") { !harness.session.refreshInFlight }
        await settle()
        #expect(harness.session.activeConnection?.username == "efgh5678")
        #expect(harness.backend.stopMasterCalls.isEmpty, "a plain Connect closed the master a running transfer rides on")
        try await harness.tick()
        await settle()
        #expect(harness.backend.stopMasterCalls.isEmpty, "kept while the transfer runs")

        try await transfers.release()
        try await harness.tick()
        try await waitUntil("old master closed") { harness.backend.stopMasterCalls.count == 1 }
        #expect(harness.backend.stopMasterCalls.map(\.controlPath) == [old.controlPath])
    }

    @Test("An old master kept for a terminal stays up while a transfer still runs after the terminal ends")
    func keptMasterOutlivesItsTerminalWhileATransferRuns() async throws {
        _ = NSApplication.shared
        let transfers = HeldTransfers()
        let harness = try SessionHarness(files: transfers.files)
        try await harness.startAndSettle()
        let old = try #require(harness.session.activeConnection)
        let shell = try #require(harness.session.terminals.openShell(settings: old))
        try await transfers.startDownload(settings: old)

        harness.host.signInConfiguration.username = "efgh5678"
        harness.session.markLoginQueued()
        #expect(await harness.session.performLogin(password: "pw", configuration: harness.host.signInConfiguration) == .succeeded(passwordVerified: true))
        try await waitUntil("post-login refresh") { !harness.session.refreshInFlight }

        shell.processDidExit(rawWaitStatus: 0)
        try await harness.tick()
        await settle()
        #expect(harness.backend.stopMasterCalls.isEmpty, "the old master was closed under a running transfer")

        try await transfers.release()
        try await harness.tick()
        try await waitUntil("old master closed") { harness.backend.stopMasterCalls.count == 1 }
        #expect(harness.backend.stopMasterCalls.map(\.controlPath) == [old.controlPath])
    }

    @Test("Changing only the login host keeps the job baseline: jobs that ended meanwhile are still announced")
    func hostChangeKeepsJobBaseline() async throws {
        let mine = [
            Job(jobId: "101", partition: "gpu", name: "train-a", state: "RUNNING"),
            Job(jobId: "102", partition: "gpu", name: "train-b", state: "RUNNING")
        ]
        let harness = try SessionHarness(backend: FakeBackend(snapshot: makeSnapshot(jobs: mine)))
        try await harness.startAndSettle()

        // Half an hour unwatched (a bad round-robin node, say), then a
        // sign-in to one specific login node; both jobs ended meanwhile.
        harness.clock.advance(30 * 60)
        harness.backend.setFallback(.success(makeSnapshot(collectedAt: "2026-10-13T12:30:00Z", jobs: [])))
        harness.session.hostname = "login2.aire.leeds.ac.uk"
        let before = harness.backend.completedCollections
        harness.session.markLoginQueued()
        #expect(await harness.session.performLogin(password: "pw", configuration: harness.host.signInConfiguration) == .succeeded(passwordVerified: true))
        try await waitUntil("post-login refresh") { harness.backend.completedCollections > before && !harness.session.refreshInFlight }
        #expect(harness.session.activeConnection?.hostname == "login2.aire.leeds.ac.uk")

        let changes = try #require(harness.host.notifier.jobChanges.last, "the endings were dropped by a host-only change")
        #expect(changes.ended.map(\.jobId) == ["101", "102"])
        guard case .summary = changes.delivery else {
            Issue.record("a half-hour gap is announced as one catch-up summary, got \(changes.delivery)")
            return
        }
    }

    @Test("Signing in as another account never announces the old account's jobs as ended")
    func identityChangeDoesNotEndOldJobs() async throws {
        let mine = [
            Job(jobId: "101", partition: "gpu", name: "train-a", state: "RUNNING"),
            Job(jobId: "102", partition: "gpu", name: "train-b", state: "RUNNING")
        ]
        let harness = try SessionHarness(backend: FakeBackend(snapshot: makeSnapshot(jobs: mine)))
        try await harness.startAndSettle()

        // Account B's listing has only B's job: 101 and 102 did not end,
        // they belong to someone else now.
        harness.clock.advance(30)
        let theirs = [Job(jobId: "201", partition: "gpu", name: "eval", state: "RUNNING")]
        harness.backend.setFallback(.success(makeSnapshot(collectedAt: "2026-10-13T12:00:30Z", jobs: theirs)))
        harness.host.signInConfiguration.username = "efgh5678"
        let before = harness.backend.completedCollections
        harness.session.markLoginQueued()
        #expect(await harness.session.performLogin(password: "pw", configuration: harness.host.signInConfiguration) == .succeeded(passwordVerified: true))
        try await waitUntil("post-login refresh") { harness.backend.completedCollections > before && !harness.session.refreshInFlight }

        #expect(harness.host.notifier.jobChanges.isEmpty, "the old account's jobs were announced as ended")
        harness.session.flushCacheWrites()
        let baseline = try #require(harness.cache.loadJobStateSnapshot())
        #expect(baseline.jobs.keys.sorted() == ["201"])
        #expect(baseline.identity == ClusterSession.jobIdentity(of: try #require(harness.session.activeConnection)))
        #expect(baseline.identity?.hasPrefix("efgh5678@") == true)

        // Under the new account, changes are announced as usual.
        harness.clock.advance(10)
        harness.backend.setFallback(.success(makeSnapshot(collectedAt: "2026-10-13T12:00:40Z", jobs: [])))
        try await harness.tick()
        let changes = try #require(harness.host.notifier.jobChanges.last)
        #expect(changes.ended.map(\.jobId) == ["201"])
    }

    @Test("A route change closes the old route's master and probes the new one")
    func routeChangeStopsOldMaster() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        let oldSocket = try #require(harness.session.activeConnection?.controlPath)

        harness.host.signInConfiguration.route = .rashJump
        harness.session.connectionSettingsDidChange()
        #expect(harness.session.presentation.phase == .checking)

        try await waitUntil("old master closed and new route probed") {
            harness.backend.stopMasterCalls.count == 1 && !harness.session.refreshInFlight
        }
        #expect(harness.backend.stopMasterCalls.first?.controlPath == oldSocket)
        #expect(harness.backend.collectCalls.last?.useJumpHost == true)
        #expect(harness.session.activeConnection?.useJumpHost == true)
    }

    @Test("Disconnect closes the master and leaves the last snapshot as cached data")
    func disconnect() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()

        await harness.session.disconnect()

        #expect(harness.backend.stopMasterCalls.count == 1)
        #expect(!harness.session.isLoggedIn)
        #expect(harness.session.snapshot != nil)
        #expect(harness.session.presentation.phase == .stale)
        #expect(harness.session.presentation.allowsRefresh == false)
        #expect(harness.session.presentation.primaryAction == .connect)
        #expect(harness.appState()?.live == false)
    }

    @Test("After Disconnect no timer probes the closed master, and a probe that finds none keeps the calm status")
    func disconnectStaysCalm() async throws {
        let harness = try SessionHarness(route: .rashJump)
        try await harness.startAndSettle()
        harness.backend.setStopMasterResult(.success(StopMasterReport(statusLines: [
            "stopped the AIRE session",
            "kept the shared jump-host session (rash.leeds.ac.uk): another connection still uses it"
        ])))
        await harness.session.disconnect(stopJumpIfUnused: true)
        let signedOut = harness.session.statusMessage
        #expect(signedOut == "Signed out — showing the last snapshot • rash.leeds.ac.uk stays signed in for another connection")
        #expect(!harness.scheduler.isScheduled, "the app knows the master is gone: nothing to poll every minute")

        harness.backend.setFallback(.failure(missingMaster))
        let collections = harness.backend.completedCollections
        harness.scheduler.fire()
        harness.session.refreshQuietly()
        await settle()
        #expect(harness.backend.completedCollections == collections, "neither a tick nor a glance at the menu probes a signed-out cluster")

        // Refresh still probes (a master may have been started from a
        // terminal); finding none is exactly what the status says.
        harness.session.refresh()
        try await waitUntil("probe") { harness.backend.completedCollections == collections + 1 && !harness.session.refreshInFlight }
        #expect(harness.session.statusMessage == signedOut)
        #expect(harness.session.lastRefreshFailure == nil)
        #expect(harness.session.errorMessage == nil)
        #expect(!harness.scheduler.isScheduled)
        #expect(harness.session.presentation.phase == .stale)

        // Pause and Resume probe once and come back to the same calm line.
        harness.session.pauseMonitoring()
        harness.session.resumeMonitoring()
        try await waitUntil("resume probe") { harness.backend.completedCollections == collections + 2 && !harness.session.refreshInFlight }
        #expect(harness.session.statusMessage == signedOut)
        #expect(harness.session.lastRefreshFailure == nil)
        #expect(!harness.scheduler.isScheduled)
    }

    @Test("A master started elsewhere after Disconnect is picked up by Refresh, and monitoring resumes")
    func masterAfterDisconnect() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        await harness.session.disconnect()
        #expect(!harness.scheduler.isScheduled)

        harness.backend.setFallback(.success(makeSnapshot(collectedAt: "2026-10-13T12:02:00Z")))
        harness.session.refresh()
        try await waitUntil("probe") { harness.session.isLoggedIn && !harness.session.refreshInFlight }
        #expect(harness.scheduler.isScheduled)
    }

    @Test("One cache write recovering keeps the warning while another still fails")
    func persistenceWarningPerKind() throws {
        let harness = try SessionHarness()
        let session = harness.session
        let full = "No space left on device"
        session.cacheWriteProblemChanged(.appState, full)
        session.cacheWriteProblemChanged(.history, full)
        session.cacheWriteProblemChanged(.snapshot, full)

        // The small app_state.json fits again; the others still fail.
        session.cacheWriteProblemChanged(.appState, nil)
        let stillFailing = try #require(harness.host.persistenceProblems.last ?? nil)
        #expect(stillFailing.contains("latest_snapshot.json and snapshot_history.jsonl"))
        #expect(!stillFailing.contains("app_state.json"))
        #expect(stillFailing.contains("the desktop widget and the cached snapshot are not updating"))
        #expect(stillFailing.contains("Trends history is not being saved"))

        session.cacheWriteProblemChanged(.snapshot, nil)
        #expect(harness.host.persistenceProblems.last == "Cannot write \(session.displayName)'s snapshot_history.jsonl (\(full)) — Trends history is not being saved. Check free disk space and the permissions of .runtime/clusters/aire.")

        session.cacheWriteProblemChanged(.history, nil)
        #expect(harness.host.persistenceProblems.last == .some(nil))
    }

    @Test("Switching monitoring off writes the lease and stops refreshing")
    func disableWritesLease() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        harness.session.isEnabled = false
        #expect(!harness.scheduler.isScheduled)
        let lease = try #require(harness.appState())
        #expect(!lease.enabled)
        #expect(!lease.live)
    }

    @Test("Termination removes the lease so the widget can take over at once")
    func terminationRemovesLease() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        #expect(harness.appState() != nil)
        harness.session.prepareForTermination()
        #expect(harness.cache.loadAppState() == nil)
    }

    @Test("Job events reach the notifier, and the baseline advances every refresh")
    func jobEventsReachNotifier() async throws {
        let pending = Job(jobId: "7", partition: "gpu", name: "train", state: "PENDING")
        let harness = try SessionHarness(backend: FakeBackend(snapshot: makeSnapshot(jobs: [pending])))
        try await harness.startAndSettle()
        harness.session.flushCacheWrites()
        #expect(harness.cache.loadJobStateSnapshot()?.jobs["7"]?.state == "PENDING")

        harness.clock.advance(10)
        let running = Job(jobId: "7", partition: "gpu", name: "train", state: "RUNNING")
        harness.backend.setFallback(.success(makeSnapshot(collectedAt: "2026-10-13T12:00:10Z", jobs: [running])))
        try await harness.tick()

        let changes = try #require(harness.host.notifier.jobChanges.last)
        #expect(changes.started.map(\.jobId) == ["7"])
        #expect(changes.delivery == .individual)
        harness.session.flushCacheWrites()
        #expect(harness.cache.loadJobStateSnapshot()?.jobs["7"]?.state == "RUNNING")
    }

    @Test("Cancel on an array's pending remainder never touches its running tasks")
    func arrayRemainderCancel() async throws {
        let remainder = Job(
            jobId: "8248307",
            name: "pack",
            state: "PENDING",
            arrayJobID: 8248307,
            arrayPendingTasks: "2-5",
            arrayThrottle: 4,
            pendingTaskCount: 4
        )
        let task = Job(jobId: "8248307_0", name: "pack", state: "RUNNING", arrayJobID: 8248307)
        #expect(ClusterSession.cancelCommand(for: remainder) == "scancel --state=PENDING '8248307'")
        #expect(ClusterSession.cancelCommand(for: task) == "scancel '8248307_0'")
        #expect(ClusterSession.cancelCommand(for: Job(jobId: "42")) == "scancel '42'")

        let harness = try SessionHarness()
        try await harness.startAndSettle()
        try await harness.session.cancelJob(remainder)
        #expect(harness.backend.remoteCommands == ["scancel --state=PENDING '8248307'"])
    }

    @Test("Preview state counts as settled, not checking")
    func previewStateIsSettled() {
        let session = ClusterSession(profile: catalogProfile(.calder), isEnabled: true, hostname: nil, scheduler: ManualScheduler())
        session.installPreviewState(snapshot: nil, isLoggedIn: false)
        #expect(session.presentation.phase == .notConnected)
    }
}

@Suite("Refresh classification")
struct RefreshClassificationTests {
    @Test("Errors with a remote answer are Slurm errors; without one, transport")
    func classification() {
        #expect(RefreshClassification.classify(makeSnapshot()) == .success)
        let slurm = makeSnapshot(errors: ["Section 'jobs' failed with exit 1", "Section 'nodes' missing from remote output"])
        #expect(RefreshClassification.classify(slurm) == .schedulerError(
            failedSections: ["jobs", "nodes"],
            message: "Section 'jobs' failed with exit 1\nSection 'nodes' missing from remote output"
        ))
        let transport = makeSnapshot(errors: ["Command failed with exit 255: snapshot collection"], remoteHostname: "")
        #expect(RefreshClassification.classify(transport) == .transport(message: "Command failed with exit 255: snapshot collection"))
    }

    @Test("An unusable jobs listing counts as a failed jobs section, so the previous queue is kept")
    func unusableJobsListing() {
        let error = "No usable jobs listing (squeue --json payload has no jobs array; no pipe-format listing arrived)"
        #expect(RefreshClassification.failedSections(in: [error]) == ["jobs"])
        let previous = makeSnapshot(jobs: [Job(jobId: "7", state: "RUNNING")])
        let incoming = makeSnapshot(collectedAt: "2026-10-13T12:00:10Z", errors: [error])
        guard case .schedulerError(let sections, _) = RefreshClassification.classify(incoming) else {
            Issue.record("expected a Slurm-side error")
            return
        }
        let merged = ClusterSession.merge(previous: previous, incoming: incoming, failedSections: sections)
        #expect(merged.jobs.map(\.jobId) == ["7"])
    }

    @Test("Merging keeps only what failed and came back empty")
    func merge() {
        let previousJob = Job(jobId: "1", state: "RUNNING")
        let freshNode = NodeSummary(node: "gpu01", state: "idle")
        let previous = ClusterSnapshot(
            collectedAt: "2026-10-13T12:00:00Z",
            jobs: [previousJob],
            nodes: [NodeSummary(node: "old01")],
            storage: [StorageSummary(label: "Home", usedPercent: 50)]
        )
        let incoming = ClusterSnapshot(
            collectedAt: "2026-10-13T12:01:00Z",
            remote: RemoteInfo(hostname: "login1"),
            jobs: [],
            nodes: [freshNode],
            storage: nil,
            errors: ["Section 'jobs' failed with exit 1"],
            warnings: ["Section 'storage' failed with exit 1"]
        )
        let merged = ClusterSession.merge(previous: previous, incoming: incoming, failedSections: ["jobs"])
        #expect(merged.jobs == [previousJob])
        #expect(merged.nodes == [freshNode])
        #expect(merged.storage?.first?.label == "Home")
        #expect(merged.collectedAt == "2026-10-13T12:01:00Z")
        #expect(merged.errors.isEmpty)
        #expect(merged.warnings.first == "Section 'jobs' failed with exit 1")
        #expect(merged.warnings.contains("Slurm jobs query failed — showing the previous job list"))
    }
}

@Suite("Session refusal wording")
struct SessionRefusalExplanationTests {
    @Test(
        "A refused mux session is a session budget problem, not a refused login",
        arguments: [
            "mux_client_request_session: session request failed: Session open refused by peer",
            "channel 3: open failed: administratively prohibited: open failed"
        ]
    )
    func refusalWording(raw: String) {
        let text = MonitorService.explainSSHFailure(raw, exitCode: 255, clusterName: "Calder")
        #expect(text.hasPrefix("Calder refused to open another session on the existing connection."))
        #expect(text.contains("terminals or file transfers"))
        #expect(!text.contains("closed the connection before authentication"))
        #expect(MonitorService.isSessionRefusal(raw))
    }

    @Test("Ordinary failures are not refusals")
    func notRefusals() {
        #expect(!MonitorService.isSessionRefusal("Connection closed by 10.0.0.1 port 22"))
        #expect(!MonitorService.isSessionRefusal("scp: /nope: No such file or directory"))
    }
}

@Suite("Widget lease")
struct ClusterAppStateTests {
    @Test("Fresh for max(90 s, 3 × the refresh interval)")
    func freshnessWindow() {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let lease = ClusterAppState(updatedAt: now, enabled: true, paused: false, live: true, refreshInterval: 10)
        #expect(lease.freshnessWindow == 90)
        #expect(lease.isFresh(now: now.addingTimeInterval(89)))
        #expect(!lease.isFresh(now: now.addingTimeInterval(91)))
        let backingOff = ClusterAppState(updatedAt: now, enabled: true, paused: false, live: true, refreshInterval: 60)
        #expect(backingOff.freshnessWindow == 180)
        #expect(backingOff.isFresh(now: now.addingTimeInterval(170)))
    }

    @Test("Uses the contract's JSON keys")
    func jsonKeys() throws {
        let lease = ClusterAppState(updatedAt: "2026-10-13T12:00:00Z", enabled: true, paused: true, live: false, refreshInterval: 20)
        let json = try #require(String(data: JSONEncoder().encode(lease), encoding: .utf8))
        for key in ["\"updatedAt\"", "\"enabled\"", "\"paused\"", "\"live\"", "\"refreshInterval\""] {
            #expect(json.contains(key))
        }
    }
}

private let missingMasterError = MonitorError.processFailed(
    "connection lost: SSH control master is not running (log in again from the app)"
)
private let transportError = MonitorError.processFailed("Command failed with exit 255: snapshot collection")

/// Signing in: Duo outcomes, reuse versus replace, and adopting a master the
/// app did not start.
@MainActor
@Suite("ClusterSession · sign-in")
struct SessionSignInTests {
    @Test("A Duo push that was not approved is its own outcome, not a failed password")
    func duoNotApproved() async throws {
        let harness = try SessionHarness(backend: FakeBackend(failure: missingMasterError))
        try await harness.startAndSettle()
        harness.backend.enqueueLogin(.failure(MonitorError.duoNotApproved(
            MonitorService.explainSSHFailure("duo-denied", exitCode: 15, clusterName: "AIRE")
        )))
        harness.session.markLoginQueued()
        let outcome = await harness.session.performLogin(password: "secret", configuration: harness.host.signInConfiguration)

        #expect(outcome == .duoNotApproved)
        #expect(harness.session.statusMessage == "Duo approval was not completed for AIRE")
        #expect(harness.session.errorMessage?.contains("Your password was accepted") == true)
        #expect(!harness.session.isLoggingIn)
    }

    @Test("A plain sign-in reuses a master; only a confirmed replace asks for a new one")
    func forceReplaceReachesTheHelpers() async throws {
        let harness = try SessionHarness(backend: FakeBackend(failure: missingMasterError))
        try await harness.startAndSettle()
        harness.session.markLoginQueued()
        _ = await harness.session.performLogin(password: "pw", configuration: harness.host.signInConfiguration)
        try await waitUntil("post-login refresh") { !harness.session.refreshInFlight }
        harness.session.markLoginQueued()
        _ = await harness.session.performLogin(password: "pw", configuration: harness.host.signInConfiguration, forceReplace: true)
        try await waitUntil("post-login refresh") { !harness.session.refreshInFlight }

        #expect(harness.backend.loginCalls.map(\.forceReplace) == [false, true])
    }

    @Test("A master that answers its socket but not a command is left running and points to Reconnect")
    func unresponsiveMasterIsLeftRunning() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        harness.backend.enqueueLogin(.failure(MonitorService.loginError(
            "The existing AIRE session answers on its control socket, but a check command through it did not come back within 15 s.",
            exitCode: MonitorService.existingSessionUnresponsiveExitCode,
            clusterName: "AIRE"
        )))
        harness.session.markLoginQueued()
        let outcome = await harness.session.performLogin(password: "pw", configuration: harness.host.signInConfiguration)

        #expect(outcome == .failed)
        #expect(harness.backend.loginCalls.map(\.forceReplace) == [false])
        #expect(harness.backend.stopMasterCalls.isEmpty)
        #expect(harness.session.statusMessage == "AIRE's existing session did not answer — Reconnect… replaces it")
        let message = try #require(harness.session.errorMessage)
        #expect(message.contains("Reconnect…"))
        #expect(message.contains("Nothing on it was closed and no password was sent"))
    }

    @Test("A sign-in that only reused open sessions says the password was not checked")
    func reusedSignInIsNotAVerifiedPassword() async throws {
        let harness = try SessionHarness(backend: FakeBackend(failure: missingMasterError))
        try await harness.startAndSettle()
        harness.backend.enqueueReusedLogin()
        harness.session.markLoginQueued()
        let outcome = await harness.session.performLogin(password: "maybe-a-typo", configuration: harness.host.signInConfiguration)
        try await waitUntil("post-login refresh") { !harness.session.refreshInFlight }

        #expect(outcome == .succeeded(passwordVerified: false))
    }

    @Test("A master found at startup is adopted once, quietly")
    func adoptsFoundMasterOnce() async throws {
        let harness = try SessionHarness()
        harness.backend.setAdoption(.unavailable("exit 2: something odd"))
        try await harness.startAndSettle()
        try await waitUntil("adoption ran") { harness.backend.adoptCalls.count == 1 }

        #expect(harness.backend.adoptCalls.first?.controlPath == harness.session.activeConnection?.controlPath)
        #expect(harness.session.errorMessage == nil, "adoption is housekeeping: logged, never shown")
        #expect(harness.session.isLoggedIn)
        #expect(harness.backend.loginCalls.isEmpty, "adoption never signs in, prompts or pushes Duo")
        try await harness.tick()
        try await harness.tick()
        await settle()
        #expect(harness.backend.adoptCalls.count == 1)
    }

    @Test("A master built by signing in is never adopted, even after a sign-out and recovery")
    func noAdoptionAfterSignIn() async throws {
        let harness = try SessionHarness(backend: FakeBackend(failure: missingMasterError))
        try await harness.startAndSettle()
        harness.backend.setFallback(.success(makeSnapshot()))
        harness.session.markLoginQueued()
        #expect(await harness.session.performLogin(password: "pw", configuration: harness.host.signInConfiguration) == .succeeded(passwordVerified: true))
        try await waitUntil("post-login refresh") { !harness.session.refreshInFlight && harness.session.isLoggedIn }

        harness.backend.setFallback(.failure(transportError))
        for _ in 0..<3 {
            try await harness.tick()
        }
        #expect(!harness.session.isLoggedIn)
        harness.backend.setFallback(.success(makeSnapshot(collectedAt: "2026-10-13T12:05:00Z")))
        try await harness.tick()
        #expect(harness.session.isLoggedIn)
        await settle()
        #expect(harness.backend.adoptCalls.isEmpty)
    }

    @Test("Disconnect reports a kept jump-host session calmly")
    func disconnectKeepsJumpCalmly() async throws {
        let harness = try SessionHarness(route: .rashJump)
        try await harness.startAndSettle()
        harness.backend.setStopMasterResult(.success(StopMasterReport(statusLines: [
            "stopped the AIRE session",
            "kept the shared jump-host session (rash.leeds.ac.uk): another connection still uses it"
        ])))

        await harness.session.disconnect(stopJumpIfUnused: true)

        #expect(harness.backend.stopJumpFlags == [true])
        #expect(harness.session.errorMessage == nil)
        #expect(harness.session.statusMessage == "Signed out — showing the last snapshot • rash.leeds.ac.uk stays signed in for another connection")
    }

    @Test("A Disconnect that cannot close the master says so")
    func disconnectFailureIsShown() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        harness.backend.setStopMasterResult(.failure(MonitorError.processFailed(
            "Could not close the AIRE SSH session (exit 1): A AIRE master process survived SIGKILL."
        )))

        await harness.session.disconnect()

        #expect(harness.session.statusMessage == "Could not sign out of AIRE")
        #expect(harness.session.errorMessage?.contains("exit 1") == true)
        #expect(!harness.session.isLoggedIn)
    }
}

/// `lastRefreshFailure`: set on every failed refresh, whoever started it.
@MainActor
@Suite("ClusterSession · refresh failures")
struct SessionRefreshFailureTests {
    @Test("Every failed refresh records why, with kind and count; success clears it")
    func transportFailuresRecorded() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        #expect(harness.session.lastRefreshFailure == nil)
        harness.backend.setFallback(.failure(transportError))

        try await harness.tick()
        let first = try #require(harness.session.lastRefreshFailure)
        #expect(first.kind == .transport)
        #expect(first.consecutiveCount == 1)
        #expect(first.message == "Command failed with exit 255: snapshot collection")
        #expect(first.detail == transportError.localizedDescription)
        #expect(first.date == harness.clock.now)
        #expect(harness.session.errorMessage == nil, "automatic failures stay out of the error box")

        // A manual refresh records it too, and also shows the error.
        let before = harness.backend.completedCollections
        harness.session.refresh()
        try await waitUntil("manual refresh") { harness.backend.completedCollections > before && !harness.session.refreshInFlight }
        #expect(harness.session.lastRefreshFailure?.consecutiveCount == 2)
        #expect(harness.session.errorMessage != nil)

        harness.backend.setFallback(.success(makeSnapshot(collectedAt: "2026-10-13T12:03:00Z")))
        try await harness.tick()
        #expect(harness.session.lastRefreshFailure == nil)
    }

    @Test("The startup probe's failure is recorded, without an error box")
    func probeFailureRecorded() async throws {
        let harness = try SessionHarness(backend: FakeBackend(failure: missingMasterError))
        try await harness.startAndSettle()
        let failure = try #require(harness.session.lastRefreshFailure)
        #expect(failure.kind == .transport)
        #expect(failure.message == "No AIRE SSH session — sign in to refresh")
        #expect(harness.session.errorMessage == nil)
    }

    @Test("A missing collector script is a configuration problem named in the status line")
    func missingCollectorIsConfiguration() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        let path = "\(harness.root.path)/\(MonitorService.collectorScript)"
        harness.backend.setFallback(.failure(MonitorError.missingFile(path)))
        for _ in 0..<3 {
            try await harness.tick()
        }

        let failure = try #require(harness.session.lastRefreshFailure)
        #expect(failure.kind == .configuration)
        #expect(failure.message == "Collector script missing at \(path)")
        #expect(failure.consecutiveCount == 3)
        #expect(harness.session.statusMessage == failure.message)
        #expect(harness.session.isLoggedIn, "a local setup problem says nothing about the master")
    }

    @Test("Slurm errors over a live session are cluster-side")
    func schedulerErrorsAreClusterSide() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        harness.backend.setFallback(.success(makeSnapshot(
            collectedAt: "2026-10-13T12:01:00Z",
            errors: ["Section 'jobs' failed with exit 1"]
        )))
        try await harness.tick()
        try await harness.tick()

        let failure = try #require(harness.session.lastRefreshFailure)
        #expect(failure.kind == .clusterSide)
        #expect(failure.message == "Slurm error on AIRE: Section 'jobs' failed with exit 1")
        #expect(failure.consecutiveCount == 2)
        #expect(harness.session.isLoggedIn)
    }

    @Test("Configuration errors are told apart from failed round trips")
    func configurationClassification() {
        #expect(RefreshFailure.isConfigurationError(MonitorError.missingFile("/x/scripts/hpc_snapshot.py")))
        #expect(RefreshFailure.isConfigurationError(CocoaError(.fileNoSuchFile)))
        #expect(!RefreshFailure.isConfigurationError(transportError))
        #expect(!RefreshFailure.isConfigurationError(MonitorError.invalidJSON("snapshot script produced no output")))
        #expect(RefreshFailure.configurationSummary(MonitorError.missingFile("/x/scripts/hpc_snapshot.py"))
            == "Collector script missing at /x/scripts/hpc_snapshot.py")
        #expect(RefreshFailure.firstLine(of: "\n  first line  \nsecond") == "first line")
        #expect(RefreshFailure.firstLine(of: String(repeating: "x", count: 300)).count == 160)
    }
}

/// app_state.json at start and quit (the widget honours paused/off at any
/// age, so those records must outlive the app; plain live ones must not).
@MainActor
@Suite("ClusterSession · widget lease lifecycle")
struct SessionLeaseLifecycleTests {
    @Test("Starting replaces a paused record a previous run left behind")
    func startReplacesStalePausedLease() async throws {
        let harness = try SessionHarness()
        try harness.cache.saveAppState(ClusterAppState(
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            enabled: true,
            paused: true,
            live: false,
            refreshInterval: 10
        ))
        harness.backend.holdCollections(true)
        harness.session.start()

        let lease = try #require(harness.appState())
        #expect(!lease.paused, "written at start, before the probe finishes")
        #expect(lease.isFresh(now: harness.clock.now))

        harness.backend.releaseCollections()
        try await waitUntil("probe") { harness.session.hasCompletedFirstProbe && !harness.session.refreshInFlight }
        #expect(harness.appState()?.live == true, "and again after the first probe")
    }

    @Test("Quitting keeps a paused cluster's record, so the widget keeps honouring the pause")
    func terminationKeepsPausedLease() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        harness.session.pauseMonitoring()
        harness.session.prepareForTermination()

        let lease = try #require(harness.cache.loadAppState())
        #expect(lease.paused)
        #expect(lease.enabled)
        #expect(!lease.live, "nothing feeds the cluster once the app is gone")
    }

    @Test("Quitting keeps a switched-off cluster's record")
    func terminationKeepsDisabledLease() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        harness.session.isEnabled = false
        harness.session.prepareForTermination()
        #expect(harness.cache.loadAppState()?.enabled == false)
    }
}

/// Storage is collected every few minutes, not every 10 s refresh.
@MainActor
@Suite("ClusterSession · storage cadence")
struct SessionStorageCadenceTests {
    private let home = StorageSummary(label: "Home", source: "nfs", usedPercent: 40)
    private let flash = StorageSummary(label: "Flash", source: "lustre", usedPercent: 10, optional: true)
    private let flashCut = StorageSummary(label: "Flash", source: "unavailable", unavailableReason: "not-collected", optional: true)

    @Test("Collected on the first refresh, skipped after, collected again once 5 minutes old")
    func cadence() async throws {
        let harness = try SessionHarness(backend: FakeBackend(snapshot: makeSnapshot(storage: [home])))
        try await harness.startAndSettle()
        #expect(harness.backend.skipStorageFlags == [false], "the first refresh after start collects storage")
        #expect(harness.session.storageCollectedAt == "2026-10-13T12:00:00Z")

        harness.backend.setFallback(.success(makeSnapshot(collectedAt: "2026-10-13T12:00:10Z", storage: nil)))
        harness.clock.advance(10)
        try await harness.tick()
        #expect(harness.backend.skipStorageFlags.last == true)
        #expect(harness.session.snapshot?.storage == [home], "a skipped section keeps the previous rows")
        #expect(harness.session.storageCollectedAt == "2026-10-13T12:00:00Z", "and their collection time")
        #expect(harness.session.history.last?.homeUsedPercent == 40, "history carries the figure forward: no gap, no drop to zero")

        harness.clock.advance(300)
        try await harness.tick()
        #expect(harness.backend.skipStorageFlags.last == false)
    }

    @Test("A manual Refresh, the open Storage tab and a sign-in always collect storage")
    func explicitTriggers() async throws {
        let harness = try SessionHarness(backend: FakeBackend(snapshot: makeSnapshot(storage: [home])))
        try await harness.startAndSettle()
        try await harness.tick()
        #expect(harness.backend.skipStorageFlags.last == true)

        var before = harness.backend.completedCollections
        harness.session.refresh()
        try await waitUntil("manual refresh") { harness.backend.completedCollections > before && !harness.session.refreshInFlight }
        #expect(harness.backend.skipStorageFlags.last == false)

        try await harness.tick()
        #expect(harness.backend.skipStorageFlags.last == true)
        harness.session.dashboard.selectedTab = .storage
        try await harness.tick()
        #expect(harness.backend.skipStorageFlags.last == false)
        harness.session.dashboard.selectedTab = .jobs

        before = harness.backend.completedCollections
        harness.session.markLoginQueued()
        #expect(await harness.session.performLogin(password: "pw", configuration: harness.host.signInConfiguration) == .succeeded(passwordVerified: true))
        try await waitUntil("post-login refresh") { harness.backend.completedCollections > before && !harness.session.refreshInFlight }
        #expect(harness.backend.skipStorageFlags.last == false)
    }

    @Test("Storage that does not come back is asked for again a minute later, not every refresh")
    func missIsThrottled() async throws {
        let harness = try SessionHarness(backend: FakeBackend(snapshot: makeSnapshot(storage: nil)))
        try await harness.startAndSettle()
        #expect(harness.backend.skipStorageFlags == [false])
        harness.clock.advance(10)
        try await harness.tick()
        #expect(harness.backend.skipStorageFlags.last == true)
        harness.clock.advance(60)
        try await harness.tick()
        #expect(harness.backend.skipStorageFlags.last == false)
    }

    @Test("An optional volume cut short shows only where it had real figures")
    func optionalCutRows() async throws {
        // AIRE-like: Flash never had figures, so its cut row stays hidden.
        #expect(ClusterSession.mergeStorage(previous: nil, incoming: [home, flashCut], labelsWithFigures: ["Home"]) == [home])
        // Calder-like: Flash had figures, so the cut row is shown.
        #expect(ClusterSession.mergeStorage(previous: nil, incoming: [home, flashCut], labelsWithFigures: ["Home", "Flash"]) == [home, flashCut])
        // nil keeps the previous rows; [] means collected, no volumes.
        #expect(ClusterSession.mergeStorage(previous: [home], incoming: nil, labelsWithFigures: []) == [home])
        #expect(ClusterSession.mergeStorage(previous: [home], incoming: [], labelsWithFigures: ["Home"]) == [])

        // Calder-like in a session: Flash had figures, so a refresh that cuts
        // it short keeps those figures (and a minute later asks again)
        // rather than wiping them; see SessionStorageCutTests.
        let harness = try SessionHarness(backend: FakeBackend(snapshot: makeSnapshot(storage: [home, flash])))
        try await harness.startAndSettle()
        harness.backend.setFallback(.success(makeSnapshot(collectedAt: "2026-10-13T12:01:00Z", storage: [home, flashCut])))
        harness.session.refresh()
        try await waitUntil("manual refresh") { harness.backend.completedCollections == 2 && !harness.session.refreshInFlight }
        #expect(harness.session.snapshot?.storage == [home, flash])
    }

    @Test("collector.json, which the widget replays, never carries --skip-storage")
    func widgetArgvCollectsStorage() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        try await harness.tick()
        #expect(harness.backend.skipStorageFlags.last == true)
        harness.session.flushCacheWrites()
        let json = try harness.root.contents(of: ".runtime/clusters/aire/collector.json")
        #expect(json.contains("--cluster-id"))
        #expect(!json.contains("--skip-storage"))
    }
}

/// A storage section cut short (the round trip's budget ran out inside it,
/// or a df/lfs stalled) is a miss, not a collection: good figures stay on
/// screen for a while and the section is asked for again a minute later.
@MainActor
@Suite("ClusterSession · storage cut short")
struct SessionStorageCutTests {
    private let home = StorageSummary(label: "Home", source: "nfs", usedPercent: 40)
    private let scratch = StorageSummary(label: "Scratch", source: "lustre", availableGB: 900, usedPercent: 55)
    private let scratchStalled = StorageSummary(label: "Scratch", source: "unavailable", unavailableReason: "no-figures")
    private let scratchNotReached = StorageSummary(label: "Scratch", source: "unavailable", unavailableReason: "not-collected")
    private let scratchMissing = StorageSummary(label: "Scratch", source: "unavailable", unavailableReason: "missing")

    @Test("A required volume cut mid-section keeps its figures and is asked for again a minute later")
    func cutRowIsRetried() async throws {
        let harness = try SessionHarness(backend: FakeBackend(snapshot: makeSnapshot(storage: [home, scratch])))
        try await harness.startAndSettle()
        #expect(harness.session.storageCollectedAt == "2026-10-13T12:00:00Z")

        harness.clock.advance(300)
        harness.backend.setFallback(.success(makeSnapshot(collectedAt: "2026-10-13T12:05:00Z", storage: [home, scratchStalled])))
        try await harness.tick()
        #expect(harness.backend.skipStorageFlags.last == false)
        #expect(harness.session.snapshot?.storage == [home, scratch], "one stalled df does not wipe good figures")
        #expect(harness.session.storageCollectedAt == "2026-10-13T12:00:00Z", "carried figures are not passed off as fresh")
        #expect(harness.session.history.last?.scratchUsedPercent == 55, "no gap in history")

        // Not every refresh: a stuck df is probably still stuck.
        harness.clock.advance(10)
        harness.backend.setFallback(.success(makeSnapshot(collectedAt: "2026-10-13T12:05:10Z", storage: nil)))
        try await harness.tick()
        #expect(harness.backend.skipStorageFlags.last == true)

        // A minute after the miss, not five: the cut section was no collection.
        harness.clock.advance(60)
        let fresh = StorageSummary(label: "Scratch", source: "lustre", availableGB: 880, usedPercent: 56)
        harness.backend.setFallback(.success(makeSnapshot(collectedAt: "2026-10-13T12:06:10Z", storage: [home, fresh])))
        try await harness.tick()
        #expect(harness.backend.skipStorageFlags.last == false)
        #expect(harness.session.snapshot?.storage == [home, fresh])
        #expect(harness.session.storageCollectedAt == "2026-10-13T12:06:10Z")
    }

    @Test("Figures are carried only for a while: a volume that keeps failing shows as unreadable")
    func carryIsBounded() async throws {
        let harness = try SessionHarness(backend: FakeBackend(snapshot: makeSnapshot(storage: [home, scratch])))
        try await harness.startAndSettle()

        harness.clock.advance(300)
        harness.backend.setFallback(.success(makeSnapshot(collectedAt: "2026-10-13T12:05:00Z", storage: [home, scratchNotReached])))
        try await harness.tick()
        #expect(harness.session.snapshot?.storage == [home, scratch])

        harness.clock.advance(ClusterSession.storageCarryLimit)
        harness.backend.setFallback(.success(makeSnapshot(collectedAt: "2026-10-13T12:15:00Z", storage: [home, scratchNotReached])))
        try await harness.tick()
        #expect(harness.backend.skipStorageFlags.last == false)
        #expect(harness.session.snapshot?.storage == [home, scratchNotReached])
    }

    @Test("After a sign-in as another account, a row cut short never shows the previous account's figures or path")
    func accountChangeNeverCarriesEarlierRows() async throws {
        let homeA = StorageSummary(label: "Home", path: "/users/abcd1234", source: "nfs", usedPercent: 40)
        let scratchA = StorageSummary(label: "Scratch", path: "/scratch/users/abcd1234", source: "lustre", availableGB: 900, usedPercent: 55)
        let harness = try SessionHarness(backend: FakeBackend(snapshot: makeSnapshot(storage: [homeA, scratchA])))
        try await harness.startAndSettle()

        // Three minutes later (well inside the carry limit), signed in as
        // another account whose Home df stalls.
        harness.clock.advance(180)
        let homeCutB = StorageSummary(label: "Home", path: "/users/efgh5678", source: "unavailable", unavailableReason: "no-figures")
        let scratchB = StorageSummary(label: "Scratch", path: "/scratch/users/efgh5678", source: "lustre", availableGB: 100, usedPercent: 90)
        harness.backend.setFallback(.success(makeSnapshot(collectedAt: "2026-10-13T12:03:00Z", storage: [homeCutB, scratchB])))
        harness.host.signInConfiguration.username = "efgh5678"
        let before = harness.backend.completedCollections
        harness.session.markLoginQueued()
        #expect(await harness.session.performLogin(password: "pw", configuration: harness.host.signInConfiguration) == .succeeded(passwordVerified: true))
        try await waitUntil("post-login refresh") { harness.backend.completedCollections > before && !harness.session.refreshInFlight }

        #expect(harness.session.snapshot?.storage == [homeCutB, scratchB], "the previous account's Home row was shown as this account's")
        #expect(harness.session.storageCollectedAt == "2026-10-13T12:03:00Z")
        #expect(harness.session.history.last?.homeUsedPercent == nil)
    }

    @Test("After a sign-in as another account, a refresh without storage shows none, not the previous account's rows")
    func accountChangeNeverKeepsEarlierRows() async throws {
        let homeA = StorageSummary(label: "Home", path: "/users/abcd1234", source: "nfs", usedPercent: 40)
        let harness = try SessionHarness(backend: FakeBackend(snapshot: makeSnapshot(storage: [homeA])))
        try await harness.startAndSettle()

        harness.clock.advance(180)
        harness.backend.setFallback(.success(makeSnapshot(collectedAt: "2026-10-13T12:03:00Z", storage: nil)))
        harness.host.signInConfiguration.username = "efgh5678"
        let before = harness.backend.completedCollections
        harness.session.markLoginQueued()
        #expect(await harness.session.performLogin(password: "pw", configuration: harness.host.signInConfiguration) == .succeeded(passwordVerified: true))
        try await waitUntil("post-login refresh") { harness.backend.completedCollections > before && !harness.session.refreshInFlight }

        #expect(harness.session.snapshot?.storage == nil, "the previous account's rows were kept as this account's")
        #expect(harness.session.storageCollectedAt == nil)

        // The new account's own rows arrive with its first collection.
        harness.clock.advance(ClusterSession.storageRetryAfterMiss)
        let homeB = StorageSummary(label: "Home", path: "/users/efgh5678", source: "nfs", usedPercent: 12)
        harness.backend.setFallback(.success(makeSnapshot(collectedAt: "2026-10-13T12:04:00Z", storage: [homeB])))
        try await harness.tick()
        #expect(harness.backend.skipStorageFlags.last == false)
        #expect(harness.session.snapshot?.storage == [homeB])
    }

    @Test("After a sign-in as another account, a failed jobs section shows no jobs, never the previous account's queue")
    func accountChangeNeverKeepsEarlierJobs() async throws {
        let jobA = Job(jobId: "101", user: "abcd1234", state: "RUNNING")
        let harness = try SessionHarness(backend: FakeBackend(snapshot: makeSnapshot(jobs: [jobA])))
        try await harness.startAndSettle()
        #expect(harness.session.snapshot?.jobs.map(\.jobId) == ["101"])

        harness.backend.setFallback(.success(makeSnapshot(
            collectedAt: "2026-10-13T12:01:00Z",
            errors: ["Section 'jobs' failed with exit 1"]
        )))
        harness.host.signInConfiguration.username = "efgh5678"
        let before = harness.backend.completedCollections
        harness.session.markLoginQueued()
        #expect(await harness.session.performLogin(password: "pw", configuration: harness.host.signInConfiguration) == .succeeded(passwordVerified: true))
        try await waitUntil("post-login refresh") { harness.backend.completedCollections > before && !harness.session.refreshInFlight }

        #expect(harness.session.snapshot?.jobs.isEmpty == true, "the previous account's jobs were kept as this account's")
        // Nodes and partitions are cluster-wide; the session stays live.
        #expect(harness.session.isLoggedIn)
    }

    @Test("A change of login host alone keeps the account's storage rows")
    func hostChangeKeepsRows() async throws {
        let home = StorageSummary(label: "Home", path: "/users/abcd1234", source: "nfs", usedPercent: 40)
        let harness = try SessionHarness(backend: FakeBackend(snapshot: makeSnapshot(storage: [home])))
        try await harness.startAndSettle()

        harness.backend.setFallback(.success(makeSnapshot(collectedAt: "2026-10-13T12:01:00Z", storage: nil)))
        harness.session.hostname = "login2.aire.leeds.ac.uk"
        let before = harness.backend.completedCollections
        harness.session.markLoginQueued()
        #expect(await harness.session.performLogin(password: "pw", configuration: harness.host.signInConfiguration) == .succeeded(passwordVerified: true))
        try await waitUntil("post-login refresh") { harness.backend.completedCollections > before && !harness.session.refreshInFlight }

        #expect(harness.session.snapshot?.storage == [home])
        #expect(harness.session.storageCollectedAt == "2026-10-13T12:00:00Z")
    }

    @Test("Only rows cut short keep earlier figures; a volume that is gone is shown as gone")
    func mergeRules() {
        let labels: Set<String> = ["Home", "Scratch"]
        #expect(ClusterSession.mergeStorage(previous: [home, scratch], incoming: [home, scratchNotReached], labelsWithFigures: labels, carryCutRows: true) == [home, scratch])
        #expect(ClusterSession.mergeStorage(previous: [home, scratch], incoming: [home, scratchStalled], labelsWithFigures: labels, carryCutRows: true) == [home, scratch])
        #expect(ClusterSession.mergeStorage(previous: [home, scratch], incoming: [home, scratchNotReached], labelsWithFigures: labels, carryCutRows: false) == [home, scratchNotReached])
        #expect(ClusterSession.mergeStorage(previous: [home, scratch], incoming: [home, scratchMissing], labelsWithFigures: labels, carryCutRows: true) == [home, scratchMissing])
        // Nothing to carry when the previous row had no figures either.
        #expect(ClusterSession.mergeStorage(previous: [home, scratchStalled], incoming: [home, scratchNotReached], labelsWithFigures: labels, carryCutRows: true) == [home, scratchNotReached])

        #expect(ClusterSession.storageCarriesEarlierRows(incoming: [home, scratchNotReached], merged: [home, scratch]))
        #expect(!ClusterSession.storageCarriesEarlierRows(incoming: [home, scratchNotReached], merged: [home, scratchNotReached]))
        #expect(!ClusterSession.storageCarriesEarlierRows(incoming: [home, scratch], merged: [home, scratch]))
        #expect(!ClusterSession.storageCarriesEarlierRows(incoming: nil, merged: [home, scratch]))
    }
}

/// Cancel job edge cases.
@MainActor
@Suite("ClusterSession · cancel job")
struct SessionCancelJobTests {
    @Test("A remainder without a task string is still cancelled by array id, pending tasks only")
    func remainderWithoutTaskString() {
        let remainder = Job(jobId: "9863", state: "PENDING", arrayJobID: 9863, arrayPendingTasks: "")
        #expect(remainder.isArrayRemainder)
        #expect(ClusterSession.cancelCommand(for: remainder) == "scancel --state=PENDING '9863'")
    }

    @Test("A scancel that times out is not reported as a login timeout")
    func scancelTimeout() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        harness.backend.setRemoteCommandResult(ProcessResult(
            stdout: "",
            stderr: "Process timed out after 30s: /usr/bin/ssh",
            exitCode: MonitorService.processTimedOutExitCode
        ))
        await #expect(throws: MonitorError.self) {
            try await harness.session.cancelJob(Job(jobId: "42"))
        }
        let message = try #require(harness.session.errorMessage)
        #expect(message.contains("did not answer in time"))
        #expect(!message.contains("login"))
        try await waitUntil("follow-up refresh") { !harness.session.refreshInFlight }
    }
}
