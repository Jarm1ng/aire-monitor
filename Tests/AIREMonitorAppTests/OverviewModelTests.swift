import HPCCore
import Foundation
import Testing
@testable import AIREMonitorApp

// The overview's derived data (OverviewModel.swift), the shared queue and
// GPU wording it is built on (HPCCore/OverviewSummaries.swift), and the
// state pill wording (Components.swift). All pure: no sessions, no views.

// MARK: - Fixtures

private func job(
    _ id: String,
    state: String,
    partition: String = "gpu",
    reason: String = "",
    elapsed: String = "0:00",
    timeLimit: String = "2-00:00:00",
    nodes: String = "1",
    submitTime: String? = nil,
    arrayJobID: Int? = nil,
    arrayPendingTasks: String? = nil,
    pendingTaskCount: Int? = nil
) -> Job {
    Job(
        jobId: id,
        partition: partition,
        name: "job-\(id)",
        user: testUsername,
        state: state,
        elapsed: elapsed,
        timeLimit: timeLimit,
        nodes: nodes,
        reasonOrNodeList: reason,
        submitTime: submitTime,
        arrayJobID: arrayJobID,
        arrayPendingTasks: arrayPendingTasks,
        pendingTaskCount: pendingTaskCount
    )
}

/// The live AIRE node from the audit: every CPU allocated, one GPU idle.
/// No job can start there, so its idle GPU is stranded, not free.
private let gpu018 = NodeSummary(
    node: "gpu018",
    partitions: ["gpu"],
    state: "alloc",
    cpuAllocated: 24,
    cpuIdle: 0,
    cpuOther: 0,
    cpuTotal: 24,
    gres: "gpu:l40s:3(S:0-1)",
    gpuTotal: 3,
    gpuAllocated: 2,
    gpuIdle: 1
)

private func gpuNode(_ name: String, state: String, gres: String, total: Int, allocated: Int, partition: String, cpuIdle: Int = 32) -> NodeSummary {
    NodeSummary(
        node: name,
        partitions: [partition],
        state: state,
        cpuAllocated: 64 - cpuIdle,
        cpuIdle: cpuIdle,
        cpuOther: 0,
        cpuTotal: 64,
        gres: gres,
        gpuTotal: total,
        gpuAllocated: allocated,
        gpuIdle: total - allocated
    )
}

private func cpuNode(_ name: String, state: String, idle: Int, total: Int = 168) -> NodeSummary {
    NodeSummary(node: name, partitions: ["nodes"], state: state, cpuAllocated: total - idle, cpuIdle: idle, cpuOther: 0, cpuTotal: total)
}

/// Calder as observed live: H200s in calder-gpu-hopper, one drained L40
/// node in aire-gpu-lovelace.
private let calderNodes: [NodeSummary] = [
    gpuNode("calder-h200-01", state: "mix-", gres: "gpu:nvidia_h200:8(S:0-1)", total: 8, allocated: 7, partition: "calder-gpu-hopper"),
    gpuNode("calder-h200-02", state: "alloc", gres: "gpu:nvidia_h200:8(S:0-1)", total: 8, allocated: 8, partition: "calder-gpu-hopper"),
    gpuNode("calder-h200-03", state: "drain", gres: "gpu:nvidia_h200:8(S:0-1)", total: 8, allocated: 0, partition: "calder-gpu-hopper"),
    gpuNode("aire-l40-01", state: "drain*", gres: "gpu:nvidia_l40:3", total: 3, allocated: 0, partition: "aire-gpu-lovelace")
]

private func snapshot(
    collectedAt: String = "2026-10-13T12:00:00+00:00",
    jobs: [Job] = [],
    nodes: [NodeSummary] = [],
    partitions: [PartitionSummary] = [],
    storage: [StorageSummary]? = nil
) -> ClusterSnapshot {
    ClusterSnapshot(collectedAt: collectedAt, jobs: jobs, partitions: partitions, nodes: nodes, storage: storage)
}

// MARK: - Queue counts

@Suite("Job queue counts")
struct JobQueueCountsTests {
    @Test("Running, pending, held and other are told apart; SUSPENDED is not pending")
    func classification() {
        let counts = JobQueueCounts(jobs: [
            job("1", state: "RUNNING"),
            job("2", state: "COMPLETING"),
            job("3", state: "PENDING", reason: "Priority"),
            job("4", state: "PENDING", reason: "JobHeldUser"),
            job("5", state: "SUSPENDED"),
            job("6", state: "REQUEUE_HOLD", reason: "JobHoldMaxRequeue")
        ])
        #expect(counts.running == 2)
        #expect(counts.pending == 1)
        #expect(counts.held == 2)
        #expect(counts.other == 1)
        #expect(counts.waiting == 3)
        #expect(counts.total == 6)
    }

    @Test("An array's pending remainder counts every queued task")
    func arrayRemainder() {
        let remainder = job("8248307", state: "PENDING", reason: "Priority", arrayJobID: 8248307, arrayPendingTasks: "2-58", pendingTaskCount: 57)
        let task = job("8248307_1", state: "RUNNING", arrayJobID: 8248307)
        let counts = JobQueueCounts(jobs: [remainder, task])
        #expect(counts.pending == 57)
        #expect(counts.running == 1)
        #expect(counts.total == 58)
    }

