import AppKit
import SwiftUI

/// Content of the status-bar dropdown: a combined header, one compact
/// section per cluster, the shared home quota once, and the footer actions.
/// Every number comes from `MenuBarDigest`, the same value the status item
/// title and tooltip are built from, so the two surfaces never disagree.
struct MenuBarMonitorView: View {
    @ObservedObject var model: AppModel
    let closeMenu: @MainActor () -> Void

    /// Wide enough for a badge, name, state pill and "Updated" ticker on one
    /// line per cluster; still narrower than a typical menu-bar dropdown.
    private static let panelWidth: CGFloat = 400

    var body: some View {
        let digest = MenuBarDigest(model: model)

        ZStack {
            MenuVisualEffectBackground(material: .popover, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(MenuPalette.backgroundOverlay)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(MenuPalette.border, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 10) {
                MenuHeader(digest: digest)

                ForEach(digest.clusters) { cluster in
                    MenuClusterSection(
                        cluster: cluster,
                        onConnect: { model.connect(cluster.id) },
                        onResume: { model.session(for: cluster.id)?.togglePause() },
                        onTurnOn: { model.session(for: cluster.id)?.isEnabled = true },
                        onOpenDashboard: { openDashboard(on: .cluster(cluster.id)) }
                    )
                    .transition(.opacity)
                }

                if let home = digest.sharedHome {
                    MenuSharedHomeSection(home: home)
                        .transition(.opacity)
                }

                if let message = model.errorMessage?.menuTrimmed.menuNilIfEmpty {
                    // App-level problems, e.g. Connect pressed with no saved
                    // password. Without this the Connect button would look
                    // dead from the menu.
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(message)
                }

                Divider()
                    .opacity(0.55)

                footer
            }
            .padding(12)
        }
        .frame(width: Self.panelWidth)
        .animation(AppTheme.smoothEase, value: digest.animationKey)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                model.refreshAll()
            } label: {
                Label(model.isAnyRefreshing ? "Refreshing" : "Refresh all", systemImage: "arrow.clockwise")
            }
            // Each session self-guards, so the button only needs to be off
            // when no enabled cluster could start a refresh right now.
            .disabled(!model.enabledSessions.contains { !$0.isRefreshing && !$0.isLoggingIn })
            .help("Refresh every enabled cluster now")

            Button {
                openDashboard(on: nil)
            } label: {
                Label("Open dashboard", systemImage: "macwindow")
            }

            Button {
                closeMenu()
                model.openDesktopWidget()
            } label: {
                Label("Widget", systemImage: "rectangle.on.rectangle.angled")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// Closes the menu first so activating the dashboard window does not
    /// fight the menu's tracking session. `selection` nil keeps whatever the
    /// dashboard last showed.
    private func openDashboard(on selection: SidebarSelection?) {
        closeMenu()
        if let selection {
            model.selection = selection
        }
        DashboardWindowPresenter.shared.show()
    }
}

// MARK: - Header

private struct MenuHeader: View {
    let digest: MenuBarDigest

    var body: some View {
        HStack(spacing: 8) {
            AppLogoMark(cornerRadius: 7)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Leeds HPC Monitor")
                        .font(.headline.weight(.semibold))
                    Circle()
                        .fill(digest.health.color)
                        .frame(width: 7, height: 7)
                        .shadow(color: digest.health.color.opacity(0.28), radius: 3, x: 0, y: 0)
                        .accessibilityHidden(true)
                }
                Text(digest.headerStatusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(digest.headerStatusLine)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Leeds HPC Monitor")
        .accessibilityValue(digest.headerStatusLine)
    }
}

// MARK: - Cluster section

private struct MenuClusterSection: View {
    let cluster: MenuBarClusterDigest
    let onConnect: () -> Void
    let onResume: () -> Void
    let onTurnOn: () -> Void
    let onOpenDashboard: () -> Void

    /// Jobs shown per cluster before the "+N more" line; keeps the dropdown
    /// on screen when both clusters are busy.
    private static let maxVisibleJobs = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if cluster.isEnabled {
                enabledContent
            } else {
                statusRow(
                    text: "Monitoring is off for \(cluster.displayName)",
                    color: .secondary,
                    action: ("Turn on", onTurnOn)
                )
            }
        }
        .menuSectionSurface(accent: cluster.profile.accent.color)
    }

    private var header: some View {
        HStack(spacing: 7) {
            ClusterBadge(profile: cluster.profile, size: 20)
            Text(cluster.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            ConnectionStatePill(state: cluster.state)

            Spacer(minLength: 6)

            if let collected = cluster.collectedAt, cluster.isEnabled {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Updated \(menuRelativeAge(from: collected, to: context.date))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .accessibilityLabel("\(cluster.displayName) snapshot age")
            }

            Button(action: onOpenDashboard) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Open \(cluster.displayName) in the dashboard")
            .accessibilityLabel("Open \(cluster.displayName) in the dashboard")
        }
    }

    @ViewBuilder
    private var enabledContent: some View {
        if let signIn = cluster.signInText {
            statusRow(text: signIn, color: .secondary, action: nil)
        } else if let error = cluster.errorMessage, !cluster.isLive {
            statusRow(text: error, color: .red, action: connectAction)
        } else if let action = connectAction {
            statusRow(text: cluster.connectionHint, color: .secondary, action: action)
        } else if let error = cluster.errorMessage {
            // Live but the last manual refresh failed: worth a line, no
            // button (the session is still up).
            statusRow(text: error, color: .orange, action: nil)
        }

        if cluster.hasSnapshot {
            jobsBlock

            if let pool = cluster.gpu {
                MenuMeterRow(
                    systemImage: "memorychip",
                    iconColor: AppTheme.gpu,
                    title: pool.title,
                    fraction: pool.usedFraction,
                    color: pool.color,
                    value: "\(pool.allocated)/\(pool.total) · \(pool.idle) free",
                    help: pool.helpText(clusterName: cluster.displayName)
                )
            }

            ForEach(cluster.storage) { row in
                MenuMeterRow(
                    systemImage: row.kind.systemImage,
                    iconColor: row.kind.color,
                    title: row.label,
                    fraction: row.riskFraction ?? 0,
                    color: row.level.color,
                    value: row.valueLabel,
                    help: "\(cluster.displayName) \(row.label): \(row.detail)"
                )
            }
        }
    }

    /// The single action offered for a cluster that is enabled but not live.
    private var connectAction: (String, () -> Void)? {
        switch cluster.state {
        case .notConnected, .cached:
            return ("Connect", onConnect)
        case .paused:
            return ("Resume", onResume)
        case .disabled, .queued, .connecting, .live:
            return nil
        }
    }

    @ViewBuilder
    private var jobsBlock: some View {
        let jobs = cluster.runningJobs + cluster.pendingJobs
        if jobs.isEmpty {
            Text("No running or pending jobs")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    Label("\(cluster.runningJobs.count) running", systemImage: "play.fill")
                        .foregroundStyle(cluster.runningJobs.isEmpty ? Color.secondary : Color.green)
                    Label("\(cluster.pendingJobs.count) pending", systemImage: "clock.fill")
                        .foregroundStyle(cluster.pendingJobs.isEmpty ? Color.secondary : Color.orange)
                }
                .font(.caption2.weight(.semibold).monospacedDigit())
                .accessibilityElement(children: .combine)

                ForEach(jobs.prefix(Self.maxVisibleJobs)) { job in
                    MenuJobRow(job: MenuJobSummary(job: job))
                }

                if jobs.count > Self.maxVisibleJobs {
                    Text("+\(jobs.count - Self.maxVisibleJobs) more on \(cluster.displayName) — open the dashboard for the full list")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func statusRow(text: String, color: Color, action: (String, () -> Void)?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
                .font(.caption)
                .foregroundStyle(color)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(text)
            Spacer(minLength: 6)
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(cluster.profile.accent.color)
                    .accessibilityLabel("\(action.0) \(cluster.displayName)")
            }
        }
    }
}

// MARK: - Shared home

private struct MenuSharedHomeSection: View {
    let home: MenuBarSharedHome

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MenuMeterRow(
                systemImage: home.row.kind.systemImage,
                iconColor: home.row.kind.color,
                title: home.row.label,
                fraction: home.row.riskFraction ?? 0,
                color: home.row.level.color,
                value: home.row.valueLabel,
                help: "\(home.row.label): \(home.row.detail) — reported by \(home.source.displayName)"
            )
            Text(home.caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .menuSectionSurface(accent: nil)
    }
}

// MARK: - Rows

/// One line: icon, fixed-width title, usage bar, fixed-width value. Used for
/// GPU pools and storage so the bars of every row line up.
private struct MenuMeterRow: View {
    let systemImage: String
    let iconColor: Color
    let title: String
    let fraction: Double
    let color: Color
    let value: String
    let help: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(iconColor)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(width: 70, alignment: .leading)
            MenuUsageBar(value: fraction, color: color)
            Text(value)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .frame(width: 108, alignment: .trailing)
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint(help)
    }
}

private struct MenuUsageBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(MenuPalette.fill)
                RoundedRectangle(cornerRadius: 4)
                    .fill(color)
                    .frame(width: max(proxy.size.width * CGFloat(min(max(value, 0), 1)), value > 0 ? 7 : 0))
                    .animation(AppTheme.smoothEase, value: value)
            }
        }
        .frame(height: 7)
    }
}

