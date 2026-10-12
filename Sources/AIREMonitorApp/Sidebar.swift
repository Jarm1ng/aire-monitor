import SwiftUI

struct SidebarHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            AppLogoMark()
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 1) {
                Text("Leeds HPC Monitor")
                    .font(.headline.weight(.semibold))
                Text(ClusterCatalog.all.map(\.displayName).joined(separator: " · ") + " Slurm dashboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Sidebar: the cluster switcher first (overview plus one live row per
/// cluster), then one shared sign-in form — the same university account,
/// route and Duo choice serve every cluster — then notifications and the
/// selected cluster's session details.
struct ConnectionSidebar: View {
    @ObservedObject var model: AppModel
    @State private var showAdvanced = false

    var body: some View {
        // Scrolls so the form never clips at the 680pt minimum window height.
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SidebarHeader()
                clusterList
                loginProgressBanners
                connectionForm
                actions
                notificationsPanel
                sessionPanel
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.thinMaterial)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(AppTheme.border)
                .frame(width: 1)
        }
        .animation(AppTheme.smoothEase, value: model.isAnyLoginActive)
    }

    // MARK: Cluster switcher

    private var clusterList: some View {
        VStack(alignment: .leading, spacing: 6) {
            SidebarSelectableRow(isSelected: model.selection == .overview) {
                model.selection = .overview
            } content: {
                HStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Overview")
                            .font(.callout.weight(.semibold))
                        Text("All clusters side by side")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }

            ForEach(model.sessions) { session in
                ClusterSidebarRow(
                    session: session,
                    isSelected: model.selection == .cluster(session.id),
                    onSelect: { model.selection = .cluster(session.id) },
                    onConnect: { model.connect(session.id) }
                )
            }
        }
    }

    // MARK: Duo feedback

    @ViewBuilder
    private var loginProgressBanners: some View {
        ForEach(model.sessions.filter { $0.isLoggingIn || $0.isLoginQueued }) { session in
            LoginProgressBanner(session: session, route: model.connectionRoute)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: Form

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Sign in", subtitle: "One university account for every cluster")

            VStack(alignment: .leading, spacing: 6) {
                Picker("Connection route", selection: $model.connectionRoute) {
                    ForEach(ConnectionRoute.allCases) { route in
                        Text(route.shortTitle).tag(route)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Connection route")
                // Locked while any sign-in runs (so a route flip can't repoint
                // an in-flight ControlMaster). When merely connected it stays
                // switchable; the model re-probes every cluster on change.
                .disabled(model.isAnyLoginActive)

                Text(model.connectionRoute.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabeledContent("Username") {
                TextField("Username", text: $model.username)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("University username")
                    // Queued sign-ins send the password resolved for this
                    // account; editing it mid-chain must not be possible.
                    .disabled(model.isAnyLoginActive)
            }

            LabeledContent("Password") {
                SecureField("Password", text: $model.password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        // Mirror the Connect button's disabled state: a second
                        // Return during an in-flight sign-in must not queue a
                        // duplicate attempt.
                        guard !model.isAnyLoginActive else { return }
                        model.connectAll()
                    }
            }

            Toggle("Remember in Keychain", isOn: $model.rememberPassword)
                .toggleStyle(.checkbox)

            if model.hasSavedPassword {
                HStack(spacing: 8) {
                    Label("Saved password available", systemImage: "key.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Forget", role: .destructive) {
                        model.forgetSavedPassword()
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .help("Remove the saved university password from the macOS Keychain")
                }
            }

            if let warning = model.keychainWarning, !warning.isEmpty {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabeledContent("Duo option") {
                TextField("1", text: $model.duoOption)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .accessibilityLabel("Duo option number")
                    .disabled(model.isAnyLoginActive)
            }

            Label(duoRouteHint, systemImage: "person.badge.key")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup(isExpanded: $showAdvanced) {
                advancedFields
                    .padding(.top, 8)
            } label: {
                Label("Advanced", systemImage: "gearshape")
                    .font(.callout.weight(.medium))
            }
        }
        .font(.callout)
        .dashboardCard()
    }

    private var advancedFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose which clusters to monitor. Host names rarely need changing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(model.sessions) { session in
                ClusterAdvancedRow(session: session, isLocked: model.isAnyLoginActive)
            }

            LabeledContent("Jump host") {
                TextField("rash.leeds.ac.uk", text: $model.jumpHostname)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.connectionRoute != .rashJump || model.isAnyLoginActive)
            }

            LabeledContent("Project root") {
                TextField("Path to this project", text: $model.projectRoot)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                model.connectAll()
            } label: {
                HStack(spacing: 6) {
                    if model.isAnyLoginActive {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                    }
                    Text(model.isAnyLoginActive ? "Signing in" : model.connectAllTitle)
                }
            }
            .disabled(model.isAnyLoginActive || model.enabledSessions.isEmpty)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .help("Sign in to every enabled cluster, one Duo approval at a time")

            Button {
                model.refreshAll()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.enabledSessions.isEmpty)
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help("Refresh every enabled cluster now")

            Button {
                model.openDesktopWidget()
            } label: {
                Label("Widget", systemImage: "rectangle.on.rectangle.angled")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    // MARK: Notifications

    private var notificationsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Notifications", subtitle: "Local alerts from every cluster")

            Toggle("Notify when a GPU frees up", isOn: $model.notifyWhenGPUFrees)
                .toggleStyle(.checkbox)
            Text("Alerts once when a cluster goes from zero idle GPUs to at least one.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Label("Permission", systemImage: "bell.badge")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.notificationAuthorizationSummary)
                    .font(.caption.weight(.medium))
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .help("Job and GPU alerts use macOS notifications; manage access in System Settings > Notifications.")
        }
        .font(.callout)
        .dashboardCard()
    }

    // MARK: Session

    @ViewBuilder
    private var sessionPanel: some View {
        if let error = model.errorMessage, !error.isEmpty {
            ErrorBox(message: error)
        }
        if let session = model.selectedSession {
            ClusterSessionPanel(session: session)
        } else {
            ForEach(model.sessions.filter { $0.errorMessage?.isEmpty == false }) { session in
                VStack(alignment: .leading, spacing: 6) {
                    ClusterTitle(profile: session.profile, font: .callout.weight(.semibold))
                    ErrorBox(message: session.errorMessage ?? "")
                }
                .dashboardCard(accent: .red)
            }
        }
    }

    // MARK: Copy

    private var duoRouteHint: String {
        let clusters = model.enabledSessions.map(\.displayName)
        let list = clusters.isEmpty ? "each cluster" : clusters.joined(separator: " and ")
        if model.connectionRoute == .rashJump {
            let jump = model.jumpHostname.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Duo approvals: one for \(jump.isEmpty ? "the jump host" : jump) (reused while it stays open), then one each for \(list)."
        }
        return "Duo approvals: one each for \(list), sent one at a time."
    }
}

// MARK: - Rows and panels

/// Highlightable sidebar row with the app's glass selection treatment.
private struct SidebarSelectableRow<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.16) : (isHovered ? Color.primary.opacity(0.05) : .clear))
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                            }
                        }
                }
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(AppTheme.smoothEase, value: isHovered)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// One cluster in the sidebar: identity, live state, a one-line summary and
/// a Connect button when the cluster is not live.
private struct ClusterSidebarRow: View {
    @ObservedObject var session: ClusterSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onConnect: () -> Void

