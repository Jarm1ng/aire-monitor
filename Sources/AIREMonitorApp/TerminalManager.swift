import HPCCore
import AppKit
import Foundation
import SwiftTerm

// MARK: - SSH argument building

/// Builds `/usr/bin/ssh` invocations that reuse one cluster's 24h
/// ControlMaster session. Nothing here ever handles a password: BatchMode
/// suppresses every prompt (see `SSHMuxOptions`). Note that a dead or
/// missing master does NOT make ssh fail fast — OpenSSH silently falls back
/// to a direct, un-jumped connection — which is why every session
/// pre-flights its cluster's master (`TerminalSessionBackend`) before
/// launching.
enum SSHTerminalCommand {
    /// Wraps a value in single quotes for safe interpolation into a remote
    /// shell command (`'` becomes `'\''`).
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Like `shellQuote`, but leaves a plain ASCII word (letters, digits and
    /// `-_./:=@+,`) bare. Used for profile-supplied tokens such as partition
    /// names, so a command typed into the user's shell (and shown as a
    /// tooltip) reads `sinfo -N -p calder-gpu-hopper`, not a quoted string —
    /// while anything unexpected is still quoted safely.
    static func shellWord(_ value: String) -> String {
        let isPlainWord = !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (
                CharacterSet.alphanumerics.contains(scalar) || "-_./:=@+,".unicodeScalars.contains(scalar)
            )
        }
        return isPlainWord ? value : shellQuote(value)
    }

    /// Printed by the remote shell before a remote command runs: an SGR
    /// reset, invisible on screen. A login shell always prints a prompt,
    /// but a command such as `tail -F` on an empty log may print nothing for
    /// minutes; without this first byte the tab could not tell "connected,
    /// quiet" from "stuck on a wedged master" and would sit in "connecting…".
    static let connectionHandshake = "printf '\\033[0m'"

    /// Arguments for an interactive PTY session (`ssh -tt …`) on the cluster
    /// `settings` describes, optionally running a remote command instead of
    /// a login shell.
    static func terminalArguments(settings: ConnectionSettings, remoteCommand: String? = nil) -> [String] {
        var arguments = ["-tt"] + SSHMuxOptions.sshArguments(settings: settings) + [settings.hostname]
        if let remoteCommand, !remoteCommand.isEmpty {
            arguments.append("\(connectionHandshake); \(remoteCommand)")
        }
        return arguments
    }

    /// Child environment: every child's environment (the app's own minus any
    /// exported password, `MonitorService.childEnvironment`) plus a UTF-8
    /// locale and a terminal type SwiftTerm renders faithfully. A password
    /// left over from the old command-line helpers must never reach ssh or,
    /// through a SendEnv rule in ~/.ssh/config, the remote shell.
    static func environment() -> [String] {
        var environment = MonitorService.childEnvironment()
        environment["LANG"] = "en_US.UTF-8"
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        return environment.map { "\($0.key)=\($0.value)" }
    }
}

/// How a terminal session reaches the outside world. The live backend
/// pre-flights the cluster's master with `MonitorService.requireLiveMaster`
/// (`ssh -O check`, bounded by its 5 s timeout, so a wedged master can no
/// longer hang the pre-flight with an unreaped child) and forks ssh into the
/// pty. Tests swap in fakes, so routing, the session budget and the argv can
/// be checked without a pty, a socket or a cluster.
struct TerminalSessionBackend: Sendable {
    var masterIsAlive: @Sendable (ConnectionSettings) async -> Bool
    var launch: @MainActor @Sendable (LocalProcessTerminalView, _ arguments: [String], _ environment: [String]) -> Void
    /// Without a byte from ssh after this long, the tab says the shared
    /// session may be stale instead of spinning silently. A healthy
    /// connect delivers the prompt in well under a second.
    var stallHintDelay: TimeInterval = 15

    static let live = TerminalSessionBackend(
        masterIsAlive: { settings in
            do {
                try await MonitorService().requireLiveMaster(settings: settings)
                return true
            } catch {
                return false
            }
        },
        launch: { view, arguments, environment in
            view.startProcess(executable: "/usr/bin/ssh", args: arguments, environment: environment)
        }
    )
}

