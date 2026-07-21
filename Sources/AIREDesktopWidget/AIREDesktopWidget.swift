import AppKit
import SwiftUI

private enum WidgetLayout {
    static let width: CGFloat = 548
    static let height: CGFloat = 246
    /// Minimum spacing between fallback snapshot collections, and the cadence
    /// the widget advertises in the footer.
    static let refreshInterval: TimeInterval = 10
    /// How often the widget polls the snapshot file for changes (belt and
    /// braces alongside the directory watcher).
    static let filePollInterval: TimeInterval = 2
    /// A snapshot older than this is considered stale: the main app is not
    /// feeding the file, so the widget collects its own snapshot.
    static let staleThreshold: TimeInterval = 30
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

    private static func loadLogoImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "AIRELogo", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        let fallback = ProjectLocator.findProjectRoot() + "/assets/AIRELogo.png"
        return NSImage(contentsOfFile: fallback)
    }
}

@main
struct AIREDesktopWidgetApp: App {
    @NSApplicationDelegateAdaptor(WidgetAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            DesktopWidgetView()
                .frame(width: WidgetLayout.width, height: WidgetLayout.height)
                .background(DesktopWindowConfigurator())
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
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    /// Idempotent: runs on every SwiftUI update, so every assignment is
    /// guarded to avoid needless AppKit relayout/flicker.
    private func configure(window: NSWindow?) {
        guard let window else {
            return
        }
        if window.title != "AIRE Desktop Widget" {
            window.title = "AIRE Desktop Widget"
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
        if window.frameAutosaveName != "AIREDesktopWidget" {
            window.setFrameAutosaveName("AIREDesktopWidget")
        }
        let contentSize = NSSize(width: WidgetLayout.width, height: WidgetLayout.height)
        if window.frame.size != contentSize {
            let frame = window.frame
            let nextFrame = NSRect(
                x: frame.minX,
                y: frame.maxY - contentSize.height,
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
    }
}

enum WidgetDataStatus {
    case connecting
    case live
    case cached
    case offline
}

@MainActor
final class WidgetModel: ObservableObject {
    @Published var snapshot: WidgetSnapshot?
    @Published var errorMessage: String?
    @Published var isRefreshing = false
    /// When the displayed data last changed (file reload or collection).
    @Published var lastUpdate: Date?
    /// When the displayed snapshot was collected on the cluster.
    @Published var snapshotDate: Date?
    @Published var status: WidgetDataStatus = .connecting
    @Published var launchMessage: String?

    let projectRoot = ProjectLocator.findProjectRoot()

    private var pollTimer: Timer?
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var loadedModificationDate: Date?
    private var failedModificationDate: Date?
    private var lastFallbackAttempt: Date?
    /// True when the displayed snapshot came from this widget's own fallback
    /// collection (rather than the main app writing the snapshot file).
    private var lastDataFromFallback = false
    /// Modification date of the snapshot file as last written by this
    /// widget's own fallback collection; reloading that same write must not
    /// be mistaken for the main app feeding the file.
    private var ownWriteModificationDate: Date?

    private var runtimeDirectory: String {
        "\(projectRoot)/.runtime"
    }

    private var snapshotPath: String {
        "\(runtimeDirectory)/latest_snapshot.json"
    }

    private var legacySnapshotPath: String {
        "\(runtimeDirectory)/last_snapshot.json"
    }

    func start() {
        guard pollTimer == nil else {
            return
        }
        installDirectoryWatcherIfNeeded()
        syncWithSnapshotFile(forceReload: true)
        pollTimer = Timer.scheduledTimer(withTimeInterval: WidgetLayout.filePollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.installDirectoryWatcherIfNeeded()
                self.syncWithSnapshotFile()
            }
        }
    }

    func refresh() {
        syncWithSnapshotFile(forceReload: true, forceCollect: true)
    }

    func openMainApp() {
        let appURL = URL(fileURLWithPath: "\(projectRoot)/.runtime/AIREMonitorApp.app")
        if FileManager.default.fileExists(atPath: appURL.path) {
            launchMessage = "Launching AIRE Monitor…"
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { [weak self] _, error in
                Task { @MainActor in
                    guard let self else {
                        return
                    }
                    self.launchMessage = nil
                    if let error {
                        self.errorMessage = "Could not open AIRE Monitor: \(error.localizedDescription)"
                    }
                }
            }
            return
        }

        let scriptURL = URL(fileURLWithPath: "\(projectRoot)/scripts/run_macos_app.sh")
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            errorMessage = "Cannot find main app launcher at \(scriptURL.path)"
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
                    self.errorMessage = "AIRE Monitor launcher exited with status \(status); run scripts/run_macos_app.sh in Terminal for details."
                }
            }
        }
        do {
            try process.run()
            launchMessage = "Launching AIRE Monitor… (building if needed)"
        } catch {
            errorMessage = "Could not launch AIRE Monitor: \(error.localizedDescription)"
        }
    }

