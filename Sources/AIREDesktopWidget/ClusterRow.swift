import HPCCore
import SwiftUI

/// One cluster: identity and status on top, then its GPU pools, its jobs and
/// its GPU-node heatmap. Every number in the row belongs to this cluster.
/// Numbers that are not live (cached, paused, off) are muted and their age
/// is spelled out, so a two-hour-old green "1 free" cannot pass for a
/// current one.
struct ClusterRow: View {
    @ObservedObject var feed: ClusterFeed

    var body: some View {
        let digest = ClusterDigest(snapshot: feed.snapshot)
        let isStale = feed.snapshot != nil && feed.status != .live
        VStack(alignment: .leading, spacing: 6) {
            titleLine
                .frame(height: 20)

            HStack(alignment: .center, spacing: 12) {
                gpuGauge(digest, isStale: isStale)
                    .staleDimmed(isStale)
                Rectangle()
                    .fill(WidgetPalette.border)
                    .frame(width: 1)
                    .padding(.vertical, 4)
                activity(digest)
                    .staleDimmed(isStale)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetSurface()
        .animation(.easeInOut(duration: 0.28), value: digest.fleet.allocated)
        .animation(.easeInOut(duration: 0.28), value: digest.fleet.total)
        .animation(.easeInOut(duration: 0.28), value: digest.runningCount)
        .animation(.easeInOut(duration: 0.28), value: digest.pendingCount)
        .animation(.easeInOut(duration: 0.28), value: isStale)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(feed.displayName)
    }

    private var titleLine: some View {
        HStack(spacing: 7) {
            ClusterMonogram(identity: feed.identity)

            Text(feed.displayName)
                .font(.system(size: 14, weight: .semibold))
                .singleLine()
                .contentTransition(.opacity)

            StatusChip(title: feed.status.title, value: chipValue, color: feed.status.color)
                .help(chipHelp)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(feed.displayName) status")
                .accessibilityValue("\(feed.status.title), \(chipValue)")

            Spacer(minLength: 6)

            if feed.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Collecting \(feed.displayName) snapshot")
            }

            SnapshotAgeText(date: feed.snapshotDate, status: feed.status, clusterName: feed.displayName)
        }
    }

    private var chipValue: String {
        switch feed.status {
        case .live, .cached:
            return feed.remoteName ?? "login node"
        case .connecting:
            return "waiting"
        case .offline:
            return "no data"
        case .paused, .off:
            return "in the app"
        }
    }

    /// Errors and notices first, with when the widget retries; otherwise
    /// the collector's warnings (an enrichment step such as storage or job
    /// details that failed while the core data is fine). Tooltip only: the
    /// row has no room for them, and they never make the snapshot less
    /// trustworthy for what the row shows.
    private var chipHelp: String {
        if let message = feed.errorMessage ?? feed.notice {
            var lines = [message]
            if feed.status.isUserChoice {
                lines.append("The widget never collects a cluster the app has paused or switched off.")
            }
            if let next = feed.nextAutomaticAttempt {
                lines.append("Next attempt at \(next.formatted(date: .omitted, time: .standard)).")
            }
            return lines.joined(separator: "\n")
        }
        let warnings = feed.snapshot?.warnings ?? []
        guard !warnings.isEmpty else {
            return chipValue
        }
        let shown = warnings.prefix(3).joined(separator: "\n")
        let more = warnings.count > 3 ? "\n(+\(warnings.count - 3) more)" : ""
        return "\(chipValue)\n\(shown)\(more)"
    }

    private func gpuGauge(_ digest: ClusterDigest, isStale: Bool) -> some View {
        let hasGPUs = digest.hasGPUs
        let model = digest.modelLabel
        let accent = feed.identity.accentColor
        return HStack(spacing: 10) {
            RingMeter(
                value: digest.gpuRatio ?? 0,
                color: digest.gpuColor,
                label: hasGPUs ? digest.gpuPercentLabel : "–",
                lineWidth: 6
            )
            .frame(width: 52, height: 52)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(feed.displayName) \(model) GPU usage")
            .accessibilityValue(hasGPUs ? digest.gpuAccessibilityValue : "No GPU data")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(model)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(accent.opacity(0.14), in: Capsule())
                        .singleLine()
                    Text("free")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .singleLine()
                }

                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(hasGPUs ? digest.freeFigure : "–")
                        .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(idleColor(digest, isStale: isStale))
                        .contentTransition(.opacity)
                    if hasGPUs {
                        Text("/\(digest.fleet.total)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .singleLine()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(feed.displayName) free GPUs")
                .accessibilityValue(digest.freeAccessibilityValue)

                GPUUsageBar(fleet: digest.fleet, color: digest.allocatedSegmentColor)
                    .accessibilityHidden(true)
            }
            .frame(width: 112, alignment: .leading)
        }
        .help(digest.gpuHelp)
    }

