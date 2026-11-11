import HPCCore
import Foundation

// The status item's menu as data: what rows it has, in which order, with
// what text and which command, built from one `MenuBarDigest`. Pure and
// AppKit-free, so every state is unit-tested; `StatusMenuBuilder` turns the
// entries into native NSMenuItems (actions, submenus) and a few hosted
// SwiftUI rows (cluster headers, GPU meters, warnings), keyed by `id` so an
// open menu is updated in place.

// MARK: - Entries

/// What a native item does when chosen. Every command runs after the menu
/// has closed. None of them sends a Duo push on its own except Connect (a
/// plain sign-in that reuses an open session); Renew asks first.
enum MenuCommand: Equatable {
    case openJob(ClusterID, String)
    case openCluster(ClusterID)
    case connect(ClusterID)
    case cancelSignIn(ClusterID)
    case resume(ClusterID)
    case turnOn(ClusterID)
    case renewAll
    case openDashboard
    case openWidget
    case setTitleMode(StatusTitleMode)
    case quit
}

/// A submenu filled when it opens.
enum MenuSubmenu: Equatable {
    /// Every queued job of a cluster, then "Open … in Dashboard".
    case jobs(ClusterID)
    /// "Show in Menu Bar": Running Jobs, Idle GPUs, Icon Only.
    case titleMode
}

/// A native menu item.
struct MenuItemModel: Equatable {
    let id: String
    /// Plain title: what type-select matches.
    let title: String
    /// Right-aligned figure after a tab ("1h 08m of 4h").
    var trailing: String?
    /// The end of `title` that must survive truncation (" · 8248307_0"):
    /// only the part before it is shortened.
    var protectedSuffix: String?
    var toolTip: String?
    var indent = 0
    var command: MenuCommand?
    var submenu: MenuSubmenu?
    var isEnabled = true
    /// A checkmark (the title-mode submenu).
    var isChecked = false
    /// A section header ("Running", "Pending") in a submenu.
    var isSectionHeader = false
}

/// A cluster's first row: badge, name, and its state.
struct MenuClusterHeader: Equatable {
    enum Dot: Equatable {
        case live
        case warning
        case critical
        case idle
        case none
        case busy
    }

    let cluster: ClusterID
    let statusText: String
    let dot: Dot
    let accessibilityLabel: String
}

/// A short line of text under a header, or above the footer.
struct MenuNote: Equatable {
    enum Tone: Equatable {
        case secondary
        case warning
        case critical
    }

    let text: String
    var tone: Tone = .secondary
}

/// One GPU pool: model, meter, "16 of 56 idle", and why when none is.
struct MenuGPURow: Equatable {
    let pool: GPUPool
    var label: String { pool.label }
    var idleFigure: String { pool.idleFigure }
    var total: Int { pool.total }
    var tone: StatusTone { pool.idleTone }
    /// Only when nothing is idle (or idle is unknown): explain zeros, not
    /// positives.
    var caption: String? {
        pool.idle == 0 || pool.idleIsUnknown ? pool.capacityCaption : nil
    }

    var spokenText: String {
        let idle = pool.idleIsUnknown ? pool.idleSpokenSummary : "\(pool.idleFigure) of \(pool.total) idle"
        return "\(pool.label) GPUs: \(idle); \(pool.capacityCaption)"
    }
}

/// A storage space at warning or worse.
struct MenuStorageWarning: Equatable {
    let label: String
    let percentLabel: String
    /// " · 492 GiB free", or "" when unknown.
    let rest: String
    let tone: StatusTone
    let detail: String

    init(row: MenuBarStorageRow, label: String? = nil, detail: String? = nil) {
        self.label = label ?? row.label
        percentLabel = row.percentLabel
        rest = row.valueLabel.hasPrefix(row.percentLabel) ? String(row.valueLabel.dropFirst(row.percentLabel.count)) : ""
        tone = row.tone
        self.detail = detail ?? row.detail
    }
}

enum MenuEntry: Equatable, Identifiable {
    case clusterHeader(MenuClusterHeader)
    case note(id: String, MenuNote)
    case gpuPool(id: String, MenuGPURow)
    case storage(id: String, MenuStorageWarning)
    case item(MenuItemModel)
    case separator(id: String)

    var id: String {
        switch self {
        case .clusterHeader(let header): return "\(header.cluster.rawValue).header"
        case .note(let id, _), .gpuPool(let id, _), .storage(let id, _), .separator(let id): return id
        case .item(let item): return item.id
        }
    }

    /// Hosted SwiftUI rows are informational: disabled, never highlighted,
    /// skipped by the arrow keys.
    var isHosted: Bool {
        switch self {
        case .clusterHeader, .note, .gpuPool, .storage: return true
        case .item, .separator: return false
        }
    }
}

