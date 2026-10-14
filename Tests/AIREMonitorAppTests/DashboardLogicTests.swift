import HPCCore
import Foundation
import Testing
@testable import AIREMonitorApp

// Logic behind the per-cluster dashboards (Jobs, Partitions, Nodes,
// Storage, Trends): every figure here is a number users act on, and each
// case below is a live situation the audit found mis-shown.

// MARK: - Fixtures

private let aire = ClusterProfile.aire
private let calder = ClusterProfile.calder

/// AIRE's live array 8248307: two running tasks and the pending remainder
/// standing for tasks 2-5 (throttled to 4 at once).
private let arrayRemainder = Job(
    jobId: "8248307", partition: "gpu", name: "c3-d1a-pack", state: "PENDING",
    elapsed: "0:00", timeLimit: "4:00:00", nodes: "1", reasonOrNodeList: "(Priority)",
    stdoutPath: "/scratch/logs/c3-d1a-pack_8248307_4294967294.out",
    reqTres: "cpu=8,mem=80G,node=1,billing=8,gres/gpu=1",
    arrayJobID: 8248307, arrayPendingTasks: "2-5", arrayThrottle: 4, pendingTaskCount: 4
)
private let arrayTask0 = Job(
    jobId: "8248307_0", partition: "gpu", name: "c3-d1a-pack", state: "RUNNING",
    elapsed: "1:11:17", timeLimit: "4:00:00", nodes: "1", reasonOrNodeList: "gpu003",
    nodeList: "gpu003", allocTres: "cpu=8,gres/gpu=1", arrayJobID: 8248307
)
/// An older cache: no array_job_id on the running task, only its id.
private let arrayTask1Legacy = Job(
    jobId: "8248307_1", partition: "gpu", name: "c3-d1a-pack", state: "RUNNING",
    elapsed: "1:08:12", timeLimit: "4:00:00", nodes: "1", reasonOrNodeList: "gpu020"
)
private let dependencyJob = Job(
    jobId: "8248381", partition: "nodes", name: "c3-c05-tune", state: "PENDING",
    elapsed: "0:00", timeLimit: "8:00:00", nodes: "1", reasonOrNodeList: "(Dependency)"
)
private let heldH200Job = Job(
    jobId: "9863", partition: "calder-gpu-hopper", name: "c3-d1-dump", state: "PENDING",
    elapsed: "0:00", timeLimit: "3:00:00", nodes: "1", reasonOrNodeList: "(JobHeldUser)",
    reqTres: "cpu=16,gres/gpu=2,gres/gpu:nvidia_h200=2"
)
private let suspendedJob = Job(
    jobId: "77", partition: "nodes", name: "paused", state: "SUSPENDED",
    elapsed: "2:00", timeLimit: "1:00:00", nodes: "1", reasonOrNodeList: "node010"
)

/// AIRE's gpu018: state alloc, every CPU taken, one GPU still idle.
private let gpu018 = NodeSummary(
    node: "gpu018", partitions: ["gpu"], state: "alloc",
    cpuAllocated: 24, cpuIdle: 0, cpuOther: 0, cpuTotal: 24,
    gres: "gpu:l40s:3(S:0-1)", gpuTotal: 3, gpuAllocated: 2, gpuIdle: 1
)

private func h200Node(_ name: String, state: String, allocated: Int?, cpuIdle: Int = 64) -> NodeSummary {
    NodeSummary(
        node: name, partitions: ["calder-gpu-hopper"], state: state,
        cpuAllocated: 128 - cpuIdle, cpuIdle: cpuIdle, cpuTotal: 128, memoryMB: 1_547_000,
        gres: "gpu:nvidia_h200:8(S:0-1)", gpuTotal: 8, gpuAllocated: allocated,
        gpuIdle: allocated.map { 8 - $0 }, memoryAllocatedMB: 0, memoryFreeMB: 1_400_000,
        currentWatts: 0
    )
}

private let lovelaceDrained = NodeSummary(
    node: "gpu028", partitions: ["aire-gpu-lovelace"], state: "drain*",
    cpuAllocated: 0, cpuIdle: 24, cpuTotal: 24, gres: "gpu:nvidia_l40:3", gpuTotal: 3
)

// MARK: - Jobs

@Suite("Jobs dashboard")
struct JobsDashboardLogicTests {
    @Test("An array remainder counts as the tasks it stands for")
    func arrayRemainderMultiplicity() {
        let rows = JobRow.rows(for: [arrayRemainder, arrayTask0, arrayTask1Legacy, dependencyJob], profile: aire)
        let summary = JobQueueSummary(rows: rows)
        #expect(summary.running == 2)
        #expect(summary.pending == 5) // 4 queued tasks + 1 dependency job
        #expect(summary.onDependency == 1)
        #expect(summary.total == 7)
        #expect(summary.queuedArrayTasks == 4)
        // 1 GPU per task × 4 queued tasks + 1 per running task.
        #expect(summary.gpuJobs == 6)
        // The legacy running task names no GPU count, so it adds a GPU job
        // but no requested GPUs.
        #expect(summary.gpusByModel[""] == 5)
        #expect(summary.gpuSubtitle == "5 GPUs requested")
        #expect(summary.totalSubtitle == "incl. 4 array tasks")
    }

    @Test("Rows follow the shared display order: running, waiting, dependency, held")
    func displayOrder() {
        let rows = JobRow.rows(for: [heldH200Job, dependencyJob, arrayRemainder, arrayTask1Legacy, arrayTask0], profile: calder)
        #expect(rows.map(\.job.jobId) == ["8248307_0", "8248307_1", "8248307", "8248381", "9863"])
        #expect(rows.map(\.group) == [.running, .running, .waiting, .waiting, .held])
    }

    @Test("A held job reads Held, not Pending, and its GPUs are named by model")
    func heldJob() {
        let row = JobRow(job: heldH200Job, profile: calder)
        #expect(row.isHeld)
        #expect(row.statusText == "Held")
        #expect(row.group == .held)
        #expect(row.gpuText == "2 × H200")
        let summary = JobQueueSummary(rows: [row])
        #expect(summary.held == 1)
        #expect(summary.pending == 0)
        #expect(summary.pendingSubtitle == "+1 held")
        #expect(summary.gpuSubtitle == "2 × H200 requested")
    }

