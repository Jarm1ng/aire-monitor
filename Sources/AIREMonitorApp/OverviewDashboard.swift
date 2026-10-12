import AppKit
import SwiftUI

// MARK: - Overview

/// The default landing view: every monitored cluster side by side, where
/// capacity is idle right now, and the user's jobs from all clusters in one
/// list.
///
/// Two rules shape everything on this page:
/// - Numbers from different clusters are never silently added together. An
///   L40S and an H200 are different pools, Slurm job ids and node names are
///   only unique within one controller, and the /users home quota is one NFS
///   export that every cluster reports. Anything cross-cluster is shown per
///   cluster, tagged with its badge.
/// - A cluster without a snapshot shows an explicit "not connected" / "off"
///   state, never zeros, so "no data" can never read as "nothing running".
struct OverviewDashboard: View {
    @ObservedObject var model: AppModel

    /// The combined job list is capped until expanded, so a long array-job
    /// backlog does not cost hundreds of rows on every 10-second refresh.
    @State private var showAllJobs = false

    private static let collapsedJobLimit = 40

    var body: some View {
        // One pass over every session per render; each section below reads
        // from this digest instead of re-filtering the snapshots itself.
        let digest = OverviewDigest(sessions: model.sessions)

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(digest)

                OverviewAdaptiveGrid(minimumColumnWidth: 400, spacing: 12) {
                    ForEach(model.sessions) { session in
                        ClusterOverviewCard(model: model, session: session)
                    }
                }

                if !digest.reporting.isEmpty {
                    OverviewRunNowStrip(reports: digest.reporting, missing: digest.missing)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                jobsSection(digest)
            }
            .padding(18)
        }
        .animation(AppTheme.smoothEase, value: digest.reporting.count)
        .animation(AppTheme.smoothEase, value: showAllJobs)
    }

    // MARK: Header

    private func header(_ digest: OverviewDigest) -> some View {
        // The subtitle carries a relative age ("updated 12 sec. ago"); the
        // timeline keeps it ticking between refreshes, and while every
        // cluster is paused or offline, when nothing else repaints the page.
        TimelineView(.periodic(from: .now, by: 15)) { context in
            PageHeader(
                title: "Overview",
                subtitle: digest.summary(now: context.date),
                systemImage: "rectangle.3.group",
                accent: AppTheme.gpu
            ) {
                refreshAllButton
            }
        }
    }

    private var refreshAllButton: some View {
        Button {
            model.refreshAll()
        } label: {
            HStack(spacing: 6) {
                if model.isAnyRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text("Refresh all")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(model.enabledSessions.isEmpty)
        .keyboardShortcut("r", modifiers: .command)
        .help("Refresh every enabled cluster now (⌘R)")
    }

    // MARK: Jobs

    @ViewBuilder
    private func jobsSection(_ digest: OverviewDigest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            OverviewJobsHeader(digest: digest)

            if digest.reporting.isEmpty {
                EmptyVisual(
                    title: "No job data yet",
                    subtitle: digest.missing.isEmpty
                        ? "Every cluster is switched off. Turn one on to see your Slurm jobs here."
                        : "Connect to a cluster to see your Slurm jobs here. Nothing is listed until a real snapshot arrives.",
                    systemImage: "list.bullet.rectangle"
                )
            } else if digest.jobs.isEmpty {
                EmptyVisual(
                    title: "No jobs in any queue",
                    subtitle: digest.emptyQueueDetail,
                    systemImage: "checkmark.circle"
                )
            } else {
                let limit = Self.collapsedJobLimit
                let visible = showAllJobs ? digest.jobs : Array(digest.jobs.prefix(limit))
                VStack(spacing: 0) {
                    // Full columns when the window is wide enough; otherwise
                    // two-line rows that keep every field readable.
                    ViewThatFits(in: .horizontal) {
                        OverviewJobsWideTable(entries: visible, onOpen: openJob)
                        OverviewJobsCompactList(entries: visible, onOpen: openJob)
                    }

                    if digest.jobs.count > limit {
                        Divider()
                        Button(showAllJobs ? "Show the first \(limit) jobs" : "Show all \(digest.jobs.count) jobs") {
                            showAllJobs.toggle()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .padding(.vertical, 8)
                    }
                }
                .dashboardCard(padding: 6, accent: .blue)
            }
        }
    }

    /// Jumps to the job's own cluster, on its Jobs tab, with the job sheet
    /// open. The dashboard state is set before the selection changes, so the
    /// cluster view already finds the job when it appears and its
    /// `sheet(item:)` presents it straight away.
    private func openJob(_ entry: OverviewJobEntry) {
        guard let session = model.session(for: entry.profile.id) else {
            return
        }
        session.dashboard.selectedTab = .jobs
        session.dashboard.selectedJob = entry.job
        model.selection = .cluster(entry.profile.id)
    }
}

// MARK: - Cluster card

/// One cluster's at-a-glance card: identity, connection state, snapshot age,
/// the headline numbers and its storage. It observes its own session, so it
/// repaints whenever that cluster changes, independently of the page.
struct ClusterOverviewCard: View {
    /// Used for actions only (connect, selection). Not observed: everything
    /// the card displays comes from `session`.
    let model: AppModel
    @ObservedObject var session: ClusterSession

    var body: some View {
        let state = session.connectionState
        let accent = session.profile.accent.color

        VStack(alignment: .leading, spacing: 14) {
            header(state: state)

            if session.isEnabled, let error = session.errorMessage, !error.isEmpty {
                errorLine(error)
            }

            content(state: state)

            if session.isEnabled, session.snapshot != nil {
                // Figures keep their natural height; the placeholder states
                // instead grow to fill the card (see OverviewCardPlaceholder).
                Spacer(minLength: 0)
            }

            footer(state: state, accent: accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dashboardCard(padding: 16, accent: accent)
        .animation(AppTheme.smoothEase, value: state)
        .animation(AppTheme.smoothEase, value: session.snapshot == nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(session.displayName) cluster")
    }

    /// The login host the session actually uses: a blank Advanced field
    /// falls back to the profile default, exactly like `settings`.
    private var hostname: String {
        let trimmed = session.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? session.profile.defaultHostname : trimmed
    }

    // MARK: Header

    private func header(state: ClusterConnectionState) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ClusterBadge(profile: session.profile, size: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .font(.title3.weight(.semibold))
                Text(hostname)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(session.profile.tagline)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help(session.profile.tagline)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                ConnectionStatePill(state: state)
                if session.isEnabled, let collectedAt = session.snapshot?.collectedAt, !collectedAt.isEmpty {
                    StalenessBadge(collectedAt: collectedAt)
                }
            }
        }
    }

    private func errorLine(_ error: String) -> some View {
        // First line only: full collector/SSH errors can run to many lines
        // and are shown in full in the sidebar and on hover.
        let firstLine = error
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? error
        return Label(firstLine, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .lineLimit(2)
            .help(error)
            .accessibilityLabel("Error")
            .accessibilityValue(error)
    }

    // MARK: Content

    @ViewBuilder
    private func content(state: ClusterConnectionState) -> some View {
        if !session.isEnabled {
            OverviewCardPlaceholder(
                systemImage: "power.circle",
                title: "Monitoring is off",
                detail: "\(session.displayName) is not being polled, so nothing is shown here. "
                    + "Turn it on to see your jobs, idle GPUs and storage.",
                showsProgress: false
            )
        } else if let snapshot = session.snapshot {
            OverviewClusterFigures(
                profile: session.profile,
                snapshot: snapshot,
                stats: OverviewClusterStats(
                    profile: session.profile,
                    snapshot: snapshot,
                    gpu: session.gpuAvailability
                )
            )
        } else if state == .connecting {
            OverviewCardPlaceholder(
                systemImage: "person.badge.key",
                title: "Signing in to \(session.displayName)…",
                detail: session.loginProgress ?? "Approve the Duo push on your phone when it arrives.",
                showsProgress: true
            )
        } else if state == .queued {
            OverviewCardPlaceholder(
                systemImage: "hourglass",
                title: "Waiting to sign in",
                detail: "Sign-ins run one at a time so Duo pushes arrive in order.",
                showsProgress: true
            )
        } else if state == .live {
            OverviewCardPlaceholder(
                systemImage: "arrow.triangle.2.circlepath",
                title: "Collecting the first snapshot…",
                detail: "Jobs, GPUs and storage appear as soon as it lands.",
                showsProgress: true
            )
        } else if state == .paused {
            OverviewCardPlaceholder(
                systemImage: "pause.circle",
                title: "Monitoring paused",
                detail: "No snapshot has been collected yet. Resume to start polling \(hostname).",
                showsProgress: false
            )
        } else if session.isRefreshing {
            // Startup / route-change probe: it reuses an SSH session that is
            // already open, and fails quietly to "Not connected" otherwise.
            OverviewCardPlaceholder(
                systemImage: "antenna.radiowaves.left.and.right",
                title: "Checking for a live session…",
                detail: "Looking for an SSH session to \(hostname) that is already open.",
                showsProgress: true
            )
        } else {
            OverviewCardPlaceholder(
                systemImage: "bolt.horizontal.circle",
                title: "Not connected yet",
                detail: "Connect to load your jobs, idle GPUs and storage from \(hostname). "
                    + "No numbers are shown until a real snapshot arrives.",
                showsProgress: false
            )
        }
    }

    // MARK: Footer

    private func footer(state: ClusterConnectionState, accent: Color) -> some View {
        VStack(spacing: 10) {
            Divider()
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    // Only sign-in shows a spinner: a live session refreshes
                    // every 10 s, and a spinner flickering that often would
                    // be noise rather than information.
                    if state.isBusy {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(session.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .help(session.statusMessage)

                Spacer(minLength: 8)

                actionButtons(state: state, accent: accent)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private func actionButtons(state: ClusterConnectionState, accent: Color) -> some View {
        HStack(spacing: 8) {
            switch state {
            case .disabled:
                Button {
                    session.isEnabled = true
                } label: {
                    Label("Turn on", systemImage: "power")
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .help("Start monitoring \(session.displayName)")
            case .notConnected, .cached:
                Button {
                    model.connect(session.id)
                } label: {
                    Label("Connect", systemImage: "person.crop.circle.badge.checkmark")
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .help("Sign in to \(session.displayName) with the account in the sidebar")
            case .paused:
                Button {
                    session.togglePause()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .help("Resume background refreshes for \(session.displayName)")
            case .queued, .connecting, .live:
                EmptyView()
            }

            Button {
                model.selection = .cluster(session.id)
            } label: {
                Label("Open dashboard", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.bordered)
            .help("Show the full \(session.displayName) dashboard")
        }
    }
}

/// Friendly stand-in for a card's figures while there is no snapshot to
/// show. Deliberately shaped like content, not like zeroed metrics.
private struct OverviewCardPlaceholder: View {
    let systemImage: String
    let title: String
    let detail: String
    let showsProgress: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.06))
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        // Grows to the card's height when the neighbouring card is taller,
        // so a placeholder never leaves a ragged gap above the footer.
        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Card figures

private struct OverviewClusterFigures: View {
    let profile: ClusterProfile
    let snapshot: ClusterSnapshot
    let stats: OverviewClusterStats

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    jobsTile
                    gpuTile
                }
                GridRow {
                    cpuTile
                    nodesTile
                }
            }
            // Ideal height only: when this card is stretched to match a
            // taller neighbour, the slack goes to the card's spacer instead
            // of inflating the tiles.
            .fixedSize(horizontal: false, vertical: true)

            OverviewFlowLayout(spacing: 6, lineSpacing: 6) {
                if let walltime = stats.walltime {
                    InfoChip(
                        label: "Max walltime",
                        value: walltime.display,
                        systemImage: "hourglass",
                        color: profile.accent.color
                    )
                    .help(walltime.detail)
                }
                InfoChip(
                    label: "Partitions",
                    value: "\(stats.partitionCount)",
                    systemImage: "square.grid.2x2",
                    color: .purple
                )
                if !snapshot.warnings.isEmpty {
                    InfoChip(
                        label: "Collector warnings",
                        value: "\(snapshot.warnings.count)",
                        systemImage: "exclamationmark.triangle",
                        color: .orange
                    )
                    .help(snapshot.warnings.joined(separator: "\n"))
                }
            }

            storageSection
        }
    }

    // MARK: Tiles

    private var jobsTile: some View {
        OverviewStatTile(
            title: "My jobs",
            systemImage: "list.bullet.rectangle",
            accent: .blue,
            value: "\(stats.runningJobs)",
            unit: "running",
            caption: stats.otherJobs > 0
                ? "\(stats.pendingJobs) pending · \(stats.otherJobs) other"
                : "\(stats.pendingJobs) pending"
        ) {
            SegmentedMeter(
                segments: [
                    MeterSegment(id: "Running", value: stats.runningJobs, color: .green),
                    MeterSegment(id: "Pending", value: stats.pendingJobs, color: .orange),
                    MeterSegment(id: "Other", value: stats.otherJobs, color: .secondary.opacity(0.6))
                ],
                height: 5
            )
        }
    }

    @ViewBuilder
    private var gpuTile: some View {
        if stats.nodeCount == 0 {
            OverviewStatTile(
                title: "Idle GPUs",
                systemImage: "memorychip",
                accent: AppTheme.gpu,
                value: missingValuePlaceholder,
                unit: nil,
                caption: "No node data in this snapshot"
            ) {
                SegmentedMeter(segments: [], height: 5)
            }
        } else if stats.totalGPUs == 0 {
            OverviewStatTile(
                title: "Idle GPUs",
                systemImage: "memorychip",
                accent: AppTheme.gpu,
                value: "None",
                unit: nil,
                caption: "No GPU nodes reported"
            ) {
                SegmentedMeter(segments: [], height: 5)
            }
        } else {
            OverviewStatTile(
                title: stats.gpuModel.map { "Idle \($0) GPUs" } ?? "Idle GPUs",
                systemImage: "memorychip",
                accent: stats.idleGPUs > 0 ? AppTheme.gpu : .orange,
                value: "\(stats.idleGPUs)",
                unit: "of \(stats.totalGPUs)",
                caption: "\(stats.busyGPUs) in use · \(stats.unavailableGPUs) unavailable"
            ) {
                SegmentedMeter(
                    segments: [
                        MeterSegment(id: "Idle", value: stats.idleGPUs, color: .green),
                        MeterSegment(id: "In use", value: stats.busyGPUs, color: AppTheme.gpu),
                        MeterSegment(id: "Unavailable", value: stats.unavailableGPUs, color: .red)
                    ],
                    height: 5
                )
            }
        }
    }

    @ViewBuilder
    private var cpuTile: some View {
        if stats.cpuNodesReporting == 0 {
            OverviewStatTile(
                title: "Idle CPU cores",
                systemImage: "cpu",
                accent: AppTheme.cpu,
                value: missingValuePlaceholder,
                unit: nil,
                caption: stats.nodeCount == 0 ? "No node data in this snapshot" : "No available CPU nodes reported"
            ) {
                SegmentedMeter(segments: [], height: 5)
            }
        } else {
            OverviewStatTile(
                title: "Idle CPU cores",
                systemImage: "cpu",
                accent: AppTheme.cpu,
                value: stats.cpuIdle.formatted(),
                unit: "of \(stats.cpuTotal.formatted())",
                caption: "on \(stats.cpuNodesReporting) available CPU node\(stats.cpuNodesReporting == 1 ? "" : "s")"
            ) {
                SegmentedMeter(
                    segments: [
                        MeterSegment(id: "Idle", value: stats.cpuIdle, color: .green),
                        MeterSegment(id: "Busy", value: max(stats.cpuTotal - stats.cpuIdle, 0), color: AppTheme.cpu)
                    ],
                    height: 5
                )
            }
        }
    }

    private var nodesTile: some View {
        let unavailable = stats.unavailableNodes
        return OverviewStatTile(
            title: "Unavailable nodes",
            systemImage: unavailable > 0 ? "exclamationmark.triangle" : "checkmark.seal",
            accent: unavailable > 0 ? .red : .green,
            value: stats.nodeCount == 0 ? missingValuePlaceholder : "\(unavailable)",
            unit: stats.nodeCount == 0 ? nil : "of \(stats.nodeCount)",
            caption: stats.nodeCount == 0
                ? "No node data in this snapshot"
                : (unavailable > 0 ? "Down, drained or failing" : "Every node is up")
        ) {
            SegmentedMeter(
                segments: [
                    MeterSegment(id: "Available", value: stats.nodeCount - unavailable, color: .green),
                    MeterSegment(id: "Unavailable", value: unavailable, color: .red)
                ],
                height: 5
            )
        }
    }

    // MARK: Storage

    private var storageSection: some View {
        let storage = snapshot.sortedStorage
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Storage", systemImage: "internaldrive")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(storage.count == 1 ? "1 space" : "\(storage.count) spaces")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if storage.isEmpty {
                Text("No storage figures in this snapshot yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(storage) { item in
                    OverviewStorageRow(item: item)
                }
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }
}

/// Compact metric used inside a cluster card. MetricView carries its own
/// glass card, which would nest card-in-card here, so this uses the lighter
/// thin-material tile the job pulse panel uses.
private struct OverviewStatTile<Accessory: View>: View {
    let title: String
    let systemImage: String
    let accent: Color
    let value: String
    let unit: String?
    let caption: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(accent)
                if let unit {
                    Text(unit)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            accessory
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .animation(AppTheme.softSpring, value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue([value, unit, caption].compactMap { $0 }.joined(separator: ", "))
    }
}

/// One storage space: usage bar, used/limit, and what kind of quota governs
/// it. The home row says it is shared, because the same /users quota appears
/// on every cluster's card and must not be read as two separate allowances.
private struct OverviewStorageRow: View {
    let item: StorageSummary

    var body: some View {
        let kind = item.kind
        let percent = OverviewFormat.usedPercent(item)
        let color = OverviewFormat.usageColor(percent: percent, kind: kind)
        let quotaCaption = OverviewFormat.quotaCaption(item)

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: kind.systemImage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(kind.color)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.label)
                            .font(.callout.weight(.semibold))
                        if item.overQuota == true {
                            Text("Over quota")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.red.opacity(0.12), in: Capsule())
                        }
                    }
                    HStack(spacing: 6) {
                        if let quotaCaption {
                            Text(quotaCaption)
                        }
                        if kind.isSharedAcrossClusters {
                            Label("shared by all clusters", systemImage: "link")
                                .foregroundStyle(StorageKind.home.color)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(OverviewFormat.usageText(item))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .lineLimit(1)
                    Text(percentText(percent))
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(color)
                }
            }

            OverviewUsageBar(fraction: percent.map { $0 / 100 }, color: color)
        }
        .help(helpText(quotaCaption: quotaCaption))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.label) storage")
        .accessibilityValue(accessibilityValue(percent: percent, quotaCaption: quotaCaption))
    }

    private func helpText(quotaCaption: String?) -> String {
        var lines = [item.path.isEmpty ? item.label : item.path]
        if let quotaCaption {
            lines.append(quotaCaption)
        }
        if item.kind.isSharedAcrossClusters {
            lines.append("/users is one NFS export mounted on every Leeds cluster: this is the same quota on each cluster's card, not a separate allowance.")
        }
        return lines.joined(separator: "\n")
    }

    private func accessibilityValue(percent: Double?, quotaCaption: String?) -> String {
        var parts = [OverviewFormat.usageText(item)]
        if let percent {
            parts.append("\(Int(percent.rounded())) percent used")
        }
        if let quotaCaption {
            parts.append(quotaCaption)
        }
        if item.kind.isSharedAcrossClusters {
            parts.append("shared by all clusters")
        }
        if item.overQuota == true {
            parts.append("over quota")
        }
        return parts.joined(separator: ", ")
    }
}

/// Thin capsule usage bar; an unknown fraction shows only the track.
private struct OverviewUsageBar: View {
    let fraction: Double?
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppTheme.mutedFill)
                if let fraction {
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: max(proxy.size.width * min(max(fraction, 0), 1), fraction > 0 ? 4 : 0))
                }
            }
        }
        .frame(height: 6)
        .animation(AppTheme.softSpring, value: fraction)
        .accessibilityHidden(true)
    }
}