    @Test("Summary leaves out empty parts but always names running")
    func summary() {
        #expect(JobQueueCounts(running: 1, pending: 13).summary == "1 running · 13 pending")
        #expect(JobQueueCounts(running: 0, pending: 0, held: 2).summary == "0 running · 2 held")
        #expect(JobQueueCounts().summary == "0 running · 0 pending")
        #expect(JobQueueCounts(running: 3, pending: 1, held: 1, other: 2).summary == "3 running · 1 pending · 1 held · 2 other")
    }

    @Test("Held jobs are named apart from pending ones; the other part can be named by the caller")
    func summaryWithOtherLabel() {
        let counts = JobQueueCounts(running: 9, pending: 1, held: 11)
        #expect(counts.summary == "9 running · 1 pending · 11 held")
        #expect(counts.summary(otherLabel: "suspended") == counts.summary)
        let suspended = JobQueueCounts(running: 1, pending: 6, other: 1)
        #expect(suspended.summary(otherLabel: "suspended") == "1 running · 6 pending · 1 suspended")
        #expect(suspended.summary == "1 running · 6 pending · 1 other")
        #expect(JobQueueCounts(running: 0, pending: 0, other: 1).summary(otherLabel: "suspended") == "0 running · 1 suspended")
    }

    @Test("Sidebar row: the queue on one line with held apart, idle GPUs on the next")
    func sidebarSummary() {
        let jobs = (1...11).map { job("667\($0 + 10)", state: "PENDING", reason: "(JobHeldUser)") }
            + (1...9).map { job("669\($0 + 10)", state: "RUNNING") }
            + [job("66927", state: "PENDING", reason: "(BeginTime)")]
        let fleet = GPUFleet(nodes: [
            gpuNode("calder-h200-01", state: "alloc", gres: "gpu:nvidia_h200:8", total: 8, allocated: 8, partition: "calder-gpu-hopper"),
            gpuNode("gpu028", state: "drain*", gres: "gpu:nvidia_l40:3", total: 3, allocated: 0, partition: "aire-gpu-lovelace")
        ])
        let summary = ClusterSidebarSummary(jobs: jobs, fleet: fleet)
        #expect(summary.lines == ["9 running · 1 pending · 11 held", "0 of 8 H200 idle · +1 more model"])
        #expect(summary.spoken == "9 running, 1 pending, 11 held; 0 of 8 H200 idle, and 1 more GPU model")
        #expect(!summary.lines.joined().contains("12 pending"))

        let cpuOnly = ClusterSidebarSummary(jobs: [job("1", state: "RUNNING")], fleet: GPUFleet(nodes: []))
        #expect(cpuOnly.lines == ["1 running · 0 pending"])
        #expect(ClusterSidebarSummary(text: "Signing in…").lines == ["Signing in…"])
    }
}

// MARK: - GPU wording

@Suite("GPU pool wording")
struct GPUPoolWordingTests {
    @Test("A stranded GPU on a fully allocated node is not idle (gpu018 regression)")
    func strandedNotIdle() throws {
        let fleet = GPUFleet(nodes: [gpu018])
        let pool = try #require(fleet.primary)
        #expect(pool.idle == 0)
        #expect(pool.stranded == 1)
        #expect(pool.idleSummary == "0 of 3 L40S idle")
        #expect(pool.breakdownSummary == "2 in use · 1 stranded")
        #expect(pool.breakdownHelp.contains("every CPU on their node is taken"))
    }

    @Test("Mixed models stay separate pools, largest first, one phrase each")
    func mixedModels() throws {
        let fleet = GPUFleet(nodes: calderNodes)
        #expect(fleet.pools.map(\.label) == ["H200", "L40"])
        let h200 = try #require(fleet.pools.first)
        #expect(h200.idleSummary == "1 of 24 H200 idle")
        let l40 = try #require(fleet.pools.last)
        #expect(l40.isWhollyUnavailable)
        #expect(!h200.isWhollyUnavailable)
        #expect(fleet.idleSummary() == "1 of 24 H200 idle · 0 of 3 L40 idle")
        #expect(fleet.idleSummary(limit: 1) == "1 of 24 H200 idle · +1 more")
    }

    @Test("A pool without a model name says GPUs")
    func unnamedModel() throws {
        let node = gpuNode("g1", state: "mix", gres: "gpu:4", total: 4, allocated: 1, partition: "gpu")
        let pool = try #require(GPUFleet(nodes: [node]).primary)
        #expect(pool.idleSummary == "3 of 4 GPUs idle")
        #expect(GPUFleet(nodes: []).idleSummary() == nil)
    }
}

// MARK: - Per-cluster stats