// MARK: - Job lines

/// One job as a menu row: "train-resnet50 · 8248307_0", then "1h 08m of 4h".
struct MenuJobLine: Equatable {
    let title: String
    /// " · 8248307_0" when the id is part of the title (a name clash).
    let idSuffix: String?
    let trailing: String
    /// Its GPUs are partly or mostly idle (`JobUsageSummary.gpuVerdict`).
    let flagged: Bool
    let toolTip: String

    /// `isLive` false (cached, paused, Slurm not answering): the state, not
    /// an elapsed time frozen at the snapshot. `clash`: another queued job
    /// of this cluster has the same name, so the id goes in the title.
    init(job: Job, usage: JobUsageSummary?, isLive: Bool, clash: Bool) {
        let name = job.name.menuTrimmed.isEmpty ? "Job \(job.displayJobID)" : job.name.menuTrimmed
        let state = job.jobState
        if job.isArrayRemainder {
            let tasks = job.taskMultiplicity
            idSuffix = " (\(tasks) task\(tasks == 1 ? "" : "s"))"
        } else {
            idSuffix = clash ? " · \(job.displayJobID)" : nil
        }
        title = name + (idSuffix ?? "")

        let verdict = usage?.gpuVerdict
        switch verdict {
        case .someIdle?, .mostlyIdle?:
            flagged = isLive && state.occupiesNodes
        default:
            flagged = false
        }

        if state.occupiesNodes, isLive {
            let elapsed = StatusElapsedText.compact(job.elapsed) ?? "0m"
            let limit = StatusElapsedText.compactLimit(job.timeLimit)
            let timing = limit.map { "\(elapsed) of \($0)" } ?? elapsed
            trailing = flagged ? "⚠\u{FE0E} \(timing)" : timing
        } else if let reason = job.pendingReason {
            switch reason.code {
            case "JobHeldUser": trailing = "Held by you"
            case "JobHeldAdmin": trailing = "Held by admin"
            case "JobHoldMaxRequeue": trailing = "Requeue limit"
            default: trailing = reason.code
            }
        } else {
            trailing = state.label
        }

        var lines = [Self.idLine(job)]
        if let usage {
            if let headline = usage.gpuHeadline {
                lines.append(headline)
            }
            lines.append(usage.verdictText)
        }
        lines.append(menuJobResources(job))
        toolTip = lines.joined(separator: "\n")
    }

    /// "8248307_0 · gpu · gpu003 — 1:08:18 of 4:00:00".
    private static func idLine(_ job: Job) -> String {
        var identifier = job.displayJobID
        if job.isArrayRemainder {
            let tasks = job.taskMultiplicity
            identifier += tasks == 1 ? " (1 task)" : " (\(tasks) tasks)"
        }
        let partition = job.partition.menuTrimmed.isEmpty ? missingValuePlaceholder : job.partition
        var line = [identifier, partition, menuJobLocation(job)].joined(separator: " · ")
        if job.jobState.occupiesNodes, !job.elapsed.menuTrimmed.isEmpty {
            let limit = job.timeLimit.menuTrimmed.isEmpty ? missingValuePlaceholder : job.timeLimit
            line += " — \(job.elapsed) of \(limit)"
        }
        return line
    }
}

// MARK: - Layout

enum MenuBarMenuLayout {
    /// Running jobs listed inline under a live cluster; the rest are in its
    /// jobs submenu.
    static let inlineJobLimit = 3
    /// Job rows in a jobs submenu before "+N more".
    static let submenuJobLimit = 20

    static func build(digest: MenuBarDigest, now: Date = Date()) -> [MenuEntry] {
        var entries: [MenuEntry] = []
        for cluster in digest.clusters {
            entries += section(for: cluster, now: now)
            entries.append(.separator(id: "\(cluster.id.rawValue).separator"))
        }
        if let home = digest.sharedHome, home.row.tone >= .warning, home.row.tone != .unavailable {
            entries.append(.storage(id: "home.storage", MenuStorageWarning(
                row: home.row,
                label: "Home (shared)",
                detail: home.caption + "\n" + home.row.detail
            )))
        }
        if let message = digest.appErrorMessage {
            entries.append(.note(id: "app.error", MenuNote(text: firstLine(message), tone: .critical)))
        }
        if let oldest = digest.oldestLiveSince, now.timeIntervalSince(oldest) >= SessionAge.renewSuggestedAfter {
            entries.append(.note(id: "renew.note", MenuNote(
                text: "Signed in \(SessionAge.text(now.timeIntervalSince(oldest))) ago — sessions have ended about 12 h after the VPN began",
                tone: .warning
            )))
        }
        if entries.last.map({ if case .separator = $0 { return false } else { return true } }) == true {
            entries.append(.separator(id: "footer.separator.top"))
        }
        entries += footer(digest: digest, now: now)
        return entries
    }