    /// Calder's live queue: 9 running, 11 held by the user, 1 waiting for
    /// its begin time. "Pending" must mean 1 here, as on the overview,
    /// sidebar and menu bar (HPCCore `JobQueueCounts`), never 12.
    @Test("Pending never includes held jobs: the Jobs tile agrees with JobQueueCounts")
    func pendingExcludesHeld() {
        let running = (0..<9).map { Job(jobId: "6669\($0)", partition: "calder-gpu-hopper", state: "RUNNING", reasonOrNodeList: "calder-h200-01") }
        let held = (0..<11).map { Job(jobId: "6675\($0)", partition: "calder-gpu-hopper", state: "PENDING", reasonOrNodeList: "(JobHeldUser)") }
        let later = Job(jobId: "66927", partition: "calder-gpu-hopper", state: "PENDING", reasonOrNodeList: "(BeginTime)")
        let jobs = running + held + [later]
        let summary = JobQueueSummary(rows: JobRow.rows(for: jobs, profile: calder))
        let counts = JobQueueCounts(jobs: jobs)
        #expect(summary.running == counts.running && summary.running == 9)
        #expect(summary.pending == counts.pending && summary.pending == 1)
        #expect(summary.held == counts.held && summary.held == 11)
        #expect(summary.total == 21)
        #expect(summary.pendingSubtitle == "+11 held")
        #expect(summary.pendingHelp == "1 job waiting for resources, priority or a dependency; 11 held jobs on top, which will not start until released.")
        // Dependency jobs stay inside pending; held ones stay out.
        let mixed = JobQueueSummary(rows: JobRow.rows(for: [dependencyJob, heldH200Job, later], profile: calder))
        #expect(mixed.pending == 2 && mixed.onDependency == 1 && mixed.held == 1)
        #expect(mixed.pendingSubtitle == "1 on dependency · +1 held")
    }

    @Test("An array remainder's Slurm ntasks is labelled per task, beside its queued-task count")
    func arrayTasksLabel() {
        #expect(JobDetailView.slurmTasksLabel(for: arrayRemainder) == "ntasks (per task)")
        #expect(JobDetailView.slurmTasksHelp(for: arrayRemainder)?.contains("4 queued tasks") == true)
        #expect(JobDetailView.slurmTasksLabel(for: dependencyJob) == "Tasks")
        #expect(JobDetailView.slurmTasksHelp(for: dependencyJob) == nil)
    }

    @Test("Suspended jobs are neither running nor pending")
    func suspended() {
        let row = JobRow(job: suspendedJob, profile: aire)
        #expect(row.group == .other)
        #expect(row.statusText == "Suspended")
        let summary = JobQueueSummary(rows: [row])
        #expect(summary.running == 0)
        #expect(summary.pending == 0)
        #expect(summary.other == 1)
    }

    @Test("A queued job's reason is never shown as its node list")
    func nodeListOnlyForJobsOnNodes() {
        #expect(JobRow(job: dependencyJob, profile: aire).nodeListText == nil)
        #expect(JobRow(job: arrayTask1Legacy, profile: aire).nodeListText == "gpu020")
        #expect(JobRow(job: arrayRemainder, profile: aire).gpuText == "1 GPU per task")
    }

    @Test("The remainder's cancel dialog names running siblings, with or without array_job_id")
    func runningSiblings() {
        let siblings = JobsDashboard.runningSiblings(of: arrayRemainder, in: [arrayRemainder, arrayTask0, arrayTask1Legacy, dependencyJob])
        #expect(siblings.map(\.jobId) == ["8248307_0", "8248307_1"])
        #expect(JobsDashboard.runningSiblings(of: dependencyJob, in: [dependencyJob, arrayTask0]).isEmpty)
    }
}

@Suite("Pending reasons")
struct PendingReasonTests {
    @Test("Common reasons are explained", arguments: [
        ("(Dependency)", "Waiting for another job to finish"),
        ("(Priority)", "Queued behind higher-priority jobs"),
        ("(Resources)", "Waiting for free resources"),
        ("(JobHeldUser)", "Held by you — release it with scontrol release"),
        ("(JobHeldAdmin)", "Held by an administrator"),
        ("(ReqNodeNotAvail, Reserved for maintenance)", "Requested nodes are reserved for maintenance"),
        ("(QOSMaxJobsPerUserLimit)", "Waiting on a usage limit (QOSMaxJobsPerUserLimit)"),
        ("(SomethingNew)", "SomethingNew")
    ])
    func explanations(raw: String, expected: String) {
        #expect(SlurmPendingReason(raw)?.explanation == expected)
    }

    @Test("None and empty mean no reason", arguments: ["", "None", "(None)", "  "])
    func noReason(raw: String) {
        #expect(SlurmPendingReason(raw) == nil)
    }

    @Test("Held and dependency flags")
    func flags() {
        #expect(SlurmPendingReason("(JobHeldUser)")?.isHeld == true)
        #expect(SlurmPendingReason("(Dependency)")?.isDependency == true)
        #expect(SlurmPendingReason("(Priority)")?.waitsForCapacity == true)
        #expect(SlurmPendingReason("(Dependency)")?.waitsForCapacity == false)
        // A running job's %R is its node list, never a reason.
        #expect(arrayTask0.pendingReason == nil)
    }

    @Test("Relative times work in both directions")
    func distance() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(SlurmTimestamp.distanceText(to: now.addingTimeInterval(7200), now: now) == "in 2 h")
        #expect(SlurmTimestamp.distanceText(to: now.addingTimeInterval(300), now: now) == "in 5 min")
        #expect(SlurmTimestamp.distanceText(to: now.addingTimeInterval(5), now: now) == "now")
        #expect(SlurmTimestamp.distanceText(to: now.addingTimeInterval(-600), now: now) == "10 min ago")
    }

    @Test("Slurm durations are humanised, never shown raw")
    func durations() {
        #expect(elapsedText("1:11:17") == "1 h 11 min")
        #expect(formatSlurmTimeLimit("25:00") == "25 min")
        #expect(formatSlurmTimeLimit("1-00:00:00") == "1 day")
    }
}

