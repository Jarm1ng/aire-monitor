import HPCCore
import Foundation
import Testing
@testable import AIREMonitorApp

private let observedAt = Date(timeIntervalSince1970: 1_791_000_000)
nonisolated(unsafe) private let iso8601 = ISO8601DateFormatter()

private func baseline(_ jobs: [Job], at date: Date = observedAt) -> JobStateSnapshot {
    JobStateSnapshot(jobs: jobs, observedAt: iso8601.string(from: date))
}

/// Start/end detection and the gap rules. A job that ends while the lid is
/// closed must still be reported — individually after a short gap, as one
/// catch-up summary after a long one, and not at all (silent re-seed) once
/// the baseline is too old to mean anything.
@Suite("Job events")
struct JobEventTests {
    @Test("Pending to running is a start; a terminal state or leaving squeue is an ending")
    func basicDiff() {
        let previous = baseline([
            Job(jobId: "1", partition: "gpu", name: "a", state: "PENDING"),
            Job(jobId: "2", partition: "gpu", name: "b", state: "RUNNING"),
            Job(jobId: "3", partition: "gpu", name: "c", state: "RUNNING"),
            Job(jobId: "4", partition: "gpu", name: "d", state: "SUSPENDED")
        ])
        let current = [
            Job(jobId: "1", partition: "gpu", name: "a", state: "RUNNING"),
            Job(jobId: "2", partition: "gpu", name: "b", state: "COMPLETED"),
            Job(jobId: "4", partition: "gpu", name: "d", state: "RUNNING")
        ]
        let (started, ended) = JobStateDiff.compute(previous: previous, current: current)
        #expect(started.map(\.jobId) == ["1"], "a suspended job resuming is not a start")
        #expect(ended.map(\.jobId) == ["2", "3"])
        #expect(ended.first?.finalState == "COMPLETED")
        #expect(ended.last?.finalState == JobEnding.leftQueue)
    }

    @Test("Array tasks splitting off the pending remainder start; the remainder vanishing is not an ending")
    func arrayDiff() {
        let previous = baseline([
            Job(jobId: "900", name: "sweep", state: "PENDING", arrayJobID: 900, arrayPendingTasks: "1-2", pendingTaskCount: 2),
            Job(jobId: "900_0", name: "sweep", state: "RUNNING", arrayJobID: 900)
        ])
        let current = [
            Job(jobId: "900_0", name: "sweep", state: "RUNNING", arrayJobID: 900),
            Job(jobId: "900_1", name: "sweep", state: "RUNNING", arrayJobID: 900),
            Job(jobId: "900_2", name: "sweep", state: "RUNNING", arrayJobID: 900)
        ]
        let (started, ended) = JobStateDiff.compute(previous: previous, current: current)
        #expect(started.map(\.jobId) == ["900_1", "900_2"])
        #expect(ended.isEmpty)
    }

    @Test("Short gaps alert individually, long gaps summarise, very long gaps re-seed silently")
    func gapRules() {
        let previous = baseline([Job(jobId: "1", state: "RUNNING")])
        let current: [Job] = []

        let fresh = JobStateDiff.plan(previous: previous, current: current, now: observedAt.addingTimeInterval(5 * 60))
        #expect(fresh?.delivery == .individual)
        #expect(fresh?.ended.map(\.jobId) == ["1"])

        let afterSleep = JobStateDiff.plan(previous: previous, current: current, now: observedAt.addingTimeInterval(3 * 3600))
        #expect(afterSleep?.delivery == .summary(unobservedFor: 3 * 3600))

        #expect(JobStateDiff.plan(previous: previous, current: current, now: observedAt.addingTimeInterval(2 * 86_400)) == nil)
        #expect(JobStateDiff.plan(previous: nil, current: current, now: observedAt) == nil)
        let unreadable = JobStateSnapshot(updatedAt: "yesterday-ish", jobs: previous.jobs)
        #expect(JobStateDiff.plan(previous: unreadable, current: current, now: observedAt) == nil)
        #expect(JobStateDiff.plan(previous: previous, current: [Job(jobId: "1", state: "RUNNING")], now: observedAt.addingTimeInterval(60)) == nil)
    }

    @Test("A baseline seeded from the collector's fractional timestamp still parses")
    func fractionalTimestamps() {
        let previous = JobStateSnapshot(jobs: [Job(jobId: "1", state: "RUNNING")], observedAt: "2026-10-13T12:07:04.915081+00:00")
        let now = SlurmTimestamp.parse("2026-10-13T12:09:04Z")!
        #expect(JobStateDiff.plan(previous: previous, current: [], now: now)?.delivery == .individual)
    }

