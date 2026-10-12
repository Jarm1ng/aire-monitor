import AppKit
import Combine
import SwiftUI

/// Geometry and cadences. The width is fixed; the height grows by one
/// cluster row per monitored cluster, so every cluster gets its own row of
/// numbers instead of being merged into one misleading fleet total (AIRE's
/// L40S and Calder's H200 pools are different hardware on different
/// schedulers).
private enum WidgetLayout {
    static let width: CGFloat = 548
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 12
    static let headerHeight: CGFloat = 30
    static let footerHeight: CGFloat = 26
    static let sectionSpacing: CGFloat = 10
    static let clusterRowHeight: CGFloat = 108
    static let clusterRowSpacing: CGFloat = 8
    /// Rows beyond this are summarised in the footer so the window can never
    /// outgrow a laptop screen if more clusters appear.
    static let maxVisibleClusters = 4
    /// Minimum spacing between fallback snapshot collections per cluster, and
    /// the cadence the widget advertises in the footer (it matches the app's
    /// own refresh interval).
    static let refreshInterval: TimeInterval = 10
    /// How often the widget polls the cluster directories for changes (belt
    /// and braces alongside the directory watchers).
    static let filePollInterval: TimeInterval = 2
    /// A snapshot older than this is considered stale: the main app is not
    /// feeding that cluster's file, so the widget may collect it itself.
    static let staleThreshold: TimeInterval = 30

    /// Header, one row per cluster (at least one, for the empty state) and
    /// the footer: about 116 pt per cluster on top of 90 pt of chrome.
    static func height(forClusterRows rows: Int) -> CGFloat {
        let rows = max(rows, 1)
        return verticalPadding * 2
            + headerHeight
            + sectionSpacing * 2
            + footerHeight
            + CGFloat(rows) * clusterRowHeight
            + CGFloat(rows - 1) * clusterRowSpacing
    }
}

private enum WidgetPalette {
    static let backgroundOverlay = Color(nsColor: .windowBackgroundColor).opacity(0.42)
    static let fill = Color.primary.opacity(0.040)
    static let fillStrong = Color.primary.opacity(0.070)
    static let border = Color.primary.opacity(0.085)
    static let highlight = Color.primary.opacity(0.10)
    static let cyan = Color.cyan
    static let green = Color.green
    static let orange = Color.orange
    static let red = Color.red
    static let purple = Color.purple
    static let neutral = Color.secondary

    /// Matches the main app's job-state semantics: running = green,
    /// pending = orange, anything else neutral.
    static func jobStateColor(_ state: String) -> Color {
        let value = state.uppercased()
        if value.contains("RUN") {
            return green
        }
        if value.contains("PEND") {
            return orange
        }
        return neutral
    }

    /// Matches the main app's GPU ramp: green = free, orange = partially
    /// allocated, cyan = fully allocated, red = unavailable.
    static func gpuColor(allocatedRatio: Double, isAvailable: Bool = true) -> Color {
        guard isAvailable else {
            return red
        }
        if allocatedRatio >= 1 {
            return cyan
        }
        if allocatedRatio > 0 {
            return orange
        }
        return green
    }

    static func heatmapColor(for node: WidgetNode) -> Color {
        let ratio = Double(node.gpuAllocatedValue) / Double(max(node.gpuTotalValue, 1))
        let base = gpuColor(allocatedRatio: ratio, isAvailable: node.isAvailable)
        guard node.isAvailable else {
            return base.opacity(0.68)
        }
        return base.opacity(ratio > 0 ? 0.88 : 0.80)
    }
}

/// Display identity of a cluster directory. The widget shares no code with
/// the app, so it cannot read the app's ClusterCatalog; it mirrors only the
/// facts it needs (name casing, accent colour, display order) for the
/// clusters it knows, and derives something reasonable for any other
/// directory so a future cluster shows up without a widget release.
enum ClusterStyle {
    /// Directory id -> display name, for names that plain capitalisation
    /// would get wrong. The snapshot's own `cluster.name` wins when present.
    private static let knownNames = ["aire": "AIRE", "calder": "Calder"]
    /// Display order: the original cluster first, then Calder, then any
    /// other cluster alphabetically.
    private static let preferredOrder = ["aire", "calder"]

    static func fallbackName(for id: String) -> String {
        if let known = knownNames[id] {
            return known
        }
        // Plain capitalisation ("bessemer" -> "Bessemer"). Guessing acronyms
        // from the id would be wrong as often as right, and this name only
        // shows until the cluster's first snapshot brings its real one.
        return id.prefix(1).uppercased() + id.dropFirst()
    }

    /// Same colours as the app's ClusterAccent, so a cluster looks the same
    /// in the widget, the dashboard and the menu bar.
    static func accent(for id: String) -> Color {
        switch id {
        case "aire":
            return Color(red: 0.16, green: 0.74, blue: 0.48)
        case "calder":
            return Color(red: 0.56, green: 0.45, blue: 0.96)
        default:
            return Color.gray
        }
    }

    static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        let lhsRank = preferredOrder.firstIndex(of: lhs) ?? preferredOrder.count
        let rhsRank = preferredOrder.firstIndex(of: rhs) ?? preferredOrder.count
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        return lhs < rhs
    }

    /// Directory names become file paths and UI text; accept only the plain
    /// lowercase ids the app writes (`aire`, `calder`, ...), never dot files,
    /// quarantine leftovers or anything path-like.
    static func isValidID(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= 32 else {
            return false
        }
        let isPlain: (Unicode.Scalar) -> Bool = { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-" || scalar == "_"
        }
        return ("a"..."z").contains(first) && name.unicodeScalars.allSatisfy(isPlain)
    }
}

struct WidgetLogoMark: View {
    var cornerRadius: CGFloat = 7

    @MainActor private static let cachedLogo: NSImage? = loadLogoImage()

    var body: some View {
        Group {
            if let image = Self.cachedLogo {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "server.rack")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(WidgetPalette.cyan)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(WidgetPalette.cyan.opacity(0.13))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.primary.opacity(0.18), lineWidth: 1)
        )
    }

    /// The neutral Leeds HPC mark: the widget covers every cluster, so it
    /// must not wear one cluster's logo.
    private static func loadLogoImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "LeedsHPCMark", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        let fallback = ProjectLocator.findProjectRoot() + "/assets/LeedsHPCMark.png"
        return NSImage(contentsOfFile: fallback)
    }
}

/// Circular cluster monogram in the cluster's accent colour, mirroring the
/// app's ClusterBadge.
struct ClusterMonogram: View {
    let clusterID: String
    let name: String
    var size: CGFloat = 20

    var body: some View {
        Text(name.prefix(1).uppercased())
            .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(ClusterStyle.accent(for: clusterID).gradient, in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
            // The cluster name is always printed right next to the badge.
            .accessibilityHidden(true)
    }
}

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

enum WidgetDataStatus: Equatable {
    case connecting
    case live
    case cached
    case offline

    var title: String {
        switch self {
        case .connecting: return "connecting"
        case .live: return "live"
        case .cached: return "cached"
        case .offline: return "offline"
        }
    }

    var color: Color {
        switch self {
        case .connecting: return WidgetPalette.neutral
        case .live: return WidgetPalette.green
        case .cached: return WidgetPalette.orange
        case .offline: return WidgetPalette.red
        }
    }
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
        guard let data = FileManager.default.contents(atPath: path),
              let decoded = try? JSONDecoder().decode(PreferencesFile.self, from: data) else {
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

private func fileModificationDate(atPath path: String) -> Date? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return attributes?[.modificationDate] as? Date
}

// MARK: - Model

/// Discovers the clusters the app writes under `.runtime/clusters/<id>/` and
/// owns one independent ClusterFeed per cluster. Nothing here aggregates
/// numbers across clusters; it only answers "how are the feeds doing".
@MainActor
final class WidgetModel: ObservableObject {
    /// Discovered clusters in display order (AIRE, Calder, then the rest).
    @Published private(set) var feeds: [ClusterFeed] = []
    /// Widget-level problems (launching the app); per-cluster problems live
    /// on each feed.
    @Published var errorMessage: String?
    @Published var launchMessage: String?

