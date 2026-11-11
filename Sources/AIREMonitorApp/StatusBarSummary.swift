import HPCCore
import AppKit

/// What the status item shows next to its glyph ("Show in Menu Bar").
enum StatusTitleMode: String, Codable, CaseIterable, Equatable {
    /// "7 running", or just the glyph while nothing runs. The app's own
    /// word, as in "2 running · 61 pending".
    case runningJobs
    /// Idle GPUs per live cluster: "A 4 · C 16+".
    case idleGPUs
    /// The glyph alone.
    case iconOnly

    var menuTitle: String {
        switch self {
        case .runningJobs: return "Running Jobs"
        case .idleGPUs: return "Idle GPUs"
        case .iconOnly: return "Icon Only"
        }
    }
}

/// Geometry of the menu-bar status item, shared by the controller (which
/// sizes the item) and `StatusBarSummary` (which picks the width).
enum StatusItemLayout {
    static let iconWidth: CGFloat = 18
    /// Between the glyph and the title.
    static let gap: CGFloat = 4
    /// Left and right insets together.
    static let padding: CGFloat = 10
    /// The caps keep the item from crowding other menu extras (on a notched
    /// display, items that do not fit simply disappear).
    static let maxRunningLength: CGFloat = 104
    static let maxGPULength: CGFloat = 130

    /// The menu bar's own size, at the clock's weight, with digits of one
    /// width so a changing count never shifts the text.
    @MainActor static let font = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.menuBarFont(ofSize: 0).pointSize,
        weight: .regular
    )

    /// Rendered width of `text` in the status item's font.
    @MainActor
    static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// The width the item reserves. It changes only when the class changes —
/// jobs appear or all end, 100 is crossed, the live clusters change in GPU
/// mode, or the user picks another mode — never on a refresh tick.
enum StatusWidthClass: Equatable {
    case glyph
    /// Room for "88 running" (1–99) or "888 running".
    case running(digits: Int)
    /// Room for the digit-stable GPU template, e.g. "A 88 · C 88+".
    case gpus(template: String)
}

/// What the status item shows, derived from the shared menu bar digest.
///
/// Job counts and idle GPUs come from LIVE clusters only. A cached or paused
/// snapshot (after a VPN drop, a sleep, a master expiry, or at launch before
/// the first probe) may describe jobs that ended hours ago, so it never
/// feeds the title; the tooltip names it with its time. The same goes for a
/// live cluster whose Slurm is not answering (`isDegraded`).
@MainActor
struct StatusBarSummary {
    typealias Measure = @MainActor (String) -> CGFloat

    let digest: MenuBarDigest
    let mode: StatusTitleMode
    /// "" when the item shows its glyph alone.
    let title: String
    /// `title` padded with figure spaces (U+2007, as wide as a digit) to its
    /// width class's template. The status bar button centres its glyph and
    /// title together, so an unpadded "7 running" in a slot sized for "88
    /// running" would move the glyph whenever the digit count changes.
    let displayTitle: String
    let widthClass: StatusWidthClass
    private let measure: Measure

    init(digest: MenuBarDigest, mode: StatusTitleMode = .runningJobs, measure: @escaping Measure = StatusItemLayout.textWidth) {
        self.digest = digest
        self.mode = mode
        self.measure = measure
        switch mode {
        case .runningJobs:
            let running = digest.runningCount
            if running > 0 {
                let digits = running >= 100 ? 3 : 2
                title = "\(running) running"
                displayTitle = title + String(repeating: Self.figureSpace, count: max(0, digits - String(running).count))
                widthClass = .running(digits: digits)
            } else {
                title = ""
                displayTitle = ""
                widthClass = .glyph
            }
        case .idleGPUs:
            let clusters = digest.live.filter { !$0.gpuPools.isEmpty }
            if clusters.isEmpty {
                title = ""
                displayTitle = ""
                widthClass = .glyph
            } else {
                title = clusters.map { Self.idleGPUText($0, template: false) }.joined(separator: " · ")
                displayTitle = clusters.map { Self.idleGPUText($0, template: false, padded: true) }.joined(separator: " · ")
                widthClass = .gpus(template: clusters.map { Self.idleGPUText($0, template: true) }.joined(separator: " · "))
            }
        case .iconOnly:
            title = ""
            displayTitle = ""
            widthClass = .glyph
        }
    }

    /// Nothing is live with Slurm answering: the glyph dims.
    var isDimmed: Bool { digest.isDimmed }

    /// Something only the user can fix: the glyph carries a "!" badge.
    var hasAttention: Bool { !digest.attention.isEmpty }

    /// The item's length: the system's square for the glyph alone, else the
    /// glyph, a gap and the class's template text within the cap.
    func reservedLength() -> CGFloat {
        let base = StatusItemLayout.iconWidth + StatusItemLayout.gap + StatusItemLayout.padding
        switch widthClass {
        case .glyph:
            return NSStatusItem.squareLength
        case .running(let digits):
            let template = String(repeating: "8", count: digits) + " running"
            return min(base + measure(template), StatusItemLayout.maxRunningLength)
        case .gpus(let template):
            return min(base + measure(template), StatusItemLayout.maxGPULength)
        }
    }

