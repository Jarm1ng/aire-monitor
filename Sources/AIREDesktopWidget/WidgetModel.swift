import AppKit
import Combine
import HPCCore

/// Discovers the clusters the app writes under `.runtime/clusters/<id>/` and
/// owns one independent ClusterFeed per cluster. Nothing here aggregates
/// numbers across clusters; it only answers "how are the feeds doing".
@MainActor
final class WidgetModel: ObservableObject {
    /// Discovered clusters in display order (catalogue order, then the rest
    /// alphabetically).
    @Published private(set) var feeds: [ClusterFeed] = []
    /// Widget-level problems (launching the app); per-cluster problems live
    /// on each feed.
    @Published var errorMessage: String?
    @Published var launchMessage: String?

    /// nil when no candidate location holds the checkout; the widget then
    /// shows MissingProjectCard and does nothing else.
    let projectRoot: String?

    private var pollTimer: Timer?
    /// The running scripts/run_macos_app.sh, if any.
    private var appLauncher: Process?
    private var clustersWatcher: DirectoryWatcher?
    private var preferences: WidgetPreferencesReader?
    private var feedSubscriptions: [String: AnyCancellable] = [:]

    init(projectRoot: String? = ProjectLocator.findProjectRoot()) {
        self.projectRoot = projectRoot
        preferences = projectRoot.map { WidgetPreferencesReader(path: "\($0)/.runtime/preferences.json") }
        if projectRoot == nil {
            WidgetLog.app.error("Cannot find the Leeds HPC checkout (no scripts/hpc_snapshot.py under HPC_PROJECT_ROOT, the bundle's HPCProjectRoot, the working directory or the bundle's grandparent)")
        }
    }

    private var clustersRoot: String? {
        projectRoot.map { "\($0)/.runtime/clusters" }
    }

    var hasProjectRoot: Bool {
        projectRoot != nil
    }

    var isAnyRefreshing: Bool {
        feeds.contains { $0.isRefreshing }
    }

    /// The slowest refresh cadence among clusters that are being refreshed
    /// (by the app or the widget), for the footer: honest when the app or the
    /// widget is backing off instead of always claiming 10 s.
    var refreshCadence: TimeInterval {
        feeds.compactMap(\.refreshCadence).max() ?? HPCDefaults.refreshInterval
    }

    func start() {
        guard projectRoot != nil, pollTimer == nil else {
            return
        }
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: WidgetLayout.filePollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
    }

    /// Manual refresh of every cluster. Each feed decides what that means
    /// (see ClusterFeed.sync): collecting where the widget may, otherwise a
    /// short reply saying who refreshes the cluster or when it can next run.
    func refresh() {
        guard projectRoot != nil else {
            return
        }
        errorMessage = nil
        reconcileClusters()
        for feed in feeds {
            feed.installWatcherIfNeeded()
            feed.sync(manual: true)
        }
    }

    func refresh(clusterID: String) {
        feeds.first { $0.id == clusterID }?.sync(manual: true)
    }

    /// Brings the app forward, opens the installed app, or builds (only if
    /// the sources changed) and opens it — see `WidgetAppLauncher` for why
    /// a .runtime bundle is never opened directly. The launcher also
    /// repackages the widget, so a widget whose bundle changed is restarted
    /// by it on the new build.
    func openMainApp() {
        errorMessage = nil
        guard let projectRoot else {
            errorMessage = "Cannot open Leeds HPC Monitor: the widget cannot find the project folder."
            return
        }
        guard appLauncher == nil else {
            // A build is already under way; a second one would only wait
            // for the first one's lock.
            return
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: WidgetAppLauncher.appBundleIdentifier)
            .filter { !$0.isTerminated }
        let plan = WidgetAppLauncher.plan(
            projectRoot: projectRoot,
            runningBundlePaths: running.map { $0.bundleURL?.path },
            installedAppPath: AppInstallRecord.installedAppPath(projectRoot: projectRoot),
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
        switch plan {
        case .activate(let index):
            activate(running[index])
        case .openInstalled(let path):
            openInstalledApp(at: path)
        case .missingLauncher(let script):
            errorMessage = "Cannot find the Leeds HPC Monitor launcher at \(script)"
        case .runLauncher(let script):
            runLauncher(script: script, projectRoot: projectRoot)
        }
    }

    /// Through LaunchServices when the bundle is known: that also sends the
    /// reopen event, so an app whose windows are all closed shows one
    /// (activating the process alone would leave only its menu bar item).
    /// A bundle deleted under the running app (a clean of .runtime) cannot
    /// be opened, so that process is only activated.
    private func activate(_ app: NSRunningApplication) {
        guard let bundleURL = app.bundleURL, FileManager.default.fileExists(atPath: bundleURL.path) else {
            app.activate(options: [])
            return
        }
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else {
                return
            }
            let message = error.localizedDescription
            Task { @MainActor in
                WidgetLog.app.error("Could not bring the app forward: \(message, privacy: .public)")
                self?.errorMessage = "Could not open Leeds HPC Monitor: \(message)"
            }
        }
    }

