import HPCCore
import SwiftUI

/// The sidebar's "Sessions" card: how long each SSH session has been up
/// (so a renewal before a long unattended stretch is an informed choice),
/// Renew all, what a drop did, and how the sessions are shared with
/// Terminal and Claude sessions.
struct SessionsCard: View {
    @ObservedObject var model: AppModel
    @Binding var confirmation: SessionActionConfirmation?
    @State private var showsSharingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(title: "Sessions", subtitle: "Time since each sign-in")
                Spacer(minLength: 8)
                Button("Renew all…") {
                    confirmation = model.renewConfirmation()
                }
                .controlSize(.small)
                .disabled(model.isAnyLoginActive || model.enabledSessions.isEmpty)
                .help("Sign in to every session again from scratch, so each starts a fresh clock — e.g. before leaving jobs running overnight. One Duo push per session; asks first.")
            }

            // Ages tick by themselves; passes refresh the start times.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows(now: context.date)) { row in
                        SessionAgeRow(row: row)
                    }
                }
            }

            Divider()

            Toggle("Share with Terminal and Claude sessions", isOn: $model.shareSessions)
                .toggleStyle(.checkbox)
                .help("Link the live sessions into ~/.ssh so `ssh aire`, `ssh calder`, `ssh rash`, scp and rsync — in Terminal or a Claude session — ride the app's sign-in with no password or Duo.")
            if model.shareSessions {
                sharingSummary
            }

            Toggle("Sign in again after a drop", isOn: $model.reconnectAutomatically)
                .toggleStyle(.checkbox)
                .help("When sleep, a network change or the VPN ends a session, sign in again with the saved password — only while you are at the Mac, at most three tries, and never again after a Duo push is declined or missed.")
            Text(reconnectFootnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .dashboardCard()
    }

    // MARK: Rows

    struct Row: Identifiable {
        enum Tone {
            case live
            case aging
            case dropped
            case idle
        }
        let id: String
        let name: String
        let detail: String
        let tone: Tone
        let help: String
    }

    private func rows(now: Date) -> [Row] {
        var rows: [Row] = []
        let report = model.sharingReport
        let clusterNames = Set(model.sessions.map(\.id.rawValue))
        // The shared jump master first: every tunnelled cluster rides it.
        for status in report.sessions where !clusterNames.contains(status.name) {
            rows.append(liveRow(id: status.name, name: status.displayName, since: status.since, now: now, jump: true))
        }
        for session in model.enabledSessions {
            if let status = report.session(named: session.id.rawValue), session.isLoggedIn {
                rows.append(liveRow(id: status.name, name: session.displayName, since: status.since, now: now, jump: false))
            } else {
                rows.append(notLiveRow(session, now: now))
            }
        }
        return rows
    }

    private func liveRow(id: String, name: String, since: Date?, now: Date, jump: Bool) -> Row {
        guard let since else {
            return Row(id: id, name: name, detail: "Live", tone: .live, help: "Live; its start time is unknown.")
        }
        let age = now.timeIntervalSince(since)
        let aging = age >= SessionAge.renewSuggestedAfter
        let started = since.formatted(date: .omitted, time: .shortened)
        return Row(
            id: id,
            name: name,
            detail: "up \(SessionAge.text(age))" + (aging ? " — renew soon" : ""),
            tone: aging ? .aging : .live,
            help: (jump ? "The shared rash jump session, signed in at \(started)." : "Signed in at \(started).")
                + (aging ? " Sessions have ended about 12 h after the VPN session began; Renew all starts every clock over." : "")
        )
    }

    private func notLiveRow(_ session: ClusterSession, now: Date) -> Row {
        let name = session.displayName
        guard let drop = model.lastDrops[session.id], !session.isLoggedIn else {
            let detail = session.isLoggingIn || session.isLoginQueued ? "signing in…" : "not signed in"
            return Row(id: session.id.rawValue, name: name, detail: detail, tone: .idle, help: "")
        }
        let when = drop.at.formatted(date: .omitted, time: .shortened)
        let lasted = drop.lasted.map { " after \(SessionAge.text($0))" } ?? ""
        let next: String
        switch model.autoReconnect.state(of: session.id) {
        case .attempting?:
            next = "signing in again"
        case .pending?:
            next = model.reconnectAutomatically ? "signs in again when you're back" : "sign in to continue"
        case .suspended?:
            next = "sign in to continue"
        case nil:
            next = session.isLoggingIn || session.isLoginQueued ? "signing in…" : "sign in to continue"
        }
        return Row(
            id: session.id.rawValue,
            name: name,
            detail: "dropped \(when)\(lasted) · \(next)",
            tone: .dropped,
            help: "The \(name) session ended on its own at \(when)\(lasted) (sleep, a network change or the VPN ending)."
        )
    }

    // MARK: Sharing

    @ViewBuilder
    private var sharingSummary: some View {
        let report = model.sharingReport
        let linked = report.aliases.filter { $0.state == .linked }.map(\.alias)
        let held = report.aliases.filter {
            if case .heldByOtherSession = $0.state { return true }
            return false
        }
        VStack(alignment: .leading, spacing: 4) {
            if report.sessions.isEmpty {
                Text("Nothing to share until a session is live.")
            } else if linked.isEmpty {
                Text("No ~/.ssh/config alias matches yet; use `hpc-session run <name> -- <command>` or `ssh -S ~/.ssh/ctl/<name>.sock <host>`.")
            } else {
                Text(linked.map { "ssh \($0)" }.joined(separator: " · "))
                    .textSelection(.enabled)
            }
            if !held.isEmpty {
                Text("\(held.map(\.alias).joined(separator: ", ")): your own session holds \(held.count == 1 ? "it" : "them") — linked once \(held.count == 1 ? "it ends" : "they end").")
            }
            DisclosureGroup(isExpanded: $showsSharingDetails) {
                sharingDetails
                    .padding(.top, 4)
            } label: {
                Text("Details")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var sharingDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.sharingReport.sessions) { status in
                if let link = status.stableLinkPath {
                    Text("\(status.displayName): \((link as NSString).abbreviatingWithTildeInPath)")
                        .textSelection(.enabled)
                }
            }
            ForEach(model.sharingReport.aliases) { alias in
                Text("ssh \(alias.alias): \(Self.describe(alias.state))")
            }
            Text("Claude sessions: `scripts/hpc-session status`, `wait <name>`, `run <name> -- <command>` never prompt and wait out a drop instead of failing. `ssh -O exit <alias>` would close the app's session too.")
        }
    }

    static func describe(_ state: SharedAliasStatus.State) -> String {
        switch state {
        case .linked:
            return "rides the app's session"
        case .heldByOtherSession(let since):
            let age = since.map { ", up \(SessionAge.text(Date().timeIntervalSince($0)))" } ?? ""
            return "your own session\(age); left alone"
        case .noControlPath:
            return "no ControlPath in ~/.ssh/config, so it cannot share"
        case .failed(let reason):
            return reason
        }
    }

    private var reconnectFootnote: String {
        guard model.reconnectAutomatically else {
            return "A dropped session waits for you to press Connect."
        }
        guard model.rememberPassword && model.hasSavedPassword && !model.savedPasswordRejected else {
            return "Needs a password saved in Keychain; until then a dropped session waits for Connect."
        }
        return "Uses the saved password while you're at the Mac; approve the Duo push on your phone."
    }
}

private struct SessionAgeRow: View {
    let row: SessionsCard.Row

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(row.name)
                .font(.callout.weight(.medium))
                .frame(minWidth: 52, alignment: .leading)
            Text(row.detail)
                .font(.caption.monospacedDigit())
                .foregroundStyle(row.tone == .aging || row.tone == .dropped ? color : .secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .help(row.help)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch row.tone {
        case .live: return .green
        case .aging: return .orange
        case .dropped: return .red
        case .idle: return .gray
        }
    }
}
