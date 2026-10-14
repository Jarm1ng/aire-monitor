import AppKit
import SwiftUI

// The widget's source is split by responsibility:
// - DesktopWidgetApp.swift   app entry point and the desktop-level window
// - WidgetModel.swift        cluster discovery, project root, app launching
// - ClusterFeed.swift        one cluster's data path (file, app lease, fallback)
// - WidgetFileReaders.swift  directory watching, preferences and app_state readers
// - ClusterDigest.swift      what one cluster row shows, from HPCCore's rules
// - DesktopWidgetView.swift  the window content: header, rows, footer
// - ClusterRow.swift         one cluster's row and the empty/error cards
// - WidgetComponents.swift   small reusable views (chips, meters, heatmap)
// - WidgetTheme.swift        layout constants, palette, cluster styling
// Domain rules (snapshot schema, job and node states, GPU accounting,
// timestamps, defaults) and the widget's own testable policies (app lease,
// fallback decisions, collector validation, the process runner) live in
// HPCCore, so the widget can never drift from the app again.

@main
struct DesktopWidgetApp: App {
    @NSApplicationDelegateAdaptor(WidgetAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            // The view sizes itself (its height depends on how many clusters
            // are monitored) and drives the window through its configurator.
            DesktopWidgetView()
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) { }
            CommandGroup(replacing: .newItem) { }
        }
    }
}

final class WidgetAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct DesktopWindowConfigurator: NSViewRepresentable {
    /// Current widget size; changes when a cluster appears or disappears.
    let contentSize: NSSize

    /// The frame this configurator last left the window in. SwiftUI may
    /// grow the window to fit a new cluster row before configure() runs,
    /// and it does not promise to keep the top edge; comparing against this
    /// frame tells such a resize apart from the user dragging the widget
    /// (a drag never changes the size).
    @MainActor
    final class Coordinator {
        var lastFrame: NSRect?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let size = contentSize
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            Self.configure(window: view.window, contentSize: size, coordinator: coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let size = contentSize
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            Self.configure(window: nsView.window, contentSize: size, coordinator: coordinator)
        }
    }

    /// Idempotent: runs on every SwiftUI update, so every assignment is
    /// guarded to avoid needless AppKit relayout/flicker.
    @MainActor
    private static func configure(window: NSWindow?, contentSize: NSSize, coordinator: Coordinator) {
        guard let window else {
            return
        }
        if window.title != "Leeds HPC Widget" {
            window.title = "Leeds HPC Widget"
        }
        if window.titleVisibility != .hidden {
            window.titleVisibility = .hidden
        }
        if !window.titlebarAppearsTransparent {
            window.titlebarAppearsTransparent = true
        }
        let styleMask: NSWindow.StyleMask = [.borderless, .fullSizeContentView]
        if window.styleMask != styleMask {
            window.styleMask = styleMask
        }
        if !window.isMovableByWindowBackground {
            window.isMovableByWindowBackground = true
        }
        if window.isOpaque {
            window.isOpaque = false
        }
        if window.backgroundColor != .clear {
            window.backgroundColor = .clear
        }
        if !window.hasShadow {
            window.hasShadow = true
        }
        let collectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        if window.collectionBehavior != collectionBehavior {
            window.collectionBehavior = collectionBehavior
        }
        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        if window.level != level {
            window.level = level
        }
        // Kept from the single-cluster widget so the user's chosen position
        // survives the upgrade; only the height changes.
        if window.frameAutosaveName != "AIREDesktopWidget" {
            window.setFrameAutosaveName("AIREDesktopWidget")
        }
        // Keep the top edge where the user put it, so adding a cluster grows
        // the widget downwards instead of shifting it up the desktop. If the
        // window was resized behind our back since the last pass (size and
        // top edge both changed), restore the top edge from that pass.
        let frame = window.frame
        var top = frame.maxY
        if let last = coordinator.lastFrame, last.size != frame.size, last.maxY != frame.maxY {
            top = last.maxY
        }
        if frame.size != contentSize || top != frame.maxY {
            let nextFrame = NSRect(
                x: frame.minX,
                y: top - contentSize.height,
                width: contentSize.width,
                height: contentSize.height
            )
            window.setFrame(nextFrame, display: true)
        }
        if window.minSize != contentSize {
            window.minSize = contentSize
        }
        if window.maxSize != contentSize {
            window.maxSize = contentSize
        }
        if window.contentMinSize != contentSize {
            window.contentMinSize = contentSize
        }
        if window.contentMaxSize != contentSize {
            window.contentMaxSize = contentSize
        }
        coordinator.lastFrame = window.frame
    }
}
