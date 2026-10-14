import HPCCore
import SwiftUI

/// One cluster's Trends tab, drawn from that cluster's own history. Each
/// cluster keeps a separate history file, so AIRE's L40S pool and Calder's
/// H200 pool are never blended into one series. Charts plot against time
/// over a window shared with the Storage tab.
struct TrendsDashboard: View {
    let profile: ClusterProfile
    let history: [TrendPoint]
    /// The current snapshot's GPU pools. When given, the capacity signal is
    /// judged per model (an idle L40 is no help to an H200 job) instead of
    /// from the history's all-model totals, and the GPU cards name the
    /// models ("H200 + L40 GPUs"): TrendPoint does not record them, so
    /// without a fleet the cards say plain "GPUs".
    var gpuFleet: GPUFleet? = nil
    /// The current snapshot's storage, so the storage cards use the same
    /// tone (space, file count and over-quota) as the Storage tab.
    var storage: [StorageSummary] = []
    /// Monitoring is paused: the last point is not going to move.
    var isPaused = false
    /// The current snapshot's queue (`JobQueueCounts(jobs:)`), so the
    /// Queue pressure headline names held jobs apart from pending ones, as
    /// every other surface does. History points only record running and
    /// queued (pending + held), so without it the headline says "queued".
    var queueCounts: JobQueueCounts? = nil

    @AppStorage(TrendWindow.storageKey) private var window: TrendWindow = .hour

    /// "H200 + L40 GPUs" when the model is known, otherwise "GPUs".
    private var gpuNoun: String {
        gpuFleet?.modelLabel.map { "\($0) GPUs" } ?? "GPUs"
    }

