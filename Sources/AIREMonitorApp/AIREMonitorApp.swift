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

    private var model: AppModel?
    private var window: NSWindow?
    private var needsShowAfterConfigure = false

    private init() {}

    func configure(model: AppModel) {
        self.model = model
        if needsShowAfterConfigure {
            needsShowAfterConfigure = false
            show()
        }
    }

    func show() {
        guard let model else {
            needsShowAfterConfigure = true
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
        dashboardWindow.title = "AIRE Monitor"
        dashboardWindow.titlebarAppearsTransparent = true
        dashboardWindow.isReleasedWhenClosed = false
        dashboardWindow.contentViewController = hostingController
        dashboardWindow.setFrameAutosaveName("AIREMonitorDashboardWindow")
        dashboardWindow.center()
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
        DispatchQueue.main.async {
            DashboardWindowPresenter.shared.show()
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