    @Test("Old baselines without array fields still decode")
    func legacyBaselineDecodes() throws {
        let legacy = try decode(JobStateSnapshot.self, from: """
        {"updatedAt": "2026-10-11T21:14:03Z", "jobs": {"4410921": {"jobId": "4410921", "name": "train-l40s", "partition": "gpu", "state": "RUNNING", "lastSeenAt": "2026-10-11T21:14:03Z"}}}
        """)
        #expect(legacy.jobs["4410921"]?.arrayJobID == nil)
        #expect(legacy.jobs["4410921"]?.isArrayRemainder == nil)
    }

    @Test("A baseline recorded for another account re-seeds silently, also after a relaunch")
    func identityMismatchReseeds() throws {
        let jobsOfA = [Job(jobId: "101", state: "RUNNING"), Job(jobId: "102", state: "RUNNING")]
        let previous = JobStateSnapshot(jobs: jobsOfA, observedAt: iso8601.string(from: observedAt), identity: "abcd1234@aire.leeds.ac.uk")
        let soon = observedAt.addingTimeInterval(60)

        #expect(JobStateDiff.plan(previous: previous, current: [], now: soon, identity: "efgh5678@aire.leeds.ac.uk") == nil,
                "another account's jobs did not end just because they are not in this account's list")
        #expect(JobStateDiff.plan(previous: previous, current: [], now: soon, identity: "abcd1234@aire.leeds.ac.uk")?.ended.count == 2)

        // The identity survives the file round trip, so a relaunch under
        // another account re-seeds too.
        let reloaded = try decode(JobStateSnapshot.self, from: String(decoding: JSONEncoder().encode(previous), as: UTF8.self))
        #expect(reloaded.identity == "abcd1234@aire.leeds.ac.uk")
        #expect(JobStateDiff.plan(previous: reloaded, current: [], now: soon, identity: "efgh5678@aire.leeds.ac.uk") == nil)
    }

    @Test("Only the account is compared: another login host, or a baseline in the earlier user@host form, still diffs")
    func identityComparesAccountOnly() {
        let jobs = [Job(jobId: "101", state: "RUNNING"), Job(jobId: "102", state: "RUNNING")]
        let soon = observedAt.addingTimeInterval(60)
        // squeue -u $USER answers the same from every login node.
        let earlierBuild = JobStateSnapshot(jobs: jobs, observedAt: iso8601.string(from: observedAt), identity: "abcd1234@calder.leeds.ac.uk")
        #expect(JobStateDiff.plan(previous: earlierBuild, current: [], now: soon, identity: "abcd1234@calder")?.ended.count == 2)
        #expect(JobStateDiff.plan(previous: earlierBuild, current: [], now: soon, identity: "abcd1234@login2.calder.leeds.ac.uk")?.ended.count == 2)
        #expect(JobStateDiff.plan(previous: earlierBuild, current: [], now: soon, identity: "efgh5678@calder") == nil)

        let current = JobStateSnapshot(jobs: jobs, observedAt: iso8601.string(from: observedAt), identity: "abcd1234@calder")
        #expect(JobStateDiff.plan(previous: current, current: [], now: soon, identity: "abcd1234@calder")?.ended.count == 2)
        #expect(JobStateDiff.plan(previous: current, current: [], now: soon, identity: "efgh5678@calder") == nil)

        #expect(JobStateDiff.account(of: "abcd1234@calder.leeds.ac.uk") == "abcd1234")
        #expect(JobStateDiff.account(of: "abcd1234") == "abcd1234")
        #expect(JobStateDiff.account(of: "a@b@calder") == "a@b")
    }

    @Test("The session's job identity is the account on its cluster, whatever the login host")
    func sessionJobIdentityIgnoresHost() {
        let calder = catalogProfile(.calder)
        let roundRobin = ClusterSession.jobIdentity(of: makeSettings(calder))
        #expect(roundRobin == ClusterSession.jobIdentity(of: makeSettings(calder, hostname: "login2.calder.leeds.ac.uk")))
        #expect(roundRobin == ClusterSession.jobIdentity(of: makeSettings(calder, route: .rashJump)))
        #expect(roundRobin != ClusterSession.jobIdentity(of: makeSettings(calder, username: "efgh5678")))
    }

    @Test("A baseline written before identities were recorded still decodes and still diffs")
    func legacyBaselineWithoutIdentity() throws {
        let legacy = try decode(JobStateSnapshot.self, from: """
        {"updatedAt": "\(iso8601.string(from: observedAt))", "jobs": {"7": {"jobId": "7", "name": "train", "partition": "gpu", "state": "RUNNING", "lastSeenAt": "\(iso8601.string(from: observedAt))"}}}
        """)
        #expect(legacy.identity == nil)
        let changes = JobStateDiff.plan(previous: legacy, current: [], now: observedAt.addingTimeInterval(60), identity: "abcd1234@aire.leeds.ac.uk")
        #expect(changes?.ended.map(\.jobId) == ["7"])
    }

    @Test("A long gap produces one catch-up notification")
    func catchUpNotification() throws {
        let changes = JobStateChanges(
            started: [JobStart(name: "a", jobId: "1", partition: "gpu")],
            ended: (2...9).map { JobEnding(name: "j\($0)", jobId: "\($0)", partition: "gpu", lastState: "RUNNING", finalState: JobEnding.leftQueue, detail: "") },
            delivery: .summary(unobservedFor: 7200)
        )
        let notifications = JobNotificationService.notifications(for: changes, cluster: catalogProfile(.calder), timestamp: "t")
        let summary = try #require(notifications.first)
        #expect(notifications.count == 1)
        #expect(summary.title == "Calder · while you were away")
        #expect(summary.subtitle.contains("8 jobs ended or left the queue, 1 started"))
        #expect(summary.body.contains("… and 3 more"))
    }

    @Test("Individual delivery: one per start, one ending or one summary of endings")
    func individualNotifications() {
        let one = JobStateChanges(
            started: [JobStart(name: "", jobId: "5", partition: "gpu")],
            ended: [JobEnding(name: "x", jobId: "6", partition: "gpu", lastState: "RUNNING", finalState: "FAILED", detail: "d")],
            delivery: .individual
        )
        let posted = JobNotificationService.notifications(for: one, cluster: catalogProfile(.aire), timestamp: "t")
        #expect(posted.map(\.title) == ["AIRE · job started", "AIRE · job ended"])
        #expect(posted.first?.body.hasPrefix("Job 5 (#5)") == true)
        #expect(posted.last?.subtitle == "Job ended: FAILED")
    }

    @Test("Job notifications post only when allowed")
    @MainActor
    func postingRespectsAuthorization() async throws {
        let poster = FakeNotificationPoster()
        let service = JobNotificationService(poster: poster)
        let changes = JobStateChanges(started: [JobStart(name: "a", jobId: "1", partition: "gpu")], ended: [], delivery: .individual)

        poster.status = .denied
        service.notifyJobChanges(changes, cluster: catalogProfile(.aire))
        try await waitUntil("authorization checked") { service.authorization == .denied }
        await settle()
        #expect(poster.posted.isEmpty)

        poster.status = .authorized
        service.notifyJobChanges(changes, cluster: catalogProfile(.aire))
        try await waitUntil("posted") { poster.posted.count == 1 }
    }
}