    // MARK: - Snapshot file watching

    private func installDirectoryWatcherIfNeeded() {
        guard directoryWatcher == nil else {
            return
        }
        let descriptor = open(runtimeDirectory, O_EVTONLY)
        guard descriptor >= 0 else {
            return
        }
        // Watch the directory, not the file: the main app replaces the
        // snapshot atomically (write + rename), which shows up as a directory
        // write event and would orphan a watcher bound to the old file inode.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            // Read the vnode flags synchronously: source.data is only valid
            // while the handler runs and events could coalesce or be lost
            // across the async hop below.
            guard let flags = source?.data else {
                return
            }
            Task { @MainActor in
                self?.handleRuntimeDirectoryEvent(flags: flags)
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        directoryWatcher = source
    }

    private func handleRuntimeDirectoryEvent(flags: DispatchSource.FileSystemEvent) {
        if !flags.isDisjoint(with: [.delete, .rename]) {
            // The watched inode was unlinked or renamed. Checking the path
            // here would race with a delete+recreate and leave the source
            // bound to the dead inode forever, so drop the watcher
            // unconditionally and let the poll timer re-install one against
            // the current directory inode.
            directoryWatcher?.cancel()
            directoryWatcher = nil
        }
        syncWithSnapshotFile()
    }

    /// Primary data path: reload the snapshot file when it changed, then fall
    /// back to spawning the collector only when the file is missing or stale,
    /// so the widget never double-collects while the main app is running.
    private func syncWithSnapshotFile(forceReload: Bool = false, forceCollect: Bool = false) {
        let wasFallback = lastDataFromFallback
        if let modificationDate = fileModificationDate(atPath: snapshotPath) {
            let isNew = modificationDate != loadedModificationDate
                && modificationDate != failedModificationDate
            if forceReload || isNew {
                loadSnapshotFile(modificationDate: modificationDate)
            }
        }
        recomputeStatus()

        let age = snapshotAge
        let missingOrStale = age.map { $0 > WidgetLayout.staleThreshold } ?? true
        let ownFeedDue = lastDataFromFallback
            && (age.map { $0 > WidgetLayout.refreshInterval } ?? true)
        if forceCollect {
            // Manual refresh: bypass the cadence, but only collect when the
            // widget is feeding itself (or the file is missing/stale) so we
            // never double-collect while the main app feeds the file.
            if missingOrStale || wasFallback {
                collectIfNeeded(bypassCadence: true)
            }
        } else if missingOrStale || ownFeedDue {
            collectIfNeeded(bypassCadence: false)
        }
    }

    private var snapshotAge: TimeInterval? {
        guard snapshot != nil, let snapshotDate else {
            return nil
        }
        return Date().timeIntervalSince(snapshotDate)
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
            // must keep the 10s self-feed cadence intact.
            lastDataFromFallback = false
        }
        snapshot = decoded
        snapshotDate = WidgetTimestampParser.date(from: decoded.collectedAt) ?? modificationDate
        lastUpdate = Date()
        errorMessage = nil
    }

    private func recomputeStatus() {
        guard snapshot != nil else {
            status = errorMessage == nil ? .connecting : .offline
            return
        }
        if let age = snapshotAge, age <= WidgetLayout.staleThreshold {
            status = .live
        } else {
            status = .cached
        }
    }

    // MARK: - Fallback collection

    private func collectIfNeeded(bypassCadence: Bool) {
        guard !isRefreshing else {
            return
        }
        if !bypassCadence,
           let lastFallbackAttempt,
           Date().timeIntervalSince(lastFallbackAttempt) < WidgetLayout.refreshInterval {
            return
        }
        lastFallbackAttempt = Date()
        isRefreshing = true
        Task {
            defer {
                isRefreshing = false
            }
            do {
                let result = try await SnapshotRunner.collect(projectRoot: projectRoot)
                apply(result)
            } catch {
                errorMessage = error.localizedDescription
            }
            recomputeStatus()
        }
    }

