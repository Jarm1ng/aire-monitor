import AppKit
import SwiftTerm
import SwiftUI

// SwiftTerm exports its own `Color`; without this shadow every bare `Color`
// in the file is ambiguous between SwiftTerm.Color and SwiftUI.Color.
private typealias Color = SwiftUI.Color

/// Terminal tab: a session strip of glass pills, the active terminal filling
/// the remaining space, and a quick-command chip row. Sessions live in
/// `TerminalManager` (a `@StateObject` up in `ContentView`), so switching
/// tabs never interrupts a running ssh.
struct TerminalDashboard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var manager: TerminalManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(
                title: "Terminal",
                subtitle: "Interactive shells over the app's live SSH session",
                systemImage: "terminal",
                accent: AIRETheme.gpu
            ) {
                HStack(spacing: 10) {
                    fontSizeControls

                    Button {
                        manager.openShell(settings: model.settings)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("New shell on AIRE (⌘⏎)")
                    .accessibilityLabel("New shell")
                }
            }

            if manager.sessions.isEmpty {
                emptyHintBar
            } else {
                sessionStrip
            }

            if let session = manager.activeSession {
                TerminalSessionPane(session: session)
            } else {
                TerminalHero(isLoggedIn: model.isLoggedIn) {
                    manager.openShell(settings: model.settings)
                }
            }

            quickCommandRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(AIRETheme.smoothEase, value: manager.sessions.isEmpty)
    }

    // MARK: Session strip

    private var sessionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(manager.sessions) { session in
                    SessionPill(
                        session: session,
                        isActive: manager.activeSession?.id == session.id,
                        onSelect: { manager.activeSessionID = session.id },
                        onClose: { manager.close(session) }
                    )
                }
            }
            .padding(.vertical, 1)
        }
        .animation(AIRETheme.softSpring, value: manager.sessions.count)
    }

    /// One-line hint shown in place of the session strip while no session
    /// exists, so the strip area never collapses and jumps the layout.
    private var emptyHintBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "keyboard")
                .font(.caption2.weight(.semibold))
            Text("⌘ Return opens a shell on the login node")
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

    private struct QuickCommand: Identifiable {
        let title: String
        let command: String
        let systemImage: String
        /// Full-screen programs must never be typed into an existing shell:
        /// a later chip's text would land in them as raw keystrokes.
        var opensDedicatedSession: Bool = false
        var id: String { title }
    }

    private static let quickCommandItems: [QuickCommand] = [
        QuickCommand(title: "My jobs", command: "squeue --me", systemImage: "list.bullet.rectangle"),
        QuickCommand(title: "Cluster", command: "sinfo", systemImage: "square.grid.2x2"),
        QuickCommand(title: "Quota", command: "quota -s", systemImage: "internaldrive"),
        QuickCommand(title: "GPU nodes", command: "sinfo -N -p gpu", systemImage: "memorychip"),
        QuickCommand(title: "htop", command: "htop || top", systemImage: "gauge", opensDedicatedSession: true)
    ]

    private var quickCommandRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.quickCommandItems) { item in
                    QuickCommandChip(title: item.title, systemImage: item.systemImage) {
                        manager.runQuickCommand(
                            item.command,
                            title: item.title,
                            settings: model.settings,
                            prefersDedicatedSession: item.opensDedicatedSession
                        )
                    }
                    .help(item.command)
                }
            }
            .padding(.vertical, 1)
        }
        .accessibilityLabel("Quick commands")
    }
}

// MARK: - Terminal pane

private struct TerminalSessionPane: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        TerminalHostView(session: session)
            .id(session.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Round the dark terminal surface itself so its corners never
            // poke square into the card's rounded chrome.
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .bottom) {
                if case .exited(let exitStatus) = session.status {
                    exitBar(status: exitStatus)
                }
            }
            // Terminals want space: minimal padding, but still glass chrome.
            .dashboardCard(padding: 8, accent: AIRETheme.gpu)
            .animation(AIRETheme.smoothEase, value: session.status)
    }

    private func exitBar(status: TerminalExitStatus?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.slash.fill")
                .foregroundStyle(.orange)
            Text(status?.label ?? "exited")
                .font(.caption.monospacedDigit().weight(.medium))
            Button("Restart") {
                session.restart()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(AIRETheme.border, lineWidth: 1))
        .padding(.bottom, 12)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.map { "Session \($0.label)" } ?? "Session exited")
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
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    private var statusColor: Color {
        if case .running = session.status {
            return .green
        }
        return .red
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
            .accessibilityLabel("Close \(session.title)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            Capsule()
                .fill(.regularMaterial)
                .overlay {
                    Capsule()
                        .fill(AIRETheme.gpu.opacity(isActive ? 0.16 : (isHovered ? 0.10 : 0.04)))
                }
        }
        .overlay(
            Capsule()
                .stroke(
                    isActive ? AIRETheme.gpu.opacity(0.35) : AIRETheme.chipStroke(for: colorScheme),
                    lineWidth: 1
                )
        )
        .clipShape(Capsule())
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .animation(AIRETheme.smoothEase, value: isActive)
        .animation(AIRETheme.smoothEase, value: isHovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session \(session.title)")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Quick command chip

private struct QuickCommandChip: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AIRETheme.gpu.opacity(isHovered ? 0.16 : 0.10), in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(
                            isHovered ? AIRETheme.gpu.opacity(0.35) : AIRETheme.chipStroke(for: colorScheme),
                            lineWidth: 1
                        )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(AIRETheme.smoothEase, value: isHovered)
        .accessibilityLabel(title)
    }
}

// MARK: - Empty state

private struct TerminalHero: View {
    let isLoggedIn: Bool
    let onOpenShell: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)

            VStack(spacing: 14) {
                Image(systemName: "terminal")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(AIRETheme.gpu)

                Text(
                    isLoggedIn
                        ? "No terminal sessions yet"
                        : "The terminal reuses the app's SSH session — log in first."
                )
                .font(.headline)
                .multilineTextAlignment(.center)

                Text(
                    isLoggedIn
                        ? "Open a shell on the AIRE login node over the existing SSH session — no extra password or Duo push."
                        : "You can still open a shell; ssh will print its own error if no session is available."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

                Button {
                    onOpenShell()
                } label: {
                    Label("New shell", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(AIRETheme.gpu)
            }
            .padding(28)
            .frame(maxWidth: 520)
            .dashboardCard(padding: 24, accent: AIRETheme.gpu)

            Spacer(minLength: 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