private struct MenuJobRow: View {
    let job: MenuJobSummary

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 5)
                .fill(job.color.opacity(0.18))
                .frame(width: 20, height: 20)
                .overlay(
                    Image(systemName: job.iconName)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(job.color)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(job.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(job.timing)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(job.color)
                        .lineLimit(1)
                }
                Text(job.detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(MenuPalette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(MenuPalette.border, lineWidth: 1)
        )
        // Full TRES detail would not fit on the row; keep it one hover away.
        .help(job.resourceSummary)
        .accessibilityElement(children: .combine)
    }
}

/// Display strings for one job row. Built inside a cluster section, so the
/// job id needs no cluster qualifier.
private struct MenuJobSummary {
    let name: String
    let timing: String
    let detail: String
    let resourceSummary: String
    let color: Color
    let iconName: String

    init(job: Job) {
        let isRunning = menuIsRunning(job.state)
        name = job.name.isEmpty ? "(unnamed)" : job.name
        let elapsed = job.elapsed.isEmpty ? "0:00" : job.elapsed
        let limit = job.timeLimit.isEmpty ? missingValuePlaceholder : job.timeLimit
        timing = isRunning ? "\(elapsed) / \(limit)" : SlurmState(parsing: job.state).label
        let partition = job.partition.isEmpty ? missingValuePlaceholder : job.partition
        detail = [job.jobId, partition, menuJobLocation(job)].joined(separator: " · ")
        resourceSummary = menuJobResources(job)
        color = SlurmState(parsing: job.state).color
        iconName = isRunning ? "play.fill" : "clock.fill"
    }
}

