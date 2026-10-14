import HPCCore
import Charts
import SwiftUI

// Time-based trend charts for the Trends and Storage tabs. History points
// are plotted against their collection time — never their index — so a
// sleep or VPN outage shows as a gap instead of one straight segment, and
// both tabs chart the same window of the same series.

// MARK: - Window

/// How much history the Trends and Storage charts show. One app-wide
/// preference (`@AppStorage(TrendWindow.storageKey)`), so both tabs always
/// cover the same period.
enum TrendWindow: String, CaseIterable, Identifiable {
    case hour = "1h"
    case sixHours = "6h"
    case day = "24h"

    static let storageKey = "trendWindow"

    var id: String { rawValue }

    var duration: TimeInterval {
        switch self {
        case .hour: return 3600
        case .sixHours: return 6 * 3600
        case .day: return 24 * 3600
        }
    }

    var title: String {
        switch self {
        case .hour: return "1 h"
        case .sixHours: return "6 h"
        case .day: return "24 h"
        }
    }

    /// "the last hour", "the last 6 hours".
    var phrase: String {
        switch self {
        case .hour: return "the last hour"
        case .sixHours: return "the last 6 hours"
        case .day: return "the last 24 hours"
        }
    }
}

/// Segmented window picker shared by the Trends and Storage headers.
struct TrendWindowPicker: View {
    @Binding var window: TrendWindow

