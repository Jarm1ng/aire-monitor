import Foundation

// Counting and wording shared by the overview, the sidebar and the cluster
// header. Kept in HPCCore (Foundation only) so the menu bar and the widget
// can phrase the same figures the same way, and so the rules are unit-tested
// without a UI.

// MARK: - Job queue counts

/// How many of the user's jobs are in each queue state. An array's pending
/// remainder counts as every task it stands for (`taskMultiplicity`), so a
/// 58-task backlog reads as 58 waiting jobs, as `squeue -r` would show.
public struct JobQueueCounts: Equatable, Sendable {
    /// Running, completing or still configuring: holding nodes now.
    public var running = 0
    /// Waiting for resources, priority or a dependency.
    public var pending = 0
    /// Waiting but held (`Job.isHeld`); will not start until released.
    public var held = 0
    /// Suspended, finished or a state this build does not know.
    public var other = 0

    public init() {}

    public init(running: Int = 0, pending: Int = 0, held: Int = 0, other: Int = 0) {
        self.running = running
        self.pending = pending
        self.held = held
        self.other = other
    }

    public init(jobs: [Job]) {
        for job in jobs {
            let weight = job.taskMultiplicity
            let state = job.jobState
            if state.occupiesNodes {
                running += weight
            } else if job.isHeld {
                held += weight
            } else if state.isPending {
                pending += weight
            } else {
                other += weight
            }
        }
    }

    /// Everything still queued, held jobs included.
    public var waiting: Int { pending + held }
    public var total: Int { running + pending + held + other }

    /// "1 running · 13 pending · 2 held" — zero parts other than running are
    /// left out so the line stays short.
    public var summary: String {
        summary(otherLabel: "other")
    }
}

// MARK: - GPU pool wording

extension GPUPool {
    /// "1 of 84 L40S idle", "0 of 4 GPUs idle" — the one notation for idle
    /// capacity everywhere: an explicit verb, never a bare "x/84" whose
    /// numerator could mean idle in one place and allocated in another.
    public var idleSummary: String {
        if let model {
            return "\(idle) of \(total) \(model) idle"
        }
        return "\(idle) of \(total) GPU\(total == 1 ? "" : "s") idle"
    }

    /// "77 in use · 1 stranded · 6 unavailable". Zero parts are left out,
    /// except "in use", so the line never comes out empty — unless GPUs of
    /// unknown allocation stand in for it: "6 unavailable · 78 unknown",
    /// never a definite "0 in use" for GPUs nobody reported on (as
    /// `inUseCaption`).
    public var breakdownSummary: String {
        var parts: [String] = []
        if allocated > 0 || unknown == 0 {
            parts.append("\(allocated) in use")
        }
        if stranded > 0 {
            parts.append("\(stranded) stranded")
        }
        if unavailable > 0 {
            parts.append("\(unavailable) unavailable")
        }
        if unknown > 0 {
            parts.append("\(unknown) unknown")
        }
        return parts.joined(separator: " · ")
    }

    /// Nothing is known to be idle, but only because the allocation of some
    /// GPUs is unknown (node details missing): that is not a full pool.
    public var idleIsUnknown: Bool {
        idle == 0 && unknown > 0
    }

    /// The idle count as a figure: "?" while `idleIsUnknown`, as on the
    /// node cards ("? of 8"), since a bare "0" would claim a full pool.
    /// With some GPUs known idle the count stands — a floor, and the
    /// caption beside it names the unknown ones.
    public var idleFigure: String {
        idleIsUnknown ? "?" : "\(idle)"
    }

    /// `idleSummary` with `idleFigure` in it: "? of 84 L40S idle" while
    /// `idleIsUnknown`, so a glance at the sidebar row never reads "0 of
    /// 84 L40S idle" — a full pool — when only the node details are
    /// missing. Otherwise exactly `idleSummary`.
    public var idleFigureSummary: String {
        guard idleIsUnknown else {
            return idleSummary
        }
        if let model {
            return "? of \(total) \(model) idle"
        }
        return "? of \(total) GPU\(total == 1 ? "" : "s") idle"
    }

    /// `idleSummary` for VoiceOver, without the "0 idle" a pool of unknown
    /// allocation does not have.
    public var idleSpokenSummary: String {
        guard idleIsUnknown else {
            return idleSummary
        }
        return "idle \(label) GPUs unknown: allocation unknown for \(unknown) of \(total)"
    }

    /// "12 in use", or with unknown allocation "12 in use · 40 unknown" /
    /// "56 unknown": a bare "0 in use" would claim an empty pool for GPUs
    /// nobody reported on (the mirror of `idleFigure`'s "?").
    public var inUseCaption: String {
        guard unknown > 0 else {
            return "\(allocated) in use"
        }
        return allocated == 0 ? "\(unknown) unknown" : "\(allocated) in use · \(unknown) unknown"
    }

