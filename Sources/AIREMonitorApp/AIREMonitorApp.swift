import HPCCore
import AppKit
import Darwin
import SwiftUI

/// The one AppModel of the running app. A static rather than App state so
/// the delegate, window presenter and menu bar share it, and so a second
/// evaluation of the App struct could never build a second set of sessions.
@MainActor
enum AppEnvironment {
    static let model = AppModel()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Monitoring (and the notification permission request, which fails
        // when made before launch completes) starts here, not in App.init.
        AppEnvironment.model.start()
        DashboardWindowPresenter.shared.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DashboardWindowPresenter.shared.show()
        return true
    }

    /// Like Terminal and iTerm: quitting with live shells asks first, since
    /// it ends every ssh session on every cluster (unsaved editor buffers,
    /// `srun --pty` allocations that may have queued for hours). Running
    /// file transfers and a sign-in in progress are named in the same one
    /// alert: quitting cancels them (partial files are cleaned up), which is
    /// safe but should not happen by accident.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppEnvironment.model
        let work = QuitConfirmation.Work(
            terminals: model.sessions.map { ($0.displayName, $0.terminals.sessions.filter(\.isRunning).count) },
            transfers: model.sessions.map { ($0.displayName, $0.files.activity.transfers.filter(\.isActive).count) },
            signingIn: model.isAnyLoginActive
        )
        guard let informativeText = QuitConfirmation.informativeText(for: work) else {
            return .terminateNow
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit Leeds HPC Monitor?"
        alert.informativeText = informativeText
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppEnvironment.model.prepareForTermination()
        SingleInstanceGuard.release()
    }
}

/// The wording of the quit confirmation: what quitting would end, per
/// cluster. nil when nothing would be lost, so quitting needs no alert.
enum QuitConfirmation {
    struct Work {
        /// (cluster name, running terminal tabs) per cluster.
        var terminals: [(cluster: String, count: Int)]
        /// (cluster name, waiting or running transfers) per cluster.
        var transfers: [(cluster: String, count: Int)]
        var signingIn: Bool
    }

    static func informativeText(for work: Work) -> String? {
        var details: [String] = []
        if let terminals = summary(work.terminals) {
            details.append(
                "\(terminals.total == 1 ? "A terminal session is" : "\(terminals.total) terminal sessions are") still running (\(terminals.parts)). Quitting ends \(terminals.total == 1 ? "it" : "them") and anything running inside."
            )
        }
        if let transfers = summary(work.transfers) {
            details.append(
                "\(transfers.total == 1 ? "A file transfer is" : "\(transfers.total) file transfers are") not finished (\(transfers.parts)). Quitting cancels \(transfers.total == 1 ? "it" : "them") and removes the partial \(transfers.total == 1 ? "file" : "files")."
            )
        }
        if work.signingIn {
            details.append("A sign-in in progress will be cancelled.")
        }
        return details.isEmpty ? nil : details.joined(separator: "\n\n")
    }

    /// "2 on AIRE, 1 on Calder" and the total, or nil when all are zero.
    private static func summary(_ counts: [(cluster: String, count: Int)]) -> (total: Int, parts: String)? {
        let nonZero = counts.filter { $0.count > 0 }
        guard !nonZero.isEmpty else {
            return nil
        }
        return (
            nonZero.reduce(0) { $0 + $1.count },
            nonZero.map { "\($0.count) on \($0.cluster)" }.joined(separator: ", ")
        )
    }
}

/// Gates the dashboard's SwiftUI tree: while the window is closed, or fully
/// hidden for a few seconds, the root shows an empty placeholder so model
/// changes stop re-rendering every job card of the last tab nobody can see.
@MainActor
final class DashboardRenderGate: ObservableObject {
    @Published var isRendering = true
}

private struct DashboardRootView: View {
    @ObservedObject var gate: DashboardRenderGate
    let model: AppModel

    var body: some View {
        if gate.isRendering {
            ContentView(model: model)
        } else {
            // Same minimum size as ContentView, so swapping never resizes
            // the window.
            Color(nsColor: .windowBackgroundColor)
                .frame(
                    minWidth: ContentView.minimumWindowSize.width,
                    minHeight: ContentView.minimumWindowSize.height
                )
        }
    }
}

@MainActor
final class DashboardWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = DashboardWindowPresenter()

    private static let frameAutosaveName = "AIREMonitorDashboardWindow"
    /// How long a fully covered (or minimised, or other-Space) window keeps
    /// rendering before the gate closes; brief occlusions never flicker.
    private static let occlusionGrace: TimeInterval = 5

    private var model: AppModel?
    private var window: NSWindow?
    private let renderGate = DashboardRenderGate()
    private var occlusionWork: DispatchWorkItem?

    private override init() {
        super.init()
    }

    func configure(model: AppModel) {
        self.model = model
    }

    func show() {
        guard let model else {
            return
        }

        NSApp.setActivationPolicy(.regular)
        let dashboardWindow = window ?? makeWindow(model: model)
        resumeRendering()
        if dashboardWindow.isMiniaturized {
            dashboardWindow.deminiaturize(nil)
        }
        dashboardWindow.orderFrontRegardless()
        dashboardWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow(model: AppModel) -> NSWindow {
        let hostingController = NSHostingController(rootView: DashboardRootView(gate: renderGate, model: model))
        let dashboardWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1220, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        dashboardWindow.title = "Leeds HPC Monitor"
        dashboardWindow.titlebarAppearsTransparent = true
        dashboardWindow.isReleasedWhenClosed = false
        dashboardWindow.contentViewController = hostingController
        dashboardWindow.delegate = self
        // Center only when there is no previously saved frame, so the user's
        // window position survives relaunches.
        if !dashboardWindow.setFrameUsingName(Self.frameAutosaveName) {
            dashboardWindow.center()
        }
        dashboardWindow.setFrameAutosaveName(Self.frameAutosaveName)
        window = dashboardWindow
        return dashboardWindow
    }

    private func resumeRendering() {
        occlusionWork?.cancel()
        occlusionWork = nil
        if !renderGate.isRendering {
            renderGate.isRendering = true
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        occlusionWork?.cancel()
        occlusionWork = nil
        renderGate.isRendering = false
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else {
            return
        }
        if window.occlusionState.contains(.visible) {
            resumeRendering()
            return
        }
        guard window.isVisible || window.isMiniaturized, occlusionWork == nil else {
            return
        }
        let work = DispatchWorkItem { [weak self, weak window] in
            MainActor.assumeIsolated {
                guard let self, let window else {
                    return
                }
                self.occlusionWork = nil
                if !window.occlusionState.contains(.visible) {
                    self.renderGate.isRendering = false
                }
            }
        }
        occlusionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.occlusionGrace, execute: work)
    }
}

