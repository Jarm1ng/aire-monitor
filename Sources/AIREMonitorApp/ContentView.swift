import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            ConnectionSidebar(model: model)
                .navigationTitle("Leeds HPC")
                .frame(minWidth: 340)
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
        .frame(minWidth: 1000, minHeight: 680)
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
}

/// One cluster's tabbed dashboard. All state comes from the session, and
/// per-tab UI state (selected tab, filters, open job sheet) lives on the
/// session's `ClusterDashboardState`, so switching clusters in the sidebar
/// and back restores exactly where the user was.
struct ClusterDashboardView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: ClusterSession
    @ObservedObject private var dashboard: ClusterDashboardState

    init(model: AppModel, session: ClusterSession) {
        self.model = model
        self.session = session
        self._dashboard = ObservedObject(wrappedValue: session.dashboard)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if session.snapshot == nil {
                ConnectHeroView(model: model, session: session)
            } else {
                summaryCards
                DashboardTabBar(selection: $dashboard.selectedTab, accent: session.profile.accent.color)

                if dashboard.selectedTab == .terminal {
                    // The terminal fills the remaining space and manages its
                    // own scrollback — never wrap it in the dashboard scroller.
                    TerminalDashboard(session: session, manager: session.terminals)
                } else if dashboard.selectedTab == .files {
                    // The file table likewise scrolls itself; wrapping it in
                    // the shared scroller would collapse its height.
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
                } else {
                    ScrollView {
                        tabContent
                            .padding(.bottom, 18)
                    }
                }
            }
        }
        .padding(18)
        .animation(AppTheme.smoothEase, value: session.snapshot == nil)
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
                }
            )
        case .partitions:
            PartitionsDashboard(
                profile: session.profile,
                partitions: session.snapshot?.partitions ?? [],
                showDetails: $dashboard.partitionsShowDetails
            )
        case .nodes:
            NodesDashboard(
                profile: session.profile,
                nodes: session.snapshot?.nodes ?? [],
                jobs: session.snapshot?.jobs ?? [],
                filter: $dashboard.nodesFilter,
                showDetails: $dashboard.nodesShowDetails,
                onOpenShell: {
                    withAnimation(AppTheme.softSpring) {
                        dashboard.selectedTab = .terminal
                    }
                    session.terminals.focusOrOpenShell(settings: session.settings)
                }
            )
        case .trends:
            TrendsDashboard(
                profile: session.profile,
                history: session.history,
                gpuModel: session.gpuAvailability.model
            )
        case .storage:
            StorageDashboard(
                profile: session.profile,
                storage: session.snapshot?.sortedStorage ?? [],
                history: session.history
            )
        case .files, .terminal:
            // Rendered directly in `body` (outside the ScrollView); these
            // arms only satisfy exhaustiveness.
            EmptyView()
        }
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

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ClusterBadge(profile: session.profile, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayName)
                    .font(.title2.weight(.semibold))
                if let snapshot = session.snapshot {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(headerSubtitle(for: snapshot, now: context.date))
                            .font(.caption)
                            .foregroundStyle(session.isLoggedIn ? Color.secondary : Color.orange)
                            .textSelection(.enabled)
                            .help(headerTooltip(for: snapshot))
                    }
                } else {
                    Text("\(session.settings.hostname) • \(session.profile.tagline)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            ConnectionStatePill(state: session.connectionState)
            Button {
                session.refresh()
            } label: {
                Label(session.isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(session.isRefreshing || session.isLoggingIn || !session.isEnabled)
            .buttonStyle(.bordered)
            .controlSize(.large)
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh \(session.displayName) now (⌘R) • auto-refreshes every \(session.refreshIntervalText)")
        }
        .animation(AppTheme.smoothEase, value: session.isRefreshing)
    }

    private func headerSubtitle(for snapshot: ClusterSnapshot, now: Date) -> String {
        let updated = SlurmTimestamp.relativeText(snapshot.collectedAt, reference: now)
        let staleness = session.isLoggedIn ? "updated \(updated)" : "cached data from \(updated)"
        return "\(snapshot.remote.hostname) • \(snapshot.remote.user) • \(staleness)"
    }

    private func headerTooltip(for snapshot: ClusterSnapshot) -> String {
        "Collected \(SlurmTimestamp.absoluteText(snapshot.collectedAt)) • remote time \(SlurmTimestamp.absoluteText(snapshot.remote.remoteTime))"
    }

    private var summaryCards: some View {
        let gpus = session.gpuAvailability
        return HStack(spacing: 12) {
            MetricView(title: "My jobs", value: "\(session.snapshot?.jobs.count ?? 0)", systemImage: "list.bullet.rectangle", accent: .blue)
            MetricView(title: "Partitions", value: "\(Set(session.snapshot?.partitions.map(\.partition) ?? []).count)", systemImage: "square.grid.2x2", accent: .purple)
            MetricView(title: "Nodes", value: "\(session.snapshot?.nodes.count ?? 0)", systemImage: "server.rack", accent: .teal)
            MetricView(
                title: gpus.model.map { "Idle \($0) GPUs" } ?? "Idle GPUs",
                value: "\(gpus.idle) / \(gpus.total)",
                systemImage: "memorychip",
                accent: AppTheme.gpu
            )
        }
    }
}

// MARK: - Tab bar

/// Custom pill switcher in the glass language, replacing the stock TabView.
struct DashboardTabBar: View {
    @Binding var selection: DashboardTab
    var accent: Color = AppTheme.gpu
    @Namespace private var pillNamespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(DashboardTab.allCases) { tab in
                DashboardTabPill(tab: tab, isSelected: selection == tab, accent: accent, namespace: pillNamespace) {
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dashboard sections")
    }
}

/// One pill of the tab switcher; hover shows a quiet fill on non-selected
/// pills so the switcher matches the session-pill and quick-chip family.
private struct DashboardTabPill: View {
    let tab: DashboardTab
    let isSelected: Bool
    let accent: Color
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(tab.title, systemImage: tab.systemImage)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.horizontal, 14)
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
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Hero empty state

/// First-run / logged-out hero shown instead of zeroed metrics, so
/// "not connected yet" can never be confused with "cluster is empty".
struct ConnectHeroView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: ClusterSession

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 18) {
                ClusterBadge(profile: session.profile, size: 72)

                VStack(spacing: 6) {
                    Text(heroTitle)
                        .font(.title.weight(.semibold))
                    Text("\(session.settings.hostname) • \(session.profile.tagline)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if session.isLoggingIn || session.isLoginQueued {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(session.loginProgress ?? session.statusMessage)
                            .font(.callout.weight(.medium))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.12), in: Capsule())
                    .overlay(Capsule().stroke(Color.orange.opacity(0.25), lineWidth: 1))
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else if !session.isEnabled {
                    Button("Turn on \(session.displayName) monitoring") {
                        session.isEnabled = true
                    }
                    .buttonStyle(.borderedProminent)
                } else if session.isLoggedIn || session.isRefreshing {
                    // Signed in (or probing an existing session) but the
                    // first snapshot is still being collected — common on a
                    // first sign-in with no cache. Offering Connect here
                    // would invite a needless second sign-in and Duo push.
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(session.isLoggedIn
                            ? "Signed in — collecting the first \(session.displayName) snapshot…"
                            : "Checking for a live \(session.displayName) session…")
                            .font(.callout.weight(.medium))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.green.opacity(0.10), in: Capsule())
                    .overlay(Capsule().stroke(Color.green.opacity(0.22), lineWidth: 1))
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        HeroStep(
                            number: 1,
                            title: "Enter your university password",
                            detail: "Use the sidebar. One Keychain entry covers every Leeds cluster."
                        )
                        HeroStep(
                            number: 2,
                            title: "Approve the Duo push",
                            detail: model.connectionRoute == .rashJump
                                ? "One approval for rash (skipped if it is already open), then one for \(session.displayName)."
                                : "One approval on your phone keeps the \(session.displayName) session alive."
                        )
                        HeroStep(
                            number: 3,
                            title: "Watch the live dashboard",
                            detail: "Jobs, GPUs, nodes and storage refresh automatically every \(session.refreshIntervalText)."
                        )
                    }
                    .frame(maxWidth: 440, alignment: .leading)

                    Button {
                        model.connect(session.id)
                    } label: {
                        Label("Connect to \(session.displayName)", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(session.profile.accent.color)
                }

                // App-level sign-in problems (missing username or password)
                // are shown here too: the user clicked Connect in this pane,
                // not in the sidebar where they would otherwise appear.
                ForEach(heroErrors, id: \.self) { error in
                    Text(error)
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
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
        .animation(AppTheme.smoothEase, value: session.isLoggingIn)
    }

    private var heroTitle: String {
        if !session.isEnabled {
            return "\(session.displayName) monitoring is off"
        }
        if session.isLoggedIn {
            return "Loading \(session.displayName)"
        }
        return "Connect to \(session.displayName)"
    }

    private var heroErrors: [String] {
        [model.errorMessage, session.errorMessage]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
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
