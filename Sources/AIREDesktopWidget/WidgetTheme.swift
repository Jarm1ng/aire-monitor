import AppKit
import HPCCore
import SwiftUI

/// Geometry and cadences. The width is fixed; the height grows by one
/// cluster row per monitored cluster, so every cluster gets its own row of
/// numbers instead of being merged into one misleading fleet total (AIRE's
/// L40S and Calder's H200 pools are different hardware on different
/// schedulers). Refresh cadence and staleness thresholds are not here: they
/// come from HPCDefaults, shared with the app.
enum WidgetLayout {
    static let width: CGFloat = 548
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 12
    static let headerHeight: CGFloat = 30
    static let footerHeight: CGFloat = 26
    static let sectionSpacing: CGFloat = 10
    static let clusterRowHeight: CGFloat = 108
    static let clusterRowSpacing: CGFloat = 8
    /// Rows beyond this are summarised in the footer so the window can never
    /// outgrow a laptop screen if more clusters appear.
    static let maxVisibleClusters = 4
    /// How often the widget polls the cluster directories for changes (belt
    /// and braces alongside the directory watchers). Polling only stats
    /// files; collection has its own cadence and backoff.
    static let filePollInterval: TimeInterval = 2
    /// How often relative ages ("12 min ago") are re-rendered.
    static let ageRefreshInterval: TimeInterval = 30
    /// Opacity and saturation of a row's numbers while they are not live, so
    /// an old "1 free" can never pass for a current one at a glance.
    static let staleOpacity: Double = 0.55
    static let staleSaturation: Double = 0.2

    /// Header, one row per cluster (at least one, for the empty state) and
    /// the footer: about 116 pt per cluster on top of 90 pt of chrome.
    static func height(forClusterRows rows: Int) -> CGFloat {
        let rows = max(rows, 1)
        return verticalPadding * 2
            + headerHeight
            + sectionSpacing * 2
            + footerHeight
            + CGFloat(rows) * clusterRowHeight
            + CGFloat(rows - 1) * clusterRowSpacing
    }
}

enum WidgetPalette {
    static let backgroundOverlay = Color(nsColor: .windowBackgroundColor).opacity(0.42)
    static let fill = Color.primary.opacity(0.040)
    static let fillStrong = Color.primary.opacity(0.070)
    static let border = Color.primary.opacity(0.085)
    static let highlight = Color.primary.opacity(0.10)
    static let cyan = Color.cyan
    static let green = Color.green
    static let orange = Color.orange
    static let red = Color.red
    static let neutral = Color.secondary

    /// Matches the main app's job-state semantics: running = green,
    /// pending = orange, anything else (suspended, completing, …) neutral.
    static func jobStateColor(_ state: JobState) -> Color {
        if state.isRunning {
            return green
        }
        if state.isPending {
            return orange
        }
        return neutral
    }

    /// Occupancy is capacity, not a status: allocated GPUs are cyan (paler
    /// while partly allocated), free ones green, unavailable ones grey —
    /// the app's Nodes heatmap rule. Orange and red stay for warnings and
    /// faults.
    static func gpuColor(allocatedRatio: Double, isAvailable: Bool = true) -> Color {
        guard isAvailable else {
            return Color.gray
        }
        if allocatedRatio >= 1 {
            return cyan
        }
        if allocatedRatio > 0 {
            return cyan.opacity(0.6)
        }
        return green
    }

    /// One heatmap cell, coloured by what a new job could do there (the same
    /// rule as the free count): grey when the node accepts no work, faint
    /// neutral when its allocation is unknown, cyan when no job can start
    /// (every GPU allocated, or every CPU taken so its idle GPU is
    /// stranded), pale cyan when partly allocated, green when entirely free.
    static func heatmapColor(for node: NodeSummary) -> Color {
        guard node.stateInfo.isAvailable else {
            return Color.gray.opacity(0.7)
        }
        guard let allocated = node.knownGPUAllocated else {
            return neutral.opacity(0.35)
        }
        let total = max(node.gpuCount, 1)
        if node.cpusFull {
            return cyan.opacity(0.88)
        }
        let ratio = Double(allocated) / Double(total)
        if ratio > 0 && ratio < 1 {
            return cyan.opacity(0.5)
        }
        return gpuColor(allocatedRatio: ratio).opacity(ratio > 0 ? 0.88 : 0.80)
    }

    /// Same thresholds as the app's StalenessBadge: orange while cached data
    /// is under an hour old, red from an hour (HPCDefaults.snapshotOldAfter).
    static func ageColor(age: TimeInterval) -> Color {
        age >= HPCDefaults.snapshotOldAfter ? red : orange
    }
}

extension ClusterIdentity {
    /// Same colour as the app's cluster accent, so a cluster looks the same
    /// in the widget, the dashboard and the menu bar; unknown clusters get
    /// ClusterIdentity's neutral grey.
    var accentColor: Color {
        Color(red: accentRed, green: accentGreen, blue: accentBlue)
    }
}

extension View {
    func widgetSurface() -> some View {
        self
            .padding(10)
            .background(WidgetPalette.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(WidgetPalette.border, lineWidth: 1)
            )
    }

    func singleLine() -> some View {
        self
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .truncationMode(.tail)
    }

    /// Mutes numbers that are not live (cached, paused or off).
    func staleDimmed(_ isStale: Bool) -> some View {
        self
            .opacity(isStale ? WidgetLayout.staleOpacity : 1)
            .saturation(isStale ? WidgetLayout.staleSaturation : 1)
    }
}

struct WidgetLogoMark: View {
    var cornerRadius: CGFloat = 7

    @MainActor private static let cachedLogo: NSImage? = loadLogoImage()

    var body: some View {
        Group {
            if let image = Self.cachedLogo {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "server.rack")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(WidgetPalette.cyan)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(WidgetPalette.cyan.opacity(0.13))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.primary.opacity(0.18), lineWidth: 1)
        )
    }

    /// The neutral Leeds HPC mark: the widget covers every cluster, so it
    /// must not wear one cluster's logo.
    private static func loadLogoImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "LeedsHPCMark", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        guard let root = ProjectLocator.findProjectRoot() else {
            return nil
        }
        return NSImage(contentsOfFile: root + "/assets/LeedsHPCMark.png")
    }
}

/// Circular cluster monogram in the cluster's accent colour, mirroring the
/// app's ClusterBadge.
struct ClusterMonogram: View {
    let identity: ClusterIdentity
    var size: CGFloat = 20

    var body: some View {
        Text(identity.monogram)
            .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(identity.accentColor.gradient, in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
            // The cluster name is always printed right next to the badge.
            .accessibilityHidden(true)
    }
}