    /// "A 1" — the cluster's primary (largest) GPU pool, with "+" when
    /// another model also has idle GPUs. Models are never added together;
    /// the tooltip and the menu list every pool. The count is the pool's
    /// `idleFigure`: "A ?" while nothing is known idle only because node
    /// details are missing, as on the overview tile and the header chip —
    /// "A 0" would claim a full pool. A pool of unknown allocation is not
    /// one with idle GPUs, so it never earns the "+".
    ///
    /// The template reserves a "+" whenever the cluster has another model at
    /// all, so a second pool's idle count crossing zero never resizes the
    /// item; `padded` fills the visible title out to that template with
    /// figure spaces.
    private static func idleGPUText(_ cluster: MenuBarClusterDigest, template: Bool, padded: Bool = false) -> String {
        guard let primary = cluster.primaryGPUPool else {
            return cluster.profile.monogram
        }
        let othersIdle = cluster.gpuPools.dropFirst().contains { $0.pool.idle > 0 }
        let canHavePlus = cluster.gpuPools.count > 1
        let figure = primary.pool.idleFigure
        if template {
            let count = String(repeating: "8", count: max(figure.count, 2))
            return "\(cluster.profile.monogram) \(count)\(canHavePlus ? "+" : "")"
        }
        guard padded else {
            return "\(cluster.profile.monogram) \(figure)\(othersIdle ? "+" : "")"
        }
        let figurePad = String(repeating: figureSpace, count: max(0, 2 - figure.count))
        let plus = othersIdle ? "+" : (canHavePlus ? figureSpace : "")
        return "\(cluster.profile.monogram) \(figure)\(figurePad)\(plus)"
    }

    /// U+2007 FIGURE SPACE: as wide as a digit in a monospaced-digit font.
    static let figureSpace = "\u{2007}"

    // MARK: Tooltip and accessibility

    /// The headline, what needs a look, then one block per cluster and the
    /// shared home when it is under pressure. Deliberately free of relative
    /// ages: those would change the signature every minute and defeat the
    /// redraw skipping. Figures that are not live carry the clock time they
    /// were collected at.
    var tooltip: String {
        var lines = [headline]
        for item in digest.attention {
            lines.append("Needs a look: \(item.text)")
        }
        for cluster in digest.clusters {
            lines.append("\(cluster.displayName) — \(cluster.connectionText)")
            if let signIn = cluster.signInText {
                lines.append("  \(signIn)")
            }
            guard cluster.isEnabled, cluster.hasSnapshot else {
                continue
            }
            let asOf = cluster.asOfText.map { " (\($0))" } ?? (cluster.isDegraded ? " (not current)" : "")
            lines.append("  \(cluster.jobCountsText)\(asOf)")
            for pool in cluster.gpuPools {
                lines.append("  \(pool.summaryLine)")
            }
            let pressure = cluster.storage.compactMap(\.pressureText)
            if !pressure.isEmpty {
                lines.append("  " + pressure.joined(separator: ", "))
            }
        }
        if let home = digest.sharedHome, home.row.tone >= .warning, home.row.tone != .unavailable,
           let pressure = home.row.pressureText {
            lines.append("\(pressure) (\(home.sharedByText), counted once)")
        }
        return lines.joined(separator: "\n")
    }

    private var headline: String {
        if mode == .idleGPUs, !title.isEmpty {
            let parts = digest.live.filter { !$0.gpuPools.isEmpty }.map { cluster in
                let pools = cluster.gpuPools.map { "\($0.pool.idleFigure) of \($0.pool.total) \($0.pool.label)" }
                return "\(cluster.displayName) \(pools.joined(separator: ", "))"
            }
            return "Idle GPUs — \(parts.joined(separator: "; "))"
        }
        let running = digest.runningCount
        if running > 0 {
            return "\(running) job\(running == 1 ? "" : "s") running — \(runningBreakdown)"
        }
        if digest.live.isEmpty {
            return "Leeds HPC Monitor — \(digest.headerStatusLine)"
        }
        return "No jobs running — \(digest.headerStatusLine)"
    }

    var accessibilityLabel: String {
        var sentence: String
        let running = digest.runningCount
        if mode == .idleGPUs, !title.isEmpty {
            let parts = digest.live.filter { !$0.gpuPools.isEmpty }.map { cluster in
                "\(cluster.displayName) \(cluster.gpuPools.map(\.spokenIdleText).joined(separator: " and "))"
            }
            sentence = "idle GPUs: \(parts.joined(separator: ", "))"
        } else if running > 0 {
            sentence = "\(running) job\(running == 1 ? "" : "s") running, \(runningBreakdown)"
        } else if let busy = digest.busyCluster {
            sentence = busy.status.phase == .queued ? "waiting to sign in to \(busy.displayName)" : "signing in to \(busy.displayName)"
        } else if !digest.live.isEmpty {
            sentence = "\(digest.live.map(\.displayName).joined(separator: " and ")) live, no jobs running"
        } else {
            sentence = digest.headerStatusLine
        }
        if !digest.attention.isEmpty {
            sentence += "; needs a look: " + digest.attention.map(\.text).joined(separator: "; ")
        }
        return "Leeds HPC Monitor: \(sentence)"
    }

