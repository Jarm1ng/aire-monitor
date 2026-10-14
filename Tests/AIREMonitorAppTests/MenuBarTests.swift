import HPCCore
import AppKit
import Combine
import Foundation
import Testing
@testable import AIREMonitorApp

// Menu bar: which clusters feed the status item, how jobs, array tasks and
// GPU pools are counted and worded, whether the title fits its cap, and
// that the dropdown's store only republishes real changes.

// MARK: - Fixtures

private let collectedAt = "2026-10-13T12:03:54.592330+00:00"

private func status(
    _ phase: ClusterPresentation.Phase,
    action: ClusterPresentation.Action? = nil,
    allowsRefresh: Bool = false
) -> MenuBarClusterStatus {
    MenuBarClusterStatus(phase: phase, title: "\(phase)", primaryAction: action, allowsRefresh: allowsRefresh)
}

private func runningJob(_ id: String, name: String = "train", start: String? = "2026-10-13T11:41:38", elapsed: String = "1:22:16") -> Job {
    Job(
        jobId: id,
        partition: "gpu",
        name: name,
        state: "RUNNING",
        elapsed: elapsed,
        timeLimit: "4:00:00",
        nodes: "1",
        reasonOrNodeList: "gpu003",
        startTime: start
    )
}

private func pendingJob(_ id: String, reason: String = "Priority") -> Job {
    Job(jobId: id, partition: "gpu", name: "queued", state: "PENDING", elapsed: "0:00", timeLimit: "1:00:00", nodes: "1", reasonOrNodeList: reason)
}

private func cluster(
    _ profile: ClusterProfile,
    _ phase: ClusterPresentation.Phase,
    jobs: [Job] = [],
    nodes: [NodeSummary] = [],
    storage: [StorageSummary]? = nil,
    hasSnapshot: Bool = true
) -> MenuBarClusterDigest {
    MenuBarClusterDigest(
        profile: profile,
        status: status(phase),
        snapshot: hasSnapshot ? ClusterSnapshot(collectedAt: collectedAt, jobs: jobs, nodes: nodes, storage: storage) : nil
    )
}

/// AIRE's gpu018 as seen live: ALLOCATED, every CPU taken, one GPU idle —
/// a stranded GPU no job can start on.
private let strandedNode = NodeSummary(
    node: "gpu018", partitions: ["gpu"], state: "alloc",
    cpuAllocated: 24, cpuIdle: 0, cpuTotal: 24,
    gres: "gpu:l40s:3(S:0-1)", gpuTotal: 3, gpuAllocated: 2, gpuIdle: 1
)

private let mixedL40SNode = NodeSummary(
    node: "gpu001", partitions: ["gpu"], state: "mix",
    cpuAllocated: 12, cpuIdle: 12, cpuTotal: 24,
    gres: "gpu:l40s:3(S:0-1)", gpuTotal: 3, gpuAllocated: 1, gpuIdle: 2
)

/// Calder's shape: H200s in calder-gpu-hopper, one L40 node elsewhere.
private func calderNodes(l40State: String = "drain*") -> [NodeSummary] {
    [
        NodeSummary(
            node: "calder-h200-01", partitions: ["calder-gpu-hopper"], state: "mix",
            cpuAllocated: 100, cpuIdle: 28, cpuTotal: 128,
            gres: "gpu:nvidia_h200:8(S:0-1)", gpuTotal: 8, gpuAllocated: 7, gpuIdle: 1
        ),
        NodeSummary(
            node: "calder-h200-02", partitions: ["calder-gpu-hopper"], state: "mix",
            cpuAllocated: 64, cpuIdle: 64, cpuTotal: 128,
            gres: "gpu:nvidia_h200:8(S:0-1)", gpuTotal: 8, gpuAllocated: 8, gpuIdle: 0
        ),
        NodeSummary(
            node: "calder-l40-01", partitions: ["aire-gpu-lovelace"], state: l40State,
            cpuAllocated: 0, cpuIdle: 64, cpuTotal: 64,
            gres: "gpu:nvidia_l40:3", gpuTotal: 3, gpuAllocated: 0, gpuIdle: 3
        )
    ]
}

/// AIRE's L40S nodes when the collector's node_details section failed or
/// was cut: GPU totals from gres, but no allocation for any of them.
private func unknownL40SNodes(_ count: Int) -> [NodeSummary] {
    (1...count).map { index in
        NodeSummary(
            node: "gpu10\(index)", partitions: ["gpu"], state: "mix",
            cpuAllocated: 12, cpuIdle: 12, cpuTotal: 24,
            gres: "gpu:l40s:3(S:0-1)", gpuTotal: 3, gpuAllocated: nil, gpuIdle: nil
        )
    }
}

