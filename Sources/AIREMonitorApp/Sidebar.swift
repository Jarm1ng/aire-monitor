import HPCCore
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
/// cluster), then sign-in progress and the selected cluster's session —
/// what changes and what can go wrong sit high, above the fold of the
/// minimum window — then one shared sign-in form (the same university
/// account, route and Duo choice serve every cluster), collapsed to one
/// line once everything is connected, and notifications.
struct ConnectionSidebar: View {
    @ObservedObject var model: AppModel
    @State private var showAdvanced = false
    /// The user asked to see the full form although every cluster is live
    /// (to change the route, the account or a host).
    @State private var showsFullForm = false
    @State private var confirmation: SessionActionConfirmation?

    var body: some View {
        // Scrolls so the form never clips at the 680pt minimum window height.
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SidebarHeader()
                clusterList
                loginProgressBanners
                sessionPanel
                signInCard
                actions
                notificationsPanel
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
        .animation(AppTheme.smoothEase, value: isEverythingLive)
        .animation(AppTheme.smoothEase, value: model.offerToForgetSavedPassword)
        .sessionActionConfirmation($confirmation, model: model)
    }

    /// Every enabled cluster is signed in and no sign-in is running: the
    /// form has nothing left to do and shrinks to a one-line summary.
    private var isEverythingLive: Bool {
        let enabled = model.enabledSessions
        return !enabled.isEmpty && enabled.allSatisfy(\.isLoggedIn) && !model.isAnyLoginActive
    }

