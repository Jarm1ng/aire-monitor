import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarMonitorController: NSObject {
    static let shared = StatusBarMonitorController()

    private var model: AppModel?
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var menuHostingView: NSHostingView<MenuBarMonitorView>?
    private var cancellables = Set<AnyCancellable>()
    private var lastSignature = ""

    private let statusFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    private let minItemLength: CGFloat = 56
    private let maxItemLength: CGFloat = 150

    private override init() {
        super.init()
    }

    func configure(model: AppModel) {
        self.model = model
        installStatusItemIfNeeded()
        installMenu(model: model)
        bindModel(model)
        lastSignature = ""
        updateStatusItem()
    }

    /// Dismisses the status-bar menu, so actions that activate other windows
    /// (Open, Widget) do not fight an in-progress menu tracking session.
    func closeMenu() {
        menu?.cancelTracking()
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        guard let button = item.button else { return }
        // The button renders the title and template image itself, so AppKit
        // handles menu-bar appearance (light/dark), vibrancy, and the
        // standard click highlight.
        button.title = "AIRE"
        button.font = statusFont
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.toolTip = "AIRE Monitor"
        (button.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
    }

    private func installMenu(model: AppModel) {
        let rootView = makeMenuView(model: model)
        if let menuHostingView {
            // Re-entrant configure: reuse the existing menu, just swap the model.
            menuHostingView.rootView = rootView
            return
        }

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = [.preferredContentSize]
        hostingView.setFrameSize(hostingView.fittingSize)

        let panelItem = NSMenuItem()
        panelItem.view = hostingView

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(panelItem)

        statusItem?.menu = menu
        self.menu = menu
        menuHostingView = hostingView
    }

    private func makeMenuView(model: AppModel) -> MenuBarMonitorView {
        MenuBarMonitorView(model: model) { [weak self] in
            self?.closeMenu()
        }
    }

    private func bindModel(_ model: AppModel) {
        cancellables.removeAll()
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // The queue hop above guarantees main-thread delivery (and
                // keeps flowing during menu tracking, unlike RunLoop.main).
                MainActor.assumeIsolated {
                    self?.updateStatusItem()
                }
            }
            .store(in: &cancellables)
    }

    private func updateStatusItem() {
        guard let model, let button = statusItem?.button else { return }

        let summary = StatusBarSummary(
            snapshot: model.snapshot,
            isConnected: model.isLoggedIn,
            hasCache: model.hasCachedSnapshot,
            isRefreshing: model.isRefreshing,
            refreshIntervalText: model.refreshIntervalText
        )
        let signature = summary.signature
        guard signature != lastSignature else { return }
        lastSignature = signature

        let image = summary.image
        button.image = image
        button.title = summary.title
        button.toolTip = summary.tooltip
        button.setAccessibilityLabel(summary.title)
        statusItem?.length = reservedLength(for: summary, hasIcon: image != nil)
    }

    /// Width computed from a digit-stable template of the title so the status
    /// item does not resize on every elapsed-time tick.
    private func reservedLength(for summary: StatusBarSummary, hasIcon: Bool) -> CGFloat {
        let template = summary.widthTemplateTitle as NSString
        let textWidth = ceil(template.size(withAttributes: [.font: statusFont]).width)
        let iconWidth: CGFloat = hasIcon ? 20 : 0
        let padding: CGFloat = 16
        return min(max(iconWidth + textWidth + padding, minItemLength), maxItemLength)
    }
}

extension StatusBarMonitorController: NSMenuDelegate {
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        // NSMenu delegate callbacks always arrive on the main thread.
        MainActor.assumeIsolated {
            // refresh() self-guards on isRefreshing/isLoggingIn, so opening
            // the menu shows data at most a few seconds old.
            model?.refresh()
        }
    }
}

private struct StatusBarSummary {
    let snapshot: ClusterSnapshot?
    let isConnected: Bool
    let hasCache: Bool
    let isRefreshing: Bool
    let refreshIntervalText: String

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

        if totalGPUs > 0 {
            return "GPU \(idleGPUs)"
        }

        if hasCache {
            return "Cached"
        }