    var body: some View {
        SidebarSelectableRow(isSelected: isSelected, action: onSelect) {
            HStack(spacing: 10) {
                ClusterBadge(profile: session.profile, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.displayName)
                            .font(.callout.weight(.semibold))
                        ConnectionStatePill(state: session.connectionState)
                    }
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                if showsConnectButton {
                    Button("Connect", action: onConnect)
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .help("Sign in to \(session.displayName)")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.displayName), \(session.connectionState.label), \(summary)")
    }

    private var showsConnectButton: Bool {
        switch session.connectionState {
        case .notConnected, .cached:
            return true
        default:
            return false
        }
    }

    private var summary: String {
        guard session.isEnabled else {
            return "Monitoring off"
        }
        guard let snapshot = session.snapshot else {
            return session.settings.hostname
        }
        let running = snapshot.jobs.filter { SlurmState(parsing: $0.state) == .running }.count
        let pending = snapshot.jobs.filter { SlurmState(parsing: $0.state) == .pending }.count
        let gpus = session.gpuAvailability
        var parts = ["\(running) running", "\(pending) pending"]
        if gpus.total > 0 {
            parts.append("\(gpus.idle)/\(gpus.total) \(gpus.model ?? "GPU") free")
        }
        return parts.joined(separator: " · ")
    }
}

private struct ClusterAdvancedRow: View {
    @ObservedObject var session: ClusterSession
    let isLocked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $session.isEnabled) {
                ClusterTitle(profile: session.profile, font: .callout.weight(.medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(isLocked)

            LabeledContent("\(session.displayName) host") {
                TextField(session.profile.defaultHostname, text: $session.hostname)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!session.isEnabled || isLocked)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct LoginProgressBanner: View {
    @ObservedObject var session: ClusterSession
    let route: ConnectionRoute

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    ClusterBadge(profile: session.profile, size: 16)
                    Text(session.loginProgress ?? session.statusMessage)
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard(padding: 12, accent: .orange)
        .accessibilityElement(children: .combine)
    }

    private var hint: String {
        if session.isLoginQueued {
            return "\(session.displayName) signs in next — Duo pushes arrive one at a time."
        }
        if route == .rashJump {
            return "Check your phone: rash may ask first (unless already open), then \(session.displayName)."
        }
        return "Check your phone for the \(session.displayName) Duo push."
    }
}

/// Selected cluster's session status, pause control and last error.
private struct ClusterSessionPanel: View {
    @ObservedObject var session: ClusterSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(title: "\(session.displayName) session", subtitle: session.connectionState.label)
                Spacer(minLength: 8)
                if let snapshot = session.snapshot, !snapshot.collectedAt.isEmpty {
                    StalenessBadge(collectedAt: snapshot.collectedAt)
                }
            }
            HStack {
                Circle()
                    .fill(session.connectionState.color)
                    .frame(width: 8, height: 8)
                Text(session.isPaused ? session.pausedStatusText : session.statusMessage)
                    .lineLimit(3)
                    .font(.callout)
                    .foregroundStyle(session.isLoggedIn || session.hasCachedSnapshot ? .primary : .secondary)
            }

            Button {
                session.togglePause()
            } label: {
                Label(
                    session.isPaused ? "Resume" : "Pause monitoring",
                    systemImage: session.isPaused ? "play.fill" : "pause.fill"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(session.isLoggingIn || !session.isEnabled)
            .help(
                session.isPaused
                    ? "Resume background refreshes and fetch a fresh snapshot now"
                    : "Stop background refreshes; the last snapshot stays on screen"
            )

            if let warnings = session.snapshot?.warnings, !warnings.isEmpty {
                Label(warnings.joined(separator: "\n"), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Non-fatal collector warnings; the snapshot itself is fine")
            }

            if let error = session.errorMessage, !error.isEmpty {
                ErrorBox(message: error)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .dashboardCard(accent: session.connectionState.color)
        .animation(AppTheme.smoothEase, value: session.errorMessage)
    }
}

private struct ErrorBox: View {
    let message: String

    var body: some View {
        ScrollView {
            Text(message)
                .font(.caption.monospaced())
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 60, maxHeight: 180)
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.red.opacity(0.18), lineWidth: 1)
        )
    }
}