    var body: some View {
        Picker("Trend window", selection: $window) {
            ForEach(TrendWindow.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("How much history the charts show")
        .accessibilityLabel("Trend window")
    }
}

// MARK: - Timeline

/// A cluster's history with every timestamp parsed once, in time order.
/// Parsing 1,440 ISO timestamps costs milliseconds, and the dashboards
/// re-render several times per refresh, so timelines are memoised per
/// history version (`TrendTimeline.cached(for:)`).
struct TrendTimeline {
    let points: [TrendPoint]
    let dates: [Date]
    /// Median spacing between consecutive points (the refresh cadence when
    /// healthy).
    let typicalSpacing: TimeInterval

    init(history: [TrendPoint]) {
        var pairs: [(TrendPoint, Date)] = []
        pairs.reserveCapacity(history.count)
        for point in history {
            if let date = SlurmTimestamp.parse(point.collectedAt) {
                pairs.append((point, date))
            }
        }
        // History is appended in collection order; sort anyway (stable) so a
        // clock step can never draw lines backwards.
        if zip(pairs, pairs.dropFirst()).contains(where: { $0.1 > $1.1 }) {
            pairs = pairs.enumerated()
                .sorted { lhs, rhs in lhs.element.1 != rhs.element.1 ? lhs.element.1 < rhs.element.1 : lhs.offset < rhs.offset }
                .map(\.element)
        }
        points = pairs.map(\.0)
        dates = pairs.map(\.1)
        let gaps = zip(dates, dates.dropFirst()).map { $1.timeIntervalSince($0) }.sorted()
        typicalSpacing = gaps.isEmpty ? HPCDefaults.refreshInterval : gaps[gaps.count / 2]
    }

    /// A pause longer than this breaks the line: three refresh intervals,
    /// so one slow or failed refresh does not, but sleep or an outage does.
    var gapThreshold: TimeInterval {
        3 * max(typicalSpacing, HPCDefaults.refreshInterval)
    }

    var lastDate: Date? { dates.last }

    /// The indices inside `window`, ending now — or at the last point while
    /// it is fresh, so the domain does not creep between refreshes.
    func slice(_ window: TrendWindow, now: Date = Date()) -> TrendSlice {
        // While points keep arriving the window ends at the newest one; once
        // they stop (paused, offline, asleep) it ends now, so the silence
        // shows as an empty stretch on the right instead of being hidden.
        var end = now
        if let last = lastDate, now.timeIntervalSince(last) < gapThreshold {
            end = last
        }
        let start = end.addingTimeInterval(-window.duration)
        let lower = dates.firstIndex { $0 >= start } ?? dates.count
        let upper = dates.lastIndex { $0 <= end }.map { $0 + 1 } ?? lower
        let range = lower..<max(upper, lower)
        return TrendSlice(timeline: self, indices: range, start: start, end: end)
    }

    // MARK: Memo

    @MainActor private static var cache: [String: (source: [TrendPoint], timeline: TrendTimeline)] = [:]

    /// The timeline for `history`, parsed once per history version. Looked
    /// up by count and the first/last timestamps (which change whenever a
    /// point is appended or the oldest is dropped), but served only when
    /// the stored history is the same content: two histories with the same
    /// stamps and different figures must never share a timeline. The
    /// comparison is cheap on a hit, because the stored array usually
    /// shares its buffer with `history` and `==` returns at once.
    @MainActor
    static func cached(for history: [TrendPoint]) -> TrendTimeline {
        let key = "\(history.count)|\(history.first?.collectedAt ?? "")|\(history.last?.collectedAt ?? "")"
        if let entry = cache[key], entry.source == history {
            return entry.timeline
        }
        let timeline = TrendTimeline(history: history)
        // Two clusters, a couple of versions each in flight; keep it tiny.
        if cache.count >= 8 {
            cache.removeAll(keepingCapacity: true)
        }
        cache[key] = (history, timeline)
        return timeline
    }
}

/// The part of a timeline inside one window.
struct TrendSlice {
    let timeline: TrendTimeline
    let indices: Range<Int>
    let start: Date
    let end: Date

    var isEmpty: Bool { indices.isEmpty }
    var count: Int { indices.count }
    var latest: TrendPoint? { indices.isEmpty ? nil : timeline.points[indices.upperBound - 1] }

    /// Time actually covered by points in the window.
    var coveredSpan: TimeInterval {
        guard let first = indices.first, let last = indices.last else {
            return 0
        }
        return timeline.dates[last].timeIntervalSince(timeline.dates[first])
    }

    /// Silences longer than the gap threshold inside the window: breaks
    /// between its points, a break that straddles the window's start (an
    /// outage before the first point, not a fresh history: only counted
    /// when older points exist), and the stretch after the last point once
    /// points stopped (paused, offline, asleep). So "no gaps" means the
    /// covered span really is unbroken, never that a 58-minute outage
    /// before the newest points went unnoticed.
    var gapCount: Int {
        guard let first = indices.first, let last = indices.last else {
            return 0
        }
        let threshold = timeline.gapThreshold
        var gaps = 0
        if first > 0, timeline.dates[first].timeIntervalSince(max(start, timeline.dates[first - 1])) > threshold {
            gaps += 1
        }
        for index in indices.dropFirst() where timeline.dates[index].timeIntervalSince(timeline.dates[index - 1]) > threshold {
            gaps += 1
        }
        if end.timeIntervalSince(timeline.dates[last]) > threshold {
            gaps += 1
        }
        return gaps
    }

    /// One metric over the window, split into segments at gaps and missing
    /// values, and thinned to at most `maxPoints` marks with min/max
    /// buckets so spikes survive. Swift Charts cost grows with marks: 1,440
    /// points in a 300 pt chart took ~35 ms per render.
    func series(maxPoints: Int = 320, _ value: (TrendPoint) -> Double?) -> TrendSeries {
        var segments: [[TrendSample]] = []
        var current: [TrendSample] = []
        var segment = 0
        var previousDate: Date?
        for index in indices {
            let date = timeline.dates[index]
            let brokeByGap = previousDate.map { date.timeIntervalSince($0) > timeline.gapThreshold } ?? false
            previousDate = date
            guard let raw = value(timeline.points[index]), raw.isFinite else {
                // A missing value is a gap too — never bridged, never zero.
                if !current.isEmpty {
                    segments.append(current)
                    current = []
                    segment += 1
                }
                continue
            }
            if brokeByGap, !current.isEmpty {
                segments.append(current)
                current = []
                segment += 1
            }
            current.append(TrendSample(date: date, value: raw, segment: segment))
        }
        if !current.isEmpty {
            segments.append(current)
        }
        let total = segments.reduce(0) { $0 + $1.count }
        let samples: [TrendSample]
        if total > maxPoints {
            // Each bucket contributes up to two marks (its min and max).
            let bucketSize = Int((Double(total) / Double(max(maxPoints / 2, 1))).rounded(.up))
            samples = segments.flatMap { Self.thin($0, bucketSize: bucketSize) }
        } else {
            samples = segments.flatMap { $0 }
        }
        let latest = latest.flatMap(value)
        return TrendSeries(samples: samples, latest: latest, start: start, end: end)
    }

    private static func thin(_ samples: [TrendSample], bucketSize: Int) -> [TrendSample] {
        guard bucketSize > 1, samples.count > 2 else {
            return samples
        }
        var result: [TrendSample] = []
        result.reserveCapacity(samples.count / bucketSize * 2 + 2)
        var start = 0
        while start < samples.count {
            let bucket = samples[start..<min(start + bucketSize, samples.count)]
            if let low = bucket.min(by: { $0.value < $1.value }), let high = bucket.max(by: { $0.value < $1.value }) {
                if low.date == high.date {
                    result.append(low)
                } else {
                    result.append(contentsOf: low.date < high.date ? [low, high] : [high, low])
                }
            }
            start += bucketSize
        }
        // Keep the true last point so the line ends at the latest value.
        if let last = samples.last, result.last?.date != last.date {
            result.append(last)
        }
        return result
    }
}

struct TrendSample: Identifiable, Equatable {
    let date: Date
    let value: Double
    /// Continuous run the sample belongs to; lines never join two runs.
    let segment: Int

    var id: Date { date }
}

/// One chart's data: samples in time order and the window's domain.
struct TrendSeries: Equatable {
    let samples: [TrendSample]
    /// The latest point's value (nil when missing).
    let latest: Double?
    let start: Date
    let end: Date

    var isEmpty: Bool { samples.isEmpty }

    /// Share of the domain at either end where an x-axis tick gets no time
    /// label: a centred "22:29" is about 28 pt wide, so at the narrowest
    /// chart (~180 pt plot) half of it needs ~8 % of the width.
    static let axisLabelMargin = 0.08

    /// Whether the x-axis tick at `date` gets a time label: only when the
    /// whole label fits inside the plot, i.e. the tick is not within
    /// `axisLabelMargin` of either end of the domain.
    func labelsAxisTick(at date: Date) -> Bool {
        let span = end.timeIntervalSince(start)
        guard span > 0 else {
            return true
        }
        let margin = span * Self.axisLabelMargin
        return date.timeIntervalSince(start) >= margin && end.timeIntervalSince(date) >= margin
    }

    /// Nearest sample to `date` (samples are sorted by date).
    func nearest(to date: Date) -> TrendSample? {
        guard !samples.isEmpty else {
            return nil
        }
        var low = 0
        var high = samples.count - 1
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].date < date {
                low = mid + 1
            } else {
                high = mid
            }
        }
        if low > 0, abs(samples[low - 1].date.timeIntervalSince(date)) < abs(samples[low].date.timeIntervalSince(date)) {
            return samples[low - 1]
        }
        return samples[low]
    }
}

