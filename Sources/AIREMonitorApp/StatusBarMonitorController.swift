import HPCCore
import AppKit
import Combine
import SwiftUI

/// Owns the menu-bar status item. Its title summarises every live cluster at
/// once ("C · train 1h 23m", "3 jobs", "A 6 · C 27"), its icon tint shows
/// combined connection health, and its menu hosts MenuBarMonitorView.
@MainActor
final class StatusBarMonitorController: NSObject {
    static let shared = StatusBarMonitorController()

    private var model: AppModel?
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var menuHostingView: NSHostingView<StatusMenuRootView>?
    /// Feeds the open dropdown the digest built for the status item.
    private var digestStore: MenuBarDigestStore?
    private var cancellables = Set<AnyCancellable>()
    private var lastSignature = ""
    private var isUpdateScheduled = false
    private var isMenuOpen = false
    private var isMenuContentAttached = false

    private override init() {
        super.init()
    }

    func configure(model: AppModel) {
        self.model = model
        installStatusItemIfNeeded()
        installMenuIfNeeded()
        bindModel(model)
        lastSignature = ""
        updateStatusItem()
    }

    /// Dismisses the status-bar menu, so actions that activate other windows
    /// (Open dashboard, Widget, Quit) do not fight an in-progress menu
    /// tracking session.
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
        button.font = StatusItemLayout.font
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.toolTip = "Leeds HPC Monitor"
        // StatusBarSummary already fits the title to the item; should that
        // ever fall short, cut the job name's middle, not the elapsed time.
        (button.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingMiddle
    }

    private func installMenuIfNeeded() {
        guard menuHostingView == nil else {
            // Re-entrant configure: the next open builds the content
            // against the new model.
            detachMenuContent()
            return
        }

        let hostingView = NSHostingView(rootView: StatusMenuRootView(content: nil))
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

    /// Builds the dropdown just before it is shown. While the menu is
    /// closed the hosting view holds an empty placeholder, so nothing in it
    /// observes or re-renders on the many model changes nobody would see.
    private func attachMenuContent() {
        guard let model, let menuHostingView, !isMenuContentAttached else {
            return
        }
        let digest = MenuBarDigest(model: model)
        let store = digestStore ?? MenuBarDigestStore(digest: digest)
        store.update(digest)
        digestStore = store
        menuHostingView.rootView = StatusMenuRootView(
            content: MenuBarMonitorView(model: model, store: store) { [weak self] in
                self?.closeMenu()
            }
        )
        isMenuContentAttached = true
        fitMenuPanel()
    }

    private func detachMenuContent() {
        guard isMenuContentAttached else {
            return
        }
        menuHostingView?.rootView = StatusMenuRootView(content: nil)
        isMenuContentAttached = false
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

    /// Rebuilds the digest once and hands the same value to the status item
    /// and, while it is open, the dropdown.
    private func updateStatusItem() {
        guard let model, let button = statusItem?.button else { return }

        let digest = MenuBarDigest(model: model)
        if isMenuOpen {
            digestStore?.update(digest)
            fitMenuPanel()
            // SwiftUI applies the store change on its next pass; fit again
            // once it has, so a section that grew is not clipped.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.fitMenuPanel()
                }
            }
        }

        let summary = StatusBarSummary(digest: digest)
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
        statusItem?.length = summary.reservedLength(hasIcon: image != nil)
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
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        // Called before the menu is laid out for display: the earliest point
        // to attach the real content, so the first frame has its full size.
        MainActor.assumeIsolated {
            attachMenuContent()
        }
    }

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        // NSMenu delegate callbacks always arrive on the main thread.
        MainActor.assumeIsolated {
            isMenuOpen = true
            attachMenuContent()
            fitMenuPanel()
            // Each session's refresh self-guards (pause, sign-in, never
            // connected), so opening the menu shows data at most a few
            // seconds old without ever starting a sign-in or painting an
            // error on a cluster the user is not using.
            model?.refreshAllQuietly()
        }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            isMenuOpen = false
            // Deferred: a footer action that closed the menu may still be
            // unwinding inside the hosted SwiftUI view.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isMenuOpen else { return }
                    self.detachMenuContent()
                }
            }
        }
    }
}

/// The menu item's root view: the dropdown while the menu is open, an
/// inert placeholder of the same width while it is closed.
private struct StatusMenuRootView: View {
    let content: MenuBarMonitorView?

    var body: some View {
        if let content {
            content
        } else {
            Color.clear
                .frame(width: MenuBarMonitorView.panelWidth, height: 1)
        }
    }
}