// MARK: - Terminal appearance

/// Dark, cyan-tinted terminal styling matching the app's glass language.
/// Terminals stay dark in both app appearances by convention; which cluster
/// a terminal belongs to is shown by the surrounding chrome (pills, card
/// accent), never by recoloring the text surface itself.
@MainActor
enum TerminalTheme {
    static let defaultFontSize: CGFloat = 13
    static let fontSizeRange: ClosedRange<CGFloat> = 9...22

    /// Near-black with a cold blue-cyan cast, close to AppTheme glass in dark mode.
    static let background = NSColor(srgbRed: 0.043, green: 0.058, blue: 0.078, alpha: 1)
    static let foreground = NSColor(srgbRed: 0.85, green: 0.91, blue: 0.94, alpha: 1)
    static let caret = NSColor(srgbRed: 0.36, green: 0.82, blue: 0.94, alpha: 1)

    static func font(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func ansi(_ red: Int, _ green: Int, _ blue: Int) -> SwiftTerm.Color {
        SwiftTerm.Color(
            red: UInt16(red * 257),
            green: UInt16(green * 257),
            blue: UInt16(blue * 257)
        )
    }

    /// 16-color ANSI palette leaning cyan to match the dashboard accent.
    static let ansiPalette: [SwiftTerm.Color] = [
        ansi(0x12, 0x18, 0x20), // black
        ansi(0xff, 0x5c, 0x57), // red
        ansi(0x5a, 0xf7, 0x8e), // green
        ansi(0xf3, 0xf9, 0x9d), // yellow
        ansi(0x57, 0xc7, 0xff), // blue
        ansi(0xc7, 0x92, 0xea), // magenta
        ansi(0x62, 0xe4, 0xf4), // cyan
        ansi(0xd8, 0xe2, 0xe8), // white
        ansi(0x3a, 0x4a, 0x55), // bright black
        ansi(0xff, 0x8a, 0x85), // bright red
        ansi(0x8a, 0xfa, 0xb0), // bright green
        ansi(0xf7, 0xfb, 0xc0), // bright yellow
        ansi(0x8f, 0xd8, 0xff), // bright blue
        ansi(0xdb, 0xb5, 0xf5), // bright magenta
        ansi(0x9a, 0xed, 0xfe), // bright cyan
        ansi(0xf4, 0xf8, 0xfa)  // bright white
    ]

    static func apply(to view: LocalProcessTerminalView, fontSize: CGFloat) {
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = foreground
        view.caretColor = caret
        view.installColors(ansiPalette)
        view.font = font(size: fontSize)
    }
}


// MARK: - Terminal view

/// The session's terminal view. The only addition to SwiftTerm's view is a
/// one-shot hook on the first byte ssh delivers: until then the session is
/// "connecting", not "running". A master that still passes `-O check` but
/// carries no traffic (after a sleep or a VPN drop) would otherwise show a
/// blank terminal under a green "running" pill for minutes.
final class HPCTerminalView: LocalProcessTerminalView {
    var onFirstData: (() -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        if let callback = onFirstData {
            onFirstData = nil
            callback()
        }
    }
}

// MARK: - Delegate adapter

/// Bridges SwiftTerm's nonisolated delegate callbacks back to the MainActor.
/// Signatures mirror the proven Swift 6 spike.
@MainActor
private final class TerminalProcessDelegateAdapter: NSObject, LocalProcessTerminalViewDelegate {
    private let onExit: @Sendable (Int32?) -> Void

    init(onExit: @escaping @Sendable (Int32?) -> Void) {
        self.onExit = onExit
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        onExit(exitCode)
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}

// MARK: - Exit status

/// Decoded child exit status. SwiftTerm forwards the raw `waitpid` status,
/// so a remote `exit 255` arrives as 65280 and a signal death hides in the
/// low bits — decode before anything user-facing stores or shows it.
enum TerminalExitStatus: Equatable {
    case code(Int32)
    case signal(Int32)

    init(rawWaitStatus raw: Int32) {
        if raw & 0x7f == 0 {
            self = .code((raw >> 8) & 0xff)
        } else {
            self = .signal(raw & 0x7f)
        }
    }

