import AppKit
import Combine
import SwiftUI

/// Owns the menu-bar status item. Its title summarises every enabled
/// cluster at once ("C · train 1:23", "3 jobs", "A 6 · C 27"), its icon tint
/// shows combined connection health, and its menu hosts MenuBarMonitorView.
@MainActor
final class StatusBarMonitorController: NSObject {
    static let shared = StatusBarMonitorController()

    private var model: AppModel?
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var menuHostingView: NSHostingView<MenuBarMonitorView>?
    private var cancellables = Set<AnyCancellable>()
    private var lastSignature = ""
    private var isUpdateScheduled = false
    private var isMenuOpen = false

    private let statusFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    private let minItemLength: CGFloat = 56
    private let maxItemLength: CGFloat = 160

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
    /// (Open dashboard, Widget) do not fight an in-progress menu tracking
    /// session.
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
        button.title = "HPC"
        button.font = statusFont
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.toolTip = "Leeds HPC Monitor"
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
                    self?.scheduleStatusUpdate()
                }
            }
            .store(in: &cancellables)
    }

    /// Coalesces bursts of model changes into one summary rebuild. A single
    /// refresh publishes several properties per cluster and AppModel
    /// forwards every one of them, so without this the digest of every
    /// cluster would be rebuilt once per property.
    private func scheduleStatusUpdate() {
        guard !isUpdateScheduled else { return }
        isUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isUpdateScheduled = false
                self.updateStatusItem()
                if self.isMenuOpen {
                    self.fitMenuPanel()
                }
            }
        }
    }

    private func updateStatusItem() {
        guard let model, let button = statusItem?.button else { return }

        let summary = StatusBarSummary(digest: MenuBarDigest(model: model))
        // Only touch the button when something visible changed: AppKit
        // re-lays out the whole status bar on every title/image change.
        let signature = summary.signature
        guard signature != lastSignature else { return }
        lastSignature = signature

        let image = summary.image
        button.image = image
        button.title = summary.title
        button.toolTip = summary.tooltip
        button.setAccessibilityLabel(summary.accessibilityLabel)
        statusItem?.length = reservedLength(for: summary, hasIcon: image != nil)
    }

    /// Width computed from a digit-stable template of the title so the status
    /// item does not resize on every elapsed-time tick or idle-GPU change.
    private func reservedLength(for summary: StatusBarSummary, hasIcon: Bool) -> CGFloat {
        let template = summary.widthTemplateTitle as NSString
        let textWidth = ceil(template.size(withAttributes: [.font: statusFont]).width)
        let iconWidth: CGFloat = hasIcon ? 20 : 0
        let padding: CGFloat = 16
        return min(max(iconWidth + textWidth + padding, minItemLength), maxItemLength)
    }

    /// Resizes the hosted dropdown to its content. A cluster connecting or
    /// gaining jobs changes the panel's height, and the menu item keeps
    /// whatever frame its view had unless told otherwise.
    private func fitMenuPanel() {
        guard let menuHostingView else { return }
        let size = menuHostingView.fittingSize
        guard size != menuHostingView.frame.size else { return }
        menuHostingView.setFrameSize(size)
    }
}

extension StatusBarMonitorController: NSMenuDelegate {
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        // NSMenu delegate callbacks always arrive on the main thread.
        MainActor.assumeIsolated {
            isMenuOpen = true
            fitMenuPanel()
            // Each session's refresh() self-guards on isRefreshing and
            // isLoggingIn, so opening the menu shows data at most a few
            // seconds old without ever starting a sign-in.
            model?.refreshAllQuietly()
        }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            isMenuOpen = false
        }
    }
}

/// What the status item shows, derived from the shared menu bar digest.
private struct StatusBarSummary {
    let digest: MenuBarDigest
    let mode: Mode

    enum Mode {
        /// Exactly one running job across all enabled clusters.
        case singleJob(cluster: MenuBarClusterDigest, job: Job)
        /// Several running jobs (on one or more clusters).
        case multipleJobs(count: Int)
        /// No running jobs: idle GPUs of each cluster that has a snapshot.
        /// Pools stay separate (L40S and H200 are different hardware).
        case idleGPUs([(cluster: MenuBarClusterDigest, pool: MenuBarGPUPool)])
        case idle(IdleState)
    }

