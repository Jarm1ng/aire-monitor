import HPCCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    /// The smallest main window. Every cluster tab, sign-in screen and the
    /// overview must fit the detail column at this size; the layout tests
    /// (MinimumWindowLayoutTests) measure exactly that.
    static let minimumWindowSize = CGSize(width: 1000, height: 680)
    /// The sidebar column never gets narrower than this.
    static let sidebarMinimumWidth: CGFloat = 340
    /// The narrowest and shortest the detail column gets: the minimum window
    /// minus the sidebar (the split view's 1 pt divider aside).
    static var minimumDetailSize: CGSize {
        CGSize(width: minimumWindowSize.width - sidebarMinimumWidth, height: minimumWindowSize.height)
    }

    var body: some View {
        NavigationSplitView {
            ConnectionSidebar(model: model)
                .navigationTitle("Leeds HPC")
                .frame(minWidth: Self.sidebarMinimumWidth)
        } detail: {
            Group {
                switch model.selection {
                case .overview:
                    OverviewDashboard(model: model)
                case .cluster(let id):
                    if let session = model.session(for: id) {
                        ClusterDashboardView(model: model, session: session)
                            // A distinct identity per cluster keeps SwiftUI from
                            // reusing one cluster's view state for another.
                            .id(id)
                    } else {
                        OverviewDashboard(model: model)
                    }
                }
            }
            .background(DashboardBackdrop())
        }
        .frame(minWidth: Self.minimumWindowSize.width, minHeight: Self.minimumWindowSize.height)
    }
}

// MARK: - Dashboard shell

enum DashboardTab: String, CaseIterable, Identifiable {
    case jobs
    case partitions
    case nodes
    case trends
    case storage
    case files
    case terminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jobs:
            return "Jobs"
        case .partitions:
            return "Partitions"
        case .nodes:
            return "Nodes"
        case .trends:
            return "Trends"
        case .storage:
            return "Storage"
        case .files:
            return "Files"
        case .terminal:
            return "Terminal"
        }
    }

    var systemImage: String {
        switch self {
        case .jobs:
            return "list.bullet.rectangle"
        case .partitions:
            return "square.grid.2x2"
        case .nodes:
            return "server.rack"
        case .trends:
            return "chart.xyaxis.line"
        case .storage:
            return "internaldrive"
        case .files:
            return "folder"
        case .terminal:
            return "terminal"
        }
    }

    /// The Go menu's ⌥⌘1…⌥⌘7 select tabs in `allCases` order.
    var shortcutHint: String {
        let index = (Self.allCases.firstIndex(of: self) ?? 0) + 1
        return "⌥⌘\(index)"
    }

    /// Tabs that only need the SSH session, not a snapshot: they work as
    /// soon as the master is up, before (or without) any collector run.
    var needsSnapshot: Bool {
        self != .files && self != .terminal
    }
}

/// A small count on a tab pill ("Jobs 14", "Nodes ⚠ 2"), replacing the row
/// of pinned summary tiles that repeated each tab's own figures.
struct DashboardTabBadge: Equatable {
    let text: String
    var systemImage: String?
    /// nil for a plain count; a tone for figures that signal health.
    var tone: StatusTone?
    /// Full sentence for the tooltip and VoiceOver.
    let help: String
}

/// One cluster's tabbed dashboard. All state comes from the session, and
/// per-tab UI state (selected tab, filters, open job sheet) lives on the
/// session's `ClusterDashboardState`, so switching clusters in the sidebar
/// and back restores exactly where the user was.
struct ClusterDashboardView: View {
    /// For actions only, deliberately NOT observed: AppModel republishes
    /// every session's changes, so observing it here re-ran this cluster's
    /// whole dashboard (every job card) whenever the OTHER cluster refreshed
    /// or a key was typed in the sign-in form. Views that display app-level
    /// state (the hero) observe it themselves.
    let model: AppModel
    @ObservedObject var session: ClusterSession
    @ObservedObject private var dashboard: ClusterDashboardState
    /// Observed for the Terminal tab's badge and to keep the tab bar
    /// reachable while shells are open.
    @ObservedObject private var terminals: TerminalManager

    @State private var confirmation: SessionActionConfirmation?