// MARK: - Shared menu bar digest

/// Value copy of everything the menu bar surfaces need from one cluster
/// session. Both the status item (StatusBarMonitorController) and the
/// dropdown read these, so a title like "C · train 1:23" and the dropdown
/// beneath it are always computed from the same numbers.
struct MenuBarClusterDigest: Identifiable {
    let profile: ClusterProfile
    let state: ClusterConnectionState
    let isRefreshing: Bool
    let refreshIntervalText: String
    let loginProgress: String?
    let errorMessage: String?
    let collectedAt: Date?
    let hasSnapshot: Bool
    /// Running jobs in Slurm id order (stable across refreshes).
    let runningJobs: [Job]
    let pendingJobs: [Job]
    /// nil when there is no snapshot or it has no GPU nodes.
    let gpu: MenuBarGPUPool?
    /// This cluster's own spaces (scratch, flash, …) in display order. The
    /// shared /users home is excluded on purpose: it is one NFS quota mounted
    /// on every cluster and `MenuBarDigest.sharedHome` shows it once.
    let storage: [MenuBarStorageRow]
    /// The shared home as this cluster's snapshot reported it.
    let sharedHome: StorageSummary?
    /// The job this cluster would put in the menu bar title: most recent
    /// start time, then highest Slurm id. Ids are compared only within this
    /// cluster, never across clusters.
    let newestRunningJob: (job: Job, start: Date?)?

