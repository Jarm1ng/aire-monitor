import AppKit
import SwiftUI

private enum WidgetLayout {
    static let width: CGFloat = 548
    static let height: CGFloat = 246
    static let refreshInterval: TimeInterval = 10
}

private enum WidgetPalette {
    static let backgroundOverlay = Color(nsColor: .windowBackgroundColor).opacity(0.42)
    static let fill = Color.primary.opacity(0.040)
    static let fillStrong = Color.primary.opacity(0.070)
    static let border = Color.primary.opacity(0.085)
    static let highlight = Color.white.opacity(0.16)
    static let cyan = Color.cyan
    static let green = Color.green
    static let orange = Color.orange
    static let red = Color.red
    static let purple = Color.purple
}

struct WidgetLogoMark: View {
    var cornerRadius: CGFloat = 7

    var body: some View {
        Group {
            if let image = Self.logoImage() {
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
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
    }

    private static func logoImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "AIRELogo", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        let fallback = FileManager.default.currentDirectoryPath + "/assets/AIRELogo.png"
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

    private func configure(window: NSWindow?) {
        guard let window else {
            return
        }
        window.title = "AIRE Desktop Widget"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.borderless, .fullSizeContentView]
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
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
        window.minSize = contentSize
        window.maxSize = contentSize
        window.contentMinSize = contentSize
        window.contentMaxSize = contentSize
    }
}

@MainActor
final class WidgetModel: ObservableObject {
    @Published var snapshot: WidgetSnapshot?
    @Published var errorMessage: String?
    @Published var isRefreshing = false
    @Published var lastRefresh: Date?
    @Published var usingCache = false

    let projectRoot = ProjectLocator.findProjectRoot()
    private var timer: Timer?

    func start() {
        guard timer == nil else {
            return
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: WidgetLayout.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func refresh() {
        guard !isRefreshing else {
            return
        }
        isRefreshing = true

        Task {
            do {
                let nextSnapshot = try await SnapshotRunner.collect(projectRoot: projectRoot)
                snapshot = nextSnapshot.snapshot
                errorMessage = nextSnapshot.errorMessage
                usingCache = nextSnapshot.usedCache
                lastRefresh = Date()
            } catch {
                errorMessage = error.localizedDescription
                usingCache = snapshot != nil
            }
            isRefreshing = false
        }
    }

    func openMainApp() {
        let appURL = URL(fileURLWithPath: "\(projectRoot)/.runtime/AIREMonitorApp.app")
        if FileManager.default.fileExists(atPath: appURL.path) {
            NSWorkspace.shared.open(appURL)
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
        try? process.run()
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
                        .blendMode(.screen)
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
                title: model.usingCache ? "cached" : "live",
                value: remoteName,
                color: model.errorMessage == nil ? WidgetPalette.green : WidgetPalette.orange
            )

            Spacer()

            Text(lastRefreshText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .singleLine()
                .contentTransition(.opacity)

            Button {
                model.openMainApp()
            } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(WidgetIconButtonStyle())
            .help("Open AIRE Monitor")

            Button {
                model.refresh()
            } label: {
                Image(systemName: model.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
            }
            .buttonStyle(WidgetIconButtonStyle())
            .disabled(model.isRefreshing)
            .help("Refresh")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(WidgetIconButtonStyle())
            .help("Close widget")
        }
        .frame(height: 30)
    }

    private var gpuBlock: some View {
        HStack(spacing: 12) {
            RingMeter(value: gpuRatio, color: gpuUseColor, label: "\(gpuPercent)%")
                .frame(width: 72, height: 72)

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
                } else if let firstJob = jobs.first {
                    JobRow(job: firstJob)
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
        let message = statusMessage ?? "Refreshes every 10 seconds"
        let isWarning = model.errorMessage != nil
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
            Text("10s")
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

    private var lastRefreshText: String {
        guard let lastRefresh else {
            return "not updated"
        }
        return lastRefresh.formatted(date: .omitted, time: .standard)
    }

    private var statusMessage: String? {
        if let error = model.errorMessage, !error.isEmpty {
            return model.usingCache ? "Using cached data. \(error)" : error
        }
        if let lastRefresh {
            return "Updated \(lastRefresh.formatted(date: .omitted, time: .standard))"
        }
        return nil
    }

    private var lastRefresh: Date? {
        model.lastRefresh
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
        if gpuPercent >= 90 {
            return .red
        }
        if gpuPercent >= 70 {
            return .orange
        }
        return .cyan
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

struct MetricLine: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.caption2)
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
        if job.state.uppercased().contains("RUN") {
            return .green
        }
        if job.state.uppercased().contains("PEND") {
            return .orange
        }
        return .secondary
    }
}

struct GPUHeatmap: View {
    let nodes: [WidgetNode]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 14, maximum: 18), spacing: 4)], spacing: 4) {
            ForEach(nodes) { node in
                RoundedRectangle(cornerRadius: 3)
                    .fill(color(for: node))
                    .frame(height: 12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .help("\(node.node): \(node.gpuAllocatedValue)/\(node.gpuTotalValue) GPU, \(node.state)")
            }
        }
    }