    init(model: AppModel, session: ClusterSession) {
        self.model = model
        self.session = session
        self._dashboard = ObservedObject(wrappedValue: session.dashboard)
        self._terminals = ObservedObject(wrappedValue: session.terminals)
    }

    /// Tabs appear as soon as the SSH session is usable, not only once a
    /// snapshot exists: Terminal and Files need just the master, and a
    /// terminal is exactly the tool for debugging a collector that keeps
    /// failing. Open terminals keep the bar reachable even if the session
    /// later drops to "not connected". A switched-off cluster shows the
    /// hero instead of days-old data with live remote actions.
    private var showsTabs: Bool {
        guard session.isEnabled else {
            return false
        }
        return session.snapshot != nil || session.isLoggedIn || !terminals.sessions.isEmpty
    }

    var body: some View {
        let presentation = session.presentation
        let showsTabs = showsTabs

        VStack(alignment: .leading, spacing: 12) {
            header(presentation)

            if showsTabs {
                ClusterStatusStrip(
                    session: session,
                    presentation: presentation,
                    onConnect: { confirmation = model.signInOrConfirm([session.id]) },
                    onCancelSignIn: { session.cancelLogin() }
                )

                DashboardTabBar(
                    selection: $dashboard.selectedTab,
                    accent: session.profile.accent.color,
                    badges: tabBadges
                )

                tabArea(presentation)
            } else {
                ConnectHeroView(model: model, session: session, confirmation: $confirmation)
            }
        }
        .padding(18)
        .animation(AppTheme.smoothEase, value: showsTabs)
        .animation(AppTheme.smoothEase, value: presentation.phase)
        .sessionActionConfirmation($confirmation, model: model)
    }

    // MARK: Tab content