    let projectRoot: String

    private var pollTimer: Timer?
    private var clustersWatcher: DirectoryWatcher?
    private var preferences: WidgetPreferencesReader
    private var feedSubscriptions: [String: AnyCancellable] = [:]

    init() {
        let root = ProjectLocator.findProjectRoot()
        projectRoot = root
        preferences = WidgetPreferencesReader(path: "\(root)/.runtime/preferences.json")
    }

    private var clustersRoot: String {
        "\(projectRoot)/.runtime/clusters"
    }

    var isAnyRefreshing: Bool {
        feeds.contains { $0.isRefreshing }
    }

    func start() {
        guard pollTimer == nil else {
            return
        }
        tick()
        pollTimer = Timer.scheduledTimer(withTimeInterval: WidgetLayout.filePollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    /// Manual refresh of every cluster: reloads each snapshot file and
    /// collects where the widget is allowed to (see ClusterFeed.sync), so
    /// it never double-collects while the app is feeding a cluster.
    func refresh() {
        errorMessage = nil
        reconcileClusters()
        for feed in feeds {
            feed.installWatcherIfNeeded()
            feed.sync(forceReload: true, forceCollect: true)
        }
    }

    func refresh(clusterID: String) {
        feeds.first { $0.id == clusterID }?.sync(forceReload: true, forceCollect: true)
    }

    func openMainApp() {
        errorMessage = nil
        let appURL = URL(fileURLWithPath: "\(projectRoot)/.runtime/AIREMonitorApp.app")
        if FileManager.default.fileExists(atPath: appURL.path) {
            launchMessage = "Launching Leeds HPC Monitor…"
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { [weak self] _, error in
                Task { @MainActor in
                    guard let self else {
                        return
                    }
                    self.launchMessage = nil
                    if let error {
                        self.errorMessage = "Could not open Leeds HPC Monitor: \(error.localizedDescription)"
                    }
                }
            }
            return
        }

        let scriptURL = URL(fileURLWithPath: "\(projectRoot)/scripts/run_macos_app.sh")
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            errorMessage = "Cannot find the Leeds HPC Monitor launcher at \(scriptURL.path)"
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.currentDirectoryURL = URL(fileURLWithPath: projectRoot)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.launchMessage = nil
                if status != 0 {
                    self.errorMessage = "Leeds HPC Monitor launcher exited with status \(status); run scripts/run_macos_app.sh in Terminal for details."
                }
            }
        }
        do {
            try process.run()
            launchMessage = "Launching Leeds HPC Monitor… (building if needed)"
        } catch {
            errorMessage = "Could not launch Leeds HPC Monitor: \(error.localizedDescription)"
        }
    }

    // MARK: Discovery

    /// One poll: re-arm watchers that were dropped, pick up added or removed
    /// cluster directories, and let every feed check its snapshot.
    private func tick() {
        installClustersWatcherIfNeeded()
        reconcileClusters()
        for feed in feeds {
            feed.installWatcherIfNeeded()
            feed.sync()
        }
    }

    private func installClustersWatcherIfNeeded() {
        guard clustersWatcher == nil else {
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
        let ids = discoverClusterIDs()
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
        }
        for (id, feed) in existing {
            feed.stop()
            feedSubscriptions[id] = nil
        }
        feeds = next
    }

    private func discoverClusterIDs() -> [String] {
        preferences.reloadIfChanged()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: clustersRoot) else {
            return []
        }
        return names
            .filter { name in
                var isDirectory: ObjCBool = false
                return ClusterStyle.isValidID(name)
                    && FileManager.default.fileExists(atPath: "\(clustersRoot)/\(name)", isDirectory: &isDirectory)
                    && isDirectory.boolValue
                    && !preferences.disabledClusterIDs.contains(name)
            }
            .sorted(by: ClusterStyle.precedes)
    }
}

/// Fallback-collection bookkeeping, keyed by cluster id instead of stored on
/// a ClusterFeed. A feed is dropped and recreated when its cluster is
/// disabled and re-enabled in the app, or its directory briefly disappears;
/// the replacement must still see a collection the old feed started (its
/// process keeps running until it finishes or the watchdog kills it) and
/// that collection's place in the 10 s cadence, otherwise one cluster could
/// end up with two collectors racing through the same ControlMaster.
@MainActor
enum CollectionLedger {
    /// Clusters with a collector process running right now.
    static var inFlight: Set<String> = []
    /// When each cluster's last collection (or rejected attempt) started.
    static var lastAttempt: [String: Date] = [:]
}

/// One cluster's data path: follows `.runtime/clusters/<id>/latest_snapshot.json`
/// as written by the app and, only when that file is stale and the app left
/// a `collector.json` behind, runs the collector itself. Staleness, cadence,
/// in-flight state and errors are all per cluster, so a stale Calder file
/// never triggers an AIRE collection and the reverse.
@MainActor
final class ClusterFeed: ObservableObject, Identifiable {
    /// Directory name, e.g. "aire" or "calder". Job ids and node names are
    /// only unique within one cluster, so it qualifies both (see
    /// WidgetSnapshot.qualified(by:)).
    let id: String
    let directory: String
    private let projectRoot: String

    @Published private(set) var snapshot: WidgetSnapshot?
    /// When the displayed snapshot was collected on the cluster.
    @Published private(set) var snapshotDate: Date?
    /// When the displayed data last changed (file reload or collection).
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var status: WidgetDataStatus = .connecting
    @Published private(set) var errorMessage: String?
    /// Informational: why no fresh data is coming (the app is not feeding
    /// this cluster and there is nothing the widget can run on its own).
    @Published private(set) var notice: String?
    @Published private(set) var isRefreshing = false

    private var watcher: DirectoryWatcher?
    private var isActive = true
    private var loadedModificationDate: Date?
    private var failedModificationDate: Date?
    /// True when the displayed snapshot came from this widget's own fallback
    /// collection (rather than the main app writing the snapshot file).
    private var lastDataFromFallback = false
    /// Modification date of the snapshot file as last written by this
    /// widget's own fallback collection; reloading that same write must not
    /// be mistaken for the main app feeding the file.
    private var ownWriteModificationDate: Date?

    init(id: String, directory: String, projectRoot: String) {
        self.id = id
        self.directory = directory
        self.projectRoot = projectRoot
    }

    /// The collector echoes the cluster's display name into every snapshot;
    /// until one arrives (or if it names a different cluster) fall back to a
    /// name derived from the directory.
    var displayName: String {
        if let info = snapshot?.cluster, info.id == id {
            let name = info.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return String(name.prefix(24))
            }
        }
        return ClusterStyle.fallbackName(for: id)
    }

    /// Login node that produced the snapshot, shown in the status chip.
    var remoteName: String? {
        guard let remote = snapshot?.remote else {
            return nil
        }
        let name = remote.hostname.isEmpty ? remote.host : remote.hostname
        return name.isEmpty ? nil : name
    }

    private var snapshotPath: String {
        "\(directory)/latest_snapshot.json"
    }

    func stop() {
        isActive = false
        watcher?.cancel()
        watcher = nil
    }

    func installWatcherIfNeeded() {
        guard isActive, watcher == nil else {
            return
        }
        watcher = DirectoryWatcher(path: directory) { [weak self] flags in
            self?.handleDirectoryEvent(flags: flags)
        }
    }

    private func handleDirectoryEvent(flags: DispatchSource.FileSystemEvent) {
        if DirectoryWatcher.invalidatesWatcher(flags) {
            watcher?.cancel()
            watcher = nil
        }
        sync()
    }

