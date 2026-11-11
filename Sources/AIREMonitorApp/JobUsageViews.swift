import Charts
import HPCCore
import SwiftUI

// MARK: - Jobs page: "Resource use"

/// What each running job is using, sampled on its nodes about once a minute:
/// GPU utilisation and memory, CPUs busy against CPUs allocated, and memory
/// against the job's limit — with a verdict, so an under-used allocation
/// stands out at a glance.
struct JobUsagePanel: View {
    let rows: [JobRow]
    let usage: [String: JobUsageSummary]
    let history: JobUsageHistory
    @Binding var isSampling: Bool
    var onSelect: (Job) -> Void

    private var running: [JobRow] {
        rows.filter { $0.state.occupiesNodes && !$0.job.isArrayRemainder }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(
                    title: "Resource use",
                    subtitle: isSampling
                        ? "Sampled on the compute nodes about once a minute"
                        : "Sampling is off"
                )
                Spacer(minLength: 8)
                Toggle("Sample", isOn: $isSampling)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Once a minute, while a job of yours runs, the login node reaches its nodes over ssh (allowed only where you have a job) and reads nvidia-smi and the job's cgroup counters. Read-only: no job steps, nothing written; nvidia-smi runs for about a second inside the job's allocation.")
            }
            if running.isEmpty {
                Text("No running jobs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isSampling || !usage.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 460), spacing: 10, alignment: .top)], spacing: 10) {
                    ForEach(running) { row in
                        Button {
                            onSelect(row.job)
                        } label: {
                            JobUsageCard(
                                row: row,
                                summary: usage[row.job.jobId],
                                series: history.series(for: row.job.jobId)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens job details")
                    }
                }
            }
        }
    }
}

/// One running job's usage: a verdict line, four meters and the GPU trend.
struct JobUsageCard: View {
    let row: JobRow
    let summary: JobUsageSummary?
    let series: [JobUsagePoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(row.job.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.job.displayJobID)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let summary {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        Text(SessionAge.text(context.date.timeIntervalSince(summary.sampledAt)) + " ago")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if let summary {
                Label(summary.verdictText, systemImage: verdictIcon(summary))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(verdictColor(summary))
                    .lineLimit(2)

                if summary.allocatedGPUCount > 0 || !summary.gpus.isEmpty {
                    UsageMeterRow(
                        title: "GPU",
                        fraction: summary.meanGPUUtilization.map { $0 / 100 },
                        value: summary.meanGPUUtilization.map { "\(Int($0.rounded()))%" },
                        detail: summary.gpus.isEmpty ? nil : "\(summary.gpus.count) × \(JobUsageSummary.shortGPUName(summary.gpus.first?.name ?? ""))",
                        color: AppTheme.gpu,
                        stacked: true
                    )
                    UsageMeterRow(
                        title: "GPU mem",
                        fraction: summary.gpuMemoryFraction,
                        value: summary.gpuMemoryUsedMB.map(Self.gigabytes),
                        detail: summary.gpuMemoryTotalMB.map { "of \(Self.gigabytes($0))" },
                        color: .indigo,
                        stacked: true
                    )
                }
                UsageMeterRow(
                    title: "CPU",
                    fraction: summary.cpuFraction.map { min($0, 1) },
                    value: summary.cpusBusy.map { String(format: "%.1f", $0) },
                    detail: summary.cpusAllocated.map { "of \($0) cores" },
                    color: AppTheme.cpu,
                    stacked: true
                )
                UsageMeterRow(
                    title: "Memory",
                    fraction: summary.memoryFraction,
                    value: summary.memoryUsedMB.map(Self.gigabytes),
                    detail: summary.memoryLimitMB.map { "of \(Self.gigabytes($0))" },
                    color: .purple,
                    stacked: true
                )
                if series.count > 1 {
                    JobUsageSparkline(series: series)
                        .frame(height: 40)
                }
                ForEach(summary.notes, id: \.self) { note in
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Waiting for the first sample…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
        .accessibilityElement(children: .combine)
    }

    private func verdictIcon(_ summary: JobUsageSummary) -> String {
        switch summary.gpuVerdict {
        case .wellUsed: return "checkmark.circle.fill"
        case .someIdle, .mostlyIdle: return "exclamationmark.triangle.fill"
        case .partlyUsed: return "circle.lefthalf.filled"
        case .unknown: return summary.allocatedGPUCount > 0 ? "questionmark.circle" : "cpu"
        }
    }

    private func verdictColor(_ summary: JobUsageSummary) -> Color {
        switch summary.gpuVerdict {
        case .wellUsed: return .green
        case .someIdle, .mostlyIdle: return .orange
        case .partlyUsed: return .yellow
        case .unknown: return .secondary
        }
    }

    static func gigabytes(_ megabytes: Double) -> String {
        megabytes >= 1024 ? String(format: "%.1f GB", megabytes / 1024) : "\(Int(megabytes.rounded())) MB"
    }
}

/// "GPU  ▓▓▓▓▓▓▓░░  92%  4 × H200".
struct UsageMeterRow: View {
    let title: String
    let fraction: Double?
    let value: String?
    let detail: String?
    let color: Color
    /// Fixed width for the detail text, so the bars of one block line up.
    var detailWidth: CGFloat = 96
    /// Label and figures on one line, a full-width bar under them: for the
    /// narrow cards, where a bar beside the text would be a stub.
    var stacked = false

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(value ?? "—")
                            .font(.caption.monospacedDigit().weight(.medium))
                        if let detail {
                            Text(detail)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    FractionBar(fraction: fraction, color: color)
                        .frame(height: 6)
                }
            } else {
                inline
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue([value, detail].compactMap { $0 }.joined(separator: " "))
    }

    private var inline: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            FractionBar(fraction: fraction, color: color)
                .frame(height: 7)
            Text(value ?? "—")
                .font(.caption.monospacedDigit().weight(.medium))
                .frame(minWidth: 50, alignment: .trailing)
            if let detail {
                Text(detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: detailWidth, alignment: .leading)
            }
        }
    }
}