    @ViewBuilder
    private func tabArea(_ presentation: ClusterPresentation) -> some View {
        switch dashboard.selectedTab {
        case .terminal:
            // The terminal fills the remaining space and manages its own
            // scrollback — never wrap it in the dashboard scroller.
            TerminalDashboard(session: session, manager: session.terminals)
        case .files:
            // The file table likewise scrolls itself; wrapping it in the
            // shared scroller would collapse its height.
            FilesDashboard(
                session: session,
                files: session.files,
                onOpenShellAt: { path in
                    openShellSession(at: path)
                },
                onOpenVim: { path in
                    openVimSession(for: path)
                }
            )
        default:
            if session.snapshot == nil {
                FirstSnapshotPlaceholder(
                    session: session,
                    presentation: presentation,
                    tab: dashboard.selectedTab,
                    onOpenShell: openShell,
                    onOpenFiles: {
                        withAnimation(AppTheme.softSpring) {
                            dashboard.selectedTab = .files
                        }
                    }
                )
            } else {
                ScrollView {
                    tabContent
                        .padding(.bottom, 18)
                }
            }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch dashboard.selectedTab {
        case .jobs:
            JobsDashboard(
                profile: session.profile,
                jobs: session.snapshot?.jobs ?? [],
                showDetails: $dashboard.jobsShowDetails,
                selectedJob: $dashboard.selectedJob,
                onTailOutput: { job in
                    openTailSession(for: job)
                },
                onCancelJob: { job in
                    try await session.cancelJob(job)
                },
                onBrowseWorkDir: { job in
                    openFileBrowser(for: job)
                },
                usage: session.jobUsage,
                usageHistory: session.jobUsageHistory,
                isSamplingUsage: Binding(
                    get: { model.sampleJobUsage },
                    set: { model.sampleJobUsage = $0 }
                )
            )
        case .partitions:
            PartitionsDashboard(
                profile: session.profile,
                partitions: session.snapshot?.partitions ?? [],
                // Counts by unique node: AIRE's teaching nodes also sit in
                // `nodes`, so summed sinfo rows would count them twice.
                nodes: session.snapshot?.nodes ?? [],
                showDetails: $dashboard.partitionsShowDetails
            )
        case .nodes:
            NodesDashboard(
                profile: session.profile,
                nodes: session.snapshot?.nodes ?? [],
                jobs: session.snapshot?.jobs ?? [],
                filter: $dashboard.nodesFilter,
                showDetails: $dashboard.nodesShowDetails,
                onOpenShell: openShell
            )
        case .trends:
            TrendsDashboard(
                profile: session.profile,
                history: session.history,
                // Per-model capacity signal (an idle L40 is no help to an
                // H200 job) and the model names on the GPU cards.
                gpuFleet: session.gpuFleet,
                // The Storage tab's tone: space, file count, over quota.
                storage: session.snapshot?.sortedStorage ?? [],
                isPaused: session.isPaused,
                // Running / pending / held, as on the overview, sidebar and
                // menu bar (history points only know "queued").
                queueCounts: session.snapshot.map { JobQueueCounts(jobs: $0.jobs) }
            )
        case .storage:
            StorageDashboard(
                profile: session.profile,
                storage: session.snapshot?.sortedStorage ?? [],
                history: session.history
            )
        case .files, .terminal:
            // Rendered by `tabArea` (outside the ScrollView); these arms only
            // satisfy exhaustiveness.
            EmptyView()
        }
    }

    // MARK: Tab badges

    /// Counts that used to sit in four pinned tiles above the tab bar, now
    /// on the tabs they belong to. Only figures worth a glance get a badge.
    private var tabBadges: [DashboardTab: DashboardTabBadge] {
        var badges: [DashboardTab: DashboardTabBadge] = [:]
        if let snapshot = session.snapshot {
            let counts = JobQueueCounts(jobs: snapshot.jobs)
            if counts.total > 0 {
                badges[.jobs] = DashboardTabBadge(
                    text: "\(counts.total)",
                    help: "\(counts.total) job\(counts.total == 1 ? "" : "s"): \(counts.summary)"
                )
            }
            let unavailable = snapshot.nodes.filter { !$0.stateInfo.isAvailable }.count
            if unavailable > 0 {
                badges[.nodes] = DashboardTabBadge(
                    text: "\(unavailable)",
                    systemImage: "exclamationmark.triangle",
                    tone: .unavailable,
                    help: "\(unavailable) of \(snapshot.nodes.count) nodes accept no work (down, drained, maintenance or not responding)"
                )
            }
            // The space under the most pressure (space or file count, as
            // the Storage tab measures it), only once it needs a look.
            if let fullest = snapshot.sortedStorage
                .filter({ $0.usageTone == .warning || $0.usageTone == .critical })
                .max(by: { ($0.pressurePercent ?? 0) < ($1.pressurePercent ?? 0) }) {
                let rounded = Int((fullest.pressurePercent ?? 100).rounded())
                badges[.storage] = DashboardTabBadge(
                    text: fullest.overQuota == true ? "over" : "\(rounded)%",
                    tone: fullest.usageTone,
                    help: fullest.overQuota == true
                        ? "\(fullest.label) is over its quota"
                        : "\(fullest.label) is at \(rounded)% of its \(fullest.fileCountDominates ? "file-count quota" : "space")"
                )
            }
        }
        if !terminals.sessions.isEmpty {
            let count = terminals.sessions.count
            badges[.terminal] = DashboardTabBadge(
                text: "\(count)",
                help: "\(count) terminal session\(count == 1 ? "" : "s") open on \(session.displayName)"
            )
        }
        return badges
    }

    // MARK: Cross-tab actions

    private func openShell() {
        withAnimation(AppTheme.softSpring) {
            dashboard.selectedTab = .terminal
        }
        session.terminals.focusOrOpenShell(settings: session.settings)
    }

    /// Closes the job sheet, jumps to the Files tab, and opens the job's
    /// working directory in this cluster's file browser.
    private func openFileBrowser(for job: Job) {
        guard let workDir = job.workDir, !workDir.isEmpty else {
            return
        }
        dashboard.selectedJob = nil
        withAnimation(AppTheme.softSpring) {
            dashboard.selectedTab = .files
        }
        session.files.navigate(to: workDir)
    }

    /// Files tab → terminal: opens a shell landing in `path` (quoted inside
    /// `openShell(settings:startDirectory:)`).
    private func openShellSession(at path: String) {
        withAnimation(AppTheme.softSpring) {
            dashboard.selectedTab = .terminal
        }
        session.terminals.openShell(settings: session.settings, startDirectory: path)
    }

    /// Files preview → terminal: edits the file with vim over the live SSH
    /// session. The remote path is untrusted listing data, so it is
    /// single-quoted before interpolation.
    private func openVimSession(for path: String) {
        withAnimation(AppTheme.softSpring) {
            dashboard.selectedTab = .terminal
        }
        session.terminals.open(
            command: "vim \(SSHTerminalCommand.shellQuote(path))",
            title: "vim \((path as NSString).lastPathComponent)",
            settings: session.settings
        )
    }

    /// Closes the job sheet, jumps to the terminal tab, and tails the job's
    /// stdout over this cluster's SSH session.
    private func openTailSession(for job: Job) {
        dashboard.selectedJob = nil
        withAnimation(AppTheme.softSpring) {
            dashboard.selectedTab = .terminal
        }
        session.terminals.openTail(job: job, settings: session.settings)
    }

    // MARK: Header

    /// One compact pinned row: identity, where the data comes from, the
    /// idle GPU pools, connection state and the session controls. The tab
    /// bar is the only other pinned element, so content starts high.
    private func header(_ presentation: ClusterPresentation) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ClusterBadge(profile: session.profile, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayName)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                if let snapshot = session.snapshot, session.isEnabled {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(headerSubtitle(for: snapshot, now: context.date))
                            .font(.caption)
                            .foregroundStyle(session.isLoggedIn ? Color.secondary : Color.orange)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(headerTooltip(for: snapshot))
                    }
                } else {
                    Text("\(session.settings.hostname) · \(session.profile.tagline)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            if session.isEnabled, session.snapshot != nil {
                // Per GPU model, never one summed "H200 + L40" figure. Drops
                // to the largest pool, then to nothing, before the title or
                // the controls would have to truncate.
                ViewThatFits(in: .horizontal) {
                    HeaderGPUChips(fleet: session.gpuFleet, limit: 2, isCompact: false)
                    HeaderGPUChips(fleet: session.gpuFleet, limit: 1, isCompact: false)
                    HeaderGPUChips(fleet: session.gpuFleet, limit: 1, isCompact: true)
                    Color.clear.frame(width: 0, height: 0)
                }
            }

            ConnectionStatePill(presentation: presentation)

            Button {
                session.refresh()
            } label: {
                Label(session.isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                    .lineLimit(1)
                    .fixedSize()
            }
            .disabled(session.isRefreshing || !presentation.allowsRefresh)
            .buttonStyle(.bordered)
            .controlSize(.large)
            .keyboardShortcut("r", modifiers: .command)
            .help(refreshHelp(presentation))

            ClusterSessionMenu(model: model, session: session, confirmation: $confirmation)
                .controlSize(.large)
        }
        .animation(AppTheme.smoothEase, value: session.isRefreshing)
    }