    var id: ClusterID { profile.id }
    var displayName: String { profile.displayName }
    var isEnabled: Bool { state != .disabled }
    var isLive: Bool { state == .live }

    @MainActor
    init(session: ClusterSession) {
        profile = session.profile
        state = session.connectionState
        isRefreshing = session.isRefreshing
        refreshIntervalText = session.refreshIntervalText
        loginProgress = session.loginProgress?.menuTrimmed.menuNilIfEmpty
        errorMessage = session.errorMessage?.menuTrimmed.menuNilIfEmpty

        let snapshot = session.snapshot
        hasSnapshot = snapshot != nil
        collectedAt = snapshot.flatMap { MenuBarDates.collectedAt($0.collectedAt) }

        let jobs = snapshot?.jobs ?? []
        let running = jobs.filter { menuIsRunning($0.state) }.sorted(by: menuJobIDAscending)
        runningJobs = running
        pendingJobs = jobs.filter { menuIsPending($0.state) }.sorted(by: menuJobIDAscending)

        gpu = snapshot.flatMap { MenuBarGPUPool(nodes: $0.nodes, availability: session.gpuAvailability) }

        let spaces = snapshot?.sortedStorage ?? []
        storage = spaces
            .filter { !$0.kind.isSharedAcrossClusters }
            .map(MenuBarStorageRow.init(storage:))
        sharedHome = spaces.first { $0.kind.isSharedAcrossClusters }

        // `running` is id-ascending, so on equal (or missing) start times
        // the later element - the higher Slurm id - wins.
        var newest: (job: Job, start: Date?)?
        for job in running {
            let start = job.startTime.flatMap(MenuBarDates.slurmTime)
            guard let current = newest else {
                newest = (job, start)
                continue
            }
            switch (start, current.start) {
            case let (lhs?, rhs?) where lhs >= rhs:
                newest = (job, start)
            case (.some, .none), (.none, .none):
                newest = (job, start)
            default:
                break
            }
        }
        newestRunningJob = newest
    }

    /// Sign-in text that names the cluster ("Calder: waiting for Duo
    /// approval…"), or nil when this cluster is not signing in.
    var signInText: String? {
        switch state {
        case .connecting:
            return named(loginProgress ?? "signing in — watch for a Duo push")
        case .queued:
            return named("waiting for the previous sign-in to finish")
        default:
            return nil
        }
    }

    /// One-line connection description for the tooltip.
    var connectionText: String {
        switch state {
        case .disabled:
            return "monitoring off"
        case .notConnected:
            return "not connected"
        case .queued:
            return "waiting to sign in"
        case .connecting:
            return "signing in"
        case .live:
            return "live, refreshes every \(refreshIntervalText)"
        case .paused:
            return "paused"
        case .cached:
            return "showing cached data, retrying every \(refreshIntervalText)"
        }
    }

    /// Guidance next to the Connect/Resume button.
    var connectionHint: String {
        switch state {
        case .cached:
            return "Showing cached data — sign in for live updates"
        case .paused:
            return "Monitoring paused — last snapshot shown"
        default:
            return "Not connected — one Duo approval signs in"
        }
    }

    /// Leads with the cluster name, because two clusters may be signing in
    /// one after the other. The login scripts end their progress lines with
    /// the target label ("waiting for Duo approval on your phone (Calder)");
    /// that suffix is dropped so the name is not said twice. A suffix naming
    /// another host (the shared rash jump host) is kept: it says which Duo
    /// push this is.
    private func named(_ text: String) -> String {
        if text.lowercased().hasPrefix(displayName.lowercased()) {
            return text
        }
        var message = text
        let suffix = " (\(displayName))"
        if message.hasSuffix(suffix) {
            message.removeLast(suffix.count)
        }
        return "\(displayName): \(message)"
    }
}

