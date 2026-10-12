import Charts
import SwiftUI

// MARK: - Headers and titles

struct SectionTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
            Spacer()
            Text(subtitle)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let accent: Color
    let trailing: Trailing

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        accent: Color,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.accent = accent
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(accent.opacity(0.14))
                Image(systemName: systemImage)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)
            trailing
        }
        .dashboardCard(padding: 12, accent: accent)
    }
}

// MARK: - Chips and badges

struct InfoChip: View {
    let label: String
    let value: String
    let systemImage: String
    var color: Color = .secondary

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(color.opacity(0.10))
        .foregroundStyle(color)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(AppTheme.chipStroke(for: colorScheme), lineWidth: 1)
        )
        .animation(AppTheme.smoothEase, value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

struct StatusBadge: View {
    let isConnected: Bool
    let isCached: Bool

    private var label: String {
        if isConnected {
            return "Connected"
        }
        if isCached {
            return "Cached"
        }
        return "Offline"
    }

    private var color: Color {
        if isConnected {
            return .green
        }
        if isCached {
            return .orange
        }
        return .gray
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(isConnected || isCached ? color : .secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            Capsule()
                .fill(.thinMaterial)
                .overlay {
                    Capsule()
                        .fill(color.opacity(0.11))
                }
        }
        .overlay {
            Capsule()
                .stroke(color.opacity(0.18), lineWidth: 1)
        }
        .clipShape(Capsule())
        .animation(AppTheme.softSpring, value: label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connection status")
        .accessibilityValue(label)
    }
}

/// Compact relative-age badge for a snapshot timestamp: green while fresh
/// (under a minute), orange while minutes old, red once it is an hour stale.
/// Re-renders on a 30s cadence so the age keeps ticking without external
/// state; generic over any `collectedAt`-style string so headers can adopt it.
struct StalenessBadge: View {
    let collectedAt: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            badge(reference: context.date)
        }
    }

    @MainActor
    private func badge(reference: Date) -> some View {
        let text = SlurmTimestamp.relativeText(collectedAt, reference: reference)
        let color = ageColor(reference: reference)
        return HStack(spacing: 5) {
            Image(systemName: "clock")
                .font(.caption2.weight(.semibold))
            Text(text)
                .font(.caption2.weight(.medium))
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule()
                .fill(.thinMaterial)
                .overlay {
                    Capsule()
                        .fill(color.opacity(0.12))
                }
        }
        .overlay(
            Capsule()
                .stroke(color.opacity(0.20), lineWidth: 1)
        )
        .clipShape(Capsule())
        .foregroundStyle(color)
        .animation(AppTheme.smoothEase, value: text)
        .help("Snapshot collected \(SlurmTimestamp.absoluteText(collectedAt))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Snapshot age")
        .accessibilityValue(text)
    }

    @MainActor
    private func ageColor(reference: Date) -> Color {
        guard let collected = SlurmTimestamp.parse(collectedAt) else {
            return .secondary
        }
        let age = reference.timeIntervalSince(collected)
        if age < 60 {
            return .green
        }
        if age < 3600 {
            return .orange
        }
        return .red
    }
}

struct StatePill: View {
    let state: String

    private var slurmState: SlurmState {
        SlurmState(parsing: state)
    }

    var body: some View {
        Text(state.uppercased())
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background {
                Capsule()
                    .fill(.thinMaterial)
                    .overlay {
                        Capsule()
                            .fill(slurmState.color.opacity(0.14))
                    }
            }
            .foregroundStyle(slurmState.color)
            .overlay(
                Capsule()
                    .stroke(slurmState.color.opacity(0.20), lineWidth: 1)
            )
            .clipShape(Capsule())
            .animation(AppTheme.smoothEase, value: state)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("State")
            .accessibilityValue(state)
    }
}

// MARK: - Metrics

struct MetricView: View {
    let title: String
    let value: String
    var subtitle: String?
    var systemImage: String?
    var accent: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accent)
                }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(accent)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard(accent: accent)
        .animation(AppTheme.softSpring, value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle.map { "\(value), \($0)" } ?? value)
    }
}

struct InsightCard: View {
    let title: String
    let value: String
    let subtitle: String
    let color: Color
    let systemImage: String
    var helpText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.headline.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard(accent: color)
        .help(helpText ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value), \(subtitle)")
    }
}

// MARK: - Meters

struct MeterSegment: Identifiable {
    let id: String
    let value: Int
    let color: Color
}

struct SegmentedMeter: View {
    let segments: [MeterSegment]
    var height: CGFloat = 12

    private var total: Int {
        segments.reduce(0) { $0 + max($1.value, 0) }
    }

    private var visibleSegments: [MeterSegment] {
        segments.filter { $0.value > 0 }
    }

