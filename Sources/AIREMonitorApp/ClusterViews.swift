import HPCCore
import SwiftUI

/// Monogram disc in the cluster's identity color. Used wherever data from
/// several clusters could otherwise be confused.
struct ClusterBadge: View {
    let profile: ClusterProfile
    var size: CGFloat = 22

    var body: some View {
        Text(profile.monogram)
            .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(profile.accent.color.gradient, in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
            // The cluster name is printed beside the badge almost everywhere;
            // labelling the badge too makes VoiceOver say it twice.
            .accessibilityHidden(true)
    }
}

/// Compact "● Live" style pill for a cluster's connection state.
///
/// Prefer `init(presentation:)`: it shows the shared `ClusterPresentation`
/// wording ("Checking", "Loading"), so the pill agrees with the hero, the
/// sidebar row and the overview card. `init(state:)` remains for surfaces
/// that only have the coarse `ClusterConnectionState`.
struct ConnectionStatePill: View {
    private let label: String
    private let tint: Color
    private let isBusy: Bool
    private let isLive: Bool

    init(state: ClusterConnectionState) {
        label = state.label
        tint = state.color
        isBusy = state.isBusy
        isLive = state == .live
    }

    init(presentation: ClusterPresentation) {
        label = presentation.title
        tint = presentation.tint
        isBusy = presentation.showsProgress
        isLive = presentation.phase == .live
    }

    var body: some View {
        HStack(spacing: 5) {
            if isBusy {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
            }
            Text(label)
                .font(.caption2.weight(.semibold))
                // Full primary for Live; slightly softer otherwise, but well
                // above the 4.5:1 that plain `.secondary` misses on a tint.
                .foregroundStyle(isLive ? Color.primary : Color.primary.opacity(0.78))
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection: \(label)")
    }
}

/// "Calder" label with badge, for section headers that need cluster context.
struct ClusterTitle: View {
    let profile: ClusterProfile
    var font: Font = .headline