    private func apply(_ result: SnapshotResult) {
        let collectedDate = WidgetTimestampParser.date(from: result.snapshot.collectedAt)
        if let existing = snapshotDate, let collectedDate, collectedDate < existing {
            // The main app wrote a newer snapshot while the fallback
            // collection ran; keep the newer data and only surface the error.
            errorMessage = result.errorMessage
            return
        }
        snapshot = result.snapshot
        errorMessage = result.errorMessage
        lastDataFromFallback = !result.usedCache
        if result.usedCache {
            snapshotDate = collectedDate
                ?? fileModificationDate(atPath: snapshotPath)
                ?? fileModificationDate(atPath: legacySnapshotPath)
        } else {
            snapshotDate = collectedDate ?? Date()
            // SnapshotRunner just wrote the cache file; remember its
            // modification date so the watcher does not redundantly reload it
            // and so a forced reload of it is recognized as our own write.
            loadedModificationDate = fileModificationDate(atPath: snapshotPath)
            ownWriteModificationDate = loadedModificationDate
        }
        lastUpdate = Date()
    }

    private func fileModificationDate(atPath path: String) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.modificationDate] as? Date
    }
}

struct DesktopWidgetView: View {
    @StateObject private var model = WidgetModel()

    private var jobs: [WidgetJob] {
        model.snapshot?.jobs ?? []
    }

    private var nodes: [WidgetNode] {
        model.snapshot?.nodes ?? []
    }

    private var gpuNodes: [WidgetNode] {
        nodes.filter { $0.gpuTotalValue > 0 }
    }

    private var gpuTotal: Int {
        gpuNodes.reduce(0) { $0 + $1.gpuTotalValue }
    }

    private var gpuAllocated: Int {
        gpuNodes.reduce(0) { $0 + $1.gpuAllocatedValue }
    }

    private var gpuIdle: Int {
        max(gpuTotal - gpuAllocated, 0)
    }

    private var runningJobs: [WidgetJob] {
        jobs.filter { $0.state.uppercased().contains("RUN") }
    }

    private var pendingJobs: [WidgetJob] {
        jobs.filter { $0.state.uppercased().contains("PEND") }
    }

    /// Running jobs first, then pending, then everything else, preserving the
    /// original (squeue) order within each group.
    private var featuredJobs: [WidgetJob] {
        let ranked = jobs.enumerated().sorted { lhs, rhs in
            let lhsRank = Self.jobRank(lhs.element)
            let rhsRank = Self.jobRank(rhs.element)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.offset < rhs.offset
        }
        return ranked.prefix(2).map(\.element)
    }