    var body: some View {
        let timeline = TrendTimeline.cached(for: history)
        let slice = timeline.slice(window)

        VStack(alignment: .leading, spacing: 14) {
            PageHeader(
                title: "Trends",
                subtitle: "Workload, GPU pressure, node health and storage drift on \(profile.displayName)",
                systemImage: "chart.xyaxis.line",
                accent: .indigo
            ) {
                TrendWindowPicker(window: $window)
            }

            if timeline.points.count < 2 {
                EmptyVisual(
                    title: "Building trend history",
                    subtitle: "The app records one local point after each \(profile.displayName) refresh. Charts become richer as the cache grows.",
                    systemImage: "chart.line.uptrend.xyaxis"
                )
            } else {
                trendHero(timeline: timeline, slice: slice)
                // Headline values are the newest point overall (the current
                // state); the charts show the selected window.
                let latest = timeline.points.last
                // Two columns even in the narrowest detail column: at a
                // 310 pt minimum one 460 pt column sat centred there with
                // empty margins on both sides.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 290, maximum: 460), spacing: 12, alignment: .top)], spacing: 12) {
                    gpuCards(slice, latest: latest)
                    storageCards(slice, latest: latest)
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: Cards

    @ViewBuilder
    private func gpuCards(_ slice: TrendSlice, latest: TrendPoint?) -> some View {
        TimeTrendCard(
            title: "Idle GPUs",
            subtitle: "Idle \(gpuNoun) on nodes that can start work on \(profile.displayName)",
            value: TrendGPUText.idleValue(latest),
            systemImage: "memorychip",
            color: .green,
            series: slice.series(gpuIdleCount),
            help: TrendGPUText.idleHelp(latest)
        )
        TimeTrendCard(
            title: "GPU allocation",
            subtitle: "Share of \(profile.displayName)'s \(gpuNoun) allocated",
            value: TrendGPUText.allocationValue(latest),
            systemImage: "speedometer",
            color: AppTheme.gpu,
            series: slice.series(gpuPercent),
            isPercentage: true,
            help: TrendGPUText.allocationHelp(latest, noun: gpuNoun)
        )
        TimeTrendCard(
            title: "Queue pressure",
            subtitle: TrendQueueText.subtitle(clusterName: profile.displayName),
            value: TrendQueueText.value(latest, counts: queueCounts),
            systemImage: "list.bullet.rectangle",
            color: .blue,
            series: slice.series { Double($0.runningJobs + $0.pendingJobs) },
            help: TrendQueueText.help(hasCounts: queueCounts != nil)
        )
        TimeTrendCard(
            title: "Unavailable GPU nodes",
            subtitle: "GPU nodes that accept no work: down, drained, failing, reserved or not responding",
            value: latest.map { pluralized($0.unavailableGpuNodes, "node") } ?? missingValuePlaceholder,
            systemImage: "exclamationmark.triangle",
            color: StatusTone.unavailable.color,
            series: slice.series { Double($0.unavailableGpuNodes) }
        )
    }

    /// Storage series, coloured by the latest status tone, judged like the
    /// Storage tab (space, file count, over quota) from the current snapshot
    /// when available, else from the latest point's space usage.
    @ViewBuilder
    private func storageCards(_ slice: TrendSlice, latest: TrendPoint?) -> some View {
        storageCard(
            kind: .home,
            title: "Home usage",
            subtitle: "Home quota · shared by all Leeds clusters",
            latest: latest?.homeUsedPercent,
            series: slice.series(\.homeUsedPercent)
        )
        storageCard(
            kind: .scratch,
            title: "Scratch usage",
            subtitle: "Scratch quota pressure on \(profile.displayName)",
            latest: latest?.scratchUsedPercent,
            series: slice.series(\.scratchUsedPercent)
        )
        // Flash is optional per cluster (no personal AIRE flash directory
        // yet), so only chart it once points exist.
        let flash = slice.series(\.flashUsedPercent)
        if !flash.isEmpty || latest?.flashUsedPercent != nil {
            storageCard(
                kind: .flash,
                title: "Flash usage",
                subtitle: "Flash quota pressure on \(profile.displayName)",
                latest: latest?.flashUsedPercent,
                series: flash
            )
        }
    }

    private func storageCard(kind: StorageKind, title: String, subtitle: String, latest: Double?, series: TrendSeries) -> some View {
        let space = storage.first { $0.kind == kind }
        let tone = space?.usageTone ?? StatusTone(usedPercent: latest)
        var value = percentText(latest)
        if let space, space.overQuota == true {
            value = "over quota"
        } else if let space, space.fileCountDominates, let files = space.fileUsedPercent {
            value = "\(percentText(files)) files"
        }
        return TimeTrendCard(
            title: title,
            subtitle: subtitle,
            value: value,
            systemImage: kind.systemImage,
            // Status colour, as on the Storage tab: a kind colour such as
            // Flash's must never read as a warning.
            color: tone.color,
            series: series,
            isPercentage: true,
            thresholds: storageThresholds,
            valueColor: tone == .normal ? .primary : tone.color,
            help: "Warning from 75 %, critical from 90 % of the limit (space or file count, whichever is closer)."
        )
    }

    // MARK: Hero

    private func trendHero(timeline: TrendTimeline, slice: TrendSlice) -> some View {
        let signal = gpuFleet.map(CapacitySignal.init(fleet:)) ?? CapacitySignal(latest: timeline.points.last)
        return HStack(spacing: 12) {
            InsightCard(
                title: "Capacity signal",
                value: signal.title,
                subtitle: signal.subtitle(clusterName: profile.displayName),
                color: signal.tone.color,
                systemImage: "chart.line.uptrend.xyaxis",
                helpText: signal.explanation
            )
            // Ticks on its own: while paused or offline nothing else
            // re-renders this tab, and "just now" would stand for hours.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                InsightCard(
                    title: "Last point",
                    value: timeline.points.last.map { SlurmTimestamp.relativeText($0.collectedAt, reference: context.date) } ?? missingValuePlaceholder,
                    subtitle: isPaused ? "Local cache timestamp · paused" : "Local cache timestamp",
                    color: isPaused ? .orange : .secondary,
                    systemImage: isPaused ? "pause.circle" : "clock",
                    helpText: timeline.points.last.map { SlurmTimestamp.absoluteText($0.collectedAt) }
                )
            }
            InsightCard(
                title: "Covered",
                value: slice.isEmpty ? "no data" : spanText(slice.coveredSpan),
                subtitle: coverageSubtitle(slice),
                color: .indigo,
                systemImage: "point.3.connected.trianglepath.dotted",
                helpText: "\(pluralized(slice.count, "point")) in \(window.phrase); the cache keeps \(pluralized(timeline.points.count, "point")) in all."
            )
        }
    }

    /// "of the last hour · no gaps", "of the last 6 hours · 2 gaps"; just
    /// "in the last hour" for an empty window, where "no gaps" would read
    /// as complete coverage. `gapCount` also counts an outage before the
    /// window's first point and the silence after the last once points
    /// stopped, so 1 minute of data after a 58-minute outage says "1 gap".
    private func coverageSubtitle(_ slice: TrendSlice) -> String {
        guard !slice.isEmpty else {
            return "in \(window.phrase)"
        }
        let gaps = slice.gapCount
        let gapText = gaps == 0 ? "no gaps" : pluralized(gaps, "gap")
        return "of \(window.phrase) · \(gapText)"
    }
}

/// One-word verdict on GPU headroom, from cluster GPU state only — never
/// from the user's own queue, whose dependency-held or CPU jobs say nothing
/// about free GPUs.
///
/// "Room available" is relative to the pool: a fixed idle count tuned for
/// one cluster is generous on a small pool and stingy on a large one (AIRE's
/// L40S pool and Calder's 56 H200s differ in size and value per GPU). Each
/// GPU model is judged on its own, and the verdict names the pool it is
/// about.
struct CapacitySignal: Equatable {
    /// Ordered by how soon a job could start, for picking the headline
    /// pool: a pool whose allocation is unknown ranks above a full one (it
    /// may have room) and below a tight one (which has known idle GPUs).
    enum Verdict: Int, Comparable {
        case noData
        case unavailable
        case full
        /// Unknown allocation could tip the verdict either way (node details
        /// missing): never reported as full, tight or room.
        case unknown
        case tight
        case room

