import SwiftUI

struct StorageDashboard: View {
    let storage: [StorageSummary]
    let history: [TrendPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(
                title: "Storage",
                subtitle: "Quota and filesystem headroom for home and scratch spaces",
                systemImage: "internaldrive",
                accent: .teal
            ) {
                InfoChip(label: "Spaces", value: "\(storage.count)", systemImage: "folder", color: .teal)
            }

            if storage.isEmpty {
                EmptyVisual(
                    title: "No storage snapshot yet",
                    subtitle: "Storage quota information will appear after the next successful refresh.",
                    systemImage: "externaldrive.badge.questionmark"
                )
            } else {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(storage) { item in
                        StorageCard(item: item, history: history)
                    }
                }

                StorageComparison(storage: storage)
            }
        }
    }
}

struct StorageCard: View {
    let item: StorageSummary
    let history: [TrendPoint]

    private var percent: Double {
        min(max(item.usedPercent ?? 0, 0), 100)
    }

    private var color: Color {
        if percent >= 90 {
            return .red
        }
        if percent >= 75 {
            return .orange
        }
        return item.label.lowercased() == "scratch" ? .teal : .purple
    }

    /// Trend series keyed by the storage label; unknown mounts show an empty
    /// chart instead of silently reusing the home series.
    private var trendValues: [Double] {
        switch item.label.lowercased() {
        case "scratch":
            return history.compactMap(\.scratchUsedPercent)
        case "home":
            return history.compactMap(\.homeUsedPercent)
        default:
            return []
        }
    }

    private var iconName: String {
        switch item.label.lowercased() {
        case "scratch":
            return "externaldrive"
        case "home":
            return "house"
        default:
            return "internaldrive"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(item.label, systemImage: iconName)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(color)
                    Text(item.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
                Spacer()
                RingMeter(value: percent / 100, color: color, label: "used")
                    .frame(width: 74, height: 74)
            }

            HStack(spacing: 10) {
                StorageStat(title: "Used", value: formatGB(item.usedGB), color: color)
                StorageStat(title: "Free", value: formatGB(item.availableGB), color: .green)
                StorageStat(title: "Limit", value: formatGB(item.limitGB), color: .secondary)
            }

            if !trendValues.isEmpty {
                TrendChart(values: trendValues, color: color, isPercentage: true, threshold: 90)
                    .frame(height: 72)
            }

            if let fileLimit = item.fileLimit, fileLimit > 0 {
                StorageFileBar(count: item.fileCount, limit: fileLimit, color: color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard(accent: color)
        .animation(AIRETheme.smoothEase, value: percent)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.label) storage")
        .accessibilityValue("\(Int(percent.rounded())) percent used")
    }
}

struct StorageStat: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color.opacity(0.14), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

struct StorageFileBar: View {
    let count: Int?
    let limit: Int
    let color: Color

    private var ratio: Double {
        min(Double(count ?? 0) / Double(max(limit, 1)), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Files")
                Spacer()
                Text("\(count ?? 0) / \(limit)")
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            ProgressView(value: ratio)
                .tint(ratio > 0.9 ? .red : color)
                .accessibilityLabel("File count usage")
                .accessibilityValue("\(Int((ratio * 100).rounded())) percent")
        }
    }
}

struct StorageComparison: View {
    let storage: [StorageSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Space balance", subtitle: "Quota-backed remaining capacity")
            ForEach(storage) { item in
                HStack(spacing: 10) {
                    Text(item.label)
                        .font(.caption.weight(.semibold))
                        .frame(width: 70, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.green.opacity(0.16))
                            RoundedRectangle(cornerRadius: 5)
                                .fill(storageColor(item).opacity(0.85))
                                .frame(width: proxy.size.width * CGFloat(min(max((item.usedPercent ?? 0) / 100, 0), 1)))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .frame(height: 12)
                    Text(percentText(item.usedPercent))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .frame(width: 42, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.label) usage")
                .accessibilityValue(percentText(item.usedPercent))
            }
        }
        .dashboardCard(accent: .teal)
    }

    private func storageColor(_ item: StorageSummary) -> Color {
        let percent = item.usedPercent ?? 0
        if percent >= 90 {
            return .red
        }
        if percent >= 75 {
            return .orange
        }
        return item.label.lowercased() == "scratch" ? .teal : .purple
    }
}
