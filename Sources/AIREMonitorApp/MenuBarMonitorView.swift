import HPCCore
import AppKit
import SwiftUI

/// Content of the status-bar dropdown: a combined header, one compact
/// section per cluster, the shared home quota once, and the footer actions.
/// Every figure comes from `MenuBarDigest`, the same value the status item
/// title and tooltip are built from, so the two surfaces never disagree.
///
/// The view observes only its `MenuBarDigestStore`, which the status-bar
/// controller updates while the menu is open; the model is held for its
/// actions alone. A refresh on either cluster or a keystroke in the sign-in
/// form therefore no longer re-renders the dropdown.
struct MenuBarMonitorView: View {
    /// For actions only — deliberately not observed.
    let model: AppModel
    @ObservedObject var store: MenuBarDigestStore
    let closeMenu: @MainActor () -> Void

    /// Wide enough for a badge, name, state pill and "Updated" ticker on one
    /// line per cluster; still narrower than a typical menu-bar dropdown.
    static let panelWidth: CGFloat = 400

    init(model: AppModel, store: MenuBarDigestStore, closeMenu: @escaping @MainActor () -> Void) {
        self.model = model
        self.store = store
        self.closeMenu = closeMenu
    }

    /// A dropdown showing the model as it is right now (previews, offscreen
    /// renders). The live menu passes the controller's store instead.
    init(model: AppModel, closeMenu: @escaping @MainActor () -> Void) {
        self.init(model: model, store: MenuBarDigestStore(digest: MenuBarDigest(model: model)), closeMenu: closeMenu)
    }

