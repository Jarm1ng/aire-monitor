import HPCCore
import AppKit
import Foundation
import Testing
@testable import AIREMonitorApp

// The status item's menu, as data: which rows each cluster state gets, in
// which order, what the badge reacts to, and what the menu never offers.

private let collected = "2026-10-13T12:03:54.592330+00:00"
private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func phaseStatus(_ phase: ClusterPresentation.Phase, detail: String = "", action: ClusterPresentation.Action? = nil) -> MenuBarClusterStatus {
    MenuBarClusterStatus(phase: phase, title: "\(phase)", detail: detail, primaryAction: action)
}

private func running(_ id: String, name: String = "train", elapsed: String = "1:08:18", limit: String = "4:00:00") -> Job {
    Job(jobId: id, partition: "gpu", name: name, state: "RUNNING", elapsed: elapsed, timeLimit: limit, nodes: "1", reasonOrNodeList: "gpu003")
}

private func pending(_ id: String, reason: String = "(Priority)") -> Job {
    Job(jobId: id, partition: "gpu", name: "queued", state: "PENDING", timeLimit: "1:00:00", nodes: "1", reasonOrNodeList: reason)
}

private let l40sNode = NodeSummary(
    node: "gpu001", partitions: ["gpu"], state: "mix",
    cpuAllocated: 12, cpuIdle: 12, cpuTotal: 24,
    gres: "gpu:l40s:3(S:0-1)", gpuTotal: 3, gpuAllocated: 1, gpuIdle: 2
)

private let drainedL40Node = NodeSummary(
    node: "gpu028", partitions: ["aire-gpu-lovelace"], state: "drain*",
    cpuAllocated: 0, cpuIdle: 24, cpuTotal: 24,
    gres: "gpu:nvidia_l40:3(S:0-1)", gpuTotal: 3, gpuAllocated: 0, gpuIdle: 3
)

private func digestCluster(
    _ profile: ClusterProfile,
    _ phase: ClusterPresentation.Phase,
    detail: String = "",
    action: ClusterPresentation.Action? = nil,
    jobs: [Job] = [],
    nodes: [NodeSummary] = [],
    storage: [StorageSummary]? = nil,
    hasSnapshot: Bool = true,
    errorMessage: String? = nil,
    schedulerIssue: String? = nil,
    sessionSince: Date? = nil,
    drop: MenuBarDrop? = nil,
    usage: [String: JobUsageSummary] = [:],
    signInFailed: Bool = false
) -> MenuBarClusterDigest {
    MenuBarClusterDigest(
        profile: profile,
        status: phaseStatus(phase, detail: detail, action: action),
        errorMessage: errorMessage,
        schedulerIssue: schedulerIssue,
        snapshot: hasSnapshot ? ClusterSnapshot(collectedAt: collected, jobs: jobs, nodes: nodes, storage: storage) : nil,
        sessionSince: sessionSince,
        drop: drop,
        jobUsage: usage,
        lastSignInFailed: signInFailed
    )
}

private func ids(_ entries: [MenuEntry]) -> [String] {
    entries.map(\.id)
}

private func items(_ entries: [MenuEntry]) -> [MenuItemModel] {
    entries.compactMap { if case .item(let item) = $0 { return item } else { return nil } }
}

private func header(_ entries: [MenuEntry], _ id: ClusterID) -> MenuClusterHeader? {
    for entry in entries {
        if case .clusterHeader(let header) = entry, header.cluster == id {
            return header
        }
    }
    return nil
}

private func usage(_ id: String, gpus: [Double]) -> JobUsageSummary {
    JobUsageSummary(displayID: id, sampledAt: now, nodes: [JobNodeUsage(
        jobID: id, displayID: id, node: "calder-h200-01",
        gpuIndices: Array(gpus.indices),
        gpus: gpus.enumerated().map { GPUUsage(index: $0.offset, name: "NVIDIA H200", utilizationPercent: $0.element, memoryUsedMB: 1, memoryTotalMB: 2) }
    )])
}

