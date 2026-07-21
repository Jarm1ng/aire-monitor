import SwiftUI

struct TrendsDashboard: View {
    let history: [TrendPoint]
    let snapshot: ClusterSnapshot?

    private var recentHistory: [TrendPoint] {
        Array(history.suffix(240))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(
                title: "Trends",
                subtitle: "Historical workload, GPU pressure, node health, and storage drift",
                systemImage: "chart.xyaxis.line",
                accent: .indigo
            ) {
                InfoChip(label: "Points", value: "\(history.count)", systemImage: "clock.arrow.circlepath", color: .indigo)
            }

            if recentHistory.count < 2 {
                EmptyVisual(
                    title: "Building trend history",
                    subtitle: "The app records one local point after each refresh. Charts become richer as the cache grows.",
                    systemImage: "chart.line.uptrend.xyaxis"
                )
            } else {
                trendHero
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 310, maximum: 460), spacing: 12)], spacing: 12) {
                    TrendChartCard(
                        title: "Free GPUs",
                        subtitle: "Capacity available for new training jobs",
                        value: "\(recentHistory.last?.gpuIdle ?? 0)",
                        systemImage: "memorychip",
                        color: .green,
                        values: recentHistory.map { Double($0.gpuIdle) }
                    )
                    TrendChartCard(
                        title: "GPU Allocation",
                        subtitle: "Allocated GPUs across training nodes",
                        value: "\(recentHistory.last?.gpuAllocated ?? 0)/\(recentHistory.last?.gpuTotal ?? 0)",
                        systemImage: "gauge.with.dots.needle.67percent",
                        color: AIRETheme.gpu,
                        values: recentHistory.map { gpuPercent($0) },
                        isPercentage: true
                    )
                    TrendChartCard(
                        title: "Queue Pressure",
                        subtitle: "Running and pending jobs for the current user",
                        value: "\(recentHistory.last?.runningJobs ?? 0) run / \(recentHistory.last?.pendingJobs ?? 0) wait",
                        systemImage: "list.bullet.rectangle",
                        color: .orange,
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
                    TrendChartCard(
                        title: "Home Usage",
                        subtitle: "Quota pressure under /users",
                        value: percentText(recentHistory.last?.homeUsedPercent),
                        systemImage: "house",
                        color: .purple,
                        values: recentHistory.compactMap(\.homeUsedPercent),
                        isPercentage: true,
                        threshold: 90
                    )
                    TrendChartCard(
                        title: "Scratch Usage",
                        subtitle: "Quota pressure under /mnt/scratch",
                        value: percentText(recentHistory.last?.scratchUsedPercent),
                        systemImage: "externaldrive",
                        color: .teal,
                        values: recentHistory.compactMap(\.scratchUsedPercent),
                        isPercentage: true,
                        threshold: 90
                    )
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var trendHero: some View {
        HStack(spacing: 12) {
            InsightCard(
                title: "Best signal",
                value: trendSignal,
                subtitle: "Based on recent GPU availability",
                color: trendSignalColor,
                systemImage: "sparkline"
            )
            InsightCard(
                title: "Last point",
                value: lastPointText,
                subtitle: "Local cache timestamp",
                color: .secondary,
                systemImage: "clock",
                helpText: recentHistory.last.map { AIRETimestamp.absoluteText($0.collectedAt) }
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
        return AIRETimestamp.relativeText(last.collectedAt)
    }

    private var trendSignal: String {
        guard let last = recentHistory.last else {
            return "Collecting"
        }
        if last.gpuIdle == 0 {
            return "GPU full"
        }
        if last.pendingJobs > last.runningJobs {
            return "Queue building"
        }
        if last.gpuIdle >= 8 {
            return "Room available"
        }
        return "Tight capacity"
    }

    private var trendSignalColor: Color {
        guard let last = recentHistory.last else {
            return .secondary
        }
        if last.gpuIdle == 0 {
            return .red
        }
        if last.gpuIdle >= 8 {
            return .green
        }
        return .orange
    }
}

func gpuPercent(_ point: TrendPoint) -> Double {
    guard point.gpuTotal > 0 else {
        return 0
    }
    return Double(point.gpuAllocated) / Double(point.gpuTotal) * 100
}