// MARK: - Storage

@Suite("Storage tone")
struct StorageToneTests {
    @Test("A healthy Flash is normal whatever its identity colour")
    func flashHealthy() {
        let flash = StorageSummary(label: "Flash", usedPercent: 63)
        #expect(flash.usageTone == .normal)
    }

    @Test("Thresholds 75/90, over quota is critical, unreadable is unavailable")
    func thresholds() {
        #expect(StorageSummary(label: "Scratch", usedPercent: 88).usageTone == .warning)
        #expect(StorageSummary(label: "Scratch", usedPercent: 90.5).usageTone == .critical)
        #expect(StorageSummary(label: "Home", usedPercent: 20, overQuota: true).usageTone == .critical)
        #expect(StorageSummary(label: "Scratch", source: "unavailable").usageTone == .unavailable)
    }

    @Test("File-count pressure counts when it is the closer limit")
    func filePressure() {
        let space = StorageSummary(label: "Home", usedPercent: 40, fileCount: 950_000, fileQuota: 1_000_000)
        #expect(space.fileCountDominates)
        #expect(space.fileUsedPercent == 95)
        #expect(space.pressurePercent == 95)
        #expect(space.usageTone == .critical)
    }
}

// MARK: - Partitions

@Suite("Partition health")
struct PartitionHealthTests {
    private func row(_ partition: String, _ state: String, _ count: Int, availability: String = "up") -> PartitionSummary {
        PartitionSummary(partition: partition, availability: availability, nodeCount: count, state: state)
    }

    @Test("Every node drained: up in sinfo, but no usable nodes")
    func allDrained() {
        let rows = [row("aire-cpu-genoa", "drain$", 1), row("aire-cpu-genoa", "drain*", 1), row("aire-cpu-genoa", "drain", 6)]
        let health = PartitionHealth(rows: rows)
        #expect(health == .noUsableNodes(total: 8))
        #expect(!health.acceptsWork)
        #expect(health.label == "no usable nodes")
    }

    @Test("Some nodes out: degraded with the usable share")
    func degraded() {
        let rows = [row("calder-gpu-hopper", "mix-", 4), row("calder-gpu-hopper", "drain", 1), row("calder-gpu-hopper", "mix", 2)]
        let health = PartitionHealth(rows: rows)
        #expect(health == .degraded(usable: 6, total: 7))
        #expect(health.acceptsWork)
        #expect(health.label == "up · 6 of 7 usable")
    }

    /// A partition whose every node is drained is out of service, the grey
    /// "accepts no work" class (as its GPU pool's header chip is), not a
    /// red fault; only a partition Slurm reports down is red.
    @Test("Tones: no usable nodes is grey, down is red, degraded is orange")
    func tones() {
        #expect(PartitionHealth.noUsableNodes(total: 8).tone == .unavailable)
        #expect(PartitionHealth.down("inactive").tone == .critical)
        #expect(PartitionHealth.degraded(usable: 26, total: 28).tone == .warning)
        #expect(PartitionHealth.up.tone == .normal)
    }

    @Test("Administratively down and fully healthy")
    func downAndUp() {
        #expect(PartitionHealth(rows: [row("p", "idle", 3, availability: "inact")]) == .down("inactive"))
        #expect(PartitionHealth(rows: [row("p", "mix", 3), row("p", "idle", 2)]) == .up)
        // A maintenance reservation is not usable capacity.
        #expect(PartitionHealth(rows: [row("p", "idle$", 2)]) == .noUsableNodes(total: 2))
    }

    @Test("Totals count unique nodes and maintenance reservations")
    func totals() {
        let nodes = [
            NodeSummary(node: "node001", partitions: ["nodes", "teachingnodes"], state: "mix"),
            NodeSummary(node: "node002", partitions: ["nodes"], state: "down$"),
            NodeSummary(node: "node003", partitions: ["nodes"], state: "drain*"),
            gpu018
        ]
        let partitions = [row("nodes", "mix", 1), row("nodes", "down$", 1), row("nodes", "drain*", 1), row("teachingnodes", "mix", 1)]
        let totals = PartitionTotals(partitions: partitions, nodes: nodes)
        #expect(totals.nodeCount == 4)
        #expect(totals.nodeSubtitle == "1 in 2+ partitions")
        #expect(totals.nodeHelp == "4 nodes, each counted once; 1 node is in more than one partition.")
        #expect(totals.unavailableNodes == 2)
        #expect(totals.unavailableSubtitle == "1 in maintenance")
        #expect(totals.gpuTotal == 3)
        #expect(totals.gpuSubtitle == "3 L40S configured")
        // Without node rows the sums say what they are.
        #expect(PartitionTotals(partitions: partitions, nodes: []).nodeSubtitle == "summed across partitions")
    }

    @Test("Several GPU models are each named, short enough for a quarter of the narrowest column")
    func mixedModelSubtitle() {
        let totals = PartitionTotals(partitions: [], nodes: CoreFixtures.calderNodes)
        #expect(totals.gpuSubtitle.contains("H200"))
        #expect(totals.gpuSubtitle.contains(" + "))
        #expect(!totals.gpuSubtitle.contains("configured"))
    }

    @Test("State rows sort busy, idle, then unavailable — not alphabetically")
    func rowOrder() {
        let group = PartitionGroup(
            name: "gpu",
            rows: [row("gpu", "mix", 19), row("gpu", "down$", 2), row("gpu", "alloc", 7), row("gpu", "idle", 1)],
            profile: aire
        )
        #expect(group.sortedRows.map(\.state) == ["alloc", "mix", "idle", "down$"])
    }