    private func color(for node: WidgetNode) -> Color {
        if !node.isAvailable {
            return .red.opacity(0.65)
        }
        let ratio = Double(node.gpuAllocatedValue) / Double(max(node.gpuTotalValue, 1))
        if ratio >= 1 {
            return .cyan.opacity(0.85)
        }
        if ratio > 0 {
            return .orange.opacity(0.85)
        }
        return .green.opacity(0.78)
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
                        .fill(color(for: node))
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

    private func color(for node: WidgetNode) -> Color {
        if !node.isAvailable {
            return WidgetPalette.red.opacity(0.68)
        }
        let ratio = Double(node.gpuAllocatedValue) / Double(max(node.gpuTotalValue, 1))
        if ratio >= 1 {
            return WidgetPalette.cyan.opacity(0.88)
        }
        if ratio > 0 {
            return WidgetPalette.orange.opacity(0.88)
        }
        return WidgetPalette.green.opacity(0.80)
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
    static func collect(projectRoot: String) async throws -> SnapshotResult {
        try await Task.detached(priority: .userInitiated) {
            let script = "\(projectRoot)/scripts/aire_monitor_snapshot.py"
            let cache = URL(fileURLWithPath: "\(projectRoot)/.runtime/latest_snapshot.json")
            let legacyCache = URL(fileURLWithPath: "\(projectRoot)/.runtime/last_snapshot.json")
            guard FileManager.default.fileExists(atPath: script) else {
                throw WidgetError.message("Missing snapshot script at \(script)")
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [script, "--host", "aire", "--timeout", "8"]
            process.currentDirectoryURL = URL(fileURLWithPath: projectRoot)

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()
            let deadline = Date().addingTimeInterval(12)
            while process.isRunning && Date() < deadline {
                usleep(50_000)
            }
            if process.isRunning {
                process.terminate()
            }

            let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            if let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: stdout) {
                try? FileManager.default.createDirectory(
                    at: cache.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? stdout.write(to: cache, options: .atomic)
                let errors = snapshot.errors.joined(separator: "\n")
                return SnapshotResult(
                    snapshot: snapshot,
                    errorMessage: errors.isEmpty ? nil : errors,
                    usedCache: false
                )
            }

            let cachedData = (try? Data(contentsOf: cache)) ?? (try? Data(contentsOf: legacyCache))
            if let cached = cachedData,
               let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: cached) {
                let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return SnapshotResult(
                    snapshot: snapshot,
                    errorMessage: message.isEmpty ? "Refresh failed; showing cached data." : message,
                    usedCache: true
                )
            }

            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WidgetError.message(message.isEmpty ? "Refresh failed and no cached snapshot is available." : message)
        }.value
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

enum WidgetError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text):
            return text
        }
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

struct WidgetNode: Codable, Identifiable {
    let node: String
    let state: String
    let gpuTotal: Int?
    let gpuAllocated: Int?

    var id: String {
        node
    }

    var gpuTotalValue: Int {
        gpuTotal ?? 0
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
    }
}