        static func < (lhs: Verdict, rhs: Verdict) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var title: String {
            switch self {
            case .noData: return "No GPU data"
            case .unavailable: return "GPUs unavailable"
            case .full: return "GPU full"
            case .unknown: return "Allocation unknown"
            case .tight: return "Tight capacity"
            case .room: return "Room available"
            }
        }

        /// Lower-case phrase for the per-pool tooltip lines.
        var phrase: String {
            switch self {
            case .noData: return "no data"
            case .unavailable: return "no node accepting work"
            case .full: return "full"
            case .unknown: return "cannot be judged"
            case .tight: return "tight"
            case .room: return "room available"
            }
        }

        /// The shared GPU pool tones: idle GPUs green; a pool known to be
        /// full is a warning (orange, like its "0 of 56 H200 idle" header
        /// chip), never red, which is kept for faults and critical storage;
        /// grey when nothing can be judged or no node accepts work.
        var tone: StatusTone {
            switch self {
            case .room: return .normal
            case .tight, .full: return .warning
            case .unknown, .unavailable, .noData: return .unavailable
            }
        }
    }

    let verdict: Verdict
    /// The pool the verdict describes ("H200"); nil for an unnamed pool or
    /// the all-model history fallback.
    let poolLabel: String?
    let explanation: String

    var title: String { verdict.title }
    var tone: StatusTone { verdict.tone }

    func subtitle(clusterName: String) -> String {
        if let poolLabel {
            return "\(poolLabel) on \(clusterName)"
        }
        return "\(clusterName) GPU availability"
    }

    /// Idle GPUs that count as room: 10% of the pool, but at least 2.
    static func roomThreshold(gpuTotal: Int) -> Int {
        max(2, Int((Double(gpuTotal) * 0.10).rounded(.up)))
    }