    var body: some View {
        HStack(spacing: 7) {
            ClusterBadge(profile: profile, size: 18)
            Text(profile.displayName)
                .font(font)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Confirmed session actions

/// What closing one cluster's ControlMaster would end right now: the
/// session itself (signing in again costs a Duo push) and everything
/// multiplexed over it — running terminal tabs and file transfers.
struct SessionWork: Equatable {
    let clusterID: ClusterID
    let clusterName: String
    var isLive = false
    var runningTerminals = 0
    /// Transfers waiting or running (`TransferItem.isActive`): every scp
    /// rides the same master, and a waiting one would start over a closed
    /// one and fail.
    var activeTransfers = 0

    /// Something besides the bare session would end with the master.
    var hasRunningWork: Bool { runningTerminals > 0 || activeTransfers > 0 }
}

/// A session action that would end live SSH work and so must be confirmed:
/// a reconnect (forced sign-in) replaces the cluster's ControlMaster, and
/// every shell, job-log tail, editor, `srun --pty` and file transfer
/// multiplexed over it dies with it; a disconnect closes it outright; a
/// route change closes every current master, since each route has its own.
///
/// A plain Connect never needs one: `AppModel.signIn(_:)` reuses a healthy
/// master (no teardown, no Duo push), so nothing running can close.
struct SessionActionConfirmation: Identifiable {
    enum Kind: Equatable {
        case reconnect
        case disconnect
        /// Switch the connection route to this one.
        case changeRoute(ConnectionRoute)
    }

    let id = UUID()
    let kind: Kind
    /// The clusters whose sessions the action ends, with what runs there.
    let work: [SessionWork]
    /// The route the clusters sign in over afterwards uses the rash jump
    /// host (one more Duo push if its session has closed).
    let usesJumpHost: Bool
    /// A disconnect that also closes the shared rash jump master, because
    /// no other cluster is live, signing in or queued through it
    /// (`AppModel.disconnectLeavesJumpHostUnused`): signing back in then
    /// needs a rash approval as well.
    var closesJumpHost = false

    var clusterIDs: [ClusterID] { work.map(\.clusterID) }
    var clusterNames: [String] { work.map(\.clusterName) }
    var runningTerminals: Int { work.reduce(0) { $0 + $1.runningTerminals } }
    var activeTransfers: Int { work.reduce(0) { $0 + $1.activeTransfers } }

    private var nameList: String {
        Self.join(clusterNames)
    }

    var title: String {
        switch kind {
        case .reconnect: return "Reconnect \(nameList)?"
        case .disconnect: return "Disconnect \(nameList)?"
        case .changeRoute(let route): return "Switch to the \(route.shortTitle) route?"
        }
    }

    var confirmTitle: String {
        switch kind {
        case .reconnect: return clusterNames.count > 1 ? "Reconnect \(clusterNames.count) clusters" : "Reconnect"
        case .disconnect: return "Disconnect"
        case .changeRoute: return "Switch route"
        }
    }

    /// Says exactly what the action costs: which sessions end (and the Duo
    /// pushes to get them back), then the terminals that close and the
    /// transfers that stop — named per cluster when several are involved.
    var message: String {
        var lines: [String] = []
        let many = clusterNames.count > 1
        switch kind {
        case .reconnect:
            var duo = many
                ? "Reconnecting replaces the SSH sessions to \(nameList) with fresh sign-ins: one Duo push each, sent one at a time"
                : "Reconnecting replaces the \(nameList) SSH session with a fresh sign-in: one Duo push"
            if usesJumpHost {
                duo += ", plus one for the rash jump host if its session has closed"
            }
            duo += "."
            // A forced sign-in tears the old master down BEFORE it
            // authenticates (hpc_start_target_master.zsh), so "replaces" is
            // not an atomic swap: a missed push loses the session. Said only
            // where there is a session (or work over its master) to lose.
            if work.contains(where: { $0.isLive || $0.hasRunningWork }) {
                duo += many
                    ? " Each old session closes first: a cluster whose push is missed or declined stays signed out."
                    : " The old session closes first: if the push is missed or declined, \(nameList) stays signed out."
            }
            lines.append(duo)
        case .disconnect:
            if closesJumpHost {
                lines.append(
                    "This ends the SSH session to \(nameList) and the rash jump host session, which no other cluster uses now. "
                        + "Signing in again needs two Duo approvals: one for rash, then one for \(nameList)."
                )
            } else {
                lines.append("This ends the SSH session to \(nameList). Signing in again needs a new Duo approval.")
            }
        case .changeRoute:
            var text = many
                ? "Each route has its own SSH sessions, so switching closes the sessions to \(nameList) now. Signing in again over the new route costs one Duo push each"
                : "Each route has its own SSH sessions, so switching closes the \(nameList) session now. Signing in again over the new route costs one Duo push"
            if usesJumpHost {
                text += ", plus one for the rash jump host if its session has closed"
            }
            lines.append(text + ".")
        }
        let terminals = runningTerminals
        if terminals > 0 {
            lines.append(
                "Open terminals there close: \(terminals) running session\(terminals == 1 ? "" : "s")\(breakdown(\.runningTerminals)), "
                    + "including whatever runs in \(terminals == 1 ? "it" : "them"), such as a shell, a job-log tail, "
                    + "unsaved edits or an srun allocation."
            )
        } else {
            lines.append("Open terminals there would close; none are running now.")
        }
        let transfers = activeTransfers
        if transfers > 0 {
            lines.append(
                "\(transfers == 1 ? "A file transfer" : "\(transfers) file transfers") there stop\(transfers == 1 ? "s" : "") unfinished\(breakdown(\.activeTransfers)); "
                    + "start \(transfers == 1 ? "it" : "them") again after signing in."
            )
        }
        return lines.joined(separator: "\n\n")
    }

    /// " (2 on AIRE, 1 on Calder)" when several clusters are named, so a
    /// total never stands without its parts; empty for a single cluster.
    private func breakdown(_ count: KeyPath<SessionWork, Int>) -> String {
        guard work.count > 1 else {
            return ""
        }
        let parts = work.filter { $0[keyPath: count] > 0 }.map { "\($0[keyPath: count]) on \($0.clusterName)" }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
    }

    static func join(_ names: [String]) -> String {
        switch names.count {
        case 0: return "no clusters"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
    }

    /// The sessions a route change would end without asking: enabled
    /// clusters that are live, or have a terminal or transfer running over
    /// their master (`ClusterSession.connectionSettingsDidChange` closes
    /// the previous route's master of every enabled cluster).
    static func endedByRouteChange(_ work: [SessionWork]) -> [SessionWork] {
        work.filter { $0.isLive || $0.hasRunningWork }
    }
}

@MainActor
extension AppModel {
    /// What closing each cluster's master would end now, in `ids` order.
    func sessionWork(on ids: [ClusterID]) -> [SessionWork] {
        ids.compactMap { session(for: $0) }.map { session in
            SessionWork(
                clusterID: session.id,
                clusterName: session.displayName,
                isLive: session.isLoggedIn,
                runningTerminals: runningTerminalCount(on: [session.id]),
                activeTransfers: session.files.activity.transfers.filter(\.isActive).count
            )
        }
    }

    /// The Connect buttons' action: a PLAIN sign-in (`signIn(_:)`) to every
    /// target that is not live yet, straight away and without a dialog — a
    /// plain sign-in reuses a healthy master, so even a cached cluster that
    /// still has terminals running over its master loses nothing.
    ///
    /// Returns a reconnect confirmation only when every target is already
    /// live: signing in to a live cluster can only mean replacing its
    /// session, which is never done without asking.
    func signInOrConfirm(_ ids: [ClusterID]) -> SessionActionConfirmation? {
        let targets = Self.signInTargets(ids.compactMap { session(for: $0) })
        guard !targets.isEmpty else {
            return nil
        }
        let notLive = targets.filter { !$0.isLoggedIn }
        guard notLive.isEmpty else {
            signIn(notLive.map(\.id))
            return nil
        }
        return reconnectConfirmation(targets.map(\.id))
    }

    /// The confirmation for a deliberate reconnect ("Reconnect…"): always
    /// asked, live or not, because a reconnect is a forced sign-in that
    /// replaces the master — one Duo push each, open terminals close and
    /// transfers stop. nil when no target can be reconnected (off, or
    /// already signing in).
    func reconnectConfirmation(_ ids: [ClusterID]) -> SessionActionConfirmation? {
        let targets = Self.signInTargets(ids.compactMap { session(for: $0) })
        guard !targets.isEmpty else {
            return nil
        }
        return SessionActionConfirmation(
            kind: .reconnect,
            work: sessionWork(on: targets.map(\.id)),
            usesJumpHost: connectionRoute == .rashJump
        )
    }

    /// Enabled clusters with no sign-in already running or queued.
    private static func signInTargets(_ sessions: [ClusterSession]) -> [ClusterSession] {
        sessions.filter { $0.isEnabled && !$0.isLoggingIn && !$0.isLoginQueued }
    }

    /// Disconnects straight away when only the session itself would end
    /// (the user asked for exactly that), otherwise returns the
    /// confirmation naming the terminals and transfers that would close.
    func disconnectOrConfirm(_ id: ClusterID) -> SessionActionConfirmation? {
        guard let confirmation = disconnectConfirmation(id) else {
            return nil
        }
        guard confirmation.work.contains(where: \.hasRunningWork) else {
            disconnect(id)
            return nil
        }
        return confirmation
    }

    /// What a disconnect of `id` would end now, worded for the dialog —
    /// including whether it closes the shared rash jump master too (the
    /// same rule `disconnect(_:)` applies). nil for an unknown cluster.
    func disconnectConfirmation(_ id: ClusterID) -> SessionActionConfirmation? {
        guard let session = session(for: id), let work = sessionWork(on: [id]).first else {
            return nil
        }
        return SessionActionConfirmation(
            kind: .disconnect,
            work: [work],
            usesJumpHost: connectionRoute == .rashJump,
            closesJumpHost: Self.disconnectLeavesJumpHostUnused(session, among: sessions)
        )
    }

    /// The route picker's setter. Each route has its own ControlMasters, so
    /// switching closes the current one of every enabled cluster: the
    /// switch happens at once only when that ends nothing — no live
    /// session, running terminal or transfer — and otherwise returns the
    /// confirmation naming what closes. Ignored while a sign-in runs (the
    /// picker is locked then, so a flip cannot repoint an in-flight
    /// master).
    func changeRouteOrConfirm(to route: ConnectionRoute) -> SessionActionConfirmation? {
        guard route != connectionRoute, !isAnyLoginActive else {
            return nil
        }
        let ended = SessionActionConfirmation.endedByRouteChange(sessionWork(on: enabledSessions.map(\.id)))
        guard !ended.isEmpty else {
            connectionRoute = route
            return nil
        }
        return SessionActionConfirmation(
            kind: .changeRoute(route),
            work: ended,
            usesJumpHost: route == .rashJump
        )
    }

    /// Runs a confirmed action. The only caller of the forced
    /// `reconnect(_:)` in the views: a replace always goes through a dialog.
    func perform(_ confirmation: SessionActionConfirmation) {
        switch confirmation.kind {
        case .reconnect:
            reconnect(confirmation.clusterIDs)
        case .disconnect:
            for id in confirmation.clusterIDs {
                disconnect(id)
            }
        case .changeRoute(let route):
            // A sign-in that started while the dialog was open keeps the
            // route it was queued with; the picker is locked meanwhile.
            guard !isAnyLoginActive else {
                return
            }
            connectionRoute = route
        }
    }
}

extension View {
    /// Presents a pending `SessionActionConfirmation` and runs it on
    /// confirmation. Every Connect/Reconnect/Disconnect entry point and the
    /// route picker route through this, so none of them can end a live
    /// session, a terminal or a transfer silently.
    func sessionActionConfirmation(_ pending: Binding<SessionActionConfirmation?>, model: AppModel) -> some View {
        confirmationDialog(
            pending.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { pending.wrappedValue != nil },
                set: { if !$0 { pending.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: pending.wrappedValue
        ) { confirmation in
            Button(confirmation.confirmTitle, role: .destructive) {
                model.perform(confirmation)
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
    }
}

/// The cluster's secondary session actions (pause, reconnect, disconnect,
/// turn off) in one "⋯" menu, so the dashboard header can offer them
/// without a row of buttons. Destructive ones go through the confirmation.
struct ClusterSessionMenu: View {
    let model: AppModel
    @ObservedObject var session: ClusterSession
    @Binding var confirmation: SessionActionConfirmation?

    var body: some View {
        let name = session.displayName
        let isSigningIn = session.isLoggingIn || session.isLoginQueued
        Menu {
            Button {
                session.togglePause()
            } label: {
                Label(session.isPaused ? "Resume monitoring" : "Pause monitoring", systemImage: session.isPaused ? "play.fill" : "pause.fill")
            }
            .disabled(isSigningIn || !session.isEnabled)

            Divider()

            Button {
                confirmation = model.reconnectConfirmation([session.id])
            } label: {
                Label("Reconnect \(name)…", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(isSigningIn || !session.isEnabled)
            .help("Replace the \(name) SSH session with a fresh sign-in (asks first: one Duo push; open terminals close and file transfers stop)")

            Button {
                confirmation = model.disconnectOrConfirm(session.id)
            } label: {
                Label("Disconnect \(name)…", systemImage: "bolt.horizontal.circle")
            }
            .disabled(isSigningIn || !session.isEnabled)
            .help("End the \(name) SSH session (asks first when terminals or file transfers would close)")

            Divider()

            Button {
                session.isEnabled = false
            } label: {
                Label("Turn off \(name) monitoring", systemImage: "power")
            }
            .disabled(isSigningIn || !session.isEnabled)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More \(name) session actions: pause, reconnect, disconnect")
        .accessibilityLabel("\(name) session actions")
    }
}