/// One cluster's GPU pool. L40S and H200 are different pools, so pools are
/// always shown per cluster and labelled with their model, never summed.
struct MenuBarGPUPool: Equatable {
    /// Display model, e.g. "H200"; nil when gres carries no type.
    let model: String?
    /// Idle GPUs on nodes that can take jobs right now.
    let idle: Int
    let allocated: Int
    let total: Int
    let nodeCount: Int

    init?(nodes: [NodeSummary], availability: (idle: Int, total: Int, model: String?)) {
        let gpuNodes = nodes.filter { gpuTotal($0) > 0 }
        guard availability.total > 0, !gpuNodes.isEmpty else {
            return nil
        }
        model = availability.model
        idle = availability.idle
        total = availability.total
        allocated = gpuNodes.reduce(0) { $0 + gpuAllocated($1) }
        nodeCount = gpuNodes.count
    }

    /// "H200 GPUs", or "GPUs" when the model is unknown.
    var title: String {
        model.map { "\($0) GPUs" } ?? "GPUs"
    }

    var usedFraction: Double {
        guard total > 0 else {
            return 0
        }
        return min(Double(allocated) / Double(total), 1)
    }

    /// GPUs neither allocated nor idle on an available node: drained, down
    /// or in maintenance.
    var unavailable: Int {
        max(total - allocated - idle, 0)
    }

    var pressure: MenuBarPressure {
        if idle == 0 {
            return .critical
        }
        return usedFraction >= 0.75 ? .warning : .normal
    }

    func helpText(clusterName: String) -> String {
        var text = "\(clusterName): \(idle) of \(total) \(title) free on \(nodeCount) GPU node\(nodeCount == 1 ? "" : "s")"
        if unavailable > 0 {
            text += ", \(unavailable) unavailable (drained or down)"
        }
        return text
    }
}

enum MenuBarPressure {
    case unknown
    case normal
    case warning
    case critical
}

/// Presentation of one storage space, shared by the dropdown rows and the
/// status item tooltip so both report the same dominant pressure.
struct MenuBarStorageRow: Identifiable {
    let id: String
    let kind: StorageKind
    let label: String
    /// max(space, files) as 0...1; nil when the collector had no numbers.
    let riskFraction: Double?
    /// Dominant pressure alone: "42%", "95% files", "over quota", "n/a".
    let percentLabel: String
    /// Dropdown value column: the percentage plus free space when known.
    let valueLabel: String
    let detail: String
    let level: MenuBarPressure

    init(storage: StorageSummary) {
        id = storage.label
        kind = storage.kind
        label = storage.label.capitalized

        let spaceFraction = storage.usedPercent.map { min(max($0 / 100, 0), 1) }
        let fileLimit = storage.fileLimit ?? storage.fileQuota
        var fileFraction: Double?
        if let fileCount = storage.fileCount, let fileLimit, fileLimit > 0 {
            fileFraction = min(Double(fileCount) / Double(fileLimit), 1)
        }

        switch (spaceFraction, fileFraction) {
        case (nil, nil):
            riskFraction = nil
        default:
            riskFraction = max(spaceFraction ?? 0, fileFraction ?? 0)
        }

        // Show whichever pressure dominates, qualified so the row never
        // appears to disagree with its bar (e.g. "95% files" vs 40% space).
        if storage.overQuota == true {
            percentLabel = "over quota"
        } else if let fileFraction, fileFraction > (spaceFraction ?? 0) {
            percentLabel = "\(Int((fileFraction * 100).rounded()))% files"
        } else if let spaceFraction {
            percentLabel = "\(Int((spaceFraction * 100).rounded()))%"
        } else {
            percentLabel = "n/a"
        }
        if let available = storage.availableGB, riskFraction != nil, storage.overQuota != true {
            valueLabel = "\(percentLabel) · \(formatGB(available)) free"
        } else {
            valueLabel = percentLabel
        }

        var parts = [
            "\(formatGB(storage.availableGB)) free",
            "\(formatGB(storage.quotaGB)) quota",
            "\(formatGB(storage.limitGB)) limit"
        ]
        if let fileFraction {
            parts.append("files \(Int((fileFraction * 100).rounded()))%")
        }
        if !storage.path.isEmpty {
            parts.append(storage.path)
        }
        detail = parts.joined(separator: " · ")

        if storage.overQuota == true {
            level = .critical
        } else if let riskFraction {
            level = riskFraction >= 0.9 ? .critical : (riskFraction >= 0.8 ? .warning : .normal)
        } else {
            level = .unknown
        }
    }