@MainActor
@Suite("Menu bar menu layout")
struct MenuBarMenuLayoutTests {
    @Test("Two live clusters: header, counts, running jobs, GPU pools, warned storage, then the footer")
    func twoLive() {
        let storage = [
            StorageSummary(label: "home", usedPercent: 69),
            StorageSummary(label: "scratch", usedPercent: 88),
            StorageSummary(label: "flash", usedPercent: 62)
        ]
        let aire = digestCluster(
            .aire, .live,
            jobs: [running("8248307_0", name: "train-resnet50"), running("8248307_1", name: "train-resnet50"), pending("8248326")],
            nodes: [l40sNode],
            storage: storage,
            sessionSince: now.addingTimeInterval(-3 * 3600)
        )
        let calder = digestCluster(.calder, .live, jobs: [running("9926", name: "monitor-loop", limit: "12:00:00")], nodes: [drainedL40Node])
        let entries = MenuBarMenuLayout.build(digest: MenuBarDigest(clusters: [aire, calder], canRenew: true), now: now)
        #expect(ids(entries) == [
            "aire.header", "aire.counts", "aire.job.8248307_0", "aire.job.8248307_1", "aire.gpu.L40S", "aire.storage.scratch", "aire.separator",
            "calder.header", "calder.counts", "calder.job.9926", "calder.gpu.L40", "calder.separator",
            "footer.dashboard", "footer.widget", "footer.renew", "footer.titleMode", "footer.separator", "footer.quit"
        ])
        #expect(header(entries, .aire)?.statusText == "up 3 h")
        #expect(header(entries, .aire)?.dot == .live)
        #expect(header(entries, .calder)?.statusText == "Live")
        let rows = items(entries)
        #expect(rows.first { $0.id == "aire.counts" }?.title == "2 running · 1 pending")
        #expect(rows.first { $0.id == "aire.counts" }?.submenu == .jobs(.aire))
        let job = rows.first { $0.id == "aire.job.8248307_0" }
        #expect(job?.title == "train-resnet50 · 8248307_0")
        #expect(job?.trailing == "1h 08m of 4h")
        #expect(job?.command == .openJob(.aire, "8248307_0"))
        #expect(rows.first { $0.id == "calder.job.9926" }?.trailing == "1h 08m of 12h")
        #expect(rows.first { $0.id == "footer.renew" }?.isEnabled == true)

        // Zeros are explained; positives are not.
        let gpus = entries.compactMap { if case .gpuPool(_, let row) = $0 { return row } else { return nil } }
        #expect(gpus.first { $0.label == "L40S" }?.caption == nil)
        #expect(gpus.first { $0.label == "L40" }?.caption == "all 3 unavailable")
        // Storage below 75 % is not listed; the healthy shared home neither.
        #expect(!ids(entries).contains("aire.storage.flash"))
        #expect(!ids(entries).contains("home.storage"))
    }

    @Test("Each state gets its own short section", arguments: [
        (ClusterPresentation.Phase.notConnected, ["calder.header", "calder.connect"]),
        (.checking, ["calder.header"]),
        (.queued, ["calder.header", "calder.note", "calder.cancelSignIn"]),
        (.signingIn, ["calder.header", "calder.note", "calder.cancelSignIn"]),
        (.loadingFirstSnapshot, ["calder.header"]),
        (.paused, ["calder.header", "calder.resume", "calder.counts"]),
        (.stale, ["calder.header", "calder.connect", "calder.counts"]),
        (.off(hasCache: false), ["calder.header", "calder.turnOn"])
    ])
    func states(phase: ClusterPresentation.Phase, expected: [String]) {
        let calder = digestCluster(.calder, phase, detail: "Waiting for Duo approval on your phone", jobs: [running("1")])
        let entries = MenuBarMenuLayout.build(digest: MenuBarDigest(clusters: [calder]), now: now)
        let section = Array(ids(entries).prefix { $0 != "calder.separator" })
        #expect(section == expected, "\(phase)")
        // A cluster that is not live never shows elapsed times, GPU or storage rows.
        #expect(!ids(entries).contains { $0.hasPrefix("calder.job.") || $0.hasPrefix("calder.gpu.") || $0.hasPrefix("calder.storage.") })
        if case .stale = phase {
            #expect(items(entries).first { $0.id == "calder.counts" }?.title.hasPrefix("As of ") == true)
        }
    }

    @Test("A dropped session: red header, the shared drop wording, Connect — and the badge")
    func dropped() {
        let note = SessionDropNote.make(
            drop: SessionDrop(at: now, lasted: 11 * 3600 + 52 * 60),
            state: .pending(attempts: 0, notBefore: now),
            reconnectAutomatically: false,
            isSigningIn: false
        )
        let calder = digestCluster(.calder, .stale, jobs: [running("1")], drop: MenuBarDrop(at: now, note: note))
        let digest = MenuBarDigest(clusters: [calder])
        let entries = MenuBarMenuLayout.build(digest: digest, now: now)
        #expect(Array(ids(entries).prefix(3)) == ["calder.header", "calder.note", "calder.connect"])
        #expect(header(entries, .calder)?.dot == .critical)
        #expect(header(entries, .calder)?.statusText == "Dropped \(note.when)")
        guard case .note(_, let shown)? = entries.dropFirst().first else {
            Issue.record("expected the drop note")
            return
        }
        #expect(shown.text == "Lasted 11 h 52 min · sign in to continue")
        #expect(digest.attention.map(\.kind) == [.dropped])
        #expect(StatusBarSummary(digest: digest).hasAttention)
        // The card in the sidebar words the same drop the same way.
        #expect(note.cardText == "dropped \(note.when) after 11 h 52 min · sign in to continue")

        // After a Disconnect there is no drop: no red header, no badge.
        let signedOut = digestCluster(.calder, .notConnected, hasSnapshot: false)
        #expect(MenuBarDigest(clusters: [signedOut]).attention.isEmpty)
    }

    @Test("A failed sign-in badges; signing in again, not connected, off, paused or ageing never do")
    func badgeRules() {
        let failed = digestCluster(.calder, .notConnected, hasSnapshot: false, errorMessage: "Calder rejected the password.", signInFailed: true)
        let failedDigest = MenuBarDigest(clusters: [failed])
        #expect(failedDigest.attention.map(\.kind) == [.signInFailed])
        let entries = MenuBarMenuLayout.build(digest: failedDigest, now: now)
        #expect(header(entries, .calder)?.statusText == "Sign-in failed")
        #expect(ids(entries).contains("calder.connect"))

        let retrying = digestCluster(.calder, .signingIn, hasSnapshot: false, errorMessage: "Calder rejected the password.", signInFailed: true)
        #expect(MenuBarDigest(clusters: [retrying]).attention.isEmpty)
        let quiet: [MenuBarClusterDigest] = [
            digestCluster(.aire, .notConnected, hasSnapshot: false),
            digestCluster(.calder, .off(hasCache: false), hasSnapshot: false),
            digestCluster(.calder, .paused),
            digestCluster(.aire, .live, sessionSince: now.addingTimeInterval(-13 * 3600))
        ]
        for cluster in quiet {
            #expect(MenuBarDigest(clusters: [cluster]).attention.isEmpty, "\(cluster.status.phase)")
        }
    }

    @Test("Slurm not answering: a note and the counts marked not current — no jobs, GPUs or storage")
    func degraded() {
        let calder = digestCluster(
            .calder, .live,
            jobs: [running("1"), pending("2")],
            nodes: [drainedL40Node],
            storage: [StorageSummary(label: "scratch", usedPercent: 95)],
            schedulerIssue: "Slurm error on Calder: Section 'jobs' failed with exit 1"
        )
        let entries = MenuBarMenuLayout.build(digest: MenuBarDigest(clusters: [calder]), now: now)
        #expect(Array(ids(entries).prefix { $0 != "calder.separator" }) == ["calder.header", "calder.note", "calder.counts"])
        #expect(header(entries, .calder)?.statusText == "Slurm not answering")
        #expect(items(entries).first { $0.id == "calder.counts" }?.title == "1 running · 1 pending (not current)")
    }

    @Test("Jobs whose GPUs sit idle are listed first and marked")
    func flaggedJobsPromoted() {
        let jobs = (1...5).map { running("\($0)", name: "job\($0)") }
        let calder = digestCluster(.calder, .live, jobs: jobs, usage: [
            "5": usage("5", gpus: [97, 96, 0, 1]),
            "1": usage("1", gpus: [95])
        ])
        let entries = MenuBarMenuLayout.build(digest: MenuBarDigest(clusters: [calder]), now: now)
        let listed = items(entries).filter { $0.id.hasPrefix("calder.job.") }
        #expect(listed.count == MenuBarMenuLayout.inlineJobLimit)
        #expect(listed.contains { $0.id == "calder.job.5" })
        #expect(listed.first { $0.id == "calder.job.5" }?.trailing?.hasPrefix("⚠\u{FE0E} ") == true)
        #expect(listed.first { $0.id == "calder.job.1" }?.trailing?.hasPrefix("⚠") == false)
        #expect(listed.first { $0.id == "calder.job.5" }?.toolTip?.contains("2 of 4 GPUs idle") == true)
    }

    @Test("The jobs submenu caps its rows and its '+N more' adds up; it ends with Open in Dashboard")
    func jobsSubmenu() {
        let jobs = (1...5).map { running("r\($0)") } + (1...30).map { pending("p\($0)") } + [pending("h1", reason: "(JobHeldUser)")]
        let aire = digestCluster(.aire, .live, jobs: jobs)
        let entries = MenuBarMenuLayout.submenu(for: .aire, digest: MenuBarDigest(clusters: [aire]))
        let rows = items(entries)
        #expect(rows.filter { $0.id.hasPrefix("aire.all.") && $0.command != nil && $0.id != "aire.all.open" }.count == MenuBarMenuLayout.submenuJobLimit)
        #expect(rows.filter(\.isSectionHeader).map(\.title) == ["Running", "Pending"])
        #expect(rows.first { $0.id == "aire.all.more" }?.title == "+16 more")
        #expect(rows.last?.command == .openCluster(.aire))
        #expect(rows.first { $0.id == "aire.all.p1" }?.trailing == "Priority")
        let held = MenuBarMenuLayout.submenu(for: .aire, digest: MenuBarDigest(clusters: [digestCluster(.aire, .live, jobs: [pending("h1", reason: "(JobHeldUser)")])]))
        #expect(items(held).first { $0.id == "aire.all.h1" }?.trailing == "Held by you")
    }

    @Test("The renew note appears once the oldest live leg — rash included — is 11 h old")
    func renewNote() {
        let aire = digestCluster(.aire, .live, sessionSince: now.addingTimeInterval(-3600))
        let young = MenuBarDigest(clusters: [aire], jumpSince: now.addingTimeInterval(-2 * 3600))
        #expect(!ids(MenuBarMenuLayout.build(digest: young, now: now)).contains("renew.note"))
        let oldRash = MenuBarDigest(clusters: [aire], jumpSince: now.addingTimeInterval(-11.5 * 3600))
        #expect(ids(MenuBarMenuLayout.build(digest: oldRash, now: now)).contains("renew.note"))
        #expect(oldRash.oldestLiveSince == now.addingTimeInterval(-11.5 * 3600))
        // A connected cluster whose Slurm is not answering still ages.
        let degraded = digestCluster(.calder, .live, schedulerIssue: "Slurm error", sessionSince: now.addingTimeInterval(-11.5 * 3600))
        #expect(ids(MenuBarMenuLayout.build(digest: MenuBarDigest(clusters: [degraded]), now: now)).contains("renew.note"))
    }

    @Test("Paused wins over an old error: Resume stays, no badge; a refresh error is a note, never a badge")
    func pausedAndRefreshErrors() {
        let paused = digestCluster(.calder, .paused, errorMessage: "Calder rejected the password.", signInFailed: true)
        let pausedDigest = MenuBarDigest(clusters: [paused])
        #expect(pausedDigest.attention.isEmpty)
        #expect(Array(ids(MenuBarMenuLayout.build(digest: pausedDigest, now: now)).prefix(3)) == ["calder.header", "calder.resume", "calder.note"])

        let refreshFailed = digestCluster(.calder, .stale, jobs: [running("1")], errorMessage: "ssh: connect to host calder.leeds.ac.uk port 22: Operation timed out")
        let digest = MenuBarDigest(clusters: [refreshFailed])
        #expect(digest.attention.isEmpty)
        let entries = MenuBarMenuLayout.build(digest: digest, now: now)
        #expect(header(entries, .calder)?.statusText.hasPrefix("Cached") == true)
        #expect(ids(entries).contains("calder.note"))
    }

    @Test("A sign-in attempted after a drop that failed says why under the drop")
    func dropThenFailedSignIn() {
        let note = SessionDropNote.make(drop: SessionDrop(at: now, lasted: nil), state: .suspended, reconnectAutomatically: true, isSigningIn: false)
        let calder = digestCluster(.calder, .notConnected, hasSnapshot: false, errorMessage: "Calder: the Duo push was declined.", drop: MenuBarDrop(at: now, note: note), signInFailed: true)
        let entries = MenuBarMenuLayout.build(digest: MenuBarDigest(clusters: [calder]), now: now)
        #expect(Array(ids(entries).prefix(4)) == ["calder.header", "calder.note", "calder.error", "calder.connect"])
        #expect(MenuBarDigest(clusters: [calder]).attention.map(\.kind) == [.dropped])
    }

    @Test("The shared home appears only under pressure, once")
    func sharedHomeWarning() {
        let storage = [StorageSummary(label: "home", usedPercent: 93)]
        let digest = MenuBarDigest(clusters: [digestCluster(.aire, .live, storage: storage), digestCluster(.calder, .live, storage: storage)])
        #expect(ids(MenuBarMenuLayout.build(digest: digest, now: now)).filter { $0 == "home.storage" }.count == 1)
    }

    @Test("Never in the menu: Reconnect, Disconnect or Refresh; Renew follows its confirmation's rule")
    func absentActions() {
        let entries = MenuBarMenuLayout.build(digest: MenuBarDigest(clusters: [digestCluster(.aire, .live)], canRenew: false), now: now)
        let titles = items(entries).map(\.title)
        #expect(!titles.contains { $0.contains("Reconnect") || $0.contains("Disconnect") || $0.contains("Refresh") })
        #expect(items(entries).first { $0.id == "footer.renew" }?.isEnabled == false)
        let modes = items(MenuBarMenuLayout.titleModeSubmenu(current: .idleGPUs))
        #expect(modes.map(\.title) == ["Running Jobs", "Idle GPUs", "Icon Only"])
        #expect(modes.filter(\.isChecked).map(\.title) == ["Idle GPUs"])
    }
}

