import HPCCore
import AppKit

/// Geometry of the menu-bar status item, shared by the controller (which
/// sizes the item) and `StatusBarSummary` (which fits the title into it).
enum StatusItemLayout {
    static let iconWidth: CGFloat = 20
    static let padding: CGFloat = 16
    static let minLength: CGFloat = 56
    /// The cap keeps the item from crowding other menu extras (on a notched
    /// display, items that do not fit simply disappear).
    static let maxLength: CGFloat = 160

    /// Room for the title once the icon and padding are reserved.
    static var maxTextWidth: CGFloat { maxLength - iconWidth - padding }

    @MainActor static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)

    /// Rendered width of `text` in the status item's font.
    @MainActor
    static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// What the status item shows, derived from the shared menu bar digest.
///
/// Job counts, elapsed times and idle GPUs come from LIVE clusters only. A
/// cached or paused snapshot (after a VPN drop, a sleep, a master expiry, or
/// at launch before the first probe) may describe jobs that ended hours
/// ago, so it never feeds the title; it is named, with its time, in the
/// tooltip instead. The same goes for a live cluster whose Slurm is not
/// answering (`MenuBarClusterDigest.isDegraded`): its job list is only
/// carried forward from the last good refresh.
@MainActor
struct StatusBarSummary {
    typealias Measure = @MainActor (String) -> CGFloat

    let digest: MenuBarDigest
    let mode: Mode
    let title: String
    /// `title` with every changing digit replaced by a fixed-width
    /// placeholder, so the reserved width only changes when the job or the
    /// cluster set changes — not on every refresh.
    let widthTemplateTitle: String
    private let measure: Measure

    enum Mode {
        /// Exactly one running job across all live clusters.
        case singleJob(cluster: MenuBarClusterDigest, job: Job)
        /// Several running jobs (on one or more live clusters).
        case multipleJobs(count: Int)
        /// No running jobs: idle GPUs of each live cluster with GPU nodes.
        case idleGPUs([MenuBarClusterDigest])
        case idle(IdleState)
    }

    enum IdleState: Equatable {
        case off
        case signingIn
        case checking
        case syncing
        case ready
        /// Connected, but Slurm is not answering, so nothing is current.
        case slurmError
        case paused
        case cached
        case offline

        var title: String {
            switch self {
            case .off: return "Off"
            case .signingIn: return "Signing in"
            case .checking: return "Checking"
            case .syncing: return "Syncing"
            case .ready: return "Ready"
            case .slurmError: return "Slurm error"
            case .paused: return "Paused"
            case .cached: return "Cached"
            case .offline: return "Offline"
            }
        }
    }

    init(digest: MenuBarDigest, measure: @escaping Measure = StatusItemLayout.textWidth) {
        self.digest = digest
        self.measure = measure
        let live = digest.live
        let running = digest.runningCount
        let mode: Mode
        if running == 1, let primary = digest.primaryRunningJob {
            mode = .singleJob(cluster: primary.cluster, job: primary.job)
        } else if running > 1 {
            mode = .multipleJobs(count: running)
        } else {
            let withGPUs = live.filter { !$0.gpuPools.isEmpty }
            mode = withGPUs.isEmpty ? .idle(Self.idleState(for: digest)) : .idleGPUs(withGPUs)
        }
        self.mode = mode

        switch mode {
        case .singleJob(let cluster, let job):
            let titles = Self.singleJobTitles(cluster: cluster, job: job, measure: measure)
            title = titles.title
            widthTemplateTitle = titles.template
        case .multipleJobs(let count):
            title = "\(count) jobs"
            widthTemplateTitle = title
        case .idleGPUs(let clusters):
            title = clusters.map { Self.idleGPUText($0, template: false) }.joined(separator: " · ")
            widthTemplateTitle = clusters.map { Self.idleGPUText($0, template: true) }.joined(separator: " · ")
        case .idle(let state):
            title = state.title
            widthTemplateTitle = title
        }
    }

    /// What to say when no live cluster has jobs or GPUs, most pressing
    /// first.
    private static func idleState(for digest: MenuBarDigest) -> IdleState {
        let phases = digest.enabled.map(\.status.phase)
        if phases.isEmpty {
            return .off
        }
        if phases.contains(where: { $0 == .signingIn || $0 == .queued }) {
            return .signingIn
        }
        if phases.contains(.checking) {
            return .checking
        }
        if phases.contains(.loadingFirstSnapshot) {
            return .syncing
        }
        if digest.enabled.contains(where: \.hasCurrentFigures) {
            return .ready
        }
        if digest.enabled.contains(where: \.isDegraded) {
            return .slurmError
        }
        if phases.contains(.stale) {
            return .cached
        }
        if phases.contains(.paused) {
            return .paused
        }
        return .offline
    }

    // MARK: Title pieces

    /// "A · c2-mi…sync 9h 29m". The name is fitted by measured width with
    /// middle truncation, so the monogram and — above all — the elapsed
    /// time, the part that changes, are never cut off by the item's cap.
    private static func singleJobTitles(
        cluster: MenuBarClusterDigest,
        job: Job,
        measure: Measure
    ) -> (title: String, template: String) {
        let monogram = cluster.profile.monogram
        let prefix = "\(monogram) · "
        let elapsed = StatusElapsedText.compact(job.elapsed)
        let suffix = elapsed.map { " \($0)" } ?? ""
        let suffixTemplate = elapsed.map { " \(digitTemplate($0))" } ?? ""
        let budget = StatusItemLayout.maxTextWidth - measure(prefix) - measure(suffixTemplate)
        let name = middleTruncated(jobTitleName(job), toFit: budget, measure: measure)
        guard !name.isEmpty else {
            // Not even "a…" fits: keep what matters, cluster and time.
            return ("\(monogram)\(suffix)", "\(monogram)\(suffixTemplate)")
        }
        return (prefix + name + suffix, prefix + name + suffixTemplate)
    }