/// Calder's H200 node with its allocation missing.
private func unknownH200Node(_ name: String) -> NodeSummary {
    NodeSummary(
        node: name, partitions: ["calder-gpu-hopper"], state: "mix",
        cpuAllocated: 64, cpuIdle: 64, cpuTotal: 128,
        gres: "gpu:nvidia_h200:8(S:0-1)", gpuTotal: 8, gpuAllocated: nil, gpuIdle: nil
    )
}

// MARK: - Live versus cached

@MainActor
@Suite("Menu bar digest")
struct MenuBarDigestTests {
    @Test("Cached clusters never feed the status item's job count or title")
    func cachedExcluded() {
        let aire = cluster(.aire, .live, jobs: [runningJob("8248307_0", start: "2026-10-13T11:41:38")])
        let calderJobs = (1...17).map { runningJob("38961_\($0)", name: "c2-mirrorsynth-rgpu", start: "2026-10-13T12:00:00") }
        let calder = cluster(.calder, .stale, jobs: calderJobs)
        let digest = MenuBarDigest(clusters: [aire, calder])

        #expect(digest.runningCount == 1)
        #expect(digest.primaryRunningJob?.cluster.id == .aire)
        let summary = StatusBarSummary(digest: digest)
        guard case .singleJob(let owner, let job) = summary.mode else {
            Issue.record("expected the single live job, got \(summary.mode)")
            return
        }
        #expect(owner.id == .aire)
        #expect(job.jobId == "8248307_0")
        #expect(summary.title.hasPrefix("A · "))
        // Calder's cached figures are named with their time instead.
        #expect(summary.tooltip.contains("17 running · 0 pending (as of "))
        #expect(digest.health == .partial)
    }

    @Test("Only cached data: the title says Cached and shows no frozen elapsed time")
    func onlyCached() {
        let aire = cluster(.aire, .stale, jobs: [runningJob("1"), runningJob("2")], nodes: [mixedL40SNode])
        let calder = cluster(.calder, .notConnected, hasSnapshot: false)
        let digest = MenuBarDigest(clusters: [aire, calder])
        let summary = StatusBarSummary(digest: digest)
        #expect(digest.runningCount == 0)
        #expect(summary.title == "Cached")
        #expect(digest.health == .stale)
        #expect(summary.tint == .secondaryLabelColor)

        // The dropdown greys the cached rows and drops their elapsed time.
        let row = MenuJobSummary(job: runningJob("1", elapsed: "9:29:15"), isLive: false)
        #expect(row.timing == "Running")
        #expect(row.color == .secondary)
        #expect(aire.asOfText?.hasPrefix("as of ") == true)
    }

    @Test("The startup probe reads Checking, never Not connected")
    func checking() {
        let digest = MenuBarDigest(clusters: [
            cluster(.aire, .checking, jobs: [runningJob("1")]),
            cluster(.calder, .off(hasCache: false), hasSnapshot: false)
        ])
        #expect(StatusBarSummary(digest: digest).title == "Checking")
        #expect(digest.health == .connecting)
        #expect(digest.headerStatusLine == "AIRE checking")
    }

    @Test("Signed in but no snapshot yet: the header says the data is still coming")
    func collecting() {
        let digest = MenuBarDigest(clusters: [
            cluster(.aire, .live, nodes: [mixedL40SNode]),
            cluster(.calder, .loadingFirstSnapshot, hasSnapshot: false)
        ])
        #expect(digest.headerStatusLine == "AIRE live · Calder collecting first snapshot")
        #expect(digest.health == .partial)
    }

    @Test("A cluster that is off contributes no snapshot data")
    func offContributesNothing() {
        let home = StorageSummary(label: "home", usedPercent: 50)
        let off = cluster(.calder, .off(hasCache: true), jobs: [runningJob("1")], storage: [home])
        #expect(!off.hasSnapshot)
        #expect(off.jobs.isEmpty)
        #expect(MenuBarDigest(clusters: [off]).sharedHome == nil)
        #expect(MenuBarDigest(clusters: [off]).health == .off)
    }