    // MARK: Cluster sections

    private static func section(for cluster: MenuBarClusterDigest, now: Date) -> [MenuEntry] {
        let id = cluster.id
        let key = id.rawValue
        let name = cluster.displayName
        func header(_ text: String, _ dot: MenuClusterHeader.Dot, spoken: String? = nil) -> MenuEntry {
            .clusterHeader(MenuClusterHeader(
                cluster: id,
                statusText: text,
                dot: dot,
                accessibilityLabel: "\(name), \(spoken ?? text)"
            ))
        }
        func action(_ title: String, _ command: MenuCommand, _ suffix: String, toolTip: String? = nil) -> MenuEntry {
            .item(MenuItemModel(id: "\(key).\(suffix)", title: title, toolTip: toolTip, command: command))
        }
        let connect = action(
            "Connect to \(name)",
            .connect(id),
            "connect",
            toolTip: "Sign in to \(name): one Duo push, none if a session is still open."
        )

        if !cluster.isEnabled {
            return [header("Off", .none), action("Turn On \(name)", .turnOn(id), "turnOn")]
        }

        switch cluster.status.phase {
        case .checking:
            return [header("Checking…", .busy, spoken: "checking for an open session")]
        case .loadingFirstSnapshot:
            return [header("Collecting first snapshot…", .busy)]
        case .queued, .signingIn:
            var entries = [header(cluster.status.phase == .queued ? "Waiting to sign in" : "Signing in…", .busy)]
            let detail = cluster.status.detail.menuTrimmed
            if !detail.isEmpty {
                entries.append(.note(id: "\(key).note", MenuNote(text: firstLine(detail))))
            }
            entries.append(action("Cancel \(name) Sign-In", .cancelSignIn(id), "cancelSignIn"))
            return entries
        case .live:
            return liveSection(for: cluster, now: now)
        default:
            break
        }

        if let drop = cluster.drop {
            var entries = [
                header("Dropped \(drop.note.when)", .critical, spoken: "session dropped at \(drop.note.when)"),
                .note(id: "\(key).note", MenuNote(text: drop.note.menuText))
            ]
            // A sign-in attempted since the drop that failed says why.
            if let message = cluster.errorMessage {
                entries.append(.note(id: "\(key).error", MenuNote(text: firstLine(message), tone: .critical)))
            }
            entries.append(connect)
            return entries
        }
        if cluster.status.phase == .paused {
            var entries = [header("Paused", .idle), action("Resume \(name)", .resume(id), "resume")]
            if let message = cluster.errorMessage {
                entries.append(.note(id: "\(key).note", MenuNote(text: firstLine(message), tone: .warning)))
            }
            if let counts = asOfCountsRow(cluster) {
                entries.append(counts)
            }
            return entries
        }
        if cluster.signInFailed {
            return [
                header("Sign-in failed", .critical),
                .note(id: "\(key).note", MenuNote(text: firstLine(cluster.errorMessage ?? "The last sign-in did not complete."), tone: .critical)),
                connect
            ]
        }
        // Any other error (a manual refresh that failed) is a note, never
        // a badge.
        let errorNote: MenuEntry? = cluster.errorMessage.map {
            .note(id: "\(key).note", MenuNote(text: firstLine($0), tone: .warning))
        }
        switch cluster.status.phase {
        case .stale:
            let when = cluster.collectedAt.map { MenuBarDates.clockText($0, now: now) }
            var entries = [header(when.map { "Cached · \($0)" } ?? "Cached", .idle)]
            if let errorNote {
                entries.append(errorNote)
            }
            if cluster.status.primaryAction == .connect || cluster.status.primaryAction == nil {
                entries.append(connect)
            }
            if let counts = asOfCountsRow(cluster) {
                entries.append(counts)
            }
            return entries
        default:
            return [header("Not connected", .idle)] + [errorNote].compactMap { $0 } + [connect]
        }
    }

