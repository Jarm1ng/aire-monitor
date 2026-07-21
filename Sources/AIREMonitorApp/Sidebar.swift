import SwiftUI

struct SidebarHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            AIRELogoMark()
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 1) {
                Text("AIRE Monitor")
                    .font(.headline.weight(.semibold))
                Text("Slurm cluster dashboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Sidebar: sign-in first with a two-way route picker (direct VPN vs rash jump
/// host), hostname plumbing collapsed under Advanced, live Duo feedback while
/// logging in.
struct ConnectionSidebar: View {
    @ObservedObject var model: AppModel
    @State private var showAdvanced = false

    var body: some View {
        // Scrolls so the form never clips at the 680pt minimum window height
        // (Advanced expanded plus an error box exceeds the visible area).
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SidebarHeader()

                if model.isLoggingIn {
                    loginProgressBanner
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                connectionForm
                actions
                notificationsPanel
                statusPanel
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.thinMaterial)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(AIRETheme.border)
                .frame(width: 1)
        }
        .animation(AIRETheme.smoothEase, value: model.isLoggingIn)
    }

    // MARK: Duo feedback

    private var loginProgressBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.loginProgress ?? "Connecting…")
                    .font(.callout.weight(.semibold))
                Text(duoBannerHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard(padding: 12, accent: .orange)
        .accessibilityElement(children: .combine)
    }

    private var duoBannerHint: String {
        if model.connectionRoute == .rashJump {
            return "Check your phone for a Duo push — two approvals expected via the jump host."
        }
        return "Check your phone for a Duo push."
    }

    // MARK: Form

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Sign in", subtitle: "SSH and Duo authentication")

            VStack(alignment: .leading, spacing: 6) {
                Picker("Connection route", selection: $model.connectionRoute) {
                    ForEach(ConnectionRoute.allCases) { route in
                        Text(route.shortTitle).tag(route)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Connection route")
                // Only locked mid-login (so a route flip can't repoint the
                // in-flight ControlMaster). When merely connected it stays
                // switchable; the change is handled as a deliberate route
                // switch below rather than silently desyncing the session.
                .disabled(model.isLoggingIn)
                .onChange(of: model.connectionRoute) { _ in
                    model.handleRouteChange()
                }

                Text(model.connectionRoute.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabeledContent("Username") {
                TextField("Username", text: $model.username)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("University username")
            }

            LabeledContent("Password") {
                SecureField("Password", text: $model.password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        // Mirror the Login button's disabled state: a second
                        // Return during an in-flight login must not start a
                        // concurrent SSH attempt over the same ControlMaster.
                        guard !model.isLoggingIn else { return }
                        model.login()
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
                    .help("Remove the saved password from the macOS Keychain")
                }
            }

            if let warning = model.keychainWarning, !warning.isEmpty {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabeledContent(duoOptionLabel) {
                TextField("1", text: $model.duoOption)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .accessibilityLabel("Duo option number")
            }

            if model.connectionRoute == .rashJump {
                Label(duoRouteHint, systemImage: "person.2.badge.key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

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
            Text("Hostnames rarely need changing — the route above already selects direct vs jump.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("AIRE host") {
                TextField("aire.leeds.ac.uk", text: $model.aireHostname)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("Jump host") {
                TextField("rash.leeds.ac.uk", text: $model.jumpHostname)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.connectionRoute != .rashJump)
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
                model.login()
            } label: {
                HStack(spacing: 6) {
                    if model.isLoggingIn {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                    }
                    Text(model.isLoggingIn ? "Logging in" : "Login")
                }
            }
            .disabled(model.isLoggingIn || model.isRefreshing)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            Button {
                model.refresh()
            } label: {
                Label(model.isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoggingIn || model.isRefreshing)
            .buttonStyle(.bordered)
            .controlSize(.large)

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
            SectionTitle(title: "Notifications", subtitle: "Local alerts from the cluster")

            Toggle("Notify when a GPU frees up", isOn: $model.notifyWhenGPUFrees)
                .toggleStyle(.checkbox)
            Text("Alerts once when the fleet goes from zero idle GPUs to at least one.")
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

    // MARK: Status

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(title: "Session", subtitle: sessionSubtitle)
                Spacer(minLength: 8)
                if let snapshot = model.snapshot, !snapshot.collectedAt.isEmpty {
                    StalenessBadge(collectedAt: snapshot.collectedAt)
                }
            }
            HStack {
                Circle()
                    .fill(sessionColor)
                    .frame(width: 8, height: 8)
                Text(model.isPaused ? model.pausedStatusText : model.statusMessage)
                    .lineLimit(3)
                    .font(.callout)
                    .foregroundStyle(model.isLoggedIn || model.hasCachedSnapshot ? .primary : .secondary)
            }

            Button {
                model.togglePause()
            } label: {
                Label(
                    model.isPaused ? "Resume" : "Pause monitoring",
                    systemImage: model.isPaused ? "play.fill" : "pause.fill"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isLoggingIn)
            .help(
                model.isPaused
                    ? "Resume background refreshes and fetch a fresh snapshot now"
                    : "Stop background refreshes; the last snapshot stays on screen"
            )

            if let error = model.errorMessage, !error.isEmpty {
                ScrollView {
                    Text(error)
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 90, maxHeight: 180)
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.red.opacity(0.18), lineWidth: 1)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .dashboardCard(accent: sessionColor)
        .animation(AIRETheme.smoothEase, value: model.errorMessage)
        .animation(AIRETheme.softSpring, value: sessionSubtitle)
    }

    // MARK: Copy

    private var duoOptionLabel: String {
        model.connectionRoute == .rashJump ? "Duo option for both prompts" : "Duo option"
    }

    private var duoRouteHint: String {
        let jump = model.jumpHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let aire = model.aireHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Expect two Duo approvals: \(jump.isEmpty ? "jump host" : jump), then \(aire.isEmpty ? "AIRE" : aire)."
    }

    private var sessionSubtitle: String {
        if model.isPaused {
            return "Paused"
        }
        if model.isLoggedIn {
            return "Connected"
        }
        if model.hasCachedSnapshot {
            return "Cached / offline"
        }
        return "Not connected"
    }

    private var sessionColor: Color {
        if model.isPaused {
            return .orange
        }
        if model.isLoggedIn {
            return .green
        }
        if model.hasCachedSnapshot {
            return .orange
        }
        return .gray
    }
}
