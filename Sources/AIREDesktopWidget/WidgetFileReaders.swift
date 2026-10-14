import Foundation
import HPCCore
import os

/// The widget's diagnostics, readable with
/// `log stream --predicate 'subsystem == "local.aire.desktop-widget"'`.
/// Only transitions and outcomes are logged (never the 2 s poll itself), and
/// paths, which contain the user's home and username, are private.
enum WidgetLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "local.aire.desktop-widget"
    /// Snapshot loading, app ownership changes and fallback collections.
    static let feed = Logger(subsystem: subsystem, category: "feed")
    /// Discovery, the project root and launching the app.
    static let app = Logger(subsystem: subsystem, category: "widget")
}

// MARK: - Directory watching

/// Watches one directory's vnode on the main queue. Directories are watched
/// rather than files because the app replaces snapshots atomically (write +
/// rename), which shows up as a directory write event and would orphan a
/// watcher bound to the old file inode.
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(path: String, onEvent: @escaping @MainActor @Sendable (DispatchSource.FileSystemEvent) -> Void) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            return nil
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak source] in
            // Read the vnode flags synchronously: source.data is only valid
            // while the handler runs and events could coalesce or be lost
            // across the async hop below.
            guard let flags = source?.data else {
                return
            }
            Task { @MainActor in
                onEvent(flags)
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        self.source = source
    }

    func cancel() {
        source.cancel()
    }

    deinit {
        source.cancel()
    }

    /// The watched inode itself was unlinked or renamed. Checking the path
    /// at that moment would race with a delete+recreate and leave the source
    /// bound to the dead inode forever, so callers drop the watcher
    /// unconditionally and let the poll timer install a fresh one.
    static func invalidatesWatcher(_ flags: DispatchSource.FileSystemEvent) -> Bool {
        !flags.isDisjoint(with: [.delete, .rename])
    }
}

func fileModificationDate(atPath path: String) -> Date? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return attributes?[.modificationDate] as? Date
}

// MARK: - App preferences

/// Reads only the per-cluster `enabled` flags from the app's password-free
/// `.runtime/preferences.json`, so a cluster the user switched off in the app
/// disappears from the widget (and is never collected by its fallback)
/// instead of lingering as a stale row. Every other key is ignored, and an
/// unreadable file hides nothing.
struct WidgetPreferencesReader {
    private struct PreferencesFile: Decodable {
        struct Cluster: Decodable {
            let enabled: Bool?
        }

        let clusters: [String: Cluster]?
    }

    let path: String
    private(set) var disabledClusterIDs: Set<String> = []
    private var loadedModificationDate: Date?
    private var hasLoaded = false

    init(path: String) {
        self.path = path
    }

    mutating func reloadIfChanged() {
        let modificationDate = fileModificationDate(atPath: path)
        guard !hasLoaded || modificationDate != loadedModificationDate else {
            return
        }
        hasLoaded = true
        loadedModificationDate = modificationDate
        guard let data = FileManager.default.contents(atPath: path) else {
            disabledClusterIDs = []
            return
        }
        guard let decoded = try? JSONDecoder().decode(PreferencesFile.self, from: data) else {
            let path = self.path
            WidgetLog.app.error("Cannot decode the app preferences at \(path, privacy: .private); showing every cluster")
            disabledClusterIDs = []
            return
        }
        disabledClusterIDs = Set(
            (decoded.clusters ?? [:]).compactMap { id, cluster in
                cluster.enabled == false ? id : nil
            }
        )
    }
}

// MARK: - App state lease

/// Follows one cluster's `app_state.json` (see WidgetAppState), re-reading
/// it only when its modification date changes, like the preferences reader.
/// The decoded record and its mtime are kept so ownership can be re-judged
/// against the clock on every poll without touching the file again.
struct WidgetAppStateReader {
    let path: String
    private(set) var state: WidgetAppState?
    private(set) var modificationDate: Date?
    private var hasLoaded = false

    init(path: String) {
        self.path = path
    }

    mutating func reloadIfChanged() {
        let current = fileModificationDate(atPath: path)
        guard !hasLoaded || current != modificationDate else {
            return
        }
        hasLoaded = true
        modificationDate = current
        guard current != nil, let data = FileManager.default.contents(atPath: path) else {
            state = nil
            return
        }
        state = WidgetAppState.decode(data)
        if state == nil {
            let path = self.path
            WidgetLog.feed.error("Cannot decode \(path, privacy: .private); treating the app as not running for this cluster")
        }
    }

    func ownership(now: Date = Date()) -> WidgetAppOwnership {
        WidgetAppOwnership.resolve(state, fileModificationDate: modificationDate, now: now)
    }
}

// MARK: - Project root

enum ProjectLocator {
    /// Present in every checkout of this repository; also what the app uses
    /// to recognise a project root.
    static let markerScript = ProjectRootLocator.markerScript

    /// The checkout the widget reads `.runtime/` from, by the rule the app
    /// uses too (see `ProjectRootLocator`): HPC_PROJECT_ROOT (or the
    /// pre-multi-cluster AIRE_PROJECT_ROOT), the bundle's HPCProjectRoot
    /// Info.plist key, the working directory, or the bundle's grandparent
    /// (`<root>/.runtime/AIREDesktopWidget.app`). nil when none of them
    /// holds the collector: falling back to the working directory (`/`
    /// under `open`) used to make a moved bundle watch `/.runtime/clusters`
    /// and tell the user to connect in the app, which could never help.
    static func findProjectRoot() -> String? {
        ProjectRootLocator.locateForCurrentProcess()
    }
}
