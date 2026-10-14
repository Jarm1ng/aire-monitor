import HPCCore
import SwiftUI

/// Everything one cluster row shows, derived from that cluster's snapshot
/// alone and from HPCCore's rules, so the widget can never disagree with the
/// app about what an idle GPU, an available node or a pending job is:
/// - GPU figures come from GPUFleet: "free" counts only GPUs a new job could
///   start on now (available node with a free CPU). Idle GPUs on nodes whose
///   CPUs are all taken are "stranded", idle GPUs on drained/down nodes are
///   "unavailable", and GPUs whose allocation the collector could not read
///   are "unknown" — none of them is ever shown as free.
/// - Job counts use JobState (a SUSPENDED job is neither running nor
///   pending), and the pending remainder of a job array counts every task it
///   stands for.
struct ClusterDigest {
    let fleet: GPUFleet
    let gpuNodes: [NodeSummary]
    let runningCount: Int
    /// Queued jobs that can start, array tasks included; held jobs are not
    /// pending (the app's JobQueueCounts rule on every surface).
    let pendingCount: Int
    /// Held jobs: queued but will not start until released.
    let heldCount: Int
    /// The first running job in the app's display order, else the first
    /// pending one.
    let topJob: Job?

    init(snapshot: ClusterSnapshot?) {
        let nodes = snapshot?.nodes ?? []
        fleet = GPUFleet(nodes: nodes)
        gpuNodes = nodes.filter { $0.gpuCount > 0 }

        let jobs = snapshot?.jobs ?? []
        let running = jobs.filter { $0.jobState.isRunning }
        let pending = jobs.filter { $0.jobState.isPending }
        let counts = JobQueueCounts(jobs: jobs)
        runningCount = counts.running
        pendingCount = counts.pending
        heldCount = counts.held
        topJob = running.min(by: jobDisplayOrder) ?? pending.min(by: jobDisplayOrder)
    }

    var hasGPUs: Bool {
        fleet.total > 0
    }

    /// "L40S", "H200 + L40", "H200 + L40 + more".
    var modelLabel: String {
        fleet.modelLabel ?? "GPU"
    }

    /// Share of GPUs allocated; nil while any GPU's allocation is unknown,
    /// the same rule as the app's Nodes ring and menu meter — a partial
    /// count would understate the load (40 allocated + 40 unknown of 84 is
    /// not "48 %"), and with nothing known it would read a free "0 %".
    var gpuRatio: Double? {
        guard fleet.total > 0, fleet.unknown == 0 else {
            return nil
        }
        return min(Double(fleet.allocated) / Double(fleet.total), 1)
    }

    /// "73%", or "?" while allocation is unknown.
    var gpuPercentLabel: String {
        gpuRatio.map { "\(Int(($0 * 100).rounded()))%" } ?? "?"
    }

    var gpuAccessibilityValue: String {
        guard let gpuRatio else {
            return "Allocation unknown for \(fleet.unknown) of \(fleet.total) GPUs; \(fleet.allocated) known to be allocated"
        }
        return "\(fleet.allocated) of \(fleet.total) GPUs allocated, \(Int((gpuRatio * 100).rounded())) percent"
    }

    /// Ring colour: neutral while allocation is unknown.
    var gpuColor: Color {
        gpuRatio.map { WidgetPalette.gpuColor(allocatedRatio: $0) } ?? WidgetPalette.neutral
    }

    /// Colour of the known-allocated segment in the usage bar, which stays
    /// coloured beside the grey unknown and stranded segments.
    var allocatedSegmentColor: Color {
        WidgetPalette.gpuColor(allocatedRatio: Double(fleet.allocated) / Double(max(fleet.total, 1)))
    }

    /// The free count, one term per model in the label's order, so mixed
    /// hardware is never merged into one anonymous figure: "1" for a single
    /// pool, "2 + 1" under "H200 + L40". Beyond two models the rest are
    /// summed into a third term, matching the label's "+ more".
    var freeFigure: String {
        let pools = fleet.pools
        guard pools.count > 1 else {
            // "?" when nothing is known idle only because the node details
            // are missing: a bare 0 would claim a full pool.
            return pools.first?.idleFigure ?? "\(fleet.idle)"
        }
        var terms = pools.prefix(2).map(\.idleFigure)
        if pools.count > 2 {
            let rest = pools.dropFirst(2)
            let restIdle = rest.reduce(0) { $0 + $1.idle }
            terms.append(restIdle == 0 && rest.contains { $0.unknown > 0 } ? "?" : "\(restIdle)")
        }
        return terms.joined(separator: " + ")
    }

    var hasFreeGPUs: Bool {
        fleet.idle > 0
    }

    /// Per-model breakdown for the tooltip.
    var gpuHelp: String {
        guard hasGPUs else {
            return "No GPU data in this snapshot"
        }
        var lines = fleet.pools.map { pool in
            var parts = ["\(pool.idleFigure) free", "\(pool.allocated) allocated"]
            if pool.stranded > 0 {
                parts.append("\(pool.stranded) idle on nodes whose CPUs are all allocated")
            }
            if pool.unavailable > 0 {
                parts.append("\(pool.unavailable) on unavailable nodes")
            }
            if pool.unknown > 0 {
                parts.append("\(pool.unknown) with unknown allocation")
            }
            return "\(pool.label): " + parts.joined(separator: ", ") + " of \(pool.total)"
        }
        lines.append("Free means a new job could start now: the node accepts work and has a free CPU.")
        return lines.joined(separator: "\n")
    }

    var freeAccessibilityValue: String {
        guard hasGPUs else {
            return "No GPU data"
        }
        let perPool = fleet.pools
            .map { $0.idleIsUnknown ? "an unknown number of \($0.label)" : "\($0.idle) \($0.label)" }
            .joined(separator: " and ")
        var parts = ["\(perPool) free of \(fleet.total) GPUs"]
        if fleet.stranded > 0 {
            parts.append("\(fleet.stranded) idle on nodes whose CPUs are full")
        }
        if fleet.unavailable > 0 {
            parts.append("\(fleet.unavailable) on unavailable nodes")
        }
        if fleet.unknown > 0 {
            parts.append("\(fleet.unknown) with unknown allocation")
        }
        return parts.joined(separator: "; ")
    }

    /// GPU nodes where a new job could start and at least one GPU is free.
    var nodesWithFreeGPUs: Int {
        gpuNodes.filter { node in
            guard node.stateInfo.isAvailable, !node.cpusFull, let allocated = node.knownGPUAllocated else {
                return false
            }
            return allocated < node.gpuCount
        }.count
    }

    /// Available GPU nodes where no new job can start: every GPU allocated,
    /// or every CPU taken.
    var fullNodes: Int {
        gpuNodes.filter { node in
            guard node.stateInfo.isAvailable else {
                return false
            }
            if node.cpusFull {
                return true
            }
            return node.knownGPUAllocated.map { $0 >= node.gpuCount } ?? false
        }.count
    }

    var nodeAccessibilityValue: String {
        var parts = [
            "\(gpuNodes.count) nodes: \(nodesWithFreeGPUs) with free GPUs",
            "\(fullNodes) full",
            "\(fleet.unavailableNodes) unavailable"
        ]
        let unknownNodes = gpuNodes.filter { $0.stateInfo.isAvailable && $0.knownGPUAllocated == nil }.count
        if unknownNodes > 0 {
            parts.append("\(unknownNodes) unknown")
        }
        return parts.joined(separator: ", ")
    }
}
