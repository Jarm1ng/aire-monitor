import HPCCore
import SwiftUI

/// One cluster's Storage tab. `storage` arrives pre-sorted (home, scratch,
/// flash, others). Icons and identity colours come from
/// `StorageSummary.kind`, never from a particular cluster's labels or mount
/// points, so AIRE's /mnt/scratch, Calder's /scratch-calder and future
/// /scratch-aire, /flash-* spaces render without code changes. How full a
/// space is shows only through the shared status tone
/// (`StorageSummary.usageTone`: 75 % warning, 90 % or over quota critical),
/// so a healthy Flash never wears a warning colour.
struct StorageDashboard: View {
    let profile: ClusterProfile
    let storage: [StorageSummary]
    let history: [TrendPoint]

    /// Shared with the Trends tab, so both chart the same period.
    @AppStorage(TrendWindow.storageKey) private var window: TrendWindow = .hour

    private var overQuotaCount: Int {
        storage.filter { $0.overQuota == true }.count
    }

    /// "AIRE quotas and filesystem headroom · home, scratch and flash",
    /// listing whatever spaces the collector actually reported.
    private var subtitle: String {
        let base = "\(profile.displayName) quotas and filesystem headroom"
        let names = storage.map { $0.label.lowercased() }
        guard !names.isEmpty else {
            return base
        }
        return "\(base) · \(ListFormatter.localizedString(byJoining: names))"
    }

    var body: some View {
        // Parsed once per history version, windowed like the Trends tab.
        let slice = TrendTimeline.cached(for: history).slice(window)

        VStack(alignment: .leading, spacing: 14) {
            PageHeader(
                title: "Storage",
                subtitle: subtitle,
                systemImage: "internaldrive",
                accent: .teal
            ) {
                HStack(spacing: 8) {
                    if overQuotaCount > 0 {
                        InfoChip(
                            label: "Over quota",
                            value: "\(overQuotaCount)",
                            systemImage: "exclamationmark.triangle.fill",
                            color: StatusTone.critical.color
                        )
                    }
                    TrendWindowPicker(window: $window)
                }
            }

            if storage.isEmpty {
                EmptyVisual(
                    title: "No storage snapshot yet",
                    subtitle: "\(profile.displayName) quota information will appear after the next successful refresh.",
                    systemImage: "externaldrive.badge.questionmark"
                )
            } else {
                StorageColumnsLayout(minimumColumnWidth: 290, spacing: 12) {
                    ForEach(storage) { item in
                        StorageCard(item: item, trend: trendSeries(for: item, in: slice))
                    }
                }

                StorageComparison(storage: storage)
            }
        }
    }

    /// History series for a space over the shared window. TrendPoint keeps
    /// one value per kind (the first home/scratch/flash space of each
    /// snapshot), so a kind that appears more than once gets no chart rather
    /// than a borrowed one.
    private func trendSeries(for item: StorageSummary, in slice: TrendSlice) -> TrendSeries? {
        guard storage.filter({ $0.kind == item.kind }).count == 1 else {
            return nil
        }
        let series: TrendSeries
        switch item.kind {
        case .home:
            series = slice.series(maxPoints: 240, \.homeUsedPercent)
        case .scratch:
            series = slice.series(maxPoints: 240, \.scratchUsedPercent)
        case .flash:
            series = slice.series(maxPoints: 240, \.flashUsedPercent)
        case .other:
            return nil
        }
        return series.isEmpty ? nil : series
    }
}

struct StorageCard: View {
    let item: StorageSummary
    var trend: TrendSeries? = nil

    private var percent: Double {
        min(max(item.usedPercent ?? 0, 0), 100)
    }

    private var isOverQuota: Bool {
        item.overQuota == true
    }

    private var tone: StatusTone {
        item.usageTone
    }

    /// Status colour for everything that says how full the space is.
    private var statusColor: Color {
        StorageCard.statusColor(for: item)
    }