    /// `unknown` GPUs (allocation not reported) may be idle or allocated,
    /// so a verdict stands only when it holds either way: with every
    /// unknown GPU idle (`idle + unknown`) and with none of them idle
    /// (`idle`). Otherwise it is `.unknown` — in particular never "GPU full"
    /// merely because nothing is KNOWN to be idle.
    static func verdict(idle: Int, total: Int, unknown: Int, allNodesUnavailable: Bool) -> Verdict {
        guard total > 0 else {
            return .noData
        }
        if allNodesUnavailable {
            return .unavailable
        }
        let known = judged(idle: idle, total: total)
        if unknown > 0, judged(idle: idle + unknown, total: total) != known {
            return .unknown
        }
        return known
    }

    private static func judged(idle: Int, total: Int) -> Verdict {
        if idle == 0 {
            return .full
        }
        return idle >= roomThreshold(gpuTotal: total) ? .room : .tight
    }

    /// Per-model verdicts from the current snapshot; the headline is the
    /// best pool (where a job could start soonest), and the tooltip lists
    /// every pool.
    init(fleet: GPUFleet) {
        guard !fleet.isEmpty else {
            self.init(verdict: .noData, poolLabel: nil, explanation: "The latest snapshot reported no GPU nodes.")
            return
        }
        var best: (verdict: Verdict, pool: GPUPool)?
        var lines: [String] = []
        for pool in fleet.pools {
            let verdict = Self.verdict(
                idle: pool.idle,
                total: pool.total,
                unknown: pool.unknown,
                allNodesUnavailable: pool.unavailableNodes == pool.nodeCount
            )
            let threshold = Self.roomThreshold(gpuTotal: pool.total)
            var line = "\(pool.label): \(pool.idle) of \(pool.total) idle and startable — \(verdict.phrase) (room means at least \(threshold))"
            if pool.stranded > 0 {
                line += "; \(pool.stranded) more idle on nodes whose CPUs are full"
            }
            if pool.unknown > 0 {
                line += "; \(pool.unknown) with unknown allocation"
            }
            lines.append(line + ".")
            if let current = best, current.verdict >= verdict {
                continue
            }
            best = (verdict, pool)
        }
        let rule = "Room available means at least 10% of a model's GPUs idle on nodes that can start work (minimum 2)."
        self.init(
            verdict: best?.verdict ?? .noData,
            poolLabel: fleet.pools.count > 1 || best?.pool.model != nil ? best?.pool.label : nil,
            explanation: (lines + [rule]).joined(separator: "\n")
        )
    }

    /// Fallback from the latest history point (all models together).
    init(latest: TrendPoint?) {
        guard let latest else {
            self.init(verdict: .noData, poolLabel: nil, explanation: "Waiting for the first refresh point.")
            return
        }
        guard latest.gpuTotal > 0 else {
            // A snapshot without GPU nodes (all filtered out, or none
            // configured) is "no data", not "GPU full".
            self.init(verdict: .noData, poolLabel: nil, explanation: "The latest snapshot reported no GPU nodes.")
            return
        }
        let threshold = Self.roomThreshold(gpuTotal: latest.gpuTotal)
        let unknown = latest.gpuUnknown ?? 0
        let verdict = Self.verdict(idle: latest.gpuIdle, total: latest.gpuTotal, unknown: unknown, allNodesUnavailable: false)
        let idle = latest.gpuIdle == 1 ? "1 GPU idle" : "\(latest.gpuIdle) GPUs idle"
        var explanation = "\(idle) on nodes that can start work. Room available means at least \(threshold) of \(latest.gpuTotal) GPUs idle (10% of the pool, minimum 2)."
        if unknown > 0 {
            explanation += " Allocation unknown for \(pluralized(unknown, "GPU")): node details were missing, so they count neither as idle nor as allocated."
        }
        self.init(verdict: verdict, poolLabel: nil, explanation: explanation)
    }