    private static func liveSection(for cluster: MenuBarClusterDigest, now: Date) -> [MenuEntry] {
        let id = cluster.id
        let key = id.rawValue
        let name = cluster.displayName
        if cluster.isDegraded {
            return [
                .clusterHeader(MenuClusterHeader(
                    cluster: id,
                    statusText: "Slurm not answering",
                    dot: .warning,
                    accessibilityLabel: "\(name), connected but Slurm is not answering"
                )),
                .note(id: "\(key).note", MenuNote(text: "Previous figures shown · retrying every \(cluster.refreshIntervalText)")),
                .item(MenuItemModel(
                    id: "\(key).counts",
                    title: "\(countsText(cluster)) (not current)",
                    submenu: .jobs(id)
                ))
            ]
        }

        let aging = cluster.isAging(now: now)
        let upText = cluster.sessionSince.map { "up \(SessionAge.text(now.timeIntervalSince($0)))" } ?? "Live"
        var entries: [MenuEntry] = [
            .clusterHeader(MenuClusterHeader(
                cluster: id,
                statusText: upText,
                dot: aging ? .warning : .live,
                accessibilityLabel: "\(name), live" + (cluster.sessionSince.map {
                    ", signed in \(SessionAge.text(now.timeIntervalSince($0))) ago"
                } ?? "")
            )),
            .item(MenuItemModel(
                id: "\(key).counts",
                title: countsText(cluster),
                toolTip: "Every \(name) job, and Open \(name) in Dashboard",
                submenu: .jobs(id)
            ))
        ]

        let names = nameCounts(cluster.jobs)
        for job in inlineRunningJobs(cluster) {
            let line = MenuJobLine(job: job, usage: cluster.jobUsage[job.jobId], isLive: true, clash: (names[job.name] ?? 0) > 1)
            entries.append(.item(MenuItemModel(
                id: "\(key).job.\(job.jobId)",
                title: line.title,
                trailing: line.trailing,
                protectedSuffix: line.idSuffix,
                toolTip: line.toolTip,
                indent: 1,
                command: .openJob(id, job.jobId)
            )))
        }

        for pool in cluster.gpuPools {
            entries.append(.gpuPool(id: "\(key).gpu.\(pool.id)", MenuGPURow(pool: pool.pool)))
        }
        for row in cluster.storage where row.tone >= .warning && row.tone != .unavailable {
            entries.append(.storage(id: "\(key).storage.\(row.id)", MenuStorageWarning(row: row)))
        }
        if let message = cluster.errorMessage {
            entries.append(.note(id: "\(key).note", MenuNote(text: firstLine(message), tone: .warning)))
        }
        return entries
    }

    /// Up to `inlineJobLimit` running jobs: those whose GPUs sit partly or
    /// mostly idle first (they need a look), shown in display order.
    static func inlineRunningJobs(_ cluster: MenuBarClusterDigest) -> [Job] {
        let running = cluster.runningJobs
        guard running.count > inlineJobLimit else {
            return running
        }
        let flagged = running.filter { job in
            switch cluster.jobUsage[job.jobId]?.gpuVerdict {
            case .someIdle?, .mostlyIdle?: return true
            default: return false
            }
        }
        var chosen = Set(flagged.prefix(inlineJobLimit).map(\.jobId))
        for job in running where chosen.count < inlineJobLimit {
            chosen.insert(job.jobId)
        }
        return running.filter { chosen.contains($0.jobId) }
    }

    private static func countsText(_ cluster: MenuBarClusterDigest) -> String {
        cluster.jobs.isEmpty ? "No jobs in the queue" : cluster.jobCountsText
    }

    /// "As of 14:05: 5 running · 17 pending" for a cached or paused
    /// snapshot; nil without one.
    private static func asOfCountsRow(_ cluster: MenuBarClusterDigest) -> MenuEntry? {
        guard cluster.hasSnapshot else {
            return nil
        }
        let when = cluster.collectedAt.map { "As of \(MenuBarDates.clockText($0)): " } ?? "Last seen: "
        return .item(MenuItemModel(id: "\(cluster.id.rawValue).counts", title: when + countsText(cluster), submenu: .jobs(cluster.id)))
    }

    // MARK: Jobs submenu