    @Test("The shared home is listed once, never per cluster")
    func sharedHome() {
        let storage = [StorageSummary(label: "home", usedPercent: 69), StorageSummary(label: "scratch", usedPercent: 40)]
        let digest = MenuBarDigest(clusters: [
            cluster(.aire, .live, storage: storage),
            cluster(.calder, .live, storage: storage)
        ])
        #expect(digest.sharedHome != nil)
        #expect(digest.clusters.allSatisfy { $0.storage.map(\.kind) == [.scratch] })
    }

    @Test("Refresh all is offered only when some cluster allows a refresh")
    func refreshGate() {
        let never = MenuBarClusterDigest(profile: .aire, status: status(.notConnected, action: .connect), snapshot: nil)
        #expect(!MenuBarDigest(clusters: [never]).canRefreshAny)
        let live = MenuBarClusterDigest(profile: .aire, status: status(.live, allowsRefresh: true), snapshot: nil)
        #expect(MenuBarDigest(clusters: [never, live]).canRefreshAny)
    }

    @Test("While Slurm is failing, the carried-forward job list never reads as live")
    func slurmOutage() {
        let issue = "Slurm error on Calder: Section 'jobs' failed with exit 1"
        let calder = MenuBarClusterDigest(
            profile: .calder,
            status: status(.live, allowsRefresh: true),
            schedulerIssue: issue,
            snapshot: ClusterSnapshot(collectedAt: collectedAt, jobs: [runningJob("38961_1", elapsed: "1:23:00")], nodes: calderNodes())
        )
        #expect(calder.isDegraded)
        #expect(!calder.hasCurrentFigures)
        #expect(calder.asOfText == nil)     // "as of <fresh time>" would vouch for it too

        let digest = MenuBarDigest(clusters: [calder])
        #expect(digest.live.isEmpty)
        #expect(digest.runningCount == 0)
        #expect(digest.primaryRunningJob == nil)
        #expect(digest.health == .partial)
        #expect(digest.headerStatusLine == "Calder Slurm not answering")
        let summary = StatusBarSummary(digest: digest)
        #expect(summary.title == "Slurm error")
        #expect(summary.tint == .systemOrange)
        #expect(summary.tooltip.contains("Slurm is not answering"))
        #expect(summary.tooltip.contains("1 running · 0 pending (not current)"))

        // AIRE still live and healthy: its job names the item; Calder's does not.
        let aire = cluster(.aire, .live, jobs: [runningJob("8248307_0", start: "2026-10-13T11:00:00")])
        let both = MenuBarDigest(clusters: [aire, calder])
        #expect(both.runningCount == 1)
        #expect(both.primaryRunningJob?.cluster.id == .aire)
        #expect(both.health == .partial)
        #expect(both.headerStatusLine == "AIRE live · Calder Slurm not answering")

        // The issue only counts while live; a cleared one restores everything.
        let recovered = MenuBarClusterDigest(profile: .calder, status: status(.live), snapshot: ClusterSnapshot(collectedAt: collectedAt))
        #expect(recovered.hasCurrentFigures)
        #expect(MenuBarDigest(clusters: [recovered]).health == .allLive)
        let stale = MenuBarClusterDigest(profile: .calder, status: status(.stale), schedulerIssue: issue, snapshot: nil)
        #expect(stale.schedulerIssue == nil)
    }
}

// MARK: - Jobs

@Suite("Menu bar jobs")
struct MenuBarJobTests {
    @Test("One display order; queued array tasks counted; suspended kept apart; finished dropped")
    func jobCounting() {
        let remainder = Job(
            jobId: "8248307", partition: "gpu", name: "c3-d1a-pack", state: "PENDING",
            reasonOrNodeList: "JobArrayTaskLimit",
            arrayJobID: 8248307, arrayPendingTasks: "2-5", arrayThrottle: 4, pendingTaskCount: 4
        )
        let jobs = [
            pendingJob("100", reason: "(Dependency)"),
            pendingJob("101"),
            Job(jobId: "99", state: "COMPLETED"),
            Job(jobId: "103", name: "paused", state: "SUSPENDED"),
            remainder,
            runningJob("102")
        ]
        let digest = cluster(.aire, .live, jobs: jobs)
        #expect(digest.jobs.first?.jobId == "102")
        #expect(!digest.jobs.contains { $0.jobId == "99" })
        #expect(digest.runningJobs.map(\.jobId) == ["102"])
        #expect(digest.pendingTaskCount == 6)
        #expect(digest.otherJobCount == 1)
        #expect(digest.jobCountsText == "1 running · 6 pending · 1 suspended")

        let row = MenuJobSummary(job: remainder, isLive: true)
        #expect(row.detail.hasPrefix("8248307_[2-5] (4 tasks) · gpu · reason JobArrayTaskLimit"))
        #expect(row.timing == "Pending")
    }