        return isConnected ? "Ready" : "Offline"
    }

    /// `title` with every elapsed digit replaced by a fixed-width placeholder,
    /// padded to at least h:mm:ss, so the reserved width only changes when the
    /// job (or the elapsed format) changes - not every refresh tick.
    var widthTemplateTitle: String {
        guard runningJobs == 1, let job = primaryRunningJob, !job.elapsed.isEmpty else {
            return title
        }
        let name = shortened(job.name, limit: 16)
        return "\(name) \(elapsedWidthTemplate(job.elapsed))".trimmedStatusTitle
    }

    var iconName: String {
        if isRefreshing {
            return "arrow.triangle.2.circlepath"
        }
        if snapshot == nil && !hasCache {
            return "wifi.slash"
        }
        if runningJobs > 0 {
            return "play.circle.fill"
        }
        if totalGPUs > 0 {
            return "bolt.horizontal.circle.fill"
        }
        return "server.rack"
    }

    /// nil means "render as a standard template image" (adapts to the menu
    /// bar appearance); a color tints the icon so connection/pressure state
    /// is visible at a glance.
    var tint: NSColor? {
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
        if totalGPUs == 0 {
            return nil
        }
        if idleGPUs == 0 {
            return .systemRed
        }
        if gpuUsageFraction >= 0.75 {
            return .systemOrange
        }
        return .systemTeal
    }

    var image: NSImage? {
        let base = NSImage(systemSymbolName: iconName, accessibilityDescription: "AIRE Monitor status")
        var configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        if let tint {
            configuration = configuration.applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        }
        let image = base?.withSymbolConfiguration(configuration)
        image?.isTemplate = tint == nil
        return image
    }

    var tooltip: String {
        var lines: [String] = []
        if let job = primaryRunningJob {
            lines.append("\(job.name) has been running for \(job.elapsed)")
        } else {
            lines.append(runningJobs == 0 ? "No running jobs" : "\(runningJobs) running jobs")
        }
        lines.append("\(runningJobs) running, \(pendingJobs) pending")
        if totalGPUs > 0 {
            lines.append("\(idleGPUs) of \(totalGPUs) GPUs free")
        }
        if !storagePressureText.isEmpty {
            lines.append(storagePressureText)
        }
        lines.append(isConnected ? "Live, refreshes every \(refreshIntervalText)" : (hasCache ? "Showing cached data" : "Not connected"))
        return lines.joined(separator: "\n")
    }

    var signature: String {
        [
            title,
            widthTemplateTitle,
            iconName,
            tint?.description ?? "template",
            tooltip
        ].joined(separator: "|")
    }

    private var runningJobs: Int {
        snapshot?.jobs.filter { statusIsRunning($0.state) }.count ?? 0
    }

    private var pendingJobs: Int {
        snapshot?.jobs.filter { statusIsPending($0.state) }.count ?? 0
    }

    private var primaryRunningJob: Job? {
        (snapshot?.jobs ?? [])
            .filter { statusIsRunning($0.state) }
            .min { $0.jobId < $1.jobId }
    }

    private var gpuNodes: [NodeSummary] {
        snapshot?.nodes.filter { gpuTotal($0) > 0 } ?? []
    }

    private var totalGPUs: Int {
        gpuNodes.reduce(0) { $0 + gpuTotal($1) }
    }

    private var allocatedGPUs: Int {
        gpuNodes.reduce(0) { $0 + gpuAllocated($1) }
    }

    private var idleGPUs: Int {
        gpuNodes.reduce(0) { $0 + gpuIdle($1) }
    }

    private var gpuUsageFraction: Double {
        guard totalGPUs > 0 else { return 0 }
        return min(Double(allocatedGPUs) / Double(totalGPUs), 1)
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

private func statusIsRunning(_ state: String) -> Bool {
    state.uppercased().contains("RUN")
}

private func statusIsPending(_ state: String) -> Bool {
    state.uppercased().contains("PEND")
}

private func elapsedWidthTemplate(_ elapsed: String) -> String {
    let mapped = String(elapsed.map { $0.isNumber ? "8" : $0 })
    return mapped.count >= 7 ? mapped : "8:88:88"
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
