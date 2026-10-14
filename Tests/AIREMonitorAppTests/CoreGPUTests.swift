import HPCCore
import Foundation
import Testing

// GPU figures are the headline numbers on every surface, so these tests pin
// HPCCore's one definition of them: gres parsing, per-node facts, and the
// per-model pools in GPUFleet (idle = startable now; stranded = idle but the
// node's CPUs are full; unavailable = on a node that accepts no work;
// unknown = no allocation reported, never counted as idle).

@Suite("Core · gres parsing")
struct CoreGresTests {
    @Test("GPU totals from sinfo %G strings", arguments: [
        ("gpu:4", 4),
        ("gpu:l40s:3", 3),
        ("gpu:l40s:3(S:0-1)", 3),
        ("gpu:nvidia_h200:8(S:0-1)", 8),
        ("gpu:nvidia_l40:3", 3),
        ("gpu:a100:4(S:0,2),mps:400", 4),
        ("mps:400,gpu:a100:4(IDX:0-3)", 4),
        ("gpu:nvidia_h200:8(S:0-1),gpu:nvidia_l40:2", 10),
        ("GPU:2", 2),
        ("gpu", 1),
        ("mps:400", 0),
        ("(null)", 0),
        (" (null) ", 0),
        ("", 0)
    ])
    func totals(gres: String, expected: Int) {
        #expect(slurmGPUTotal(from: gres) == expected)
    }

    @Test("Raw model identifiers", arguments: [
        ("gpu:l40s:3(S:0-1)", "l40s" as String?),
        ("gpu:nvidia_h200:8", "nvidia_h200"),
        ("mps:400,gpu:a100:4(S:0,2)", "a100"),
        ("gpu:4", nil),
        ("gpu", nil),
        ("(null)", nil),
        ("", nil)
    ])
    func models(gres: String, expected: String?) {
        #expect(slurmGPUModel(from: gres) == expected)
    }

    @Test("Display names never show the vendor prefix or raw underscores", arguments: [
        ("gpu:nvidia_h200:8(S:0-1)", "H200" as String?),
        ("gpu:nvidia_l40:3", "L40"),
        ("gpu:l40s:3", "L40S"),
        ("gpu:a100_80g:4", "A100 80G"),
        ("gpu:4", nil)
    ])
    func displayNames(gres: String, expected: String?) {
        #expect(slurmGPUModelDisplayName(from: gres) == expected)
    }

    @Test("Vendor prefixes are dropped whatever their case or separator", arguments: [
        ("NVIDIA_H200", "H200"),
        ("nvidia-a100", "A100"),
        ("amd_mi250x", "MI250X"),
        ("amd-mi300a", "MI300A"),
        ("h100", "H100")
    ])
    func vendorPrefixes(raw: String, expected: String) {
        #expect(gpuModelDisplayName(raw) == expected)
    }
}

@Suite("Core · per-node GPU facts")
struct CoreNodeGPUFactTests {
    @Test("Configured GPUs prefer the TRES count over the gres string")
    func gpuCount() {
        #expect(NodeSummary(node: "n", gres: "gpu:l40s:3", gpuTotal: 4).gpuCount == 4)
        #expect(NodeSummary(node: "n", gres: "gpu:l40s:3").gpuCount == 3)
        #expect(NodeSummary(node: "n").gpuCount == 0)
        #expect(gpuTotal(NodeSummary(node: "n", gres: "gpu:nvidia_h200:8(S:0-1)")) == 8)
    }

    @Test("Allocation is known, derived from the idle count, or unknown")
    func knownAllocation() {
        #expect(NodeSummary(node: "n", gres: "gpu:3", gpuTotal: 3, gpuAllocated: 2, gpuIdle: 1).knownGPUAllocated == 2)
        // Only the idle count reported: allocation is the rest.
        #expect(NodeSummary(node: "n", gres: "gpu:3", gpuTotal: 3, gpuIdle: 1).knownGPUAllocated == 2)
        // An idle count above the total never goes negative.
        #expect(NodeSummary(node: "n", gres: "gpu:3", gpuTotal: 3, gpuIdle: 5).knownGPUAllocated == 0)
        // No node details at all: unknown, which is never the same as idle.
        #expect(NodeSummary(node: "n", gres: "gpu:3").knownGPUAllocated == nil)
        // A CPU node has nothing to allocate.
        #expect(NodeSummary(node: "n").knownGPUAllocated == 0)
    }