    @Test("Held jobs are never counted as pending: Calder's live queue reads '9 running · 1 pending · 11 held'")
    func heldApartFromPending() {
        // The live Calder snapshot: 9 running, 11 held by the user, one
        // waiting for its begin time.
        let held = (1...11).map { pendingJob("667\($0 + 10)", reason: "(JobHeldUser)") }
        let running = (1...9).map { runningJob("669\($0 + 10)") }
        let digest = cluster(.calder, .live, jobs: held + running + [pendingJob("66927", reason: "(BeginTime)")])
        #expect(digest.pendingTaskCount == 1)
        #expect(digest.heldTaskCount == 11)
        #expect(digest.showsPendingCount)
        #expect(digest.jobCountsText == "9 running · 1 pending · 11 held")
        // The same wording as the overview and the sidebar.
        #expect(digest.jobCountsText == JobQueueCounts(jobs: digest.jobs).summary)
        // Held rows still sort last and stay in the job list.
        #expect(digest.pendingJobs.count == 12)
        #expect(digest.jobs.last?.reasonOrNodeList == "(JobHeldUser)")

        // Nothing pending beside held jobs: no "0 pending".
        let onlyHeld = cluster(.calder, .live, jobs: Array(held.prefix(2)) + [runningJob("1")])
        #expect(!onlyHeld.showsPendingCount)
        #expect(onlyHeld.jobCountsText == "1 running · 2 held")
        // An empty queue still says "0 pending".
        let idle = cluster(.calder, .live, jobs: [runningJob("1")])
        #expect(idle.showsPendingCount)
        #expect(idle.jobCountsText == "1 running · 0 pending")
    }

    @Test("The '+N more' line counts jobs, so it adds up with the count line above it")
    func hiddenJobsLine() {
        // AIRE live: 3 running, then 16 queued rows of which four array
        // remainders stand for 6, 16, 1 and 2 tasks — 40 jobs in 19 rows.
        func remainder(_ id: String, tasks: Int) -> Job {
            Job(
                jobId: id, partition: "gpu", name: "c2-trackm", state: "PENDING", reasonOrNodeList: "(Priority)",
                arrayJobID: Int(id), arrayPendingTasks: "0-\(tasks - 1)", pendingTaskCount: tasks
            )
        }
        let running = ["8254575", "8254595", "8254596"].map { runningJob($0) }
        let arrays = [remainder("8254562", tasks: 6), remainder("8254563", tasks: 16), remainder("8254641", tasks: 1), remainder("8254642", tasks: 2)]
        let singles = (1...12).map { pendingJob("82547\($0 + 10)") }
        let aire = cluster(.aire, .live, jobs: running + arrays + singles)
        #expect(aire.jobs.count == 19)
        #expect(aire.jobCountsText == "3 running · 37 pending")
        #expect(aire.hiddenJobsText(afterFirst: 3) == "+37 more jobs in 16 rows on AIRE")
        #expect(aire.hiddenJobsText(afterFirst: 3, compact: true) == "+37 more jobs in 16 rows")

        // Without arrays rows and jobs agree, and the line stays short.
        let calder = cluster(.calder, .live, jobs: running + singles)
        #expect(calder.hiddenJobsText(afterFirst: 3) == "+12 more on Calder")
        #expect(calder.hiddenJobsText(afterFirst: 15) == nil)
        #expect(cluster(.calder, .live, jobs: [runningJob("1")]).hiddenJobsText(afterFirst: 0) == "+1 more on Calder")
    }

    @Test("A live running row shows elapsed and limit")
    func liveRow() {
        let row = MenuJobSummary(job: runningJob("1", elapsed: "1:22:16"), isLive: true)
        #expect(row.timing == "1:22:16 / 4:00:00")
        #expect(row.iconName == "play.fill")
    }
}

// MARK: - GPU pools