@Suite("Overview cluster stats")
struct OverviewClusterStatsTests {
    @Test("CPU capacity counts available CPU nodes only; unknown and maintenance states are unavailable")
    func cpuAndAvailability() {
        let nodes = [
            cpuNode("node001", state: "mix", idle: 100),
            cpuNode("node002", state: "idle$", idle: 168),   // maintenance reservation
            cpuNode("node003", state: "resv", idle: 168),    // reserved: not free capacity
            cpuNode("node004", state: "down*", idle: 168),
            gpu018
        ]
        let snap = snapshot(nodes: nodes)
        let stats = OverviewClusterStats(profile: .aire, snapshot: snap, fleet: GPUFleet(nodes: nodes))
        #expect(stats.cpuNodesReporting == 1)
        #expect(stats.cpuIdle == 100)
        #expect(stats.cpuTotal == 168)
        #expect(stats.nodeCount == 5)
        #expect(stats.unavailableNodes == 3)
        #expect(stats.fleet.idle == 0)
    }

    @Test("Walltime uses the shared Slurm duration rules")
    func walltime() throws {
        let partitions = [
            PartitionSummary(partition: "gpu", state: "mix", timeLimit: "2-00:00:00"),
            PartitionSummary(partition: "teachingnodes", state: "idle", timeLimit: "8:00:00"),
            PartitionSummary(partition: "gpu", state: "alloc", timeLimit: "2-00:00:00"),
            PartitionSummary(partition: "debug", state: "idle", timeLimit: "n/a")
        ]
        let walltime = try #require(OverviewFormat.maximumWalltime(partitions: partitions, profile: .aire))
        #expect(walltime.display == "2 days")
        // Same wording as the Partitions tab: "8 h", and the placeholder for n/a.
        #expect(walltime.detail.contains("teachingnodes: 8 h"))
        #expect(walltime.detail.contains("debug: \(missingValuePlaceholder)"))
    }

    @Test("An infinite limit outranks every finite one")
    func infiniteWalltime() throws {
        let partitions = [
            PartitionSummary(partition: "a", timeLimit: "7-00:00:00"),
            PartitionSummary(partition: "b", timeLimit: "infinite")
        ]
        let walltime = try #require(OverviewFormat.maximumWalltime(partitions: partitions, profile: .calder))
        #expect(walltime.display == "no limit")
    }
}

// MARK: - Digest

@Suite("Overview digest")
struct OverviewDigestTests {
    private func input(_ profile: ClusterProfile, phase: ClusterPresentation.Phase = .live, snapshot: ClusterSnapshot?, isEnabled: Bool = true, error: String? = nil) -> OverviewClusterInput {
        OverviewClusterInput(profile: profile, isEnabled: isEnabled, phase: phase, snapshot: snapshot, errorMessage: error)
    }

    @Test("Jobs follow the shared groups across clusters: running first, then resources, dependencies, held")
    func jobOrder() {
        let aire = snapshot(jobs: [
            job("8248683", state: "PENDING", reason: "Dependency"),
            job("8248700", state: "PENDING", reason: "Priority"),
            job("8248690", state: "RUNNING")
        ])
        let calder = snapshot(jobs: [
            job("9863", state: "PENDING", reason: "JobHeldUser"),
            job("9926", state: "RUNNING")
        ])
        let digest = OverviewDigest(clusters: [input(.aire, snapshot: aire), input(.calder, snapshot: calder)])
        // No submit times: the two running jobs tie, so catalog order
        // decides — never Calder's shorter id.
        #expect(digest.jobs.map(\.job.jobId) == ["8248690", "9926", "8248700", "8248683", "9863"])
        #expect(digest.counts.running == 2)
        #expect(digest.counts.held == 1)
    }

    @Test("Across clusters, submit time orders a group — Calder's short ids no longer take the collapsed list")
    @MainActor
    func crossClusterOrderBySubmitTime() {
        // The live snapshots: 3 running on AIRE (7-digit ids), 9 on Calder
        // (5-digit ids). By id every Calder job came first and the 8-row
        // collapsed list showed no AIRE job at all.
        let aire = snapshot(jobs: [
            job("8254575", state: "RUNNING", submitTime: "2026-10-13T17:17:03"),
            job("8254595", state: "RUNNING", submitTime: "2026-10-13T17:20:34"),
            job("8254596", state: "RUNNING", submitTime: "2026-10-13T17:20:34"),
            job("8248382", state: "PENDING", reason: "Priority", submitTime: "2026-10-13T10:37:57")
        ])
        let calderRunning: [(String, String)] = [
            ("66692", "16:26:59"), ("66848", "20:04:23"), ("66860", "20:28:32"), ("66899", "21:33:00"),
            ("66902", "21:41:01"), ("66904", "21:45:08"), ("66906", "21:49:09"), ("66922", "22:17:19"), ("66928", "22:29:21")
        ]
        let calder = snapshot(jobs: calderRunning.map { job($0.0, state: "RUNNING", submitTime: "2026-10-13T\($0.1)") } + [
            job("66927", state: "PENDING", reason: "BeginTime", submitTime: "2026-10-13T22:26:00"),
            job("66682", state: "PENDING", reason: "JobHeldUser", submitTime: "2026-10-13T16:18:51")
        ])
        let digest = OverviewDigest(clusters: [input(.aire, snapshot: aire), input(.calder, snapshot: calder)])
        let collapsed = digest.jobs.prefix(OverviewDashboard.collapsedJobLimit).map(\.job.jobId)
        #expect(collapsed == ["66692", "8254575", "8254595", "8254596", "66848", "66860", "66899", "66902"])
        // Every running job before any queued one; the earlier-submitted
        // AIRE job leads the resource-waiting group; held stays last.
        #expect(digest.jobs.map(\.job.jobId).suffix(3) == ["8248382", "66927", "66682"])
        // Each cluster's own order is exactly the Jobs tab's.
        for id in [ClusterID.aire, .calder] {
            let own = digest.jobs.filter { $0.profile.id == id }.map(\.job)
            #expect(own.map(\.jobId) == own.sorted(by: jobDisplayOrder).map(\.jobId))
        }
    }

