import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarMonitorController: NSObject {
    static let shared = StatusBarMonitorController()

    private var model: AppModel?
    private var statusItem: NSStatusItem?
    private var statusView: StatusBarCapsuleView?
    private var menu: NSMenu?
    private var cancellables = Set<AnyCancellable>()
    private var lastSignature = ""

    private override init() {
        super.init()
    }

    func configure(model: AppModel) {
        self.model = model
        installStatusItemIfNeeded()
        installMenu(model: model)
        bindModel(model)
        updateStatusItem()
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        guard let button = item.button else { return }
        button.title = ""
        button.image = nil
        button.toolTip = "AIRE Monitor"

        let view = StatusBarCapsuleView(
            frame: button.bounds
        )
        view.autoresizingMask = [.width, .height]
        button.addSubview(view)
        statusView = view
    }

    private func installMenu(model: AppModel) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let hostingView = NSHostingView(rootView: MenuBarMonitorView(model: model))
        hostingView.frame = NSRect(x: 0, y: 0, width: 370, height: 520)

        let panelItem = NSMenuItem()
        panelItem.view = hostingView
        menu.addItem(panelItem)

        statusItem?.menu = menu
        self.menu = menu
    }

    private func bindModel(_ model: AppModel) {
        cancellables.removeAll()
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateStatusItem()
                }
            }
            .store(in: &cancellables)
    }

    private func updateStatusItem() {
        guard let model, let statusView, let button = statusItem?.button else { return }

        let summary = StatusBarSummary(
            snapshot: model.snapshot,
            isConnected: model.isLoggedIn,
            hasCache: model.hasCachedSnapshot,
            isRefreshing: model.isRefreshing
        )
        let signature = summary.signature
        guard signature != lastSignature else { return }
        lastSignature = signature

        statusView.update(title: summary.title, image: summary.image, tooltip: summary.tooltip)
        let width = statusView.preferredWidth
        statusItem?.length = width
        button.toolTip = summary.tooltip
        button.setAccessibilityLabel(summary.title)
        statusView.frame = NSRect(x: 0, y: 0, width: width, height: NSStatusBar.system.thickness)
    }
}

extension StatusBarMonitorController: NSMenuDelegate {
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor in
            StatusBarMonitorController.shared.statusView?.isActive = true
        }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        Task { @MainActor in
            StatusBarMonitorController.shared.statusView?.isActive = false
        }
    }
}

private final class StatusBarCapsuleView: NSView {
    var isActive = false {
        didSet {
            needsDisplay = true
        }
    }

    private let imageView = NSImageView()
    private let titleField = NSTextField(labelWithString: "AIRE")
    private let statusTextFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    private let horizontalPadding: CGFloat = 6
    private let maxWidth: CGFloat = 124
    private let minWidth: CGFloat = 44

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    var preferredWidth: CGFloat {
        let textWidth = ceil(titleField.intrinsicContentSize.width)
        let contentWidth = horizontalPadding * 2 + textWidth + 16
        return min(max(contentWidth, minWidth), maxWidth)
    }

    func update(title: String, image: NSImage?, tooltip: String) {
        titleField.stringValue = title
        imageView.image = image
        toolTip = tooltip
        setAccessibilityLabel(title)
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredWidth, height: NSStatusBar.system.thickness)
    }

    override func layout() {
        super.layout()

        let highlightHeight: CGFloat = 20
        let y = floor((bounds.height - highlightHeight) / 2)
        let textX = horizontalPadding
        let textWidth = max(bounds.width - textX - horizontalPadding, 0)
        titleField.frame = NSRect(x: textX, y: y + 1, width: textWidth, height: highlightHeight - 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard isActive else { return }

        let highlightRect = bounds.insetBy(dx: 1, dy: 3)
        let path = NSBezierPath(
            roundedRect: highlightRect,
            xRadius: highlightRect.height / 2,
            yRadius: highlightRect.height / 2
        )
        NSColor.white.withAlphaComponent(0.18).setFill()
        path.fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func setup() {
        wantsLayer = false
        setAccessibilityRole(.button)

        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = .white
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        imageView.isHidden = true
        addSubview(imageView)

        titleField.font = statusTextFont
        titleField.textColor = .white
        titleField.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
            shadow.shadowBlurRadius = 1.5
            shadow.shadowOffset = NSSize(width: 0, height: -0.5)
            return shadow
        }()
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.drawsBackground = false
        titleField.isBordered = false
        titleField.isEditable = false
        titleField.isSelectable = false
        addSubview(titleField)
    }
}

private struct StatusBarSummary {
    let snapshot: ClusterSnapshot?
    let isConnected: Bool
    let hasCache: Bool
    let isRefreshing: Bool

