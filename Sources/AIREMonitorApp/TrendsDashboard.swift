import SwiftUI

/// One cluster's Trends tab, drawn from that cluster's own history. Each
/// cluster keeps a separate history file, so AIRE's L40S pool and Calder's
/// H200 pool are never blended into one series.
struct TrendsDashboard: View {
    let profile: ClusterProfile
    let history: [TrendPoint]
    /// Display name of the cluster's GPU model ("H200", "L40S") when the
    /// caller knows it, e.g. `session.gpuAvailability.model`. TrendPoint does
    /// not record the model, so without this the cards say plain "GPUs".
    var gpuModel: String? = nil

    private var recentHistory: [TrendPoint] {
        Array(history.suffix(240))
    }

    /// "H200 GPUs" when the model is known, otherwise "GPUs".
    private var gpuNoun: String {
        gpuModel.map { "\($0) GPUs" } ?? "GPUs"
    }

    private var flashValues: [Double] {
        recentHistory.compactMap(\.flashUsedPercent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(
                title: "Trends",
                subtitle: "Workload, GPU pressure, node health and storage drift on \(profile.displayName)",
                systemImage: "chart.xyaxis.line",
                accent: .indigo
            ) {
                InfoChip(label: "Points", value: "\(history.count)", systemImage: "clock.arrow.circlepath", color: .indigo)
            }

            if recentHistory.count < 2 {
                EmptyVisual(
                    title: "Building trend history",
                    subtitle: "The app records one local point after each \(profile.displayName) refresh. Charts become richer as the cache grows.",
                    systemImage: "chart.line.uptrend.xyaxis"
                )
            } else {
                trendHero
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 310, maximum: 460), spacing: 12)], spacing: 12) {
                    TrendChartCard(
                        title: "Free GPUs",
                        subtitle: "Unallocated \(gpuNoun) on \(profile.displayName)",
                        value: "\(recentHistory.last?.gpuIdle ?? 0)",
                        systemImage: "memorychip",
                        color: .green,
                        values: recentHistory.map { Double($0.gpuIdle) }
                    )
                    TrendChartCard(
                        title: "GPU Allocation",
                        subtitle: "Share of \(profile.displayName)'s \(gpuNoun) allocated",
                        value: "\(recentHistory.last?.gpuAllocated ?? 0)/\(recentHistory.last?.gpuTotal ?? 0)",
                        systemImage: "speedometer",
                        color: AppTheme.gpu,
                        values: recentHistory.map { gpuPercent($0) },
                        isPercentage: true
                    )
                    TrendChartCard(
                        title: "Queue Pressure",
                        subtitle: "Your running and pending jobs on \(profile.displayName)",
                        value: "\(recentHistory.last?.runningJobs ?? 0) run / \(recentHistory.last?.pendingJobs ?? 0) wait",
                        systemImage: "list.bullet.rectangle",
                        color: .blue,
                        values: recentHistory.map { Double($0.runningJobs + $0.pendingJobs) }
                    )
                    TrendChartCard(
                        title: "Unavailable GPU Nodes",
                        subtitle: "Nodes in down, drain, fail, or maintenance states",
                        value: "\(recentHistory.last?.unavailableGpuNodes ?? 0)",
                        systemImage: "exclamationmark.triangle",
                        color: .red,
                        values: recentHistory.map { Double($0.unavailableGpuNodes) }
                    )
                    // Storage series use the same kind colors and icons as the
                    // Storage tab, and generic wording: the actual mount point
                    // differs per cluster (and moves with Aire 2.0).
                    TrendChartCard(
                        title: "Home Usage",
                        subtitle: "Home quota · shared by all Leeds clusters",
                        value: percentText(recentHistory.last?.homeUsedPercent),
                        systemImage: StorageKind.home.systemImage,
                        color: StorageKind.home.color,
                        values: recentHistory.compactMap(\.homeUsedPercent),
                        isPercentage: true,
                        threshold: 90
                    )
                    TrendChartCard(
                        title: "Scratch Usage",
                        subtitle: "Scratch quota pressure on \(profile.displayName)",
                        value: percentText(recentHistory.last?.scratchUsedPercent),
                        systemImage: StorageKind.scratch.systemImage,
                        color: StorageKind.scratch.color,
                        values: recentHistory.compactMap(\.scratchUsedPercent),
                        isPercentage: true,
                        threshold: 90
                    )
                    // Flash is optional per cluster (no personal AIRE flash
                    // directory yet), so only chart it once points exist.
                    if !flashValues.isEmpty {
                        TrendChartCard(
                            title: "Flash Usage",
                            subtitle: "Flash quota pressure on \(profile.displayName)",
                            value: percentText(recentHistory.last?.flashUsedPercent),
                            systemImage: StorageKind.flash.systemImage,
                            color: StorageKind.flash.color,
                            values: flashValues,
                            isPercentage: true,
                            threshold: 90
                        )
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var trendHero: some View {
        let signal = CapacitySignal(latest: recentHistory.last)
        return HStack(spacing: 12) {
            InsightCard(
                title: "Capacity signal",
                value: signal.title,
                subtitle: "\(profile.displayName) GPU availability",
                color: signal.color,
                systemImage: "chart.line.uptrend.xyaxis",
                helpText: signal.explanation
            )
            InsightCard(
                title: "Last point",
                value: lastPointText,
                subtitle: "Local cache timestamp",
                color: .secondary,
                systemImage: "clock",
                helpText: recentHistory.last.map { SlurmTimestamp.absoluteText($0.collectedAt) }
            )
            InsightCard(
                title: "Window",
                value: "\(recentHistory.count)",
                subtitle: "recent refresh points",
                color: .indigo,
                systemImage: "point.3.connected.trianglepath.dotted"
            )
        }
    }

    private var lastPointText: String {
        guard let last = recentHistory.last else {
            return missingValuePlaceholder
        }
        return SlurmTimestamp.relativeText(last.collectedAt)
    }
}

/// One-word verdict on the latest point's GPU headroom.
///
/// "Room available" is relative to the pool: a fixed idle count tuned for
/// one cluster is generous on a small pool and stingy on a large one (AIRE's
/// L40S pool and Calder's 56 H200s differ in size and value per GPU).
private struct CapacitySignal {
    let title: String
    let color: Color
    let explanation: String

    /// Idle GPUs that count as room: 10% of the pool, but at least 2.
    static func roomThreshold(gpuTotal: Int) -> Int {
        max(2, Int((Double(gpuTotal) * 0.10).rounded(.up)))
    }

    init(latest: TrendPoint?) {
        guard let latest else {
            self.init(title: "Collecting", color: .secondary, explanation: "Waiting for the first refresh point.")
            return
        }
        guard latest.gpuTotal > 0 else {
            // A snapshot without GPU nodes (all filtered out, or none
            // configured) is "no data", not "GPU full".
            self.init(title: "No GPU data", color: .secondary, explanation: "The latest snapshot reported no GPU nodes.")
            return
        }
        let threshold = Self.roomThreshold(gpuTotal: latest.gpuTotal)
        let rule = "Room available means at least \(threshold) of \(latest.gpuTotal) GPUs idle (10% of the pool, minimum 2)."
        if latest.gpuIdle == 0 {
            self.init(title: "GPU full", color: .red, explanation: "Every GPU is allocated. \(rule)")
        } else if latest.pendingJobs > latest.runningJobs {
            self.init(
                title: "Queue building",
                color: .orange,
                explanation: "More of your jobs are pending than running. \(rule)"
            )
        } else if latest.gpuIdle >= threshold {
            self.init(title: "Room available", color: .green, explanation: "\(Self.idleText(latest.gpuIdle)). \(rule)")
        } else {
            self.init(title: "Tight capacity", color: .orange, explanation: "Only \(Self.idleText(latest.gpuIdle)). \(rule)")
        }
    }

    private static func idleText(_ idle: Int) -> String {
        idle == 1 ? "1 GPU idle" : "\(idle) GPUs idle"
    }

    private init(title: String, color: Color, explanation: String) {
        self.title = title
        self.color = color
        self.explanation = explanation
    }
}

func gpuPercent(_ point: TrendPoint) -> Double {
    guard point.gpuTotal > 0 else {
        return 0
    }
    return Double(point.gpuAllocated) / Double(point.gpuTotal) * 100
}
