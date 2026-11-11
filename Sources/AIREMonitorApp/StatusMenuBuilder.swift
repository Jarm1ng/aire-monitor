import HPCCore
import AppKit
import SwiftUI

// Turns `MenuEntry` values into the status item's native NSMenu: real
// NSMenuItems for everything you act on (system highlight, keyboard, type
// select, native scrolling) and small SwiftUI views in disabled items for
// the rows that need a meter or a tone colour. An open menu is updated in
// place by entry id — never rebuilt — so the highlight under the pointer
// stays put while a refresh lands.

/// Metrics that line hosted rows up with native items. Where AppKit's own
/// geometry differs between macOS releases, it is measured once from a
/// throwaway NSMenu rather than assumed.
@MainActor
enum MenuMetrics {
    static let minimumWidth: CGFloat = 340
    /// Where native titles start (and hosted rows' content).
    static var textInset: CGFloat {
        if #available(macOS 26, *) {
            return 16
        }
        return 14
    }

    static var font: NSFont { NSFont.menuFont(ofSize: 0) }

    /// How much wider a menu is than a title's tab stop: insets plus the
    /// submenu-arrow column. A trailing tab at `trailingTab` then keeps the
    /// menu at `minimumWidth`.
    static let trailingOverhead: CGFloat = {
        let probe: CGFloat = 200
        let menu = NSMenu()
        menu.showsStateColumn = false
        menu.font = NSFont.menuFont(ofSize: 0)
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: probe)]
        let tabbed = NSMenuItem(title: "X", action: nil, keyEquivalent: "")
        tabbed.attributedTitle = NSAttributedString(string: "X\tX", attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: style])
        menu.addItem(tabbed)
        let parent = NSMenuItem(title: "X", action: nil, keyEquivalent: "")
        parent.submenu = NSMenu()
        menu.addItem(parent)
        let overhead = menu.size.width - probe
        return overhead > 20 && overhead < 140 ? overhead : 65
    }()

    /// The right-aligned tab stop for trailing figures, from the title's
    /// start; hosted rows end their figures at the same x.
    static var trailingTab: CGFloat { minimumWidth - trailingOverhead }

    /// AppKit's indent per `indentationLevel` (12 pt on recent releases).
    static let indentPerLevel: CGFloat = {
        func width(_ level: Int) -> CGFloat {
            let menu = NSMenu()
            menu.showsStateColumn = false
            menu.font = NSFont.menuFont(ofSize: 0)
            let item = NSMenuItem(title: "W", action: nil, keyEquivalent: "")
            item.indentationLevel = level
            menu.addItem(item)
            return menu.size.width
        }
        let delta = width(1) - width(0)
        return delta > 0 && delta < 40 ? delta : 12
    }()

    /// A native item's height (22 pt before macOS 26, 24 pt after), which
    /// hosted single-line rows match.
    static let rowHeight: CGFloat = {
        func height(_ count: Int) -> CGFloat {
            let menu = NSMenu()
            menu.font = NSFont.menuFont(ofSize: 0)
            for index in 0..<count {
                menu.addItem(withTitle: "Item \(index)", action: nil, keyEquivalent: "")
            }
            return menu.size.height
        }
        let delta = height(2) - height(1)
        return delta > 14 && delta < 40 ? delta : 22
    }()

    static let headerHeight: CGFloat = 28
    static var captionedRowHeight: CGFloat { rowHeight + 14 }
    static let noteLineHeight: CGFloat = 16
}

@MainActor
final class StatusMenuBuilder: NSObject, NSMenuDelegate {
    let menu: NSMenu
    /// Runs a chosen item's command (after the menu has closed).
    var onCommand: ((MenuCommand) -> Void)?
    /// Entries of a submenu, asked for when it is about to open.
    var submenuEntries: ((MenuSubmenu) -> [MenuEntry])?
    /// Root menu events, for the controller.
    var onNeedsUpdate: (() -> Void)?
    var onWillOpen: (() -> Void)?
    var onDidClose: (() -> Void)?