@MainActor
@Suite("Menu bar renew availability")
struct MenuBarRenewTests {
    @Test("canRenew matches whether Renew all would do anything")
    func canRenewMatchesConfirmation() throws {
        let harness = try ModelHarness()
        #expect(MenuBarDigest(model: harness.model).canRenew == (harness.model.renewConfirmation() != nil))
        #expect(MenuBarDigest(model: harness.model).canRenew)
    }
}

@MainActor
@Suite("Sign-in failure flag")
struct SignInFailedFlagTests {
    @Test("A failed sign-in sets it; a failed refresh does not; the next sign-in clears it")
    func flag() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        #expect(!harness.session.signInFailed)

        harness.backend.enqueueLogin(.failure(MonitorError.duoNotApproved("Calder: the Duo push was declined.")))
        harness.session.markLoginQueued()
        let failed = await harness.session.performLogin(password: "x", configuration: harness.host.signInConfiguration)
        #expect(failed == .duoNotApproved)
        #expect(harness.session.signInFailed)

        harness.session.markLoginQueued()
        let succeeded = await harness.session.performLogin(password: "x", configuration: harness.host.signInConfiguration)
        #expect(succeeded == .succeeded(passwordVerified: true))
        #expect(!harness.session.signInFailed)

        // A refresh that fails over a live session is not a sign-in failure.
        harness.backend.setFallback(.failure(MonitorError.processFailed("ssh: connect to host calder port 22: Operation timed out")))
        harness.session.refresh()
        try await waitUntil("failed refresh") { !harness.session.refreshInFlight && harness.session.errorMessage != nil }
        #expect(!harness.session.signInFailed)
    }
}