    @Test("A node's CPUs are full when nothing is idle")
    func cpusFull() {
        #expect(NodeSummary(node: "n", cpuAllocated: 24, cpuIdle: 0, cpuOther: 0, cpuTotal: 24).cpusFull)
        #expect(!NodeSummary(node: "n", cpuAllocated: 23, cpuIdle: 1, cpuOther: 0, cpuTotal: 24).cpusFull)
        // Without an idle count it is derived from total - allocated - other.
        #expect(NodeSummary(node: "n", cpuAllocated: 20, cpuOther: 4, cpuTotal: 24).cpusFull)
        #expect(!NodeSummary(node: "n", cpuAllocated: 20, cpuTotal: 24).cpusFull)
        // Nothing known: never claim the node is full.
        #expect(!NodeSummary(node: "n").cpusFull)
    }

    @Test("gpu018: CPUs full with one GPU idle")
    func strandedNode() {
        let node = CoreFixtures.node("gpu018", in: CoreFixtures.aireNodes)
        #expect(node.cpusFull)
        #expect(node.knownGPUAllocated == 2)
        #expect(node.stateInfo.isAvailable)
    }

    @Test("Per-node legacy accessors")
    func legacyAccessors() {
        let gpu002 = CoreFixtures.node("gpu002", in: CoreFixtures.aireNodes)
        #expect(gpuTotal(gpu002) == 3)
        #expect(gpuAllocated(gpu002) == 1)
        #expect(gpuIdle(gpu002) == 2)
        #expect(isAvailable(gpu002))

        let down = CoreFixtures.node("gpu021", in: CoreFixtures.aireNodes)
        #expect(gpuAllocated(down) == 0)
        #expect(!isAvailable(down))
    }

    @Test("The legacy idle count never claims GPUs whose allocation is unknown")
    func legacyIdleWithUnknownAllocation() {
        // A usable node the collector had no details for: GPUFleet calls its
        // 4 GPUs "unknown", and the legacy gpuIdle(_:) must agree that none
        // of them is idle.
        let node = NodeSummary(node: "g1", partitions: ["gpu"], state: "mix", gres: "gpu:a100:4")
        #expect(GPUFleet(nodes: [node]).idle == 0)
        #expect(gpuIdle(node) == 0)
    }
}

@Suite("Core · GPU pools")
struct CoreGPUFleetTests {
    @Test("Unknown allocation is never a definite figure: '?' idle and an in-use caption that names the unknown GPUs")
    func unknownAllocationCaptions() throws {
        let unknownNode = NodeSummary(node: "g1", partitions: ["gpu"], state: "mix", gres: "gpu:h200:8")
        let known = NodeSummary(node: "g2", partitions: ["gpu"], state: "mix", cpuIdle: 4, gres: "gpu:h200:8", gpuAllocated: 3)
        let allUnknown = try #require(GPUFleet(nodes: [unknownNode]).pools.first)
        #expect(allUnknown.idleFigure == "?")
        #expect(allUnknown.inUseCaption == "8 unknown")
        #expect(!allUnknown.breakdownHelp.contains("0 of 8"))
        let partly = try #require(GPUFleet(nodes: [unknownNode, known]).pools.first)
        #expect(partly.inUseCaption == "3 in use · 8 unknown")
        let complete = try #require(GPUFleet(nodes: [known]).pools.first)
        #expect(complete.inUseCaption == "3 in use")
    }

    @Test("AIRE: one L40S pool with idle, stranded and unavailable GPUs kept apart")
    func aireFleet() throws {
        let fleet = GPUFleet(nodes: CoreFixtures.aireNodes)
        #expect(fleet.pools.count == 1)
        let pool = try #require(fleet.primary)
        #expect(pool.model == "L40S")
        #expect(pool.label == "L40S")
        #expect(pool.partitions == ["gpu"])
        #expect(pool.nodeCount == 14)
        #expect(pool.total == 42)
        #expect(pool.allocated == 31)
        #expect(pool.inUse == 31)
        // gpu001, gpu002 and gpu010 have free CPUs next to their idle GPUs.
        #expect(pool.idle == 4)
        // gpu018's idle GPU sits on a node whose CPUs are all taken.
        #expect(pool.stranded == 1)
        // gpu021 and gpu028 are down$ with no allocation reported.
        #expect(pool.unavailable == 6)
        #expect(pool.unavailableNodes == 2)
        #expect(pool.unknown == 0)
        #expect(!fleet.hasUnknownAllocation)
        #expect(fleet.modelLabel == "L40S")
        #expect(fleet.poolsWithIdle.map(\.label) == ["L40S"])
    }