    /// "Scratch 42%" / "Flash 91% files" for the tooltip; nil when unknown.
    var pressureText: String? {
        guard riskFraction != nil else {
            return nil
        }
        return "\(label) \(percentLabel)"
    }
}

/// The /users home quota: one NFS export shared by every cluster, so it is
/// listed once - never once per cluster, and never summed.
struct MenuBarSharedHome {
    let row: MenuBarStorageRow
    /// Cluster whose snapshot supplied the figure (the freshest one).
    let source: ClusterProfile
    /// Clusters that mount this home.
    let sharedBy: [ClusterProfile]

    /// "shared by AIRE and Calder".
    var sharedByText: String {
        let names = sharedBy.map(\.displayName)
        switch names.count {
        case 0:
            return "shared by every cluster"
        case 1:
            return "used by \(names[0])"
        case 2:
            return "shared by \(names[0]) and \(names[1])"
        default:
            return "shared by all \(names.count) clusters"
        }
    }

    var caption: String {
        let text = sharedByText
        return text.prefix(1).uppercased() + text.dropFirst() + " — one quota, counted once"
    }
}

/// Combined connection health of the enabled clusters; drives the status
/// item tint and the dropdown header dot.
enum MenuBarHealth {
    /// No cluster is enabled.
    case off
    case allLive
    /// Some live and some not, or showing cached/paused data.
    case partial
    /// Nothing live yet, but a sign-in is in progress.
    case connecting
    /// Nothing live and at least one cluster reports an error.
    case failing
    case offline

    var color: Color {
        switch self {
        case .off, .offline: return .gray
        case .allLive: return .green
        case .partial, .connecting: return .orange
        case .failing: return .red
        }
    }
}

/// Everything the menu bar shows, for all clusters at once.
struct MenuBarDigest {
    /// Every cluster in catalog order, disabled ones included (the dropdown
    /// offers to turn them on). Status totals use `enabled` only.
    let clusters: [MenuBarClusterDigest]
    let sharedHome: MenuBarSharedHome?

    @MainActor
    init(model: AppModel) {
        self.init(sessions: model.sessions)
    }

    @MainActor
    init(sessions: [ClusterSession]) {
        let digests = sessions.map(MenuBarClusterDigest.init(session:))
        clusters = digests
        sharedHome = Self.freshestSharedHome(in: digests)
    }

    var enabled: [MenuBarClusterDigest] {
        clusters.filter(\.isEnabled)
    }

    var runningCount: Int {
        enabled.reduce(0) { $0 + $1.runningJobs.count }
    }

    var health: MenuBarHealth {
        let active = enabled
        if active.isEmpty {
            return .off
        }
        if active.allSatisfy(\.isLive) {
            return .allLive
        }
        if active.contains(where: { $0.isLive || $0.state == .cached || $0.state == .paused }) {
            return .partial
        }
        if active.contains(where: { $0.state.isBusy }) {
            return .connecting
        }
        if active.contains(where: { $0.errorMessage != nil }) {
            return .failing
        }
        return .offline
    }

    /// The cluster whose sign-in is currently in progress (or next in line).
    var busyCluster: MenuBarClusterDigest? {
        enabled.first { $0.state == .connecting } ?? enabled.first { $0.state == .queued }
    }

