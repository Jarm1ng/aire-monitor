import Foundation

// MARK: - GPU requests

/// GPUs a job holds or asked for, read from its Slurm TRES strings.
public struct JobGPURequest: Equatable, Sendable {
    /// GPUs for the whole job (per task for an array remainder); nil when
    /// Slurm names GPUs without a count.
    public let count: Int?
    /// Raw gres type, e.g. "nvidia_h200" or "l40s"; nil for an untyped
    /// request such as `--gres=gpu:2`.
    public let model: String?

    public init(count: Int?, model: String?) {
        self.count = count
        self.model = model
    }

    public var modelDisplayName: String? {
        model.map(gpuModelDisplayName)
    }

    /// "2 × H200", "1 GPU", "H200 GPU", or just "GPU".
    public var summary: String {
        switch (count, modelDisplayName) {
        case let (count?, model?):
            return "\(count) × \(model)"
        case let (count?, nil):
            return count == 1 ? "1 GPU" : "\(count) GPUs"
        case let (nil, model?):
            return "\(model) GPU"
        case (nil, nil):
            return "GPU"
        }
    }
}

extension Job {
    /// The job's GPUs, or nil when none of its TRES strings mention gres/gpu.
    ///
    /// Whole-job totals win: AllocTRES is what Slurm actually granted (a
    /// running job), ReqTRES what a pending job asked for. TresPerNode is per
    /// node, so it is only a fallback and is scaled by the node count.
    public var gpuRequest: JobGPURequest? {
        let allocated = TRESGPUTally(allocTres)
        let requested = TRESGPUTally(reqTres)
        let perNode = TRESGPUTally(tresPerNode)
        guard allocated.mentionsGPU || requested.mentionsGPU || perNode.mentionsGPU else {
            return nil
        }
        let nodeCount = max(Int(nodes.trimmingCharacters(in: .whitespaces)) ?? 1, 1)
        let count = allocated.count ?? requested.count ?? perNode.count.map { $0 * nodeCount }
        // An explicit zero ("gres/gpu=0") is a CPU job that merely names the gres.
        if count == 0 {
            return nil
        }
        return JobGPURequest(count: count, model: allocated.model ?? requested.model ?? perNode.model)
    }

    /// GPUs this row stands for in queue totals: per-task GPUs times the
    /// queued task count for an array remainder.
    public var requestedGPUCount: Int {
        guard let count = gpuRequest?.count else {
            return 0
        }
        return count * taskMultiplicity
    }
}

/// GPU entries found in one Slurm TRES string. Understands both shapes Slurm
/// prints:
/// - TRES lists (`ReqTRES`/`AllocTRES`): `cpu=8,gres/gpu=2,gres/gpu:nvidia_h200=2`
/// - per-node GRES (`TresPerNode`): `gres/gpu:nvidia_h200:2` (23.02+),
///   `gres:gpu:2` (21.08–22.05), or a bare `gpu:l40s:1` (older releases).
private struct TRESGPUTally {
    private(set) var mentionsGPU = false
    private(set) var model: String?
    private var untypedCount: Int?
    private var typedCount: Int?

    /// Slurm lists both the untyped total and the per-type split
    /// (`gres/gpu=2,gres/gpu:nvidia_h200=2`); the untyped total wins so the
    /// GPUs are not counted twice.
    var count: Int? {
        untypedCount ?? typedCount
    }

    init(_ raw: String?) {
        guard let raw else {
            return
        }
        for rawEntry in splitOutsideParentheses(raw, separator: ",") {
            var entry = rawEntry.trimmingCharacters(in: .whitespaces).lowercased()
            // Drop index suffixes such as "(IDX:0-1)".
            if let paren = entry.firstIndex(of: "(") {
                entry = String(entry[..<paren])
            }
            var key = entry
            var valueText: Substring?
            if let equals = entry.firstIndex(of: "=") {
                key = String(entry[..<equals])
                valueText = entry[entry.index(after: equals)...]
            }
            for prefix in ["gres/", "gres:"] where key.hasPrefix(prefix) {
                key = String(key.dropFirst(prefix.count))
                break
            }
            var pieces = key.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            // "gpumem"/"gpuutil" style TRES are not GPU counts.
            guard pieces.first == "gpu" else {
                continue
            }
            pieces.removeFirst()

            var entryCount: Int?
            if let valueText {
                entryCount = Int(valueText.prefix { $0.isNumber })
            } else if let last = pieces.last, let parsed = Int(last) {
                entryCount = parsed
                pieces.removeLast()
            }
            let entryModel = pieces.first { !$0.isEmpty }

            mentionsGPU = true
            if let entryModel {
                model = model ?? entryModel
                if let entryCount {
                    typedCount = (typedCount ?? 0) + entryCount
                }
            } else if let entryCount {
                untypedCount = (untypedCount ?? 0) + entryCount
            }
        }
    }
}