    @Test("Calder: H200 and L40 are separate pools, largest first")
    func calderFleet() throws {
        let fleet = GPUFleet(nodes: CoreFixtures.calderNodes)
        #expect(fleet.pools.map(\.label) == ["H200", "L40"])
        #expect(fleet.modelLabel == "H200 + L40")

        let h200 = try #require(fleet.pools.first)
        #expect(h200.partitions == ["calder-gpu-hopper"])
        #expect(h200.nodeCount == 7)
        #expect(h200.total == 56)
        #expect(h200.allocated == 32)
        // mix- nodes (planned by backfill) still accept work.
        #expect(h200.idle == 16)
        #expect(h200.stranded == 0)
        // calder-h200-05 is drained with no allocation reported.
        #expect(h200.unavailable == 8)
        #expect(h200.unavailableNodes == 1)

        let l40 = try #require(fleet.pools.last)
        #expect(l40.partitions == ["aire-gpu-lovelace"])
        #expect(l40.nodeCount == 1)
        #expect(l40.total == 3)
        #expect(l40.idle == 0)
        #expect(l40.allocated == 0)
        #expect(l40.unavailable == 3)
        #expect(l40.unavailableNodes == 1)

        // Fleet totals exist for alerts and trend lines only; the per-model
        // split is what the user sees.
        #expect(fleet.total == 59)
        #expect(fleet.idle == 16)
        #expect(fleet.unavailable == 11)
        #expect(fleet.unavailableNodes == 2)
        #expect(fleet.nodeCount == 8)
        #expect(fleet.poolsWithIdle.map(\.label) == ["H200"])
    }

    @Test("Every GPU is counted exactly once in each pool")
    func poolsPartitionTheirGPUs() {
        let nodes = CoreFixtures.aireNodes + CoreFixtures.calderNodes + [
            NodeSummary(node: "u1", partitions: ["gpu"], state: "mix", gres: "gpu:a100:4"),
            NodeSummary(node: "d1", partitions: ["gpu"], state: "drng", gres: "gpu:a100:4", gpuTotal: 4, gpuAllocated: 2)
        ]
        let fleet = GPUFleet(nodes: nodes)
        for pool in fleet.pools {
            #expect(pool.allocated + pool.idle + pool.stranded + pool.unavailable + pool.unknown == pool.total, "\(pool.label)")
        }
        #expect(fleet.total == nodes.reduce(0) { $0 + $1.gpuCount })
    }

    @Test("Unknown allocation on a usable node is unknown, never idle")
    func unknownAllocation() throws {
        let node = NodeSummary(node: "g1", partitions: ["gpu"], state: "mix", gres: "gpu:a100:4")
        let pool = try #require(GPUFleet(nodes: [node]).primary)
        #expect(pool.unknown == 4)
        #expect(pool.idle == 0)
        #expect(pool.allocated == 0)
        #expect(GPUFleet(nodes: [node]).hasUnknownAllocation)
    }

    @Test("Unknown allocation on a node that accepts no work is unavailable")
    func unknownOnDrainedNode() throws {
        let node = NodeSummary(node: "g1", partitions: ["gpu"], state: "drain", gres: "gpu:a100:4")
        let pool = try #require(GPUFleet(nodes: [node]).primary)
        #expect(pool.unavailable == 4)
        #expect(pool.unknown == 0)
        #expect(pool.unavailableNodes == 1)
    }

    @Test("Idle GPUs on draining and reserved nodes are unavailable, their running jobs still count", arguments: [
        "drng", "mix$", "idle$", "mix*", "mix@"
    ])
    func idleOnNodesThatAcceptNoWork(state: String) throws {
        // The regression the last review fixed: idle GPUs on a drained node
        // were offered as free capacity.
        let node = NodeSummary(
            node: "g1", partitions: ["gpu"], state: state,
            cpuAllocated: 8, cpuIdle: 16, cpuOther: 0, cpuTotal: 24,
            gres: "gpu:l40s:3", gpuTotal: 3, gpuAllocated: 1, gpuIdle: 2
        )
        let pool = try #require(GPUFleet(nodes: [node]).primary)
        #expect(pool.allocated == 1)
        #expect(pool.idle == 0)
        #expect(pool.stranded == 0)
        #expect(pool.unavailable == 2)
        #expect(pool.unavailableNodes == 1)
    }

    @Test("Over-reported allocation is clamped to the node's GPUs")
    func clampsAllocation() throws {
        let node = NodeSummary(node: "g1", state: "alloc", gres: "gpu:4", gpuTotal: 4, gpuAllocated: 6)
        let pool = try #require(GPUFleet(nodes: [node]).primary)
        #expect(pool.allocated == 4)
        #expect(pool.idle == 0)
    }