    @Test("Within a cluster the Jobs tab's order stands even when submit times disagree with ids")
    func withinClusterOrderKept() {
        // 101 was requeued, so it carries a later submit time than 102.
        let calder = snapshot(jobs: [
            job("102", state: "RUNNING", submitTime: "2026-10-13T09:00:00"),
            job("101", state: "RUNNING", submitTime: "2026-10-13T11:00:00")
        ])
        let aire = snapshot(jobs: [job("8254575", state: "RUNNING", submitTime: "2026-10-13T10:00:00")])
        let digest = OverviewDigest(clusters: [input(.aire, snapshot: aire), input(.calder, snapshot: calder)])
        #expect(digest.jobs.map(\.job.jobId) == ["8254575", "101", "102"])
        // Deterministic whatever order the clusters' rows arrive in.
        let reversed = OverviewDigest(clusters: [
            input(.aire, snapshot: aire),
            input(.calder, snapshot: snapshot(jobs: calder.jobs.reversed()))
        ])
        #expect(reversed.jobs.map(\.id) == digest.jobs.map(\.id))
    }

    @Test("The merge's groups are jobDisplayOrder's: a lower group always sorts first")
    func queueRankMatchesSharedOrder() {
        let jobs = [
            job("5", state: "RUNNING"),
            job("6", state: "COMPLETING"),
            job("7", state: "CONFIGURING"),
            job("1", state: "PENDING", reason: "(Priority)"),
            job("2", state: "PENDING", reason: "(Resources)"),
            job("3", state: "PENDING", reason: "(Dependency)"),
            job("4", state: "PENDING", reason: "(DependencyNeverSatisfied)"),
            job("8", state: "PENDING", reason: "(JobHeldUser)"),
            job("9", state: "PENDING", reason: "(JobHeldAdmin)"),
            job("10", state: "REQUEUED", reason: "(launch failed requeued held)"),
            job("11", state: "SUSPENDED"),
            job("12", state: "WEIRD")
        ]
        let ranks = jobs.map(OverviewJobEntry.queueRank)
        #expect(ranks == [0, 0, 0, 1, 1, 2, 2, 3, 3, 3, 4, 4])
        for lhs in jobs {
            for rhs in jobs where OverviewJobEntry.queueRank(lhs) < OverviewJobEntry.queueRank(rhs) {
                #expect(jobDisplayOrder(lhs, rhs), "\(lhs.jobId) should sort before \(rhs.jobId)")
                #expect(!jobDisplayOrder(rhs, lhs))
            }
        }
    }

    @Test("The same job id on two clusters is two entries, ordered by cluster")
    func sameIDTwoClusters() {
        let digest = OverviewDigest(clusters: [
            input(.aire, snapshot: snapshot(jobs: [job("123", state: "RUNNING")])),
            input(.calder, snapshot: snapshot(jobs: [job("123", state: "RUNNING")]))
        ])
        #expect(digest.jobs.map(\.id) == ["aire:123", "calder:123"])
    }

    @Test("Missing and disabled clusters are named, never counted as empty")
    func missingAndDisabled() {
        let digest = OverviewDigest(clusters: [
            input(.aire, snapshot: snapshot(jobs: [])),
            input(.calder, phase: .off(hasCache: true), snapshot: snapshot(jobs: [job("1", state: "RUNNING")]), isEnabled: false)
        ])
        #expect(digest.disabled.map(\.id) == [.calder])
        #expect(digest.jobs.isEmpty)
        let loading = OverviewDigest(clusters: [
            input(.aire, snapshot: snapshot(jobs: [])),
            input(.calder, phase: .loadingFirstSnapshot, snapshot: nil)
        ])
        #expect(loading.missing.first?.tagText == "loading")
        #expect(loading.emptyQueueDetail.contains("Calder is still loading"))
        let unreachable = OverviewDigest(clusters: [
            input(.aire, snapshot: snapshot(jobs: [])),
            input(.calder, phase: .notConnected, snapshot: nil)
        ])
        #expect(unreachable.emptyQueueDetail.contains("Calder is not connected, so its queue is unknown"))
    }

    @Test("The header age is the oldest snapshot, or per cluster when ages diverge")
    func summaryAges() {
        let now = SlurmTimestamp.parse("2026-10-13T12:00:30+00:00")!
        let close = OverviewDigest(clusters: [
            input(.aire, snapshot: snapshot(collectedAt: "2026-10-13T12:00:25+00:00")),
            input(.calder, snapshot: snapshot(collectedAt: "2026-10-13T11:59:50+00:00"))
        ])
        #expect(close.summary(now: now) == "2 clusters · 2 live · updated 40 s ago")

        let diverging = OverviewDigest(clusters: [
            input(.aire, snapshot: snapshot(collectedAt: "2026-10-13T12:00:25+00:00")),
            input(.calder, phase: .stale, snapshot: snapshot(collectedAt: "2026-10-13T11:00:00+00:00"))
        ])
        #expect(diverging.summary(now: now) == "2 clusters · 1 live · AIRE just now · Calder 1 h ago")

        let none = OverviewDigest(clusters: [input(.aire, phase: .notConnected, snapshot: nil)])
        #expect(none.summary(now: now) == "1 cluster · none live · no data yet")
    }