    private var items: [String: NSMenuItem] = [:]
    private var entries: [String: MenuEntry] = [:]
    private var submenuKinds: [ObjectIdentifier: MenuSubmenu] = [:]

    override init() {
        menu = NSMenu()
        super.init()
        configure(menu)
        menu.delegate = self
    }

    private func configure(_ menu: NSMenu) {
        menu.autoenablesItems = false
        menu.minimumWidth = MenuMetrics.minimumWidth
        menu.showsStateColumn = false
        menu.font = MenuMetrics.font
    }

    // MARK: Applying entries

    /// Makes the root menu show `newEntries`: updates items whose id stays
    /// in place, inserts and removes only what changed.
    func apply(_ newEntries: [MenuEntry]) {
        let ids = newEntries.map(\.id)
        let wanted = Set(ids)
        for (id, item) in items where !wanted.contains(id) {
            if menu.index(of: item) >= 0 {
                menu.removeItem(item)
            }
            items[id] = nil
            entries[id] = nil
        }
        for (index, entry) in newEntries.enumerated() {
            if let item = items[entry.id] {
                if entries[entry.id] != entry {
                    update(item, with: entry)
                    entries[entry.id] = entry
                }
                if menu.index(of: item) != index {
                    menu.removeItem(item)
                    menu.insertItem(item, at: min(index, menu.numberOfItems))
                }
            } else {
                let item = makeItem(entry)
                items[entry.id] = item
                entries[entry.id] = entry
                menu.insertItem(item, at: min(index, menu.numberOfItems))
            }
        }
    }

    /// Fills a submenu from scratch (it is rebuilt each time it opens).
    private func fill(_ submenu: NSMenu, with newEntries: [MenuEntry]) {
        submenu.removeAllItems()
        for entry in newEntries {
            submenu.addItem(makeItem(entry))
        }
    }

