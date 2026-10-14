import HPCCore
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

/// The card at the top of every tab: icon, title, subtitle and the tab's
/// own controls.
///
/// Sized for the narrowest detail column (`ContentView.minimumDetailSize`):
/// the trailing controls keep their ideal width, so an action label never
/// truncates to "New Fol…"; the title block takes what is left — at least
/// 160 pt, and before the spacer — with a one-line title and a subtitle
/// that wraps to a second line before it truncates.
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
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            .frame(minWidth: 160, alignment: .leading)
            .layoutPriority(1)
            .help(subtitle)

            Spacer(minLength: 12)
            trailing
                .fixedSize()
        }
        .dashboardCard(padding: 12, accent: accent)
    }
}

// MARK: - Chips and badges

/// Label-and-value capsule. Only the icon and the value carry the tint; the
/// label is neutral. A tinted label on a tint-washed capsule measured about
/// 1.4:1 contrast in light mode — readable only by its colour.
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
                .foregroundStyle(color)
            Text(label)
                .foregroundStyle(Color.primary.opacity(0.72))
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(color.legibleText(in: colorScheme))
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(color.opacity(colorScheme == .dark ? 0.12 : 0.10), in: Capsule())
        .overlay(
            Capsule()
                .stroke(color.opacity(colorScheme == .dark ? 0.28 : 0.30), lineWidth: 1)
        )
        .animation(AppTheme.smoothEase, value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
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

    @Environment(\.colorScheme) private var colorScheme

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
                .foregroundStyle(color.legibleText(in: colorScheme))
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
        .lineLimit(1)
        .fixedSize()
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
        if age < HPCDefaults.snapshotOldAfter {
            return .orange
        }
        return .red
    }
}

/// A Slurm state as a plain-language pill: "Running", "Mixed",
/// "Drained" — never the raw code ("MIX-", "DRAIN*", "down$"), whose
/// suffixes mean something but explain nothing. Node flags show as a small
/// glyph, and the tooltip carries the raw code and what each flag means.
struct StatePill: View {
    /// Which Slurm vocabulary `state` comes from. `.automatic` reads exact
    /// job states first (they are long upper-case words such as RUNNING),
    /// then anything else as a node state — right for every existing caller,
    /// but a caller that knows should say so.
    enum Kind {
        case automatic
        case job
        case node
    }

    let state: String
    var kind: Kind = .automatic
    /// Set by `init(job:)`: the whole job, so a held one can read "Held".
    private var job: Job?

    @Environment(\.colorScheme) private var colorScheme

    init(state: String, kind: Kind = .automatic) {
        self.state = state
        self.kind = kind
    }

    /// A job's pill with the Jobs tab's held rule (`StatePillPresentation(job:)`).
    init(job: Job) {
        self.state = job.state
        self.kind = .job
        self.job = job
    }