    private static func jobRank(_ job: WidgetJob) -> Int {
        let state = job.state.uppercased()
        if state.contains("RUN") {
            return 0
        }
        if state.contains("PEND") {
            return 1
        }
        return 2
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

            VStack(alignment: .leading, spacing: 12) {
                header

                HStack(alignment: .top, spacing: 10) {
                    gpuBlock
                        .frame(width: 190, height: 102)
                    healthBlock
                        .frame(width: 132, height: 102)
                    jobsBlock
                        .frame(maxWidth: .infinity, minHeight: 102, maxHeight: 102)
                }

                heatmapStrip
                    .frame(height: 36)

                footer
                    .frame(height: 14)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(width: WidgetLayout.width, height: WidgetLayout.height, alignment: .topLeading)
        .ignoresSafeArea()
        .contextMenu {
            Button("Refresh") {
                model.refresh()
            }
            Button("Open AIRE Monitor") {
                model.openMainApp()
            }
            Divider()
            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: gpuAllocated)
        .animation(.easeInOut(duration: 0.28), value: gpuTotal)
        .animation(.easeInOut(duration: 0.28), value: runningJobs.count)
        .animation(.easeInOut(duration: 0.28), value: pendingJobs.count)
        .task {
            model.start()
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            WidgetLogoMark()
            .frame(width: 30, height: 30)

            Text("AIRE")
                .font(.title3.weight(.semibold))
                .singleLine()
                .contentTransition(.opacity)

            StatusChip(
                title: statusPresentation.title,
                value: statusPresentation.value,
                color: statusPresentation.color
            )

            Spacer()

            Text(headerTimestampText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(headerTimestampColor)
                .singleLine()
                .contentTransition(.opacity)

            Button {
                model.openMainApp()
            } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(WidgetIconButtonStyle())
            .help("Open AIRE Monitor")
            .accessibilityLabel("Open AIRE Monitor")

            Button {
                model.refresh()
            } label: {
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(WidgetIconButtonStyle())
            .disabled(model.isRefreshing)
            .help("Refresh")
            .accessibilityLabel("Refresh")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(WidgetIconButtonStyle())
            .help("Close widget")
            .accessibilityLabel("Close widget")
        }
        .frame(height: 30)
    }

    private var gpuBlock: some View {
        HStack(spacing: 12) {
            RingMeter(value: gpuRatio, color: gpuUseColor, label: "\(gpuPercent)%")
                .frame(width: 72, height: 72)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("GPU fleet usage")
                .accessibilityValue("\(gpuAllocated) of \(gpuTotal) GPUs allocated, \(gpuPercent) percent")

            VStack(alignment: .leading, spacing: 9) {
                Text("GPU Fleet")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .singleLine()

                Text("\(gpuAllocated)/\(gpuTotal)")
                    .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(gpuUseColor)
                    .singleLine()
                    .contentTransition(.opacity)

                GPUUsageBar(allocated: gpuAllocated, total: gpuTotal, color: gpuUseColor)

                Text("\(gpuIdle) free GPUs")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .singleLine()
            }
        }
        .widgetSurface()
    }

    private var healthBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nodes")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .singleLine()

            MiniStat(title: "GPU", value: "\(gpuNodes.count)", color: WidgetPalette.cyan)
            MiniStat(title: "Free", value: "\(gpuIdle)", color: WidgetPalette.green)
            MiniStat(title: "Issues", value: "\(unavailableNodes)", color: WidgetPalette.red)
        }
        .widgetSurface()
    }

    private var jobsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("My Jobs")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .singleLine()
                Spacer()
                Text("\(jobs.count)")
                    .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(WidgetPalette.purple)
                    .singleLine()
            }

            HStack(spacing: 6) {
                JobCountPill(title: "Run", value: runningJobs.count, color: WidgetPalette.green)
                JobCountPill(title: "Wait", value: pendingJobs.count, color: WidgetPalette.orange)
            }