@MainActor
@Suite("Menu bar GPU pools")
struct MenuBarGPUPoolTests {
    @Test("Calder's models stay separate pools, largest first")
    func perModel() throws {
        let digest = cluster(.calder, .live, nodes: calderNodes())
        #expect(digest.gpuPools.map(\.title) == ["H200 GPUs", "L40 GPUs"])
        let h200 = try #require(digest.gpuPools.first)
        #expect(h200.valueText == "1 of 16 idle")
        #expect(h200.detailText == "15 in use")
        #expect(h200.tone == .normal)
        let l40 = try #require(digest.gpuPools.last)
        #expect(l40.valueText == "0 of 3 idle")
        #expect(l40.detailText == "all 3 unavailable")
        #expect(l40.summaryLine == "L40: 0 of 3 idle · all 3 unavailable")
        #expect(l40.tone == .unavailable)
    }

    @Test("An idle GPU on a node with every CPU taken is stranded, not idle")
    func stranded() throws {
        let pool = try #require(cluster(.aire, .live, nodes: [strandedNode]).gpuPools.first)
        #expect(pool.pool.idle == 0)
        #expect(pool.pool.stranded == 1)
        #expect(pool.valueText == "0 of 3 idle")
        #expect(pool.detailText == "2 in use · 1 stranded")
        // Known full: a warning, never red (red is for faults).
        #expect(pool.tone == .warning)
        #expect(pool.summaryLine == "L40S: 0 of 3 idle · 2 in use · 1 stranded")
        #expect(pool.helpText(clusterName: "AIRE").contains("1 idle on nodes whose CPUs are all taken"))

        let both = try #require(cluster(.aire, .live, nodes: [strandedNode, mixedL40SNode]).gpuPools.first)
        #expect(both.valueText == "2 of 6 idle")
        #expect(both.detailText == "3 in use · 1 stranded")
    }

    @Test("Calder's live H200 pool: the row names the stranded and unavailable GPUs, in the overview's orange")
    func liveH200Breakdown() throws {
        // calder-h200-04 has every CPU taken with 7 GPUs free (stranded);
        // h200-05 is drained and h200-07 draining with 15 GPUs free
        // between them (unavailable). 34 of 56 allocated, none idle.
        func h200(_ index: Int, state: String, cpuIdle: Int, allocated: Int) -> NodeSummary {
            NodeSummary(
                node: "calder-h200-0\(index)", partitions: ["calder-gpu-hopper"], state: state,
                cpuAllocated: 128 - cpuIdle, cpuIdle: cpuIdle, cpuTotal: 128,
                gres: "gpu:nvidia_h200:8(S:0-1)", gpuTotal: 8, gpuAllocated: allocated, gpuIdle: 8 - allocated
            )
        }
        let nodes = [
            h200(1, state: "alloc", cpuIdle: 0, allocated: 8),
            h200(2, state: "alloc", cpuIdle: 0, allocated: 8),
            h200(3, state: "alloc", cpuIdle: 0, allocated: 8),
            h200(4, state: "alloc", cpuIdle: 0, allocated: 1),
            h200(5, state: "drain", cpuIdle: 128, allocated: 0),
            h200(6, state: "alloc", cpuIdle: 0, allocated: 8),
            h200(7, state: "drng", cpuIdle: 64, allocated: 1)
        ]
        let pool = try #require(cluster(.calder, .live, nodes: nodes).gpuPools.first)
        #expect(pool.valueText == "0 of 56 idle")
        #expect(pool.detailText == "34 in use · 7 stranded · 15 unavailable")
        #expect(pool.tone == .warning)
        // The overview tile and header chip colour the same pool orange.
        #expect(pool.tone.color == pool.pool.idleTint)
        #expect(pool.spokenValueText == "0 of 56 idle; 34 in use · 7 stranded · 15 unavailable")
    }

    @Test("Idle-GPU title: the primary pool per live cluster, '+' when another model has idle GPUs")
    func idleTitle() {
        let aire = cluster(.aire, .live, nodes: [mixedL40SNode, strandedNode])
        let calder = cluster(.calder, .live, nodes: calderNodes(l40State: "idle"))
        let summary = StatusBarSummary(digest: MenuBarDigest(clusters: [aire, calder]))
        #expect(summary.title == "A 2 · C 1+")
        #expect(summary.widthTemplateTitle == "A 88 · C 88+")
        #expect(summary.accessibilityLabel.contains("Calder 1 idle H200 GPUs and 3 idle L40 GPUs"))

        let drained = StatusBarSummary(digest: MenuBarDigest(clusters: [cluster(.calder, .live, nodes: calderNodes())]))
        #expect(drained.title == "C 1")
    }
}

// MARK: - Unknown GPU allocation