    @Test("Attention: full storage, held jobs, never-satisfiable dependencies, unusable GPU models, refresh errors")
    func attention() throws {
        let storage = [
            StorageSummary(label: "Home", usedGB: 44.5, quotaGB: 65, usedPercent: 69),
            StorageSummary(label: "Scratch", usedGB: 926, limitGB: 1024, usedPercent: 90.4),
            StorageSummary(label: "Flash", usedGB: 10, quotaGB: 5, overQuota: true)
        ]
        let jobs = [
            job("1", state: "PENDING", reason: "JobHeldUser"),
            job("2", state: "PENDING", reason: "DependencyNeverSatisfied"),
            job("3", state: "RUNNING")
        ]
        let calder = snapshot(jobs: jobs, nodes: calderNodes, storage: storage)
        let digest = OverviewDigest(clusters: [
            input(.aire, snapshot: snapshot(nodes: [cpuNode("n1", state: "idle", idle: 168)])),
            input(.calder, snapshot: calder, error: "Slurm query failed\nsecond line")
        ])
        // Nothing to say about AIRE, so it gets no line at all.
        #expect(digest.attention.map(\.profile.id) == [.calder])
        let items = try #require(digest.attention.first).items
        let texts = items.map(\.text)
        // The error comes with no refresh failure behind it (a sign-in or a
        // job action), so it is named by its own first line.
        #expect(texts == [
            "Slurm query failed",
            "Scratch 90% full",
            "Flash over quota",
            "1 job can never start",
            "1 job held",
            "L40 GPUs unavailable"
        ])
        #expect(items.first?.help == "Slurm query failed")
        #expect(items.first { $0.text == "L40 GPUs unavailable" }?.tab == .nodes)
        #expect(items.first { $0.text.hasPrefix("Scratch") }?.tone == .critical)
        #expect(items.first { $0.text.hasSuffix("held") }?.tone == .warning)
    }

    @Test("A Slurm outage over a healthy session reads as such, not as a sign-in problem")
    func schedulerIssue() {
        let digest = OverviewDigest(clusters: [
            OverviewClusterInput(
                profile: .calder,
                phase: .live,
                snapshot: snapshot(),
                schedulerIssue: "Slurm error on Calder: Section 'jobs' failed with exit 1"
            )
        ])
        let item = digest.attention.first?.items.first
        #expect(item?.text == "Slurm not answering")
        #expect(item?.tone == .warning)
        #expect(item?.help.contains("signing in again would not help") == true)
    }

    @Test("A cluster with no snapshot still surfaces its error, named by what failed")
    func attentionWithoutSnapshot() {
        let refresh = OverviewDigest(clusters: [
            OverviewClusterInput(
                profile: .calder,
                phase: .notConnected,
                snapshot: nil,
                errorMessage: "ssh: connect to host login1.calder: Operation timed out",
                refreshFailure: RefreshFailure(
                    kind: .transport,
                    message: "Calder did not answer",
                    detail: "ssh: connect to host login1.calder: Operation timed out",
                    consecutiveCount: 1,
                    date: Date()
                )
            )
        ])
        #expect(refresh.attention.first?.items.map(\.text) == ["Refresh failed"])

        let signIn = OverviewDigest(clusters: [
            input(.calder, phase: .notConnected, snapshot: nil, error: "Duo approval was not completed for Calder")
        ])
        let item = signIn.attention.first?.items.first
        #expect(item?.text == "Duo approval was not completed for Calder")
        #expect(item?.tone == .critical)
    }

    @Test("A failed sign-in never reads 'Refresh failed', and a Slurm outage keeps its wording after ⌘R")
    func errorLabelledByOrigin() {
        // (a) A rejected sign-in on a cluster that still shows its cache.
        let signIn = OverviewDigest(clusters: [
            input(.calder, phase: .stale, snapshot: snapshot(), error: "Calder rejected the password.\nCheck it and try again.")
        ])
        let signInItem = signIn.attention.first?.items.first
        #expect(signInItem?.text == "Calder rejected the password.")
        #expect(signInItem?.help == "Calder rejected the password.")

        // (b) ⌘R during a Slurm outage: the manual refresh's error is the
        // same report as the recorded failure, so the warning stays.
        let raw = "slurm_load_jobs error: Socket timed out on send/recv operation"
        let outage = RefreshFailure(kind: .clusterSide, message: "Slurm error on Calder: \(raw)", detail: raw, consecutiveCount: 2, date: Date())
        let manual = "Slurm on Calder did not answer. The SSH connection is fine, so signing in again would not help.\n\n\(raw)"
        let slurm = OverviewDigest(clusters: [
            OverviewClusterInput(profile: .calder, phase: .live, snapshot: snapshot(), errorMessage: manual, refreshFailure: outage)
        ])
        let slurmItem = slurm.attention.first?.items.first
        #expect(slurmItem?.text == "Slurm not answering")
        #expect(slurmItem?.tone == .warning)
    }

    @Test("Long first lines are cut to chip size at a word boundary")
    func shortenedChipText() {
        #expect(OverviewAttention.shortened("Short line") == "Short line")
        let long = "Calder rejected the password or the Duo approval timed out while waiting"
        let short = OverviewAttention.shortened(long)
        #expect(short.count <= 48)
        #expect(short == "Calder rejected the password or the Duo…")
    }

    private func failure(_ kind: RefreshFailure.Kind, count: Int = 1) -> RefreshFailure {
        RefreshFailure(kind: kind, message: "message for \(kind)", detail: "raw output", consecutiveCount: count, date: Date())
    }

    @Test("Automatic refresh failures reach the attention panel by kind")
    func refreshFailureAttention() {
        func items(_ failure: RefreshFailure, phase: ClusterPresentation.Phase = .live) -> [OverviewAttentionItem] {
            OverviewDigest(clusters: [
                OverviewClusterInput(profile: .calder, phase: phase, snapshot: snapshot(), refreshFailure: failure)
            ]).attention.first?.items ?? []
        }
        let setup = items(failure(.configuration))
        #expect(setup.map(\.text) == ["Setup problem"])
        #expect(setup.first?.tone == .critical)
        #expect(setup.first?.help.contains("signing in again will not help") == true)

        let slurm = items(failure(.clusterSide))
        #expect(slurm.map(\.text) == ["Slurm not answering"])
        #expect(slurm.first?.tone == .warning)

        // One connection blip heals on the next refresh: not worth a line.
        #expect(items(failure(.transport, count: 1)).isEmpty)
        let failing = items(failure(.transport, count: 3))
        #expect(failing.map(\.text) == ["Refreshes failing"])
        #expect(failing.first?.help.contains("3 failures in a row") == true)
        // A cluster that already dropped to cached data says so on its card.
        #expect(items(failure(.transport, count: 3), phase: .stale).isEmpty)
    }

    @Test("An error the user caused wins over the automatic failure behind it")
    func errorBeatsFailure() {
        let digest = OverviewDigest(clusters: [
            OverviewClusterInput(profile: .calder, phase: .live, snapshot: snapshot(), errorMessage: "manual refresh failed", refreshFailure: failure(.clusterSide))
        ])
        #expect(digest.attention.first?.items.map(\.text) == ["manual refresh failed"])
    }

    @Test("A setup problem before the first snapshot is named, a missing master is not")
    func setupProblemWithoutSnapshot() {
        let setup = OverviewDigest(clusters: [
            OverviewClusterInput(profile: .calder, phase: .notConnected, snapshot: nil, refreshFailure: failure(.configuration))
        ])
        #expect(setup.attention.first?.items.map(\.text) == ["Setup problem"])
        let notSignedIn = OverviewDigest(clusters: [
            OverviewClusterInput(profile: .calder, phase: .notConnected, snapshot: nil, refreshFailure: failure(.transport, count: 5))
        ])
        #expect(notSignedIn.attention.isEmpty)
    }
}