    /// Mixed is a healthy state (partly allocated, still accepting work):
    /// it must not borrow the warning orange a degraded partition uses.
    @Test("Node occupancy uses capacity colours, never a status tone")
    func occupancyColours() {
        let mixed = SlurmState(node: "mix")
        #expect(mixed == .mixed)
        #expect(mixed.color != StatusTone.warning.color)
        #expect(mixed.color != StatusTone.critical.color)
        #expect(mixed.color != SlurmState(node: "alloc").color)
        #expect(mixed.color != SlurmState(node: "idle").color)
        #expect(SlurmState(node: "mix-").color == mixed.color)
        // A queued job keeps its orange; a drained node stays grey.
        #expect(SlurmState(job: "PENDING").color == .orange)
        #expect(SlurmState(node: "drain").color == AppTheme.unavailable)
    }

    @Test("Legend text replaces raw suffixes")
    func legendText() {
        #expect(NodeStateInfo("drain*").legendText == "Drained · not responding")
        #expect(NodeStateInfo("down$").legendText == "Down · maintenance")
        #expect(NodeStateInfo("mix-").legendText == "Mixed · planned")
        #expect(NodeStateInfo("drain*").helpText.hasPrefix("drain* — Drained"))
    }
}

// MARK: - Nodes

@Suite("Nodes dashboard")
struct NodesDashboardLogicTests {
    @Test("gpu018: the idle GPU on a full node is stranded, not free")
    func strandedGPU() {
        #expect(GPUSlotKind.slots(for: gpu018) == [.allocated, .allocated, .stranded])
        #expect(GPUNodeCategory(node: gpu018) == .full)
        let pool = GPUFleet(nodes: [gpu018]).pools[0]
        #expect(pool.idle == 0)
        #expect(pool.stranded == 1)
    }

    @Test("Unknown allocation is never drawn as idle")
    func unknownAllocation() {
        let node = h200Node("calder-h200-01", state: "mix", allocated: nil)
        #expect(GPUNodeCategory(node: node) == .unknown)
        #expect(GPUSlotKind.slots(for: node) == Array(repeating: .unknown, count: 8))
        #expect(gpuText(node) == "?/8")
    }