    /// Primary data path: reload the snapshot file when it changed, then fall
    /// back to spawning the collector only when the file is missing or stale
    /// (or the widget is already the one feeding it), so the widget never
    /// double-collects while the main app is running.
    func sync(forceReload: Bool = false, forceCollect: Bool = false) {
        guard isActive else {
            return
        }
        let wasFallback = lastDataFromFallback
        reloadIfChanged(force: forceReload)
        recomputeStatus()

        let age = snapshotAge
        let missingOrStale = age.map { $0 > WidgetLayout.staleThreshold } ?? true
        // Once the widget feeds itself it keeps the app's 10 s cadence
        // instead of letting the data go stale between collections.
        let ownFeedDue = lastDataFromFallback
            && (age.map { $0 > WidgetLayout.refreshInterval } ?? true)
        if forceCollect {
            // Manual refresh: collect only when the widget is feeding itself
            // (or the file is missing/stale) so we never double-collect while
            // the main app feeds the file. The 10 s cadence still applies.
            if missingOrStale || wasFallback {
                collectIfNeeded()
            }
        } else if missingOrStale || ownFeedDue {
            collectIfNeeded()
        } else {
            setNotice(nil)
        }
    }

    private var snapshotAge: TimeInterval? {
        guard snapshot != nil, let snapshotDate else {
            return nil
        }
        return Date().timeIntervalSince(snapshotDate)
    }

    private func reloadIfChanged(force: Bool) {
        guard let modificationDate = fileModificationDate(atPath: snapshotPath) else {
            return
        }
        let isNew = modificationDate != loadedModificationDate
            && modificationDate != failedModificationDate
        if force || isNew {
            loadSnapshotFile(modificationDate: modificationDate)
        }
    }

    private func loadSnapshotFile(modificationDate: Date) {
        guard let data = FileManager.default.contents(atPath: snapshotPath),
              let decoded = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else {
            failedModificationDate = modificationDate
            return
        }
        failedModificationDate = nil
        loadedModificationDate = modificationDate
        if modificationDate != ownWriteModificationDate {
            // Only a write by someone else (the main app) means we are no
            // longer feeding ourselves; a forced reload of our own write
            // must keep the 10 s self-feed cadence intact.
            lastDataFromFallback = false
        }
        snapshot = decoded.qualified(by: id)
        snapshotDate = WidgetTimestampParser.date(from: decoded.collectedAt) ?? modificationDate
        lastUpdate = Date()
        errorMessage = nil
        setNotice(nil)
    }

    private func recomputeStatus() {
        let next: WidgetDataStatus
        if snapshot == nil {
            next = (errorMessage == nil && notice == nil) ? .connecting : .offline
        } else if let age = snapshotAge, age <= WidgetLayout.staleThreshold {
            next = .live
        } else {
            next = .cached
        }
        // Guarded: this runs on every 2 s poll and an unconditional
        // assignment would repaint the whole widget each time.
        if status != next {
            status = next
        }
    }

    private func setNotice(_ value: String?) {
        if notice != value {
            notice = value
        }
    }

    // MARK: Fallback collection

    /// At most one collection per 10 s per cluster, even for a manual
    /// refresh, and never two at once for the same cluster: every attempt
    /// is an SSH round-trip through the user's ControlMaster. Both rules are
    /// kept in CollectionLedger (keyed by cluster id) rather than on this
    /// feed, so they survive the feed being replaced mid-collection.
    private func collectIfNeeded() {
        guard !isRefreshing, !CollectionLedger.inFlight.contains(id) else {
            return
        }
        if let lastAttempt = CollectionLedger.lastAttempt[id],
           Date().timeIntervalSince(lastAttempt) < WidgetLayout.refreshInterval {
            return
        }

        let collector: ValidatedCollector
        switch CollectorLoader.load(clusterID: id, directory: directory, projectRoot: projectRoot) {
        case .missing:
            // The app has never connected to this cluster (or has not since
            // the upgrade), so there is no password-free invocation to reuse.
            setNotice(
                snapshot == nil
                    ? "Connect to \(displayName) in Leeds HPC Monitor to start monitoring it."
                    : "Leeds HPC Monitor is not updating \(displayName); reconnect it in the app."
            )
            recomputeStatus()
            return
        case .invalid(let message):
            // Throttled like a real attempt so a broken record is not
            // re-validated (and re-reported) on every 2 s poll.
            CollectionLedger.lastAttempt[id] = Date()
            if errorMessage != message {
                errorMessage = message
            }
            recomputeStatus()
            return
        case .ready(let validated):
            collector = validated
        }

        setNotice(nil)
        let clusterID = id
        CollectionLedger.lastAttempt[clusterID] = Date()
        CollectionLedger.inFlight.insert(clusterID)
        isRefreshing = true
        Task {
            defer {
                isRefreshing = false
                CollectionLedger.inFlight.remove(clusterID)
            }
            do {
                let result = try await SnapshotRunner.collect(projectRoot: projectRoot, collector: collector)
                apply(result)
            } catch {
                errorMessage = error.localizedDescription
            }
            recomputeStatus()
        }
    }

    private func apply(_ result: CollectionResult) {
        guard isActive else {
            // The cluster was disabled or its directory removed while the
            // collector ran; do not resurrect its snapshot file.
            return
        }
        // Pick up anything the main app wrote while the collector ran, so
        // the comparison below sees the newest data on disk.
        reloadIfChanged(force: false)

        guard result.isClean, let collected = result.snapshot else {
            errorMessage = result.failureMessage ?? "Refresh failed."
            return
        }
        if let info = collected.cluster, info.id != id {
            errorMessage = "The collector answered for cluster '\(info.id)', not '\(id)'; check \(directory)/collector.json."
            return
        }
        let collectedDate = WidgetTimestampParser.date(from: collected.collectedAt)
        if let existing = snapshotDate, let collectedDate, collectedDate <= existing {
            // The main app wrote a newer snapshot while the fallback
            // collection ran; keep the newer data.
            errorMessage = nil
            return
        }

        do {
            // Atomic replace: the app (and the directory watchers) only ever
            // see a complete file.
            try result.output.write(to: URL(fileURLWithPath: snapshotPath), options: .atomic)
            errorMessage = nil
        } catch {
            errorMessage = "Collected a snapshot but could not save it: \(error.localizedDescription)"
        }
        snapshot = collected.qualified(by: id)
        snapshotDate = collectedDate ?? Date()
        lastDataFromFallback = true
        // Remember our own write so the watcher does not redundantly reload
        // it and so a forced reload of it is recognized as our own write.
        loadedModificationDate = fileModificationDate(atPath: snapshotPath)
        ownWriteModificationDate = loadedModificationDate
        lastUpdate = Date()
    }
}

// MARK: - Per-cluster digest

/// Everything one cluster row shows, derived from that cluster's snapshot
/// alone. GPU numbers follow the app's gpuAvailability: "free" counts idle
/// GPUs on nodes that can actually run jobs.
struct ClusterDigest {
    let gpuNodes: [WidgetNode]
    let gpuTotal: Int
    let gpuAllocated: Int
    let gpuIdle: Int
    /// "H200", "L40S", or "L40S + A100" for a mixed pool; nil when the gres
    /// strings carry no model.
    let gpuModel: String?
    let unavailableGPUNodes: Int
    let running: [WidgetJob]
    let pending: [WidgetJob]

    init(snapshot: WidgetSnapshot?) {
        let nodes = snapshot?.nodes ?? []
        let gpuNodes = nodes.filter { $0.gpuTotalValue > 0 }
        self.gpuNodes = gpuNodes
        gpuTotal = gpuNodes.reduce(0) { $0 + $1.gpuTotalValue }
        gpuAllocated = gpuNodes.reduce(0) { $0 + min($1.gpuAllocatedValue, $1.gpuTotalValue) }
        gpuIdle = gpuNodes.filter(\.isAvailable).reduce(0) { $0 + $1.gpuIdleValue }
        unavailableGPUNodes = gpuNodes.filter { !$0.isAvailable }.count
        gpuModel = Self.modelSummary(gpuNodes)

        let jobs = snapshot?.jobs ?? []
        running = jobs.filter { $0.state.uppercased().contains("RUN") }
        pending = jobs.filter { $0.state.uppercased().contains("PEND") }
    }

    /// The first running job in squeue order, else the first pending one.
    var topJob: WidgetJob? {
        running.first ?? pending.first
    }

    /// Idle GPUs on drained/down nodes: neither allocated nor usable.
    var unavailableGPUs: Int {
        max(gpuTotal - gpuAllocated - gpuIdle, 0)
    }