@Suite("GPU-free alert")
struct GPUFreeAlertTests {
    private let start = Date(timeIntervalSince1970: 1_791_000_000)

    @Test("Fires on 0 → >0, then respects the cooldown without losing the transition")
    func cooldown() {
        var tracker = GPUFreeAlertTracker()
        var fired = tracker.evaluate(idleGPUs: 0, alertsEnabled: true, now: start)
        #expect(!fired, "first observation only seeds")
        fired = tracker.evaluate(idleGPUs: 2, alertsEnabled: true, now: start)
        #expect(fired)
        tracker.recordFired(at: start)
        fired = tracker.evaluate(idleGPUs: 0, alertsEnabled: true, now: start.addingTimeInterval(60))
        #expect(!fired)
        // Within the cooldown: suppressed, but the baseline stays 0…
        fired = tracker.evaluate(idleGPUs: 1, alertsEnabled: true, now: start.addingTimeInterval(120))
        #expect(!fired)
        #expect(tracker.previousIdle == 0)
        // …so the transition fires once the cooldown has passed.
        fired = tracker.evaluate(idleGPUs: 1, alertsEnabled: true, now: start.addingTimeInterval(GPUFreeAlertTracker.cooldown + 1))
        #expect(fired)
    }

    @Test("Unknown allocation keeps the baseline; a disabled preference advances it")
    func unknownAndDisabled() {
        var tracker = GPUFreeAlertTracker()
        _ = tracker.evaluate(idleGPUs: 0, alertsEnabled: true, now: start)
        var fired = tracker.evaluate(idleGPUs: nil, alertsEnabled: true, now: start)
        #expect(!fired)
        #expect(tracker.previousIdle == 0)
        fired = tracker.evaluate(idleGPUs: 3, alertsEnabled: false, now: start)
        #expect(!fired)
        #expect(tracker.previousIdle == 3)
        fired = tracker.evaluate(idleGPUs: 4, alertsEnabled: true, now: start)
        #expect(!fired, "no 0 → >0 transition")
    }
}