    private func makeItem(_ entry: MenuEntry) -> NSMenuItem {
        switch entry {
        case .separator:
            return NSMenuItem.separator()
        case .item(let model):
            if model.isSectionHeader {
                if #available(macOS 14, *) {
                    return NSMenuItem.sectionHeader(title: model.title)
                }
                let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                item.attributedTitle = NSAttributedString(string: model.title, attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor
                ])
                return item
            }
            let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: "")
            update(item, with: entry)
            return item
        default:
            let item = NSMenuItem()
            item.isEnabled = false
            update(item, with: entry)
            return item
        }
    }

    private func update(_ item: NSMenuItem, with entry: MenuEntry) {
        switch entry {
        case .separator:
            return
        case .item(let model):
            configureNative(item, model)
        case .clusterHeader(let header):
            host(item, AnyView(MenuClusterHeaderRow(header: header)), height: MenuMetrics.headerHeight, label: header.accessibilityLabel)
        case .note(_, let note):
            host(item, AnyView(MenuNoteRow(note: note)), height: noteHeight(note.text), label: note.text)
        case .gpuPool(_, let row):
            host(
                item,
                AnyView(MenuGPUPoolRow(row: row)),
                height: row.caption == nil ? MenuMetrics.rowHeight : MenuMetrics.captionedRowHeight,
                label: row.spokenText
            )
        case .storage(_, let row):
            host(
                item,
                AnyView(MenuStorageWarningRow(row: row)),
                height: MenuMetrics.rowHeight,
                label: "\(row.label) \(row.percentLabel)\(row.rest)"
            )
            item.toolTip = row.detail
            item.view?.toolTip = row.detail
        }
    }

    private func configureNative(_ item: NSMenuItem, _ model: MenuItemModel) {
        let indentWidth = CGFloat(model.indent) * MenuMetrics.indentPerLevel
        let font = MenuMetrics.font
        let measure: (String) -> CGFloat = { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }
        var title = model.title
        // Only job rows are fitted: they carry a figure (or an id) that must
        // stay visible. Other rows keep their full text; a rare long one
        // widens the menu instead.
        if model.trailing != nil || model.protectedSuffix != nil {
            var budget = MenuMetrics.trailingTab - indentWidth
            if let trailing = model.trailing {
                budget -= measure(trailing) + 16
            }
            title = TextFitting.middleTruncated(model.title, toFit: max(budget, 60), measure: measure)
            if title != model.title, let suffix = model.protectedSuffix, model.title.hasSuffix(suffix) {
                // Shorten the name, never the id after it.
                let name = String(model.title.dropLast(suffix.count))
                let fitted = TextFitting.middleTruncated(name, toFit: max(budget - measure(suffix), 40), measure: measure)
                title = (fitted.isEmpty ? "…" : fitted) + suffix
            }
        }
        if let trailing = model.trailing {
            let style = NSMutableParagraphStyle()
            style.tabStops = [NSTextTab(textAlignment: .right, location: MenuMetrics.trailingTab - indentWidth)]
            // Font and paragraph style only — never a colour — so AppKit
            // still inverts the title when the item is highlighted.
            item.attributedTitle = NSAttributedString(string: "\(title)\t\(trailing)", attributes: [
                .font: font,
                .paragraphStyle: style
            ])
        } else if title != model.title {
            item.attributedTitle = NSAttributedString(string: title, attributes: [.font: font])
        } else {
            item.attributedTitle = nil
        }
        // The full, plain title last: setting `attributedTitle` replaces
        // `title`, and type-select and VoiceOver read the plain one.
        item.title = model.title
        item.toolTip = model.toolTip
        item.indentationLevel = model.indent
        item.state = model.isChecked ? .on : .off
        item.isEnabled = model.isEnabled
        if let command = model.command {
            item.target = self
            item.action = #selector(choose(_:))
            item.representedObject = MenuCommandBox(command)
        } else {
            item.target = nil
            item.action = nil
            item.representedObject = nil
        }
        if let kind = model.submenu {
            let submenu = item.submenu ?? NSMenu(title: model.title)
            configure(submenu)
            submenu.minimumWidth = 300
            submenu.delegate = self
            submenuKinds[ObjectIdentifier(submenu)] = kind
            if kind == .titleMode {
                submenu.showsStateColumn = true
            }
            item.submenu = submenu
        } else {
            item.submenu = nil
        }
    }

    private func host(_ item: NSMenuItem, _ view: AnyView, height: CGFloat, label: String) {
        let content = AnyView(view.accessibilityElement(children: .ignore).accessibilityLabel(label))
        if let hosting = item.view as? MenuRowHostingView {
            hosting.rootView = content
            if hosting.frame.height != height {
                hosting.setFrameSize(NSSize(width: hosting.frame.width, height: height))
            }
        } else {
            let hosting = MenuRowHostingView(rootView: content)
            hosting.frame = NSRect(x: 0, y: 0, width: MenuMetrics.minimumWidth, height: height)
            item.view = hosting
        }
        item.isEnabled = false
    }

    private func noteHeight(_ text: String) -> CGFloat {
        let width = MenuMetrics.trailingTab - 18
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width, height: 200),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
        )
        let lines = min(max(Int(ceil(bounds.height / 14)), 1), 2)
        return CGFloat(lines) * MenuMetrics.noteLineHeight + 6
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? MenuCommandBox else {
            return
        }
        onCommand?(box.command)
    }

    // MARK: NSMenuDelegate

    // NSMenu calls its delegate on the main thread; the menus never leave
    // it, so handing one into the main-actor closure is safe.

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        nonisolated(unsafe) let target = menu
        MainActor.assumeIsolated {
            if target === self.menu {
                onNeedsUpdate?()
            } else if let kind = submenuKinds[ObjectIdentifier(target)] {
                fill(target, with: submenuEntries?(kind) ?? [])
            }
        }
    }

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        let target = ObjectIdentifier(menu)
        MainActor.assumeIsolated {
            if target == ObjectIdentifier(self.menu) {
                onWillOpen?()
            }
        }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        let target = ObjectIdentifier(menu)
        MainActor.assumeIsolated {
            if target == ObjectIdentifier(self.menu) {
                onDidClose?()
            }
        }
    }
}