    /// Raw, unexplained form for tooltips: "exit status 255", "signal 9".
    var label: String {
        switch self {
        case .code(let code):
            return "exit status \(code)"
        case .signal(let number):
            return "signal \(number)"
        }
    }
}

/// How a session's status reads in its pill and status bar. One mapping, so
/// the pill and the bar can never disagree, and testable without a view:
/// a quick command that finished normally is "done", not a red failure, and
/// ssh's own 255 is explained as a connection problem rather than shown as
/// a bare number.
struct TerminalStatusPresentation: Equatable {
    enum Tone: Equatable {
        /// Connected and working.
        case live
        /// Launching: pre-flight running or no byte from ssh yet.
        case progress
        /// Ended normally; nothing to worry about.
        case neutral
        /// The connection is the problem, not the command.
        case warning
        /// The command itself failed or was killed.
        case failure
    }

    /// Pill and status-bar text: "running", "done", "SSH connection closed".
    let label: String
    let tone: Tone
    let systemImage: String
    /// The status bar's button ("Run again", "Restart", "Retry"); nil while
    /// ssh is alive.
    let actionTitle: String?
    /// One-sentence explanation for tooltips and VoiceOver.
    let help: String
}

// MARK: - Session

/// One SSH terminal session on one cluster: a live terminal view plus what
/// is needed to restart it after exit. Owned by that cluster's
/// `TerminalManager`; the view survives tab and cluster switches because the
/// session object does.
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    enum Kind: Equatable {
        case shell
        case tail(jobId: String)
        case command(String)
    }

    enum Status: Equatable {
        /// ssh is being launched: the master pre-flight is running, or ssh
        /// started but has not delivered a single byte yet.
        case connecting
        /// ssh delivered output: the session is connected.
        case running
        case exited(TerminalExitStatus?)
        /// The pre-flight found no live ControlMaster for this cluster, so
        /// ssh was never launched. Distinct from `.exited` so the UI can say
        /// "not connected" and offer a retry instead of a bare exit code.
        case sessionUnavailable

        /// The ssh child is alive or about to be: what closing the tab, a
        /// reconnect or quitting the app would end, and what counts against
        /// the cluster connection's session budget.
        var isRunning: Bool {
            self == .running || self == .connecting
        }

        func presentation(kind: Kind, clusterName: String) -> TerminalStatusPresentation {
            let isShell = kind == .shell
            let again = isShell ? "Reopen" : "Run again"
            switch self {
            case .connecting:
                return TerminalStatusPresentation(
                    label: "connecting…",
                    tone: .progress,
                    systemImage: "ellipsis.circle",
                    actionTitle: nil,
                    help: "Opening a session over \(clusterName)'s existing SSH connection."
                )
            case .running:
                return TerminalStatusPresentation(
                    label: "running",
                    tone: .live,
                    systemImage: "circle.fill",
                    actionTitle: nil,
                    help: "Connected to \(clusterName)."
                )
            case .sessionUnavailable:
                return TerminalStatusPresentation(
                    label: "\(clusterName) not connected",
                    tone: .warning,
                    systemImage: "bolt.horizontal.circle",
                    actionTitle: "Retry",
                    help: "No live SSH session for \(clusterName) was found, so ssh was not started. "
                        + "Use Connect for \(clusterName) in the sidebar, then Retry."
                )
            case .exited(.code(0)?):
                return TerminalStatusPresentation(
                    label: isShell ? "closed" : "done",
                    tone: .neutral,
                    systemImage: "checkmark.circle",
                    actionTitle: again,
                    help: isShell
                        ? "The shell on \(clusterName) ended normally."
                        : "The command finished successfully on \(clusterName)."
                )
            case .exited(.code(130)?):
                // 128 + SIGINT: the user pressed Control-C (e.g. to stop a
                // tail) — an ordinary way to end, not a failure.
                return TerminalStatusPresentation(
                    label: "interrupted",
                    tone: .neutral,
                    systemImage: "stop.circle",
                    actionTitle: again,
                    help: "Stopped with Control-C on \(clusterName)."
                )
            case .exited(.code(255)?):
                return TerminalStatusPresentation(
                    label: "SSH connection closed",
                    tone: .warning,
                    systemImage: "bolt.slash.fill",
                    actionTitle: "Restart",
                    help: "ssh ended with status 255: the connection to \(clusterName), or its shared session, "
                        + "failed or refused a new session. If \(clusterName) still shows as live, Restart; "
                        + "otherwise use Connect first."
                )
            case .exited(.code(let code)?):
                return TerminalStatusPresentation(
                    label: "exited (\(code))",
                    tone: .failure,
                    systemImage: "xmark.octagon",
                    actionTitle: isShell ? "Restart" : again,
                    help: "The remote \(isShell ? "shell" : "command") ended with exit status \(code)."
                )
            case .exited(.signal(let number)?):
                return TerminalStatusPresentation(
                    label: "killed (signal \(number))",
                    tone: .failure,
                    systemImage: "xmark.octagon",
                    actionTitle: "Restart",
                    help: "The local ssh process was ended by signal \(number)."
                )
            case .exited(nil):
                return TerminalStatusPresentation(
                    label: "ended",
                    tone: .neutral,
                    systemImage: "stop.circle",
                    actionTitle: "Restart",
                    help: "The ssh session ended."
                )
            }
        }
    }