// MARK: - Job entries

@Suite("Overview job entries")
struct OverviewJobEntryTests {
    @Test("Time reads like the Partitions tab: elapsed of limit, or the limit while queued")
    func timeText() {
        let running = OverviewJobEntry(profile: .aire, clusterOrder: 0, job: job("1", state: "RUNNING", elapsed: "1:23:45", timeLimit: "2-00:00:00"), isFromLiveSession: true)
        #expect(running.timeText == "1 h 23 min of 2 days")
        let pending = OverviewJobEntry(profile: .aire, clusterOrder: 0, job: job("2", state: "PENDING", timeLimit: "12:00:00"), isFromLiveSession: true)
        #expect(pending.timeText == "limit 12 h")
        let unlimited = OverviewJobEntry(profile: .aire, clusterOrder: 0, job: job("3", state: "RUNNING", elapsed: "5:00", timeLimit: "UNLIMITED"), isFromLiveSession: true)
        #expect(unlimited.timeText == "5 min · no limit")
    }

    @Test("An array remainder says how many tasks wait; the GPU flag comes from the partition role")
    func placement() {
        let remainder = job("8248307", state: "PENDING", partition: "gpu", reason: "Priority", arrayJobID: 8248307, arrayPendingTasks: "2-58", pendingTaskCount: 57)
        let entry = OverviewJobEntry(profile: .aire, clusterOrder: 0, job: remainder, isFromLiveSession: true)
        #expect(entry.placementText == "57 tasks queued · Priority")
        #expect(entry.isGPU)
        #expect(entry.job.displayJobID == "8248307_[2-58]")
        let cpu = OverviewJobEntry(profile: .aire, clusterOrder: 0, job: job("9", state: "RUNNING", partition: "nodes", reason: "node010"), isFromLiveSession: true)
        #expect(!cpu.isGPU)
        #expect(cpu.placementText == "1 node · node010")
    }

