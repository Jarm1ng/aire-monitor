import HPCCore
import SwiftUI

// The status strip under a cluster's header: what is wrong (or merely
// different) about this cluster right now. Before it existed the cluster
// tab showed none of this — errors lived only in a sidebar panel below the
// fold, automatic refresh failures were invisible, and a failed ⌘R just
// flipped the button for half a second.
//
// The wording is decided by `ClusterStatusContent.make(_:)` from plain
// values, so every state is unit-testable and previewable without a
// session that has really failed.

// MARK: - Content

/// What the strip says and offers. nil from `make` means "nothing to say":
/// a healthy live cluster shows no strip at all.
struct ClusterStatusContent: Equatable {
    enum Action: Hashable {
        case connect
        case resume
        case pause
        case cancelSignIn
    }

    let tone: StatusTone
    let systemImage: String
    let showsProgress: Bool
    /// The headline, e.g. the failure's one-line message.
    let text: String
    /// One quieter line: what it means and what (not) to do about it.
    var hint: String?
    /// Full text behind the Details disclosure; nil hides the button.
    var details: String?
    var actions: [Action] = []
    /// Tooltip of the Cancel sign-in action: what else the cancel stops
    /// (`cancelSignInHelp(clusterName:isQueued:)`).
    var cancelSignInHelp: String?
}

/// The slice of a session the strip reads; tests and previews build it
/// directly.
struct ClusterStatusInput {
    var displayName: String
    var phase: ClusterPresentation.Phase
    var presentationDetail: String
    var primaryAction: ClusterPresentation.Action?
    var isPaused: Bool = false
    var hasSnapshot: Bool = true
    var statusMessage: String = ""
    /// Raised by something the user did (manual refresh, sign-in, cancel).
    var errorMessage: String?
    /// Set on EVERY failed refresh — automatic, startup probe or manual —
    /// and cleared by the next success.
    var failure: RefreshFailure?
    /// Slurm failing over a healthy connection.
    var schedulerIssue: String?
    var warnings: [String] = []
    /// The current (possibly backed-off) cadence, e.g. "40s".
    var refreshIntervalText: String = "\(Int(HPCDefaults.refreshInterval))s"
}

extension ClusterStatusInput {
    @MainActor
    init(session: ClusterSession, presentation: ClusterPresentation) {
        self.init(
            displayName: session.displayName,
            phase: presentation.phase,
            presentationDetail: presentation.detail,
            primaryAction: presentation.primaryAction,
            isPaused: session.isPaused,
            hasSnapshot: session.snapshot != nil,
            statusMessage: session.statusMessage,
            errorMessage: session.errorMessage,
            failure: session.lastRefreshFailure,
            schedulerIssue: session.schedulerIssue,
            warnings: session.snapshot?.warnings ?? [],
            refreshIntervalText: session.refreshIntervalText
        )
    }
}