    let id = UUID()
    let kind: Kind
    /// The cluster this session runs on. A session never moves between
    /// clusters: a Calder job's log or a /scratch-calder directory does not
    /// exist on AIRE, and Slurm job ids repeat across clusters.
    let clusterID: ClusterID
    /// Display name used in text printed into the terminal itself.
    let clusterName: String
    @Published var title: String
    @Published private(set) var status: Status = .connecting
    /// Still connecting after the backend's `stallHintDelay`: the shared
    /// master most likely passes `-O check` but carries no traffic.
    @Published private(set) var isConnectionStalled = false

    var isRunning: Bool { status.isRunning }

    /// A connected shell that can receive typed quick commands.
    var isLiveShell: Bool {
        kind == .shell && status == .running
    }

    /// Whether closing this tab could lose work: a connected shell or
    /// command (an unsaved vim buffer, an `srun --pty` allocation). A tail
    /// only follows a log, and a session that never connected holds nothing.
    var closingEndsWork: Bool {
        guard status == .running else {
            return false
        }
        if case .tail = kind {
            return false
        }
        return true
    }

    var statusPresentation: TerminalStatusPresentation {
        status.presentation(kind: kind, clusterName: clusterName)
    }

    let terminalView: HPCTerminalView
    /// The remote command (nil for a login shell). Kept apart from the
    /// connection settings so a restart can rebuild the connection half
    /// from the cluster's current settings (e.g. after a route change) while
    /// re-running exactly the same command.
    private let remoteCommand: String?
    private var settings: ConnectionSettings
    private let environment: [String]
    private let backend: TerminalSessionBackend
    private var delegateAdapter: TerminalProcessDelegateAdapter?
    /// Set once the session is closed, so a pre-flight still in flight can
    /// never launch an ssh child into a session nobody can see or close.
    private var isClosed = false
    /// Bumped on every start, so a pre-flight or stall timer belonging to an
    /// earlier attempt can never act on a later one.
    private var attempt = 0

    /// The full ssh argv this session launches with its current settings.
    var arguments: [String] {
        SSHTerminalCommand.terminalArguments(settings: settings, remoteCommand: remoteCommand)
    }

    init(
        kind: Kind,
        title: String,
        remoteCommand: String?,
        settings: ConnectionSettings,
        fontSize: CGFloat,
        backend: TerminalSessionBackend = .live
    ) {
        self.kind = kind
        self.title = title
        self.clusterID = settings.clusterID
        self.clusterName = settings.clusterName
        self.remoteCommand = remoteCommand
        self.settings = settings
        self.backend = backend
        self.environment = SSHTerminalCommand.environment()
        self.terminalView = HPCTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        TerminalTheme.apply(to: terminalView, fontSize: fontSize)

        let adapter = TerminalProcessDelegateAdapter { [weak self] exitCode in
            Task { @MainActor in
                self?.processDidExit(rawWaitStatus: exitCode)
            }
        }
        delegateAdapter = adapter
        terminalView.processDelegate = adapter
    }