    @Test("A held job reads Held, as on the Jobs tab, never an ordinary Pending")
    func heldLabel() {
        let held = OverviewJobEntry(profile: .calder, clusterOrder: 1, job: job("9863", state: "PENDING", reason: "(JobHeldUser)"), isFromLiveSession: true)
        #expect(held.stateLabel == "Held")
        let queued = OverviewJobEntry(profile: .calder, clusterOrder: 1, job: job("9864", state: "PENDING", reason: "(Priority)"), isFromLiveSession: true)
        #expect(queued.stateLabel == "Pending")
    }
}

@Suite("Overview job list toggle")
struct OverviewJobListToggleTests {
    @Test("The expand button counts rows and names the job total once an array remainder stands for many")
    func rowsVersusJobs() {
        let remainder = job("8248307", state: "PENDING", reason: "Priority", arrayJobID: 8248307, arrayPendingTasks: "2-58", pendingTaskCount: 57)
        let others = (1...8).map { job("90\($0)", state: $0 <= 2 ? "RUNNING" : "PENDING", reason: $0 <= 2 ? "gpu001" : "Priority") }
        let digest = OverviewDigest(clusters: [
            OverviewClusterInput(profile: .aire, phase: .live, snapshot: snapshot(jobs: [remainder] + others))
        ])
        #expect(digest.jobs.count == 9)
        #expect(digest.counts.total == 65)
        #expect(digest.rowsStandForMoreJobs)
        #expect(digest.jobListToggleTitle(showingAll: false, limit: 8) == "Show all 9 rows (65 jobs)")
        #expect(digest.jobListToggleTitle(showingAll: true, limit: 8) == "Show the first 8 rows")

        let plain = OverviewDigest(clusters: [
            OverviewClusterInput(profile: .aire, phase: .live, snapshot: snapshot(jobs: others + [job("999", state: "PENDING", reason: "Priority")]))
        ])
        #expect(!plain.rowsStandForMoreJobs)
        #expect(plain.jobListToggleTitle(showingAll: false, limit: 8) == "Show all 9 jobs")
        #expect(plain.jobListToggleTitle(showingAll: true, limit: 8) == "Show the first 8 jobs")
    }
}

// MARK: - State pills

@Suite("State pill wording")
struct StatePillPresentationTests {
    @Test("Node codes become plain words with the raw code and flags in the tooltip", arguments: [
        ("mix-", "Mixed", "calendar.badge.clock", "planned by backfill"),
        ("drain*", "Drained", "exclamationmark.circle", "not responding"),
        ("down$", "Down", "wrench.and.screwdriver", "maintenance reservation"),
        ("idle", "Idle", nil, "no CPUs allocated"),
        ("alloc", "Allocated", nil, "every CPU on the node is allocated")
    ] as [(String, String, String?, String)])
    func nodeStates(raw: String, label: String, glyph: String?, helpFragment: String) {
        let presentation = StatePillPresentation(raw: raw, kind: .automatic)
        #expect(presentation.label == label)
        #expect(presentation.flagGlyph == glyph)
        #expect(presentation.help.contains(raw))
        #expect(presentation.help.contains(helpFragment))
    }

    @Test("Job states read as job states; SUSPENDED is not Pending")
    func jobStates() {
        #expect(StatePillPresentation(raw: "RUNNING", kind: .automatic).label == "Running")
        #expect(StatePillPresentation(raw: "SUSPENDED", kind: .job).label == "Suspended")
        #expect(StatePillPresentation(raw: "SUSPENDED", kind: .job).slurmState == .suspended)
        #expect(StatePillPresentation(raw: "PD", kind: .job).label == "Pending")
    }

    @Test("A held job's pill reads Held in grey with the reason; other pending jobs keep Pending")
    func heldJob() {
        let held = StatePillPresentation(job: job("9863", state: "PENDING", reason: "(JobHeldUser)"))
        #expect(held.label == "Held")
        #expect(held.color == .gray)
        #expect(held.help == "PENDING — Held by you — release it with scontrol release")
        #expect(held.accessibilityValue.hasPrefix("Held, "))
        let admin = StatePillPresentation(job: job("1", state: "PENDING", reason: "(JobHeldAdmin)"))
        #expect(admin.label == "Held")
        let queued = StatePillPresentation(job: job("2", state: "PENDING", reason: "(Priority)"))
        #expect(queued == StatePillPresentation(raw: "PENDING", kind: .job))
        #expect(queued.label == "Pending")
        // A running job's reason column holds its node list, never a hold.
        #expect(StatePillPresentation(job: job("3", state: "RUNNING", reason: "gpu-hold-01")).label == "Running")
    }

    @Test("Partition availability keeps reading Up / Down")
    func partitionAvailability() {
        #expect(StatePillPresentation(raw: "up", kind: .automatic).label == "Up")
        #expect(StatePillPresentation(raw: "down", kind: .automatic).label == "Down")
    }
}

// MARK: - Confirmations

@Suite("Session action confirmations")
struct SessionActionConfirmationTests {
    private func work(_ id: ClusterID, live: Bool = true, terminals: Int = 0, transfers: Int = 0) -> SessionWork {
        SessionWork(
            clusterID: id,
            clusterName: catalogProfile(id).displayName,
            isLive: live,
            runningTerminals: terminals,
            activeTransfers: transfers
        )
    }

