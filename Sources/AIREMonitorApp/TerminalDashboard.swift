import HPCCore
import AppKit
import SwiftTerm
import SwiftUI

// SwiftTerm exports its own `Color`; without this shadow every bare `Color`
// in the file is ambiguous between SwiftTerm.Color and SwiftUI.Color.
private typealias Color = SwiftUI.Color

/// Terminal tab of one cluster's dashboard: a session strip of glass pills,
/// the active terminal filling the remaining space, and a quick-command chip
/// row. Sessions live in the cluster's own `TerminalManager`
/// (`session.terminals`), so switching tabs or clusters never interrupts a
/// running ssh, and everything here — new shells, chips, restarts — goes
/// to this cluster only. The cluster's accent color tints the chrome so an
/// AIRE terminal and a Calder terminal are never mistaken for each other.
struct TerminalDashboard: View {
    @ObservedObject var session: ClusterSession
    @ObservedObject var manager: TerminalManager

    private var clusterName: String { session.displayName }
    private var accent: Color { session.profile.accent.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(
                title: "Terminal",
                subtitle: "Interactive shells on \(clusterName) over the app's live SSH session",
                systemImage: "terminal",
                accent: accent
            ) {
                HStack(spacing: 10) {
                    fontSizeControls

                    Button {
                        manager.openShell(settings: session.settings)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("New shell on \(clusterName) (⌘⏎)")
                    .accessibilityLabel("New shell on \(clusterName)")
                }
            }

            if manager.sessions.isEmpty {
                emptyHintBar
            } else {
                sessionStrip
            }

            if case .sessionLimit(let limit) = manager.notice {
                SessionLimitBanner(
                    clusterName: clusterName,
                    limit: limit,
                    runningTailCount: manager.runningTailSessions.count,
                    onCloseTails: { manager.closeRunningTails() },
                    onDismiss: { manager.dismissNotice() }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let terminal = manager.activeSession {
                TerminalSessionPane(session: terminal, accent: accent) {
                    // Fresh settings, so a restart follows a route or host
                    // change made since the session was opened.
                    manager.restart(terminal, settings: session.settings)
                }
            } else {
                TerminalHero(
                    clusterName: clusterName,
                    accent: accent,
                    presentation: session.presentation
                ) {
                    manager.openShell(settings: session.settings)
                }
            }

            quickCommandRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(AppTheme.smoothEase, value: manager.sessions.isEmpty)
        .animation(AppTheme.smoothEase, value: manager.notice)
        // Keyed by cluster: the same view slot is reused when the sidebar
        // switches clusters, so plain onAppear would miss that switch and
        // leave this cluster's terminals at a stale text size.
        .task(id: session.id) {
            manager.adoptSharedFontSize()
        }
    }

    // MARK: Session strip

    private var sessionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(manager.sessions) { terminal in
                    SessionPill(
                        session: terminal,
                        accent: accent,
                        isActive: manager.activeSession?.id == terminal.id,
                        onSelect: { manager.activeSessionID = terminal.id },
                        onClose: { requestClose(terminal) }
                    )
                }
            }
            .padding(.vertical, 1)
        }
        .animation(AppTheme.softSpring, value: manager.sessions.count)
        .accessibilityLabel("\(clusterName) terminal sessions")
    }

    /// Closing a connected shell or command ends whatever runs in it — an
    /// unsaved vim buffer, an `srun --pty` allocation that queued for hours —
    /// so it asks first (unless the person opted out). Tails, finished and
    /// never-connected tabs close at once: nothing is lost.
    private func requestClose(_ terminal: TerminalSession) {
        guard terminal.closingEndsWork, !TerminalCloseConfirmation.isSuppressed else {
            manager.close(terminal)
            return
        }
        TerminalCloseConfirmation.confirm(sessionTitle: terminal.title, clusterName: clusterName) { confirmed in
            if confirmed {
                manager.close(terminal)
            }
        }
    }