    /// Clusters the primary button signs in to: not live, not signing in,
    /// and not in the middle of the startup probe — a probe may be about to
    /// confirm a live master, and a forced sign-in would tear it down.
    private var connectTargets: [ClusterSession] {
        model.sessionsNeedingSignIn.filter { $0.presentation.primaryAction == .connect }
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
            .help("Overview (⌘0)")

            ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                ClusterSidebarRow(
                    session: session,
                    isSelected: model.selection == .cluster(session.id),
                    shortcutHint: index < 9 ? "⌘\(index + 1)" : nil,
                    onSelect: { model.selection = .cluster(session.id) },
                    onConnect: { confirmation = model.signInOrConfirm([session.id]) }
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

    // MARK: Session

    @ViewBuilder
    private var sessionPanel: some View {
        if let error = model.errorMessage, !error.isEmpty {
            // App-level problems (project root, widget, sign-in input)
            // stay until fixed or dismissed; they are not tied to a cluster.
            ErrorBox(message: error, onDismiss: { model.dismissError() })
        }
        if let session = model.selectedSession {
            ClusterSessionPanel(model: model, session: session, confirmation: $confirmation)
        } else {
            ForEach(model.sessions.filter { $0.isEnabled && $0.errorMessage?.isEmpty == false }) { session in
                VStack(alignment: .leading, spacing: 6) {
                    ClusterTitle(profile: session.profile, font: .callout.weight(.semibold))
                    ErrorBox(message: session.errorMessage ?? "")
                }
                .dashboardCard(accent: .red)
            }
        }
    }

    // MARK: Sign-in card

    @ViewBuilder
    private var signInCard: some View {
        if isEverythingLive && !showsFullForm {
            signedInSummary
                .transition(.opacity)
        } else {
            connectionForm
                .transition(.opacity)
        }
    }

    /// One line once every cluster is connected: the full form (with an
    /// empty password field) would otherwise fill a third of the sidebar
    /// and push the session details below the fold.
    private var signedInSummary: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.title3)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Signed in as \(model.username.trimmingCharacters(in: .whitespacesAndNewlines))")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.connectionRoute.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button("Change…") {
                showsFullForm = true
            }
            .controlSize(.small)
            .help("Show the sign-in form: route, account, Duo option and hosts")
        }
        .dashboardCard()
        .accessibilityElement(children: .contain)
    }

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(title: "Sign in", subtitle: "One university account for every cluster")
                Spacer(minLength: 8)
                if isEverythingLive {
                    Button("Done") {
                        showsFullForm = false
                    }
                    .controlSize(.small)
                    .help("Collapse the sign-in form")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker("Connection route", selection: routeSelection) {
                    ForEach(ConnectionRoute.allCases) { route in
                        Text(route.shortTitle).tag(route)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Connection route")
                // Locked while any sign-in runs (so a route flip can't repoint
                // an in-flight ControlMaster). Otherwise switchable, but each
                // route has its own masters: a switch closes the current ones
                // and re-probes under the new route, so it asks first whenever
                // that would end a live session, a terminal or a transfer.
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
                        // Mirror the Connect button: a second Return during an
                        // in-flight sign-in must not queue a duplicate, and
                        // Return never touches a live (or still-probing)
                        // cluster — only the ones the button would sign in.
                        // A plain sign-in: a healthy master found on the
                        // way is reused, never replaced.
                        let targets = connectTargets
                        guard !model.isAnyLoginActive, !targets.isEmpty else { return }
                        model.signIn(targets.map(\.id))
                    }
            }

            Toggle("Remember in Keychain", isOn: $model.rememberPassword)
                .toggleStyle(.checkbox)

            if model.offerToForgetSavedPassword {
                forgetSavedPasswordPrompt
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if model.hasSavedPassword {
                HStack(spacing: 8) {
                    savedPasswordStatus
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

            if let pending = pendingSignInChangesText {
                Label(pending, systemImage: "arrow.uturn.forward.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// The picker never writes the route straight to the model: switching
    /// closes every current master, so `changeRouteOrConfirm` either
    /// switches at once (nothing would end) or hands back the dialog. Until
    /// it is confirmed the picker keeps showing the current route.
    private var routeSelection: Binding<ConnectionRoute> {
        Binding(
            get: { model.connectionRoute },
            set: { route in
                confirmation = model.changeRouteOrConfirm(to: route)
            }
        )
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
                TextField(HPCDefaults.jumpHostname, text: $model.jumpHostname)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.connectionRoute != .rashJump || model.isAnyLoginActive)
            }

            LabeledContent("Project root") {
                TextField("Path to this project", text: $model.projectRoot)
                    .textFieldStyle(.roundedBorder)
                    // Return applies at once; otherwise the model applies
                    // it after a pause in typing, never half-typed.
                    .onSubmit { model.commitProjectRoot(model.projectRoot) }
                    // Queued sign-ins run the scripts under this root.
                    .disabled(model.isAnyLoginActive)
                    .help("The checkout of this app (it holds the scripts). Press Return to apply.")
            }
        }
    }

    // MARK: Actions

    /// Primary action (Connect / Cancel sign-in; absent when everything is
    /// live), then Refresh, Widget and the secondary "Reconnect…" menu. The
    /// controls are regular-size and never truncate; when the sidebar is
    /// too narrow for one row they wrap onto two.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                primaryAction
                secondaryActions
            }
            VStack(alignment: .leading, spacing: 8) {
                primaryAction
                HStack(spacing: 8) {
                    secondaryActions
                }
            }
        }
        .controlSize(.regular)
    }

    @ViewBuilder
    private var primaryAction: some View {
        if model.isAnyLoginActive {
            Button(role: .cancel) {
                model.cancelLogins()
            } label: {
                Label("Cancel sign-in", systemImage: "xmark.circle")
                    .lineLimit(1)
                    .fixedSize()
            }
            .buttonStyle(.bordered)
            .help("Stop the running sign-in and every queued one")
        } else if let first = connectTargets.first {
            let targets = connectTargets
            Button {
                // Plain sign-in (reuses a healthy master): no confirmation
                // needed, nothing running can close.
                model.signIn(targets.map(\.id))
            } label: {
                Label(
                    targets.count > 1 ? "Connect all" : "Connect \(first.displayName)",
                    systemImage: "person.crop.circle.badge.checkmark"
                )
                .lineLimit(1)
                .fixedSize()
            }
            // No .defaultAction shortcut: a stray Return (focus on a table,
            // or on nothing after switching tabs) must never start sign-ins.
            .buttonStyle(.borderedProminent)
            .help("Sign in to \(SessionActionConfirmation.join(targets.map(\.displayName))), one Duo approval at a time; a session that is still open is reused without one. Live clusters are never touched.")
        }
    }

    @ViewBuilder
    private var secondaryActions: some View {
        Button {
            model.refreshAll()
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
                .lineLimit(1)
                .fixedSize()
        }
        .disabled(model.enabledSessions.isEmpty)
        .buttonStyle(.bordered)
        .help("Refresh every connected cluster now")

        Button {
            model.openDesktopWidget()
        } label: {
            HStack(spacing: 6) {
                if model.isPreparingDesktopWidget {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "rectangle.on.rectangle.angled")
                }
                Text("Widget")
            }
            .lineLimit(1)
            .fixedSize()
        }
        .buttonStyle(.bordered)
        .disabled(model.isPreparingDesktopWidget)
        .help(model.isPreparingDesktopWidget ? "Building and opening the desktop widget…" : "Open the desktop widget")

        reconnectMenu
    }

    /// Deliberate re-authentication, kept off the primary button and always
    /// confirmed (`reconnectConfirmation`): it is a forced sign-in that
    /// replaces the cluster's ControlMaster, closing every terminal and
    /// stopping every transfer there, and costs a Duo push per cluster.
    @ViewBuilder
    private var reconnectMenu: some View {
        // Live sessions (or ones with terminals still open): the others are
        // signed in with Connect, which never needs a confirmation.
        let candidates = model.enabledSessions.filter {
            !$0.isLoggingIn && !$0.isLoginQueued && ($0.isLoggedIn || !$0.terminals.sessions.isEmpty)
        }
        if !candidates.isEmpty {
            Menu {
                ForEach(candidates) { session in
                    Button("Reconnect \(session.displayName)…") {
                        confirmation = model.reconnectConfirmation([session.id])
                    }
                }
                if candidates.count > 1 {
                    Divider()
                    Button("Reconnect all…") {
                        confirmation = model.reconnectConfirmation(candidates.map(\.id))
                    }
                }
            } label: {
                Text("Reconnect…")
                    .lineLimit(1)
                    .fixedSize()
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .fixedSize()
            .disabled(model.isAnyLoginActive)
            .help("Replace a cluster's SSH session with a fresh sign-in (asks first: one Duo push each; open terminals close and file transfers stop)")
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

            // Without permission every alert is dropped silently; offer the
            // one step that fixes it (ask, or open System Settings).
            if let action = model.notificationPermissionAction {
                Button(action.title) {
                    model.performNotificationPermissionAction()
                }
                .controlSize(.small)
                .help(action == .request
                    ? "Ask macOS for permission to show job and GPU alerts"
                    : "Notifications are turned off for this app; allow them in System Settings > Notifications")
            }
        }
        .font(.callout)
        .dashboardCard()
    }

    // MARK: Saved password

    /// Asked right after "Remember in Keychain" is switched off while a
    /// password is saved: unticking alone deletes nothing, so the opt-out
    /// would otherwise leave the old password in the Keychain unnoticed.
    private var forgetSavedPasswordPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Also remove the saved password from the Keychain?")
                .font(.caption.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Remove", role: .destructive) {
                    model.forgetSavedPassword()
                }
                Button("Keep") {
                    model.dismissForgetSavedPasswordOffer()
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// What an empty password field will do: use the saved password, or
    /// not, because the cluster rejected it last time.
    @ViewBuilder
    private var savedPasswordStatus: some View {
        if model.savedPasswordRejected {
            Label("Saved password was rejected — type the current one", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(StatusTone.warning.color)
                .fixedSize(horizontal: false, vertical: true)
                .help("The cluster refused the saved password last time, so it is not sent again until a typed password works or you forget it.")
        } else {
            Label(
                model.savedPasswordWillBeUsed ? "Saved password is used when the field is empty" : "Saved password available",
                systemImage: "key.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Copy

    /// Edits to the account, jump host or a host never re-target a live
    /// session; say so instead of letting them look ignored. (A route
    /// change is different: it closes the current masters, after asking.)
    private var pendingSignInChangesText: String? {
        let pending = model.sessions.filter { $0.isEnabled && $0.signInChangesPending }
        guard !pending.isEmpty else {
            return nil
        }
        let names = SessionActionConfirmation.join(pending.map(\.displayName))
        return "Changes apply at the next sign-in to \(names); the live session keeps its current settings until then (Reconnect… to apply now)."
    }

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

/// One cluster in the sidebar: identity, state, a one-line summary and the
/// one action its state calls for (Connect, Turn on or Resume) — all from
/// the shared `ClusterPresentation`, so the row never offers Connect while
/// the startup probe is still checking for a live session.
private struct ClusterSidebarRow: View {
    @ObservedObject var session: ClusterSession
    let isSelected: Bool
    let shortcutHint: String?
    let onSelect: () -> Void
    let onConnect: () -> Void

    var body: some View {
        let presentation = session.presentation
        let summary = summary(presentation)

        SidebarSelectableRow(isSelected: isSelected, action: onSelect) {
            HStack(spacing: 10) {
                ClusterBadge(profile: session.profile, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.displayName)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        ConnectionStatePill(presentation: presentation)
                    }
                    ForEach(Array(summary.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                // Before the spacer: sharing the leftover width with it
                // squeezed "Calder" to one letter per line next to a
                // "Not connected" pill and a Connect button.
                .layoutPriority(1)
                Spacer(minLength: 4)
                if let action = presentation.primaryAction {
                    actionButton(action)
                }
            }
        }
        .help(rowHelp(summary: summary.lines.joined(separator: "\n")))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.displayName), \(presentation.title), \(summary.spoken)")
    }

    @ViewBuilder
    private func actionButton(_ action: ClusterPresentation.Action) -> some View {
        switch action {
        case .connect:
            Button("Connect", action: onConnect)
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help("Sign in to \(session.displayName)")
        case .turnOn:
            Button("Turn on") {
                session.isEnabled = true
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .help("Start monitoring \(session.displayName)")
        case .resume:
            Button("Resume") {
                session.togglePause()
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .help("Resume background refreshes for \(session.displayName)")
        }
    }

    /// The queue and idle GPUs while there is data (`ClusterSidebarSummary`);
    /// otherwise what the state means, never zeros.
    private func summary(_ presentation: ClusterPresentation) -> ClusterSidebarSummary {
        switch presentation.phase {
        case .off:
            return ClusterSidebarSummary(text: "Monitoring off")
        case .signingIn:
            return ClusterSidebarSummary(text: "Signing in…")
        case .queued:
            return ClusterSidebarSummary(text: "Waiting for the previous sign-in")
        case .loadingFirstSnapshot:
            return ClusterSidebarSummary(text: "Collecting the first snapshot…")
        case .notConnected:
            return ClusterSidebarSummary(text: session.settings.hostname)
        case .checking where session.snapshot == nil:
            return ClusterSidebarSummary(text: "Checking for an open session…")
        default:
            break
        }
        guard let snapshot = session.snapshot else {
            return ClusterSidebarSummary(text: session.settings.hostname)
        }
        return ClusterSidebarSummary(jobs: snapshot.jobs, fleet: session.gpuFleet)
    }

    private func rowHelp(summary: String) -> String {
        var lines = [shortcutHint.map { "\(session.displayName) (\($0))" } ?? session.displayName]
        if session.isEnabled, let snapshot = session.snapshot {
            lines.append(JobQueueCounts(jobs: snapshot.jobs).summary)
            lines.append(contentsOf: session.gpuFleet.pools.map(\.idleFigureSummary))
        } else {
            lines.append(summary)
        }
        return lines.joined(separator: "\n")
    }
}

/// What a cluster's sidebar row says under its name. While there is data:
/// the queue on one line — "9 running · 1 pending · 11 held", the
/// overview's `JobQueueCounts` wording, so a held job is never counted as
/// pending — and idle GPUs on the next — "0 of 56 H200 idle · +1 more
/// model" (`GPUFleet.primaryIdleText`). Two lines, because one would cut
/// the GPU phrase off at the sidebar's width.
struct ClusterSidebarSummary: Equatable {
    let lines: [String]
    /// The same for VoiceOver: no "?" or "+" to read out.
    let spoken: String

    /// A state with no figures ("Signing in…", the host name).
    init(text: String) {
        lines = [text]
        spoken = text
    }

    init(jobs: [Job], fleet: GPUFleet) {
        let queue = JobQueueCounts(jobs: jobs).summary
        var lines = [queue]
        var spoken = [queue.replacingOccurrences(of: " · ", with: ", ")]
        if let gpus = fleet.primaryIdleText {
            lines.append(gpus)
        }
        if let gpus = fleet.primaryIdleSpokenText {
            spoken.append(gpus)
        }
        self.lines = lines
        self.spoken = spoken.joined(separator: "; ")
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

/// One sign-in in progress (or queued), with its own Cancel: a missed or
/// declined Duo push must not lock the form for minutes.
private struct LoginProgressBanner: View {
    @ObservedObject var session: ClusterSession
    let route: ConnectionRoute

    var body: some View {
        let presentation = session.presentation
        HStack(alignment: .top, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    ClusterBadge(profile: session.profile, size: 16)
                    Text("\(session.displayName): \(presentation.detail)")
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            Button("Cancel", role: .cancel) {
                session.cancelLogin()
            }
            .controlSize(.small)
            .help(ClusterStatusContent.cancelSignInHelp(clusterName: session.displayName, isQueued: session.isLoginQueued))
            .accessibilityLabel("Cancel \(session.displayName) sign-in")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard(padding: 12, accent: .orange)
    }

    private var hint: String {
        if session.isLoginQueued {
            return "Duo pushes arrive one at a time; this one follows the current sign-in."
        }
        if route == .rashJump {
            return "Check your phone: rash may ask first (unless already open), then \(session.displayName)."
        }
        return "Check your phone for the \(session.displayName) Duo push."
    }
}

/// Selected cluster's session status, pause, reconnect/disconnect and the
/// last error. Sits right under the cluster list so it is visible at the
/// minimum window height.
private struct ClusterSessionPanel: View {
    let model: AppModel
    @ObservedObject var session: ClusterSession
    @Binding var confirmation: SessionActionConfirmation?

    var body: some View {
        let presentation = session.presentation
        let isSigningIn = session.isLoggingIn || session.isLoginQueued

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(title: "\(session.displayName) session", subtitle: presentation.title)
                Spacer(minLength: 8)
                if session.isEnabled, let snapshot = session.snapshot, !snapshot.collectedAt.isEmpty {
                    StalenessBadge(collectedAt: snapshot.collectedAt)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Circle()
                    .fill(presentation.tint)
                    .frame(width: 8, height: 8)
                Text(session.isPaused ? session.pausedStatusText : session.statusMessage)
                    .lineLimit(3)
                    .font(.callout)
                    .foregroundStyle(session.isLoggedIn || session.hasCachedSnapshot ? .primary : .secondary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                Button {
                    session.togglePause()
                } label: {
                    Label(
                        session.isPaused ? "Resume" : "Pause",
                        systemImage: session.isPaused ? "play.fill" : "pause.fill"
                    )
                    .lineLimit(1)
                    .fixedSize()
                }
                .help(
                    session.isPaused
                        ? "Resume background refreshes and fetch a fresh snapshot now"
                        : "Stop background refreshes; the last snapshot stays on screen"
                )

                Button {
                    confirmation = model.reconnectConfirmation([session.id])
                } label: {
                    Text("Reconnect…")
                        .lineLimit(1)
                        .fixedSize()
                }
                .help("Replace the \(session.displayName) SSH session with a fresh sign-in (asks first: one Duo push; open terminals close and file transfers stop)")

                Button {
                    confirmation = model.disconnectOrConfirm(session.id)
                } label: {
                    Text("Disconnect")
                        .lineLimit(1)
                        .fixedSize()
                }
                .help("End the \(session.displayName) SSH session (asks first when terminals or file transfers would close)")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isSigningIn || !session.isEnabled)

            if let warnings = session.snapshot?.warnings, !warnings.isEmpty {
                Label(warnings.joined(separator: "\n"), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Non-fatal collector warnings; the snapshot itself is fine")
            }

            if let error = session.errorMessage, !error.isEmpty {
                ErrorBox(message: error)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .dashboardCard(accent: presentation.tint)
        .animation(AppTheme.smoothEase, value: session.errorMessage)
    }
}

private struct ErrorBox: View {
    let message: String
    /// Shows a close button when set.
    var onDismiss: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            Text(message)
                .font(.caption.monospaced())
                .foregroundStyle(Color.red.legibleText(in: colorScheme))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, onDismiss == nil ? 0 : 18)
        }
        .frame(minHeight: 60, maxHeight: 180)
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.red.opacity(0.18), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("Dismiss")
                .accessibilityLabel("Dismiss error")
            }
        }
    }
}