    var title: String {
        if isRefreshing && snapshot == nil {
            return "Syncing"
        }

        if runningJobs > 0 {
            let name = shortened(primaryRunningJob?.name ?? "job", limit: runningJobs > 1 ? 12 : 16)
            if runningJobs == 1 {
                return "\(name) \(primaryRunningJob?.elapsed ?? "")".trimmedStatusTitle
            }
            return "\(runningJobs) jobs \(name)"
        }

        if gpuTotal > 0 {
            return "GPU \(gpuIdle)"
        }

        if hasCache {
            return "Cached"
        }

        return isConnected ? "Ready" : "Offline"
    }

    var image: NSImage? {
        let name: String
        if isRefreshing {
            name = "arrow.triangle.2.circlepath"
        } else if snapshot == nil && !hasCache {
            name = "wifi.slash"
        } else if runningJobs > 0 {
            name = "play.circle.fill"
        } else if gpuTotal > 0 {
            name = "bolt.horizontal.circle.fill"
        } else {
            name = "server.rack"
        }

        let image = NSImage(systemSymbolName: name, accessibilityDescription: "AIRE Monitor")
        image?.isTemplate = true
        return image
    }

    var tint: NSColor {
        if isRefreshing {
            return isConnected ? .systemMint : .systemOrange
        }
        if snapshot == nil && !hasCache {
            return .secondaryLabelColor
        }
        if !isConnected && hasCache {
            return .systemOrange
        }
        if runningJobs > 0 {
            return .systemGreen
        }
        if gpuTotal == 0 {
            return .labelColor
        }
        if gpuIdle == 0 {
            return .systemRed
        }
        if gpuUsageFraction >= 0.75 {
            return .systemOrange
        }
        return .systemTeal
    }

    var tooltip: String {
        var lines: [String] = []
        if let job = primaryRunningJob {
            lines.append("\(job.name) has been running for \(job.elapsed)")
        } else {
            lines.append(runningJobs == 0 ? "No running jobs" : "\(runningJobs) running jobs")
        }
        lines.append("\(runningJobs) running, \(pendingJobs) pending")
        if gpuTotal > 0 {
            lines.append("\(gpuIdle) of \(gpuTotal) GPUs free")
        }
        if !storagePressureText.isEmpty {
            lines.append(storagePressureText)
        }
        lines.append(isConnected ? "Live, refreshes every 10s" : (hasCache ? "Showing cached data" : "Not connected"))
        return lines.joined(separator: "\n")
    }

    var signature: String {
        [
            title,
            "\(isRefreshing)",
            "\(isConnected)",
            "\(hasCache)",
            "\(runningJobs)",
            "\(pendingJobs)",
            "\(gpuIdle)",
            "\(gpuTotal)",
            storagePressureText
        ].joined(separator: "|")
    }

    private var runningJobs: Int {
        snapshot?.jobs.filter { $0.state.uppercased().contains("RUN") }.count ?? 0
    }

    private var pendingJobs: Int {
        snapshot?.jobs.filter { $0.state.uppercased().contains("PEND") }.count ?? 0
    }

    private var primaryRunningJob: Job? {
        snapshot?.jobs.first { $0.state.uppercased().contains("RUN") }
    }

    private var gpuNodes: [NodeSummary] {
        snapshot?.nodes.filter { statusGPUTotal($0) > 0 } ?? []
    }

    private var gpuTotal: Int {
        gpuNodes.reduce(0) { $0 + statusGPUTotal($1) }
    }

    private var gpuAllocated: Int {
        gpuNodes.reduce(0) { $0 + ($1.gpuAllocated ?? 0) }
    }

    private var gpuIdle: Int {
        max(gpuTotal - gpuAllocated, 0)
    }

    private var gpuUsageFraction: Double {
        guard gpuTotal > 0 else { return 0 }
        return min(Double(gpuAllocated) / Double(gpuTotal), 1)
    }

    private var storagePressureText: String {
        let rows = (snapshot?.storage ?? [])
            .filter { ["home", "scratch"].contains($0.label.lowercased()) }
            .compactMap { storagePressure($0) }
        guard !rows.isEmpty else { return "" }
        return rows.joined(separator: ", ")
    }

    private func storagePressure(_ item: StorageSummary) -> String? {
        guard let percent = item.usedPercent else { return nil }
        return "\(item.label) \(Int(percent.rounded()))%"
    }
}

private func statusGPUTotal(_ node: NodeSummary) -> Int {
    if let gpuTotal = node.gpuTotal {
        return gpuTotal
    }

    if node.gres.localizedCaseInsensitiveContains("gpu") {
        return 1
    }

    return 0
}

private func shortened(_ value: String, limit: Int) -> String {
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard cleaned.count > limit else { return cleaned }
    let end = cleaned.index(cleaned.startIndex, offsetBy: max(limit - 1, 1))
    return "\(cleaned[..<end])..."
}

private extension String {
    var trimmedStatusTitle: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