    /// "A 1" — the cluster's primary (largest) GPU pool, with "+" when
    /// another model also has idle GPUs. Models are never added together;
    /// the tooltip and the dropdown list every pool. The count is the
    /// pool's `idleFigure`: "A ?" while nothing is known idle only because
    /// node details are missing, as on the overview tile and the header
    /// chip — "A 0" would claim a full pool. A pool of unknown allocation
    /// is not one with idle GPUs, so it never earns the "+".
    private static func idleGPUText(_ cluster: MenuBarClusterDigest, template: Bool) -> String {
        guard let primary = cluster.primaryGPUPool else {
            return cluster.profile.monogram
        }
        let othersIdle = cluster.gpuPools.dropFirst().contains { $0.pool.idle > 0 }
        let figure = primary.pool.idleFigure
        let count = template
            ? String(repeating: "8", count: max(figure.count, 2))
            : figure
        return "\(cluster.profile.monogram) \(count)\(othersIdle ? "+" : "")"
    }

    private static func jobTitleName(_ job: Job) -> String {
        let name = job.name.menuTrimmed
        // A runaway name cannot fit anyway; bound the fitting loop.
        return String((name.isEmpty ? "job" : name).prefix(64))
    }

    private static func jobDisplayName(_ job: Job) -> String {
        let name = job.name.menuTrimmed
        return name.isEmpty ? "Job \(job.displayJobID)" : name
    }

    /// Shortens `text` by dropping characters from the middle ("c2-mi…sync")
    /// until it fits `width`; "" when not even one character and the
    /// ellipsis fit.
    static func middleTruncated(_ text: String, toFit width: CGFloat, measure: Measure) -> String {
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

    private static func digitTemplate(_ text: String) -> String {
        String(text.map { $0.isNumber ? "8" : $0 })
    }

    // MARK: Item appearance

    /// Width to reserve for the item: icon, template title and padding,
    /// within the layout's bounds.
    func reservedLength(hasIcon: Bool) -> CGFloat {
        let iconWidth = hasIcon ? StatusItemLayout.iconWidth : 0
        let length = iconWidth + measure(widthTemplateTitle) + StatusItemLayout.padding
        return min(max(length, StatusItemLayout.minLength), StatusItemLayout.maxLength)
    }

    var iconName: String {
        switch mode {
        case .singleJob, .multipleJobs:
            return "play.circle.fill"
        case .idleGPUs:
            return "bolt.horizontal.circle.fill"
        case .idle(.off):
            return "pause.circle"
        case .idle(.paused):
            return "pause.circle.fill"
        case .idle(.signingIn), .idle(.checking), .idle(.syncing):
            return "arrow.triangle.2.circlepath"
        case .idle(.ready):
            return "server.rack"
        case .idle(.slurmError):
            return "exclamationmark.triangle"
        case .idle(.cached):
            return "clock.arrow.circlepath"
        case .idle(.offline):
            return "wifi.slash"
        }
    }

    /// Combined connection health: green when every enabled cluster is
    /// live, orange while only some are (or a check, sign-in or first
    /// collection runs), red when nothing is live or shown and a cluster
    /// reports an error, dimmed when only cached figures exist or simply
    /// offline. nil (template image) when monitoring is off everywhere, so
    /// the icon blends in.
    var tint: NSColor? {
        switch digest.health {
        case .off: return nil
        case .allLive: return .systemGreen
        case .partial, .connecting: return .systemOrange
        case .failing: return .systemRed
        case .stale, .offline: return .secondaryLabelColor
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

    // MARK: Tooltip and accessibility

    /// One block per cluster, then the shared home quota once. Deliberately
    /// free of relative ages: those would change the signature every second
    /// and defeat the redraw skipping. Figures that are not live carry the
    /// clock time they were collected at.
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
        if let home = digest.sharedHome, let pressure = home.row.pressureText {
            lines.append("\(pressure) (\(home.sharedByText), counted once)")
        }
        return lines.joined(separator: "\n")
    }

    var accessibilityLabel: String {
        switch mode {
        case .singleJob(let cluster, let job):
            return "\(Self.jobDisplayName(job)) running on \(cluster.displayName) for \(StatusElapsedText.spoken(job.elapsed))"
        case .multipleJobs(let count):
            return "\(count) running jobs: \(runningBreakdown)"
        case .idleGPUs(let clusters):
            let parts = clusters.map { cluster in
                let pools = cluster.gpuPools.map(\.spokenIdleText)
                return "\(cluster.displayName) \(pools.joined(separator: " and "))"
            }
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

    /// "AIRE 1, Calder 2": running jobs per live cluster, never one bare sum.
    private var runningBreakdown: String {
        digest.live
            .filter { !$0.runningJobs.isEmpty }
            .map { "\($0.displayName) \($0.runningJobs.count)" }
            .joined(separator: ", ")
    }
}

/// Elapsed time for the status item. squeue's "9:29:15" carries seconds the
/// title cannot keep current (it changes only on each refresh) and costs
/// width the job name needs, so the title uses a compact form: "45s",
/// "23m", "9h 29m", "1d 04h".
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

    /// "1 h 30 min" for VoiceOver.
    static func spoken(_ raw: String) -> String {
        guard let seconds = slurmElapsedSeconds(raw) else {
            return raw.menuTrimmed.isEmpty ? "an unknown time" : raw.menuTrimmed
        }
        return slurmDurationText(seconds: seconds)
    }
}