            Group {
                if jobs.isEmpty {
                    Label("No active jobs", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(WidgetPalette.green)
                        .singleLine()
                } else if featuredJobs.count == 1 {
                    JobRow(job: featuredJobs[0])
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(featuredJobs) { job in
                            CompactJobRow(job: job)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .widgetSurface()
    }

    private var heatmapStrip: some View {
        HStack(spacing: 10) {
            Text("GPU nodes")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .singleLine()
                .frame(width: 62, alignment: .leading)
            GPUHeatmapStrip(nodes: gpuNodes)
            Text("\(gpuNodes.count)")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .singleLine()
                .frame(width: 24, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .background(WidgetPalette.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(WidgetPalette.border, lineWidth: 1)
        )
    }

    private var footer: some View {
        let message = statusMessage ?? "Refreshes every \(Int(WidgetLayout.refreshInterval)) seconds"
        let isWarning = model.errorMessage != nil || model.status == .cached
        let color = isWarning ? WidgetPalette.orange : WidgetPalette.green

        return HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .padding(.top, 4)
                .shadow(
                    color: color.opacity(0.28),
                    radius: 3,
                    x: 0,
                    y: 0
                )
            Text(message)
                .font(.caption2)
                .foregroundColor(isWarning ? .primary : .secondary)
                .lineLimit(isWarning ? 2 : 1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.9)
            Spacer()
            Text("\(Int(WidgetLayout.refreshInterval))s")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .singleLine()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background((isWarning ? WidgetPalette.orange.opacity(0.12) : WidgetPalette.fill), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isWarning ? WidgetPalette.orange.opacity(0.18) : WidgetPalette.border, lineWidth: 1)
        )
        .help(message)
    }

    private var remoteName: String {
        if let snapshot = model.snapshot {
            return snapshot.remote.hostname.isEmpty ? snapshot.remote.host : snapshot.remote.hostname
        }
        return "waiting"
    }

    /// One state drives the chip's title, value, and color consistently.
    private var statusPresentation: (title: String, value: String, color: Color) {
        switch model.status {
        case .connecting:
            return ("connecting", "waiting", WidgetPalette.neutral)
        case .live:
            return ("live", remoteName, WidgetPalette.green)
        case .cached:
            return ("cached", remoteName, WidgetPalette.orange)
        case .offline:
            return ("offline", "no data", WidgetPalette.red)
        }
    }

    private var headerTimestampText: String {
        switch model.status {
        case .cached:
            guard let snapshotDate = model.snapshotDate else {
                return "data age unknown"
            }
            return "data from \(snapshotDate.formatted(date: .omitted, time: .shortened))"
        case .live:
            guard let lastUpdate = model.lastUpdate else {
                return "not updated"
            }
            return lastUpdate.formatted(date: .omitted, time: .standard)
        case .connecting, .offline:
            return "not updated"
        }
    }

    private var headerTimestampColor: Color {
        model.status == .cached ? WidgetPalette.orange : Color.secondary
    }

    private var statusMessage: String? {
        if let launchMessage = model.launchMessage {
            return launchMessage
        }
        if let error = model.errorMessage, !error.isEmpty {
            return model.status == .cached ? "Using cached data. \(error)" : error
        }
        if model.status == .cached, let snapshotDate = model.snapshotDate {
            return "Showing data from \(snapshotDate.formatted(date: .omitted, time: .shortened)); waiting for a fresh snapshot."
        }
        if let lastUpdate = model.lastUpdate {
            return "Updated \(lastUpdate.formatted(date: .omitted, time: .standard))"
        }
        return nil
    }

    private var gpuRatio: Double {
        guard gpuTotal > 0 else {
            return 0
        }
        return min(Double(gpuAllocated) / Double(gpuTotal), 1)
    }

    private var gpuPercent: Int {
        Int((gpuRatio * 100).rounded())
    }

    private var gpuUseColor: Color {
        WidgetPalette.gpuColor(allocatedRatio: gpuRatio)
    }

    private var unavailableNodes: Int {
        gpuNodes.filter { !$0.isAvailable }.count
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
        .padding(.vertical, 5)
        .frame(maxWidth: 190, alignment: .leading)
        .background(color.opacity(0.10), in: Capsule())
        .background(.thinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(color.opacity(0.15), lineWidth: 1)
        )
    }
}

struct MiniStat: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 5, height: 18)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .singleLine()
            Spacer(minLength: 4)
            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
                .singleLine()
        }
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

    var body: some View {
        ZStack {
            Circle()
                .stroke(WidgetPalette.fillStrong, lineWidth: 8)
            Circle()
                .trim(from: 0, to: min(max(value, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.32), value: value)
            Text(label)
                .font(.caption.monospacedDigit().weight(.bold))
                .singleLine()
        }
    }
}

struct GPUUsageBar: View {
    let allocated: Int
    let total: Int
    let color: Color

    private var ratio: Double {
        guard total > 0 else {
            return 0
        }
        return min(Double(allocated) / Double(total), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(WidgetPalette.green.opacity(0.16))
                RoundedRectangle(cornerRadius: 5)
                    .fill(color.opacity(0.88))
                    .frame(width: width * ratio)
                    .animation(.easeInOut(duration: 0.32), value: ratio)
            }
        }
        .frame(height: 10)
    }
}

struct JobCountPill: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Text("\(value)")
                .monospacedDigit()
                .fontWeight(.semibold)
        }
        .font(.caption2)
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
        .background(.thinMaterial, in: Capsule())
        .foregroundStyle(color)
        .overlay(
            Capsule()
                .stroke(color.opacity(0.14), lineWidth: 1)
        )
    }
}

struct JobRow: View {
    let job: WidgetJob

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(job.partition) • \(job.elapsed)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            Text(job.state.prefix(1))
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
        }
    }

    private var color: Color {
        WidgetPalette.jobStateColor(job.state)
    }
}