    var gpuRatio: Double {
        guard gpuTotal > 0 else {
            return 0
        }
        return min(Double(gpuAllocated) / Double(gpuTotal), 1)
    }

    var gpuPercent: Int {
        Int((gpuRatio * 100).rounded())
    }

    var gpuColor: Color {
        WidgetPalette.gpuColor(allocatedRatio: gpuRatio)
    }

    var fullyFreeNodes: Int {
        gpuNodes.filter { $0.isAvailable && $0.gpuAllocatedValue == 0 }.count
    }

    var fullyAllocatedNodes: Int {
        gpuNodes.filter { $0.isAvailable && $0.gpuAllocatedValue >= $0.gpuTotalValue }.count
    }

    /// Models ranked by GPU count, at most two, so a mixed pool is labelled
    /// honestly instead of by whichever node happened to come first.
    private static func modelSummary(_ nodes: [WidgetNode]) -> String? {
        var counts: [String: Int] = [:]
        var firstSeen: [String] = []
        for node in nodes {
            guard let raw = WidgetGresParser.gpuModel(in: node.gres ?? "") else {
                continue
            }
            let name = WidgetGresParser.displayName(forModel: raw)
            if counts[name] == nil {
                firstSeen.append(name)
            }
            counts[name, default: 0] += node.gpuTotalValue
        }
        let ranked = firstSeen.enumerated().sorted { lhs, rhs in
            let lhsCount = counts[lhs.element] ?? 0
            let rhsCount = counts[rhs.element] ?? 0
            if lhsCount != rhsCount {
                return lhsCount > rhsCount
            }
            return lhs.offset < rhs.offset
        }
        guard !ranked.isEmpty else {
            return nil
        }
        return ranked.prefix(2).map(\.element).joined(separator: " + ")
    }
}

// MARK: - Views

struct DesktopWidgetView: View {
    @StateObject private var model = WidgetModel()

    private var visibleFeeds: [ClusterFeed] {
        Array(model.feeds.prefix(WidgetLayout.maxVisibleClusters))
    }

    private var hiddenFeedCount: Int {
        max(model.feeds.count - WidgetLayout.maxVisibleClusters, 0)
    }

    private var windowHeight: CGFloat {
        WidgetLayout.height(forClusterRows: visibleFeeds.count)
    }

    var body: some View {
        ZStack {
            WidgetVisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(WidgetPalette.backgroundOverlay)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(WidgetPalette.border, lineWidth: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(WidgetPalette.highlight, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.18), radius: 22, x: 0, y: 10)

            VStack(alignment: .leading, spacing: WidgetLayout.sectionSpacing) {
                header
                    .frame(height: WidgetLayout.headerHeight)

                if visibleFeeds.isEmpty {
                    EmptyClustersCard {
                        model.openMainApp()
                    }
                    .frame(height: WidgetLayout.clusterRowHeight)
                } else {
                    VStack(spacing: WidgetLayout.clusterRowSpacing) {
                        ForEach(visibleFeeds) { feed in
                            ClusterRow(feed: feed)
                                .frame(height: WidgetLayout.clusterRowHeight)
                                .transition(.opacity)
                        }
                    }
                }

                footer
                    .frame(height: WidgetLayout.footerHeight)
            }
            .padding(.horizontal, WidgetLayout.horizontalPadding)
            .padding(.vertical, WidgetLayout.verticalPadding)
        }
        .frame(width: WidgetLayout.width, height: windowHeight, alignment: .topLeading)
        .background(
            DesktopWindowConfigurator(contentSize: NSSize(width: WidgetLayout.width, height: windowHeight))
        )
        .ignoresSafeArea()
        .contextMenu {
            Button(model.feeds.count > 1 ? "Refresh All" : "Refresh") {
                model.refresh()
            }
            if model.feeds.count > 1 {
                ForEach(model.feeds) { feed in
                    Button("Refresh \(feed.displayName)") {
                        model.refresh(clusterID: feed.id)
                    }
                }
            }
            Button("Open Leeds HPC Monitor") {
                model.openMainApp()
            }
            Divider()
            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: visibleFeeds.map(\.id))
        .task {
            model.start()
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            WidgetLogoMark()
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)

            Text("Leeds HPC")
                .font(.title3.weight(.semibold))
                .singleLine()

            StatusChip(
                title: overallStatus.title,
                value: overallStatus.value,
                color: overallStatus.color
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Overall status")
            .accessibilityValue("\(overallStatus.title), \(overallStatus.value)")

            Spacer()

            Button {
                model.openMainApp()
            } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(WidgetIconButtonStyle())
            .help("Open Leeds HPC Monitor")
            .accessibilityLabel("Open Leeds HPC Monitor")

            Button {
                model.refresh()
            } label: {
                if model.isAnyRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(WidgetIconButtonStyle())
            .disabled(model.feeds.isEmpty)
            .help(model.feeds.count > 1 ? "Refresh all clusters" : "Refresh")
            .accessibilityLabel(model.feeds.count > 1 ? "Refresh all clusters" : "Refresh")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(WidgetIconButtonStyle())
            .help("Close widget")
            .accessibilityLabel("Close widget")
        }
    }

    /// How the feeds are doing as a whole. Deliberately a count of clusters,
    /// never a sum of their numbers.
    private var overallStatus: (title: String, value: String, color: Color) {
        let feeds = model.feeds
        guard !feeds.isEmpty else {
            return ("waiting", "no clusters yet", WidgetPalette.neutral)
        }
        let live = feeds.filter { $0.status == .live }.count
        let cached = feeds.filter { $0.status == .cached }.count
        let offline = feeds.filter { $0.status == .offline }.count
        if live == feeds.count {
            return ("live", feeds.count == 1 ? feeds[0].displayName : "all \(feeds.count) clusters", WidgetPalette.green)
        }
        if live > 0 {
            return ("partial", "\(live) of \(feeds.count) live", WidgetPalette.orange)
        }
        if cached > 0 {
            return ("cached", "\(cached) of \(feeds.count) cached", WidgetPalette.orange)
        }
        if offline == feeds.count {
            return ("offline", "no data", WidgetPalette.red)
        }
        return ("connecting", "waiting", WidgetPalette.neutral)
    }

    private var footer: some View {
        let presentation = footerPresentation
        let color = presentation.isWarning ? WidgetPalette.orange : WidgetPalette.green

        return HStack(alignment: .center, spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.28), radius: 3, x: 0, y: 0)
            Text(presentation.message)
                .font(.caption2)
                .foregroundColor(presentation.isWarning ? .primary : .secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .minimumScaleFactor(0.9)
            Spacer()
            Text("\(Int(WidgetLayout.refreshInterval))s")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .singleLine()
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(
            presentation.isWarning ? WidgetPalette.orange.opacity(0.12) : WidgetPalette.fill,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(presentation.isWarning ? WidgetPalette.orange.opacity(0.18) : WidgetPalette.border, lineWidth: 1)
        )
        .help(presentation.message)
        .accessibilityElement(children: .combine)
    }

    /// Most important message first: launching, widget errors, per-cluster
    /// errors (always prefixed with the cluster name), then notices.
    private var footerPresentation: (message: String, isWarning: Bool) {
        var message: String
        var isWarning = true
        let feeds = model.feeds
        let problems = feeds.compactMap { feed in
            feed.errorMessage.map { "\(feed.displayName): \($0)" }
        }
        let notices = feeds.compactMap(\.notice)
        let cachedNames = feeds.filter { $0.status == .cached }.map(\.displayName)

        if let launchMessage = model.launchMessage {
            message = launchMessage
            isWarning = false
        } else if let error = model.errorMessage, !error.isEmpty {
            message = error
        } else if !problems.isEmpty {
            message = problems.joined(separator: " · ")
        } else if !notices.isEmpty {
            message = notices.joined(separator: " ")
        } else if !cachedNames.isEmpty {
            message = "\(cachedNames.joined(separator: " and ")): showing cached data; waiting for a fresh snapshot."
        } else if feeds.isEmpty {
            message = "Waiting for Leeds HPC Monitor to write a cluster snapshot."
            isWarning = false
        } else if let lastUpdate = feeds.compactMap(\.lastUpdate).max() {
            message = "Updated \(lastUpdate.formatted(date: .omitted, time: .standard)) · refreshes every \(Int(WidgetLayout.refreshInterval)) seconds"
            isWarning = false
        } else {
            message = "Refreshes every \(Int(WidgetLayout.refreshInterval)) seconds"
            isWarning = false
        }
        if hiddenFeedCount > 0 {
            message += " (+\(hiddenFeedCount) more \(hiddenFeedCount == 1 ? "cluster" : "clusters") not shown)"
        }
        return (message, isWarning)
    }
}

/// One cluster: identity and status on top, then its GPU pool, its jobs and
/// its GPU-node heatmap. Every number in the row belongs to this cluster.
struct ClusterRow: View {
    @ObservedObject var feed: ClusterFeed