extension ClusterStatusContent {
    /// Priority: a sign-in in progress (it has the Cancel), then an error
    /// the user caused, then the last refresh failure, then the phase.
    static func make(_ input: ClusterStatusInput) -> ClusterStatusContent? {
        let name = input.displayName
        switch input.phase {
        case .signingIn, .queued:
            return ClusterStatusContent(
                tone: .warning,
                systemImage: "person.badge.key",
                showsProgress: true,
                text: input.presentationDetail,
                actions: [.cancelSignIn],
                cancelSignInHelp: cancelSignInHelp(clusterName: name, isQueued: input.phase == .queued)
            )
        case .off:
            return nil
        default:
            break
        }

        let pauseOrResume: Action = input.isPaused ? .resume : .pause

        if let error = nonEmpty(input.errorMessage) {
            // A manual refresh that failed sets both: show it once, with the
            // failure's kind-specific wording and details.
            if let failure = input.failure, failure.describes(error) {
                return failureContent(failure, input: input, userAsked: true, userMessage: error)
            }
            var actions: [Action] = []
            if input.primaryAction == .connect {
                actions.append(.connect)
            }
            actions.append(pauseOrResume)
            return ClusterStatusContent(
                tone: .critical,
                systemImage: "exclamationmark.triangle.fill",
                showsProgress: false,
                text: firstLine(error),
                details: error.contains("\n") || error.count > 120 ? error : nil,
                actions: actions
            )
        }

        switch input.phase {
        case .paused:
            var content = ClusterStatusContent(
                tone: .unavailable,
                systemImage: "pause.circle.fill",
                showsProgress: false,
                text: input.presentationDetail,
                actions: [.resume]
            )
            // Often paused BECAUSE refreshes kept failing: keep the reason
            // in reach instead of hiding it behind the pause.
            if let failure = input.failure {
                content.hint = "Before the pause: \(failure.message)"
                content.details = failure.detailsText(userMessage: nil)
            }
            return content
        case .checking:
            return ClusterStatusContent(
                tone: .unavailable,
                systemImage: "antenna.radiowaves.left.and.right",
                showsProgress: true,
                text: "\(input.presentationDetail) The cached snapshot stays on screen meanwhile."
            )
        case .stale, .notConnected:
            if let failure = input.failure {
                return failureContent(failure, input: input, userAsked: false, userMessage: nil)
            }
            return ClusterStatusContent(
                tone: .warning,
                systemImage: "clock.badge.exclamationmark",
                showsProgress: false,
                text: input.hasSnapshot ? "Not live — \(input.statusMessage)" : input.presentationDetail,
                actions: input.primaryAction == .connect ? [.connect] : []
            )
        case .live, .loadingFirstSnapshot:
            if let failure = input.failure {
                return failureContent(failure, input: input, userAsked: false, userMessage: nil)
            }
            if let issue = nonEmpty(input.schedulerIssue) {
                return ClusterStatusContent(
                    tone: .warning,
                    systemImage: "server.rack",
                    showsProgress: false,
                    text: issue,
                    hint: "The SSH session is fine, so signing in again would not help; anything Slurm could not refresh shows the previous data.",
                    details: input.warnings.isEmpty ? nil : input.warnings.joined(separator: "\n"),
                    actions: [pauseOrResume]
                )
            }
            if !input.warnings.isEmpty {
                let count = input.warnings.count
                return ClusterStatusContent(
                    tone: .warning,
                    systemImage: "exclamationmark.bubble",
                    showsProgress: false,
                    text: count == 1
                        ? "1 collector warning; the rest of the \(name) snapshot is fine"
                        : "\(count) collector warnings; the rest of the \(name) snapshot is fine",
                    details: input.warnings.joined(separator: "\n")
                )
            }
            return nil
        case .signingIn, .queued, .off:
            return nil
        }
    }

