import HPCCore
import AppKit
import Combine
import Foundation
import Testing
@testable import AIREMonitorApp

// Menu bar: which clusters feed the status item, how jobs, array tasks and
// GPU pools are counted and worded, and the title's modes and width
// classes. The menu's rows are in MenuBarMenuLayoutTests.swift.

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
        #expect(summary.title == "1 running")
        #expect(summary.widthClass == .running(digits: 2))
        // Calder's cached figures are named with their time instead.
        #expect(summary.tooltip.contains("17 running · 0 pending (as of "))
        #expect(digest.health == .partial)
    }

    @Test("Only cached data: the glyph dims, no title, and no frozen elapsed time anywhere")
    func onlyCached() {
        let aire = cluster(.aire, .stale, jobs: [runningJob("1"), runningJob("2")], nodes: [mixedL40SNode])
        let calder = cluster(.calder, .notConnected, hasSnapshot: false)
        let digest = MenuBarDigest(clusters: [aire, calder])
        let summary = StatusBarSummary(digest: digest)
        #expect(digest.runningCount == 0)
        #expect(summary.title == "")
        #expect(summary.widthClass == .glyph)
        #expect(summary.isDimmed)
        #expect(!summary.hasAttention)
        #expect(digest.health == .stale)

        // The menu's cached rows show the state, not an elapsed time.
        let row = MenuJobLine(job: runningJob("1", elapsed: "9:29:15"), usage: nil, isLive: false, clash: false)
        #expect(row.trailing == "Running")
        #expect(aire.asOfText?.hasPrefix("as of ") == true)
    }

    @Test("The startup probe reads Checking, never Not connected")
    func checking() {
        let digest = MenuBarDigest(clusters: [
            cluster(.aire, .checking, jobs: [runningJob("1")]),
            cluster(.calder, .off(hasCache: false), hasSnapshot: false)
        ])
        let summary = StatusBarSummary(digest: digest)
        #expect(summary.title == "")
        #expect(summary.isDimmed)
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
        #expect(summary.title == "")
        #expect(summary.isDimmed)
        #expect(summary.hasAttention)
        #expect(digest.attention.map(\.kind) == [.slurmDown])
        #expect(summary.tooltip.contains("Needs a look: Calder: Slurm not answering"))
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

        let row = MenuJobLine(job: remainder, usage: nil, isLive: true, clash: false)
        #expect(row.title == "c3-d1a-pack (4 tasks)")
        #expect(row.toolTip.hasPrefix("8248307_[2-5] (4 tasks) · gpu · reason JobArrayTaskLimit"))
        #expect(row.trailing == "JobArrayTaskLimit")
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

    @Test("A live running row shows elapsed and limit compactly; the seconds go to the tooltip")
    func liveRow() {
        let row = MenuJobLine(job: runningJob("1", elapsed: "1:22:16"), usage: nil, isLive: true, clash: false)
        #expect(row.title == "train")
        #expect(row.trailing == "1h 22m of 4h")
        #expect(!row.flagged)
        #expect(row.toolTip.hasPrefix("1 · gpu · gpu003 — 1:22:16 of 4:00:00"))
        let clash = MenuJobLine(job: runningJob("8248307_0", name: "train-resnet50"), usage: nil, isLive: true, clash: true)
        #expect(clash.title == "train-resnet50 · 8248307_0")
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
        let summary = StatusBarSummary(digest: MenuBarDigest(clusters: [aire, calder]), mode: .idleGPUs)
        #expect(summary.title == "A 2 · C 1+")
        #expect(summary.widthClass == .gpus(template: "A 88 · C 88+"))
        #expect(summary.accessibilityLabel.contains("Calder 1 idle H200 GPUs and 3 idle L40 GPUs"))
        #expect(summary.tooltip.hasPrefix("Idle GPUs — AIRE 2 of 6 L40S; Calder 1 of 16 H200, 3 of 3 L40"))
        // The default mode never shows GPUs: nothing runs, so the glyph only.
        #expect(StatusBarSummary(digest: MenuBarDigest(clusters: [aire, calder])).title == "")

        let drained = StatusBarSummary(digest: MenuBarDigest(clusters: [cluster(.calder, .live, nodes: calderNodes())]), mode: .idleGPUs)
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
        let summary = StatusBarSummary(digest: MenuBarDigest(clusters: [aire]), mode: .idleGPUs)
        #expect(summary.title == "A ?")
        #expect(summary.widthClass == .gpus(template: "A 88"))
        #expect(summary.accessibilityLabel == "Leeds HPC Monitor: idle GPUs: AIRE idle L40S GPUs unknown")
        #expect(!summary.accessibilityLabel.contains("0 idle"))
        #expect(summary.tooltip.contains("L40S: ? of 9 idle · 9 unknown"))

        // "+" still means another model has idle GPUs: an unknown pool
        // never earns it, and an unknown primary keeps it for a known one.
        let unknownPrimary = cluster(.calder, .live, nodes: [
            unknownH200Node("calder-h200-01"), unknownH200Node("calder-h200-02"), calderNodes(l40State: "idle")[2]
        ])
        #expect(StatusBarSummary(digest: MenuBarDigest(clusters: [unknownPrimary]), mode: .idleGPUs).title == "C ?+")
        let unknownOther = cluster(.calder, .live, nodes: Array(calderNodes().prefix(2)) + unknownL40SNodes(1))
        #expect(StatusBarSummary(digest: MenuBarDigest(clusters: [unknownOther]), mode: .idleGPUs).title == "C 1")
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
    private func digest(running: Int) -> MenuBarDigest {
        MenuBarDigest(clusters: [cluster(.aire, .live, jobs: (0..<running).map { runningJob("\($0)") })])
    }

    @Test("The title is the live running count; the width holds from 1 to 99 and across ticks")
    func runningCount() {
        let widths = [1, 9, 10, 99].map { StatusBarSummary(digest: digest(running: $0)).reservedLength() }
        #expect(Set(widths).count == 1)
        #expect(widths[0] <= StatusItemLayout.maxRunningLength)
        #expect(StatusBarSummary(digest: digest(running: 7)).title == "7 running")
        // Elapsed times change on every refresh; the item never does.
        let early = MenuBarDigest(clusters: [cluster(.aire, .live, jobs: [runningJob("1", elapsed: "0:05:00")])])
        let late = MenuBarDigest(clusters: [cluster(.aire, .live, jobs: [runningJob("1", elapsed: "9:29:15")])])
        #expect(StatusBarSummary(digest: early).title == StatusBarSummary(digest: late).title)
        #expect(StatusBarSummary(digest: early).reservedLength() == StatusBarSummary(digest: late).reservedLength())
        #expect(StatusBarSummary(digest: digest(running: 100)).widthClass == .running(digits: 3))
        // The drawn title fills its slot exactly, so the centred glyph
        // never moves between 9 and 10 running.
        let drawn = [1, 9, 10, 99].map { StatusItemLayout.textWidth(StatusBarSummary(digest: digest(running: $0)).displayTitle) }
        #expect(Set(drawn).count == 1)
        #expect(drawn[0] == StatusItemLayout.textWidth("88 running"))
    }

    @Test("Idle GPUs: a second pool's idle count crossing zero never resizes or shifts the item")
    func gpuWidthStable() {
        func calder(_ l40State: String) -> MenuBarDigest {
            MenuBarDigest(clusters: [cluster(.calder, .live, nodes: calderNodes(l40State: l40State))])
        }
        let none = StatusBarSummary(digest: calder("drain*"), mode: .idleGPUs)
        let some = StatusBarSummary(digest: calder("idle"), mode: .idleGPUs)
        #expect(none.title == "C 1")
        #expect(some.title == "C 1+")
        #expect(none.widthClass == some.widthClass)
        #expect(none.reservedLength() == some.reservedLength())
        #expect(StatusItemLayout.textWidth(none.displayTitle) == StatusItemLayout.textWidth(some.displayTitle))
    }

    @Test("Nothing running, or Icon Only: the glyph alone at the system's square length")
    func glyphOnly() {
        let idle = StatusBarSummary(digest: digest(running: 0))
        #expect(idle.title == "")
        #expect(idle.reservedLength() == NSStatusItem.squareLength)
        #expect(!idle.isDimmed)
        let iconOnly = StatusBarSummary(digest: digest(running: 3), mode: .iconOnly)
        #expect(iconOnly.title == "")
        #expect(iconOnly.reservedLength() == NSStatusItem.squareLength)
    }

    @Test("No state word is ever a title, in any phase")
    func noStateWords() {
        let phases: [ClusterPresentation.Phase] = [.notConnected, .checking, .queued, .signingIn, .loadingFirstSnapshot, .paused, .stale, .off(hasCache: false)]
        for phase in phases {
            for mode in StatusTitleMode.allCases {
                let summary = StatusBarSummary(digest: MenuBarDigest(clusters: [cluster(.aire, phase, jobs: [runningJob("1")])]), mode: mode)
                #expect(summary.title == "", "\(phase) in \(mode)")
                #expect(summary.isDimmed, "\(phase)")
            }
        }
    }

    @Test("Several live jobs: one count, broken down per cluster in the tooltip and for VoiceOver")
    func multiple() {
        let digest = MenuBarDigest(clusters: [
            cluster(.aire, .live, jobs: [runningJob("1")]),
            cluster(.calder, .live, jobs: [runningJob("2"), runningJob("3")])
        ])
        let summary = StatusBarSummary(digest: digest)
        #expect(summary.title == "3 running")
        #expect(summary.tooltip.hasPrefix("3 jobs running — AIRE 1, Calder 2"))
        #expect(summary.accessibilityLabel == "Leeds HPC Monitor: 3 jobs running, AIRE 1, Calder 2")
    }

    @Test("Middle truncation keeps both ends")
    func middleTruncation() {
        let measure: (String) -> CGFloat = { CGFloat($0.count * 10) }
        #expect(TextFitting.middleTruncated("abcdefghij", toFit: 60, measure: measure) == "abc…ij")
        #expect(TextFitting.middleTruncated("abc", toFit: 60, measure: measure) == "abc")
        #expect(TextFitting.middleTruncated("abcdef", toFit: 10, measure: measure) == "")
    }

    @Test("Compact limits", arguments: [
        ("4:00:00", "4h" as String?),
        ("12:00:00", "12h"),
        ("2-00:00:00", "2d"),
        ("1-12:00:00", "1d 12h"),
        ("30:00", "30m"),
        ("1:30:00", "1h 30m"),
        ("UNLIMITED", nil),
        ("", nil)
    ])
    func compactLimit(raw: String, expected: String?) {
        #expect(StatusElapsedText.compactLimit(raw) == expected)
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