struct CompactJobRow: View {
    let job: WidgetJob

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(WidgetPalette.jobStateColor(job.state))
                .frame(width: 5, height: 5)
            Text(job.name)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(job.elapsed)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct GPUHeatmapStrip: View {
    let nodes: [WidgetNode]

    var body: some View {
        GeometryReader { proxy in
            let count = max(nodes.count, 1)
            let spacing: CGFloat = 3
            let width = max((proxy.size.width - spacing * CGFloat(count - 1)) / CGFloat(count), 4)
            HStack(spacing: spacing) {
                ForEach(nodes) { node in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(WidgetPalette.heatmapColor(for: node))
                        .frame(width: width, height: 16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                        .help("\(node.node): \(node.gpuAllocatedValue)/\(node.gpuTotalValue) GPU, \(node.state)")
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

struct SnapshotResult {
    let snapshot: WidgetSnapshot
    let errorMessage: String?
    let usedCache: Bool
}

enum SnapshotRunner {
    /// Per-SSH-command timeout passed to aire_monitor_snapshot.py.
    static let perCommandTimeout = 8
    /// aire_monitor_snapshot.py runs six sequential SSH commands (remote,
    /// jobs, job details, partitions, nodes, storage); the process deadline
    /// must cover the aggregate worst case plus local startup slack so a slow
    /// link is not mistaken for a hang.
    static let remoteCommandCount = 6
    static var processDeadline: TimeInterval {
        TimeInterval(remoteCommandCount * perCommandTimeout) + 12
    }
    private static let killGracePeriod: TimeInterval = 3
    private static let maxCapturedOutputBytes = 8 * 1024 * 1024

    static func collect(projectRoot: String) async throws -> SnapshotResult {
        let script = "\(projectRoot)/scripts/aire_monitor_snapshot.py"
        let cacheURL = URL(fileURLWithPath: "\(projectRoot)/.runtime/latest_snapshot.json")
        let legacyCacheURL = URL(fileURLWithPath: "\(projectRoot)/.runtime/last_snapshot.json")
        guard FileManager.default.fileExists(atPath: script) else {
            throw WidgetError.message("Missing snapshot script at \(script)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = try WidgetConnectionProfile.snapshotArguments(
            projectRoot: projectRoot,
            script: script
        )
        process.currentDirectoryURL = URL(fileURLWithPath: projectRoot)

        let outcome = try await execute(process)
        let stderrText = String(data: outcome.stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let timeoutText = outcome.timedOut
            ? "Snapshot collection timed out after \(Int(processDeadline)) seconds."
            : nil
        let cachedData = (try? Data(contentsOf: cacheURL)) ?? (try? Data(contentsOf: legacyCacheURL))

        if let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: outcome.stdout) {
            let scriptErrors = snapshot.errors.joined(separator: "\n")
            let liveMessage = combinedMessage([timeoutText, scriptErrors.isEmpty ? stderrText : scriptErrors])
            if outcome.terminationStatus == 0 && scriptErrors.isEmpty && !outcome.timedOut {
                try? FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? outcome.stdout.write(to: cacheURL, options: .atomic)
                return SnapshotResult(
                    snapshot: snapshot,
                    errorMessage: nil,
                    usedCache: false
                )
            }
            if let cached = cachedData,
               let cachedSnapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: cached) {
                return SnapshotResult(
                    snapshot: cachedSnapshot,
                    errorMessage: liveMessage.isEmpty ? "Refresh failed; showing cached data." : liveMessage,
                    usedCache: true
                )
            }
            return SnapshotResult(
                snapshot: snapshot,
                errorMessage: liveMessage.isEmpty ? "Refresh failed." : liveMessage,
                usedCache: false
            )
        }

        let failureMessage = combinedMessage([timeoutText, stderrText])
        if let cached = cachedData,
           let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: cached) {
            return SnapshotResult(
                snapshot: snapshot,
                errorMessage: failureMessage.isEmpty ? "Refresh failed; showing cached data." : failureMessage,
                usedCache: true
            )
        }
        throw WidgetError.message(
            failureMessage.isEmpty ? "Refresh failed and no cached snapshot is available." : failureMessage
        )
    }

    private static func combinedMessage(_ parts: [String?]) -> String {
        parts
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Runs the process without blocking a cooperative-pool thread: both
    /// pipes are drained concurrently while the child runs (a full pipe
    /// buffer can otherwise deadlock the child), termination is observed via
    /// terminationHandler before the exit status is read, and a watchdog
    /// escalates SIGTERM to SIGKILL and finally force-completes so the widget
    /// can never hang on a wedged child or an inherited pipe descriptor.
    private static func execute(_ process: Process) async throws -> ProcessOutcome {
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
            try? await Task.sleep(nanoseconds: UInt64(processDeadline * 1_000_000_000))
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
    static func findProjectRoot() -> String {
        let environment = ProcessInfo.processInfo.environment
        if let value = environment["AIRE_PROJECT_ROOT"], hasSnapshotScript(value) {
            return value
        }

        let current = FileManager.default.currentDirectoryPath
        if hasSnapshotScript(current) {
            return current
        }

        let bundleRoot = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        if hasSnapshotScript(bundleRoot) {
            return bundleRoot
        }

        return current
    }

    private static func hasSnapshotScript(_ root: String) -> Bool {
        FileManager.default.fileExists(atPath: "\(root)/scripts/aire_monitor_snapshot.py")
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

struct WidgetConnectionProfile: Codable {
    let useSSHAlias: Bool
    let sshAlias: String
    let username: String
    let aireHostname: String
    let useJumpHost: Bool
    let jumpHostname: String
    let controlPath: String
    let jumpControlPath: String

    private static var timeoutArgument: String {
        String(SnapshotRunner.perCommandTimeout)
    }

    static func snapshotArguments(projectRoot: String, script: String) throws -> [String] {
        switch load(projectRoot: projectRoot) {
        case .missing:
            return [script, "--host", "aire", "--timeout", timeoutArgument]
        case .invalid(let message):
            throw WidgetError.message(message)
        case .loaded(let profile):
            return snapshotArguments(script: script, profile: profile)
        }
    }

    private static func snapshotArguments(script: String, profile: WidgetConnectionProfile) -> [String] {
        if profile.useSSHAlias {
            return [
                script,
                "--host", profile.sshAlias.isEmpty ? "aire" : profile.sshAlias,
                "--timeout", timeoutArgument
            ]
        }

        var arguments = [
            script,
            "--username", profile.username,
            "--aire-hostname", profile.aireHostname,
            "--jump-hostname", profile.jumpHostname,
            profile.useJumpHost ? "--use-jump-host" : "--no-jump-host",
            "--control-path", profile.controlPath,
            "--timeout", timeoutArgument
        ]
        if !profile.jumpControlPath.isEmpty {
            arguments.append(contentsOf: ["--jump-control-path", profile.jumpControlPath])
        }
        return arguments
    }

    private static func load(projectRoot: String) -> ProfileLoadResult {
        let url = URL(fileURLWithPath: projectRoot)
            .appendingPathComponent(".runtime")
            .appendingPathComponent("connection_profile.json")
        guard let data = try? Data(contentsOf: url) else {
            return .missing
        }
        do {
            return .loaded(try JSONDecoder().decode(WidgetConnectionProfile.self, from: data))
        } catch {
            return .invalid("Connection profile is invalid: \(url.path)\n\(error.localizedDescription)")
        }
    }

    private enum ProfileLoadResult {
        case missing
        case invalid(String)
        case loaded(WidgetConnectionProfile)
    }
}

struct WidgetSnapshot: Codable {
    let collectedAt: String
    let remote: WidgetRemote
    let jobs: [WidgetJob]
    let nodes: [WidgetNode]
    let errors: [String]

    enum CodingKeys: String, CodingKey {
        case collectedAt = "collected_at"
        case remote
        case jobs
        case nodes
        case errors
    }
}

struct WidgetRemote: Codable {
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
}

struct WidgetJob: Codable, Identifiable {
    let jobId: String
    let partition: String
    let name: String
    let state: String
    let elapsed: String

    var id: String {
        jobId
    }

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case partition
        case name
        case state
        case elapsed
    }
}

enum WidgetGresParser {
    /// Parses GPU counts from Slurm gres strings, tolerating socket/index
    /// suffixes and comma-joined lists: "gpu:l40s:3(S:0-1)" -> 3,
    /// "gpu:4(IDX:0-3)" -> 4, "gpu:a100:4,mps:400" -> 4, "gpu" -> 1.
    static func gpuCount(in gres: String) -> Int {
        var total = 0
        for rawEntry in gres.split(separator: ",") {
            let entry = rawEntry.trimmingCharacters(in: .whitespaces)
            let base = entry
                .split(separator: "(", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init) ?? entry
            let pieces = base.split(separator: ":")
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
}

struct WidgetNode: Codable, Identifiable {
    let node: String
    let state: String
    let gpuTotal: Int?
    let gpuAllocated: Int?
    let gres: String?

    var id: String {
        node
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

    var isAvailable: Bool {
        let value = state.lowercased()
        return !value.contains("maint")
            && !value.contains("down")
            && !value.contains("drain")
            && !value.contains("fail")
    }

    enum CodingKeys: String, CodingKey {
        case node
        case state
        case gpuTotal = "gpu_total"
        case gpuAllocated = "gpu_allocated"
        case gres
    }
}
