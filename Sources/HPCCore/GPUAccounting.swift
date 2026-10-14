import Foundation

// MARK: - GRES

/// Sums GPU counts from a Slurm GRES string: `gpu:4`, `gpu:l40s:3` (AIRE),
/// `gpu:nvidia_h200:8(S:0-1)` (Calder), `gpu:a100:4(S:0,2),mps:400`, a bare
/// `gpu` (one GPU), and `(null)`.
public func slurmGPUTotal(from gres: String) -> Int {
    let trimmed = gres.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.lowercased() != "(null)" else {
        return 0
    }
    var total = 0
    for rawEntry in splitOutsideParentheses(trimmed, separator: ",") {
        // Drop any parenthesised suffix like (S:0-1) or (IDX:0,2).
        let core = rawEntry.trimmingCharacters(in: .whitespaces).prefix { $0 != "(" }
        let pieces = core.split(separator: ":")
        guard let first = pieces.first, first.lowercased() == "gpu" else {
            continue
        }
        if pieces.count == 1 {
            total += 1
            continue
        }
        if let last = pieces.last, let count = Int(last.prefix { $0.isNumber }) {
            total += count
        }
    }
    return total
}

/// Raw Slurm gres type: "l40s" for `gpu:l40s:3(S:0-1)`, "nvidia_h200" for
/// `gpu:nvidia_h200:8`, nil for `gpu:4` or `(null)`. An identifier — show it
/// through `gpuModelDisplayName`, never uppercased raw.
public func slurmGPUModel(from gres: String) -> String? {
    for rawEntry in splitOutsideParentheses(gres, separator: ",") {
        let core = rawEntry.trimmingCharacters(in: .whitespaces).prefix { $0 != "(" }
        let pieces = core.split(separator: ":")
        guard pieces.count >= 3, pieces[0].lowercased() == "gpu" else {
            continue
        }
        return String(pieces[1])
    }
    return nil
}

/// Display name for a Slurm GPU gres type: "l40s" -> "L40S",
/// "nvidia_h200" -> "H200", "a100_80g" -> "A100 80G".
public func gpuModelDisplayName(_ rawModel: String) -> String {
    var model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in ["nvidia_", "nvidia-", "amd_", "amd-"] where model.lowercased().hasPrefix(prefix) {
        model = String(model.dropFirst(prefix.count))
    }
    return model
        .replacingOccurrences(of: "_", with: " ")
        .uppercased()
}

/// "L40S" for `gpu:l40s:3`, "H200" for `gpu:nvidia_h200:8(S:0-1)`, nil when
/// the GRES names no model.
public func slurmGPUModelDisplayName(from gres: String) -> String? {
    slurmGPUModel(from: gres).map(gpuModelDisplayName)
}

// MARK: - Per-node GPU facts

extension NodeSummary {
    /// Configured GPUs (from TRES when the collector had node details,
    /// otherwise from the gres string).
    public var gpuCount: Int {
        gpuTotal ?? slurmGPUTotal(from: gres)
    }

    /// Allocated GPUs, or nil when unknown: the collector had no node details
    /// for this node, so "no allocation reported" cannot be told apart from
    /// "nothing allocated". Unknown is never treated as idle.
    public var knownGPUAllocated: Int? {
        if let gpuAllocated {
            return gpuAllocated
        }
        if let gpuIdle {
            return max(gpuCount - gpuIdle, 0)
        }
        return gpuCount == 0 ? 0 : nil
    }

    /// Whether every CPU is taken, so no new job can start here even when a
    /// GPU is idle (a "stranded" GPU).
    public var cpusFull: Bool {
        if let cpuIdle {
            return cpuIdle <= 0
        }
        if let total = cpuTotal, let allocated = cpuAllocated {
            return total - allocated - (cpuOther ?? 0) <= 0
        }
        return false
    }
}

/// Legacy accessors kept for views that show raw per-node counts. Totals and
/// "free" figures must come from `GPUFleet`, which handles unknown allocation.
public func gpuTotal(_ node: NodeSummary) -> Int {
    node.gpuCount
}

public func gpuAllocated(_ node: NodeSummary) -> Int {
    node.knownGPUAllocated ?? 0
}

/// GPUs known to be unallocated; 0 when the allocation is unknown, the same
/// rule as `GPUFleet` (unknown is never idle).
public func gpuIdle(_ node: NodeSummary) -> Int {
    node.knownGPUAllocated.map { max(node.gpuCount - $0, 0) } ?? 0
}

public func isAvailable(_ node: NodeSummary) -> Bool {
    node.stateInfo.isAvailable
}

// MARK: - GPU pools