    var body: some View {
        let digest = store.digest

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
                        onAction: { action in perform(action, on: cluster.id) },
                        onOpenDashboard: { openDashboard(on: .cluster(cluster.id)) }
                    )
                    .transition(.opacity)
                }

                if let home = digest.sharedHome {
                    MenuSharedHomeSection(home: home)
                        .transition(.opacity)
                }

                if let message = digest.appErrorMessage {
                    // App-level problems, e.g. Connect pressed with no saved
                    // password. Without this the Connect button would look
                    // dead from the menu.
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(StatusTone.critical.color)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(message)
                }

                Divider()
                    .opacity(0.55)

                footer(digest)
            }
            .padding(12)
        }
        .frame(width: Self.panelWidth)
        .animation(AppTheme.smoothEase, value: digest.animationKey)
    }

    private func footer(_ digest: MenuBarDigest) -> some View {
        HStack(spacing: 8) {
            Button {
                model.refreshAll()
            } label: {
                Label(digest.isAnyRefreshing ? "Refreshing" : "Refresh all", systemImage: "arrow.clockwise")
            }
            // Off unless some cluster could refresh right now (per its
            // ClusterPresentation): a never-signed-in cluster would only
            // paint a "control master is not running" error.
            .disabled(!digest.canRefreshAny)
            .help("Refresh every connected cluster now")

            Button {
                openDashboard(on: nil)
            } label: {
                Label("Dashboard", systemImage: "macwindow")
            }
            .help("Open the dashboard window")

            Button {
                closeMenu()
                model.openDesktopWidget()
            } label: {
                Label("Widget", systemImage: "rectangle.on.rectangle.angled")
            }
            .help("Open the desktop widget")

            Spacer(minLength: 0)

            // Menu-bar apps are expected to offer Quit in their menu. The
            // menu closes first; the quit itself goes through the app
            // delegate, which can still ask about running terminals.
            Button {
                closeMenu()
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            } label: {
                Label("Quit", systemImage: "power")
            }
            .help("Quit Leeds HPC Monitor")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func perform(_ action: ClusterPresentation.Action, on id: ClusterID) {
        switch action {
        case .connect:
            model.connect(id)
        case .resume:
            model.session(for: id)?.togglePause()
        case .turnOn:
            model.session(for: id)?.isEnabled = true
        }
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
    let onAction: (ClusterPresentation.Action) -> Void
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
                statusRow(text: cluster.connectionHint, color: .secondary, action: cluster.status.primaryAction)
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
            MenuPhasePill(status: cluster.status)

            Spacer(minLength: 6)

            // Not while Slurm is failing: the snapshot is stamped with each
            // attempt, so "Updated 4s ago" would vouch for a job list that is
            // only carried forward.
            if let collected = cluster.collectedAt, cluster.isEnabled, !cluster.isDegraded {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Updated \(SlurmTimestamp.ageText(from: collected, now: context.date))")
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
            progressRow(signIn)
        } else if cluster.status.phase == .checking {
            // The startup probe may confirm a live master any moment; a
            // Connect here would force a re-login and cost a Duo push.
            progressRow(cluster.status.detail.menuNilIfEmpty ?? "Checking for an open \(cluster.displayName) session…")
        } else if let error = cluster.errorMessage, !cluster.isLive {
            statusRow(text: error, color: StatusTone.critical.color, action: cluster.status.primaryAction)
        } else if let action = cluster.status.primaryAction {
            statusRow(text: cluster.connectionHint, color: .secondary, action: action)
        } else if cluster.status.phase == .loadingFirstSnapshot {
            progressRow("Signed in — collecting the first snapshot…")
        } else if let issue = cluster.schedulerIssue {
            // Live, but Slurm is failing: the one-line summary rather than
            // the manual refresh's long explanation. No button — the
            // connection is fine and the app keeps retrying.
            statusRow(text: "\(issue) — showing the previous figures", color: StatusTone.warning.color, action: nil)
        } else if let error = cluster.errorMessage {
            // Live but the last manual refresh failed: worth a line, no
            // button (the session is still up).
            statusRow(text: error, color: StatusTone.warning.color, action: nil)
        }

        if cluster.hasSnapshot {
            if let asOf = cluster.asOfText {
                Label("Figures \(asOf) — not live", systemImage: "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            jobsBlock

            ForEach(cluster.gpuPools) { pool in
                MenuGPURow(pool: pool, clusterName: cluster.displayName, isCurrent: cluster.hasCurrentFigures)
            }

            ForEach(cluster.storage) { row in
                MenuMeterRow(
                    systemImage: row.kind.systemImage,
                    iconColor: row.kind.color,
                    title: row.label,
                    fraction: row.riskFraction ?? 0,
                    color: row.tone.color,
                    value: row.valueLabel,
                    compactValue: row.percentLabel,
                    help: "\(cluster.displayName) \(row.label): \(row.detail)"
                )
            }
        }
    }

    @ViewBuilder
    private var jobsBlock: some View {
        let jobs = cluster.jobs
        if jobs.isEmpty {
            Text("No running or pending jobs")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                // Cached counts stay grey: green "17 running" under a
                // cached snapshot (or a job list carried forward while Slurm
                // is failing) would read as live.
                HStack(spacing: 10) {
                    Label("\(cluster.runningJobs.count) running", systemImage: "play.fill")
                        .foregroundStyle(
                            cluster.hasCurrentFigures && !cluster.runningJobs.isEmpty ? SlurmState.running.color : Color.secondary
                        )
                    // Held jobs are never "pending": they will not start
                    // until released (JobQueueCounts, as on the overview).
                    if cluster.showsPendingCount {
                        Label("\(cluster.pendingTaskCount) pending", systemImage: "clock.fill")
                            .foregroundStyle(
                                cluster.hasCurrentFigures && cluster.pendingTaskCount > 0 ? SlurmState.pending.color : Color.secondary
                            )
                    }
                    if cluster.heldTaskCount > 0 {
                        Label("\(cluster.heldTaskCount) held", systemImage: "pause.circle.fill")
                            .foregroundStyle(.secondary)
                            .help("Held by you or an administrator: will not start until released")
                    }
                    if cluster.otherJobCount > 0 {
                        Label(
                            "\(cluster.otherJobCount) \(cluster.otherJobsAreSuspended ? "suspended" : "other")",
                            systemImage: "pause.fill"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                .font(.caption2.weight(.semibold).monospacedDigit())
                .accessibilityElement(children: .combine)

                ForEach(jobs.prefix(Self.maxVisibleJobs)) { job in
                    MenuJobRow(job: MenuJobSummary(job: job, isLive: cluster.hasCurrentFigures))
                }

                // Counts jobs, not rows, so it adds up with the count line
                // above (a queued array remainder is one row for many tasks).
                if let hidden = cluster.hiddenJobsText(afterFirst: Self.maxVisibleJobs),
                   let compact = cluster.hiddenJobsText(afterFirst: Self.maxVisibleJobs, compact: true) {
                    ViewThatFits(in: .horizontal) {
                        hiddenJobsLine("\(hidden) — open the dashboard for the full list")
                        hiddenJobsLine("\(hidden) — open the dashboard")
                        hiddenJobsLine(hidden)
                        hiddenJobsLine(compact)
                    }
                    .help("\(hidden). A queued array remainder is one row standing for all of its tasks.")
                }
            }
        }
    }

    private func hiddenJobsLine(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize()
    }

    private func progressRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.75)
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(text)
            Spacer(minLength: 0)
        }
    }

    private func statusRow(text: String, color: Color, action: ClusterPresentation.Action?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
                .font(.caption)
                .foregroundStyle(color)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(text)
            Spacer(minLength: 6)
            if let action {
                Button(action.menuTitle) {
                    onAction(action)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(cluster.profile.accent.color)
                .accessibilityLabel("\(action.menuTitle) \(cluster.displayName)")
            }
        }
    }
}

private extension ClusterPresentation.Action {
    var menuTitle: String {
        switch self {
        case .connect: return "Connect"
        case .turnOn: return "Turn on"
        case .resume: return "Resume"
        }
    }
}

/// The cluster's state exactly as ClusterPresentation words it.
private struct MenuPhasePill: View {
    let status: MenuBarClusterStatus

    var body: some View {
        HStack(spacing: 5) {
            if status.showsProgress {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(status.tint)
                    .frame(width: 7, height: 7)
            }
            Text(status.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(status.isLive ? Color.primary : Color.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(status.tint.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(status.tint.opacity(0.25), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection: \(status.title)")
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
                color: home.row.tone.color,
                value: home.row.valueLabel,
                compactValue: home.row.percentLabel,
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
/// storage; `MenuGPURow` shares its columns so the bars of every row line
/// up. The value falls back to its compact form when the full text would
/// be cut off. A nil fraction draws only the bar's track, never a definite
/// fill.
private struct MenuMeterRow: View {
    let systemImage: String
    let iconColor: Color
    let title: String
    let fraction: Double?
    let color: Color
    let value: String
    let compactValue: String
    /// What VoiceOver reads instead of `value`, e.g. for a "?" figure.
    var spokenValue: String?
    let help: String

    static let iconWidth: CGFloat = 14
    static let spacing: CGFloat = 6
    /// Fits "H200 GPUs" and "Scratch"; the bar takes what is left.
    static let titleWidth: CGFloat = 84
    /// Fits "98% files · 2.4 TB free".
    static let valueWidth: CGFloat = 150
    /// Where the bar starts: text under it lines up with it.
    static var barInset: CGFloat { iconWidth + spacing + titleWidth + spacing }

    var body: some View {
        HStack(spacing: Self.spacing) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(iconColor)
                .frame(width: Self.iconWidth)
                .accessibilityHidden(true)
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(width: Self.titleWidth, alignment: .leading)
            MenuUsageBar(value: fraction, color: color)
                .frame(minWidth: 36)
            ViewThatFits(in: .horizontal) {
                valueLabel(value)
                valueLabel(compactValue)
            }
            .frame(width: Self.valueWidth, alignment: .trailing)
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(spokenValue ?? value)
        .accessibilityHint(help)
    }

    private func valueLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }
}

/// One GPU model on one cluster, in `MenuMeterRow`'s columns so its meter
/// lines up with the storage bars. The meter shows the pool's make-up —
/// idle, in use, stranded, unavailable, unknown — in the shared capacity
/// colours (`GPUPoolMeter`, as on the overview tile), never an empty track
/// that would read as free GPUs. The idle figure takes the shared idle tone
/// (`GPUPool.idleTone`), and the line beneath names every GPU that is not
/// idle, so the grey parts of the meter are in plain text too.
private struct MenuGPURow: View {
    let pool: MenuBarGPUPool
    let clusterName: String
    /// Live with Slurm answering. Otherwise the figures are not current
    /// and the row is drawn without status colours.
    let isCurrent: Bool

    var body: some View {
        let help = pool.helpText(clusterName: clusterName)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: MenuMeterRow.spacing) {
                Image(systemName: "memorychip")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.gpu)
                    .frame(width: MenuMeterRow.iconWidth)
                Text(pool.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .frame(width: MenuMeterRow.titleWidth, alignment: .leading)
                GPUPoolMeter(pool: pool.pool, height: 7)
                    .saturation(isCurrent ? 1 : 0)
                    .frame(minWidth: 36)
                Text(pool.valueText)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(isCurrent ? pool.tone.color : Color.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: MenuMeterRow.valueWidth, alignment: .trailing)
            }
            Text(pool.detailText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, MenuMeterRow.barInset)
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pool.title)
        .accessibilityValue(pool.spokenValueText)
        .accessibilityHint(help)
    }
}

/// Thin usage bar; an unknown value shows only the track.
private struct MenuUsageBar: View {
    let value: Double?
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(MenuPalette.fill)
                if let value {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: max(proxy.size.width * CGFloat(min(max(value, 0), 1)), value > 0 ? 7 : 0))
                }
            }
            .animation(AppTheme.smoothEase, value: value)
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
struct MenuJobSummary: Equatable {
    let name: String
    let timing: String
    let detail: String
    let resourceSummary: String
    let color: Color
    let iconName: String

    /// `isLive` false: the row comes from a cached or paused snapshot, so it
    /// shows the job's state rather than an elapsed time frozen at the
    /// snapshot, in grey rather than live state colours.
    init(job: Job, isLive: Bool) {
        let state = job.jobState
        name = job.name.isEmpty ? "(unnamed)" : job.name
        if state.occupiesNodes, isLive {
            let elapsed = job.elapsed.isEmpty ? "0:00" : job.elapsed
            let limit = job.timeLimit.isEmpty ? missingValuePlaceholder : job.timeLimit
            timing = "\(elapsed) / \(limit)"
        } else {
            timing = state.label
        }
        // The pending remainder of an array is one row for many queued
        // tasks: name the tasks, not the bare array id that would read as
        // a single job (and that scancel treats as the whole array).
        var identifier = job.displayJobID
        if job.isArrayRemainder {
            let tasks = job.taskMultiplicity
            identifier += tasks == 1 ? " (1 task)" : " (\(tasks) tasks)"
        }
        let partition = job.partition.isEmpty ? missingValuePlaceholder : job.partition
        detail = [identifier, partition, menuJobLocation(job)].joined(separator: " · ")
        resourceSummary = menuJobResources(job)
        color = isLive ? SlurmState(job: job.state).color : .secondary
        if state.occupiesNodes {
            iconName = "play.fill"
        } else if state == .suspended {
            iconName = "pause.fill"
        } else {
            iconName = "clock.fill"
        }
    }
}

// MARK: - Styling

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

private func menuJobLocation(_ job: Job) -> String {
    let value = menuFirstNonEmpty(job.nodeList, job.batchHost, job.reasonOrNodeList, job.nodes)
    return job.jobState.isPending ? "reason \(value)" : value
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