    /// Whole-filesystem numbers (df) are not a personal quota: say "Size"
    /// rather than implying the user may fill the entire filesystem.
    private var limitTitle: String {
        item.quotaType == "df" && item.source != "unavailable" ? "Size" : "Limit"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        // Identity (icon in the kind colour) is kept apart
                        // from status (ring, bars, values).
                        Label {
                            Text(item.label)
                                .foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: item.kind.systemImage)
                                .foregroundStyle(item.kind.color)
                        }
                        .font(.headline.weight(.semibold))
                        if isOverQuota {
                            overQuotaBadge
                        }
                    }
                    Text(item.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(pathHelp)
                    if let caption = StorageCard.quotaCaption(for: item) {
                        Label(caption, systemImage: StorageCard.quotaIcon(for: item))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(StorageCard.quotaHelp(for: item))
                    }
                    if item.kind.isSharedAcrossClusters {
                        Label("Shared by all Leeds clusters", systemImage: "link")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .help("/users is one NFS export mounted on every Leeds cluster, so this quota is the same space and the same numbers on each of them.")
                    }
                }
                Spacer(minLength: 0)
                ringMeter
                    .frame(width: 74, height: 74)
            }

            HStack(spacing: 10) {
                StorageStat(title: "Used", value: formatGB(item.usedGB), color: tone == .normal ? .primary : statusColor)
                StorageStat(title: "Free", value: formatGB(item.availableGB), color: isOverQuota ? StatusTone.critical.color : .primary)
                StorageStat(title: limitTitle, value: formatGB(item.limitGB), color: .secondary)
            }

            if let trend {
                TimeTrendChart(series: trend, color: statusColor, isPercentage: true, thresholds: storageThresholds, compact: true)
                    .equatable()
                    .frame(height: 86)
            }

            if let fileLimit = item.fileLimit ?? item.fileQuota, fileLimit > 0 {
                StorageFileBar(count: item.fileCount, limit: fileLimit)
            }
        }
        // Fill the row height StorageColumnsLayout offers, so neighbouring
        // cards line up even when only some have a trend chart or file bar.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dashboardCard(accent: tone == .warning || tone == .critical ? statusColor : .primary)
        .animation(AppTheme.smoothEase, value: percent)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.label) storage")
        .accessibilityValue(accessibilitySummary)
    }

    /// A ring for known usage; a dashed placeholder when the collector could
    /// not read this space (a required volume is still reported, with nulls),
    /// so "unknown" never masquerades as "0% used".
    @ViewBuilder
    private var ringMeter: some View {
        if item.usedPercent != nil {
            RingMeter(value: percent / 100, color: statusColor, label: isOverQuota ? "over" : "used")
        } else {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.14), style: StrokeStyle(lineWidth: 9, dash: [4, 4]))
                Text(missingValuePlaceholder)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Usage not available")
        }
    }

    private var overQuotaBadge: some View {
        Label("Over quota", systemImage: "exclamationmark.triangle.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(StatusTone.critical.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(StatusTone.critical.color.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(StatusTone.critical.color.opacity(0.28), lineWidth: 1))
            .help("Usage is above the soft quota. Writes start failing once the grace period expires or the hard limit is reached.")
    }

    private var pathHelp: String {
        var lines = [item.path]
        if let mount = item.mount, !mount.isEmpty {
            lines.append("Mount: \(mount)")
        }
        if !item.filesystem.isEmpty {
            lines.append("Filesystem: \(item.filesystem)")
        }
        return lines.joined(separator: "\n")
    }

    private var accessibilitySummary: String {
        var parts: [String] = []
        if item.usedPercent != nil {
            parts.append("\(Int((item.usedPercent ?? 0).rounded())) percent used")
        } else {
            parts.append("usage not available")
        }
        if isOverQuota {
            parts.append("over quota")
        } else if item.fileCountDominates, let files = item.fileUsedPercent {
            parts.append("\(Int(files.rounded())) percent of the file limit")
        }
        switch tone {
        case .warning: parts.append("warning")
        case .critical: parts.append("critical")
        default: break
        }
        if let caption = StorageCard.quotaCaption(for: item) {
            parts.append(caption)
        }
        if item.kind.isSharedAcrossClusters {
            parts.append("shared by all Leeds clusters")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Shared presentation rules (also used by StorageComparison)

    /// The status colour of a space: the shared tone (space or file count,
    /// whichever is closer to its limit; over quota is critical). Green
    /// while healthy, never the kind colour, so an orange-ish identity can
    /// not pass for a warning.
    static func statusColor(for item: StorageSummary) -> Color {
        item.usageTone.color
    }

    /// How the numbers were measured, e.g. "Lustre project quota · project
    /// 123456". Calder governs scratch/flash by Lustre *project* quotas and
    /// AIRE by per-user quotas; showing which avoids confusing the two.
    static func quotaCaption(for item: StorageSummary) -> String? {
        if item.source == "unavailable" {
            return item.unavailableCaption
        }
        switch item.quotaType {
        case "lustre-project":
            if let projectID = item.projectID {
                return "Lustre project quota · project \(projectID)"
            }
            return "Lustre project quota"
        case "lustre-user":
            return "Lustre user quota"
        case "nfs":
            return "NFS quota"
        case "df":
            return "Filesystem usage (df)"
        default:
            // Snapshots from before quota_type existed only carry `source`.
            switch item.source {
            case "quota":
                return "NFS quota"
            case "lfs quota":
                return "Lustre quota"
            case "df":
                return "Filesystem usage (df)"
            default:
                return nil
            }
        }
    }

    static func quotaIcon(for item: StorageSummary) -> String {
        if item.source == "unavailable" {
            return "questionmark.folder"
        }
        switch item.quotaType {
        case "lustre-project":
            return "folder.badge.person.crop"
        case "lustre-user":
            return "person.crop.circle"
        case "nfs":
            return "network"
        default:
            return "chart.pie"
        }
    }

    static func quotaHelp(for item: StorageSummary) -> String {
        if item.source == "unavailable" {
            return item.unavailableHelp
        }
        switch item.quotaType {
        case "lustre-project":
            return "Usage of the Lustre project this directory belongs to (lfs quota -p)."
        case "lustre-user":
            return "Your per-user usage on this Lustre filesystem (lfs quota -u)."
        case "nfs":
            return "Your quota on the NFS export (quota -s)."
        case "df":
            return "No personal quota could be read, so these are whole-filesystem totals from df, shared with every user."
        default:
            return "Quota source: \(item.source)"
        }
    }
}

/// Equal-width card columns that never leave a column empty: as many columns
/// as fit at `minimumColumnWidth`, capped at the number of cards, with every
/// row as tall as its tallest card. An adaptive LazyVGrid would show three
/// spaces as three cards plus a blank fourth slot on a wide window.
private struct StorageColumnsLayout: Layout {
    var minimumColumnWidth: CGFloat
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = resolvedWidth(proposal, itemCount: subviews.count)
        let columns = columnCount(width: width, itemCount: subviews.count)
        let heights = rowHeights(subviews: subviews, columns: columns, columnWidth: columnWidth(width: width, columns: columns))
        let height = heights.reduce(0, +) + spacing * CGFloat(max(heights.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = columnCount(width: bounds.width, itemCount: subviews.count)
        let width = columnWidth(width: bounds.width, columns: columns)
        var y = bounds.minY
        for (row, height) in rowHeights(subviews: subviews, columns: columns, columnWidth: width).enumerated() {
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else {
                    break
                }
                subviews[index].place(
                    at: CGPoint(x: bounds.minX + CGFloat(column) * (width + spacing), y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: width, height: height)
                )
            }
            y += height + spacing
        }
    }

    /// An unspecified or infinite width (ideal-size query) gets one minimum
    /// column per card.
    private func resolvedWidth(_ proposal: ProposedViewSize, itemCount: Int) -> CGFloat {
        if let width = proposal.width, width.isFinite {
            return width
        }
        let count = CGFloat(max(itemCount, 1))
        return minimumColumnWidth * count + spacing * (count - 1)
    }

    private func columnCount(width: CGFloat, itemCount: Int) -> Int {
        let fitting = Int((width + spacing) / (minimumColumnWidth + spacing))
        return min(max(fitting, 1), max(itemCount, 1))
    }

    private func columnWidth(width: CGFloat, columns: Int) -> CGFloat {
        max((width - spacing * CGFloat(columns - 1)) / CGFloat(columns), 0)
    }

    private func rowHeights(subviews: Subviews, columns: Int, columnWidth: CGFloat) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
                .max() ?? 0
        }
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

    private var ratio: Double {
        min(Double(count ?? 0) / Double(max(limit, 1)), 1)
    }

    private var tone: StatusTone {
        count == nil ? .unavailable : StatusTone(usedPercent: ratio * 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Files")
                Spacer()
                Text("\(count.map(groupedNumber) ?? missingValuePlaceholder) of \(groupedNumber(limit))")
                    .monospacedDigit()
                    .foregroundStyle(tone == .normal || tone == .unavailable ? Color.secondary : tone.color)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            ProgressView(value: ratio)
                .tint(tone.color)
                .accessibilityLabel("File count usage")
                .accessibilityValue("\(Int((ratio * 100).rounded())) percent")
        }
    }
}

struct StorageComparison: View {
    let storage: [StorageSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Space balance", subtitle: "Used share of each space's limit · warning from 75 %, critical from 90 %")
            // A Grid sizes the label column to the longest label, so
            // "Scratch" or a future "Project flash" never truncates while the
            // bars still line up.
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                ForEach(storage) { item in
                    GridRow {
                        Label {
                            Text(item.label)
                        } icon: {
                            Image(systemName: item.kind.systemImage)
                                .foregroundStyle(item.kind.color)
                        }
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .fixedSize()
                            .accessibilityHidden(true)
                        usageBar(for: item)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(item.label) usage")
                            .accessibilityValue(accessibilityValue(for: item))
                        Text(pressureText(for: item))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(item.usageTone == .normal || item.usageTone == .unavailable ? Color.primary : item.usageTone.color)
                            .gridColumnAlignment(.trailing)
                            .accessibilityHidden(true)
                        Text("\(formatGB(item.usedGB)) / \(formatGB(item.limitGB))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .gridColumnAlignment(.trailing)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .dashboardCard(accent: .teal)
    }

    /// "63%", or "95% files" when the file count is the closer limit, so
    /// the figure agrees with the colour beside it.
    private func pressureText(for item: StorageSummary) -> String {
        if item.fileCountDominates, let files = item.fileUsedPercent {
            return "\(percentText(files)) files"
        }
        return percentText(item.usedPercent)
    }

    private func usageBar(for item: StorageSummary) -> some View {
        let ratio = CGFloat(min(max((item.usedPercent ?? 0) / 100, 0), 1))
        return RoundedRectangle(cornerRadius: 5)
            .fill(AppTheme.mutedFill)
            .frame(height: 12)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 5)
                        .fill(StorageCard.statusColor(for: item).opacity(0.85))
                        .frame(width: proxy.size.width * ratio)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func accessibilityValue(for item: StorageSummary) -> String {
        var value = percentText(item.usedPercent)
        if item.overQuota == true {
            value += ", over quota"
        } else if item.fileCountDominates, let files = item.fileUsedPercent {
            value += ", \(Int(files.rounded())) percent of the file limit"
        }
        return value
    }
}