    private init(verdict: Verdict, poolLabel: String?, explanation: String) {
        self.verdict = verdict
        self.poolLabel = poolLabel
        self.explanation = explanation
    }
}

/// Share of the GPUs allocated at one point, for the allocation chart; nil
/// (a gap) without GPUs or when any GPU's allocation was unknown. Those
/// GPUs count in `gpuTotal` but are neither allocated nor idle, so any
/// share drawn for the point would invent a dip — down to 0 % when node
/// details failed outright.
func gpuPercent(_ point: TrendPoint) -> Double? {
    guard point.gpuTotal > 0, (point.gpuUnknown ?? 0) == 0 else {
        return nil
    }
    return Double(point.gpuAllocated) / Double(point.gpuTotal) * 100
}

/// Startable idle GPUs at one point, for the idle chart; nil (a gap) when
/// any GPU's allocation was unknown: `gpuIdle` then counts only the GPUs
/// known to be idle, and a line through it would read as GPUs filling up.
func gpuIdleCount(_ point: TrendPoint) -> Double? {
    guard (point.gpuUnknown ?? 0) == 0 else {
        return nil
    }
    return Double(point.gpuIdle)
}

/// Wording of the Trends Queue pressure card. "Pending" never includes held
/// jobs (HPCCore `JobQueueCounts`): with the current snapshot's counts the
/// headline reads "9 running · 1 pending · 11 held", like the overview,
/// sidebar and menu bar. A history point records only running and queued
/// (pending + held together), so the fallback calls that figure "queued"
/// rather than mislabelling held jobs as pending.
enum TrendQueueText {
    static func value(_ point: TrendPoint?, counts: JobQueueCounts?) -> String {
        if let counts {
            return counts.summary
        }
        guard let point else {
            return missingValuePlaceholder
        }
        return "\(point.runningJobs) running · \(point.pendingJobs) queued"
    }

    static func subtitle(clusterName: String) -> String {
        "Your running and queued jobs on \(clusterName), held ones included (array tasks counted individually)"
    }

    static func help(hasCounts: Bool) -> String {
        let line = "The line counts every job you have running or queued, held jobs included."
        return hasCounts
            ? line + " Held jobs will not start until released, so the headline names them apart from pending ones."
            : line + " \"Queued\" is pending and held together: held jobs will not start until released."
    }
}

/// Headline wording of the Trends GPU cards for the newest point. A point
/// with unknown allocation never states a figure it does not have: no
/// allocation share at all, and idle GPUs only as a lower bound.
enum TrendGPUText {
    static func idleValue(_ point: TrendPoint?) -> String {
        guard let point else {
            return missingValuePlaceholder
        }
        guard (point.gpuUnknown ?? 0) > 0 else {
            return "\(point.gpuIdle) idle"
        }
        return point.gpuIdle > 0 ? "at least \(point.gpuIdle) idle" : "unknown"
    }

    static func idleHelp(_ point: TrendPoint?) -> String {
        var text = "Startable GPUs only: idle GPUs on drained or down nodes, or on nodes whose CPUs are all taken, are not counted."
        if let unknown = point?.gpuUnknown, unknown > 0 {
            text += " Allocation unknown for \(pluralized(unknown, "GPU")) at the latest point (node details were missing); points like it are left out of the chart."
        }
        return text
    }

    static func allocationValue(_ point: TrendPoint?) -> String {
        guard let point else {
            return missingValuePlaceholder
        }
        guard (point.gpuUnknown ?? 0) == 0 else {
            return "unknown"
        }
        return "\(point.gpuAllocated) of \(point.gpuTotal)"
    }

    static func allocationHelp(_ point: TrendPoint?, noun: String) -> String? {
        guard let point else {
            return nil
        }
        if let unknown = point.gpuUnknown, unknown > 0 {
            return "Allocation unknown for \(unknown) of \(point.gpuTotal) \(noun) at the latest point (node details were missing), so no share is shown; points like it are left out of the chart. \(point.gpuAllocated) known to be allocated."
        }
        return "\(point.gpuAllocated) of \(point.gpuTotal) \(noun) allocated at the latest point"
    }
}