/// The most-glanced surfaces (status item, dropdown row, sidebar row) say
/// "?" for a pool whose allocation is unknown, as the overview tile and
/// the header chip do — never a definite "0 idle" (a full pool) or "0 in
/// use" (an empty meter) for GPUs nobody reported on.
@MainActor
@Suite("Unknown GPU allocation at a glance")
struct UnknownGPUAllocationGlanceTests {
    @Test("Node details missing: the status item reads 'A ?', never 'A 0'")
    func statusItemTitle() {
        let aire = cluster(.aire, .live, nodes: unknownL40SNodes(3))
        let summary = StatusBarSummary(digest: MenuBarDigest(clusters: [aire]))
        #expect(summary.title == "A ?")
        #expect(summary.widthTemplateTitle == "A 88")
        #expect(summary.accessibilityLabel == "Idle GPUs: AIRE idle L40S GPUs unknown")
        #expect(!summary.accessibilityLabel.contains("0 idle"))
        #expect(summary.tooltip.contains("L40S: ? of 9 idle · 9 unknown"))

        // "+" still means another model has idle GPUs: an unknown pool
        // never earns it, and an unknown primary keeps it for a known one.
        let unknownPrimary = cluster(.calder, .live, nodes: [
            unknownH200Node("calder-h200-01"), unknownH200Node("calder-h200-02"), calderNodes(l40State: "idle")[2]
        ])
        #expect(StatusBarSummary(digest: MenuBarDigest(clusters: [unknownPrimary])).title == "C ?+")
        let unknownOther = cluster(.calder, .live, nodes: Array(calderNodes().prefix(2)) + unknownL40SNodes(1))
        #expect(StatusBarSummary(digest: MenuBarDigest(clusters: [unknownOther])).title == "C 1")
    }

    @Test("Dropdown row: '?' and the unknown count, no '0 idle' or '0 in use'")
    func dropdownRow() throws {
        let pool = try #require(cluster(.aire, .live, nodes: unknownL40SNodes(3)).gpuPools.first)
        #expect(pool.pool.idleIsUnknown)
        #expect(pool.valueText == "? of 9 idle")
        #expect(pool.detailText == "9 unknown")
        #expect(!pool.summaryLine.contains("0 idle"))
        #expect(!pool.summaryLine.contains("in use"))
        #expect(pool.tone == .unavailable)
        #expect(pool.summaryLine == "L40S: ? of 9 idle · 9 unknown")
        #expect(pool.spokenValueText == "idle L40S GPUs unknown: allocation unknown for 9 of 9; 9 unknown")
        let help = pool.helpText(clusterName: "AIRE")
        #expect(help.hasPrefix("AIRE L40S GPUs: idle GPUs unknown"))
        #expect(!help.contains("0 idle"))
    }

    @Test("Partly unknown: the known idle count stands and is green — a job can start on it")
    func partlyUnknown() throws {
        // 1 allocated and 2 idle known, 3 unknown.
        let narrow = try #require(cluster(.aire, .live, nodes: [mixedL40SNode] + unknownL40SNodes(1)).gpuPools.first)
        #expect(!narrow.pool.idleIsUnknown)
        #expect(narrow.valueText == "2 of 6 idle")
        #expect(narrow.detailText == "1 in use · 3 unknown")
        #expect(narrow.summaryLine == "L40S: 2 of 6 idle · 1 in use · 3 unknown")
        #expect(narrow.spokenValueText == "2 of 6 idle; 1 in use · 3 unknown")
        #expect(narrow.tone == .normal)

        // 9 of 12 unknown: still two GPUs known startable, so still green
        // (the one idle-tone rule: some idle is good, whatever is unknown).
        let wide = try #require(cluster(.aire, .live, nodes: [mixedL40SNode] + unknownL40SNodes(3)).gpuPools.first)
        #expect(wide.tone == .normal)
        #expect(wide.tone == wide.pool.idleTone)
    }

    @Test("Sidebar row: '? of 9 L40S idle', never '0 of 9 L40S idle'")
    func sidebarRow() {
        #expect(GPUFleet(nodes: unknownL40SNodes(3)).primaryIdleText == "? of 9 L40S idle")
        // A pool known to be full still reads 0; other pools are counted.
        #expect(GPUFleet(nodes: [strandedNode]).primaryIdleText == "0 of 3 L40S idle")
        #expect(GPUFleet(nodes: calderNodes()).primaryIdleText == "1 of 16 H200 idle · +1 more model")
        #expect(GPUFleet(nodes: []).primaryIdleText == nil)
        let summary = ClusterSidebarSummary(jobs: [], fleet: GPUFleet(nodes: unknownL40SNodes(3)))
        #expect(!summary.spoken.contains("?"))
    }
}