    enum IdleState {
        case off
        case signingIn
        case syncing
        case ready
        case cached
        case offline

        var title: String {
            switch self {
            case .off: return "Off"
            case .signingIn: return "Signing in"
            case .syncing: return "Syncing"
            case .ready: return "Ready"
            case .cached: return "Cached"
            case .offline: return "Offline"
            }
        }
    }

    init(digest: MenuBarDigest) {
        self.digest = digest
        let enabled = digest.enabled
        let running = digest.runningCount
        if running == 1, let primary = digest.primaryRunningJob {
            mode = .singleJob(cluster: primary.cluster, job: primary.job)
        } else if running > 1 {
            mode = .multipleJobs(count: running)
        } else {
            let pools = enabled.compactMap { cluster in
                cluster.gpu.map { (cluster: cluster, pool: $0) }
            }
            if !pools.isEmpty {
                mode = .idleGPUs(pools)
            } else if enabled.isEmpty {
                mode = .idle(.off)
            } else if enabled.contains(where: { $0.state.isBusy }) {
                mode = .idle(.signingIn)
            } else if enabled.contains(where: \.isRefreshing), !enabled.contains(where: \.hasSnapshot) {
                mode = .idle(.syncing)
            } else if enabled.contains(where: \.isLive) {
                mode = .idle(.ready)
            } else if enabled.contains(where: \.hasSnapshot) {
                mode = .idle(.cached)
            } else {
                mode = .idle(.offline)
            }
        }
    }

    var title: String {
        switch mode {
        case .singleJob(let cluster, let job):
            return "\(cluster.profile.monogram) · \(Self.jobTitle(job)) \(job.elapsed)".statusTrimmed
        case .multipleJobs(let count):
            return "\(count) jobs"
        case .idleGPUs(let pools):
            return pools.map { "\($0.cluster.profile.monogram) \($0.pool.idle)" }.joined(separator: " · ")
        case .idle(let state):
            return state.title
        }
    }

    /// `title` with every changing digit replaced by a fixed-width
    /// placeholder (elapsed padded to at least h:mm:ss, GPU counts to two
    /// digits), so the reserved width only changes when the job or the
    /// cluster set changes - not on every refresh tick.
    var widthTemplateTitle: String {
        switch mode {
        case .singleJob(let cluster, let job) where !job.elapsed.isEmpty:
            return "\(cluster.profile.monogram) · \(Self.jobTitle(job)) \(elapsedWidthTemplate(job.elapsed))".statusTrimmed
        case .idleGPUs(let pools):
            return pools.map { "\($0.cluster.profile.monogram) \(countWidthTemplate($0.pool.idle))" }
                .joined(separator: " · ")
        default:
            return title
        }
    }

    var iconName: String {
        switch mode {
        case .singleJob, .multipleJobs:
            return "play.circle.fill"
        case .idleGPUs:
            return "bolt.horizontal.circle.fill"
        case .idle(.off):
            return "pause.circle"
        case .idle(.signingIn), .idle(.syncing):
            return "arrow.triangle.2.circlepath"
        case .idle(.ready), .idle(.cached):
            return "server.rack"
        case .idle(.offline):
            return "wifi.slash"
        }
    }

    /// Combined connection health: green when every enabled cluster is
    /// live, orange when only some are (or data is cached/paused, or a
    /// sign-in is running), red when nothing is live and a cluster reports
    /// an error, dimmed when simply offline. nil (template image) when
    /// monitoring is off everywhere, so the icon blends in.
    var tint: NSColor? {
        switch digest.health {
        case .off: return nil
        case .allLive: return .systemGreen
        case .partial, .connecting: return .systemOrange
        case .failing: return .systemRed
        case .offline: return .secondaryLabelColor
        }
    }

