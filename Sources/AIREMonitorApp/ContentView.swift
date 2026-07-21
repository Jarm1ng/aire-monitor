import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    // Owned here (not in DashboardView) so terminal sessions and their ssh
    // processes survive any dashboard rebuild, not just tab switches.
    @StateObject private var terminalManager = TerminalManager()
    // Owned here for the same reason: navigation history, listings, and
    // in-flight transfers survive dashboard rebuilds and tab switches.
    @StateObject private var fileBrowserModel = FileBrowserModel()

    var body: some View {
        NavigationSplitView {
            ConnectionSidebar(model: model)
                .navigationTitle("AIRE")
                .frame(minWidth: 340)
        } detail: {
            DashboardView(
                model: model,
                terminalManager: terminalManager,
                fileBrowserModel: fileBrowserModel
            )
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

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var terminalManager: TerminalManager
    @ObservedObject var fileBrowserModel: FileBrowserModel
    @State private var selectedTab: DashboardTab = .jobs

    // Per-tab UI state lives here (not in the child dashboards) because the
    // pill switcher's `switch` removes non-selected tabs from the hierarchy,
    // which would destroy child @State on every switch. The old stock TabView
    // kept all children alive; hoisting preserves that behavior.
    @State private var jobsShowDetails = false
    @State private var selectedJob: Job?
    @State private var partitionsShowDetails = false
    @State private var nodesFilter: NodeFilter = .all
    @State private var nodesShowDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if model.snapshot == nil {
                ConnectHeroView(model: model)
            } else {
                summaryCards
                DashboardTabBar(selection: $selectedTab)

                if selectedTab == .terminal {
                    // The terminal fills the remaining space and manages its
                    // own scrollback — never wrap it in the dashboard scroller.
                    TerminalDashboard(model: model, manager: terminalManager)
                } else if selectedTab == .files {
                    // The file table likewise scrolls itself; wrapping it in
                    // the shared scroller would collapse its height.
                    FilesDashboard(
                        model: model,
                        files: fileBrowserModel,
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
        .animation(AIRETheme.smoothEase, value: model.snapshot == nil)
        .onAppear {
            fileBrowserModel.attach(appModel: model)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .jobs:
            JobsDashboard(
                jobs: model.snapshot?.jobs ?? [],
                showDetails: $jobsShowDetails,
                selectedJob: $selectedJob,
                onTailOutput: { job in
                    openTailSession(for: job)
                },
                onCancelJob: { job in
                    try await cancelJob(job)
                },
                onBrowseWorkDir: { job in
                    openFileBrowser(for: job)
                }
            )
        case .partitions:
            PartitionsDashboard(
                partitions: model.snapshot?.partitions ?? [],
                showDetails: $partitionsShowDetails
            )
        case .nodes:
            NodesDashboard(
                nodes: model.snapshot?.nodes ?? [],
                jobs: model.snapshot?.jobs ?? [],
                filter: $nodesFilter,
                showDetails: $nodesShowDetails,
                onOpenShell: {
                    withAnimation(AIRETheme.softSpring) {
                        selectedTab = .terminal
                    }
                    terminalManager.focusOrOpenShell(settings: model.settings)
                }
            )
        case .trends:
            TrendsDashboard(history: model.history, snapshot: model.snapshot)
        case .storage:
            StorageDashboard(storage: model.snapshot?.storage ?? [], history: model.history)
        case .files, .terminal:
            // Rendered directly in `body` (outside the ScrollView); these
            // arms only satisfy exhaustiveness.
            EmptyView()
        }
    }

    /// Closes the job sheet, jumps to the Files tab, and opens the job's
    /// working directory in the file browser.
    private func openFileBrowser(for job: Job) {
        guard let workDir = job.workDir, !workDir.isEmpty else {
            return
        }
        selectedJob = nil
        fileBrowserModel.attach(appModel: model)
        withAnimation(AIRETheme.softSpring) {
            selectedTab = .files
        }
        fileBrowserModel.navigate(to: workDir)
    }

    /// Files tab → terminal: opens a shell landing in `path` (quoted inside
    /// `openShell(settings:startDirectory:)`).
    private func openShellSession(at path: String) {
        withAnimation(AIRETheme.softSpring) {
            selectedTab = .terminal
        }
        terminalManager.openShell(settings: model.settings, startDirectory: path)
    }

    /// Files preview → terminal: edits the file with vim over the live SSH
    /// session. The remote path is untrusted listing data, so it is
    /// single-quoted before interpolation.
    private func openVimSession(for path: String) {
        withAnimation(AIRETheme.softSpring) {
            selectedTab = .terminal
        }
        terminalManager.open(
            command: "vim \(SSHTerminalCommand.shellQuote(path))",
            title: "vim \((path as NSString).lastPathComponent)",
            settings: model.settings
        )
    }

    /// Closes the job sheet, jumps to the terminal tab, and tails the job's
    /// stdout over the existing SSH session.
    private func openTailSession(for job: Job) {
        selectedJob = nil
        withAnimation(AIRETheme.softSpring) {
            selectedTab = .terminal
        }
        terminalManager.openTail(job: job, settings: model.settings)
    }

    /// Runs `scancel` for the job over the ControlMaster socket, then asks the
    /// model for a fresh snapshot so the queue reflects the cancellation.
    /// Failures also land in `model.errorMessage`, because the job sheet that
    /// shows the inline status can be dismissed while the cancel is in flight.
    private func cancelJob(_ job: Job) async throws {
        do {
            let result = try await MonitorService().runRemoteCommand(
                settings: model.settings,
                command: "scancel \(SSHTerminalCommand.shellQuote(job.jobId))"
            )
            guard result.exitCode == 0 else {
                let message = result.stderr.isEmpty ? result.stdout : result.stderr
                throw MonitorError.processFailed(
                    message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "scancel exited with code \(result.exitCode)"
                        : MonitorService.explainSSHFailure(message, exitCode: result.exitCode)
                )
            }
        } catch {
            model.errorMessage = "Could not cancel job \(job.jobId) — \(error.localizedDescription)"
            throw error
        }
        // Non-droppable: a plain refresh() silently no-ops while another
        // refresh is in flight, which would leave the cancelled job showing
        // as RUNNING (indefinitely so while monitoring is paused).
        model.refreshAfterMutation()
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AIRE Monitor")
                    .font(.title2.weight(.semibold))
                if let snapshot = model.snapshot {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(headerSubtitle(for: snapshot, now: context.date))
                            .font(.caption)
                            .foregroundStyle(model.isLoggedIn ? Color.secondary : Color.orange)
                            .textSelection(.enabled)
                            .help(headerTooltip(for: snapshot))
                    }
                } else {
                    Text("Not connected yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            StatusBadge(isConnected: model.isLoggedIn, isCached: model.hasCachedSnapshot)
            Button {
                model.refresh()
            } label: {
                Label(model.isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isRefreshing || model.isLoggingIn)
            .buttonStyle(.bordered)
            .controlSize(.large)
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh now (⌘R) • auto-refreshes every \(model.refreshIntervalText)")
        }
        .animation(AIRETheme.smoothEase, value: model.isRefreshing)
    }

    private func headerSubtitle(for snapshot: ClusterSnapshot, now: Date) -> String {
        let updated = AIRETimestamp.relativeText(snapshot.collectedAt, reference: now)
        let staleness = model.isLoggedIn ? "updated \(updated)" : "cached data from \(updated)"
        return "\(snapshot.remote.hostname) • \(snapshot.remote.user) • \(staleness)"
    }

    private func headerTooltip(for snapshot: ClusterSnapshot) -> String {
        "Collected \(AIRETimestamp.absoluteText(snapshot.collectedAt)) • remote time \(AIRETimestamp.absoluteText(snapshot.remote.remoteTime))"
    }

    private var summaryCards: some View {
        HStack(spacing: 12) {
            MetricView(title: "Jobs", value: "\(model.snapshot?.jobs.count ?? 0)", systemImage: "list.bullet.rectangle", accent: .blue)
            MetricView(title: "Partitions", value: "\(model.snapshot?.partitions.count ?? 0)", systemImage: "square.grid.2x2", accent: .purple)
            MetricView(title: "Nodes", value: "\(model.snapshot?.nodes.count ?? 0)", systemImage: "server.rack", accent: .teal)
            MetricView(title: "GPU Nodes", value: "\(gpuNodeCount)", systemImage: "memorychip", accent: AIRETheme.gpu)
        }
    }

    private var gpuNodeCount: Int {
        model.snapshot?.nodes.filter { gpuTotal($0) > 0 }.count ?? 0
    }
}

// MARK: - Tab bar

/// Custom pill switcher in the glass language, replacing the stock TabView.
struct DashboardTabBar: View {
    @Binding var selection: DashboardTab
    @Namespace private var pillNamespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(DashboardTab.allCases) { tab in
                DashboardTabPill(tab: tab, isSelected: selection == tab, namespace: pillNamespace) {
                    withAnimation(AIRETheme.softSpring) {
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
                        .stroke(AIRETheme.border, lineWidth: 1)
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
                            .fill(AIRETheme.gpu.opacity(0.16))
                            .overlay {
                                Capsule()
                                    .stroke(AIRETheme.gpu.opacity(0.35), lineWidth: 1)
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
        .animation(AIRETheme.smoothEase, value: isHovered)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Hero empty state

/// First-run / logged-out hero shown instead of zeroed metrics, so
/// "not connected yet" can never be confused with "cluster is empty".
struct ConnectHeroView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 18) {
                AIRELogoMark(cornerRadius: 14)
                    .frame(width: 72, height: 72)

                VStack(spacing: 6) {
                    Text("Connect to AIRE")
                        .font(.title.weight(.semibold))
                    Text("Live Slurm monitoring for the University of Leeds AIRE cluster")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if model.isLoggingIn {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(model.loginProgress ?? "Connecting… check your phone for a Duo push")
                            .font(.callout.weight(.medium))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.12), in: Capsule())
                    .overlay(Capsule().stroke(Color.orange.opacity(0.25), lineWidth: 1))
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        HeroStep(
                            number: 1,
                            title: "Enter your password",
                            detail: "Use the sidebar on the left. Optionally remember it in the macOS Keychain."
                        )
                        HeroStep(
                            number: 2,
                            title: "Approve the Duo push",
                            detail: model.connectionRoute == .rashJump
                                ? "Two approvals on your phone — one for the jump host, one for AIRE."
                                : "One approval on your phone keeps the SSH session alive."
                        )
                        HeroStep(
                            number: 3,
                            title: "Watch the live dashboard",
                            detail: "Jobs, GPUs, nodes, and storage refresh automatically every \(model.refreshIntervalText)."
                        )
                    }
                    .frame(maxWidth: 440, alignment: .leading)
                }
            }
            .padding(28)
            .frame(maxWidth: 560)
            .dashboardCard(padding: 24, accent: AIRETheme.gpu)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(AIRETheme.smoothEase, value: model.isLoggingIn)
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
                .foregroundStyle(AIRETheme.gpu)
                .frame(width: 26, height: 26)
                .background(AIRETheme.gpu.opacity(0.14), in: Circle())
                .overlay(Circle().stroke(AIRETheme.gpu.opacity(0.28), lineWidth: 1))

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