// MARK: - Job arrays

extension Job {
    /// The pending remainder of a job array: one squeue row standing for
    /// every task still queued. Cancelling it by id would cancel the WHOLE
    /// array, running tasks included.
    public var isArrayRemainder: Bool {
        arrayPendingTasks != nil && !jobId.contains("_")
    }

    /// How many jobs this row stands for in queue counts.
    public var taskMultiplicity: Int {
        isArrayRemainder ? max(pendingTaskCount ?? 1, 1) : 1
    }

    /// "8248307_[2-5]" for an array remainder, the plain id otherwise.
    public var displayJobID: String {
        if isArrayRemainder, let tasks = arrayPendingTasks, !tasks.isEmpty {
            return "\(jobId)_[\(tasks)]"
        }
        return jobId
    }
}

// MARK: - Display order

/// One job order for every surface (Jobs tab, overview, menu bar): running
/// first, then pending jobs that wait for resources or priority, then those
/// blocked on dependencies, then held, then anything else; ties by id in
/// natural order (9 before 10).
public func jobDisplayOrder(_ lhs: Job, _ rhs: Job) -> Bool {
    let left = jobDisplayRank(lhs)
    let right = jobDisplayRank(rhs)
    if left != right {
        return left < right
    }
    return lhs.jobId.localizedStandardCompare(rhs.jobId) == .orderedAscending
}

/// The group `jobDisplayOrder` sorts by first: 0 running, 1 pending on
/// resources or priority, 2 on a dependency, 3 held, 4 anything else. Public
/// so lists merged across clusters (whose job ids are not comparable) can
/// group the same way.
public func jobDisplayRank(_ job: Job) -> Int {
    let state = job.jobState
    if state.occupiesNodes {
        return 0
    }
    if state.isPending {
        let reason = job.reasonOrNodeList.lowercased()
        if reason.contains("held") || reason.contains("hold") {
            return 3
        }
        if reason.contains("dependency") {
            return 2
        }
        return 1
    }
    return 4
}

// MARK: - Node lists

/// Expands a compressed Slurm node list into concrete hostnames.
/// `gpu[001-004,007],cpu01` -> `["gpu001", "gpu002", "gpu003", "gpu004", "gpu007", "cpu01"]`.
/// Dashes outside the brackets are part of the name, so Calder's
/// `calder-h200-[01-03]` -> `["calder-h200-01", "calder-h200-02", "calder-h200-03"]`.
public func expandNodeList(_ compressed: String) -> [String] {
    let trimmed = compressed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.lowercased() != "(null)" else {
        return []
    }
    var result: [String] = []
    for token in splitOutsideBrackets(trimmed) {
        guard let open = token.firstIndex(of: "["),
              let close = token.lastIndex(of: "]"),
              open < close else {
            let name = token.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                result.append(name)
            }
            continue
        }
        let prefix = String(token[..<open])
        let suffix = String(token[token.index(after: close)...])
        let inner = token[token.index(after: open)..<close]
        for part in inner.split(separator: ",") {
            if let dash = part.firstIndex(of: "-") {
                let startText = part[..<dash]
                let endText = part[part.index(after: dash)...]
                if let start = Int(startText), let end = Int(endText), start <= end, end - start < 100_000 {
                    let width = startText.count
                    for value in start...end {
                        result.append(prefix + String(format: "%0\(width)d", value) + suffix)
                    }
                    continue
                }
            }
            result.append(prefix + String(part) + suffix)
        }
    }
    return result
}

/// Set of nodes running the given jobs, built from exact expanded hostnames.
/// Never substring-matches, so `gpu1` can not collide with `gpu10`.
/// Hostnames are only unique within one cluster: pass a single cluster's
/// jobs and test the result only against that cluster's nodes.
public func busyNodeSet(for jobs: [Job]) -> Set<String> {
    var nodes = Set<String>()
    for job in jobs where job.jobState.occupiesNodes {
        if let list = job.nodeList, !list.isEmpty {
            nodes.formUnion(expandNodeList(list))
        } else if job.jobState.isRunning {
            // For running jobs squeue's %R column is the node list.
            nodes.formUnion(expandNodeList(job.reasonOrNodeList))
        }
    }
    return nodes
}

private func splitOutsideBrackets(_ text: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var depth = 0
    for character in text {
        if character == "[" {
            depth += 1
        } else if character == "]" {
            depth = max(depth - 1, 0)
        }
        if character == "," && depth == 0 {
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