    var body: some View {
        let digest = ClusterDigest(snapshot: feed.snapshot)
        VStack(alignment: .leading, spacing: 6) {
            titleLine
                .frame(height: 20)

            HStack(alignment: .center, spacing: 12) {
                gpuGauge(digest)
                Rectangle()
                    .fill(WidgetPalette.border)
                    .frame(width: 1)
                    .padding(.vertical, 4)
                activity(digest)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetSurface()
        .animation(.easeInOut(duration: 0.28), value: digest.gpuAllocated)
        .animation(.easeInOut(duration: 0.28), value: digest.gpuTotal)
        .animation(.easeInOut(duration: 0.28), value: digest.running.count)
        .animation(.easeInOut(duration: 0.28), value: digest.pending.count)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(feed.displayName)
    }

    private var titleLine: some View {
        HStack(spacing: 7) {
            ClusterMonogram(clusterID: feed.id, name: feed.displayName)

            Text(feed.displayName)
                .font(.system(size: 14, weight: .semibold))
                .singleLine()
                .contentTransition(.opacity)

            StatusChip(title: feed.status.title, value: chipValue, color: feed.status.color)
                .help(chipHelp)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(feed.displayName) status")
                .accessibilityValue("\(feed.status.title), \(chipValue)")

            Spacer(minLength: 6)

            if feed.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Collecting \(feed.displayName) snapshot")
            }

            Text(timestampText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(feed.status == .cached ? WidgetPalette.orange : Color.secondary)
                .singleLine()
                .contentTransition(.opacity)
                .accessibilityLabel("\(feed.displayName) snapshot time")
                .accessibilityValue(timestampText)
        }
    }

    private var chipValue: String {
        switch feed.status {
        case .live, .cached:
            return feed.remoteName ?? "login node"
        case .connecting:
            return "waiting"
        case .offline:
            return "no data"
        }
    }

    /// Errors and notices first; otherwise the collector's warnings (an
    /// enrichment step such as storage or job details that failed while the
    /// core data is fine). Tooltip only: the row has no room for them, and
    /// they never make the snapshot less trustworthy for what the row shows.
    private var chipHelp: String {
        if let message = feed.errorMessage ?? feed.notice {
            return message
        }
        let warnings = feed.snapshot?.warnings ?? []
        guard !warnings.isEmpty else {
            return chipValue
        }
        let shown = warnings.prefix(3).joined(separator: "\n")
        let more = warnings.count > 3 ? "\n(+\(warnings.count - 3) more)" : ""
        return "\(chipValue)\n\(shown)\(more)"
    }

    private var timestampText: String {
        guard let snapshotDate = feed.snapshotDate else {
            return feed.status == .connecting ? "waiting" : "not updated"
        }
        let isToday = Calendar.current.isDateInToday(snapshotDate)
        switch feed.status {
        case .cached:
            return "data from \(snapshotDate.formatted(date: isToday ? .omitted : .abbreviated, time: .shortened))"
        case .live, .connecting, .offline:
            return snapshotDate.formatted(date: .omitted, time: .standard)
        }
    }

    private func gpuGauge(_ digest: ClusterDigest) -> some View {
        let hasGPUs = digest.gpuTotal > 0
        let model = digest.gpuModel ?? "GPU"
        return HStack(spacing: 10) {
            RingMeter(
                value: digest.gpuRatio,
                color: digest.gpuColor,
                label: hasGPUs ? "\(digest.gpuPercent)%" : "–",
                lineWidth: 6
            )
            .frame(width: 52, height: 52)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(feed.displayName) \(model) GPU usage")
            .accessibilityValue(
                hasGPUs
                    ? "\(digest.gpuAllocated) of \(digest.gpuTotal) GPUs allocated, \(digest.gpuPercent) percent"
                    : "No GPU data"
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(model)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(ClusterStyle.accent(for: feed.id))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(ClusterStyle.accent(for: feed.id).opacity(0.14), in: Capsule())
                        .singleLine()
                    Text("free")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .singleLine()
                }

                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(hasGPUs ? "\(digest.gpuIdle)" : "–")
                        .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(idleColor(digest))
                        .contentTransition(.opacity)
                    if hasGPUs {
                        Text("/\(digest.gpuTotal)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .singleLine()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(feed.displayName) free \(model) GPUs")
                .accessibilityValue(hasGPUs ? "\(digest.gpuIdle) of \(digest.gpuTotal)" : "No GPU data")

                GPUUsageBar(
                    allocated: digest.gpuAllocated,
                    unavailable: digest.unavailableGPUs,
                    total: digest.gpuTotal,
                    color: digest.gpuColor
                )
                .accessibilityHidden(true)
            }
            .frame(width: 112, alignment: .leading)
        }
    }

    private func idleColor(_ digest: ClusterDigest) -> Color {
        guard digest.gpuTotal > 0 else {
            return .secondary
        }
        return digest.gpuIdle > 0 ? WidgetPalette.green : WidgetPalette.orange
    }

    private func activity(_ digest: ClusterDigest) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                // Unknown is not zero: without a snapshot the pills show a dash.
                let hasData = feed.snapshot != nil
                JobCountPill(title: "Run", value: hasData ? digest.running.count : nil, color: WidgetPalette.green)
                    .accessibilityLabel("\(feed.displayName) running jobs")
                JobCountPill(title: "Wait", value: hasData ? digest.pending.count : nil, color: WidgetPalette.orange)
                    .accessibilityLabel("\(feed.displayName) pending jobs")
                Spacer(minLength: 4)
                if digest.unavailableGPUNodes > 0 {
                    Label("\(digest.unavailableGPUNodes) down", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(WidgetPalette.red)
                        .singleLine()
                        .help("\(digest.unavailableGPUNodes) GPU node(s) drained, down or in maintenance")
                        .accessibilityLabel("\(digest.unavailableGPUNodes) GPU nodes unavailable on \(feed.displayName)")
                }
            }

            jobLine(digest)
                .frame(height: 16)

            HStack(spacing: 8) {
                GPUHeatmapStrip(nodes: digest.gpuNodes, clusterName: feed.displayName)
                Text("\(digest.gpuNodes.count) \(digest.gpuNodes.count == 1 ? "node" : "nodes")")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .frame(height: 12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(feed.displayName) GPU nodes")
            .accessibilityValue(
                "\(digest.gpuNodes.count) nodes: \(digest.fullyFreeNodes) fully free, "
                    + "\(digest.fullyAllocatedNodes) fully allocated, \(digest.unavailableGPUNodes) unavailable"
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func jobLine(_ digest: ClusterDigest) -> some View {
        if feed.snapshot == nil {
            Label(
                feed.status == .connecting ? "Waiting for the first snapshot" : "No snapshot yet",
                systemImage: "hourglass"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .singleLine()
        } else if let job = digest.topJob {
            TopJobRow(job: job, clusterName: feed.displayName)
        } else {
            Label("No active jobs", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(WidgetPalette.green)
                .singleLine()
        }
    }
}

/// Shown until the app has written at least one cluster directory.
struct EmptyClustersCard: View {
    let onOpenApp: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("No clusters yet")
                    .font(.callout.weight(.semibold))
                Text("Open Leeds HPC Monitor and connect; each cluster appears here after its first snapshot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Open Monitor", action: onOpenApp)
                .controlSize(.small)
                .help("Open Leeds HPC Monitor")
                .accessibilityLabel("Open Leeds HPC Monitor")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetSurface()
    }
}

struct WidgetIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 25, height: 25)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? WidgetPalette.fillStrong : WidgetPalette.fill)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(WidgetPalette.border, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct StatusChip: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .fontWeight(.semibold)
            Text(value)
                .foregroundStyle(.secondary)
                .truncationMode(.middle)
        }
        .font(.caption2)
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: 200, alignment: .leading)
        .background(color.opacity(0.10), in: Capsule())
        .background(.thinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(color.opacity(0.15), lineWidth: 1)
        )
    }
}

private extension View {
    func widgetSurface() -> some View {
        self
            .padding(10)
            .background(WidgetPalette.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(WidgetPalette.border, lineWidth: 1)
            )
    }