    var body: some View {
        GeometryReader { proxy in
            let visible = visibleSegments
            if total == 0 || visible.isEmpty {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(AppTheme.mutedFill)
            } else {
                let widths = segmentWidths(for: visible, in: proxy.size.width)
                HStack(spacing: SegmentedMeter.segmentSpacing) {
                    ForEach(Array(zip(visible, widths)), id: \.0.id) { segment, width in
                        RoundedRectangle(cornerRadius: height / 2)
                            .fill(segment.color)
                            .frame(width: width)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: height / 2))
            }
        }
        .frame(height: height)
        .animation(AppTheme.softSpring, value: total)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Distribution")
        .accessibilityValue(
            visibleSegments
                .map { "\($0.id) \($0.value)" }
                .joined(separator: ", ")
        )
    }

    private static let segmentSpacing: CGFloat = 2

    /// Distributes the width proportionally, honoring inter-segment spacing so the
    /// bar never overflows its container; tiny segments keep a visible minimum and
    /// everything is rescaled when minimums push the sum past the available width.
    private func segmentWidths(for visible: [MeterSegment], in totalWidth: CGFloat) -> [CGFloat] {
        let count = CGFloat(visible.count)
        let available = max(totalWidth - SegmentedMeter.segmentSpacing * (count - 1), 0)
        let sum = CGFloat(visible.reduce(0) { $0 + $1.value })
        guard sum > 0, available > 0 else {
            return visible.map { _ in 0 }
        }
        let minimum = min(4, available / count)
        var widths = visible.map { max(available * CGFloat($0.value) / sum, minimum) }
        let widthSum = widths.reduce(0, +)
        if widthSum > available {
            widths = widths.map { $0 * available / widthSum }
        }
        return widths
    }
}

struct RingMeter: View {
    let value: Double
    let color: Color
    let label: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.10), lineWidth: 9)
            Circle()
                .trim(from: 0, to: min(max(value, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(AppTheme.softSpring, value: value)
            VStack(spacing: 2) {
                Text("\(Int((value * 100).rounded()))%")
                    .font(.headline.monospacedDigit())
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

// MARK: - Empty state

struct EmptyVisual: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .dashboardCard(padding: 20, accent: .secondary)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Controls

struct DetailsToggleButton: View {
    @Binding var showDetails: Bool

    var body: some View {
        Button {
            showDetails.toggle()
        } label: {
            Label(showDetails ? "Hide Details" : "Show Details", systemImage: showDetails ? "tablecells.badge.ellipsis" : "tablecells")
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - Trend charts (Swift Charts)

struct TrendChartCard: View {
    let title: String
    let subtitle: String
    let value: String
    let systemImage: String
    let color: Color
    let values: [Double]
    var isPercentage: Bool = false
    var threshold: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: systemImage)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(color)
                Spacer()
                Text(value)
                    .font(.headline.monospacedDigit().weight(.semibold))
            }

            TrendChart(values: values, color: color, isPercentage: isPercentage, threshold: threshold)
                .frame(height: 118)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .dashboardCard(accent: color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

/// Swift Charts trend line with an area gradient, sensible fixed domains
/// (0–100 for percentages, 0-anchored for counts) and a hover value readout.
struct TrendChart: View {
    let values: [Double]
    let color: Color
    var isPercentage: Bool = false
    var threshold: Double?

    @State private var hoverIndex: Int?

    private struct Sample: Identifiable {
        let index: Int
        let value: Double
        var id: Int { index }
    }

    private var samples: [Sample] {
        values.enumerated()
            .filter { $0.element.isFinite }
            .map { Sample(index: $0.offset, value: $0.element) }
    }

    private var yDomain: ClosedRange<Double> {
        if isPercentage {
            return 0...100
        }
        let maxValue = samples.map(\.value).max() ?? 1
        return 0...max(maxValue * 1.15, 1)
    }

    var body: some View {
        let data = samples
        Chart {
            ForEach(data) { sample in
                AreaMark(
                    x: .value("Point", sample.index),
                    y: .value("Value", sample.value)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(
                        colors: [color.opacity(0.26), color.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Point", sample.index),
                    y: .value("Value", sample.value)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .foregroundStyle(color)
            }

            if let threshold {
                RuleMark(y: .value("Threshold", threshold))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color.red.opacity(0.45))
            }

            if let hoverIndex, let sample = data.first(where: { $0.index == hoverIndex }) {
                RuleMark(x: .value("Point", sample.index))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                PointMark(
                    x: .value("Point", sample.index),
                    y: .value("Value", sample.value)
                )
                .symbolSize(46)
                .foregroundStyle(color)
                .annotation(position: .top, alignment: .center) {
                    Text(valueText(sample.value))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine()
                    .foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let plotOrigin = geometry[proxy.plotAreaFrame].origin
                            let x = location.x - plotOrigin.x
                            if let position: Double = proxy.value(atX: x) {
                                hoverIndex = nearestIndex(to: position, in: data)
                            }
                        case .ended:
                            hoverIndex = nil
                        }
                    }
            }
        }
        .accessibilityHidden(true)
    }

    private func nearestIndex(to position: Double, in data: [Sample]) -> Int? {
        data.min { abs(Double($0.index) - position) < abs(Double($1.index) - position) }?.index
    }

    private func valueText(_ value: Double) -> String {
        if isPercentage {
            return "\(Int(value.rounded()))%"
        }
        if value.rounded() == value {
            return "\(Int(value))"
        }
        return String(format: "%.1f", value)
    }
}