    /// Pre-flights this cluster's ControlMaster (a dead master would
    /// otherwise make ssh silently dial the host directly, bypassing the
    /// jump host and prompting nobody), then launches ssh. The session stays
    /// "connecting" until ssh delivers its first byte.
    func start() {
        guard !isClosed else {
            return
        }
        attempt += 1
        let currentAttempt = attempt
        status = .connecting
        isConnectionStalled = false
        let settings = self.settings
        let masterIsAlive = backend.masterIsAlive
        Task { [weak self] in
            let alive = await masterIsAlive(settings)
            guard let self, !self.isClosed, self.attempt == currentAttempt else {
                return
            }
            if alive {
                self.launch(attempt: currentAttempt)
            } else {
                let name = self.clusterName
                self.terminalView.feed(
                    text: "\u{1b}[31m\(name) SSH session is not running — "
                        + "use Connect for \(name) in the sidebar first.\u{1b}[0m\r\n"
                )
                self.status = .sessionUnavailable
            }
        }
    }

    private func launch(attempt currentAttempt: Int) {
        terminalView.onFirstData = { [weak self] in
            guard let self, self.attempt == currentAttempt, self.status == .connecting else {
                return
            }
            self.isConnectionStalled = false
            self.status = .running
        }
        backend.launch(terminalView, arguments, environment)
        let stallDelay = UInt64(max(backend.stallHintDelay, 0) * 1_000_000_000)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: stallDelay)
            guard let self, !self.isClosed, self.attempt == currentAttempt, self.status == .connecting else {
                return
            }
            self.isConnectionStalled = true
        }
    }

    /// The ssh child exited (SwiftTerm's raw wait status, decoded here).
    func processDidExit(rawWaitStatus: Int32?) {
        terminalView.onFirstData = nil
        isConnectionStalled = false
        status = .exited(rawWaitStatus.map { TerminalExitStatus(rawWaitStatus: $0) })
    }

    /// Re-runs the same command in the same view. With `settings` for this
    /// session's cluster, the ssh connection is rebuilt from them first, so
    /// a restart after a route or host change targets the master that is
    /// live now instead of the socket the session was first opened on.
    /// Settings for another cluster are ignored rather than trusted.
    func restart(using settings: ConnectionSettings? = nil) {
        guard !isRunning, !isClosed else {
            return
        }
        if let settings, settings.clusterID == clusterID {
            self.settings = settings
        }
        terminalView.feed(text: "\r\n\u{1b}[2m[restarting ssh session on \(clusterName)]\u{1b}[0m\r\n")
        start()
    }

    /// Marks the session closed and stops its ssh child.
    func close() {
        isClosed = true
        terminalView.onFirstData = nil
        terminateIfRunning()
    }

    /// Terminates the child ssh so closing a session never leaves a zombie.
    /// SwiftTerm's `terminate()` cancels its exit monitor before the SIGTERM
    /// is delivered, so nothing in SwiftTerm ever reaps the child — do it
    /// ourselves off the main thread (waitpid returns as soon as ssh exits).
    func terminateIfRunning() {
        guard terminalView.process.running else {
            return
        }
        let pid = terminalView.process.shellPid
        terminalView.terminate()
        guard pid > 0 else {
            return
        }
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
    }

    /// Types text into the terminal as if entered by the user.
    func send(_ text: String) {
        terminalView.send(txt: text)
    }
}

// MARK: - Quick-command routing

/// What the quick-command router needs to know about a session. A protocol
/// so the routing rules can be tested with plain values, without a pty.
@MainActor
protocol TerminalRoutingTarget {
    var id: UUID { get }
    var kind: TerminalSession.Kind { get }
    var clusterID: ClusterID { get }
    var status: TerminalSession.Status { get }
    /// The ssh child is alive. SwiftTerm silently drops bytes sent to a dead
    /// one, and the status lags the child by one main-loop hop.
    var acceptsInput: Bool { get }
    /// A full-screen program (vim, less, htop, a pager) owns the screen:
    /// typed text would land in it as raw keystrokes.
    var isShowingFullScreenProgram: Bool { get }
}

extension TerminalSession: TerminalRoutingTarget {
    var acceptsInput: Bool {
        terminalView.process.running
    }