    private func idleColor(_ digest: ClusterDigest, isStale: Bool) -> Color {
        guard digest.hasGPUs, !isStale else {
            return .secondary
        }
        // The app's one GPU-pool rule (HPCCore `GPUPool.idleTone`): green
        // while any pool has a startable GPU, orange when a pool is known
        // full (never red), grey when every pool is unknown or out of
        // service — a drained pool's "0" is not a full one.
        let tones = digest.fleet.pools.map(\.idleTone)
        if tones.contains(.normal) {
            return WidgetPalette.green
        }
        if tones.contains(.warning) {
            return WidgetPalette.orange
        }
        return WidgetPalette.neutral
    }

    private func activity(_ digest: ClusterDigest) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                // Unknown is not zero: without a snapshot the pills show a dash.
                let hasData = feed.snapshot != nil
                JobCountPill(title: "Run", value: hasData ? digest.runningCount : nil, color: WidgetPalette.green)
                    .accessibilityLabel("\(feed.displayName) running jobs")
                JobCountPill(title: "Wait", value: hasData ? digest.pendingCount : nil, color: WidgetPalette.orange)
                    .accessibilityLabel("\(feed.displayName) pending jobs")
                    .help("Queued jobs that can start, counting every task of a pending job array; held jobs are counted apart")
                if hasData && digest.heldCount > 0 {
                    JobCountPill(title: "Held", value: digest.heldCount, color: WidgetPalette.neutral)
                        .accessibilityLabel("\(feed.displayName) held jobs")
                        .help("Held jobs: queued, but they will not start until released (scontrol release)")
                }
                Spacer(minLength: 4)
                let downNodes = digest.fleet.unavailableNodes
                if downNodes > 0 {
                    Label("\(downNodes) down", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        // Grey like nodes that accept no work everywhere in
                        // the app: out of the pool, not a fault of the user's.
                        .foregroundStyle(WidgetPalette.neutral)
                        .singleLine()
                        .help("\(downNodes) GPU node\(downNodes == 1 ? "" : "s") drained, down, reserved or in maintenance")
                        .accessibilityLabel("\(downNodes) GPU nodes unavailable on \(feed.displayName)")
                }
            }

            jobLine(digest)
                .frame(height: 16)

            HStack(spacing: 8) {
                GPUHeatmapStrip(nodes: digest.gpuNodes, clusterName: feed.displayName)
                Text("\(digest.gpuNodes.count) \(digest.gpuNodes.count == 1 ? "node" : "nodes")")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .frame(height: 12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(feed.displayName) GPU nodes")
            .accessibilityValue(digest.nodeAccessibilityValue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func jobLine(_ digest: ClusterDigest) -> some View {
        if feed.snapshot == nil {
            Label(
                feed.status == .connecting ? "Waiting for the first snapshot" : "No snapshot yet",
                systemImage: "hourglass"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .singleLine()
        } else if let job = digest.topJob {
            TopJobRow(job: job, clusterName: feed.displayName)
        } else {
            Label("No active jobs", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(WidgetPalette.green)
                .singleLine()
        }
    }
}

/// The snapshot's collection time: the clock time while live, otherwise its
/// age ("12 min ago", the app's relative style) in orange, red from an hour,
/// re-rendered every 30 s so it keeps escalating while nothing else changes.
struct SnapshotAgeText: View {
    let date: Date?
    let status: WidgetDataStatus
    let clusterName: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: WidgetLayout.ageRefreshInterval)) { context in
            let text = text(now: context.date)
            Text(text)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(color(now: context.date))
                .singleLine()
                .contentTransition(.opacity)
                .accessibilityLabel("\(clusterName) snapshot time")
                .accessibilityValue(text)
        }
        .help(date.map { "Collected \($0.formatted(date: .abbreviated, time: .standard))" } ?? "No snapshot yet")
    }

    private func text(now: Date) -> String {
        guard let date else {
            return status == .connecting ? "waiting" : "not updated"
        }
        if status == .live {
            return date.formatted(date: .omitted, time: .standard)
        }
        return SlurmTimestamp.ageText(from: date, now: now)
    }

    private func color(now: Date) -> Color {
        guard let date, status != .live else {
            return .secondary
        }
        return WidgetPalette.ageColor(age: now.timeIntervalSince(date))
    }
}

/// Shown until the app has written at least one cluster directory.
struct EmptyClustersCard: View {
    let onOpenApp: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("No clusters yet")
                    .font(.callout.weight(.semibold))
                Text("Open Leeds HPC Monitor and connect; each cluster appears here after its first snapshot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Open Monitor", action: onOpenApp)
                .controlSize(.small)
                .help("Open Leeds HPC Monitor")
                .accessibilityLabel("Open Leeds HPC Monitor")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetSurface()
    }
}

/// Shown instead of any cluster row when the widget cannot find the
/// checkout it reads `.runtime/` from (a bundle copied out of the project,
/// or launched with no usable working directory). Nothing else would work,
/// and "connect in the app" would send the user the wrong way.
struct MissingProjectCard: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(WidgetPalette.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Cannot find the Leeds HPC checkout")
                    .font(.callout.weight(.semibold))
                Text("Launch the widget from Leeds HPC Monitor, or set HPC_PROJECT_ROOT to the project folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetSurface()
        .accessibilityElement(children: .combine)
    }
}