    var body: some View {
        let presentation = job.map(StatePillPresentation.init(job:)) ?? StatePillPresentation(raw: state, kind: kind)
        HStack(spacing: 4) {
            if let glyph = presentation.flagGlyph {
                Image(systemName: glyph)
                    .font(.caption2.weight(.bold))
                    .accessibilityHidden(true)
            }
            Text(presentation.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(presentation.color.legibleText(in: colorScheme))
        }
        .foregroundStyle(presentation.color)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background {
            Capsule()
                .fill(.thinMaterial)
                .overlay {
                    Capsule()
                        .fill(presentation.color.opacity(0.14))
                }
        }
        .overlay(
            Capsule()
                .stroke(presentation.color.opacity(0.24), lineWidth: 1)
        )
        .clipShape(Capsule())
        .animation(AppTheme.smoothEase, value: state)
        .help(presentation.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("State")
        .accessibilityValue(presentation.accessibilityValue)
    }
}

/// What a StatePill shows for one raw state. Separate from the view so the
/// wording is unit-testable.
struct StatePillPresentation: Equatable {
    private(set) var label: String
    let flagGlyph: String?
    private(set) var help: String
    private(set) var accessibilityValue: String
    let slurmState: SlurmState
    /// Read as a job state (true) or a node / partition state.
    let readsAsJob: Bool
    /// Replaces the state colour where the pill shows a derived state (a
    /// held job's grey).
    private var colorOverride: Color?

    /// A job that ended badly (FAILED, TIMEOUT…) is `.failed`, red; a node
    /// that accepts no work is `.unavailable`, grey.
    var color: Color {
        colorOverride ?? slurmState.color
    }

    /// A job's pill. Slurm's state, except that a pending job held by the
    /// user or an administrator reads "Held" in grey, exactly as on the
    /// Jobs tab (`JobRow.statusText`/`statusColor`): it will not start
    /// however much capacity frees up, so it must never look like an
    /// ordinary orange "Pending" job.
    init(job: Job) {
        self.init(raw: job.state, kind: .job)
        guard let reason = job.pendingReason, reason.isHeld else {
            return
        }
        label = "Held"
        colorOverride = .gray
        help = "\(job.state) — \(reason.explanation)"
        accessibilityValue = "Held, \(reason.explanation)"
    }

    init(raw: String, kind: StatePill.Kind) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let jobState = JobState(trimmed)
        let readsAsJob: Bool
        switch kind {
        case .job:
            readsAsJob = true
        case .node:
            readsAsJob = false
        case .automatic:
            if case .other = jobState {
                readsAsJob = false
            } else {
                readsAsJob = true
            }
        }

        self.readsAsJob = readsAsJob
        if readsAsJob {
            label = jobState.label
            flagGlyph = nil
            slurmState = SlurmState(job: trimmed)
            help = trimmed.isEmpty ? "No state reported" : "Slurm job state \(trimmed.uppercased())"
            accessibilityValue = label
            return
        }

        // Partition availability ("up"/"down") also arrives here.
        if trimmed.lowercased() == "up" {
            label = "Up"
            flagGlyph = nil
            slurmState = .idle
            help = "Partition is up and accepting jobs"
            accessibilityValue = label
            return
        }

        let info = NodeStateInfo(trimmed)
        label = info.displayLabel
        slurmState = SlurmState(node: trimmed)
        flagGlyph = Self.glyph(for: info)
        var explanation = info.flagDescriptions
        switch info.base {
        case .mixed:
            explanation.insert("some of the node's CPUs are allocated", at: 0)
        case .allocated:
            explanation.insert("every CPU on the node is allocated", at: 0)
        case .idle, .planned:
            explanation.insert("no CPUs allocated", at: 0)
        case .draining:
            explanation.insert("finishing its jobs; accepts no new work", at: 0)
        case .drained:
            explanation.insert("accepts no new work", at: 0)
        default:
            break
        }
        let details = explanation.joined(separator: ", ")
        if trimmed.isEmpty {
            help = "No state reported"
        } else {
            help = details.isEmpty ? "Slurm node state \(trimmed)" : "Slurm node state \(trimmed) — \(details)"
        }
        accessibilityValue = info.flagDescriptions.isEmpty
            ? label
            : "\(label), \(info.flagDescriptions.joined(separator: ", "))"
    }

    /// The most important flag gets the glyph: a node that is not
    /// responding matters more than one that is merely planned.
    private static func glyph(for info: NodeStateInfo) -> String? {
        if info.notResponding {
            return "exclamationmark.circle"
        }
        if info.maintenanceReservation {
            return "wrench.and.screwdriver"
        }
        if info.rebootPending {
            return "arrow.clockwise"
        }
        if info.poweringDown || info.powerSaving {
            return "moon.zzz"
        }
        if info.plannedByBackfill {
            return "calendar.badge.clock"
        }
        return nil
    }
}

// MARK: - Metrics

struct MetricView: View {
    let title: String
    let value: String
    var subtitle: String?
    var systemImage: String?
    var accent: Color = .accentColor
    /// Tooltip for the tile; the subtitle when nil, so a caption cut short
    /// in the narrowest column can still be read in full on hover.
    var help: String? = nil

    @Environment(\.colorScheme) private var colorScheme

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
                    // One line, so a long title ("Idle H200 GPUs") never
                    // makes one tile taller than its neighbours.
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(accent.legibleText(in: colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard(accent: accent)
        .help(help ?? subtitle ?? "")
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
    /// Fraction 0…1, or nil when it is not known: the ring then shows only
    /// its track and the missing-value placeholder, never an empty "0%"
    /// that would read as nothing in use.
    let value: Double?
    let color: Color
    let label: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.10), lineWidth: 9)
            if let value {
                Circle()
                    .trim(from: 0, to: min(max(value, 0), 1))
                    .stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(AppTheme.softSpring, value: value)
            }
            VStack(spacing: 2) {
                Text(value.map { "\(Int(($0 * 100).rounded()))%" } ?? missingValuePlaceholder)
                    .font(.headline.monospacedDigit())
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value.map { "\(Int(($0 * 100).rounded())) percent" } ?? "unknown")
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

/// Show/Hide Details. Always at its full size: a "Show…" stub explains
/// nothing, and PageHeader leaves the title at least 160 pt beside it even
/// in the narrowest detail column.
struct DetailsToggleButton: View {
    @Binding var showDetails: Bool

    private var title: String { showDetails ? "Hide Details" : "Show Details" }
    private var systemImage: String { showDetails ? "tablecells.badge.ellipsis" : "tablecells" }

    var body: some View {
        Button {
            showDetails.toggle()
        } label: {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .fixedSize()
        .help(showDetails ? "Hide the detail table" : "Show every row in a sortable detail table")
        .accessibilityLabel(title)
    }
}
