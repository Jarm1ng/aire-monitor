import AppKit
import Foundation
import SwiftTerm

// MARK: - SSH argument building

/// Builds `/usr/bin/ssh` invocations that reuse the app's 24h ControlMaster
/// session. Nothing here ever handles a password: BatchMode suppresses every
/// prompt. Note that a dead or missing master does NOT make ssh fail fast —
/// OpenSSH silently falls back to a direct, un-jumped connection — which is
/// why explicit-mode sessions pre-flight the master with `ssh -O check`
/// (`masterIsRunning`) before launching.
enum SSHTerminalCommand {
    /// The explicit-mode ControlMaster socket to verify before launching ssh.
    struct MasterCheck {
        let controlPath: String
        let host: String
    }

    /// Wraps a value in single quotes for safe interpolation into a remote
    /// shell command (`'` becomes `'\''`).
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Arguments for an interactive PTY session (`ssh -tt …`), optionally
    /// running a remote command instead of a login shell.
    static func terminalArguments(settings: ServerSettings, remoteCommand: String? = nil) -> [String] {
        var arguments = ["-tt"]
        if settings.useSSHAlias {
            arguments.append(settings.sshAlias)
        } else {
            arguments.append(contentsOf: [
                "-S", settings.controlPath,
                "-o", "User=\(settings.username)",
                "-o", "BatchMode=yes",
                "-o", "PasswordAuthentication=no",
                "-o", "KbdInteractiveAuthentication=no",
                // A dead master silently falls back to a direct connection;
                // bound that connect attempt instead of hanging until the
                // kernel TCP timeout (~75s) on an unreachable login node.
                "-o", "ConnectTimeout=5",
                settings.aireHostname
            ])
        }
        if let remoteCommand, !remoteCommand.isEmpty {
            arguments.append(remoteCommand)
        }
        return arguments
    }

    /// Runs `ssh -O check` against the ControlMaster socket. Both a missing
    /// and a dead socket fail in milliseconds, whereas launching plain ssh in
    /// that state silently dials the host directly, bypassing the jump host.
    static func masterIsRunning(_ check: MasterCheck) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-S", check.controlPath, "-O", "check", check.host]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
            }
        }
    }

    /// Child environment: the inherited environment plus a UTF-8 locale and a
    /// terminal type SwiftTerm renders faithfully.
    static func environment() -> [String] {
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "en_US.UTF-8"
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        return environment.map { "\($0.key)=\($0.value)" }
    }
}

// MARK: - Terminal appearance

/// Dark, cyan-tinted terminal styling matching the app's glass language.
/// Terminals stay dark in both app appearances by convention.
@MainActor
enum TerminalTheme {
    static let defaultFontSize: CGFloat = 13
    static let fontSizeRange: ClosedRange<CGFloat> = 9...22

    /// Near-black with a cold blue-cyan cast, close to AIRETheme glass in dark mode.
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

// MARK: - Session

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

    var label: String {
        switch self {
        case .code(let code):
            return "exited (\(code))"
        case .signal(let number):
            return "signal \(number)"
        }
    }
}