    /// One-line hint shown in place of the session strip while no session
    /// exists, so the strip area never collapses and jumps the layout.
    private var emptyHintBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "keyboard")
                .font(.caption2.weight(.semibold))
            Text("⌘ Return opens a shell on the \(clusterName) login node")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 1)
        .frame(minHeight: 28, alignment: .leading)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }

    private var fontSizeControls: some View {
        HStack(spacing: 4) {
            Button {
                manager.adjustFontSize(by: -1)
            } label: {
                Image(systemName: "textformat.size.smaller")
            }
            .keyboardShortcut("-", modifiers: .command)
            .help("Smaller terminal text (⌘−)")
            .accessibilityLabel("Smaller terminal text")

            Button {
                manager.adjustFontSize(by: 1)
            } label: {
                Image(systemName: "textformat.size.larger")
            }
            .keyboardShortcut("=", modifiers: .command)
            .help("Larger terminal text (⌘=)")
            .accessibilityLabel("Larger terminal text")
        }
        .buttonStyle(.bordered)
    }

    // MARK: Quick commands

    /// Rebuilt from the profile on every render: cheap (five tiny values)
    /// and it can never go stale against the cluster this view shows.
    private var quickCommandItems: [TerminalQuickCommand] {
        TerminalQuickCommand.items(for: session.profile)
    }

    private var quickCommandRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(quickCommandItems) { item in
                    QuickCommandChip(
                        title: item.title,
                        systemImage: item.systemImage,
                        accent: accent,
                        accessibilityHint: item.opensDedicatedSession
                            ? "Opens in its own \(clusterName) tab"
                            : "Types into the active \(clusterName) shell unless a full-screen program "
                                + "is open there; otherwise runs in its own tab"
                    ) {
                        manager.runQuickCommand(
                            item.command,
                            title: item.title,
                            settings: session.settings,
                            prefersDedicatedSession: item.opensDedicatedSession
                        )
                    }
                    .help(item.command)
                }
            }
            .padding(.vertical, 1)
        }
        .accessibilityLabel("\(clusterName) quick commands")
    }
}

// MARK: - Terminal pane

private struct TerminalSessionPane: View {
    @ObservedObject var session: TerminalSession
    let accent: Color
    let onRestart: () -> Void

