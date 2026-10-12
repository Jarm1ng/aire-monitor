import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DashboardWindowPresenter.shared.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DashboardWindowPresenter.shared.show()
        return true
    }
}

@MainActor
final class DashboardWindowPresenter {
    static let shared = DashboardWindowPresenter()

    private static let frameAutosaveName = "AIREMonitorDashboardWindow"

    private var model: AppModel?
    private var window: NSWindow?

    private init() {}

    func configure(model: AppModel) {
        self.model = model
    }

    func show() {
        guard let model else {
            return
        }

        NSApp.setActivationPolicy(.regular)
        let dashboardWindow = window ?? makeWindow(model: model)
        if dashboardWindow.isMiniaturized {
            dashboardWindow.deminiaturize(nil)
        }
        dashboardWindow.orderFrontRegardless()
        dashboardWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow(model: AppModel) -> NSWindow {
        let hostingController = NSHostingController(rootView: ContentView(model: model))
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
        // Center only when there is no previously saved frame, so the user's
        // window position survives relaunches.
        if !dashboardWindow.setFrameUsingName(Self.frameAutosaveName) {
            dashboardWindow.center()
        }
        dashboardWindow.setFrameAutosaveName(Self.frameAutosaveName)
        window = dashboardWindow
        return dashboardWindow
    }
}

@MainActor
@main
struct AIREMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
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
        }
    }
}