    /// Every node of the pool accepts no new work (down, drained,
    /// maintenance): nothing of this model can start, whatever the counts.
    public var isWhollyUnavailable: Bool {
        nodeCount > 0 && unavailableNodes == nodeCount
    }

    /// The line under a pool's idle figure, wherever one is shown (the
    /// overview tile and its per-model rows, the menu bar row): every GPU
    /// that is not idle, by why — `breakdownSummary` — so a pool's
    /// stranded and unavailable GPUs never hide in a tooltip. A pool none
    /// of whose nodes accept work reads "all 3 unavailable" instead of
    /// "0 in use · 3 unavailable"; if jobs still run on its draining nodes,
    /// the breakdown names them.
    public var capacityCaption: String {
        if isWhollyUnavailable, allocated == 0, unknown == 0 {
            return "all \(total) unavailable"
        }
        return breakdownSummary
    }

    /// The one status tone of a pool's idle capacity, on every surface
    /// (overview tile, cluster header chip, menu bar row, Trends): green
    /// (`.normal`) while some GPU can start a job now; orange (`.warning`)
    /// when the pool is known to be full — a busy pool, not a fault, so
    /// never red; grey (`.unavailable`) when nothing can start there
    /// because every node is out of service, or while `idleIsUnknown`
    /// (shown as "?"). Red stays for faults and critical storage.
    public var idleTone: StatusTone {
        if total == 0 || isWhollyUnavailable || idleIsUnknown {
            return .unavailable
        }
        return idle > 0 ? .normal : .warning
    }

    /// Plain-language explanation of every figure, for tooltips and
    /// VoiceOver. Stranded and unknown are the two that need words.
    public var breakdownHelp: String {
        var lines = ["\(label): \(idleFigureSummary) — idle on nodes that can start a job now."]
        lines.append("\(allocated) allocated to running jobs.")
        if stranded > 0 {
            lines.append("\(stranded) stranded: idle, but every CPU on their node is taken, so no job can start there.")
        }
        if unavailable > 0 {
            lines.append("\(unavailable) unavailable: on nodes that accept no work (down, drained, maintenance or not responding).")
        }
        if unknown > 0 {
            lines.append("\(unknown) unknown: the collector had no allocation details for their nodes, so they are not counted as idle.")
        }
        if !partitions.isEmpty {
            lines.append("Partitions: \(partitions.joined(separator: ", ")).")
        }
        return lines.joined(separator: "\n")
    }
}

extension GPUFleet {
    /// One idle phrase per pool, largest first, e.g.
    /// "1 of 56 H200 idle · 0 of 3 L40 idle"; past `limit` pools the rest
    /// collapse to "+N more". Nil for a cluster without GPUs.
    public func idleSummary(limit: Int = Int.max) -> String? {
        guard !pools.isEmpty else {
            return nil
        }
        let shown = pools.prefix(max(limit, 1)).map(\.idleSummary)
        let hidden = pools.count - shown.count
        let joined = shown.joined(separator: " · ")
        return hidden > 0 ? "\(joined) · +\(hidden) more" : joined
    }

    /// The largest pool's idle phrase, then how many other models there
    /// are: "0 of 56 H200 idle · +1 more model". "+1" straight after
    /// "idle" would read as one more idle GPU. The phrase is the pool's
    /// `idleFigureSummary` ("? of 84 L40S idle" while its allocation is
    /// unknown). An idle L40 is not an idle H200, so pools are never
    /// summed. Nil for a cluster without GPUs.
    public var primaryIdleText: String? {
        guard let primary = pools.first else {
            return nil
        }
        let others = pools.count - 1
        guard others > 0 else {
            return primary.idleFigureSummary
        }
        return "\(primary.idleFigureSummary) · +\(others) more model\(others == 1 ? "" : "s")"
    }

    /// `primaryIdleText` for VoiceOver: no "?" or "+" to read out.
    public var primaryIdleSpokenText: String? {
        guard let primary = pools.first else {
            return nil
        }
        let others = pools.count - 1
        guard others > 0 else {
            return primary.idleSpokenSummary
        }
        return "\(primary.idleSpokenSummary), and \(others) more GPU model\(others == 1 ? "" : "s")"
    }
}

// MARK: - Job queue wording

extension JobQueueCounts {
    /// `summary` with the "other" part named as the caller knows it, e.g.
    /// "1 running · 6 pending · 1 suspended" when every other job is
    /// suspended. Held jobs are never part of "pending": they will not
    /// start until released, so they are always named on their own.
    public func summary(otherLabel: String) -> String {
        var parts = ["\(running) running"]
        if pending > 0 || (held == 0 && other == 0) {
            parts.append("\(pending) pending")
        }
        if held > 0 {
            parts.append("\(held) held")
        }
        if other > 0 {
            parts.append("\(other) \(otherLabel)")
        }
        return parts.joined(separator: " · ")
    }
}