    /// The copy scripts/install_app.sh put in /Applications (or wherever it
    /// recorded): a normal app, opened as Finder would open it. It is not
    /// rebuilt here; the user updates it with install_app.sh or
    /// run_macos_app.sh. It finds this checkout through its HPCProjectRoot
    /// Info.plist key (the record lives in this checkout, so the install was
    /// built from it), so no environment is passed.
    private func openInstalledApp(at path: String) {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else {
                return
            }
            let message = error.localizedDescription
            Task { @MainActor in
                WidgetLog.app.error("Could not open the installed app: \(message, privacy: .public)")
                self?.errorMessage = "Could not open Leeds HPC Monitor: \(message)"
            }
        }
    }

    private func runLauncher(script: String, projectRoot: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script]
        process.currentDirectoryURL = URL(fileURLWithPath: projectRoot)
        var environment = ProcessInfo.processInfo.environment
        // The app validates this against scripts/hpc_snapshot.py, so it
        // follows this checkout even if its bundle was moved.
        environment["HPC_PROJECT_ROOT"] = projectRoot
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.appLauncher = nil
                self.launchMessage = nil
                if let message = WidgetAppLauncher.failureMessage(status: status) {
                    WidgetLog.app.error("\(WidgetAppLauncher.launcherRelativePath, privacy: .public) exited with status \(status)")
                    self.errorMessage = message
                }
            }
        }
        do {
            try process.run()
            appLauncher = process
            launchMessage = "Opening Leeds HPC Monitor… (building first if the sources changed)"
        } catch {
            WidgetLog.app.error("Could not run the launcher: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Could not launch Leeds HPC Monitor: \(error.localizedDescription)"
        }
    }

    // MARK: Discovery

    /// One poll: re-arm watchers that were dropped, pick up added or removed
    /// cluster directories, and let every feed check its files. Costs a few
    /// stats when nothing changed.
    func poll() {
        guard projectRoot != nil else {
            return
        }
        installClustersWatcherIfNeeded()
        reconcileClusters()
        for feed in feeds {
            feed.installWatcherIfNeeded()
            feed.sync()
        }
    }

    private func installClustersWatcherIfNeeded() {
        guard clustersWatcher == nil, let clustersRoot else {
            return
        }
        // Fails quietly until the app creates `.runtime/clusters`; the poll
        // timer retries every couple of seconds.
        clustersWatcher = DirectoryWatcher(path: clustersRoot) { [weak self] flags in
            self?.handleClustersDirectoryEvent(flags: flags)
        }
    }

    private func handleClustersDirectoryEvent(flags: DispatchSource.FileSystemEvent) {
        if DirectoryWatcher.invalidatesWatcher(flags) {
            clustersWatcher?.cancel()
            clustersWatcher = nil
        }
        reconcileClusters()
        for feed in feeds {
            feed.installWatcherIfNeeded()
            feed.sync()
        }
    }

    /// Keeps existing feeds (and their state) for clusters that are still
    /// present, adds feeds for new cluster directories and stops feeds whose
    /// directory vanished or whose cluster was disabled in the app.
    private func reconcileClusters() {
        guard let projectRoot, let clustersRoot else {
            return
        }
        let ids = discoverClusterIDs(in: clustersRoot)
        guard ids != feeds.map(\.id) else {
            return
        }
        var existing = Dictionary(uniqueKeysWithValues: feeds.map { ($0.id, $0) })
        var next: [ClusterFeed] = []
        for id in ids {
            if let feed = existing.removeValue(forKey: id) {
                next.append(feed)
                continue
            }
            let feed = ClusterFeed(id: id, directory: "\(clustersRoot)/\(id)", projectRoot: projectRoot)
            // Forward feed changes so the header, footer and window height
            // (which depend on every feed) repaint too.
            feedSubscriptions[id] = feed.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
            next.append(feed)
            WidgetLog.app.info("Following cluster \(id, privacy: .public)")
        }
        for (id, feed) in existing {
            feed.stop()
            feedSubscriptions[id] = nil
            WidgetLog.app.info("Stopped following cluster \(id, privacy: .public)")
        }
        feeds = next
    }

    private func discoverClusterIDs(in clustersRoot: String) -> [String] {
        preferences?.reloadIfChanged()
        let disabled = preferences?.disabledClusterIDs ?? []
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: clustersRoot) else {
            return []
        }
        return names
            .filter { name in
                var isDirectory: ObjCBool = false
                return WidgetFeedPolicy.isValidClusterDirectoryName(name)
                    && FileManager.default.fileExists(atPath: "\(clustersRoot)/\(name)", isDirectory: &isDirectory)
                    && isDirectory.boolValue
                    && !disabled.contains(name)
            }
            .sorted { ClusterIdentity.sortKey(ClusterID($0)) < ClusterIdentity.sortKey(ClusterID($1)) }
    }
}