    @Test("Untyped GPUs form their own pool labelled GPU")
    func untypedPool() {
        let fleet = GPUFleet(nodes: [
            NodeSummary(node: "a", partitions: ["gpu"], state: "idle", cpuIdle: 8, gres: "gpu:2", gpuTotal: 2, gpuAllocated: 0),
            NodeSummary(node: "b", partitions: ["gpu"], state: "idle", cpuIdle: 8, gres: "gpu:l40s:3", gpuTotal: 3, gpuAllocated: 0)
        ])
        #expect(fleet.pools.map(\.label) == ["L40S", "GPU"])
        #expect(fleet.pools.last?.model == nil)
        #expect(fleet.pools.last?.id == "GPU")
    }

    @Test("Ties keep first-seen order; a third model is summarised as more")
    func orderingAndLabel() {
        func node(_ name: String, _ gres: String, _ count: Int) -> NodeSummary {
            NodeSummary(node: name, partitions: ["gpu"], state: "idle", cpuIdle: 8, gres: gres, gpuTotal: count, gpuAllocated: 0)
        }
        let fleet = GPUFleet(nodes: [
            node("a1", "gpu:a100:4", 4),
            node("v1", "gpu:v100:4", 4),
            node("h1", "gpu:nvidia_h200:8", 8)
        ])
        #expect(fleet.pools.map(\.label) == ["H200", "A100", "V100"])
        #expect(fleet.modelLabel == "H200 + A100 + more")
        #expect(fleet.primary?.label == "H200")
    }

    @Test("Partitions are collected per pool in first-seen order")
    func partitions() throws {
        let fleet = GPUFleet(nodes: [
            NodeSummary(node: "a", partitions: ["gpu", "gpu-long"], state: "mix", gres: "gpu:l40s:3", gpuTotal: 3, gpuAllocated: 3),
            NodeSummary(node: "b", partitions: ["gpu"], state: "mix", gres: "gpu:l40s:3", gpuTotal: 3, gpuAllocated: 3),
            NodeSummary(node: "c", partitions: ["gpu-debug", "gpu"], state: "mix", gres: "gpu:l40s:3", gpuTotal: 3, gpuAllocated: 3)
        ])
        let pool = try #require(fleet.primary)
        #expect(pool.partitions == ["gpu", "gpu-long", "gpu-debug"])
        #expect(pool.nodeCount == 3)
    }

    @Test("CPU-only clusters have no pools")
    func emptyFleet() {
        let fleet = GPUFleet(nodes: CoreFixtures.aireNodes.filter { $0.gpuCount == 0 })
        #expect(fleet.isEmpty)
        #expect(fleet.primary == nil)
        #expect(fleet.modelLabel == nil)
        #expect(fleet.total == 0)
        #expect(fleet.poolsWithIdle.isEmpty)
        #expect(GPUFleet(nodes: []).isEmpty)
    }
}

// MARK: - Shared pool tone and captions

/// One rule for a pool's idle tone and one caption under its idle figure,
/// so the overview tile, the cluster header chip, the menu bar row and
/// Trends can never colour or word the same pool differently.
@Suite("Core · GPU pool tone and captions")
struct CoreGPUPoolToneTests {
    private func node(
        _ name: String,
        state: String = "mix",
        cpuIdle: Int = 16,
        gres: String = "gpu:nvidia_h200:8",
        allocated: Int?
    ) -> NodeSummary {
        NodeSummary(
            node: name, partitions: ["gpu"], state: state,
            cpuAllocated: 128 - cpuIdle, cpuIdle: cpuIdle, cpuTotal: 128,
            gres: gres, gpuTotal: 8, gpuAllocated: allocated, gpuIdle: allocated.map { 8 - $0 }
        )
    }

    @Test("Some idle is good; known full is a warning, never critical; unknown or out of service is grey")
    func idleTone() throws {
        let free = try #require(GPUFleet(nodes: [node("a", allocated: 6)]).primary)
        #expect(free.idleTone == .normal)
        // 7 allocated and 1 idle stranded on a node whose CPUs are full: no
        // GPU can start a job, but that is a busy pool, not a fault.
        let full = try #require(GPUFleet(nodes: [node("a", state: "alloc", cpuIdle: 0, allocated: 7)]).primary)
        #expect(full.idle == 0 && full.stranded == 1)
        #expect(full.idleTone == .warning)
        #expect(full.idleTone != .critical)
        let unknown = try #require(GPUFleet(nodes: [node("a", allocated: nil)]).primary)
        #expect(unknown.idleIsUnknown)
        #expect(unknown.idleTone == .unavailable)
        // Some GPUs known idle beside unknown ones: a job can start, so good.
        let partly = try #require(GPUFleet(nodes: [node("a", allocated: 6), node("b", allocated: nil)]).primary)
        #expect(partly.idleTone == .normal)
        // Every node out of service, even with jobs still draining off.
        let drained = try #require(GPUFleet(nodes: [node("a", state: "drain", allocated: 0), node("b", state: "drng", allocated: 3)]).primary)
        #expect(drained.isWhollyUnavailable)
        #expect(drained.idleTone == .unavailable)
    }

