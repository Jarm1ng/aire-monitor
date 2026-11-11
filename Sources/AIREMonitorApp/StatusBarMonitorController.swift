import HPCCore
import AppKit
import Combine

/// Owns the menu-bar status item: a monochrome rack glyph (dimmed when
/// nothing is live, badged when something needs a look), a short title
/// ("7 running", or idle GPUs, or nothing — the user's choice), and a
/// native menu built by `StatusMenuBuilder` from the same digest.
@MainActor
final class StatusBarMonitorController: NSObject {
    static let shared = StatusBarMonitorController()

    private var model: AppModel?
    private var statusItem: NSStatusItem?
    private let builder = StatusMenuBuilder()
    private var cancellables = Set<AnyCancellable>()
    private var lastSignature = ""
    private var isUpdateScheduled = false
    private var isMenuOpen = false
    /// The digest the open menu was last built from.
    private var menuDigest: MenuBarDigest?

    private override init() {
        super.init()
    }

    func configure(model: AppModel) {
        self.model = model
        installStatusItemIfNeeded()
        wireBuilder()
        bindModel(model)
        lastSignature = ""
        updateStatusItem()
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.menu = builder.menu

        guard let button = item.button else { return }
        // The button draws the template glyph and the title itself, so
        // AppKit handles light and dark menu bars, vibrancy, the open
        // highlight and Increase Contrast.
        button.font = StatusItemLayout.font
        button.image = StatusItemGlyph.image(attention: false)
        button.imagePosition = .imageLeading
        button.title = ""
        button.toolTip = "Leeds HPC Monitor"
        (button.cell as? NSButtonCell)?.lineBreakMode = .byClipping
    }

    private func wireBuilder() {
        builder.onNeedsUpdate = { [weak self] in
            self?.rebuildMenu()
        }
        builder.onWillOpen = { [weak self] in
            guard let self else { return }
            isMenuOpen = true
            // Each session's refresh self-guards (pause, sign-in, never
            // connected), so opening the menu shows data at most a few
            // seconds old without ever starting a sign-in or painting an
            // error on a cluster the user is not using.
            model?.refreshAllQuietly()
        }
        builder.onDidClose = { [weak self] in
            self?.isMenuOpen = false
        }
        builder.submenuEntries = { [weak self] kind in
            guard let self, let model else { return [] }
            switch kind {
            case .jobs(let id):
                return MenuBarMenuLayout.submenu(for: id, digest: menuDigest ?? MenuBarDigest(model: model))
            case .titleMode:
                return MenuBarMenuLayout.titleModeSubmenu(current: model.menuBarTitleMode)
            }
        }
        builder.onCommand = { [weak self] command in
            self?.perform(command)
        }
    }

    /// Builds the menu from the latest digest just before it is laid out,
    /// so its first frame already has the final size.
    private func rebuildMenu() {
        guard let model else { return }
        let digest = MenuBarDigest(model: model)
        menuDigest = digest
        builder.apply(MenuBarMenuLayout.build(digest: digest))
    }

    /// Listens to the coordinator AND to every session directly: the
    /// coordinator forwards session changes today, but the status item must
    /// keep up even if that app-wide forwarding (which re-renders every
    /// observer of AppModel) is narrowed. Bursts are coalesced below.
    private func bindModel(_ model: AppModel) {
        cancellables.removeAll()
        let changes = [model.objectWillChange.map { _ in () }.eraseToAnyPublisher()]
            + model.sessions.map { $0.objectWillChange.map { _ in () }.eraseToAnyPublisher() }
        Publishers.MergeMany(changes)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                // The queue hop above guarantees main-thread delivery (and
                // keeps flowing during menu tracking, unlike RunLoop.main).
                MainActor.assumeIsolated {
                    self?.scheduleStatusUpdate()
                }
            }
            .store(in: &cancellables)
    }

    /// Coalesces bursts of model changes into one digest rebuild. A single
    /// refresh publishes several properties per cluster, so without this the
    /// digest of every cluster would be rebuilt once per property.
    private func scheduleStatusUpdate() {
        guard !isUpdateScheduled else { return }
        isUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isUpdateScheduled = false
                self.updateStatusItem()
            }
        }
    }

    /// Rebuilds the digest once and hands it to the status item and, while
    /// it is open, the menu (updated in place).
    private func updateStatusItem() {
        guard let model, let button = statusItem?.button else { return }

        let digest = MenuBarDigest(model: model)
        if isMenuOpen, digest != menuDigest {
            menuDigest = digest
            builder.apply(MenuBarMenuLayout.build(digest: digest))
        }

        let summary = StatusBarSummary(digest: digest, mode: model.menuBarTitleMode)
        // Only touch the button when something visible changed: AppKit
        // re-lays out the whole status bar on every title/image change.
        let signature = summary.signature
        guard signature != lastSignature else { return }
        lastSignature = signature

        button.image = StatusItemGlyph.image(attention: summary.hasAttention)
        button.title = summary.displayTitle
        button.appearsDisabled = summary.isDimmed
        button.toolTip = summary.tooltip
        button.setAccessibilityLabel(summary.accessibilityLabel)
        statusItem?.length = summary.reservedLength()
    }

    /// Runs a chosen menu item. NSMenu calls this after the menu has closed,
    /// so activating the app, showing the dashboard or an alert is safe.
    private func perform(_ command: MenuCommand) {
        guard let model else { return }
        switch command {
        case .openJob(let id, let jobId):
            model.showJob(jobId, on: id)
        case .openCluster(let id):
            model.showCluster(id, tab: .jobs)
        case .connect(let id):
            // A plain sign-in: reuses an open session, so no dialog.
            model.connect(id)
        case .cancelSignIn(let id):
            model.session(for: id)?.cancelLogin()
        case .resume(let id):
            model.session(for: id)?.togglePause()
        case .turnOn(let id):
            model.session(for: id)?.isEnabled = true
        case .renewAll:
            guard let confirmation = model.renewConfirmation() else { return }
            SessionActionAlert.run(confirmation, model: model)
        case .openDashboard:
            DashboardWindowPresenter.shared.show()
        case .openWidget:
            model.openDesktopWidget()
        case .setTitleMode(let mode):
            model.menuBarTitleMode = mode
        case .quit:
            // The quit itself goes through the app delegate, which can still
            // ask about running terminals.
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}