// MARK: - Status item title

@MainActor
@Suite("Status item title")
struct StatusItemTitleTests {
    @Test("A long name and a day-long elapsed still fit; the elapsed time is never cut")
    func fitsCap() {
        let job = runningJob("9926", name: "c2-mirrorsynth-gov", elapsed: "1-02:03:04")
        let summary = StatusBarSummary(digest: MenuBarDigest(clusters: [cluster(.calder, .live, jobs: [job])]))
        #expect(summary.title.hasPrefix("C · "))
        #expect(summary.title.hasSuffix(" 1d 02h"))
        #expect(summary.title.contains("…"))
        let needed = StatusItemLayout.iconWidth + StatusItemLayout.textWidth(summary.widthTemplateTitle) + StatusItemLayout.padding
        #expect(needed <= StatusItemLayout.maxLength)
        #expect(StatusItemLayout.textWidth(summary.title) <= StatusItemLayout.maxTextWidth)
        #expect(summary.reservedLength(hasIcon: true) <= StatusItemLayout.maxLength)
    }

    @Test("A short name is kept whole")
    func shortName() {
        let job = runningJob("1", name: "train", elapsed: "9:29:15")
        let summary = StatusBarSummary(digest: MenuBarDigest(clusters: [cluster(.aire, .live, jobs: [job])]))
        #expect(summary.title == "A · train 9h 29m")
        #expect(summary.widthTemplateTitle == "A · train 8h 88m")
        #expect(summary.accessibilityLabel == "train running on AIRE for 9 h 29 min")
    }

    @Test("Several live jobs: a count, broken down per cluster in the tooltip")
    func multiple() {
        let digest = MenuBarDigest(clusters: [
            cluster(.aire, .live, jobs: [runningJob("1")]),
            cluster(.calder, .live, jobs: [runningJob("2"), runningJob("3")])
        ])
        let summary = StatusBarSummary(digest: digest)
        #expect(summary.title == "3 jobs")
        #expect(summary.tooltip.hasPrefix("3 running jobs — AIRE 1, Calder 2"))
    }

    @Test("Middle truncation keeps both ends")
    func middleTruncation() {
        let measure: StatusBarSummary.Measure = { CGFloat($0.count * 10) }
        #expect(StatusBarSummary.middleTruncated("abcdefghij", toFit: 60, measure: measure) == "abc…ij")
        #expect(StatusBarSummary.middleTruncated("abc", toFit: 60, measure: measure) == "abc")
        #expect(StatusBarSummary.middleTruncated("abcdef", toFit: 10, measure: measure) == "")
    }

    @Test("Compact elapsed", arguments: [
        ("0:45", "45s" as String?),
        ("12:03", "12m"),
        ("9:29:15", "9h 29m"),
        ("1-02:03:04", "1d 02h"),
        ("", nil),
        ("INVALID", "INVALID")
    ])
    func compactElapsed(raw: String, expected: String?) {
        #expect(StatusElapsedText.compact(raw) == expected)
    }
}

// MARK: - Storage rows

@Suite("Menu bar storage rows")
struct MenuBarStorageRowTests {
    @Test("File-count pressure dominates and keeps a short fallback")
    func filePressure() {
        let row = MenuBarStorageRow(storage: StorageSummary(label: "flash", availableGB: 2457.6, usedPercent: 40, fileCount: 98, fileLimit: 100))
        #expect(row.percentLabel == "98% files")
        #expect(row.valueLabel == "98% files · \(formatGB(2457.6)) free")
        #expect(row.tone == .critical)
    }

    @Test("Shared 75/90 thresholds", arguments: [
        (50.0, StatusTone.normal),
        (80.0, .warning),
        (95.0, .critical)
    ])
    func thresholds(percent: Double, tone: StatusTone) {
        #expect(MenuBarStorageRow(storage: StorageSummary(label: "scratch", usedPercent: percent)).tone == tone)
    }

    @Test("Over quota and unreadable spaces")
    func edgeCases() {
        let over = MenuBarStorageRow(storage: StorageSummary(label: "scratch", usedPercent: 60, overQuota: true))
        #expect(over.percentLabel == "over quota")
        #expect(over.tone == .critical)

        let missing = MenuBarStorageRow(storage: StorageSummary(label: "flash", path: "/flash/x", unavailableReason: "missing"))
        #expect(missing.percentLabel == "n/a")
        #expect(missing.tone == .unavailable)
        #expect(missing.detail.hasPrefix("Not readable"))
        #expect(missing.pressureText == nil)
    }