    var isShowingFullScreenProgram: Bool {
        terminalView.getTerminal().isCurrentBufferAlternate
    }
}

enum TerminalQuickCommandRoute: Equatable {
    /// Type the command into this connected shell.
    case type(into: UUID)
    /// A dedicated tab for this command is still running (e.g. htop): show it.
    case focus(UUID)
    /// A dedicated tab for this command has finished: re-run it in place.
    case restart(UUID)
    /// Open a new dedicated tab.
    case open
}

/// Decides where a quick-command chip runs.
///
/// Typing into the active shell keeps the output next to the user's own
/// work, but only when that is safe: the shell is on the chip's cluster
/// (a Calder `squeue` can never land in an AIRE shell), connected, its ssh
/// child alive, and no full-screen program owns the screen — in vim the
/// text `squeue --me` would be executed as editing commands. A program the
/// user runs in the normal screen (a REPL, a long command) cannot be seen
/// from here; the clear-line prefix at least keeps a half-typed command
/// line from being glued to the chip's text.
///
/// Otherwise the chip reuses its own tab — focusing it while it runs,
/// re-running it once finished — so repeated clicks never pile up dead,
/// identically named tabs. Full-screen chips (htop) always use their own tab.
enum TerminalQuickCommandRouter {
    /// Control-E then Control-U: move to the end of the line and erase it.
    /// In bash the erased text goes to the kill ring (Control-Y restores
    /// it); zsh's ^U clears the whole line.
    static let clearLinePrefix = "\u{05}\u{15}"

    @MainActor
    static func route(
        command: String,
        prefersDedicatedSession: Bool,
        clusterID: ClusterID,
        active: (any TerminalRoutingTarget)?,
        sessions: [any TerminalRoutingTarget]
    ) -> TerminalQuickCommandRoute {
        if !prefersDedicatedSession,
           let active,
           active.clusterID == clusterID,
           active.kind == .shell,
           active.status == .running,
           active.acceptsInput,
           !active.isShowingFullScreenProgram {
            return .type(into: active.id)
        }
        if let existing = sessions.last(where: { $0.kind == .command(command) && $0.clusterID == clusterID }) {
            return existing.status.isRunning ? .focus(existing.id) : .restart(existing.id)
        }
        return .open
    }

    /// The keystrokes typed into a shell for `command`.
    static func keystrokes(for command: String) -> String {
        clearLinePrefix + command + "\n"
    }
}

// MARK: - Manager

/// Something the terminal tab must tell the user instead of starting ssh.
enum TerminalNotice: Equatable {
    /// `TerminalManager.maxConcurrentSessions` tabs already hold a session
    /// on the cluster's shared connection.
    case sessionLimit(limit: Int)
}

/// Owns one cluster's terminal sessions. Every `ClusterSession` holds its
/// own manager (`session.terminals`), so AIRE and Calder shells are kept
/// apart and survive both tab switches and switching clusters in the
/// sidebar. Every entry point takes that cluster's `ConnectionSettings`.
@MainActor
final class TerminalManager: ObservableObject {
    /// sshd's `MaxSessions` on the clusters, taken as OpenSSH's default of
    /// 10 (the login nodes do not advertise it, so the budget assumes the
    /// default). It caps the sessions (shells, commands, scp) one connection
    /// carries at once, and every ssh or scp the app runs is a session on
    /// that cluster's single ControlMaster. Past it the server refuses the
    /// new channel: a terminal dies with 255 and a transfer or listing fails.
    static let serverSessionLimit = 10

    /// Sessions the rest of the app needs on the same master at its busiest
    /// steady state: one collector refresh (one ssh per snapshot), one file
    /// browser command (a listing, preview or trash step) and
    /// `FileActivity.maxConcurrentTransfers` scp transfers. The master
    /// itself holds none, since it is started with -N, and there is no
    /// keepalive client any more. Short extra commands (an upload's size
    /// probe, a job action, a detached-job poll) can still overshoot for a
    /// moment; ClusterSession reads such a refusal as a busy master, not a
    /// disconnect, and the next refresh retries.
    static let reservedAppSessions = 1 + 1 + FileActivity.maxConcurrentTransfers