    @Test("The fleet ring shows no share while any allocation is unknown, never '0% in use'")
    func ringWithUnknownAllocation() throws {
        let unknown = try #require(GPUFleet(nodes: (1...7).map { h200Node("calder-h200-0\($0)", state: "mix", allocated: nil) }).primary)
        #expect(unknown.unknown == 56 && unknown.allocated == 0)
        #expect(GPUFleetPanel.utilization(unknown) == nil)

        let partial = try #require(GPUFleet(nodes: [
            h200Node("calder-h200-01", state: "mix", allocated: 8),
            h200Node("calder-h200-02", state: "mix", allocated: nil)
        ]).primary)
        #expect(GPUFleetPanel.utilization(partial) == nil)

        let known = try #require(GPUFleet(nodes: [
            h200Node("calder-h200-01", state: "mix", allocated: 8),
            h200Node("calder-h200-02", state: "mix", allocated: 0)
        ]).primary)
        #expect(GPUFleetPanel.utilization(known) == 0.5)
    }

    @Test("An idle count of 0 that only means 'allocation unknown' reads '?' in grey, not a full pool's orange 0")
    func idleTint() throws {
        let unknown = try #require(GPUFleet(nodes: [h200Node("calder-h200-01", state: "mix", allocated: nil)]).primary)
        #expect(unknown.idleIsUnknown)
        #expect(unknown.idleTint == AppTheme.unavailable)
        #expect(unknown.idleFigure == "?")
        #expect(unknown.idleSpokenSummary == "idle H200 GPUs unknown: allocation unknown for 8 of 8")
        let full = try #require(GPUFleet(nodes: [h200Node("calder-h200-01", state: "alloc", allocated: 8)]).primary)
        #expect(full.idleTint == .orange)
        #expect(full.idleFigure == "0")
        #expect(full.idleSpokenSummary == full.idleSummary)
        let free = try #require(GPUFleet(nodes: [h200Node("calder-h200-01", state: "mix", allocated: 2)]).primary)
        #expect(free.idleTint == AppTheme.idle)
        #expect(free.idleFigure == "6")
        // Some known idle beside unknown ones: the known count stands.
        let partial = try #require(GPUFleet(nodes: [
            h200Node("calder-h200-01", state: "mix", allocated: 2),
            h200Node("calder-h200-02", state: "mix", allocated: nil)
        ]).primary)
        #expect(!partial.idleIsUnknown && partial.idleFigure == "6" && partial.idleTint == AppTheme.idle)
        let drained = try #require(GPUFleet(nodes: [lovelaceDrained]).primary)
        #expect(drained.idleTint == AppTheme.unavailable)
    }

    /// Node details missing on Calder: 5 available H200 nodes report no
    /// allocation (40 unknown), two are drained (16 unavailable).
    @Test("The fleet bar, row header and summary never show a bare 0 idle while allocation is unknown")
    func fleetBarWithUnknownAllocation() throws {
        let nodes = (1...5).map { h200Node("calder-h200-0\($0)", state: "mix", allocated: nil) }
            + [h200Node("calder-h200-06", state: "drain", allocated: nil), h200Node("calder-h200-07", state: "drng", allocated: nil)]
            + [lovelaceDrained]
        let fleet = GPUFleet(nodes: nodes)
        let h200 = try #require(fleet.pools.first { $0.model == "H200" })
        #expect(h200.unknown == 40 && h200.unavailable == 16 && h200.idle == 0)
        #expect(h200.idleFigure == "?")
        #expect(GPUPoolRow.allocationText(h200) == "0 of 56 allocated · 40 unknown")
        let spoken = GPUFleetBar.accessibilityValue(h200)
        #expect(spoken.contains("idle GPUs unknown"))
        #expect(!spoken.contains("0 idle"))
        // Unknown GPUs are named beside their own model, not after the last one.
        #expect(GPUFleetPanel.summaryText(fleet) == "0 of 59 GPUs allocated · H200 0 of 56 (40 unknown) · L40 0 of 3")

        let known = try #require(GPUFleet(nodes: [h200Node("calder-h200-01", state: "mix", allocated: 3)]).primary)
        #expect(GPUPoolRow.allocationText(known) == "3 of 8 allocated")
        #expect(GPUFleetBar.accessibilityValue(known).hasPrefix("3 allocated, 5 idle and startable"))
        #expect(GPUFleetPanel.summaryText(GPUFleet(nodes: [h200Node("calder-h200-01", state: "mix", allocated: nil)])) == "0 of 8 H200 allocated · 8 unknown")
    }

    @Test("A busy GPU pool's ring is orange at most, never red")
    func ringTone() throws {
        let full = try #require(GPUFleet(nodes: [h200Node("calder-h200-01", state: "alloc", allocated: 8)]).primary)
        #expect(GPUFleetPanel.ringTone(full) == .warning)
        let busy = try #require(GPUFleet(nodes: [h200Node("calder-h200-01", state: "mix", allocated: 6)]).primary)
        #expect(GPUFleetPanel.ringTone(busy) == .warning)
        let light = try #require(GPUFleet(nodes: [h200Node("calder-h200-01", state: "mix", allocated: 2)]).primary)
        #expect(GPUFleetPanel.ringTone(light) == .normal)
        let unknown = try #require(GPUFleet(nodes: [h200Node("calder-h200-01", state: "mix", allocated: nil)]).primary)
        #expect(GPUFleetPanel.ringTone(unknown) == .normal)
    }

    @Test("A drained node's free GPUs are unavailable; its allocated ones stay allocated")
    func drainingNode() {
        let draining = NodeSummary(
            node: "gpu007", partitions: ["gpu"], state: "drng",
            cpuAllocated: 16, cpuIdle: 8, cpuTotal: 24, gres: "gpu:l40s:3", gpuTotal: 3, gpuAllocated: 2, gpuIdle: 1
        )
        #expect(GPUSlotKind.slots(for: draining) == [.allocated, .allocated, .unavailable])
        #expect(GPUNodeCategory(node: draining) == .unavailable)
        #expect(GPUSlotKind.slots(for: lovelaceDrained) == [.unavailable, .unavailable, .unavailable])
    }

    @Test("Mixed models get one shape each, never a range across models")
    func mixedShape() {
        let nodes = [h200Node("calder-h200-01", state: "mix", allocated: 4), lovelaceDrained]
        #expect(gpuShapeText(nodes) == "8 × H200, 3 × L40 per node")
        #expect(gpuShapeText([gpu018]) == "3 × L40S per node")
        #expect(gpuUnitText(5, model: "H200", adjective: "idle") == "5 idle H200")
        #expect(gpuUnitText(1, model: nil, adjective: "idle") == "1 idle GPU")
    }

    @Test("Core totals use available nodes and name the rest")
    func coreTotals() {
        let nodes = [
            NodeSummary(node: "c1", state: "mix", cpuAllocated: 64, cpuTotal: 128),
            NodeSummary(node: "c2", state: "idle", cpuAllocated: 0, cpuTotal: 128),
            NodeSummary(node: "c3", state: "drain", cpuAllocated: 0, cpuTotal: 1_600)
        ]
        #expect(coreUsageText(nodes) == ["64 of 256 cores allocated", "+\(groupedNumber(1_600)) on unavailable nodes"])
    }

    @Test("Calder's zero AllocMem and CurrentWatts mean untracked, not zero")
    func untrackedMetrics() {
        let calderNodes = [h200Node("calder-h200-01", state: "mix", allocated: 8), h200Node("calder-h200-02", state: "mix", allocated: 2)]
        let coverage = NodeMetricCoverage(nodes: calderNodes)
        #expect(!coverage.memoryTracked)
        #expect(!coverage.powerTracked)
        #expect(coverage.watts(for: calderNodes[0]) == nil)
        #expect(coverage.unallocatedMemoryMB(for: calderNodes[0]) == nil)

        let aireNode = NodeSummary(node: "gpu002", state: "mix", memoryMB: 256_656, memoryAllocatedMB: 245_760, memoryFreeMB: 231_909, currentWatts: 517)
        let downNode = NodeSummary(node: "gpu009", state: "down$", memoryMB: 256_656, memoryAllocatedMB: 0, currentWatts: 0)
        let aireCoverage = NodeMetricCoverage(nodes: [aireNode, downNode])
        #expect(aireCoverage.memoryTracked)
        #expect(aireCoverage.unallocatedMemoryMB(for: aireNode) == 10_896)
        #expect(aireCoverage.watts(for: aireNode) == 517)
        #expect(aireCoverage.watts(for: downNode) == nil)
    }
}

// MARK: - Trends