    /// One failed refresh, worded by what can fix it.
    static func failureContent(
        _ failure: RefreshFailure,
        input: ClusterStatusInput,
        userAsked: Bool,
        userMessage: String?
    ) -> ClusterStatusContent {
        let name = input.displayName
        let pauseOrResume: Action = input.isPaused ? .resume : .pause
        let isLive = input.phase == .live || input.phase == .loadingFirstSnapshot
        let repeated = failure.consecutiveCount > 1 ? "Failed \(failure.consecutiveCount) times in a row. " : ""
        let details = failure.detailsText(userMessage: userMessage)
        switch failure.kind {
        case .configuration:
            // "Again" only where there was a sign-in to repeat: a cluster
            // that is not connected (often never signed in) shows this
            // under the hero's Connect button.
            let signInNote = input.phase == .notConnected
                ? "Signing in will not fix it."
                : "Signing in again will not help."
            return ClusterStatusContent(
                tone: .critical,
                systemImage: "wrench.and.screwdriver.fill",
                showsProgress: false,
                text: failure.message,
                hint: repeated + "A setup problem on this Mac: fix it in the sidebar settings (account, project root, hosts). " + signInNote,
                details: details,
                actions: [pauseOrResume]
            )
        case .clusterSide:
            return ClusterStatusContent(
                tone: .warning,
                systemImage: "server.rack",
                showsProgress: false,
                text: failure.message,
                hint: repeated + "Slurm trouble on \(name). The SSH session is still live, so signing in again would not help; anything that could not refresh shows the previous data.",
                details: details,
                actions: [pauseOrResume]
            )
        case .transport:
            var actions: [Action] = []
            if input.primaryAction == .connect {
                actions.append(.connect)
            }
            actions.append(pauseOrResume)
            let next: String
            if input.isPaused {
                next = "Background retries are paused."
            } else if input.primaryAction == .connect {
                next = "Sign in again to refresh."
            } else {
                next = "Retrying every \(input.refreshIntervalText)."
            }
            let shown = input.hasSnapshot ? " The last snapshot stays on screen." : ""
            return ClusterStatusContent(
                tone: userAsked ? .critical : .warning,
                systemImage: "wifi.exclamationmark",
                showsProgress: false,
                text: failure.message,
                hint: repeated + (isLive
                    ? "Connection trouble reaching \(name). \(next)\(shown)"
                    : "No connection to \(name). \(next)\(shown)"),
                details: details,
                actions: actions
            )
        }
    }

    /// What one cluster's Cancel sign-in stops. A queued cluster just
    /// leaves the queue. Cancelling the sign-in that is running also skips
    /// the clusters queued by the same Connect or Reconnect (`runLoginChain`
    /// does not push the next Duo request at someone who said stop), so the
    /// tooltip must not promise that nothing else is affected. Nor may it
    /// promise that no further Duo push arrives: a cluster queued by a
    /// separate Connect is its own link of the chain and still signs in.
    /// Only the sidebar's Cancel sign-in (`AppModel.cancelLogins`) stops
    /// every link, so the tooltip points there.
    static func cancelSignInHelp(clusterName: String, isQueued: Bool) -> String {
        if isQueued {
            return "Take \(clusterName) out of the sign-in queue; the other sign-ins go ahead"
        }
        return "Stop the \(clusterName) sign-in; clusters queued by the same Connect or Reconnect are skipped too "
            + "(the sidebar's Cancel sign-in stops every queued sign-in)"
    }

    static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

extension RefreshFailure {
    /// What can fix this kind of failure, for the Details text.
    var kindExplanation: String {
        switch kind {
        case .configuration:
            return "Setup problem on this Mac (collector script, project root, account or host settings)."
        case .clusterSide:
            return "Slurm on the cluster failed; the SSH connection itself worked."
        case .transport:
            return "No usable connection (control master gone, network or VPN)."
        }
    }

    /// The Details disclosure: kind, how often, when, then the raw output.
    func detailsText(userMessage: String?) -> String {
        let attempts = consecutiveCount > 1 ? "\(consecutiveCount) failures in a row" : "First failure"
        var lines = [
            kindExplanation,
            "\(attempts); last attempt at \(date.formatted(date: .omitted, time: .standard))."
        ]
        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if let userMessage, userMessage != trimmedDetail, userMessage != message {
            lines.append("")
            lines.append(userMessage)
        }
        if !trimmedDetail.isEmpty, trimmedDetail != message {
            lines.append("")
            lines.append(trimmedDetail)
        }
        return lines.joined(separator: "\n")
    }

    /// Whether an `errorMessage` is this same failure reported to the user
    /// (a manual refresh sets both), rather than something else (a sign-in
    /// or cancel error) that must keep its own line.
    func describes(_ error: String) -> Bool {
        let error = error.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let headline = ClusterStatusContent.firstLine(error)
        if !message.isEmpty, error == message || headline == message || error.contains(message) {
            return true
        }
        guard !detail.isEmpty else {
            return false
        }
        return error == detail || error.contains(detail) || detail.contains(headline)
    }

}

// MARK: - Views

/// The cluster dashboard's strip, fed from its session.
struct ClusterStatusStrip: View {
    @ObservedObject var session: ClusterSession
    let presentation: ClusterPresentation
    let onConnect: () -> Void
    let onCancelSignIn: () -> Void