    /// Running tabs allowed per cluster: whatever `serverSessionLimit`
    /// leaves after `reservedAppSessions` (10 - 4 = 6), so a seventh tab
    /// gets the notice instead of a 255, and a full row of terminals can
    /// never starve the collector into a false disconnect.
    static let maxConcurrentSessions = serverSessionLimit - reservedAppSessions

    @Published private(set) var sessions: [TerminalSession] = []
    @Published var activeSessionID: UUID?
    @Published private(set) var fontSize: CGFloat
    @Published private(set) var notice: TerminalNotice?

    /// Text size is a reading preference of the person, not of a cluster:
    /// zooming in on Calder and then switching to AIRE should not snap the
    /// text back. Every manager adopts this when shown or when it opens a
    /// session. In memory only, like the per-manager size it replaces.
    private static var sharedFontSize = TerminalTheme.defaultFontSize

    private var shellCounter = 0
    private let backend: TerminalSessionBackend

    init(backend: TerminalSessionBackend = .live) {
        self.backend = backend
        fontSize = Self.sharedFontSize
    }

    var activeSession: TerminalSession? {
        sessions.first { $0.id == activeSessionID } ?? sessions.last
    }

    /// Tabs whose ssh is alive or launching on this cluster.
    var runningSessionCount: Int {
        sessions.filter(\.isRunning).count
    }

    var hasCapacityForNewSession: Bool {
        runningSessionCount < Self.maxConcurrentSessions
    }

    /// Running log tails: the tabs most likely kept open by accident, since
    /// `tail -F` never ends on its own.
    var runningTailSessions: [TerminalSession] {
        sessions.filter { session in
            guard case .tail = session.kind else {
                return false
            }
            return session.isRunning
        }
    }

    /// Opens an interactive shell, optionally landing in `startDirectory`.
    /// The directory name is remote-controlled data (file browser listings),
    /// so it is single-quoted before interpolation; after the `cd` the
    /// command replaces itself with a login shell, making the session
    /// indistinguishable from a plain shell (quick-command chips still work).
    /// nil when the session budget is used up (see `notice`).
    @discardableResult
    func openShell(settings: ConnectionSettings, startDirectory: String? = nil) -> TerminalSession? {
        let number = shellCounter + 1
        let title = number == 1 ? "shell" : "shell \(number)"
        let remoteCommand = startDirectory.map { directory in
            "cd \(SSHTerminalCommand.shellQuote(directory)) 2>/dev/null; exec $SHELL -l"
        }
        let session = open(kind: .shell, title: title, remoteCommand: remoteCommand, settings: settings)
        if session != nil {
            shellCounter = number
        }
        return session
    }

    /// Follows a job's stdout. The path only exists on the job's own cluster
    /// (a Calder job writes under /scratch-calder), so callers pass that
    /// cluster's settings; the title needs no cluster prefix because this
    /// manager only ever holds one cluster's sessions. Tailing the same job
    /// again reuses its tab.
    func openTail(job: Job, settings: ConnectionSettings) {
        // The pending remainder of an array has no output file of its own
        // (its path ends in the NO_VAL task id), so -F would wait forever.
        guard !job.isArrayRemainder, let path = job.stdoutPath, !path.isEmpty else {
            return
        }
        let kind = TerminalSession.Kind.tail(jobId: job.jobId)
        if let existing = sessions.last(where: { $0.kind == kind && $0.clusterID == settings.clusterID }) {
            activeSessionID = existing.id
            restart(existing, settings: settings)
            return
        }
        // -F (follow by name, retry): Slurm resolves the stdout path at
        // submit time, so a pending job's file may not exist yet — wait for
        // it instead of exiting instantly with "No such file or directory".
        let command = "tail -n 200 -F \(SSHTerminalCommand.shellQuote(path))"
        open(kind: kind, title: "tail \(job.jobId)", remoteCommand: command, settings: settings)
    }

    @discardableResult
    func open(command: String, title: String, settings: ConnectionSettings) -> TerminalSession? {
        open(kind: .command(command), title: title, remoteCommand: command, settings: settings)
    }

