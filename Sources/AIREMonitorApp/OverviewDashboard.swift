import HPCCore
import AppKit
import SwiftUI

// MARK: - Overview

/// The default landing view: what needs attention, the user's jobs from
/// every cluster in one list, then each cluster's card with its idle
/// capacity and storage.
///
/// Two rules shape everything on this page (see OverviewModel.swift):
/// - Capacity from different clusters is never silently added together. An
///   L40S and an H200 are different pools, Slurm job ids and node names are
///   only unique within one controller, and the /users home quota is one NFS
///   export that every cluster reports. Anything cross-cluster is shown per
///   cluster, tagged with its badge.
/// - A cluster without a snapshot shows an explicit "not connected" / "off"
///   state, never zeros, so "no data" can never read as "nothing running".
struct OverviewDashboard: View {
    @ObservedObject var model: AppModel

    /// The combined job list is capped until expanded, so the cluster cards
    /// stay within reach and a long array-job backlog does not cost
    /// hundreds of rows on every 10-second refresh.
    @State private var showAllJobs = false
    @State private var confirmation: SessionActionConfirmation?

    static let collapsedJobLimit = 8

    var body: some View {
        // One pass over every session per render; each section below reads
        // from this digest instead of re-filtering the snapshots itself.
        let digest = OverviewDigest(sessions: model.sessions)

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(digest)

                if !digest.attention.isEmpty {
                    OverviewAttentionPanel(lines: digest.attention, onOpen: openCluster)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                jobsSection(digest)

                OverviewAdaptiveGrid(minimumColumnWidth: 400, spacing: 12) {
                    ForEach(model.sessions) { session in
                        ClusterOverviewCard(
                            model: model,
                            session: session,
                            onConnect: { confirmation = model.signInOrConfirm([session.id]) }
                        )
                    }
                }
            }
            .padding(18)
        }
        .animation(AppTheme.smoothEase, value: digest.reporting.count)
        .animation(AppTheme.smoothEase, value: digest.attention.count)
        .animation(AppTheme.smoothEase, value: showAllJobs)
        .sessionActionConfirmation($confirmation, model: model)
    }

    // MARK: Header

    private func header(_ digest: OverviewDigest) -> some View {
        // The subtitle carries relative ages ("updated 12 s ago"); the
        // timeline keeps them ticking between refreshes, and while every
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
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        // Only clusters that can be refreshed: a never-signed-in cluster
        // would just paint "control master is not running" in red.
        .disabled(!model.enabledSessions.contains { $0.presentation.allowsRefresh })
        .keyboardShortcut("r", modifiers: .command)
        .help("Refresh every connected cluster now (⌘R)")
    }

    // MARK: Jobs

    @ViewBuilder
    private func jobsSection(_ digest: OverviewDigest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            OverviewJobsHeader(digest: digest)

            if digest.reporting.isEmpty {
                OverviewNotice(
                    systemImage: "list.bullet.rectangle",
                    title: "No job data yet",
                    detail: digest.missing.isEmpty
                        ? "Every cluster is switched off. Turn one on to see your Slurm jobs here."
                        : "Connect to a cluster to see your Slurm jobs here. Nothing is listed until a real snapshot arrives."
                )
            } else if digest.jobs.isEmpty {
                OverviewNotice(
                    systemImage: "checkmark.circle",
                    title: "No jobs in any queue",
                    detail: digest.emptyQueueDetail
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
                        Button(digest.jobListToggleTitle(showingAll: showAllJobs, limit: limit)) {
                            showAllJobs.toggle()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .padding(.vertical, 8)
                        .help(digest.rowsStandForMoreJobs
                            ? "A queued array remainder is one row standing for all of its tasks, so there are fewer rows than jobs."
                            : "")
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
        model.selectJob(entry.job.jobId, on: entry.profile.id)
    }

    /// Opens a cluster, on `tab` when given.
    private func openCluster(_ id: ClusterID, _ tab: DashboardTab?) {
        model.selectCluster(id, tab: tab)
    }
}

/// One-line stand-in for an empty section: says why it is empty without
/// taking the height of a full empty-state card, so the cluster cards
/// below stay within reach.
private struct OverviewNotice: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .dashboardCard(padding: 14, accent: .secondary)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Needs attention

/// The few things worth acting on, one line per cluster, only when there is
/// something to say: storage about to fill, jobs that will not start on
/// their own, a GPU model with no usable node, a failing refresh. Each item
/// opens the tab with the details.
private struct OverviewAttentionPanel: View {
    let lines: [OverviewAttentionLine]
    let onOpen: (ClusterID, DashboardTab?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Needs attention", systemImage: "exclamationmark.circle")
                .font(.subheadline.weight(.semibold))

            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    ClusterTitle(profile: line.profile, font: .callout.weight(.semibold))
                        .frame(minWidth: 90, alignment: .leading)
                    OverviewFlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(line.items) { item in
                            OverviewAttentionChip(item: item) {
                                onOpen(line.profile.id, item.tab)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard(accent: .orange)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Needs attention")
    }
}

private struct OverviewAttentionChip: View {
    let item: OverviewAttentionItem
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: item.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(item.tone.color)
                Text(item.text)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(item.tone.color.legibleText(in: colorScheme))
            }
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(item.tone.color.opacity(isHovered ? 0.18 : 0.11), in: Capsule())
            .overlay(Capsule().stroke(item.tone.color.opacity(0.30), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(AppTheme.smoothEase, value: isHovered)
        .help(item.help)
        .accessibilityLabel(item.text)
        .accessibilityHint(item.help)
    }
}

// MARK: - Cluster card

/// One cluster's at-a-glance card: identity, connection state, snapshot age,
/// the headline numbers and its storage. It observes its own session, so it
/// repaints whenever that cluster changes, independently of the page, and
/// computes its figures once per render.
struct ClusterOverviewCard: View {
    /// Used for actions only (selection). Not observed: everything the
    /// card displays comes from `session`.
    let model: AppModel
    @ObservedObject var session: ClusterSession
    /// Connect, routed through the page's confirmation.
    let onConnect: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let presentation = session.presentation
        let accent = session.profile.accent.color
        let snapshot = session.isEnabled ? session.snapshot : nil

        VStack(alignment: .leading, spacing: 14) {
            header(presentation)

            if session.isEnabled, let error = session.errorMessage, !error.isEmpty {
                errorLine(error)
            }

            if let snapshot {
                OverviewClusterFigures(
                    profile: session.profile,
                    snapshot: snapshot,
                    stats: OverviewClusterStats(profile: session.profile, snapshot: snapshot, fleet: session.gpuFleet)
                )
            } else {
                placeholder(presentation)
            }

            // Absorbs the slack when the neighbouring card is taller, so
            // the footers line up and the placeholder keeps its own height.
            Spacer(minLength: 0)

            footer(presentation, showsFigures: snapshot != nil, accent: accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dashboardCard(padding: 16, accent: accent)
        .animation(AppTheme.smoothEase, value: presentation.phase)
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

    private func header(_ presentation: ClusterPresentation) -> some View {
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
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(session.profile.tagline)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                ConnectionStatePill(presentation: presentation)
                if session.isEnabled, let collectedAt = session.snapshot?.collectedAt, !collectedAt.isEmpty {
                    StalenessBadge(collectedAt: collectedAt)
                }
            }
        }
    }

    private func errorLine(_ error: String) -> some View {
        // First line only: full collector/SSH errors can run to many lines
        // and are shown in full on the cluster tab and on hover.
        let firstLine = error
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? error
        return Label(firstLine, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(Color.red.legibleText(in: colorScheme))
            .lineLimit(2)
            .help(error)
            .accessibilityLabel("Error")
            .accessibilityValue(error)
    }

    // MARK: Placeholder

    /// Stand-in while there is no snapshot to show: what is happening and
    /// the one action that helps, right under the explanation (not 300 pt
    /// lower in the footer). The pill already names the state, so the title
    /// says what to expect rather than repeating it.
    @ViewBuilder
    private func placeholder(_ presentation: ClusterPresentation) -> some View {
        let name = session.displayName
        switch presentation.phase {
        case .off:
            OverviewCardPlaceholder(
                systemImage: "power.circle",
                title: "Monitoring is off",
                detail: "\(name) is not being polled, so nothing is shown here. Turn it on to see your jobs, idle GPUs and storage.",
                showsProgress: false
            ) {
                Button {
                    session.isEnabled = true
                } label: {
                    Label("Turn on", systemImage: "power")
                }
                .buttonStyle(.borderedProminent)
                .tint(session.profile.accent.color)
                .disabled(model.isAnyLoginActive)
                .help("Start monitoring \(name)")
            }
        case .signingIn, .queued:
            OverviewCardPlaceholder(
                systemImage: "person.badge.key",
                title: presentation.phase == .queued ? "Waiting to sign in" : "Signing in…",
                detail: presentation.detail,
                showsProgress: true
            ) {
                Button(role: .cancel) {
                    session.cancelLogin()
                } label: {
                    Text("Cancel sign-in")
                }
                .help(ClusterStatusContent.cancelSignInHelp(clusterName: name, isQueued: presentation.phase == .queued))
            }
        case .loadingFirstSnapshot:
            OverviewCardPlaceholder(
                systemImage: "arrow.triangle.2.circlepath",
                title: "Collecting the first snapshot…",
                detail: "Jobs, GPUs and storage appear as soon as it lands.",
                showsProgress: true
            ) {
                EmptyView()
            }
        case .checking:
            // Startup / route-change probe: it reuses an SSH session that is
            // already open, and settles on "Not connected" otherwise. No
            // Connect here — it would replace the master being confirmed.
            OverviewCardPlaceholder(
                systemImage: "antenna.radiowaves.left.and.right",
                title: "Checking for an open session…",
                detail: "Looking for an SSH session to \(hostname) that is already open.",
                showsProgress: true
            ) {
                EmptyView()
            }
        case .paused:
            OverviewCardPlaceholder(
                systemImage: "pause.circle",
                title: "Nothing collected yet",
                detail: "Monitoring is paused before the first snapshot. Resume to start polling \(hostname).",
                showsProgress: false
            ) {
                Button {
                    session.togglePause()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(session.profile.accent.color)
            }
        case .notConnected, .stale, .live:
            OverviewCardPlaceholder(
                systemImage: "bolt.horizontal.circle",
                title: "Sign in to see \(name)",
                detail: "Your jobs, idle GPUs and storage from \(hostname) appear after sign-in. No numbers are shown until a real snapshot arrives.",
                showsProgress: false
            ) {
                Button(action: onConnect) {
                    Label("Connect", systemImage: "person.crop.circle.badge.checkmark")
                }
                .buttonStyle(.borderedProminent)
                .tint(session.profile.accent.color)
                .help("Sign in to \(name) with the account in the sidebar")
            }
        }
    }

    // MARK: Footer

    private func footer(_ presentation: ClusterPresentation, showsFigures: Bool, accent: Color) -> some View {
        VStack(spacing: 10) {
            Divider()
            HStack(spacing: 8) {
                // The status line belongs to the figures, and only when it
                // adds something: while live, "Last refresh 11:30" would just
                // repeat the age badge in the header; a placeholder has
                // already said everything there is to say.
                if showsFigures, presentation.phase != .live {
                    Text(session.isPaused ? session.pausedStatusText : session.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(session.statusMessage)
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    if showsFigures, let action = presentation.primaryAction {
                        primaryButton(action, accent: accent)
                    }
                    Button {
                        model.selection = .cluster(session.id)
                    } label: {
                        Label("Open dashboard", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.bordered)
                    .help("Show the full \(session.displayName) dashboard")
                }
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private func primaryButton(_ action: ClusterPresentation.Action, accent: Color) -> some View {
        switch action {
        case .connect:
            Button(action: onConnect) {
                Label("Connect", systemImage: "person.crop.circle.badge.checkmark")
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .help("Sign in to \(session.displayName) with the account in the sidebar")
        case .resume:
            Button {
                session.togglePause()
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .help("Resume background refreshes for \(session.displayName)")
        case .turnOn:
            Button {
                session.isEnabled = true
            } label: {
                Label("Turn on", systemImage: "power")
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .help("Start monitoring \(session.displayName)")
        }
    }
}

/// Friendly stand-in for a card's figures while there is no snapshot to
/// show. Deliberately shaped like content, not like zeroed metrics, and
/// only as tall as its text: the card's spacer takes any slack.
private struct OverviewCardPlaceholder<Action: View>: View {
    let systemImage: String
    let title: String
    let detail: String
    let showsProgress: Bool
    @ViewBuilder let action: Action

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
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

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                action
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
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
                    OverviewGPUTile(stats: stats)
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
        let counts = stats.counts
        var caption = "\(counts.pending) pending"
        if counts.held > 0 {
            caption += " · \(counts.held) held"
        }
        if counts.other > 0 {
            caption += " · \(counts.other) other"
        }
        return OverviewStatTile(
            title: "My jobs",
            systemImage: "list.bullet.rectangle",
            accent: .blue,
            value: "\(counts.running)",
            valueColor: AppTheme.idle,
            unit: "running",
            caption: caption,
            help: "Array backlogs count every queued task."
        ) {
            SegmentedMeter(
                segments: [
                    MeterSegment(id: "Running", value: counts.running, color: AppTheme.idle),
                    MeterSegment(id: "Pending", value: counts.pending, color: .orange),
                    // Grey, as on the Jobs tab's queue mix: a held job will
                    // not start, and yellow is the Suspended colour.
                    MeterSegment(id: "Held", value: counts.held, color: .gray),
                    MeterSegment(id: "Other", value: counts.other, color: Color.secondary.opacity(0.65))
                ],
                height: 5
            )
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
                valueColor: stats.cpuIdle > 0 ? AppTheme.idle : .orange,
                unit: "of \(stats.cpuTotal.formatted())",
                caption: "on \(stats.cpuNodesReporting) available CPU node\(stats.cpuNodesReporting == 1 ? "" : "s")",
                help: "Cores on CPU nodes that accept work. GPU nodes' cores are left out: they exist to feed their GPUs."
            ) {
                SegmentedMeter(
                    segments: [
                        MeterSegment(id: "Idle", value: stats.cpuIdle, color: AppTheme.idle),
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
            accent: unavailable > 0 ? StatusTone.warning.color : StatusTone.normal.color,
            value: stats.nodeCount == 0 ? missingValuePlaceholder : "\(unavailable)",
            unit: stats.nodeCount == 0 ? nil : "of \(stats.nodeCount)",
            caption: stats.nodeCount == 0
                ? "No node data in this snapshot"
                : (unavailable > 0 ? "Down, drained or in maintenance" : "Every node accepts work"),
            help: "Nodes that accept no new work: down, drained or draining, in a maintenance reservation, not responding, or in a state this app does not recognise."
        ) {
            SegmentedMeter(
                segments: [
                    MeterSegment(id: "Available", value: stats.nodeCount - unavailable, color: StatusTone.normal.color),
                    MeterSegment(id: "Unavailable", value: unavailable, color: AppTheme.unavailable)
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

// MARK: - GPU tile

/// Idle GPUs, per model. One pool reads like the other tiles ("1 of 84"
/// idle L40S); several pools get one row each — an idle L40 is not an idle
/// H200, so they are never added into one "H200 + L40" figure.
private struct OverviewGPUTile: View {
    let stats: OverviewClusterStats

    var body: some View {
        let fleet = stats.fleet
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
        } else if fleet.isEmpty {
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
        } else if fleet.pools.count == 1, let pool = fleet.primary {
            OverviewStatTile(
                title: "Idle \(pool.label) GPUs",
                systemImage: "memorychip",
                accent: AppTheme.gpu,
                value: pool.idleFigure,
                valueColor: pool.idleTint,
                unit: "of \(pool.total)",
                caption: pool.capacityCaption,
                help: pool.breakdownHelp
            ) {
                GPUPoolMeter(pool: pool, height: 5)
            }
        } else {
            OverviewGPUPoolsTile(fleet: fleet)
        }
    }
}

/// Several GPU models on one cluster (Calder's H200s next to a few L40s):
/// one row per model, largest pool first. Each row carries the figures the
/// single-pool tile does — idle of total, and every other GPU by why
/// (`GPUPool.capacityCaption`: in use · stranded · unavailable · unknown) —
/// beside the figure when the tile is wide enough, otherwise on a line of
/// its own under the meter. All rows switch together, so they stay aligned,
/// and no figure is ever dropped to make room.
private struct OverviewGPUPoolsTile: View {
    let fleet: GPUFleet

    private static let maximumRows = 3

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shown = Array(fleet.pools.prefix(Self.maximumRows))
        let hidden = fleet.pools.count - shown.count
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "memorychip")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.gpu)
                Text("Idle GPUs by model")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ViewThatFits(in: .horizontal) {
                rows(shown, captionBeside: true)
                rows(shown, captionBeside: false)
            }
            if hidden > 0 {
                Text("+\(hidden) more model\(hidden == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(fleet.pools.dropFirst(shown.count).map(\.idleFigureSummary).joined(separator: "\n"))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Idle GPUs by model")
    }

    private func rows(_ pools: [GPUPool], captionBeside: Bool) -> some View {
        VStack(alignment: .leading, spacing: captionBeside ? 6 : 8) {
            ForEach(pools) { pool in
                row(pool, captionBeside: captionBeside)
            }
        }
    }

    private func row(_ pool: GPUPool, captionBeside: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(pool.label)
                    .font(.caption.weight(.semibold))
                    .frame(minWidth: 38, alignment: .leading)
                Text(pool.idleFigure)
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(pool.idleTint.legibleText(in: colorScheme))
                Text("of \(pool.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if captionBeside {
                    Spacer(minLength: 8)
                    caption(pool)
                        .fixedSize()
                }
            }
            GPUPoolMeter(pool: pool, height: 4)
            if !captionBeside {
                caption(pool)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(pool.breakdownHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(pool.label) GPUs")
        .accessibilityValue("\(pool.idleSpokenSummary); \(pool.capacityCaption)")
    }

    private func caption(_ pool: GPUPool) -> some View {
        Text(pool.capacityCaption)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

/// One pool's GPUs split into idle (startable), in use, stranded,
/// unavailable and unknown, in the shared capacity colours. Shared by the
/// overview tiles and the menu bar's GPU rows, so a pool looks the same on
/// both.
struct GPUPoolMeter: View {
    let pool: GPUPool
    var height: CGFloat = 5

    var body: some View {
        SegmentedMeter(
            segments: [
                MeterSegment(id: "Idle", value: pool.idle, color: AppTheme.idle),
                MeterSegment(id: "In use", value: pool.allocated, color: AppTheme.gpu),
                MeterSegment(id: "Stranded", value: pool.stranded, color: AppTheme.stranded),
                MeterSegment(id: "Unavailable", value: pool.unavailable, color: AppTheme.unavailable),
                MeterSegment(id: "Unknown", value: pool.unknown, color: Color.primary.opacity(0.12))
            ],
            height: height
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
    /// Colour of the headline number: the colour of the meter segment it
    /// counts (green for idle), so number and bar never disagree. Defaults
    /// to the tile accent.
    var valueColor: Color?
    let unit: String?
    let caption: String
    var help: String?
    @ViewBuilder let accessory: Accessory

    @Environment(\.colorScheme) private var colorScheme

    init(
        title: String,
        systemImage: String,
        accent: Color,
        value: String,
        valueColor: Color? = nil,
        unit: String?,
        caption: String,
        help: String? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accent = accent
        self.value = value
        self.valueColor = valueColor
        self.unit = unit
        self.caption = caption
        self.help = help
        self.accessory = accessory()
    }

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
                    .foregroundStyle((valueColor ?? accent).legibleText(in: colorScheme))
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
        .help(help ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue([value, unit, caption].compactMap { $0 }.joined(separator: ", "))
    }
}

/// One storage space: usage bar, used/limit, and what kind of quota governs
/// it. The bar and percentage take the shared storage tone (`usageTone`:
/// 75 % warning, 90 % critical, over quota critical); the icon keeps the
/// storage kind's identity colour. The
/// home row says it is shared, because the same /users quota appears on
/// every cluster's card and must not be read as two separate allowances.
private struct OverviewStorageRow: View {
    let item: StorageSummary

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let kind = item.kind
        let percent = OverviewFormat.usedPercent(item)
        // The Storage tab's rule: over quota, or space or file count past
        // the shared thresholds, whichever is closer to its limit.
        let tone = item.usageTone
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
                                .foregroundStyle(Color.red.legibleText(in: colorScheme))
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
                    HStack(spacing: 3) {
                        if tone == .warning || tone == .critical {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(tone.color)
                                .accessibilityHidden(true)
                        }
                        Text(percentText(percent))
                            .font(.caption2.monospacedDigit().weight(.medium))
                            .foregroundStyle(tone == .normal || tone == .unavailable
                                ? Color.secondary
                                : tone.color.legibleText(in: colorScheme))
                    }
                }
            }

            OverviewUsageBar(fraction: percent.map { $0 / 100 }, color: tone.color)
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
                        text: report.counts.total == 1 ? "1 job" : "\(report.counts.total) jobs",
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

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            ClusterBadge(profile: profile, size: 16)
            Text(profile.displayName)
                .fontWeight(.semibold)
            Text(text)
                .foregroundStyle(Color.primary.opacity(0.72))
                .monospacedDigit()
            if let note {
                Text(note)
                    .foregroundStyle(Color.orange.legibleText(in: colorScheme))
            }
        }
        .font(.caption)
        .padding(.leading, 4)
        .padding(.trailing, 9)
        .padding(.vertical, 4)
        .background((isMuted ? Color.secondary : profile.accent.color).opacity(0.10), in: Capsule())
        .overlay(Capsule().stroke(AppTheme.border, lineWidth: 1))
        .opacity(isMuted ? 0.8 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(profile.displayName)
        .accessibilityValue([text, note].compactMap { $0 }.joined(separator: ", "))
    }
}

extension OverviewJobEntry {
    var partitionIcon: String {
        isGPU ? PartitionRole.gpu.systemImage : PartitionRole.cpu.systemImage
    }

    var partitionColor: Color {
        isGPU ? AppTheme.gpu : AppTheme.cpu
    }
}

/// Column geometry shared by the wide table's header and rows. The flexible
/// columns declare an ideal width so `ViewThatFits` can judge the table by
/// a stable width instead of by whatever the longest job name happens to be.
private enum OverviewJobColumn {
    static let cluster: CGFloat = 92
    static let jobID: CGFloat = 104
    static let state: CGFloat = 104
    static let partition: CGFloat = 150
    static let time: CGFloat = 150
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
                Text("Time")
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

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: OverviewJobColumn.spacing) {
            HStack(spacing: 6) {
                ClusterBadge(profile: entry.profile, size: 18)
                Text(entry.profile.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            .frame(width: OverviewJobColumn.cluster, alignment: .leading)

            Text(entry.job.displayJobID)
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

            StatePill(job: entry.job)
                .frame(width: OverviewJobColumn.state, alignment: .leading)

            Label(entry.job.partition, systemImage: entry.partitionIcon)
                .font(.caption)
                .foregroundStyle(entry.partitionColor.legibleText(in: colorScheme))
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

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                ClusterBadge(profile: entry.profile, size: 18)
                Text(entry.profile.displayName)
                    .font(.caption.weight(.semibold))
                Text(entry.job.displayJobID)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(entry.job.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                StatePill(job: entry.job)
            }
            HStack(spacing: 12) {
                Label(entry.job.partition, systemImage: entry.partitionIcon)
                    .foregroundStyle(entry.partitionColor.legibleText(in: colorScheme))
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
        .help("Open \(entry.profile.displayName) job \(entry.job.displayJobID) in its dashboard")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.profile.displayName) job \(entry.job.displayJobID), \(entry.job.name)")
        .accessibilityValue(
            "\(entry.stateLabel), partition \(entry.job.partition), \(entry.timeText)"
                + (entry.isFromLiveSession ? "" : ", from cached data")
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the job in the \(entry.profile.displayName) dashboard")
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
