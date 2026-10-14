import Foundation

/// How the app and the desktop widget find the checkout (the folder holding
/// `scripts/hpc_snapshot.py` and `.runtime/`) they work in. One rule for both,
/// so a bundle installed outside the checkout (scripts/install_app.sh copies
/// the app to /Applications) finds the same folder whichever way it was
/// started: by LaunchServices (`open`, Finder, the Dock, a notification
/// click), which applies the bundle's LSEnvironment, or by exec'ing the
/// binary inside the bundle, which does not.
///
/// The candidates, first valid one wins:
/// 1. `HPC_PROJECT_ROOT`, then the pre-multi-cluster `AIRE_PROJECT_ROOT`
///    (explicit: a caller that sets them means it)
/// 2. the bundle's `HPCProjectRoot` Info.plist key, written by
///    scripts/build_bundle.sh; read through the bundle itself, so it works
///    without LaunchServices
/// 3. the working directory
/// 4. the bundle's grandparent, which makes `<checkout>/.runtime/*.app`
///    self-locating
///
/// A candidate counts only when it holds the marker script, so a stale value
/// (the checkout moved) falls through to the next one instead of pointing at
/// a folder without the helpers.
public enum ProjectRootLocator {
    /// Present in every checkout; what identifies a project root.
    public static let markerScript = "scripts/hpc_snapshot.py"

    /// In priority order. `AIRE_PROJECT_ROOT` is the pre-rename name.
    public static let environmentKeys = ["HPC_PROJECT_ROOT", "AIRE_PROJECT_ROOT"]

    /// The Info.plist key scripts/build_bundle.sh writes the checkout path to.
    public static let infoPlistKey = "HPCProjectRoot"

    public static func hasMarker(_ root: String) -> Bool {
        !root.isEmpty && FileManager.default.fileExists(atPath: "\(root)/\(markerScript)")
    }

    /// The Info.plist value as a path, or nil unless it is a non-empty
    /// absolute path string (a relative one would be resolved against the
    /// working directory, `/` under LaunchServices, which is never meant).
    public static func infoPlistRoot(_ value: Any?) -> String? {
        guard let path = value as? String, path.hasPrefix("/") else {
            return nil
        }
        return path
    }

    /// Every candidate in priority order, before validation.
    public static func candidates(
        environment: [String: String],
        infoPlistValue: Any?,
        currentDirectory: String,
        bundlePath: String
    ) -> [String] {
        var result = environmentKeys.compactMap { environment[$0] }
        if let root = infoPlistRoot(infoPlistValue) {
            result.append(root)
        }
        result.append(currentDirectory)
        result.append(
            URL(fileURLWithPath: bundlePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path
        )
        return result
    }

    /// The first candidate `isValid` accepts (by default: holds the marker
    /// script), or nil.
    public static func locate(
        environment: [String: String],
        infoPlistValue: Any?,
        currentDirectory: String,
        bundlePath: String,
        isValid: (String) -> Bool = hasMarker
    ) -> String? {
        candidates(
            environment: environment,
            infoPlistValue: infoPlistValue,
            currentDirectory: currentDirectory,
            bundlePath: bundlePath
        ).first(where: isValid)
    }

    /// `locate` for this process: its environment, `Bundle.main`'s Info.plist
    /// and location, and its working directory.
    public static func locateForCurrentProcess(isValid: (String) -> Bool = hasMarker) -> String? {
        locate(
            environment: ProcessInfo.processInfo.environment,
            infoPlistValue: Bundle.main.object(forInfoDictionaryKey: infoPlistKey),
            currentDirectory: FileManager.default.currentDirectoryPath,
            bundlePath: Bundle.main.bundleURL.path,
            isValid: isValid
        )
    }
}

/// Where scripts/install_app.sh installed the app, as recorded in
/// `<checkout>/.runtime/installed_app_path` (one absolute path to
/// "Leeds HPC Monitor.app"). The record counts only while that path holds a
/// bundle with the app's identifier, so a deleted or replaced install reads
/// as "not installed", as it does for the scripts.
public enum AppInstallRecord {
    public static let recordRelativePath = ".runtime/installed_app_path"

    /// The record's path, or nil unless its first line is an absolute path
    /// to an `.app`.
    public static func parse(_ text: String) -> String? {
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let path = String(firstLine)
        guard path.hasPrefix("/"), path.hasSuffix(".app"), path.count > 5 else {
            return nil
        }
        return path
    }

    /// CFBundleIdentifier of the bundle at `bundlePath`, read from its
    /// Info.plist directly (`Bundle(path:)` caches, so it could describe the
    /// bundle that was there before an update).
    public static func bundleIdentifier(atBundlePath bundlePath: String) -> String? {
        let plist = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary["CFBundleIdentifier"] as? String
    }

    /// The installed app's path for this checkout, or nil when there is no
    /// valid install.
    public static func installedAppPath(
        projectRoot: String,
        bundleIdentifier expected: String = WidgetAppLauncher.appBundleIdentifier
    ) -> String? {
        let recordPath = "\(projectRoot)/\(recordRelativePath)"
        guard let data = FileManager.default.contents(atPath: recordPath),
              let path = parse(String(decoding: data, as: UTF8.self)) else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
              bundleIdentifier(atBundlePath: path) == expected else {
            return nil
        }
        return path
    }
}