    func singleLine() -> some View {
        self
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .truncationMode(.tail)
    }
}

struct RingMeter: View {
    let value: Double
    let color: Color
    let label: String
    var lineWidth: CGFloat = 8

    var body: some View {
        ZStack {
            Circle()
                .stroke(WidgetPalette.fillStrong, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(value, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.32), value: value)
            Text(label)
                .font(.caption.monospacedDigit().weight(.bold))
                .singleLine()
        }
        .padding(lineWidth / 2)
    }
}

/// Allocated GPUs in the usage colour, idle GPUs on unavailable nodes in red,
/// and the free remainder as the green track.
struct GPUUsageBar: View {
    let allocated: Int
    let unavailable: Int
    let total: Int
    let color: Color

    private func fraction(_ value: Int) -> Double {
        guard total > 0 else {
            return 0
        }
        return min(max(Double(value) / Double(total), 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let allocatedWidth = width * fraction(allocated)
            let unavailableWidth = min(width * fraction(unavailable), width - allocatedWidth)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(WidgetPalette.green.opacity(0.16))
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(color.opacity(0.88))
                        .frame(width: allocatedWidth)
                    Rectangle()
                        .fill(WidgetPalette.red.opacity(0.62))
                        .frame(width: max(unavailableWidth, 0))
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .animation(.easeInOut(duration: 0.32), value: allocated)
                .animation(.easeInOut(duration: 0.32), value: unavailable)
            }
        }
        .frame(height: 8)
    }
}

struct JobCountPill: View {
    let title: String
    /// nil while the cluster has no snapshot yet.
    let value: Int?
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Text(value.map(String.init) ?? "–")
                .monospacedDigit()
                .fontWeight(.semibold)
        }
        .font(.caption2)
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
        .background(.thinMaterial, in: Capsule())
        .foregroundStyle(color)
        .overlay(
            Capsule()
                .stroke(color.opacity(0.14), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value.map(String.init) ?? "unknown")
    }
}

/// The cluster's headline job: name first (it is what the user recognises),
/// then partition and elapsed time.
struct TopJobRow: View {
    let job: WidgetJob
    let clusterName: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(WidgetPalette.jobStateColor(job.state))
                .frame(width: 6, height: 6)
            Text(job.name.isEmpty ? "Job \(job.jobId)" : job.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Text(job.partition)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(job.elapsed)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .help("\(clusterName) job \(job.jobId) · \(job.state) · \(job.partition) · \(job.elapsed)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(clusterName) top job \(job.name)")
        .accessibilityValue("\(job.state.lowercased()), partition \(job.partition), elapsed \(job.elapsed)")
    }
}

struct GPUHeatmapStrip: View {
    let nodes: [WidgetNode]
    let clusterName: String

    var body: some View {
        GeometryReader { proxy in
            let count = max(nodes.count, 1)
            // Tighter gaps for large pools so every node keeps a visible cell.
            let spacing: CGFloat = count > 24 ? 1.5 : 3
            let width = max((proxy.size.width - spacing * CGFloat(count - 1)) / CGFloat(count), 2)
            if nodes.isEmpty {
                RoundedRectangle(cornerRadius: 3)
                    .fill(WidgetPalette.fillStrong)
                    .frame(height: proxy.size.height)
            } else {
                HStack(spacing: spacing) {
                    ForEach(nodes) { node in
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(WidgetPalette.heatmapColor(for: node))
                            .frame(width: width, height: proxy.size.height)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2.5)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                            .help("\(clusterName) \(node.node): \(node.gpuAllocatedValue)/\(node.gpuTotalValue) GPU, \(node.state)")
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            }
        }
    }
}

private struct WidgetVisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}

// MARK: - Fallback collector

/// The app's password-free record of how it runs the collector for one
/// cluster: `.runtime/clusters/<id>/collector.json`.
private struct CollectorInvocation: Decodable {
    let updatedAt: String?
    let script: String
    let arguments: [String]
}

/// A collector invocation that passed validation and is safe to execute.
struct ValidatedCollector {
    let scriptPath: String
    let arguments: [String]
    let deadline: TimeInterval
}

enum CollectorLoadResult {
    case missing
    case invalid(String)
    case ready(ValidatedCollector)
}

enum CollectorLoader {
    static func load(clusterID: String, directory: String, projectRoot: String) -> CollectorLoadResult {
        let path = "\(directory)/collector.json"
        guard let data = FileManager.default.contents(atPath: path) else {
            return .missing
        }
        let invocation: CollectorInvocation
        do {
            invocation = try JSONDecoder().decode(CollectorInvocation.self, from: data)
        } catch {
            return .invalid("Unreadable collector record \(path): \(error.localizedDescription)")
        }
        // The file sits in this cluster's directory, so it must describe this
        // cluster; anything else would write one cluster's data into
        // another's snapshot.
        if let recorded = argumentValue("--cluster-id", in: invocation.arguments), recorded != clusterID {
            return .invalid("\(path) is for cluster '\(recorded)', not '\(clusterID)'; reconnect in Leeds HPC Monitor.")
        }
        do {
            let scriptPath = try validatedScriptPath(invocation.script, projectRoot: projectRoot)
            return .ready(
                ValidatedCollector(
                    scriptPath: scriptPath,
                    arguments: invocation.arguments,
                    deadline: SnapshotRunner.processDeadline(arguments: invocation.arguments)
                )
            )
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    /// The recorded script must be a relative path inside the project root
    /// (no absolute path, no `..`, and not a symlink escaping the checkout)
    /// and must exist: `.runtime` is a plain directory, and this is the only
    /// thing the widget ever executes from it.
    static func validatedScriptPath(_ script: String, projectRoot: String) throws -> String {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~"),
              !trimmed.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            throw WidgetError.message("Refusing collector script '\(script)': it must be a relative path inside the project.")
        }
        let root = URL(fileURLWithPath: projectRoot).standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = URL(fileURLWithPath: root)
            .appendingPathComponent(trimmed)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        guard candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
            throw WidgetError.message("Refusing collector script '\(script)': it resolves outside \(root).")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw WidgetError.message("Missing collector script at \(candidate).")
        }
        return candidate
    }

    /// Value of `--flag value` or `--flag=value`.
    static func argumentValue(_ flag: String, in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == flag {
                return index + 1 < arguments.count ? arguments[index + 1] : nil
            }
            if argument.hasPrefix(flag + "=") {
                return String(argument.dropFirst(flag.count + 1))
            }
        }
        return nil
    }
}

struct CollectionResult {
    /// Collector stdout byte for byte; this is what gets written to disk.
    let output: Data
    let snapshot: WidgetSnapshot?
    /// Exit 0, decoded, no collector errors and no watchdog timeout: the
    /// only outcome that may replace the cluster's snapshot file.
    let isClean: Bool
    let failureMessage: String?
}

enum SnapshotRunner {
    /// hpc_snapshot.py's own default for --timeout (its DEFAULT_TIMEOUT),
    /// used when the recorded arguments carry none.
    static let defaultCollectorTimeout = 30
    /// Watchdog headroom above the collector's own budget: interpreter
    /// start-up, the collector reaping its timed-out ssh child, and JSON
    /// assembly. Twice the app's 10 s on purpose (see processDeadline).
    private static let deadlineHeadroom: TimeInterval = 20
    private static let killGracePeriod: TimeInterval = 3
    private static let maxCapturedOutputBytes = 8 * 1024 * 1024
    private static let maxMessageLength = 400