    /// The running job to name in the status item. Most recent start time
    /// wins across clusters (times are absolute, so that comparison is
    /// meaningful); Slurm job ids are not comparable across clusters and are
    /// never used here. No start time anywhere: first cluster in catalog order.
    var primaryRunningJob: (cluster: MenuBarClusterDigest, job: Job)? {
        var best: (cluster: MenuBarClusterDigest, job: Job, start: Date?)?
        for cluster in enabled {
            guard let candidate = cluster.newestRunningJob else {
                continue
            }
            guard let current = best else {
                best = (cluster, candidate.job, candidate.start)
                continue
            }
            if let start = candidate.start, current.start.map({ start > $0 }) ?? true {
                best = (cluster, candidate.job, candidate.start)
            }
        }
        return best.map { ($0.cluster, $0.job) }
    }

    /// "AIRE live · Calder not connected", or the sign-in in progress.
    var headerStatusLine: String {
        if let signIn = busyCluster?.signInText {
            return signIn
        }
        let active = enabled
        switch health {
        case .off:
            return "Monitoring is off for every cluster"
        case .allLive:
            let names = active.map(\.displayName)
            return names.count == 2 ? "\(names[0]) and \(names[1]) live" : "\(names.joined(separator: ", ")) live"
        default:
            return active
                .map { "\($0.displayName) \($0.state.label.lowercased())" }
                .joined(separator: " · ")
        }
    }

    /// Changes whenever the dropdown's layout meaningfully changes, so
    /// sections animate in and out instead of jumping.
    var animationKey: String {
        clusters.map { cluster in
            "\(cluster.id.rawValue):\(cluster.state.label):\(cluster.runningJobs.count):\(cluster.pendingJobs.count):\(cluster.hasSnapshot)"
        }
        .joined(separator: "|") + (sharedHome == nil ? "" : "|home")
    }

    /// Picks one enabled cluster's report of the shared home: live ones
    /// first, then the most recently collected; ties go to catalog order.
    /// Disabled clusters keep their last snapshot in memory, but like every
    /// other menu figure their (possibly days-old) home row is not shown.
    private static func freshestSharedHome(in clusters: [MenuBarClusterDigest]) -> MenuBarSharedHome? {
        let candidates = clusters.filter(\.isEnabled).compactMap { cluster in
            cluster.sharedHome.map { (cluster: cluster, storage: $0) }
        }
        func rank(_ cluster: MenuBarClusterDigest) -> (Int, Int, Date) {
            (cluster.isEnabled ? 1 : 0, cluster.isLive ? 1 : 0, cluster.collectedAt ?? .distantPast)
        }
        var best: (cluster: MenuBarClusterDigest, storage: StorageSummary)?
        for candidate in candidates {
            guard let current = best else {
                best = candidate
                continue
            }
            if rank(candidate.cluster) > rank(current.cluster) {
                best = candidate
            }
        }
        guard let best else {
            return nil
        }
        let sharedBy = clusters
            .filter { cluster in
                cluster.profile.storage.contains { StorageKind(label: $0.label).isSharedAcrossClusters }
            }
            .map(\.profile)
        return MenuBarSharedHome(
            row: MenuBarStorageRow(storage: best.storage),
            source: best.cluster.profile,
            sharedBy: sharedBy
        )
    }
}

/// Cached formatters: the digest is rebuilt on every model change, so
/// allocating formatters per parse would add up.
@MainActor
enum MenuBarDates {
    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Slurm prints local wall-clock times without a zone
    /// ("2026-10-12T09:41:07"); both Leeds clusters share the Mac's zone.
    private static let slurmLocal: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    /// The collector's `collected_at` (Python isoformat, UTC offset).
    static func collectedAt(_ value: String) -> Date? {
        if let date = isoFractional.date(from: value) ?? iso.date(from: value) {
            return date
        }
        // Python's isoformat() emits microsecond fractions that the strict
        // three-digit fractional parser rejects; strip and retry.
        let stripped = value.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return iso.date(from: stripped)
    }