    var body: some View {
        // The status bar sits BELOW the terminal, never over it: the last
        // rows are exactly where ssh prints its final error ("Shared
        // connection to … closed.") and where the not-connected message
        // appears. SwiftTerm keeps the cursor row visible as it shrinks.
        VStack(spacing: 8) {
            TerminalHostView(session: session)
                .id(session.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Round the dark terminal surface itself so its corners never
                // poke square into the card's rounded chrome.
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            if let bar = statusBarContent {
                statusBar(bar)
            }
        }
        // Terminals want space: minimal padding, but still glass chrome.
        .dashboardCard(padding: 8, accent: accent)
        .animation(AppTheme.smoothEase, value: session.status)
        .animation(AppTheme.smoothEase, value: session.isConnectionStalled)
    }

    private struct StatusBarContent {
        let presentation: TerminalStatusPresentation
        let text: String
        let showsAction: Bool
    }

    /// nil while the session is healthy. A normal connect takes well under a
    /// second, so "connecting" only earns a bar once it has stalled.
    private var statusBarContent: StatusBarContent? {
        let presentation = session.statusPresentation
        switch session.status {
        case .running:
            return nil
        case .connecting:
            guard session.isConnectionStalled else {
                return nil
            }
            return StatusBarContent(
                presentation: TerminalStatusPresentation(
                    label: "no response",
                    tone: .warning,
                    systemImage: "hourglass",
                    actionTitle: nil,
                    help: presentation.help
                ),
                text: "No response from \(session.clusterName) yet — its SSH session may be stale after a sleep "
                    + "or network change. Use Connect for \(session.clusterName) in the sidebar.",
                showsAction: false
            )
        case .exited, .sessionUnavailable:
            return StatusBarContent(presentation: presentation, text: presentation.label, showsAction: true)
        }
    }

    private func statusBar(_ content: StatusBarContent) -> some View {
        let presentation = content.presentation
        return HStack(spacing: 10) {
            Image(systemName: presentation.systemImage)
                .foregroundStyle(presentation.tone.color)
                .accessibilityHidden(true)
            Text(content.text)
                .font(.caption.monospacedDigit().weight(.medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if content.showsAction, let actionTitle = presentation.actionTitle {
                Button(actionTitle, action: onRestart)
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .controlSize(.small)
                    .accessibilityLabel("\(actionTitle) \(session.title) on \(session.clusterName)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(presentation.tone.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
        .help(presentation.help)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        // .contain (not .combine) keeps the button its own element, so
        // VoiceOver can reach Restart/Retry directly.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(session.title): \(content.text). \(presentation.help)")
    }
}

/// Hosts the session's long-lived `LocalProcessTerminalView`. Recreated per
/// session via `.id(session.id)` so switching sessions swaps NSViews while
/// the underlying processes keep running.
private struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> HPCTerminalView {
        let view = session.terminalView
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: HPCTerminalView, context: Context) {}
}

// MARK: - Session pill

private struct SessionPill: View {
    @ObservedObject var session: TerminalSession
    let accent: Color
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        let presentation = session.statusPresentation
        HStack(spacing: 6) {
            Group {
                if session.status == .connecting {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 9, height: 9)
                } else {
                    Circle()
                        .fill(presentation.tone.color)
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityHidden(true)
            Text(session.title)
                .font(.caption.weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .lineLimit(1)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    // The glyph stays small; the hit area does not.
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(session.closingEndsWork ? "Close (asks first: the session is still running)" : "Close")
            .accessibilityLabel("Close \(session.title) on \(session.clusterName)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .background {
            Capsule()
                .fill(.regularMaterial)
                .overlay {
                    Capsule()
                        .fill(accent.opacity(isActive ? 0.18 : (isHovered ? 0.11 : 0.05)))
                }
        }
        .overlay(
            Capsule()
                .stroke(
                    isActive ? accent.opacity(0.45) : AppTheme.chipStroke(for: colorScheme),
                    lineWidth: 1
                )
        )
        .clipShape(Capsule())
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .help("\(session.title) on \(session.clusterName) — \(presentation.label). \(presentation.help)")
        .animation(AppTheme.smoothEase, value: isActive)
        .animation(AppTheme.smoothEase, value: isHovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session \(session.title) on \(session.clusterName), \(presentation.label)")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Session limit

/// Shown instead of starting ssh when the cluster already has
/// `TerminalManager.maxConcurrentSessions` running tabs. Without it the new
/// tab would die with "exited (255)" and the collector, sharing the same
/// connection, would be refused alongside it.
private struct SessionLimitBanner: View {
    let clusterName: String
    let limit: Int
    let runningTailCount: Int
    let onCloseTails: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "rectangle.stack.badge.minus")
                .foregroundStyle(StatusTone.warning.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Close a tab first")
                    .font(.caption.weight(.semibold))
                Text(
                    "\(clusterName) already has \(limit) terminal sessions open. Each tab uses one of the "
                        + "cluster connection's limited sessions, which the monitor and file transfers need too."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if runningTailCount > 0 {
                Button(runningTailCount == 1 ? "Close 1 log tail" : "Close \(runningTailCount) log tails", action: onCloseTails)
                    .controlSize(.small)
                    .help("Log tails never end on their own; the logs stay on \(clusterName).")
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(StatusTone.warning.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(StatusTone.warning.color.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Close confirmation

/// Asks before a tab's running session is ended. AppKit's alert (not a
/// SwiftUI dialog) for its "Don't ask again" checkbox on macOS 13.
@MainActor
enum TerminalCloseConfirmation {
    static let suppressionDefaultsKey = "TerminalSkipCloseConfirmation"

    static var isSuppressed: Bool {
        UserDefaults.standard.bool(forKey: suppressionDefaultsKey)
    }

    static func confirm(
        sessionTitle: String,
        clusterName: String,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close “\(sessionTitle)” on \(clusterName)?"
        alert.informativeText = "Its SSH session and anything running in it — an editor, an interactive job — will end."
        let closeButton = alert.addButton(withTitle: "Close")
        closeButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"
        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            let confirmed = response == .alertFirstButtonReturn
            if confirmed, alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: suppressionDefaultsKey)
            }
            completion(confirmed)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated {
                    finish(response)
                }
            }
        } else {
            finish(alert.runModal())
        }
    }
}

// MARK: - Quick command chip

private struct QuickCommandChip: View {
    let title: String
    let systemImage: String
    let accent: Color
    let accessibilityHint: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(accent.opacity(isHovered ? 0.16 : 0.10), in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(
                            isHovered ? accent.opacity(0.35) : AppTheme.chipStroke(for: colorScheme),
                            lineWidth: 1
                        )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(AppTheme.smoothEase, value: isHovered)
        .accessibilityLabel(title)
        .accessibilityHint(accessibilityHint)
    }
}

// MARK: - Empty state

private struct TerminalHero: View {
    let clusterName: String
    let accent: Color
    let presentation: ClusterPresentation
    let onOpenShell: () -> Void

    private var isConnected: Bool {
        presentation.phase == .live || presentation.phase == .loadingFirstSnapshot
    }

    private var headline: String {
        switch presentation.phase {
        case .live, .loadingFirstSnapshot:
            return "No terminal sessions on \(clusterName) yet"
        case .checking:
            return "Checking for \(clusterName)'s SSH session…"
        case .signingIn, .queued:
            return "Signing in to \(clusterName)…"
        case .off, .notConnected, .paused, .stale:
            return "The terminal reuses \(clusterName)'s SSH session — connect first."
        }
    }

    /// The not-connected copy is honest about what a shell will do: every
    /// session pre-flights the cluster's master, so trying anyway costs
    /// nothing and never prompts for a password or a Duo push.
    private var detail: String {
        switch presentation.phase {
        case .live, .loadingFirstSnapshot:
            return "Open a shell on the \(clusterName) login node over the existing SSH session — no extra password or Duo push."
        case .paused:
            return "Monitoring is paused, but a live session still works: a shell checks for it first and never asks for a password."
        case .checking:
            return "If a session is still open, a shell uses it at once — no password or Duo push."
        case .signingIn, .queued:
            return "Once the sign-in finishes, shells open over the new session without another Duo push."
        case .off, .notConnected, .stale:
            return "Use Connect for \(clusterName) in the sidebar. You can still try a shell: it checks for \(clusterName)'s session first and never asks for a password."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)

            VStack(spacing: 14) {
                Image(systemName: "terminal")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)

                TerminalPhasePill(presentation: presentation)

                Text(headline)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)

                Button {
                    onOpenShell()
                } label: {
                    Label("New shell on \(clusterName)", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
            }
            .padding(28)
            .frame(maxWidth: 520)
            .dashboardCard(padding: 24, accent: accent)

            Spacer(minLength: 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The cluster's state as `ClusterPresentation` words it, so the terminal
/// never says "Cached" while the sidebar says "Checking".
private struct TerminalPhasePill: View {
    let presentation: ClusterPresentation

    var body: some View {
        HStack(spacing: 5) {
            if presentation.showsProgress {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(presentation.tint)
                    .frame(width: 7, height: 7)
            }
            Text(presentation.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(presentation.phase == .live ? Color.primary : Color.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(presentation.tint.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(presentation.tint.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection: \(presentation.title)")
    }
}

// MARK: - Styling

extension TerminalStatusPresentation.Tone {
    /// Status colours only; the cluster accent stays on the chrome.
    var color: SwiftUI.Color {
        switch self {
        case .live: return StatusTone.normal.color
        case .progress: return .secondary
        case .neutral: return .secondary
        case .warning: return StatusTone.warning.color
        case .failure: return StatusTone.critical.color
        }
    }
}
