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
                    connectionState: session.connectionState,
                    isLoggedIn: session.isLoggedIn
                ) {
                    manager.openShell(settings: session.settings)
                }
            }

            quickCommandRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(AppTheme.smoothEase, value: manager.sessions.isEmpty)
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
                        onClose: { manager.close(terminal) }
                    )
                }
            }
            .padding(.vertical, 1)
        }
        .animation(AppTheme.softSpring, value: manager.sessions.count)
        .accessibilityLabel("\(clusterName) terminal sessions")
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
                            ? "Opens in its own \(clusterName) session"
                            : "Runs in the active \(clusterName) shell, or in a new session"
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
        TerminalHostView(session: session)
            .id(session.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Round the dark terminal surface itself so its corners never
            // poke square into the card's rounded chrome.
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .bottom) {
                switch session.status {
                case .running:
                    EmptyView()
                case .exited(let exitStatus):
                    statusBar(
                        systemImage: "bolt.slash.fill",
                        text: exitStatus?.label ?? "exited",
                        buttonTitle: "Restart",
                        accessibilityText: exitStatus.map { "Session \($0.label)" } ?? "Session exited"
                    )
                case .sessionUnavailable:
                    // ssh never ran: the pre-flight found no live master.
                    // "Retry" rather than "Restart" — after Connect in the
                    // sidebar the same session simply tries again.
                    statusBar(
                        systemImage: "bolt.horizontal.circle",
                        text: "\(session.clusterName) not connected",
                        buttonTitle: "Retry",
                        accessibilityText: "\(session.clusterName) SSH session is not running"
                    )
                }
            }
            // Terminals want space: minimal padding, but still glass chrome.
            .dashboardCard(padding: 8, accent: accent)
            .animation(AppTheme.smoothEase, value: session.status)
    }

    private func statusBar(
        systemImage: String,
        text: String,
        buttonTitle: String,
        accessibilityText: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption.monospacedDigit().weight(.medium))
            Button(buttonTitle, action: onRestart)
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .controlSize(.small)
                .accessibilityLabel("\(buttonTitle) \(session.title) on \(session.clusterName)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(AppTheme.border, lineWidth: 1))
        .padding(.bottom, 12)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        // .contain (not .combine) keeps the button its own element, so
        // VoiceOver can reach Restart/Retry directly.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }
}

/// Hosts the session's long-lived `LocalProcessTerminalView`. Recreated per
/// session via `.id(session.id)` so switching sessions swaps NSViews while
/// the underlying processes keep running.
private struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = session.terminalView
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
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

    private var statusColor: Color {
        switch session.status {
        case .running:
            return .green
        case .exited:
            return .red
        case .sessionUnavailable:
            return .orange
        }
    }

    private var statusText: String {
        switch session.status {
        case .running:
            return "running"
        case .exited(let exitStatus):
            return exitStatus?.label ?? "exited"
        case .sessionUnavailable:
            return "not connected"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(session.title)
                .font(.caption.weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .lineLimit(1)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Close \(session.title) on \(session.clusterName)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
        .help("\(session.title) on \(session.clusterName) — \(statusText)")
        .animation(AppTheme.smoothEase, value: isActive)
        .animation(AppTheme.smoothEase, value: isHovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session \(session.title) on \(session.clusterName), \(statusText)")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
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
    let connectionState: ClusterConnectionState
    let isLoggedIn: Bool
    let onOpenShell: () -> Void

    private var headline: String {
        isLoggedIn
            ? "No terminal sessions on \(clusterName) yet"
            : "The terminal reuses \(clusterName)'s SSH session — connect first."
    }

    /// The not-connected copy is honest about what a shell will do: every
    /// session pre-flights the cluster's master, so trying anyway costs
    /// nothing and never prompts for a password or a Duo push.
    private var detail: String {
        isLoggedIn
            ? "Open a shell on the \(clusterName) login node over the existing SSH session — no extra password or Duo push."
            : "Use Connect for \(clusterName) in the sidebar. You can still try a shell: it checks for \(clusterName)'s session first and never asks for a password."
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)

            VStack(spacing: 14) {
                Image(systemName: "terminal")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)

                ConnectionStatePill(state: connectionState)

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