struct FractionBar: View {
    let fraction: Double?
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(AppTheme.mutedFill)
                if let fraction {
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: max(proxy.size.width * min(max(fraction, 0), 1), fraction > 0 ? 3 : 0))
                }
            }
        }
        .animation(AppTheme.softSpring, value: fraction)
    }
}

/// GPU utilisation (and GPU memory) over the recent samples.
struct JobUsageSparkline: View {
    let series: [JobUsagePoint]
    /// Not the app's teal CPU colour: next to the cyan GPU line it would be
    /// indistinguishable.
    static let cpuLine = Color.green

    var body: some View {
        Chart {
            ForEach(series) { point in
                if let utilization = point.gpuUtilization {
                    LineMark(x: .value("Time", point.date), y: .value("GPU %", utilization), series: .value("Metric", "GPU"))
                        .foregroundStyle(AppTheme.gpu)
                        .interpolationMethod(.monotone)
                }
                if let memory = point.gpuMemoryFraction {
                    LineMark(x: .value("Time", point.date), y: .value("GPU %", memory * 100), series: .value("Metric", "GPU memory"))
                        .foregroundStyle(Color.indigo.opacity(0.7))
                        .interpolationMethod(.monotone)
                }
                if point.gpuUtilization == nil, let cpu = point.cpuFraction {
                    LineMark(x: .value("Time", point.date), y: .value("GPU %", cpu * 100), series: .value("Metric", "CPU"))
                        .foregroundStyle(Self.cpuLine)
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .accessibilityLabel("Recent utilisation")
    }
}

// MARK: - Job details

/// Per node and per GPU, with the trend since the app started watching.
struct JobUsageDetailSection: View {
    let summary: JobUsageSummary?
    let series: [JobUsagePoint]
    let isSampling: Bool

    var body: some View {
        DetailSection(title: "Resource use", systemImage: "gauge.with.dots.needle.67percent") {
            if let summary {
                Label(summary.verdictText, systemImage: "info.circle")
                    .font(.callout.weight(.medium))
                if let sustained = sustainedText {
                    Text(sustained)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if series.count > 1 {
                    trendChart
                        .frame(height: 120)
                        .padding(.vertical, 4)
                }
                ForEach(summary.nodes) { node in
                    nodeBlock(node)
                }
            } else {
                Text(isSampling
                     ? "Not sampled yet — the first sample arrives within about a minute of the job starting."
                     : "Sampling is off (Resource use on the Jobs page).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sustainedText: String? {
        let values = series.compactMap(\.gpuUtilization)
        guard values.count > 2, let first = series.first?.date, let last = series.last?.date else {
            return nil
        }
        let mean = values.reduce(0, +) / Double(values.count)
        return "Average GPU utilisation \(Int(mean.rounded()))% over the last \(SessionAge.text(last.timeIntervalSince(first))) (\(values.count) samples)."
    }

    private var trendChart: some View {
        Chart {
            ForEach(series) { point in
                if let utilization = point.gpuUtilization {
                    LineMark(x: .value("Time", point.date), y: .value("Percent", utilization), series: .value("Metric", "GPU utilisation"))
                        .foregroundStyle(by: .value("Metric", "GPU utilisation"))
                }
                if let memory = point.gpuMemoryFraction {
                    LineMark(x: .value("Time", point.date), y: .value("Percent", memory * 100), series: .value("Metric", "GPU memory"))
                        .foregroundStyle(by: .value("Metric", "GPU memory"))
                }
                if let cpu = point.cpuFraction {
                    LineMark(x: .value("Time", point.date), y: .value("Percent", cpu * 100), series: .value("Metric", "CPU"))
                        .foregroundStyle(by: .value("Metric", "CPU"))
                }
                if let memory = point.memoryFraction {
                    LineMark(x: .value("Time", point.date), y: .value("Percent", memory * 100), series: .value("Metric", "Memory"))
                        .foregroundStyle(by: .value("Metric", "Memory"))
                }
            }
        }
        .chartForegroundStyleScale([
            "GPU utilisation": AppTheme.gpu,
            "GPU memory": Color.indigo,
            "CPU": JobUsageSparkline.cpuLine,
            "Memory": Color.purple
        ])
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
            }
        }
    }

    @ViewBuilder
    private func nodeBlock(_ node: JobNodeUsage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(node.node)
                .font(.caption.weight(.semibold).monospaced())
            ForEach(node.gpus) { gpu in
                UsageMeterRow(
                    title: "GPU \(gpu.index.map(String.init) ?? "?")",
                    fraction: gpu.utilizationPercent.map { $0 / 100 },
                    value: gpu.utilizationPercent.map { "\(Int($0.rounded()))%" },
                    detail: gpuDetail(gpu),
                    color: AppTheme.gpu,
                    detailWidth: 240
                )
            }
            UsageMeterRow(
                title: "CPU",
                fraction: node.cpusBusy.flatMap { busy in node.cpusAllocated.map { min(busy / Double(max($0, 1)), 1) } },
                value: node.cpusBusy.map { String(format: "%.1f", $0) },
                detail: node.cpusAllocated.map { "of \($0) cores" },
                color: AppTheme.cpu,
                detailWidth: 240
            )
            UsageMeterRow(
                title: "Memory",
                fraction: node.memoryUsedMB.flatMap { used in node.memoryLimitMB.map { min(used / max($0, 1), 1) } },
                value: node.memoryUsedMB.map(JobUsageCard.gigabytes),
                detail: memoryDetail(node),
                color: .purple,
                detailWidth: 240
            )
            if let note = node.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func gpuDetail(_ gpu: GPUUsage) -> String {
        var parts: [String] = []
        if let used = gpu.memoryUsedMB, let total = gpu.memoryTotalMB {
            parts.append("\(JobUsageCard.gigabytes(used)) / \(JobUsageCard.gigabytes(total))")
        }
        if let watts = gpu.powerWatts {
            parts.append("\(Int(watts.rounded())) W")
        }
        if let temperature = gpu.temperatureC {
            parts.append("\(Int(temperature.rounded()))°C")
        }
        return parts.joined(separator: " · ")
    }

    private func memoryDetail(_ node: JobNodeUsage) -> String? {
        var parts: [String] = []
        if let limit = node.memoryLimitMB {
            parts.append("of \(JobUsageCard.gigabytes(limit))")
        }
        if let peak = node.memoryPeakMB {
            parts.append("peak \(JobUsageCard.gigabytes(peak))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