    /// The menu and the Storage tab must never disagree about how full a
    /// space is: the row takes `StorageSummary.usageTone` (75/90 on the
    /// larger of space and files, over quota critical) rather than a copy
    /// of the rule.
    @Test("Storage tones agree with the Storage tab", arguments: CoreFixtures.aireStorage + CoreFixtures.calderStorage + [
        StorageSummary(label: "Flash", usedPercent: 40, fileCount: 950, fileLimit: 1000),
        StorageSummary(label: "Scratch", usedPercent: 20, overQuota: true),
        StorageSummary(label: "Home", source: "unavailable", unavailableReason: "missing"),
        StorageSummary(label: "Flash", usedPercent: 74.9, fileCount: 760, fileQuota: 1000),
        StorageSummary(label: "Scratch", usedPercent: 112)
    ])
    func storageTonesAgree(row: StorageSummary) {
        let menuRow = MenuBarStorageRow(storage: row)
        #expect(menuRow.tone == row.usageTone)
        #expect(menuRow.riskFraction == row.pressurePercent.map { min(max($0 / 100, 0), 1) })
    }

    @Test("The fixtures' fullest spaces read as the Storage tab reads them")
    func fixtureTones() {
        let calder = CoreFixtures.calderStorage.map(MenuBarStorageRow.init(storage:))
        #expect(calder.map(\.tone) == [.normal, .critical, .normal])
        #expect(calder[1].percentLabel == "91%")
        let aireScratch = MenuBarStorageRow(storage: CoreFixtures.aireStorage[1])
        #expect(aireScratch.tone == .warning)
        #expect(aireScratch.valueLabel == "88% · \(formatGB(492.2)) free")
    }
}

// MARK: - Times

@Suite("Menu bar times")
struct MenuBarTimeTests {
    /// Slurm prints start times without a zone, in the clusters' own zone
    /// (Europe/London). The menu must read them there, whatever zone the
    /// Mac is in, or a travelling user's newest job and ages are hours off.
    @Test("Zone-less Slurm start times are read in the clusters' zone")
    func slurmStartZone() throws {
        let digest = cluster(.aire, .live, jobs: [runningJob("1", start: "2026-10-13T11:41:38")])
        let start = try #require(digest.newestRunningJob?.start)
        var components = DateComponents()
        components.timeZone = TimeZone(identifier: "Europe/London")
        components.year = 2026
        components.month = 10
        components.day = 13
        components.hour = 11
        components.minute = 41
        components.second = 38
        let expected = try #require(Calendar(identifier: .gregorian).date(from: components))
        #expect(start == expected)
        // 11:41:38 BST is 10:41:38 UTC.
        #expect(start == Date(timeIntervalSince1970: 1_791_888_098))
    }

    @Test("The collection time keeps its own offset")
    func collectedAtOffset() throws {
        let digest = cluster(.calder, .live)
        let collected = try #require(digest.collectedAt)
        #expect(collected == SlurmTimestamp.parse(collectedAt))
        #expect(abs(collected.timeIntervalSince1970 - 1_791_893_034.592) < 0.01)
    }

    @Test("The newest running job is the latest start, then the highest id")
    func newestRunning() {
        let digest = cluster(.aire, .live, jobs: [
            runningJob("10", start: "2026-10-13T09:00:00"),
            runningJob("9", start: "2026-10-13T11:00:00"),
            runningJob("11", start: nil)
        ])
        #expect(digest.newestRunningJob?.job.jobId == "9")
    }
}

// MARK: - Store

@MainActor
@Suite("Menu bar digest store")
struct MenuBarDigestStoreTests {
    @Test("An unchanged digest is not republished")
    func deduplicates() {
        let digest = MenuBarDigest(clusters: [cluster(.aire, .live, jobs: [runningJob("1")])])
        let store = MenuBarDigestStore(digest: digest)
        var publishes = 0
        let subscription = store.objectWillChange.sink { publishes += 1 }
        store.update(MenuBarDigest(clusters: [cluster(.aire, .live, jobs: [runningJob("1")])]))
        #expect(publishes == 0)
        store.update(MenuBarDigest(clusters: [cluster(.aire, .live, jobs: [runningJob("1"), runningJob("2")])]))
        #expect(publishes == 1)
        subscription.cancel()
    }
}