/// `MenuCommand` as an Objective-C object, for `representedObject`.
private final class MenuCommandBox: NSObject {
    let command: MenuCommand

    init(_ command: MenuCommand) {
        self.command = command
    }
}

/// Hosts one informational row: a fixed frame set before it is added (no
/// sizing during menu tracking), stretched to the menu's width by NSMenu.
final class MenuRowHostingView: NSHostingView<AnyView> {
    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = []
        autoresizingMask = [.width]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

// MARK: - Hosted rows

/// No backgrounds, materials or strokes: the menu's own material, Reduce
/// Transparency and Increase Contrast apply untouched.
private struct MenuRowFrame<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            content
                .frame(width: MenuMetrics.trailingTab, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.leading, MenuMetrics.textInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct MenuClusterHeaderRow: View {
    let header: MenuClusterHeader
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        MenuRowFrame {
            HStack(spacing: 6) {
                if let profile = ClusterCatalog.profile(for: header.cluster) {
                    ClusterBadge(profile: profile, size: 16)
                    Text(profile.displayName)
                        .font(.system(size: 13, weight: .semibold))
                }
                Spacer(minLength: 8)
                indicator
                Text(header.statusText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(textColor)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch header.dot {
        case .busy:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
                .frame(width: 10, height: 10)
        case .idle:
            Circle()
                .stroke(Color.secondary, lineWidth: 1)
                .frame(width: 6, height: 6)
        case .none:
            EmptyView()
        default:
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
        }
    }

    private var dotColor: Color {
        switch header.dot {
        case .live: return StatusTone.normal.color
        case .warning: return StatusTone.warning.color
        case .critical: return StatusTone.critical.color
        default: return .secondary
        }
    }

    private var textColor: Color {
        switch header.dot {
        case .warning, .critical: return dotColor.legibleText(in: scheme)
        default: return .secondary
        }
    }
}

struct MenuGPUPoolRow: View {
    let row: MenuGPURow
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        MenuRowFrame {
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 8) {
                    Text(row.label)
                        .font(.system(size: 13))
                        .frame(width: 48, alignment: .leading)
                    GPUPoolMeter(pool: row.pool, height: 5)
                        .frame(minWidth: 60)
                    (Text(row.idleFigure).foregroundColor(row.tone.color.legibleText(in: scheme))
                        + Text(" of \(row.total) idle").foregroundColor(.secondary))
                        .font(.system(size: 13).monospacedDigit())
                        .lineLimit(1)
                        .fixedSize()
                }
                if let caption = row.caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

struct MenuStorageWarningRow: View {
    let row: MenuStorageWarning
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        MenuRowFrame {
            HStack(spacing: 8) {
                Text(row.label)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 8)
                (Text(row.percentLabel).foregroundColor(row.tone.color.legibleText(in: scheme))
                    + Text(row.rest).foregroundColor(.secondary))
                    .font(.system(size: 13).monospacedDigit())
                    .lineLimit(1)
            }
        }
    }
}

struct MenuNoteRow: View {
    let note: MenuNote
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        MenuRowFrame {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if note.tone != .secondary {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(toneColor)
                }
                Text(note.text)
                    .font(.system(size: 11))
                    .foregroundStyle(note.tone == .secondary ? Color.secondary : toneColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var toneColor: Color {
        (note.tone == .critical ? StatusTone.critical.color : StatusTone.warning.color).legibleText(in: scheme)
    }
}