    @Test("Reconnect names the clusters, the terminals that close and the Duo pushes")
    func reconnectMessage() {
        let confirmation = SessionActionConfirmation(
            kind: .reconnect,
            work: [work(.aire, terminals: 2), work(.calder, terminals: 1)],
            usesJumpHost: true
        )
        #expect(confirmation.title == "Reconnect AIRE and Calder?")
        #expect(confirmation.confirmTitle == "Reconnect 2 clusters")
        #expect(confirmation.message.contains("replaces the SSH sessions to AIRE and Calder"))
        #expect(confirmation.message.contains("one Duo push each"))
        #expect(confirmation.message.contains("rash jump host"))
        #expect(confirmation.message.contains("Open terminals there close: 3 running sessions (2 on AIRE, 1 on Calder), including"))
        #expect(!confirmation.message.contains("file transfer"))
    }

    @Test("A reconnect always says it replaces the session and closes terminals, even with none running")
    func reconnectWithoutTerminals() {
        let confirmation = SessionActionConfirmation(kind: .reconnect, work: [work(.calder, live: false)], usesJumpHost: false)
        #expect(confirmation.confirmTitle == "Reconnect")
        #expect(confirmation.message.contains("replaces the Calder SSH session with a fresh sign-in: one Duo push."))
        #expect(confirmation.message.contains("Open terminals there would close; none are running now."))
        #expect(!confirmation.message.contains("jump host"))
    }

    @Test("Disconnect with one terminal uses the singular and promises no Duo push")
    func disconnectMessage() {
        let confirmation = SessionActionConfirmation(kind: .disconnect, work: [work(.calder, terminals: 1)], usesJumpHost: false)
        #expect(confirmation.title == "Disconnect Calder?")
        #expect(confirmation.message.contains("Open terminals there close: 1 running session,"))
        #expect(!confirmation.message.contains("Duo push"))
    }

    @Test("A running transfer is named: Disconnect and Reconnect never stop one silently")
    func transfersNamed() {
        let disconnect = SessionActionConfirmation(kind: .disconnect, work: [work(.aire, transfers: 1)], usesJumpHost: false)
        #expect(disconnect.activeTransfers == 1)
        #expect(disconnect.message.contains("A file transfer there stops unfinished; start it again after signing in."))
        #expect(disconnect.message.contains("none are running now"))

        let reconnect = SessionActionConfirmation(
            kind: .reconnect,
            work: [work(.aire, transfers: 2), work(.calder, transfers: 1)],
            usesJumpHost: false
        )
        #expect(reconnect.message.contains("3 file transfers there stop unfinished (2 on AIRE, 1 on Calder); start them again after signing in."))
    }

    @Test("A route change names every session it closes, what runs there and the Duo cost of the new route")
    func routeChangeMessage() {
        let confirmation = SessionActionConfirmation(
            kind: .changeRoute(.rashJump),
            work: [work(.aire, terminals: 2, transfers: 1), work(.calder)],
            usesJumpHost: true
        )
        #expect(confirmation.title == "Switch to the rash jump route?")
        #expect(confirmation.confirmTitle == "Switch route")
        #expect(confirmation.clusterIDs == [.aire, .calder])
        #expect(confirmation.message.contains("Each route has its own SSH sessions, so switching closes the sessions to AIRE and Calder now."))
        #expect(confirmation.message.contains("one Duo push each, plus one for the rash jump host"))
        #expect(confirmation.message.contains("Open terminals there close: 2 running sessions (2 on AIRE)"))
        #expect(confirmation.message.contains("A file transfer there stops unfinished (1 on AIRE)"))

        let direct = SessionActionConfirmation(kind: .changeRoute(.directVPN), work: [work(.calder)], usesJumpHost: false)
        #expect(direct.title == "Switch to the Direct (VPN) route?")
        #expect(direct.message.contains("switching closes the Calder session now. Signing in again over the new route costs one Duo push."))
    }

    @Test("A route change asks only when a live session, a terminal or a transfer would end")
    func routeChangeTargets() {
        let idle = work(.aire, live: false)
        let cachedWithShell = work(.calder, live: false, terminals: 1)
        let live = work(.calder)
        let transferring = work(.aire, live: false, transfers: 1)
        #expect(SessionActionConfirmation.endedByRouteChange([idle]).isEmpty)
        #expect(SessionActionConfirmation.endedByRouteChange([idle, cachedWithShell]) == [cachedWithShell])
        #expect(SessionActionConfirmation.endedByRouteChange([idle, live]) == [live])
        #expect(SessionActionConfirmation.endedByRouteChange([transferring]) == [transferring])
        #expect(!idle.hasRunningWork && cachedWithShell.hasRunningWork && transferring.hasRunningWork)
    }

    @Test("Name lists read naturally")
    func join() {
        #expect(SessionActionConfirmation.join(["AIRE"]) == "AIRE")
        #expect(SessionActionConfirmation.join(["AIRE", "Calder"]) == "AIRE and Calder")
        #expect(SessionActionConfirmation.join(["A", "B", "C"]) == "A, B and C")
    }
}