    /// hpc_snapshot.py collects everything (jobs, job details, partitions,
    /// nodes, storage) in ONE batched SSH round trip, and its --timeout is
    /// the budget for the WHOLE run, socket probe included: it prints its
    /// JSON (partial, with a warning, if storage stalled) before that budget
    /// runs out. So the watchdog only has to sit comfortably above the
    /// budget. The app allows budget + 10 s; the widget allows more, because
    /// killing a slow but healthy collection throws away a good snapshot
    /// and the next attempt cannot start for another 10 s anyway, while a
    /// wedged child still gets killed. With the app's --timeout 30 the
    /// deadline is 50 s.
    static func processDeadline(arguments: [String]) -> TimeInterval {
        let recorded = CollectorLoader.argumentValue("--timeout", in: arguments).flatMap { Int($0) }
        let budget = min(max(recorded ?? defaultCollectorTimeout, 1), 300)
        return TimeInterval(budget) + deadlineHeadroom
    }

    static func collect(projectRoot: String, collector: ValidatedCollector) async throws -> CollectionResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [collector.scriptPath] + collector.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: projectRoot)

        let outcome = try await execute(process, deadline: collector.deadline)
        let stderrText = String(data: outcome.stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let timeoutText = outcome.timedOut
            ? "Snapshot collection timed out after \(Int(collector.deadline)) seconds."
            : nil

        guard let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: outcome.stdout) else {
            let message = combinedMessage([timeoutText, stderrText])
            return CollectionResult(
                output: outcome.stdout,
                snapshot: nil,
                isClean: false,
                failureMessage: message.isEmpty
                    ? "Refresh failed (collector exited with status \(outcome.terminationStatus))."
                    : message
            )
        }
        let scriptErrors = snapshot.errors.joined(separator: "\n")
        let isClean = outcome.terminationStatus == 0 && scriptErrors.isEmpty && !outcome.timedOut
        let message = combinedMessage([timeoutText, scriptErrors.isEmpty ? stderrText : scriptErrors])
        return CollectionResult(
            output: outcome.stdout,
            snapshot: snapshot,
            isClean: isClean,
            failureMessage: isClean ? nil : (message.isEmpty ? "Refresh failed." : message)
        )
    }

    private static func combinedMessage(_ parts: [String?]) -> String {
        let joined = parts
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard joined.count > maxMessageLength else {
            return joined
        }
        return String(joined.prefix(maxMessageLength)) + "…"
    }

    /// Runs the process without blocking a cooperative-pool thread: both
    /// pipes are drained concurrently while the child runs (a full pipe
    /// buffer can otherwise deadlock the child), termination is observed via
    /// terminationHandler before the exit status is read, and a watchdog
    /// escalates SIGTERM to SIGKILL and finally force-completes so the widget
    /// can never hang on a wedged child or an inherited pipe descriptor.
    private static func execute(_ process: Process, deadline: TimeInterval) async throws -> ProcessOutcome {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let state = RunnerState(outputLimit: maxCapturedOutputBytes)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            state.drain(handle, stream: .stdout)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            state.drain(handle, stream: .stderr)
        }
        process.terminationHandler = { finished in
            state.processExited(status: finished.terminationStatus)
        }

        try process.run()
        let pid = process.processIdentifier

        let watchdog = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
            guard state.markTimedOutIfRunning() else {
                return
            }
            kill(pid, SIGTERM)
            try? await Task.sleep(nanoseconds: UInt64(killGracePeriod * 1_000_000_000))
            if !state.hasExited {
                kill(pid, SIGKILL)
            }
            try? await Task.sleep(nanoseconds: UInt64(killGracePeriod * 1_000_000_000))
            state.forceFinish()
        }

        let outcome = await withCheckedContinuation { continuation in
            state.install(continuation)
        }
        watchdog.cancel()
        return outcome
    }
}

private struct ProcessOutcome {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data
    let timedOut: Bool
}

private final class RunnerState: @unchecked Sendable {
    enum Stream {
        case stdout
        case stderr
    }

    private let lock = NSLock()
    private let outputLimit: Int
    private var stdoutData = Data()
    private var stderrData = Data()
    private var stdoutClosed = false
    private var stderrClosed = false
    private var exitStatus: Int32?
    private var timedOut = false
    private var finished = false
    private var continuation: CheckedContinuation<ProcessOutcome, Never>?

    init(outputLimit: Int) {
        self.outputLimit = outputLimit
    }

    var hasExited: Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return exitStatus != nil
    }

    func drain(_ handle: FileHandle, stream: Stream) {
        let chunk = handle.availableData
        lock.lock()
        var detach = finished
        if chunk.isEmpty {
            detach = true
            switch stream {
            case .stdout:
                stdoutClosed = true
            case .stderr:
                stderrClosed = true
            }
        } else if !finished {
            switch stream {
            case .stdout:
                if stdoutData.count < outputLimit {
                    stdoutData.append(chunk.prefix(outputLimit - stdoutData.count))
                }
            case .stderr:
                if stderrData.count < outputLimit {
                    stderrData.append(chunk.prefix(outputLimit - stderrData.count))
                }
            }
        }
        let resume = completionIfReadyLocked()
        lock.unlock()
        if detach {
            handle.readabilityHandler = nil
        }
        resume?()
    }

    func processExited(status: Int32) {
        lock.lock()
        exitStatus = status
        let resume = completionIfReadyLocked()
        lock.unlock()
        resume?()
    }

    func markTimedOutIfRunning() -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard !finished, exitStatus == nil else {
            return false
        }
        timedOut = true
        return true
    }

    /// Last-resort completion for a child (or an ssh grandchild that
    /// inherited the pipe) that never closes stdout/stderr even after
    /// SIGKILL: resume with whatever output was captured.
    func forceFinish() {
        lock.lock()
        let resume = finishLocked()
        lock.unlock()
        resume?()
    }

    func install(_ continuation: CheckedContinuation<ProcessOutcome, Never>) {
        lock.lock()
        self.continuation = continuation
        let resume = completionIfReadyLocked()
        lock.unlock()
        resume?()
    }

    private func completionIfReadyLocked() -> (() -> Void)? {
        guard stdoutClosed, stderrClosed, exitStatus != nil else {
            return nil
        }
        return finishLocked()
    }

    private func finishLocked() -> (() -> Void)? {
        guard !finished, let continuation = self.continuation else {
            return nil
        }
        finished = true
        self.continuation = nil
        let outcome = ProcessOutcome(
            terminationStatus: exitStatus ?? -1,
            stdout: stdoutData,
            stderr: stderrData,
            timedOut: timedOut
        )
        return {
            continuation.resume(returning: outcome)
        }
    }
}

enum ProjectLocator {
    /// Present in every checkout of this repository; also what the app uses
    /// to recognise a project root.
    static let markerScript = "scripts/hpc_snapshot.py"

    static func findProjectRoot() -> String {
        let environment = ProcessInfo.processInfo.environment
        // HPC_PROJECT_ROOT is the current name; AIRE_PROJECT_ROOT is the
        // pre-multi-cluster one, still honoured.
        for key in ["HPC_PROJECT_ROOT", "AIRE_PROJECT_ROOT"] {
            if let value = environment[key], hasMarker(value) {
                return value
            }
        }

        let current = FileManager.default.currentDirectoryPath
        if hasMarker(current) {
            return current
        }

        // <root>/.runtime/AIREDesktopWidget.app -> <root>
        let bundleRoot = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        if hasMarker(bundleRoot) {
            return bundleRoot
        }

        return current
    }

    private static func hasMarker(_ root: String) -> Bool {
        FileManager.default.fileExists(atPath: "\(root)/\(markerScript)")
    }
}

enum WidgetTimestampParser {
    /// Parses the snapshot's collected_at field. The python collector emits
    /// datetime.isoformat() with microseconds (e.g.
    /// "2026-07-19T12:34:56.789012+00:00"), which ISO8601DateFormatter cannot
    /// parse directly, so fractional seconds are stripped before the second
    /// attempt.
    static func date(from raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) {
            return date
        }
        guard let dotIndex = raw.firstIndex(of: ".") else {
            return nil
        }
        let tail = raw[raw.index(after: dotIndex)...].drop(while: { $0.isNumber })
        return formatter.date(from: String(raw[..<dotIndex]) + String(tail))
    }
}