/// One running copy per user. Two copies would each run both refresh loops,
/// post every notification twice, race on the cache files and could sign in
/// concurrently through the shared rash jump master that the serialized
/// login chain exists to protect. `open` and LaunchServices already refuse
/// a second copy of the bundle; `swift run` or the build-directory binary
/// do not, hence an flock on a per-user file outside the checkout (masters
/// and sockets are per user, not per checkout).
enum SingleInstanceGuard {
    nonisolated(unsafe) private static var lockDescriptor: Int32 = -1

    /// Returns normally when this is the only instance. Otherwise activates
    /// the running copy and exits before any session starts.
    @MainActor
    static func acquireOrExit() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LeedsHPCMonitor", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Log.app.error("Single-instance guard unavailable: \(error.localizedDescription, privacy: .public)")
            return
        }
        let path = directory.appendingPathComponent("app.lock").path
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            Log.app.error("Single-instance guard unavailable: open failed (errno \(errno, privacy: .public))")
            return
        }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            // Held (and the descriptor kept open) for the life of the process.
            lockDescriptor = descriptor
            return
        }
        close(descriptor)
        Log.app.info("Another Leeds HPC Monitor is already running; activating it and exiting")
        let identifier = Bundle.main.bundleIdentifier ?? "local.aire.monitor"
        let current = ProcessInfo.processInfo.processIdentifier
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != current }) {
            other.activate(options: [.activateAllWindows])
        } else {
            FileHandle.standardError.write(Data("Leeds HPC Monitor is already running.\n".utf8))
        }
        exit(0)
    }

    static func release() {
        guard lockDescriptor >= 0 else {
            return
        }
        flock(lockDescriptor, LOCK_UN)
        close(lockDescriptor)
        lockDescriptor = -1
    }
}

/// Selection mirror for the Go menu, so the menu re-renders only when the
/// selection changes — not on every model change, as it would if the App
/// observed the whole model.
@MainActor
final class GoMenuState: ObservableObject {
    @Published private(set) var selection: SidebarSelection

    init(model: AppModel) {
        selection = model.selection
        model.$selection
            .removeDuplicates()
            .assign(to: &$selection)
    }
}

/// Keyboard navigation: ⌘0 overview, ⌘1…⌘9 clusters in sidebar order,
/// ⌥⌘1…⌥⌘7 the selected cluster's tabs, ⌘[ back to the overview.
struct GoMenuCommands: View {
    let model: AppModel
    @ObservedObject var state: GoMenuState

    private var clusterSelected: Bool {
        if case .cluster = state.selection {
            return true
        }
        return false
    }

    var body: some View {
        Button("Overview") {
            go(to: .overview)
        }
        .keyboardShortcut("0", modifiers: .command)

        Divider()

        ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
            Button(session.displayName) {
                go(to: .cluster(session.id))
            }
            .keyboardShortcut(Self.digitShortcut(index, modifiers: .command))
        }

        Divider()

        ForEach(Array(DashboardTab.allCases.enumerated()), id: \.element) { index, tab in
            Button(tab.title) {
                model.selectedSession?.dashboard.selectedTab = tab
                DashboardWindowPresenter.shared.show()
            }
            .keyboardShortcut(Self.digitShortcut(index, modifiers: [.command, .option]))
            .disabled(!clusterSelected)
        }

        Divider()

        Button("Back to Overview") {
            go(to: .overview)
        }
        .keyboardShortcut("[", modifiers: .command)
        .disabled(!clusterSelected)
    }

    private func go(to selection: SidebarSelection) {
        model.selection = selection
        DashboardWindowPresenter.shared.show()
    }

    /// ⌘1…⌘9 (with `modifiers`); positions past nine get no shortcut.
    private static func digitShortcut(_ index: Int, modifiers: EventModifiers) -> KeyboardShortcut? {
        guard (0..<9).contains(index) else {
            return nil
        }
        return KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: modifiers)
    }
}

@MainActor
@main
struct AIREMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Not observed: the App's body only needs the model to build menu
    /// actions, and observing it would re-evaluate the scene and its menus
    /// on every refresh of every cluster.
    private let model: AppModel
    @StateObject private var goMenu: GoMenuState

    init() {
        SingleInstanceGuard.acquireOrExit()
        let model = AppEnvironment.model
        self.model = model
        _goMenu = StateObject(wrappedValue: GoMenuState(model: model))
        DashboardWindowPresenter.shared.configure(model: model)
        StatusBarMonitorController.shared.configure(model: model)
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            // Suppress the standard Settings menu item, which would otherwise
            // open a blank window.
            CommandGroup(replacing: .appSettings) {}
            CommandMenu("Go") {
                GoMenuCommands(model: model, state: goMenu)
            }
        }
    }
}