    private func refreshHelp(_ presentation: ClusterPresentation) -> String {
        if presentation.allowsRefresh {
            return "Refresh \(session.displayName) now (⌘R) • auto-refreshes every \(session.refreshIntervalText)"
        }
        switch presentation.phase {
        case .off:
            return "\(session.displayName) monitoring is off"
        case .signingIn, .queued:
            return "Available once the sign-in finishes"
        case .checking:
            return "A check for an open session is already running"
        default:
            return "Sign in to \(session.displayName) to refresh"
        }
    }

    private func headerSubtitle(for snapshot: ClusterSnapshot, now: Date) -> String {
        let updated = SlurmTimestamp.relativeText(snapshot.collectedAt, reference: now)
        let staleness = session.isLoggedIn ? "updated \(updated)" : "cached data from \(updated)"
        let host = snapshot.remote.hostname.isEmpty ? session.settings.hostname : snapshot.remote.hostname
        return [host, snapshot.remote.user, staleness]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func headerTooltip(for snapshot: ClusterSnapshot) -> String {
        "Collected \(SlurmTimestamp.absoluteText(snapshot.collectedAt)) • remote time \(SlurmTimestamp.absoluteText(snapshot.remote.remoteTime))"
    }
}

// MARK: - Header GPU chips

/// "1 of 84 L40S idle" per GPU pool, largest pool first; "1 L40S idle" when
/// compact. The full breakdown is in each chip's tooltip.
private struct HeaderGPUChips: View {
    let fleet: GPUFleet
    let limit: Int
    let isCompact: Bool