    static func submenu(for id: ClusterID, digest: MenuBarDigest) -> [MenuEntry] {
        guard let cluster = digest.clusters.first(where: { $0.id == id }) else {
            return []
        }
        let key = id.rawValue
        let live = cluster.hasCurrentFigures
        let names = nameCounts(cluster.jobs)
        var entries: [MenuEntry] = []
        var section: String?
        for job in cluster.jobs.prefix(submenuJobLimit) {
            let group = job.jobState.occupiesNodes ? "Running" : (job.isHeld ? "Held" : (job.jobState.isPending ? "Pending" : "Other"))
            if group != section {
                entries.append(.item(MenuItemModel(id: "\(key).section.\(group)", title: group, isEnabled: false, isSectionHeader: true)))
                section = group
            }
            let line = MenuJobLine(job: job, usage: cluster.jobUsage[job.jobId], isLive: live, clash: (names[job.name] ?? 0) > 1)
            entries.append(.item(MenuItemModel(
                id: "\(key).all.\(job.jobId)",
                title: line.title,
                trailing: line.trailing,
                protectedSuffix: line.idSuffix,
                toolTip: line.toolTip,
                command: .openJob(id, job.jobId)
            )))
        }
        if cluster.jobs.isEmpty {
            entries.append(.item(MenuItemModel(id: "\(key).all.none", title: "No jobs in the queue", isEnabled: false)))
        }
        if let hidden = cluster.hiddenJobsText(afterFirst: submenuJobLimit, compact: true) {
            entries.append(.item(MenuItemModel(id: "\(key).all.more", title: hidden, isEnabled: false)))
        }
        entries.append(.separator(id: "\(key).all.separator"))
        entries.append(.item(MenuItemModel(
            id: "\(key).all.open",
            title: "Open \(cluster.displayName) in Dashboard",
            command: .openCluster(id)
        )))
        return entries
    }

    static func titleModeSubmenu(current: StatusTitleMode) -> [MenuEntry] {
        StatusTitleMode.allCases.map { mode in
            .item(MenuItemModel(
                id: "titleMode.\(mode.rawValue)",
                title: mode.menuTitle,
                command: .setTitleMode(mode),
                isChecked: mode == current
            ))
        }
    }

    // MARK: Footer

    private static func footer(digest: MenuBarDigest, now: Date) -> [MenuEntry] {
        var legs: [String] = []
        if let jump = digest.jumpSince {
            legs.append("rash up \(SessionAge.text(now.timeIntervalSince(jump)))")
        }
        for cluster in digest.clusters where cluster.isLive {
            if let since = cluster.sessionSince {
                legs.append("\(cluster.displayName) up \(SessionAge.text(now.timeIntervalSince(since)))")
            }
        }
        let renewHelp = (legs.isEmpty ? "" : legs.joined(separator: " · ") + ". ")
            + "Signs in to each session again from scratch: one Duo push each, one at a time; open terminals there close. Asks first."
        return [
            .item(MenuItemModel(id: "footer.dashboard", title: "Open Dashboard", command: .openDashboard)),
            .item(MenuItemModel(id: "footer.widget", title: "Open Desktop Widget", command: .openWidget)),
            .item(MenuItemModel(
                id: "footer.renew",
                title: "Renew All Sessions…",
                toolTip: renewHelp,
                command: .renewAll,
                isEnabled: digest.canRenew
            )),
            .item(MenuItemModel(id: "footer.titleMode", title: "Show in Menu Bar", submenu: .titleMode)),
            .separator(id: "footer.separator"),
            .item(MenuItemModel(id: "footer.quit", title: "Quit Leeds HPC Monitor", command: .quit))
        ]
    }

    // MARK: Helpers

    private static func nameCounts(_ jobs: [Job]) -> [String: Int] {
        jobs.reduce(into: [:]) { counts, job in
            counts[job.name, default: 0] += 1
        }
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.menuTrimmed
    }
}

// MARK: - Job tooltip helpers

func menuJobLocation(_ job: Job) -> String {
    let value = menuFirstNonEmpty(job.nodeList, job.batchHost, job.reasonOrNodeList, job.nodes)
    return job.jobState.isPending ? "reason \(value)" : value
}

func menuJobResources(_ job: Job) -> String {
    let parts = [
        menuKeyValue("req", job.reqTres),
        menuKeyValue("alloc", job.allocTres),
        menuKeyValue("per node", job.tresPerNode)
    ].compactMap { $0 }

    if !parts.isEmpty {
        return parts.joined(separator: "\n")
    }

    let cpu = job.numCpus.map { "cpu=\($0)" }
    let tasks = job.numTasks.map { "tasks=\($0)" }
    return [cpu, tasks].compactMap { $0 }.joined(separator: " ").menuNilIfEmpty ?? "Resources not reported"
}

private func menuKeyValue(_ key: String, _ value: String?) -> String? {
    guard let value = value?.menuTrimmed, !value.isEmpty else {
        return nil
    }
    return "\(key): \(menuCompactTres(value))"
}

private func menuCompactTres(_ value: String) -> String {
    value.replacingOccurrences(of: "billing=", with: "bill=")
        .replacingOccurrences(of: "gres/gpu=", with: "gpu=")
}

private func menuFirstNonEmpty(_ values: String?...) -> String {
    for value in values {
        if let trimmed = value?.menuTrimmed, !trimmed.isEmpty {
            return trimmed
        }
    }
    return missingValuePlaceholder
}