// MARK: - Chart

/// A time-axis trend chart: area + line per continuous segment, a visible
/// time axis, optional threshold rules, and a hover readout (time and
/// value) drawn in a separate layer, so moving the mouse never rebuilds the
/// marks. Equatable on its data so unchanged charts are skipped.
struct TimeTrendChart: View, Equatable {
    let series: TrendSeries
    let color: Color
    var isPercentage = false
    /// Dashed rules, e.g. the 75 % and 90 % storage thresholds.
    var thresholds: [Threshold] = []
    var compact = false

    struct Threshold: Equatable {
        let value: Double
        let color: Color
    }

    nonisolated static func == (lhs: TimeTrendChart, rhs: TimeTrendChart) -> Bool {
        lhs.series == rhs.series && lhs.color == rhs.color && lhs.isPercentage == rhs.isPercentage
            && lhs.thresholds == rhs.thresholds && lhs.compact == rhs.compact
    }

    private var yDomain: ClosedRange<Double> {
        if isPercentage {
            return 0...100
        }
        let maxValue = series.samples.map(\.value).max() ?? 1
        return 0...max(maxValue * 1.15, 1)
    }

    var body: some View {
        Chart {
            ForEach(series.samples) { sample in
                AreaMark(
                    x: .value("Time", sample.date),
                    y: .value("Value", sample.value),
                    series: .value("Run", sample.segment)
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
                    x: .value("Time", sample.date),
                    y: .value("Value", sample.value),
                    series: .value("Run", sample.segment)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .foregroundStyle(color)
            }

            ForEach(Array(thresholds.enumerated()), id: \.offset) { _, threshold in
                RuleMark(y: .value("Threshold", threshold.value))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(threshold.color.opacity(0.5))
            }
        }
        .chartXScale(domain: series.start...series.end)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: compact ? 3 : 4)) { value in
                AxisGridLine()
                    .foregroundStyle(Color.primary.opacity(0.05))
                // A label centred on a tick at either end of the domain
                // hangs half outside the plot and is clipped to a stray
                // "2" under the y-axis labels: such a tick keeps its grid
                // line but shows no time.
                if let date = value.as(Date.self), series.labelsAxisTick(at: date) {
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                }
            }
        }
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
            TrendHoverLayer(proxy: proxy, series: series, color: color, isPercentage: isPercentage)
        }
        .overlay {
            if series.isEmpty {
                Text("No data in this window")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The hover rule, dot and "14:05 · 87%" readout. Its own view with its own
/// state: a hover change re-renders only this layer, not the chart marks.
private struct TrendHoverLayer: View {
    let proxy: ChartProxy
    let series: TrendSeries
    let color: Color
    let isPercentage: Bool

    @State private var hovered: TrendSample?

    var body: some View {
        GeometryReader { geometry in
            let plot = geometry[proxy.plotAreaFrame]
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let date: Date? = proxy.value(atX: location.x - plot.origin.x)
                            let nearest = date.flatMap(series.nearest(to:))
                            if nearest != hovered {
                                hovered = nearest
                            }
                        case .ended:
                            if hovered != nil {
                                hovered = nil
                            }
                        }
                    }

                if let hovered,
                   let x = proxy.position(forX: hovered.date),
                   let y = proxy.position(forY: hovered.value) {
                    let pointX = plot.origin.x + x
                    let pointY = plot.origin.y + y
                    Path { path in
                        path.move(to: CGPoint(x: pointX, y: plot.minY))
                        path.addLine(to: CGPoint(x: pointX, y: plot.maxY))
                    }
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                    .allowsHitTesting(false)

                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                        .position(x: pointX, y: pointY)
                        .allowsHitTesting(false)

                    Text(readout(hovered))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .fixedSize()
                        .position(
                            x: min(max(pointX, plot.minX + 44), plot.maxX - 44),
                            y: max(pointY - 16, plot.minY + 8)
                        )
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func readout(_ sample: TrendSample) -> String {
        let time = sample.date.formatted(date: .omitted, time: .shortened)
        return "\(time) · \(trendValueText(sample.value, isPercentage: isPercentage))"
    }
}

func trendValueText(_ value: Double, isPercentage: Bool) -> String {
    if isPercentage {
        return "\(Int(value.rounded()))%"
    }
    if value.rounded() == value {
        return "\(Int(value))"
    }
    return String(format: "%.1f", value)
}

/// A titled trend card for the Trends tab.
struct TimeTrendCard: View {
    let title: String
    let subtitle: String
    let value: String
    let systemImage: String
    let color: Color
    let series: TrendSeries
    var isPercentage = false
    var thresholds: [TimeTrendChart.Threshold] = []
    /// Colour of the headline value (a status colour for storage).
    var valueColor: Color = .primary
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Title and value side by side when they fit; stacked in a
            // narrow card ("Queue pressure" / "2 running · 61 pending")
            // rather than both truncating.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    titleLabel
                    Spacer(minLength: 8)
                    valueText
                }
                VStack(alignment: .leading, spacing: 4) {
                    titleLabel
                    valueText
                }
            }

            TimeTrendChart(series: series, color: color, isPercentage: isPercentage, thresholds: thresholds)
                .equatable()
                .frame(height: 128)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .dashboardCard(accent: color)
        .help(help ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value), \(subtitle)")
    }

    private var titleLabel: some View {
        Label(title, systemImage: systemImage)
            .font(.headline.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }

    private var valueText: some View {
        Text(value)
            .font(.headline.monospacedDigit().weight(.semibold))
            .foregroundStyle(valueColor)
            .lineLimit(1)
            .fixedSize()
    }
}

/// "39 min", "3 h 58 min" for a covered span (minute precision; seconds
/// only below a minute).
func spanText(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    if total < 60 {
        return total <= 0 ? "a moment" : "\(total) s"
    }
    return slurmDurationText(seconds: total / 60 * 60)
}

/// Storage threshold rules matching `StatusTone`'s 75 % / 90 % table.
let storageThresholds: [TimeTrendChart.Threshold] = [
    .init(value: 75, color: StatusTone.warning.color),
    .init(value: 90, color: StatusTone.critical.color)
]