    /// Activates an existing live shell on this cluster, opening one only
    /// when none exists.
    @discardableResult
    func focusOrOpenShell(settings: ConnectionSettings) -> TerminalSession? {
        if let shell = sessions.last(where: { $0.isLiveShell && $0.clusterID == settings.clusterID }) {
            activeSessionID = shell.id
            return shell
        }
        return openShell(settings: settings)
    }

    /// Runs a quick-command chip where `TerminalQuickCommandRouter` decides:
    /// typed into the active shell when that is safe, otherwise in the
    /// chip's own (reused) tab.
    func runQuickCommand(
        _ command: String,
        title: String,
        settings: ConnectionSettings,
        prefersDedicatedSession: Bool = false
    ) {
        let route = TerminalQuickCommandRouter.route(
            command: command,
            prefersDedicatedSession: prefersDedicatedSession,
            clusterID: settings.clusterID,
            active: activeSession,
            sessions: sessions
        )
        switch route {
        case .type(let id):
            guard let shell = session(id) else {
                return
            }
            activeSessionID = id
            shell.send(TerminalQuickCommandRouter.keystrokes(for: command))
        case .focus(let id):
            activeSessionID = id
        case .restart(let id):
            guard let existing = session(id) else {
                return
            }
            activeSessionID = id
            restart(existing, settings: settings)
        case .open:
            open(command: command, title: title, settings: settings)
        }
    }

    func close(_ session: TerminalSession) {
        session.close()
        sessions.removeAll { $0.id == session.id }
        if activeSessionID == session.id {
            activeSessionID = sessions.last?.id
        }
        if hasCapacityForNewSession {
            notice = nil
        }
    }

    /// Frees sessions on the shared connection by closing every running
    /// log tail (nothing is lost: the log stays on the cluster).
    func closeRunningTails() {
        for tail in runningTailSessions {
            close(tail)
        }
    }

    /// Restarts an exited session; pass the cluster's current settings so
    /// the restart follows a route or host change made since it opened.
    /// Refused, with a notice, when the session budget is used up.
    func restart(_ session: TerminalSession, settings: ConnectionSettings? = nil) {
        guard !session.isRunning else {
            return
        }
        guard hasCapacityForNewSession else {
            notice = .sessionLimit(limit: Self.maxConcurrentSessions)
            return
        }
        notice = nil
        session.restart(using: settings)
    }

    func dismissNotice() {
        notice = nil
    }

    /// Steps from the shared size (not this manager's copy), so a step is
    /// always relative to what the person last chose, on any cluster.
    func adjustFontSize(by delta: CGFloat) {
        let next = min(
            max(Self.sharedFontSize + delta, TerminalTheme.fontSizeRange.lowerBound),
            TerminalTheme.fontSizeRange.upperBound
        )
        Self.sharedFontSize = next
        applyFontSize(next)
    }

    /// Catches up with a text size chosen while another cluster's terminal
    /// was on screen. Cheap no-op when already in sync.
    func adoptSharedFontSize() {
        applyFontSize(Self.sharedFontSize)
    }

    private func applyFontSize(_ size: CGFloat) {
        guard size != fontSize else {
            return
        }
        fontSize = size
        for session in sessions {
            session.terminalView.font = TerminalTheme.font(size: size)
        }
    }

    private func session(_ id: UUID) -> TerminalSession? {
        sessions.first { $0.id == id }
    }

    /// Creates and starts a session, unless this cluster already has
    /// `maxConcurrentSessions` running: then nothing is launched and
    /// `notice` explains why, instead of a tab that dies with "exited (255)"
    /// and a collector refresh that is refused alongside it.
    @discardableResult
    private func open(
        kind: TerminalSession.Kind,
        title: String,
        remoteCommand: String?,
        settings: ConnectionSettings
    ) -> TerminalSession? {
        guard hasCapacityForNewSession else {
            notice = .sessionLimit(limit: Self.maxConcurrentSessions)
            return nil
        }
        notice = nil
        adoptSharedFontSize()
        let session = TerminalSession(
            kind: kind,
            title: title,
            remoteCommand: remoteCommand,
            settings: settings,
            fontSize: fontSize,
            backend: backend
        )
        sessions.append(session)
        activeSessionID = session.id
        session.start()
        return session
    }
}