// MARK: - Where can I run now?

/// Idle capacity side by side, one tile per cluster with its own snapshot
/// age. GPU models differ between clusters, so counts are compared, never
/// summed into a single "idle GPUs" figure.
private struct OverviewRunNowStrip: View {
    let reports: [OverviewClusterReport]
    let missing: [OverviewMissingCluster]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "scope")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppTheme.gpu)
                    .accessibilityHidden(true)
                SectionTitle(
                    title: "Where can I run now?",
                    subtitle: "Idle capacity from each cluster's latest snapshot. GPU models differ, so counts are never added together."
                )
            }

            OverviewAdaptiveGrid(minimumColumnWidth: 250, spacing: 10) {
                ForEach(reports) { report in
                    OverviewRunNowTile(report: report)
                }
            }

            if !missing.isEmpty {
                Label(
                    "\(missing.map(\.profile.displayName).joined(separator: " and ")) not included — no snapshot yet.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .dashboardCard(accent: AppTheme.gpu)
    }
}

private struct OverviewRunNowTile: View {
    let report: OverviewClusterReport

    var body: some View {
        let stats = report.stats
        let accent = report.profile.accent.color

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ClusterBadge(profile: report.profile, size: 22)
                Text(report.profile.displayName)
                    .font(.callout.weight(.semibold))
                if !report.isLive {
                    Text("cached")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                        .help("This cluster is not live; the numbers are from its last snapshot.")
                }
                Spacer(minLength: 6)
                if !report.collectedAt.isEmpty {
                    StalenessBadge(collectedAt: report.collectedAt)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(gpuHeadline(stats))
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(gpuColor(stats))
                Text(gpuDetail(stats))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Label(cpuLine(stats), systemImage: "cpu")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.thinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(accent.opacity(0.06))
                }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(accent.opacity(0.22), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(report.profile.displayName) idle capacity")
        .accessibilityValue(
            "\(gpuHeadline(stats)) \(gpuDetail(stats)); \(cpuLine(stats))\(report.isLive ? "" : "; cached data")"
        )
    }

    private func gpuHeadline(_ stats: OverviewClusterStats) -> String {
        if stats.nodeCount == 0 {
            return missingValuePlaceholder
        }
        if stats.totalGPUs == 0 {
            return "No GPUs"
        }
        return "\(stats.idleGPUs) × \(stats.gpuModel ?? "GPU")"
    }

    private func gpuDetail(_ stats: OverviewClusterStats) -> String {
        if stats.nodeCount == 0 {
            return "no node data in this snapshot"
        }
        if stats.totalGPUs == 0 {
            return "reported on this cluster"
        }
        return "idle of \(stats.totalGPUs)"
    }

    private func gpuColor(_ stats: OverviewClusterStats) -> Color {
        guard stats.totalGPUs > 0 else {
            return .secondary
        }
        return stats.idleGPUs > 0 ? .green : .orange
    }

    private func cpuLine(_ stats: OverviewClusterStats) -> String {
        guard stats.cpuNodesReporting > 0 else {
            return "CPU core counts not reported"
        }
        return "\(stats.cpuIdle.formatted()) of \(stats.cpuTotal.formatted()) CPU cores idle"
    }
}

// MARK: - Combined jobs

private struct OverviewJobsHeader: View {
    let digest: OverviewDigest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("My jobs across clusters")
                    .font(.headline)
                Spacer()
                Text(digest.jobsSubtitle)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            // What the list covers, per cluster, so a missing cluster is
            // visibly missing rather than silently contributing zero jobs.
            OverviewFlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(digest.reporting) { report in
                    OverviewClusterTag(
                        profile: report.profile,
                        text: report.jobCount == 1 ? "1 job" : "\(report.jobCount) jobs",
                        note: report.isLive ? nil : "cached",
                        isMuted: false
                    )
                }
                ForEach(digest.missing) { cluster in
                    OverviewClusterTag(
                        profile: cluster.profile,
                        text: cluster.tagText,
                        note: nil,
                        isMuted: true
                    )
                }
                ForEach(digest.disabled) { profile in
                    OverviewClusterTag(profile: profile, text: "monitoring off", note: nil, isMuted: true)
                }
            }
        }
    }
}