@Suite("Trends")
struct TrendsLogicTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func point(_ offset: TimeInterval, scratch: Double?) -> TrendPoint {
        let date = start.addingTimeInterval(offset)
        let storage = scratch.map { [StorageSummary(label: "Scratch", usedPercent: $0)] } ?? []
        return TrendPoint(snapshot: ClusterSnapshot(collectedAt: ISO8601DateFormatter().string(from: date), storage: storage))
    }

    @Test("Points are placed by time, and a long pause breaks the line")
    func gapSegments() {
        var history = (0..<10).map { point(Double($0) * 10, scratch: 50) }
        // 41 minutes asleep, then six more points.
        history += (0..<6).map { point(2_550 + Double($0) * 10, scratch: 60) }
        let timeline = TrendTimeline(history: history)
        #expect(timeline.typicalSpacing == 10)
        let slice = timeline.slice(.hour, now: start.addingTimeInterval(2_610))
        #expect(slice.count == 16)
        #expect(slice.gapCount == 1)
        let series = slice.series { $0.scratchUsedPercent }
        #expect(Set(series.samples.map(\.segment)) == [0, 1])
        #expect(series.latest == 60)
    }

    /// AIRE's live history: an outage from 17:01 to 21:27, then 11 points
    /// over 100 s. The 1 h window holds only those points; "no gaps" there
    /// read as complete coverage beside a 58-minute hole.
    @Test("A silence before the window's first point counts as a gap, unless the history is fresh")
    func leadingSilence() {
        let before = [point(0, scratch: 50)]
        let after = (0..<11).map { point(16_000 + Double($0) * 10, scratch: 50) }
        let timeline = TrendTimeline(history: before + after)
        let slice = timeline.slice(.hour, now: start.addingTimeInterval(16_100))
        #expect(slice.count == 11)
        #expect(slice.coveredSpan == 100)
        #expect(slice.gapCount == 1)
        // The same points as a brand-new history: nothing was missed.
        let fresh = TrendTimeline(history: after).slice(.hour, now: start.addingTimeInterval(16_100))
        #expect(fresh.gapCount == 0)
        // A break that only grazes the window's start is no gap in it.
        let grazing = TrendTimeline(history: [point(0, scratch: 50)] + (0..<400).map { point(100 + Double($0) * 10, scratch: 50) })
        #expect(grazing.slice(.hour, now: start.addingTimeInterval(4_090)).gapCount == 0)
    }

    @Test("Once points stop, the empty stretch after the last one counts as a gap")
    func trailingSilence() {
        let history = (0..<30).map { point(Double($0) * 10, scratch: 50) }
        let timeline = TrendTimeline(history: history)
        #expect(timeline.slice(.hour, now: start.addingTimeInterval(295)).gapCount == 0)
        // Paused ten minutes: the window ends now, ten minutes after the last point.
        #expect(timeline.slice(.hour, now: start.addingTimeInterval(290 + 600)).gapCount == 1)
    }

    /// The paused and unknown-allocation renders share every timestamp but
    /// not their GPU figures: the second must not be served the first's
    /// timeline.
    @MainActor
    @Test("The timeline memo never serves a history with the same stamps but other figures")
    func timelineMemo() {
        let formatter = ISO8601DateFormatter()
        func history(gpuAllocated: Int?) -> [TrendPoint] {
            (0..<5).map { index in
                let node = NodeSummary(
                    node: "g", partitions: ["gpu"], state: "mix", cpuAllocated: 8, cpuIdle: 16, cpuTotal: 24,
                    gres: "gpu:l40s:3", gpuTotal: 3, gpuAllocated: gpuAllocated, gpuIdle: gpuAllocated.map { 3 - $0 }
                )
                return TrendPoint(snapshot: ClusterSnapshot(collectedAt: formatter.string(from: start.addingTimeInterval(Double(index) * 10)), nodes: [node]))
            }
        }
        let known = history(gpuAllocated: 2)
        let unknown = history(gpuAllocated: nil)
        #expect(TrendTimeline.cached(for: known).points.last?.gpuUnknown == 0)
        #expect(TrendTimeline.cached(for: unknown).points.last?.gpuUnknown == 3)
        #expect(TrendTimeline.cached(for: known).points.last?.gpuAllocated == 2)
    }

    @Test("X-axis ticks at either end of the domain get no clipped time label")
    func axisLabelMargins() {
        let series = TrendSeries(samples: [], latest: nil, start: start, end: start.addingTimeInterval(3600))
        #expect(!series.labelsAxisTick(at: start.addingTimeInterval(3600)))
        #expect(!series.labelsAxisTick(at: start.addingTimeInterval(3_500)))
        #expect(!series.labelsAxisTick(at: start.addingTimeInterval(60)))
        #expect(series.labelsAxisTick(at: start.addingTimeInterval(900)))
        #expect(series.labelsAxisTick(at: start.addingTimeInterval(3_300)))
        let empty = TrendSeries(samples: [], latest: nil, start: start, end: start)
        #expect(empty.labelsAxisTick(at: start))
    }

    @Test("Queue pressure names held jobs apart from pending, or says queued without the snapshot")
    func queuePressureText() {
        let point = TrendPoint(
            collectedAt: "2026-10-13T21:29:23+00:00", totalJobs: 21, runningJobs: 9, pendingJobs: 12,
            gpuTotal: 0, gpuAllocated: 0, gpuIdle: 0, unavailableGpuNodes: 0,
            homeUsedPercent: nil, scratchUsedPercent: nil, homeAvailableGB: nil, scratchAvailableGB: nil,
            flashUsedPercent: nil, flashAvailableGB: nil
        )
        let counts = JobQueueCounts(running: 9, pending: 1, held: 11)
        #expect(TrendQueueText.value(point, counts: counts) == "9 running · 1 pending · 11 held")
        #expect(TrendQueueText.value(point, counts: nil) == "9 running · 12 queued")
        #expect(TrendQueueText.value(nil, counts: nil) == missingValuePlaceholder)
        #expect(!TrendQueueText.value(point, counts: nil).contains("pending"))
        #expect(TrendQueueText.subtitle(clusterName: "Calder").contains("held ones included"))
        #expect(TrendQueueText.help(hasCounts: false).contains("\"Queued\" is pending and held together"))
        #expect(TrendQueueText.help(hasCounts: true).contains("apart from pending"))
    }

    @Test("Missing values are gaps, never zero or bridged")
    func missingValues() {
        let history = [point(0, scratch: 50), point(10, scratch: nil), point(20, scratch: 52)]
        let series = TrendTimeline(history: history).slice(.hour, now: start.addingTimeInterval(20)).series { $0.scratchUsedPercent }
        #expect(series.samples.map(\.value) == [50, 52])
        #expect(series.samples.map(\.segment) == [0, 1])
    }

    @Test("The window excludes older points and ends now once points stop")
    func windowing() {
        let history = (0..<720).map { point(Double($0) * 10, scratch: Double($0 % 100)) } // 2 hours
        let timeline = TrendTimeline(history: history)
        let fresh = timeline.slice(.hour, now: start.addingTimeInterval(7_195))
        #expect(fresh.end == start.addingTimeInterval(7_190))
        #expect(fresh.count == 361)
        // Paused for three hours: the last hour holds nothing.
        let stale = timeline.slice(.hour, now: start.addingTimeInterval(7_190 + 3 * 3600))
        #expect(stale.isEmpty)
        #expect(timeline.slice(.sixHours, now: start.addingTimeInterval(7_195)).count == 720)
    }

    @Test("Thinning caps the marks and keeps the extremes")
    func thinning() {
        var history = (0..<1_440).map { point(Double($0) * 10, scratch: 50) }
        history[700] = point(7_000, scratch: 99)
        history[900] = point(9_000, scratch: 1)
        let series = TrendTimeline(history: history).slice(.day, now: start.addingTimeInterval(14_390)).series(maxPoints: 200) { $0.scratchUsedPercent }
        #expect(series.samples.count <= 202)
        #expect(series.samples.contains { $0.value == 99 })
        #expect(series.samples.contains { $0.value == 1 })
        #expect(series.samples.last?.date == start.addingTimeInterval(14_390))
        // Hover lookup by binary search.
        #expect(series.nearest(to: start.addingTimeInterval(7_001))?.value == 99)
    }

    @Test("The capacity signal judges each GPU model and ignores the user's queue")
    func capacitySignal() {
        // Calder: H200 with 17 idle of 56, the L40 node drained.
        let nodes = (1...7).map { h200Node("calder-h200-0\($0)", state: "mix", allocated: $0 <= 4 ? 8 : ($0 == 5 ? 3 : 2)) } + [lovelaceDrained]
        let signal = CapacitySignal(fleet: GPUFleet(nodes: nodes))
        #expect(signal.verdict == .room)
        #expect(signal.poolLabel == "H200")
        #expect(signal.explanation.contains("L40: 0 of 3 idle and startable — no node accepting work"))

        let full = CapacitySignal(fleet: GPUFleet(nodes: [gpu018]))
        #expect(full.verdict == .full) // the stranded GPU is no room
        // A known-full pool is the shared orange "full", never red.
        #expect(full.tone == .warning)

        // Many of the user's jobs pending says nothing about GPU capacity.
        let point = TrendPoint(snapshot: ClusterSnapshot(
            collectedAt: "2026-10-13T11:51:34.591558+00:00",
            jobs: (0..<9).map { Job(jobId: "\($0)", state: "PENDING", reasonOrNodeList: "(Dependency)") },
            nodes: [NodeSummary(node: "g", state: "mix", cpuAllocated: 1, cpuIdle: 7, cpuTotal: 8, gres: "gpu:l40s:84", gpuTotal: 84, gpuAllocated: 83, gpuIdle: 1)]
        ))
        #expect(CapacitySignal(latest: point).verdict == .tight)
    }

    /// An L40S node as it arrives when the collector's `scontrol show node`
    /// section failed or was cut: no allocation figures at all.
    private func l40sWithoutDetails(_ name: String, state: String = "mix") -> NodeSummary {
        NodeSummary(
            node: name, partitions: ["gpu"], state: state,
            cpuAllocated: 8, cpuIdle: 16, cpuOther: 0, cpuTotal: 24,
            gres: "gpu:l40s:3(S:0-1)"
        )
    }

    @Test("Unknown GPU allocation is never 'GPU full': it reads as unknown, in the unavailable tone")
    func capacitySignalUnknownAllocation() {
        let nodes = (1...28).map { l40sWithoutDetails(String(format: "gpu%03d", $0)) }
        let fleet = GPUFleet(nodes: nodes)
        #expect(fleet.unknown == 84 && fleet.idle == 0)
        let signal = CapacitySignal(fleet: fleet)
        #expect(signal.verdict == .unknown)
        #expect(signal.verdict != .full)
        #expect(signal.title == "Allocation unknown")
        #expect(signal.tone == .unavailable)
        #expect(signal.explanation.contains("L40S: 0 of 84 idle and startable — cannot be judged"))
        #expect(signal.explanation.contains("84 with unknown allocation"))

        // The history fallback reads the same from the stored unknown count.
        let point = TrendPoint(snapshot: ClusterSnapshot(collectedAt: "2026-10-13T11:51:34+00:00", nodes: nodes))
        #expect(point.gpuUnknown == 84)
        let fallback = CapacitySignal(latest: point)
        #expect(fallback.verdict == .unknown)
        #expect(fallback.explanation.contains("Allocation unknown for 84 GPUs"))
    }

    @Test("A verdict stands only when the unknown GPUs cannot change it", arguments: [
        (0, 0, CapacitySignal.Verdict.full),
        (0, 4, .unknown),      // could be full, could be tight
        (1, 3, .tight),        // tight either way (room needs 9 of 84)
        (1, 20, .unknown),     // tight or room
        (10, 50, .room),       // room either way
        (9, 0, .room)
    ] as [(Int, Int, CapacitySignal.Verdict)])
    func verdictBounds(idle: Int, unknown: Int, expected: CapacitySignal.Verdict) {
        #expect(CapacitySignal.verdict(idle: idle, total: 84, unknown: unknown, allNodesUnavailable: false) == expected)
    }

    @Test("No capacity verdict is red: full is a warning, unknown and unavailable are grey")
    func verdictTones() {
        #expect(CapacitySignal.Verdict.room.tone == .normal)
        #expect(CapacitySignal.Verdict.tight.tone == .warning)
        #expect(CapacitySignal.Verdict.full.tone == .warning)
        for verdict in [CapacitySignal.Verdict.unknown, .unavailable, .noData] {
            #expect(verdict.tone == .unavailable)
        }
    }

    /// The capacity card and the header chip colour the same pool alike
    /// wherever HPCCore's shared `GPUPool.idleTone` has a say: a known-full
    /// pool orange, a wholly unavailable one or one of unknown allocation
    /// grey, room green. ("Tight" is the card's own headroom grade.)
    @Test("The capacity signal's tone agrees with the shared pool tone")
    func agreesWithIdleTone() throws {
        let fleets: [GPUFleet] = [
            GPUFleet(nodes: [h200Node("calder-h200-01", state: "alloc", allocated: 8)]),   // full
            GPUFleet(nodes: [lovelaceDrained]),                                            // wholly unavailable
            GPUFleet(nodes: [h200Node("calder-h200-01", state: "mix", allocated: nil)]),   // unknown
            GPUFleet(nodes: [h200Node("calder-h200-01", state: "mix", allocated: 2)])      // room
        ]
        for fleet in fleets {
            let pool = try #require(fleet.primary)
            #expect(CapacitySignal(fleet: fleet).tone == pool.idleTone, "\(pool.breakdownSummary)")
        }
    }

    @Test("A pool of unknown allocation ranks above a full one and below a tight one")
    func unknownRanking() {
        #expect(CapacitySignal.Verdict.full < .unknown)
        #expect(CapacitySignal.Verdict.unknown < .tight)
    }

    @Test("Points with unknown GPUs are gaps in the GPU charts, never a dip to 0 %")
    func unknownGPUPointsAreGaps() {
        let formatter = ISO8601DateFormatter()
        func point(_ offset: TimeInterval, known: Bool) -> TrendPoint {
            let nodes = known
                ? [NodeSummary(node: "g", partitions: ["gpu"], state: "mix", cpuAllocated: 8, cpuIdle: 16, cpuTotal: 24, gres: "gpu:l40s:3", gpuTotal: 3, gpuAllocated: 2, gpuIdle: 1)]
                : [l40sWithoutDetails("g")]
            return TrendPoint(snapshot: ClusterSnapshot(collectedAt: formatter.string(from: start.addingTimeInterval(offset)), nodes: nodes))
        }
        let history = [point(0, known: true), point(10, known: false), point(20, known: true)]
        let slice = TrendTimeline(history: history).slice(.hour, now: start.addingTimeInterval(20))

        let allocation = slice.series(gpuPercent)
        #expect(allocation.samples.map(\.segment) == [0, 1])
        #expect(!allocation.samples.contains { $0.value == 0 })
        let idle = slice.series(gpuIdleCount)
        #expect(idle.samples.map(\.value) == [1, 1])
        #expect(idle.samples.map(\.segment) == [0, 1])

        let unknown = history[1]
        #expect(gpuPercent(unknown) == nil)
        #expect(gpuIdleCount(unknown) == nil)
        #expect(TrendGPUText.allocationValue(unknown) == "unknown")
        #expect(TrendGPUText.allocationHelp(unknown, noun: "L40S GPUs")?.contains("Allocation unknown for 3 of 3 L40S GPUs") == true)
        #expect(TrendGPUText.idleValue(unknown) == "unknown")
        #expect(TrendGPUText.idleHelp(unknown).contains("Allocation unknown for 3 GPUs"))

        let known = history[2]
        #expect(gpuPercent(known).map { Int($0.rounded()) } == 67)
        #expect(TrendGPUText.allocationValue(known) == "2 of 3")
        #expect(TrendGPUText.idleValue(known) == "1 idle")
        #expect(TrendGPUText.idleValue(nil) == missingValuePlaceholder)

        // History written before the field existed still charts.
        let legacy = TrendPoint(
            collectedAt: "2026-10-13T11:00:00+00:00", totalJobs: 0, runningJobs: 0, pendingJobs: 0,
            gpuTotal: 84, gpuAllocated: 42, gpuIdle: 40, unavailableGpuNodes: 0,
            homeUsedPercent: nil, scratchUsedPercent: nil, homeAvailableGB: nil, scratchAvailableGB: nil,
            flashUsedPercent: nil, flashAvailableGB: nil
        )
        #expect(gpuPercent(legacy) == 50)
    }

    @Test("Some GPUs known idle, the rest unknown: the idle card gives a lower bound")
    func partiallyUnknownIdle() {
        let nodes = [
            NodeSummary(node: "g1", partitions: ["gpu"], state: "mix", cpuAllocated: 8, cpuIdle: 16, cpuTotal: 24, gres: "gpu:l40s:3", gpuTotal: 3, gpuAllocated: 1, gpuIdle: 2),
            l40sWithoutDetails("g2")
        ]
        let point = TrendPoint(snapshot: ClusterSnapshot(collectedAt: "2026-10-13T11:51:34+00:00", nodes: nodes))
        #expect(point.gpuUnknown == 3)
        #expect(TrendGPUText.idleValue(point) == "at least 2 idle")
        #expect(TrendGPUText.allocationValue(point) == "unknown")
    }

    @Test("Collector timestamps with microseconds parse")
    func microsecondTimestamps() {
        #expect(SlurmTimestamp.parse("2026-10-13T11:51:34.591558+00:00") != nil)
        #expect(SlurmTimestamp.parse("2026-10-13T01:31:35") != nil)
    }
}