    var body: some View {
        if let content = ClusterStatusContent.make(ClusterStatusInput(session: session, presentation: presentation)) {
            StatusStripView(
                content: content,
                clusterName: session.displayName,
                accent: session.profile.accent.color,
                onAction: perform
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func perform(_ action: ClusterStatusContent.Action) {
        switch action {
        case .connect:
            onConnect()
        case .resume, .pause:
            session.togglePause()
        case .cancelSignIn:
            onCancelSignIn()
        }
    }
}

/// Draws one `ClusterStatusContent`: icon, headline, hint, an inline
/// Details disclosure (inline rather than a popover, so the full output
/// stays visible while the user acts on it) and the actions.
struct StatusStripView: View {
    let content: ClusterStatusContent
    let clusterName: String
    var accent: Color = .accentColor
    var onAction: (ClusterStatusContent.Action) -> Void = { _ in }

    @State private var showsDetails: Bool
    @Environment(\.colorScheme) private var colorScheme

    init(
        content: ClusterStatusContent,
        clusterName: String,
        accent: Color = .accentColor,
        initiallyExpanded: Bool = false,
        onAction: @escaping (ClusterStatusContent.Action) -> Void = { _ in }
    ) {
        self.content = content
        self.clusterName = clusterName
        self.accent = accent
        self.onAction = onAction
        _showsDetails = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                if content.showsProgress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: content.systemImage)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(content.tone.color)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(content.text)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(content.tone == .critical
                            ? content.tone.color.legibleText(in: colorScheme)
                            : Color.primary.opacity(0.88))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                    if let hint = content.hint {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(Color.primary.opacity(0.68))
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                if content.details != nil {
                    Button {
                        withAnimation(AppTheme.smoothEase) {
                            showsDetails.toggle()
                        }
                    } label: {
                        Label("Details", systemImage: showsDetails ? "chevron.up" : "chevron.down")
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .controlSize(.small)
                    .help(showsDetails ? "Hide the full output" : "Show the full output, how often it failed and when")
                    .accessibilityValue(showsDetails ? "expanded" : "collapsed")
                }

                ForEach(content.actions, id: \.self) { action in
                    actionButton(action)
                }
            }

            if showsDetails, let details = content.details {
                ScrollView {
                    Text(details)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(content.tone.color.opacity(0.18), lineWidth: 1)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityLabel("\(clusterName) status details")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(content.tone.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(content.tone.color.opacity(0.28), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(clusterName) status")
    }

    @ViewBuilder
    private func actionButton(_ action: ClusterStatusContent.Action) -> some View {
        switch action {
        case .connect:
            Button("Connect") { onAction(.connect) }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .controlSize(.small)
                .fixedSize()
                .help("Sign in to \(clusterName) with the account in the sidebar; a session that is still open is reused")
        case .resume:
            Button {
                onAction(.resume)
            } label: {
                Label("Resume", systemImage: "play.fill")
                    .fixedSize()
            }
            .controlSize(.small)
            .help("Resume background refreshes and fetch a fresh snapshot now")
        case .pause:
            Button {
                onAction(.pause)
            } label: {
                Label("Pause", systemImage: "pause.fill")
                    .fixedSize()
            }
            .controlSize(.small)
            .help("Stop retrying in the background; the last snapshot stays on screen")
        case .cancelSignIn:
            Button("Cancel sign-in", role: .cancel) { onAction(.cancelSignIn) }
                .controlSize(.small)
                .fixedSize()
                .help(content.cancelSignInHelp ?? "Stop the \(clusterName) sign-in")
        }
    }
}