private struct OverviewClusterTag: View {
    let profile: ClusterProfile
    let text: String
    let note: String?
    let isMuted: Bool

    var body: some View {
        HStack(spacing: 6) {
            ClusterBadge(profile: profile, size: 16)
            Text(profile.displayName)
                .fontWeight(.semibold)
            Text(text)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let note {
                Text(note)
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .padding(.leading, 4)
        .padding(.trailing, 9)
        .padding(.vertical, 4)
        .background((isMuted ? Color.secondary : profile.accent.color).opacity(0.10), in: Capsule())
        .overlay(Capsule().stroke(AppTheme.border, lineWidth: 1))
        .opacity(isMuted ? 0.75 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(profile.displayName)
        .accessibilityValue([text, note].compactMap { $0 }.joined(separator: ", "))
    }
}

/// Column geometry shared by the wide table's header and rows. The flexible
/// columns declare an ideal width so `ViewThatFits` can judge the table by
/// a stable width instead of by whatever the longest job name happens to be.
private enum OverviewJobColumn {
    static let cluster: CGFloat = 92
    static let jobID: CGFloat = 92
    static let state: CGFloat = 104
    static let partition: CGFloat = 150
    static let time: CGFloat = 156
    static let flexibleMinimum: CGFloat = 110
    static let flexibleIdeal: CGFloat = 150
    static let spacing: CGFloat = 10
}

private struct OverviewJobsWideTable: View {
    let entries: [OverviewJobEntry]
    let onOpen: @MainActor (OverviewJobEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: OverviewJobColumn.spacing) {
                Text("Cluster")
                    .frame(width: OverviewJobColumn.cluster, alignment: .leading)
                Text("Job ID")
                    .frame(width: OverviewJobColumn.jobID, alignment: .leading)
                Text("Name")
                    .frame(
                        minWidth: OverviewJobColumn.flexibleMinimum,
                        idealWidth: OverviewJobColumn.flexibleIdeal,
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                Text("State")
                    .frame(width: OverviewJobColumn.state, alignment: .leading)
                Text("Partition")
                    .frame(width: OverviewJobColumn.partition, alignment: .leading)
                Text("Elapsed / limit")
                    .frame(width: OverviewJobColumn.time, alignment: .leading)
                Text("Nodes / reason")
                    .frame(
                        minWidth: OverviewJobColumn.flexibleMinimum,
                        idealWidth: OverviewJobColumn.flexibleIdeal,
                        maxWidth: .infinity,
                        alignment: .leading
                    )
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .accessibilityHidden(true)

            Divider()

            ForEach(entries) { entry in
                OverviewJobRowButton(entry: entry, onOpen: onOpen) {
                    OverviewJobWideRow(entry: entry)
                }
                if entry.id != entries.last?.id {
                    Divider()
                        .opacity(0.5)
                }
            }
        }
    }
}

private struct OverviewJobWideRow: View {
    let entry: OverviewJobEntry

    var body: some View {
        HStack(spacing: OverviewJobColumn.spacing) {
            HStack(spacing: 6) {
                ClusterBadge(profile: entry.profile, size: 18)
                Text(entry.profile.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            .frame(width: OverviewJobColumn.cluster, alignment: .leading)

            Text(entry.job.jobId)
                .font(.callout.monospacedDigit())
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: OverviewJobColumn.jobID, alignment: .leading)

            Text(entry.job.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(
                    minWidth: OverviewJobColumn.flexibleMinimum,
                    idealWidth: OverviewJobColumn.flexibleIdeal,
                    maxWidth: .infinity,
                    alignment: .leading
                )

            StatePill(state: entry.job.state)
                .frame(width: OverviewJobColumn.state, alignment: .leading)

            Label(entry.job.partition, systemImage: entry.partitionIcon)
                .font(.caption)
                .foregroundStyle(entry.partitionColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: OverviewJobColumn.partition, alignment: .leading)

            Text(entry.timeText)
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .frame(width: OverviewJobColumn.time, alignment: .leading)

            Text(entry.placementText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(
                    minWidth: OverviewJobColumn.flexibleMinimum,
                    idealWidth: OverviewJobColumn.flexibleIdeal,
                    maxWidth: .infinity,
                    alignment: .leading
                )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

private struct OverviewJobsCompactList: View {
    let entries: [OverviewJobEntry]
    let onOpen: @MainActor (OverviewJobEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(entries) { entry in
                OverviewJobRowButton(entry: entry, onOpen: onOpen) {
                    OverviewJobCompactRow(entry: entry)
                }
                if entry.id != entries.last?.id {
                    Divider()
                        .opacity(0.5)
                }
            }
        }
    }
}

private struct OverviewJobCompactRow: View {
    let entry: OverviewJobEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                ClusterBadge(profile: entry.profile, size: 18)
                Text(entry.profile.displayName)
                    .font(.caption.weight(.semibold))
                Text(entry.job.jobId)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(entry.job.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                StatePill(state: entry.job.state)
            }
            HStack(spacing: 12) {
                Label(entry.job.partition, systemImage: entry.partitionIcon)
                    .foregroundStyle(entry.partitionColor)
                Label(entry.timeText, systemImage: "clock")
                    .monospacedDigit()
                Text(entry.placementText)
                    .foregroundStyle(.secondary)
                    .truncationMode(.tail)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.leading, 26)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Clickable wrapper shared by both row layouts: hover tint in the job's
/// cluster color, a context menu, and one combined accessibility element.
private struct OverviewJobRowButton<Content: View>: View {
    let entry: OverviewJobEntry
    let onOpen: @MainActor (OverviewJobEntry) -> Void
    @ViewBuilder let content: Content

    @State private var isHovered = false

    var body: some View {
        Button {
            onOpen(entry)
        } label: {
            content
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(entry.profile.accent.color.opacity(isHovered ? 0.10 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            // Visual state only — see JobCard for why no NSCursor push.
            isHovered = hovering
        }
        .animation(AppTheme.smoothEase, value: isHovered)
        .contextMenu {
            Button("Open in \(entry.profile.displayName) dashboard") {
                onOpen(entry)
            }
            Button("Copy job ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.job.jobId, forType: .string)
            }
        }
        .help("Open \(entry.profile.displayName) job \(entry.job.jobId) in its dashboard")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.profile.displayName) job \(entry.job.jobId), \(entry.job.name)")
        .accessibilityValue(
            "\(entry.state.label), partition \(entry.job.partition), elapsed \(entry.job.elapsed)"
                + (entry.isFromLiveSession ? "" : ", from cached data")
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the job in the \(entry.profile.displayName) dashboard")
    }
}

// MARK: - Derived data

/// Everything the overview derives from the sessions, computed once per
/// render.
@MainActor
private struct OverviewDigest {
    let clusterCount: Int
    let liveCount: Int
    let signingInCount: Int
    /// Enabled clusters that have a snapshot (live or cached), in catalog order.
    let reporting: [OverviewClusterReport]
    /// Enabled clusters with no snapshot yet.
    let missing: [OverviewMissingCluster]
    /// Clusters the user switched off. Their cached data is not shown.
    let disabled: [ClusterProfile]
    /// Jobs from every reporting cluster, running first, then pending.
    let jobs: [OverviewJobEntry]
    let runningJobs: Int
    let pendingJobs: Int
    private let newestCollectedAt: String?

    init(sessions: [ClusterSession]) {
        var live = 0
        var signingIn = 0
        var reporting: [OverviewClusterReport] = []
        var missing: [OverviewMissingCluster] = []
        var disabled: [ClusterProfile] = []
        var jobs: [OverviewJobEntry] = []
        var newest: (date: Date, raw: String)?

        for (order, session) in sessions.enumerated() {
            let state = session.connectionState
            if state == .live {
                live += 1
            }
            if state.isBusy {
                signingIn += 1
            }
            guard session.isEnabled else {
                disabled.append(session.profile)
                continue
            }
            guard let snapshot = session.snapshot else {
                missing.append(OverviewMissingCluster(profile: session.profile, state: state))
                continue
            }
            let isLive = state == .live
            reporting.append(
                OverviewClusterReport(
                    profile: session.profile,
                    collectedAt: snapshot.collectedAt,
                    isLive: isLive,
                    jobCount: snapshot.jobs.count,
                    stats: OverviewClusterStats(
                        profile: session.profile,
                        snapshot: snapshot,
                        gpu: session.gpuAvailability
                    )
                )
            )
            if let date = SlurmTimestamp.parse(snapshot.collectedAt), date > (newest?.date ?? .distantPast) {
                newest = (date, snapshot.collectedAt)
            }
            for job in snapshot.jobs {
                jobs.append(
                    OverviewJobEntry(
                        profile: session.profile,
                        clusterOrder: order,
                        job: job,
                        isFromLiveSession: isLive
                    )
                )
            }
        }
        jobs.sort(by: OverviewJobEntry.displayOrder)

        clusterCount = sessions.count
        liveCount = live
        signingInCount = signingIn
        self.reporting = reporting
        self.missing = missing
        self.disabled = disabled
        self.jobs = jobs
        runningJobs = jobs.filter { $0.state == .running }.count
        pendingJobs = jobs.filter { $0.state == .pending }.count
        newestCollectedAt = newest?.raw
    }

    /// "2 clusters · 1 live · updated 12 sec. ago".
    func summary(now: Date) -> String {
        var parts = [clusterCount == 1 ? "1 cluster" : "\(clusterCount) clusters"]
        parts.append(liveCount == 0 ? "none live" : "\(liveCount) live")
        if signingInCount > 0 {
            parts.append("\(signingInCount) signing in")
        }
        if !disabled.isEmpty {
            parts.append("\(disabled.count) off")
        }
        if let newestCollectedAt {
            parts.append("updated \(SlurmTimestamp.relativeText(newestCollectedAt, reference: now))")
        } else {
            parts.append("no data yet")
        }
        return parts.joined(separator: " · ")
    }

    var jobsSubtitle: String {
        guard !reporting.isEmpty else {
            return "no snapshot yet"
        }
        let total = jobs.count == 1 ? "1 job" : "\(jobs.count) jobs"
        return "\(total) · \(runningJobs) running · \(pendingJobs) pending"
    }

    /// Explains an empty combined queue without overstating it: clusters
    /// that are not reporting are named as unknown, not as empty.
    var emptyQueueDetail: String {
        let reportingNames = reporting.map(\.profile.displayName).joined(separator: " and ")
        var detail = "Nothing is queued or running for you on \(reportingNames)."
        // A signed-in cluster whose first snapshot is still on its way is
        // "loading", not "not connected": calling it disconnected would
        // invite a needless second sign-in and Duo push.
        let loading = missing.filter { $0.state == .live }
        let unreachable = missing.filter { $0.state != .live }
        if !loading.isEmpty {
            let names = loading.map(\.profile.displayName).joined(separator: " and ")
            detail += " \(names) \(loading.count == 1 ? "is" : "are") signed in but still collecting \(loading.count == 1 ? "its" : "their") first snapshot."
        }
        if !unreachable.isEmpty {
            let names = unreachable.map(\.profile.displayName).joined(separator: " and ")
            detail += " \(names) \(unreachable.count == 1 ? "is" : "are") not connected, so \(unreachable.count == 1 ? "its" : "their") queue is unknown."
        }
        return detail
    }
}

/// An enabled cluster that has no snapshot yet.
private struct OverviewMissingCluster: Identifiable {
    let profile: ClusterProfile
    let state: ClusterConnectionState

    var id: ClusterID { profile.id }

    var tagText: String {
        switch state {
        case .queued, .connecting:
            return "signing in"
        case .live:
            return "loading"
        case .paused:
            return "paused"
        default:
            return "not connected"
        }
    }
}

/// One enabled cluster that has a snapshot to report from.
private struct OverviewClusterReport: Identifiable {
    let profile: ClusterProfile
    let collectedAt: String
    let isLive: Bool
    let jobCount: Int
    let stats: OverviewClusterStats

    var id: ClusterID { profile.id }
}

/// Headline numbers for one cluster's snapshot. Each figure stays within
/// its cluster; nothing here is ever summed across clusters.
private struct OverviewClusterStats {
    let runningJobs: Int
    let pendingJobs: Int
    let otherJobs: Int

    /// Idle GPUs on available nodes (from `ClusterSession.gpuAvailability`).
    let idleGPUs: Int
    /// GPUs on every GPU node, available or not.
    let totalGPUs: Int
    /// GPUs on down/drained nodes.
    let unavailableGPUs: Int
    let busyGPUs: Int
    let gpuModel: String?

    /// Cores on available non-GPU nodes only: GPU nodes' CPUs are meant to
    /// feed their GPUs, so counting them would overstate CPU capacity.
    let cpuIdle: Int
    let cpuTotal: Int
    let cpuNodesReporting: Int

    let nodeCount: Int
    let unavailableNodes: Int
    let partitionCount: Int
    let walltime: (display: String, detail: String)?

    init(profile: ClusterProfile, snapshot: ClusterSnapshot, gpu: (idle: Int, total: Int, model: String?)) {
        var running = 0
        var pending = 0
        for job in snapshot.jobs {
            switch SlurmState(parsing: job.state) {
            case .running:
                running += 1
            case .pending:
                pending += 1
            default:
                break
            }
        }
        runningJobs = running
        pendingJobs = pending
        otherJobs = max(snapshot.jobs.count - running - pending, 0)

        var gpuOnUnavailableNodes = 0
        var cpuIdleSum = 0
        var cpuTotalSum = 0
        var cpuNodes = 0
        var unavailable = 0
        for node in snapshot.nodes {
            let available = isAvailable(node)
            let nodeGPUs = gpuTotal(node)
            if !available {
                unavailable += 1
                gpuOnUnavailableNodes += nodeGPUs
            }
            guard available, nodeGPUs == 0, let total = node.cpuTotal else {
                continue
            }
            cpuTotalSum += total
            cpuIdleSum += node.cpuIdle
                ?? max(total - (node.cpuAllocated ?? 0) - (node.cpuOther ?? 0), 0)
            cpuNodes += 1
        }

        idleGPUs = gpu.idle
        totalGPUs = gpu.total
        gpuModel = gpu.model
        unavailableGPUs = gpuOnUnavailableNodes
        busyGPUs = max(gpu.total - gpu.idle - gpuOnUnavailableNodes, 0)
        cpuIdle = cpuIdleSum
        cpuTotal = cpuTotalSum
        cpuNodesReporting = cpuNodes
        nodeCount = snapshot.nodes.count
        unavailableNodes = unavailable
        partitionCount = Set(snapshot.partitions.map(\.partition)).count
        walltime = OverviewFormat.maximumWalltime(partitions: snapshot.partitions, profile: profile)
    }
}

/// A job tagged with the cluster it belongs to. Slurm job ids are only
/// unique within one controller — AIRE and Calder can both have a job
/// 123456 — so the identity is cluster-qualified.
private struct OverviewJobEntry: Identifiable {
    let profile: ClusterProfile
    let job: Job
    let state: SlurmState
    let isFromLiveSession: Bool
    let isGPU: Bool
    let timeText: String
    let placementText: String
    private let clusterOrder: Int
    private let stateRank: Int

    var id: String { "\(profile.id.rawValue):\(job.jobId)" }

    init(profile: ClusterProfile, clusterOrder: Int, job: Job, isFromLiveSession: Bool) {
        self.profile = profile
        self.job = job
        self.isFromLiveSession = isFromLiveSession
        self.clusterOrder = clusterOrder
        let state = SlurmState(parsing: job.state)
        self.state = state
        switch state {
        case .running:
            stateRank = 0
        case .pending:
            stateRank = 1
        default:
            stateRank = 2
        }

        // Prefer the cluster's own partition knowledge; fall back to the
        // job's requested resources for partitions the profile does not
        // know (or multi-partition pending jobs like "gpu,nodes").
        if let role = profile.role(forPartition: job.partition) {
            isGPU = role == .gpu
        } else {
            let resources = [job.tresPerNode, job.allocTres, job.reqTres]
                .compactMap { $0?.lowercased() }
                .joined(separator: ",")
            isGPU = resources.contains("gpu") || job.partition.lowercased().contains("gpu")
        }

        timeText = job.timeLimit.isEmpty ? job.elapsed : "\(job.elapsed) / \(job.timeLimit)"

        let nodeCount = job.nodes.trimmingCharacters(in: .whitespaces)
        let reason = job.reasonOrNodeList.trimmingCharacters(in: .whitespaces)
        let nodesLabel = nodeCount.isEmpty ? nil : (nodeCount == "1" ? "1 node" : "\(nodeCount) nodes")
        placementText = [nodesLabel, reason.isEmpty ? nil : reason]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var partitionIcon: String {
        isGPU ? PartitionRole.gpu.systemImage : PartitionRole.cpu.systemImage
    }

    var partitionColor: Color {
        isGPU ? AppTheme.gpu : AppTheme.cpu
    }

    /// Running first, then pending, then everything else; within a group by
    /// cluster display order, then job id in natural order (so 9 < 10).
    static func displayOrder(_ lhs: OverviewJobEntry, _ rhs: OverviewJobEntry) -> Bool {
        if lhs.stateRank != rhs.stateRank {
            return lhs.stateRank < rhs.stateRank
        }
        if lhs.clusterOrder != rhs.clusterOrder {
            return lhs.clusterOrder < rhs.clusterOrder
        }
        return lhs.job.jobId.localizedStandardCompare(rhs.job.jobId) == .orderedAscending
    }
}

// MARK: - Formatting

private enum OverviewFormat {
    /// Seconds in a Slurm time limit: "2-00:00:00", "1-12", "12:00:00",
    /// "30:00" (minutes:seconds) or "30" (minutes). "infinite"/"UNLIMITED"
    /// is `.infinity`; anything unparsable (e.g. "n/a") is nil.
    static func timeLimitSeconds(_ raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value == "infinite" || value == "unlimited" {
            return .infinity
        }
        guard !value.isEmpty else {
            return nil
        }
        var days = 0
        var clock = Substring(value)
        let hasDays = value.contains("-")
        if hasDays {
            let pieces = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2, let parsedDays = Int(pieces[0]) else {
                return nil
            }
            days = parsedDays
            clock = pieces[1]
        }
        let fields = clock.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard !fields.isEmpty, fields.count <= 3, fields.allSatisfy({ $0 != nil }) else {
            return nil
        }
        let numbers = fields.compactMap { $0 }
        let hours: Int
        let minutes: Int
        let seconds: Int
        if hasDays {
            // days-hours[:minutes[:seconds]]
            hours = numbers[0]
            minutes = numbers.count > 1 ? numbers[1] : 0
            seconds = numbers.count > 2 ? numbers[2] : 0
        } else {
            switch numbers.count {
            case 1:
                (hours, minutes, seconds) = (0, numbers[0], 0)
            case 2:
                (hours, minutes, seconds) = (0, numbers[0], numbers[1])
            default:
                (hours, minutes, seconds) = (numbers[0], numbers[1], numbers[2])
            }
        }
        return Double(((days * 24 + hours) * 60 + minutes) * 60 + seconds)
    }

    /// "2-00:00:00" -> "2 days", "1-12:00:00" -> "1 day 12 h",
    /// "12:00:00" -> "12 hours", "infinite" -> "no limit". Unparsable
    /// values are shown verbatim rather than guessed at.
    static func walltime(_ raw: String) -> String {
        guard let seconds = timeLimitSeconds(raw) else {
            return raw
        }
        if seconds.isInfinite {
            return "no limit"
        }
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days == 0, minutes == 0, hours > 0 {
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        var parts: [String] = []
        if days > 0 {
            parts.append(days == 1 ? "1 day" : "\(days) days")
        }
        if hours > 0 {
            parts.append("\(hours) h")
        }
        if minutes > 0 {
            parts.append("\(minutes) min")
        }
        return parts.isEmpty ? "under a minute" : parts.joined(separator: " ")
    }

    /// The longest limit any partition allows, plus a per-partition
    /// breakdown for the tooltip. Nil when the snapshot predates time limits.
    static func maximumWalltime(
        partitions: [PartitionSummary],
        profile: ClusterProfile
    ) -> (display: String, detail: String)? {
        // sinfo emits one row per partition *and* state; the limit is a
        // partition property, so keep the first non-empty one per name.
        var limits: [String: String] = [:]
        for row in partitions {
            guard limits[row.partition] == nil,
                  let limit = row.timeLimit?.trimmingCharacters(in: .whitespaces),
                  !limit.isEmpty else {
                continue
            }
            limits[row.partition] = limit
        }
        guard let longest = limits.max(by: {
            (timeLimitSeconds($0.value) ?? -1) < (timeLimitSeconds($1.value) ?? -1)
        }) else {
            return nil
        }
        let ordered = limits.keys.sorted { lhs, rhs in
            let lhsRank = profile.hint(forPartition: lhs)?.sortRank ?? Int.max
            let rhsRank = profile.hint(forPartition: rhs)?.sortRank ?? Int.max
            return lhsRank == rhsRank ? lhs < rhs : lhsRank < rhsRank
        }
        let detail = ordered
            .map { "\($0): \(walltime(limits[$0] ?? ""))" }
            .joined(separator: "\n")
        return (walltime(longest.value), "Longest job a partition allows\n\(detail)")
    }

    static func usedPercent(_ item: StorageSummary) -> Double? {
        if let percent = item.usedPercent {
            return percent
        }
        guard let used = item.usedGB, let limit = item.limitGB ?? item.quotaGB, limit > 0 else {
            return nil
        }
        return used / limit * 100
    }

    static func usageColor(percent: Double?, kind: StorageKind) -> Color {
        guard let percent else {
            return kind.color
        }
        if percent >= 90 {
            return .red
        }
        if percent >= 75 {
            return .orange
        }
        return kind.color
    }

    /// "12.3 GB of 65.0 GB", falling back gracefully when the limit or the
    /// usage is unknown.
    static func usageText(_ item: StorageSummary) -> String {
        let limit = item.limitGB ?? item.quotaGB
        switch (item.usedGB, limit) {
        case let (used?, limit?):
            return "\(formatGB(used)) of \(formatGB(limit))"
        case let (used?, nil):
            return "\(formatGB(used)) used"
        default:
            return missingValuePlaceholder
        }
    }

    /// Which mechanism governs the space. Older caches carry no quota type.
    static func quotaCaption(_ item: StorageSummary) -> String? {
        if item.source == "unavailable" {
            // The collector tags unreadable rows quota_type "df"; captioning
            // them "Filesystem usage" would claim figures that do not exist.
            return item.unavailableCaption
        }
        switch item.quotaType?.lowercased() {
        case "nfs":
            return "NFS quota"
        case "lustre-project":
            return "Lustre project quota"
        case "lustre-user":
            return "Lustre user quota"
        case "df":
            return "Filesystem usage, no quota"
        default:
            return nil
        }
    }
}

// MARK: - Layouts

/// Adaptive grid whose cells in a row share the row's height. `LazyVGrid`
/// sizes each cell to its own content, which leaves side-by-side cluster
/// cards ragged; this proposes the tallest height in the row to every
/// cell, so cards with flexible frames line up, and still stacks into one
/// column when the window is narrow.
private struct OverviewAdaptiveGrid: Layout {
    var minimumColumnWidth: CGFloat
    var spacing: CGFloat

    private struct Row {
        var indices: Range<Int>
        var height: CGFloat
    }

    private struct Plan {
        var columnWidth: CGFloat
        var rows: [Row]
        var height: CGFloat
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else {
            return .zero
        }
        let width = resolvedWidth(proposal, count: subviews.count)
        return CGSize(width: width, height: plan(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else {
            return
        }
        let plan = plan(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in plan.rows {
            for (column, index) in row.indices.enumerated() {
                let x = bounds.minX + CGFloat(column) * (plan.columnWidth + spacing)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: plan.columnWidth, height: row.height)
                )
            }
            y += row.height + spacing
        }
    }

    private func resolvedWidth(_ proposal: ProposedViewSize, count: Int) -> CGFloat {
        if let width = proposal.width, width.isFinite {
            return width
        }
        // Ideal size: every cell side by side at the minimum width.
        let columns = CGFloat(count)
        return minimumColumnWidth * columns + spacing * (columns - 1)
    }

    private func plan(width: CGFloat, subviews: Subviews) -> Plan {
        let fitting = Int(((width + spacing) / (minimumColumnWidth + spacing)).rounded(.down))
        let columns = max(1, min(subviews.count, fitting))
        let columnWidth = max((width - spacing * CGFloat(columns - 1)) / CGFloat(columns), 0)
        var rows: [Row] = []
        var start = 0
        while start < subviews.count {
            let indices = start..<min(start + columns, subviews.count)
            let height = indices
                .map { subviews[$0].sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
                .max() ?? 0
            rows.append(Row(indices: indices, height: height))
            start += columns
        }
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return Plan(columnWidth: columnWidth, rows: rows, height: height)
    }
}

/// Left-aligned wrapping row for chips, so a narrow card wraps its chips
/// onto a second line instead of clipping them.
private struct OverviewFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? .infinity
        let frames = arrange(maxWidth: maxWidth, subviews: subviews)
        let width = frames.map(\.maxX).max() ?? 0
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(maxWidth: bounds.width, subviews: subviews)
        for (index, frame) in frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}