// MARK: - Sizes

@Suite("Size formatting")
struct SizeFormattingTests {
    /// Calder scratch: 999.06 GiB used of a 1,024 GiB limit, 24.94 GiB
    /// free. "999 GB / 1.0 TB" read as 99.9 % full beside the 98 % shown.
    @Test("Storage sizes are binary and keep sub-10 TiB limits whole")
    func storageSizes() {
        #expect(formatGB(999.0637) == "999 GiB")
        #expect(formatGB(1024) == "\(groupedNumber(1024)) GiB")
        #expect(formatGB(24.936) == "24.9 GiB")
        #expect(formatGB(65) == "65.0 GiB")
        #expect(formatGB(3715.34) == "\(groupedNumber(3715)) GiB")
        #expect(formatGB(10 * 1024) == "10.0 TiB")
        #expect(formatGB(nil) == missingValuePlaceholder)
        #expect(formatGB(.nan) == missingValuePlaceholder)
        #expect(!formatGB(1024).contains("TB") && !formatGB(500).contains("GB"))
    }

    @Test("Node memory is coarser, in the same binary units")
    func memorySizes() {
        #expect(formatMemoryGB(754.2) == "754 GiB")
        #expect(formatMemoryGB(1_547_000.0 / 1024) == "1.5 TiB")
        #expect(formatMemoryGB(1_546_000.0 / 1024) == formatMemoryGB(1_547_000.0 / 1024))
        #expect(formatMemoryGB(nil) == missingValuePlaceholder)
    }
}