    var image: NSImage? {
        let base = NSImage(systemSymbolName: iconName, accessibilityDescription: "Leeds HPC Monitor status")
        var configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        if let tint {
            configuration = configuration.applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        }
        let image = base?.withSymbolConfiguration(configuration)
        image?.isTemplate = tint == nil
        return image
    }

    /// One block per cluster, then the shared home quota once. Deliberately
    /// free of relative ages: those would change the signature every second
    /// and defeat the redraw skipping.
    var tooltip: String {
        var lines = [headline]
        for cluster in digest.clusters {
            lines.append("\(cluster.displayName) — \(cluster.connectionText)")
            if let signIn = cluster.signInText {
                lines.append("  \(signIn)")
            }
            guard cluster.isEnabled, cluster.hasSnapshot else {
                continue
            }
            lines.append("  \(cluster.runningJobs.count) running, \(cluster.pendingJobs.count) pending")
            if let pool = cluster.gpu {
                lines.append("  \(pool.idle) of \(pool.total) \(pool.title) free")
            }
            let pressure = cluster.storage.compactMap(\.pressureText)
            if !pressure.isEmpty {
                lines.append("  " + pressure.joined(separator: ", "))
            }
        }
        if let home = digest.sharedHome, let pressure = home.row.pressureText {
            lines.append("\(pressure) (\(home.sharedByText), counted once)")
        }
        return lines.joined(separator: "\n")
    }

    var accessibilityLabel: String {
        switch mode {
        case .singleJob(let cluster, let job):
            return "\(Self.jobDisplayName(job)) running on \(cluster.displayName) for \(job.elapsed)"
        case .multipleJobs(let count):
            return "\(count) running jobs: \(runningBreakdown)"
        case .idleGPUs(let pools):
            let parts = pools.map { "\($0.cluster.displayName) \($0.pool.idle) \($0.pool.title)" }
            return "Idle GPUs: \(parts.joined(separator: ", "))"
        case .idle(let state):
            return "Leeds HPC Monitor: \(state.title)"
        }
    }

    var signature: String {
        [
            title,
            widthTemplateTitle,
            iconName,
            tint?.description ?? "template",
            tooltip,
            accessibilityLabel
        ].joined(separator: "|")
    }

    private var headline: String {
        switch mode {
        case .singleJob(let cluster, let job):
            return "\(Self.jobDisplayName(job)) on \(cluster.displayName) has been running for \(job.elapsed)"
        case .multipleJobs(let count):
            var text = "\(count) running jobs — \(runningBreakdown)"
            if let primary = digest.primaryRunningJob {
                text += " (latest: \(Self.jobDisplayName(primary.job)) on \(primary.cluster.displayName))"
            }
            return text
        case .idleGPUs, .idle:
            return "Leeds HPC Monitor — \(digest.headerStatusLine)"
        }
    }

    /// "AIRE 1, Calder 2": running jobs per cluster, never as one bare sum.
    private var runningBreakdown: String {
        digest.enabled
            .filter { !$0.runningJobs.isEmpty }
            .map { "\($0.displayName) \($0.runningJobs.count)" }
            .joined(separator: ", ")
    }

    private static func jobDisplayName(_ job: Job) -> String {
        let name = job.name.statusTrimmed
        return name.isEmpty ? "Job \(job.jobId)" : name
    }

    /// Short enough that monogram + name + h:mm:ss fits the item width cap.
    private static func jobTitle(_ job: Job) -> String {
        shortened(job.name.statusTrimmed.isEmpty ? "job" : job.name, limit: 12)
    }
}

private func elapsedWidthTemplate(_ elapsed: String) -> String {
    let mapped = String(elapsed.map { $0.isNumber ? "8" : $0 })
    return mapped.count >= 7 ? mapped : "8:88:88"
}

private func countWidthTemplate(_ count: Int) -> String {
    String(repeating: "8", count: max(String(count).count, 2))
}

private func shortened(_ value: String, limit: Int) -> String {
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard cleaned.count > limit else { return cleaned }
    let end = cleaned.index(cleaned.startIndex, offsetBy: max(limit - 1, 1))
    return "\(cleaned[..<end])…"
}

private extension String {
    var statusTrimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
