import Foundation

/// How the desktop widget's "Open Leeds HPC Monitor" reaches the app, under
/// the launcher contract of scripts/build_bundle.sh: activate an app that is
/// already running; otherwise always go through scripts/run_macos_app.sh,
/// which rebuilds the bundle only when the sources changed and then opens
/// it. Opening .runtime/AIREMonitorApp.app directly whenever it existed used
/// to start whatever build was there — after a pull, or after the Widget
/// button rebuilt only the widget, an outdated app that might not even
/// write the app_state.json lease the widget relies on.
///
/// Pure decisions only (the widget target performs them), so they can be
/// tested without AppKit.
public enum WidgetAppLauncher {
    /// The app bundle's CFBundleIdentifier (scripts/build_bundle.sh keeps
    /// the pre-rename identifier on purpose).
    public static let appBundleIdentifier = "local.aire.monitor"

    /// scripts/build_bundle.sh exits 75 when another build of the same
    /// checkout held its lock for too long.
    public static let buildBusyExitStatus: Int32 = 75

    public static let launcherRelativePath = "scripts/run_macos_app.sh"

    public static func appBundlePath(projectRoot: String) -> String {
        "\(projectRoot)/.runtime/AIREMonitorApp.app"
    }

    public enum Plan: Equatable, Sendable {
        /// Bring this running instance forward (an index into the running
        /// instances passed to `plan`).
        case activate(index: Int)
        /// Run the launcher script with /bin/bash from the checkout.
        case runLauncher(script: String)
        /// No app is running and the checkout has no launcher.
        case missingLauncher(script: String)
    }

    /// `runningBundlePaths`: the bundle path of every running instance with
    /// `appBundleIdentifier` (nil when unknown). One started from this
    /// checkout's bundle is preferred, since that is the app whose files
    /// the widget reads; any other instance still beats starting a second
    /// copy of the app beside it.
    public static func plan(
        projectRoot: String,
        runningBundlePaths: [String?],
        fileExists: (String) -> Bool
    ) -> Plan {
        if !runningBundlePaths.isEmpty {
            let own = standardized(appBundlePath(projectRoot: projectRoot))
            let index = runningBundlePaths.firstIndex { $0.map(standardized) == own } ?? 0
            return .activate(index: index)
        }
        let script = "\(projectRoot)/\(launcherRelativePath)"
        return fileExists(script) ? .runLauncher(script: script) : .missingLauncher(script: script)
    }

    /// The widget's message for a launcher that exited with `status`; nil
    /// for success.
    public static func failureMessage(status: Int32) -> String? {
        switch status {
        case 0:
            return nil
        case buildBusyExitStatus:
            return "Another build of this checkout is still running, so Leeds HPC Monitor was not opened. "
                + "Try again once it has finished."
        default:
            return "Leeds HPC Monitor could not be built or opened (launcher exit status \(status)). "
                + "See .runtime/swift-build.log, or run \(launcherRelativePath) in Terminal for details."
        }
    }

    private static func standardized(_ path: String) -> String {
        var trimmed = (path as NSString).standardizingPath
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }
}