enum WidgetError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text):
            return text
        }
    }
}

// MARK: - Snapshot decoding (re-declared: the widget shares no code with the app)

/// Which cluster a snapshot came from, as echoed by the collector.
struct WidgetClusterInfo: Decodable {
    let id: String
    let name: String
}

/// The subset of the collector/app snapshot JSON the widget shows. Decoding
/// is lenient like the app's: a missing peripheral key must not discard a
/// whole cluster's snapshot.
struct WidgetSnapshot: Decodable {
    let collectedAt: String
    let cluster: WidgetClusterInfo?
    let remote: WidgetRemote
    private(set) var jobs: [WidgetJob]
    private(set) var nodes: [WidgetNode]
    let errors: [String]
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case collectedAt = "collected_at"
        case cluster
        case remote
        case jobs
        case nodes
        case errors
        case warnings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        collectedAt = try container.decodeIfPresent(String.self, forKey: .collectedAt) ?? ""
        cluster = try? container.decodeIfPresent(WidgetClusterInfo.self, forKey: .cluster)
        remote = (try? container.decodeIfPresent(WidgetRemote.self, forKey: .remote)) ?? WidgetRemote()
        jobs = try container.decodeIfPresent([WidgetJob].self, forKey: .jobs) ?? []
        nodes = try container.decodeIfPresent([WidgetNode].self, forKey: .nodes) ?? []
        errors = try container.decodeIfPresent([String].self, forKey: .errors) ?? []
        warnings = (try? container.decodeIfPresent([String].self, forKey: .warnings)) ?? []
    }

    /// Stamps every job and node with its cluster: Slurm job ids and node
    /// names are only unique within one cluster, so SwiftUI identities must
    /// carry the cluster too.
    func qualified(by clusterID: String) -> WidgetSnapshot {
        var copy = self
        copy.jobs = jobs.map { job in
            var job = job
            job.clusterID = clusterID
            return job
        }
        copy.nodes = nodes.map { node in
            var node = node
            node.clusterID = clusterID
            return node
        }
        return copy
    }
}

struct WidgetRemote: Decodable {
    let host: String
    let hostname: String
    let user: String
    let remoteTime: String

    enum CodingKeys: String, CodingKey {
        case host
        case hostname
        case user
        case remoteTime = "remote_time"
    }

    init() {
        host = ""
        hostname = ""
        user = ""
        remoteTime = ""
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        hostname = try container.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        user = try container.decodeIfPresent(String.self, forKey: .user) ?? ""
        remoteTime = try container.decodeIfPresent(String.self, forKey: .remoteTime) ?? ""
    }
}

struct WidgetJob: Decodable, Identifiable {
    let jobId: String
    let partition: String
    let name: String
    let state: String
    let elapsed: String
    /// Set by WidgetSnapshot.qualified(by:); not part of the JSON.
    fileprivate(set) var clusterID = ""

    /// "<cluster>/<job id>": job 1234 on two clusters is two different jobs.
    var id: String {
        "\(clusterID)/\(jobId)"
    }

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case partition
        case name
        case state
        case elapsed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try container.decodeIfPresent(String.self, forKey: .jobId) ?? ""
        partition = try container.decodeIfPresent(String.self, forKey: .partition) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? ""
        elapsed = try container.decodeIfPresent(String.self, forKey: .elapsed) ?? ""
    }
}

enum WidgetGresParser {
    /// Parses GPU counts from Slurm gres strings, tolerating socket/index
    /// suffixes and comma-joined lists: "gpu:nvidia_h200:8(S:0-1)" -> 8,
    /// "gpu:4(IDX:0-3)" -> 4, "gpu:l40s:3,mps:400" -> 3, "gpu" -> 1.
    static func gpuCount(in gres: String) -> Int {
        var total = 0
        for entry in entries(in: gres) {
            let pieces = entry.split(separator: ":")
            guard let kind = pieces.first, kind.lowercased() == "gpu" else {
                continue
            }
            if pieces.count == 1 {
                total += 1
                continue
            }
            guard let last = pieces.last, let value = Int(last.prefix(while: { $0.isNumber })) else {
                continue
            }
            total += value
        }
        return total
    }

    /// Raw model of the first typed GPU entry: "gpu:nvidia_h200:8" ->
    /// "nvidia_h200", "gpu:l40s:3(S:0-1)" -> "l40s"; untyped "gpu:4" -> nil.
    static func gpuModel(in gres: String) -> String? {
        for entry in entries(in: gres) {
            let pieces = entry.split(separator: ":")
            guard pieces.count >= 3, pieces[0].lowercased() == "gpu" else {
                continue
            }
            return String(pieces[1])
        }
        return nil
    }

    /// Same rule as the app's gpuModelDisplayName: "nvidia_h200" -> "H200",
    /// "l40s" -> "L40S".
    static func displayName(forModel rawModel: String) -> String {
        var model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["nvidia_", "nvidia-", "amd_", "amd-"] where model.lowercased().hasPrefix(prefix) {
            model = String(model.dropFirst(prefix.count))
        }
        return model
            .replacingOccurrences(of: "_", with: " ")
            .uppercased()
    }

    /// Comma-separated entries with any "(...)" suffix removed; commas
    /// inside parentheses ("gpu:4(IDX:0,2-3)") do not split entries.
    private static func entries(in gres: String) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        for character in gres {
            switch character {
            case "(":
                depth += 1
            case ")":
                depth = max(depth - 1, 0)
            case "," where depth == 0:
                result.append(current)
                current = ""
            default:
                if depth == 0 {
                    current.append(character)
                }
            }
        }
        result.append(current)
        return result
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

struct WidgetNode: Decodable, Identifiable {
    let node: String
    let state: String
    let gpuTotal: Int?
    let gpuAllocated: Int?
    let gpuIdle: Int?
    let gres: String?
    /// Set by WidgetSnapshot.qualified(by:); not part of the JSON.
    fileprivate(set) var clusterID = ""

    /// "<cluster>/<node>": node names are only unique within one cluster.
    var id: String {
        "\(clusterID)/\(node)"
    }

    var gpuTotalValue: Int {
        if let gpuTotal, gpuTotal > 0 {
            return gpuTotal
        }
        return WidgetGresParser.gpuCount(in: gres ?? "")
    }

    var gpuAllocatedValue: Int {
        gpuAllocated ?? 0
    }

    var gpuIdleValue: Int {
        if let gpuIdle {
            return max(gpuIdle, 0)
        }
        return max(gpuTotalValue - gpuAllocatedValue, 0)
    }

    /// Same rule as the app's SlurmState.isAvailable (SlurmFormatting.swift;
    /// this target cannot import it, so keep the two lists in step): a
    /// trailing "*" means not responding, and draining ("drng"), rebooting
    /// ("boot") or invalid nodes cannot start new work either.
    var isAvailable: Bool {
        let value = state.lowercased()
        if value.hasSuffix("*") {
            return false
        }
        let unavailableMarkers = [
            "maint", "down", "drain", "drng", "fail", "not_responding",
            "inval", "boot", "cancel", "timeout", "out_of_me"
        ]
        return !unavailableMarkers.contains { value.contains($0) }
    }

    enum CodingKeys: String, CodingKey {
        case node
        case state
        case gpuTotal = "gpu_total"
        case gpuAllocated = "gpu_allocated"
        case gpuIdle = "gpu_idle"
        case gres
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        node = try container.decodeIfPresent(String.self, forKey: .node) ?? ""
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? ""
        gpuTotal = try? container.decodeIfPresent(Int.self, forKey: .gpuTotal)
        gpuAllocated = try? container.decodeIfPresent(Int.self, forKey: .gpuAllocated)
        gpuIdle = try? container.decodeIfPresent(Int.self, forKey: .gpuIdle)
        gres = try? container.decodeIfPresent(String.self, forKey: .gres)
    }
}