    var body: some View {
        let shown = Array(fleet.pools.prefix(limit))
        let hidden = fleet.pools.count - shown.count
        HStack(spacing: 6) {
            ForEach(shown) { pool in
                HeaderGPUChip(pool: pool, isCompact: isCompact)
            }
            if hidden > 0 {
                Text("+\(hidden)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .help(fleet.pools.dropFirst(shown.count).map(\.idleFigureSummary).joined(separator: "\n"))
                    .accessibilityLabel("\(hidden) more GPU model\(hidden == 1 ? "" : "s")")
            }
        }
        .fixedSize()
    }
}

private struct HeaderGPUChip: View {
    let pool: GPUPool
    let isCompact: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var tint: Color {
        pool.idleTint
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "memorychip")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(pool.idleFigure)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint.legibleText(in: colorScheme))
            Text(isCompact ? "\(pool.label) idle" : "of \(pool.total) \(pool.label) idle")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.primary.opacity(0.78))
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.10), in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.28), lineWidth: 1))
        .help(pool.breakdownHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(pool.label) GPUs")
        .accessibilityValue("\(pool.idleSpokenSummary); \(pool.breakdownSummary)")
    }
}

// MARK: - First snapshot placeholder

/// A data tab before the first snapshot: says what is happening, and points
/// at the tabs that already work over the live session.
private struct FirstSnapshotPlaceholder: View {
    @ObservedObject var session: ClusterSession
    let presentation: ClusterPresentation
    let tab: DashboardTab
    let onOpenShell: () -> Void
    let onOpenFiles: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            if presentation.showsProgress {
                ProgressView()
                    .controlSize(.regular)
            } else {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 5) {
                Text(presentation.phase == .loadingFirstSnapshot
                    ? "Collecting the first \(session.displayName) snapshot…"
                    : "No \(session.displayName) snapshot yet")
                    .font(.headline)
                Text("\(tab.title) appear\(tab == .storage || tab == .trends ? "s" : "") as soon as it lands. "
                    + "Terminal and Files already work over the live SSH session.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button(action: onOpenShell) {
                    Label("Open a shell", systemImage: "terminal")
                }
                .buttonStyle(.borderedProminent)
                .tint(session.profile.accent.color)
                Button(action: onOpenFiles) {
                    Label("Browse files", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }
            .disabled(!session.isLoggedIn)
        }
        .padding(28)
        .frame(maxWidth: 520)
        .dashboardCard(padding: 20, accent: session.profile.accent.color)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Tab bar

/// Custom pill switcher in the glass language, replacing the stock TabView.
/// When the window is too narrow for every title it drops titles (keeping
/// the selected one as long as possible) instead of breaking labels
/// mid-word ("Parti-tions"); icon-only pills keep their title as tooltip and
/// accessibility label.
struct DashboardTabBar: View {
    @Binding var selection: DashboardTab
    var accent: Color = AppTheme.gpu
    var badges: [DashboardTab: DashboardTabBadge] = [:]
    @Namespace private var pillNamespace

    var body: some View {
        ViewThatFits(in: .horizontal) {
            pills(titles: .all)
            pills(titles: .selectedOnly)
            pills(titles: .none)
        }
        // VoiceOver gets a real segmented control (a tab group with
        // "Jobs, selected, 1 of 7"), not seven loose buttons.
        .accessibilityRepresentation {
            Picker("Dashboard sections", selection: $selection) {
                ForEach(DashboardTab.allCases) { tab in
                    Text(accessibilityTitle(for: tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    /// Which pills keep their title as the bar narrows: all of them, then
    /// only the selected one (so the user still reads where they are), then
    /// none.
    private enum TitleMode {
        case all
        case selectedOnly
        case none
    }

    private func pills(titles: TitleMode) -> some View {
        HStack(spacing: 4) {
            ForEach(DashboardTab.allCases) { tab in
                DashboardTabPill(
                    tab: tab,
                    isSelected: selection == tab,
                    showsTitle: titles == .all || (titles == .selectedOnly && selection == tab),
                    badge: badges[tab],
                    accent: accent,
                    namespace: pillNamespace
                ) {
                    withAnimation(AppTheme.softSpring) {
                        selection = tab
                    }
                }
            }
        }
        .padding(4)
        .background {
            Capsule()
                .fill(.regularMaterial)
                .overlay {
                    Capsule()
                        .stroke(AppTheme.border, lineWidth: 1)
                }
        }
        .fixedSize()
    }

    private func accessibilityTitle(for tab: DashboardTab) -> String {
        guard let badge = badges[tab] else {
            return tab.title
        }
        return "\(tab.title), \(badge.help)"
    }
}

/// One pill of the tab switcher; hover shows a quiet fill on non-selected
/// pills so the switcher matches the session-pill and quick-chip family.
private struct DashboardTabPill: View {
    let tab: DashboardTab
    let isSelected: Bool
    let showsTitle: Bool
    let badge: DashboardTabBadge?
    let accent: Color
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if showsTitle {
                    Label(tab.title, systemImage: tab.systemImage)
                } else {
                    Image(systemName: tab.systemImage)
                }
                if let badge {
                    badgeView(badge)
                }
            }
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.72))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, showsTitle ? 14 : 11)
            .padding(.vertical, 7)
            .background {
                if isSelected {
                    Capsule()
                        .fill(accent.opacity(0.16))
                        .overlay {
                            Capsule()
                                .stroke(accent.opacity(0.35), lineWidth: 1)
                        }
                        .matchedGeometryEffect(id: "dashboard-tab-pill", in: namespace)
                } else if isHovered {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(AppTheme.smoothEase, value: isHovered)
        .help(helpText)
    }

    private var helpText: String {
        var text = "\(tab.title) (\(tab.shortcutHint))"
        if let badge {
            text += " — \(badge.help)"
        }
        return text
    }

    private func badgeView(_ badge: DashboardTabBadge) -> some View {
        let tint = badge.tone?.color ?? Color.primary
        return HStack(spacing: 2) {
            if let systemImage = badge.systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.bold))
            }
            Text(badge.text)
                .font(.caption2.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(badge.tone == nil ? Color.primary.opacity(0.75) : tint.legibleText(in: colorScheme))
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background((badge.tone == nil ? Color.primary.opacity(0.08) : tint.opacity(0.16)), in: Capsule())
    }
}

// MARK: - Hero empty state

/// Shown instead of the tabs while there is nothing to show yet, or the
/// cluster is switched off — so "not connected yet" can never be confused
/// with "cluster is empty", and stale data never passes for current. Every
/// title and action comes from the shared `ClusterPresentation`, so the
/// hero agrees with the sidebar row, the overview card and the menu bar.
struct ConnectHeroView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: ClusterSession
    @Binding var confirmation: SessionActionConfirmation?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let presentation = session.presentation

        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 18) {
                ClusterBadge(profile: session.profile, size: 72)

                VStack(spacing: 6) {
                    Text(title(presentation))
                        .font(.title.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text("\(session.settings.hostname) · \(session.profile.tagline)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                phaseContent(presentation)

                // Why the startup probe or the last refresh failed, when it
                // is more than "not signed in yet" — e.g. a missing
                // collector script, which no sign-in can fix.
                if let failure = heroFailure(presentation) {
                    StatusStripView(content: failure, clusterName: session.displayName)
                        .frame(maxWidth: 480)
                }

                // App-level sign-in problems (missing username or password)
                // are shown here too: the user clicked Connect in this pane,
                // not in the sidebar where they would otherwise appear.
                ForEach(heroErrors, id: \.self) { error in
                    Text(error)
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.red.legibleText(in: colorScheme))
                        .textSelection(.enabled)
                        .frame(maxWidth: 480, alignment: .leading)
                        .lineLimit(8)
                }
            }
            .padding(28)
            .frame(maxWidth: 560)
            .dashboardCard(padding: 24, accent: session.profile.accent.color)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(AppTheme.smoothEase, value: presentation.phase)
    }

    @ViewBuilder
    private func phaseContent(_ presentation: ClusterPresentation) -> some View {
        switch presentation.phase {
        case .signingIn, .queued:
            VStack(spacing: 12) {
                progressCapsule(presentation.detail, tint: .orange)
                Text(signInHint(presentation))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(role: .cancel) {
                    session.cancelLogin()
                } label: {
                    Label("Cancel sign-in", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .help(
                    ClusterStatusContent.cancelSignInHelp(clusterName: session.displayName, isQueued: session.isLoginQueued)
                        + (session.isLoginQueued ? "." : ". A Duo push you approve afterwards no longer opens a session.")
                )
            }
        case .checking:
            // A probe is about to confirm (or rule out) a live master.
            // Offering Connect here would force a sign-in that tears that
            // master down and costs a Duo push.
            progressCapsule(presentation.detail, tint: .green)
        case .loadingFirstSnapshot:
            progressCapsule(presentation.detail, tint: .green)
        case .off(let hasCache):
            VStack(spacing: 12) {
                Text(offDetail(hasCache: hasCache))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
                Button {
                    session.isEnabled = true
                } label: {
                    Label("Turn on \(session.displayName) monitoring", systemImage: "power")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(session.profile.accent.color)
                .disabled(model.isAnyLoginActive)
            }
        case .paused:
            VStack(spacing: 12) {
                Text(presentation.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    session.togglePause()
                } label: {
                    Label("Resume monitoring", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(session.profile.accent.color)
            }
        case .notConnected, .stale, .live:
            let guide = ConnectHeroSteps.make(
                clusterName: session.displayName,
                route: model.connectionRoute,
                failureKind: session.lastRefreshFailure?.kind
            )
            VStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                        HeroStep(number: index + 1, title: step.title, detail: step.detail)
                    }
                }
                .frame(maxWidth: 440, alignment: .leading)

                connectButton(isPrimary: guide.connectIsPrimary)
                    .help(guide.connectHelp)
            }
        }
    }

    /// The hero's Connect. Prominent while signing in is the way forward;
    /// a plain bordered button while a setup problem on this Mac stands,
    /// which no sign-in fixes. It stays enabled even then: the next sign-in
    /// is how the user retries once the settings are fixed, and it still
    /// opens the session for Terminal and Files when only the collector is
    /// missing.
    @ViewBuilder
    private func connectButton(isPrimary: Bool) -> some View {
        let button = Button {
            confirmation = model.signInOrConfirm([session.id])
        } label: {
            Label("Connect to \(session.displayName)", systemImage: "person.crop.circle.badge.checkmark")
        }
        .controlSize(.large)
        .tint(session.profile.accent.color)
        if isPrimary {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func progressCapsule(_ text: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tint.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.25), lineWidth: 1))
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    private func title(_ presentation: ClusterPresentation) -> String {
        let name = session.displayName
        switch presentation.phase {
        case .off:
            return "\(name) monitoring is off"
        case .signingIn:
            return "Signing in to \(name)"
        case .queued:
            return "Waiting to sign in to \(name)"
        case .checking:
            return "Checking \(name)"
        case .paused:
            return "\(name) monitoring is paused"
        case .loadingFirstSnapshot, .live:
            return "Loading \(name)"
        case .notConnected, .stale:
            return "Connect to \(name)"
        }
    }

    private func signInHint(_ presentation: ClusterPresentation) -> String {
        if presentation.phase == .queued {
            return "Sign-ins run one at a time so Duo pushes arrive in order."
        }
        if model.connectionRoute == .rashJump {
            return "Check your phone: rash may ask first (unless already open), then \(session.displayName)."
        }
        return "Check your phone for the \(session.displayName) Duo push."
    }

    private func offDetail(hasCache: Bool) -> String {
        var text = "\(session.displayName) is not being polled."
        if hasCache {
            text += " Its last snapshot is hidden while monitoring is off, so days-old jobs never pass for current ones."
        }
        let openTerminals = session.terminals.sessions.filter(\.isRunning).count
        if openTerminals > 0 {
            text += " \(openTerminals) terminal session\(openTerminals == 1 ? " is" : "s are") still running; turn monitoring on to reach \(openTerminals == 1 ? "it" : "them")."
        }
        return text
    }

    private var heroErrors: [String] {
        [model.errorMessage, session.errorMessage]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            // Already shown, with its kind and details, by the failure strip.
            .filter { error in session.lastRefreshFailure.map { !$0.describes(error) } ?? true }
    }

    /// The last refresh failure, worded like the dashboard's status strip
    /// but without its buttons (the hero has its own). Hidden for the
    /// expected "no control master yet" of a cluster nobody signed in to,
    /// and while a sign-in, check or the cluster's "off" state owns the card.
    private func heroFailure(_ presentation: ClusterPresentation) -> ClusterStatusContent? {
        guard let failure = session.lastRefreshFailure else {
            return nil
        }
        switch presentation.phase {
        case .notConnected, .stale, .live, .loadingFirstSnapshot, .paused:
            break
        case .off, .signingIn, .queued, .checking:
            return nil
        }
        if failure.kind == .transport, session.lastFailureWasMissingMaster {
            return nil
        }
        var content = ClusterStatusContent.failureContent(
            failure,
            input: ClusterStatusInput(session: session, presentation: presentation),
            userAsked: false,
            userMessage: nil
        )
        content.actions = []
        return content
    }
}

/// What the hero's numbered steps say and how loudly it offers Connect,
/// decided from plain values so every case is unit-testable.
///
/// The usual steps lead to a sign-in. While the last refresh failed with a
/// setup problem on this Mac (`RefreshFailure.Kind.configuration`: the
/// collector script missing, the runtime folder not writable, no python3),
/// the steps start with fixing that instead: the failure strip under the
/// card says signing in will not fix it, and a sign-in before the fix
/// still costs a Duo push and loads no dashboard, so the card must not
/// make it the main action.
struct ConnectHeroSteps: Equatable {
    struct Step: Equatable {
        let title: String
        let detail: String
    }

    let steps: [Step]
    /// Connect is the card's main (prominent) action.
    let connectIsPrimary: Bool
    /// The Connect button's tooltip.
    let connectHelp: String

    @MainActor
    static func make(clusterName: String, route: ConnectionRoute, failureKind: RefreshFailure.Kind?) -> ConnectHeroSteps {
        let duo = route == .rashJump
            ? "One approval for rash (skipped if it is already open), then one for \(clusterName)."
            : "One approval on your phone keeps the \(clusterName) session alive."
        guard failureKind == .configuration else {
            return ConnectHeroSteps(
                steps: [
                    Step(title: "Enter your university password", detail: "Use the sidebar. One Keychain entry covers every Leeds cluster."),
                    Step(title: "Approve the Duo push", detail: duo),
                    Step(title: "Watch the live dashboard", detail: refreshCadenceText)
                ],
                connectIsPrimary: true,
                connectHelp: "Sign in to \(clusterName) with the account in the sidebar; a session that is still open is reused"
            )
        }
        return ConnectHeroSteps(
            steps: [
                Step(
                    title: "Fix the setup on this Mac",
                    detail: "Check the sidebar settings, usually \"Project root\" under Advanced (your checkout of this repository). The problem is named below."
                ),
                Step(
                    title: "Then sign in and approve the Duo push",
                    detail: duo + " Before the fix a sign-in still costs a push, and no snapshot loads."
                ),
                Step(title: "Watch the live dashboard", detail: "It loads once the setup problem below is fixed.")
            ],
            connectIsPrimary: false,
            connectHelp: "Sign in to \(clusterName) anyway. No snapshot loads until the setup problem below is fixed"
        )
    }

    /// How often the dashboard refreshes once signed in. The default
    /// cadence, not the session's current one: before a sign-in the
    /// background probes back off, and that longer interval ends with the
    /// sign-in. Storage is collected far less often (`wantsStorage`): most
    /// refreshes pass --skip-storage.
    @MainActor
    static var refreshCadenceText: String {
        let minutes = Int((ClusterSession.storageRefreshInterval / 60).rounded())
        return "Jobs, GPUs and nodes refresh every \(Int(HPCDefaults.refreshInterval))s; "
            + "storage every \(minutes) min, and on every refresh while the Storage tab is open."
    }
}

private struct HeroStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.callout.monospacedDigit().weight(.bold))
                .foregroundStyle(AppTheme.gpu)
                .frame(width: 26, height: 26)
                .background(AppTheme.gpu.opacity(0.14), in: Circle())
                .overlay(Circle().stroke(AppTheme.gpu.opacity(0.28), lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