/// All GPUs of one model on one cluster. GPU models are separate pools: an
/// idle L40 is not an idle H200, so pools are never summed into one "free"
/// figure without naming each model.
public struct GPUPool: Equatable, Identifiable, Sendable {
    /// Display name ("H200"); nil for GPUs whose gres names no model.
    public let model: String?
    public let partitions: [String]
    public let nodeCount: Int
    public let total: Int
    /// Known allocated GPUs, on any node (draining nodes included).
    public let allocated: Int
    /// Idle GPUs a new job could start on now: available node, free CPU.
    public let idle: Int
    /// Idle GPUs on available nodes whose CPUs are all taken.
    public let stranded: Int
    /// Idle GPUs on nodes that accept no work (down, drained, maintenance,
    /// not responding).
    public let unavailable: Int
    /// GPUs on available nodes whose allocation is unknown.
    public let unknown: Int
    /// GPU nodes that accept no new work.
    public let unavailableNodes: Int

    public var id: String { model ?? "GPU" }
    public var label: String { model ?? "GPU" }
    public var inUse: Int { allocated }
}

/// Every GPU pool of one cluster snapshot, largest first. The one place
/// idle, stranded, unavailable and unknown GPUs are defined.
public struct GPUFleet: Equatable, Sendable {
    public let pools: [GPUPool]

    public init(nodes: [NodeSummary]) {
        struct Tally {
            var partitions: [String] = []
            var nodeCount = 0
            var total = 0
            var allocated = 0
            var idle = 0
            var stranded = 0
            var unavailable = 0
            var unknown = 0
            var unavailableNodes = 0
            var firstSeen = 0
        }
        var tallies: [String: Tally] = [:]
        var order = 0
        for node in nodes {
            let total = node.gpuCount
            guard total > 0 else {
                continue
            }
            let key = slurmGPUModelDisplayName(from: node.gres) ?? ""
            var tally = tallies[key] ?? Tally(firstSeen: order)
            order += 1
            tally.nodeCount += 1
            tally.total += total
            for partition in node.partitions where !tally.partitions.contains(partition) {
                tally.partitions.append(partition)
            }
            let available = node.stateInfo.isAvailable
            if !available {
                tally.unavailableNodes += 1
            }
            if let allocated = node.knownGPUAllocated {
                let allocatedHere = min(allocated, total)
                let idleHere = total - allocatedHere
                tally.allocated += allocatedHere
                if !available {
                    tally.unavailable += idleHere
                } else if node.cpusFull {
                    tally.stranded += idleHere
                } else {
                    tally.idle += idleHere
                }
            } else if available {
                tally.unknown += total
            } else {
                tally.unavailable += total
            }
            tallies[key] = tally
        }
        var built: [(order: Int, pool: GPUPool)] = []
        for (key, tally) in tallies {
            let pool = GPUPool(
                model: key.isEmpty ? nil : key,
                partitions: tally.partitions,
                nodeCount: tally.nodeCount,
                total: tally.total,
                allocated: tally.allocated,
                idle: tally.idle,
                stranded: tally.stranded,
                unavailable: tally.unavailable,
                unknown: tally.unknown,
                unavailableNodes: tally.unavailableNodes
            )
            built.append((tally.firstSeen, pool))
        }
        built.sort { lhs, rhs in
            if lhs.pool.total != rhs.pool.total {
                return lhs.pool.total > rhs.pool.total
            }
            return lhs.order < rhs.order
        }
        pools = built.map { $0.pool }
    }

    public var isEmpty: Bool { pools.isEmpty }
    public var total: Int { pools.reduce(0) { $0 + $1.total } }
    public var allocated: Int { pools.reduce(0) { $0 + $1.allocated } }
    /// Startable idle GPUs across ALL models. Only for alerts and trend
    /// lines; anything shown to the user per model should use `pools`.
    public var idle: Int { pools.reduce(0) { $0 + $1.idle } }
    public var stranded: Int { pools.reduce(0) { $0 + $1.stranded } }
    public var unavailable: Int { pools.reduce(0) { $0 + $1.unavailable } }
    public var unknown: Int { pools.reduce(0) { $0 + $1.unknown } }
    public var unavailableNodes: Int { pools.reduce(0) { $0 + $1.unavailableNodes } }
    public var nodeCount: Int { pools.reduce(0) { $0 + $1.nodeCount } }
    public var hasUnknownAllocation: Bool { unknown > 0 }

    /// The largest pool, e.g. Calder's H200s next to a few L40s.
    public var primary: GPUPool? { pools.first }

    /// "H200", "H200 + L40", "H200 + L40 + more" — one separator everywhere.
    public var modelLabel: String? {
        let names = pools.map(\.label)
        guard !names.isEmpty else {
            return nil
        }
        let named = names.prefix(2).joined(separator: " + ")
        return names.count > 2 ? named + " + more" : named
    }

    /// Pools with idle GPUs, for "where can I run" summaries.
    public var poolsWithIdle: [GPUPool] { pools.filter { $0.idle > 0 } }
}

// MARK: - Splitting helpers

func splitOutsideParentheses(_ text: String, separator: Character) -> [String] {
    var parts: [String] = []
    var current = ""
    var depth = 0
    for character in text {
        if character == "(" {
            depth += 1
        } else if character == ")" {
            depth = max(depth - 1, 0)
        }
        if character == separator && depth == 0 {
            parts.append(current)
            current = ""
        } else {
            current.append(character)
        }
    }
    if !current.isEmpty {
        parts.append(current)
    }
    return parts
}