    @Test("Calder's live pools: H200 full is orange, the drained L40 grey")
    func calderLive() throws {
        let fleet = GPUFleet(nodes: [
            node("calder-h200-01", state: "alloc", cpuIdle: 0, allocated: 8),
            node("calder-h200-04", state: "alloc", cpuIdle: 0, allocated: 1),
            node("calder-h200-05", state: "drain", allocated: 0),
            NodeSummary(
                node: "gpu028", partitions: ["aire-gpu-lovelace"], state: "drain*",
                cpuAllocated: 0, cpuIdle: 64, cpuTotal: 64,
                gres: "gpu:nvidia_l40:3", gpuTotal: 3, gpuAllocated: 0, gpuIdle: 3
            )
        ])
        let h200 = try #require(fleet.pools.first)
        #expect(h200.idleTone == .warning)
        #expect(h200.capacityCaption == "9 in use · 7 stranded · 8 unavailable")
        let l40 = try #require(fleet.pools.last)
        #expect(l40.idleTone == .unavailable)
        #expect(l40.capacityCaption == "all 3 unavailable")
    }

    @Test("The caption names every GPU that is not idle, never a definite '0 in use' for unreported GPUs")
    func captions() throws {
        let stranded = try #require(GPUFleet(nodes: [node("a", state: "alloc", cpuIdle: 0, allocated: 7)]).primary)
        #expect(stranded.breakdownSummary == "7 in use · 1 stranded")
        #expect(stranded.capacityCaption == stranded.breakdownSummary)
        let empty = try #require(GPUFleet(nodes: [node("a", allocated: 0)]).primary)
        #expect(empty.breakdownSummary == "0 in use")
        // Node details missing on one node, the other drained.
        let unknown = try #require(GPUFleet(nodes: [node("a", allocated: nil), node("b", state: "drain", allocated: nil)]).primary)
        #expect(unknown.breakdownSummary == "8 unavailable · 8 unknown")
        #expect(!unknown.capacityCaption.contains("in use"))
        let partly = try #require(GPUFleet(nodes: [node("a", allocated: 3), node("b", allocated: nil)]).primary)
        #expect(partly.breakdownSummary == "3 in use · 8 unknown")
        // Draining nodes still running jobs: the breakdown names them.
        let draining = try #require(GPUFleet(nodes: [node("a", state: "drng", allocated: 3)]).primary)
        #expect(draining.isWhollyUnavailable)
        #expect(draining.capacityCaption == "3 in use · 5 unavailable")
    }

    @Test("The largest pool's phrase says 'more model', never a bare '+1' after 'idle'")
    func primaryIdleText() {
        let l40 = NodeSummary(
            node: "gpu028", partitions: ["aire-gpu-lovelace"], state: "drain*",
            cpuAllocated: 0, cpuIdle: 64, cpuTotal: 64,
            gres: "gpu:nvidia_l40:3", gpuTotal: 3, gpuAllocated: 0, gpuIdle: 3
        )
        let a100 = node("x", gres: "gpu:a100:8", allocated: 8)
        let h200 = node("calder-h200-01", allocated: 8)
        #expect(GPUFleet(nodes: [h200]).primaryIdleText == "0 of 8 H200 idle")
        #expect(GPUFleet(nodes: [h200, l40]).primaryIdleText == "0 of 8 H200 idle · +1 more model")
        #expect(GPUFleet(nodes: [h200, node("y", gres: "gpu:a100:8", allocated: 8), a100, l40]).primaryIdleText == "0 of 16 A100 idle · +2 more models")
        #expect(GPUFleet(nodes: [h200, l40]).primaryIdleSpokenText == "0 of 8 H200 idle, and 1 more GPU model")
        let unknown = GPUFleet(nodes: [node("calder-h200-01", allocated: nil), l40])
        #expect(unknown.primaryIdleText == "? of 8 H200 idle · +1 more model")
        #expect(unknown.primaryIdleSpokenText?.contains("?") == false)
        #expect(GPUFleet(nodes: []).primaryIdleText == nil)
        #expect(GPUFleet(nodes: []).primaryIdleSpokenText == nil)
    }
}