    /// The button is touched only when this changes.
    var signature: String {
        [
            displayTitle,
            "\(widthClass)",
            mode.rawValue,
            isDimmed ? "dim" : "lit",
            digest.attention.map(\.id).joined(separator: ","),
            tooltip,
            accessibilityLabel
        ].joined(separator: "|")
    }

    /// "AIRE 1, Calder 2": running jobs per live cluster, never one bare sum.
    private var runningBreakdown: String {
        digest.live
            .filter { !$0.runningJobs.isEmpty }
            .map { "\($0.displayName) \($0.runningJobs.count)" }
            .joined(separator: ", ")
    }
}

/// The status item's glyph: the app's rack emblem, monochrome in every
/// state (a template image, so AppKit draws it for light and dark menu bars,
/// the open state, Increase Contrast and Reduce Transparency), with a
/// knocked-out "!" badge when something needs a look. Its shape never
/// changes with the state.
enum StatusItemGlyph {
    static let size = NSSize(width: 18, height: 16)

    @MainActor private static var cache: [Bool: NSImage] = [:]

    @MainActor
    static func image(attention: Bool) -> NSImage {
        if let cached = cache[attention] {
            return cached
        }
        let symbol = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Leeds HPC Monitor")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        let badge = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .bold))
        let image = NSImage(size: size, flipped: false) { rect in
            if let symbol {
                let symbolSize = symbol.size
                let origin = NSPoint(
                    x: ((rect.width - symbolSize.width) / 2).rounded(),
                    y: ((rect.height - symbolSize.height) / 2).rounded()
                )
                symbol.draw(in: NSRect(origin: origin, size: symbolSize))
            }
            if attention, let badge, let context = NSGraphicsContext.current {
                let spot = NSRect(x: rect.maxX - 10, y: rect.minY - 1, width: 10, height: 10)
                context.compositingOperation = .destinationOut
                NSBezierPath(ovalIn: spot).fill()
                context.compositingOperation = .sourceOver
                badge.draw(in: spot.insetBy(dx: 1, dy: 1))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Leeds HPC Monitor"
        cache[attention] = image
        return image
    }
}

/// Fitting text into a fixed width.
enum TextFitting {
    /// Shortens `text` by dropping characters from the middle ("c2-mi…sync")
    /// until it fits `width`; "" when not even one character and the
    /// ellipsis fit.
    @MainActor
    static func middleTruncated(_ text: String, toFit width: CGFloat, measure: (String) -> CGFloat) -> String {
        guard measure(text) > width else {
            return text
        }
        let characters = Array(text)
        var keep = characters.count - 1
        while keep > 0 {
            let head = (keep + 1) / 2
            let tail = keep - head
            let candidate = String(characters.prefix(head)) + "…" + String(characters.suffix(tail))
            if measure(candidate) <= width {
                return candidate
            }
            keep -= 1
        }
        return ""
    }
}

/// Elapsed times and limits for the menu bar. squeue's "9:29:15" carries
/// seconds no menu keeps current (it changes only on each refresh), so the
/// menu uses compact forms: "45s", "23m", "9h 29m", "1d 04h"; limits "4h",
/// "12h", "2d", "30m".
enum StatusElapsedText {
    static func compact(_ raw: String) -> String? {
        let trimmed = raw.menuTrimmed
        guard !trimmed.isEmpty else {
            return nil
        }
        guard let seconds = slurmElapsedSeconds(trimmed) else {
            return trimmed
        }
        if seconds < 60 {
            return "\(seconds)s"
        }
        if seconds < 3600 {
            return "\(seconds / 60)m"
        }
        if seconds < 86_400 {
            return "\(seconds / 3600)h " + String(format: "%02dm", seconds % 3600 / 60)
        }
        return "\(seconds / 86_400)d " + String(format: "%02dh", seconds % 86_400 / 3600)
    }

    /// A time limit in its largest whole unit ("4h", "2d", "30m", "1d 12h");
    /// nil for UNLIMITED or anything unparseable, which then shows the
    /// elapsed time alone.
    static func compactLimit(_ raw: String) -> String? {
        let trimmed = raw.menuTrimmed
        guard !trimmed.isEmpty, trimmed.uppercased() != "UNLIMITED", trimmed.uppercased() != "INFINITE",
              let seconds = slurmElapsedSeconds(trimmed), seconds > 0 else {
            return nil
        }
        let days = seconds / 86_400
        let hours = seconds % 86_400 / 3600
        let minutes = seconds % 3600 / 60
        if days > 0 {
            return hours == 0 ? "\(days)d" : "\(days)d \(hours)h"
        }
        if hours > 0 {
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    /// "1 h 30 min" for VoiceOver.
    static func spoken(_ raw: String) -> String {
        guard let seconds = slurmElapsedSeconds(raw) else {
            return raw.menuTrimmed.isEmpty ? "an unknown time" : raw.menuTrimmed
        }
        return slurmDurationText(seconds: seconds)
    }
}