/// One SSH terminal session: a live `LocalProcessTerminalView` plus the
/// arguments needed to restart it after exit. Owned by `TerminalManager`;
/// the view survives tab switches because the session object does.
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    enum Kind: Equatable {
        case shell
        case tail(jobId: String)
        case command(String)
    }

    enum Status: Equatable {
        case running
        case exited(TerminalExitStatus?)
    }

    let id = UUID()
    let kind: Kind
    @Published var title: String
    @Published private(set) var status: Status = .running

    let terminalView: LocalProcessTerminalView
    private let arguments: [String]
    private let environment: [String]
    private let masterCheck: SSHTerminalCommand.MasterCheck?
    private var delegateAdapter: TerminalProcessDelegateAdapter?

    /// A shell that can receive typed quick commands right now.
    var isLiveShell: Bool {
        kind == .shell && status == .running
    }

    init(
        kind: Kind,
        title: String,
        arguments: [String],
        fontSize: CGFloat,
        masterCheck: SSHTerminalCommand.MasterCheck? = nil
    ) {
        self.kind = kind
        self.title = title
        self.arguments = arguments
        self.environment = SSHTerminalCommand.environment()
        self.masterCheck = masterCheck
        self.terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        TerminalTheme.apply(to: terminalView, fontSize: fontSize)

        let adapter = TerminalProcessDelegateAdapter { [weak self] exitCode in
            Task { @MainActor in
                self?.status = .exited(exitCode.map { TerminalExitStatus(rawWaitStatus: $0) })
            }
        }
        delegateAdapter = adapter
        terminalView.processDelegate = adapter
    }

    /// Pre-flights the ControlMaster in explicit mode (a dead master would
    /// otherwise make ssh silently dial the host directly, bypassing the
    /// jump host), then launches ssh.
    func start() {
        status = .running
        guard let masterCheck else {
            launch()
            return
        }
        Task { [weak self] in
            let alive = await SSHTerminalCommand.masterIsRunning(masterCheck)
            guard let self else {
                return
            }
            if alive {
                self.launch()
            } else {
                self.terminalView.feed(
                    text: "\u{1b}[31mSSH master is not running — reconnect from the app first.\u{1b}[0m\r\n"
                )
                self.status = .exited(nil)
            }
        }
    }

    private func launch() {
        terminalView.startProcess(
            executable: "/usr/bin/ssh",
            args: arguments,
            environment: environment
        )
    }

    /// Re-runs the exact same ssh invocation in the same view.
    func restart() {
        guard case .exited = status else {
            return
        }
        terminalView.feed(text: "\r\n\u{1b}[2m[restarting ssh session]\u{1b}[0m\r\n")
        start()
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

// MARK: - Manager

/// Owns every terminal session for the app. Held as a `@StateObject` in
/// `ContentView`, so sessions and their ssh processes survive tab switches.
@MainActor
final class TerminalManager: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var activeSessionID: UUID?
    @Published private(set) var fontSize: CGFloat = TerminalTheme.defaultFontSize

    private var shellCounter = 0

    var activeSession: TerminalSession? {
        sessions.first { $0.id == activeSessionID } ?? sessions.last
    }

    /// Opens an interactive shell, optionally landing in `startDirectory`.
    /// The directory name is remote-controlled data (file browser listings),
    /// so it is single-quoted before interpolation; after the `cd` the
    /// command replaces itself with a login shell, making the session
    /// indistinguishable from a plain shell (quick-command chips still work).
    @discardableResult
    func openShell(settings: ServerSettings, startDirectory: String? = nil) -> TerminalSession {
        shellCounter += 1
        let title = shellCounter == 1 ? "shell" : "shell \(shellCounter)"
        let remoteCommand = startDirectory.map { directory in
            "cd \(SSHTerminalCommand.shellQuote(directory)) 2>/dev/null; exec $SHELL -l"
        }
        return open(kind: .shell, title: title, remoteCommand: remoteCommand, settings: settings)
    }

    func openTail(job: Job, settings: ServerSettings) {
        guard let path = job.stdoutPath, !path.isEmpty else {
            return
        }
        // -F (follow by name, retry): Slurm resolves the stdout path at
        // submit time, so a pending job's file may not exist yet — wait for
        // it instead of exiting instantly with "No such file or directory".
        let command = "tail -n 200 -F \(SSHTerminalCommand.shellQuote(path))"
        open(
            kind: .tail(jobId: job.jobId),
            title: "tail \(job.jobId)",
            remoteCommand: command,
            settings: settings
        )
    }

    @discardableResult
    func open(command: String, title: String, settings: ServerSettings) -> TerminalSession {
        open(kind: .command(command), title: title, remoteCommand: command, settings: settings)
    }

    /// Activates an existing live shell, opening one only when none exists.
    @discardableResult
    func focusOrOpenShell(settings: ServerSettings) -> TerminalSession {
        if let shell = sessions.last(where: { $0.isLiveShell }) {
            activeSessionID = shell.id
            return shell
        }
        return openShell(settings: settings)
    }

    /// Quick-command chips: type into the active live shell when it can
    /// actually accept keystrokes, otherwise run the command in a fresh
    /// dedicated session. Full-screen programs (htop) always get their own
    /// session — typing a later chip into them would land as raw keystrokes.
    /// The `process.running` gate also covers the window where the ssh child
    /// has died but the `.exited` status has not landed yet, in which case
    /// SwiftTerm would silently drop the sent bytes.
    func runQuickCommand(
        _ command: String,
        title: String,
        settings: ServerSettings,
        prefersDedicatedSession: Bool = false
    ) {
        if !prefersDedicatedSession,
           let active = activeSession,
           active.isLiveShell,
           active.terminalView.process.running {
            activeSessionID = active.id
            active.send(command + "\n")
            return
        }
        open(command: command, title: title, settings: settings)
    }

    func close(_ session: TerminalSession) {
        session.terminateIfRunning()
        sessions.removeAll { $0.id == session.id }
        if activeSessionID == session.id {
            activeSessionID = sessions.last?.id
        }
    }

    func restart(_ session: TerminalSession) {
        session.restart()
    }

    func adjustFontSize(by delta: CGFloat) {
        let next = min(
            max(fontSize + delta, TerminalTheme.fontSizeRange.lowerBound),
            TerminalTheme.fontSizeRange.upperBound
        )
        guard next != fontSize else {
            return
        }
        fontSize = next
        for session in sessions {
            session.terminalView.font = TerminalTheme.font(size: next)
        }
    }

    @discardableResult
    private func open(
        kind: TerminalSession.Kind,
        title: String,
        remoteCommand: String?,
        settings: ServerSettings
    ) -> TerminalSession {
        let arguments = SSHTerminalCommand.terminalArguments(
            settings: settings,
            remoteCommand: remoteCommand
        )
        let session = TerminalSession(
            kind: kind,
            title: title,
            arguments: arguments,
            fontSize: fontSize,
            masterCheck: settings.useSSHAlias
                ? nil
                : SSHTerminalCommand.MasterCheck(
                    controlPath: settings.controlPath,
                    host: settings.aireHostname
                )
        )
        sessions.append(session)
        activeSessionID = session.id
        session.start()
        return session
    }
}