    /// A job start time; nil for "Unknown", "N/A" and other placeholders.
    static func slurmTime(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return slurmLocal.date(from: trimmed) ?? collectedAt(trimmed) ?? SlurmTimestamp.parse(trimmed)
    }
}

// MARK: - Styling

private extension MenuBarPressure {
    var color: Color {
        switch self {
        case .unknown: return .secondary
        // Matches the dashboard's storage accent instead of a stray blue.
        case .normal: return .teal
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

private extension MenuBarGPUPool {
    var color: Color {
        switch pressure {
        case .unknown: return .secondary
        case .normal: return AppTheme.gpu
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

private enum MenuPalette {
    static let backgroundOverlay = Color(nsColor: .windowBackgroundColor).opacity(0.50)
    static let fill = Color.primary.opacity(0.055)
    static let sectionFill = Color.primary.opacity(0.040)
    static let border = Color.primary.opacity(0.085)
}

private struct MenuVisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}

private extension View {
    /// Section card. A cluster section carries a faint stroke in the
    /// cluster's identity color so AIRE and Calder never blur together.
    func menuSectionSurface(accent: Color?) -> some View {
        self
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MenuPalette.sectionFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(accent.map { $0.opacity(0.30) } ?? MenuPalette.border, lineWidth: 1)
            )
    }
}

// MARK: - Helpers

private func menuIsRunning(_ state: String) -> Bool {
    SlurmState(parsing: state) == .running
}

private func menuIsPending(_ state: String) -> Bool {
    SlurmState(parsing: state) == .pending
}

/// Numeric-aware id order within ONE cluster ("999" before "1000",
/// "123_4" array tasks next to their parent).
private func menuJobIDAscending(_ lhs: Job, _ rhs: Job) -> Bool {
    lhs.jobId.compare(rhs.jobId, options: .numeric) == .orderedAscending
}

private func menuJobLocation(_ job: Job) -> String {
    let value = menuFirstNonEmpty(job.nodeList, job.batchHost, job.reasonOrNodeList, job.nodes)
    return menuIsPending(job.state) ? "reason \(value)" : value
}

private func menuJobResources(_ job: Job) -> String {
    let parts = [
        menuKeyValue("req", job.reqTres),
        menuKeyValue("alloc", job.allocTres),
        menuKeyValue("per node", job.tresPerNode)
    ].compactMap { $0 }

    if !parts.isEmpty {
        return parts.joined(separator: "\n")
    }

    let cpu = job.numCpus.map { "cpu=\($0)" }
    let tasks = job.numTasks.map { "tasks=\($0)" }
    return [cpu, tasks].compactMap { $0 }.joined(separator: " ").menuNilIfEmpty ?? "Resources not reported"
}

private func menuKeyValue(_ key: String, _ value: String?) -> String? {
    guard let value = value?.menuTrimmed, !value.isEmpty else {
        return nil
    }
    return "\(key): \(menuCompactTres(value))"
}

private func menuCompactTres(_ value: String) -> String {
    value.replacingOccurrences(of: "billing=", with: "bill=")
        .replacingOccurrences(of: "gres/gpu=", with: "gpu=")
}

private func menuFirstNonEmpty(_ values: String?...) -> String {
    for value in values {
        if let trimmed = value?.menuTrimmed, !trimmed.isEmpty {
            return trimmed
        }
    }
    return missingValuePlaceholder
}

private func menuRelativeAge(from date: Date, to now: Date) -> String {
    let seconds = max(Int(now.timeIntervalSince(date).rounded()), 0)
    if seconds < 5 {
        return "just now"
    }
    if seconds < 60 {
        return "\(seconds)s ago"
    }
    if seconds < 3_600 {
        return "\(seconds / 60)m ago"
    }
    if seconds < 86_400 {
        return "\(seconds / 3_600)h ago"
    }
    return "\(seconds / 86_400)d ago"
}

private extension String {
    var menuTrimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var menuNilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
