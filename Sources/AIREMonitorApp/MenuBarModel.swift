import HPCCore
import SwiftUI

// The menu bar's model: everything the status item (StatusBarSummary) and
// its native menu (MenuBarMenuLayout, built by StatusMenuBuilder) show, as
// plain Equatable values built once per change from the cluster sessions.
// Both surfaces read the same digest, so a title like "7 running" and the
// menu beneath it can never disagree, and the rules here are unit-testable
// without AppKit.

// MARK: - Cluster status

/// The part of `ClusterPresentation` the menu bar needs, as a plain value:
/// the menu takes its wording, phase and single action from the same
/// mapping as the sidebar, overview and hero (so it can never offer Connect
/// while another surface says "Checking"), and digests can be built in tests
/// without a live session.
struct MenuBarClusterStatus: Equatable {
    let phase: ClusterPresentation.Phase
    let title: String
    let detail: String
    let tint: Color
    let showsProgress: Bool
    let primaryAction: ClusterPresentation.Action?
    let allowsRefresh: Bool

    init(_ presentation: ClusterPresentation) {
        phase = presentation.phase
        title = presentation.title
        detail = presentation.detail
        tint = presentation.tint
        showsProgress = presentation.showsProgress
        primaryAction = presentation.primaryAction
        allowsRefresh = presentation.allowsRefresh
    }

    init(
        phase: ClusterPresentation.Phase,
        title: String,
        detail: String = "",
        tint: Color = .gray,
        showsProgress: Bool = false,
        primaryAction: ClusterPresentation.Action? = nil,
        allowsRefresh: Bool = false
    ) {
        self.phase = phase
        self.title = title
        self.detail = detail
        self.tint = tint
        self.showsProgress = showsProgress
        self.primaryAction = primaryAction
        self.allowsRefresh = allowsRefresh
    }

    var isEnabled: Bool {
        if case .off = phase {
            return false
        }
        return true
    }

    var isLive: Bool { phase == .live }

    /// Something is in progress and no data is live yet for this cluster.
    var isBusy: Bool {
        switch phase {
        case .checking, .queued, .signingIn, .loadingFirstSnapshot:
            return true
        case .off, .notConnected, .live, .paused, .stale:
            return false
        }
    }

    /// Lower-case phrase for "AIRE live · Calder collecting first snapshot".
    var headerPhrase: String {
        switch phase {
        case .off: return "off"
        case .notConnected: return "not connected"
        case .checking: return "checking"
        case .queued: return "waiting to sign in"
        case .signingIn: return "signing in"
        case .loadingFirstSnapshot: return "collecting first snapshot"
        case .live: return "live"
        case .paused: return "paused"
        case .stale: return "cached"
        }
    }
}

// MARK: - Per-cluster digest

/// A running job together with its parsed start time, for picking the job
/// the status item names.
struct MenuBarRunningJob: Equatable {
    let job: Job
    let start: Date?
}

/// Value copy of everything the menu bar surfaces need from one cluster.
struct MenuBarClusterDigest: Identifiable, Equatable {
    let profile: ClusterProfile
    let status: MenuBarClusterStatus
    let isRefreshing: Bool
    let refreshIntervalText: String
    let errorMessage: String?
    /// "Slurm error on Calder: …" while Slurm fails over a healthy
    /// connection (`ClusterSession.schedulerIssue`); nil otherwise, and
    /// always nil unless the cluster is live.
    let schedulerIssue: String?
    let collectedAt: Date?
    let hasSnapshot: Bool
    /// Every job still in the queue, in the one display order all surfaces
    /// share (running first, then waiting on resources, dependencies, held).
    let jobs: [Job]
    /// Jobs holding nodes (running, completing, configuring).
    let runningJobs: [Job]
    /// Queued rows (requeued and held included). An array remainder is ONE
    /// row standing for many tasks; `queueCounts` counts the tasks.
    let pendingJobs: [Job]
    /// The queue as every other surface counts it (HPCCore
    /// `JobQueueCounts`): each task of an array remainder, and held jobs
    /// apart from pending ones — a held job will not start until released.
    let queueCounts: JobQueueCounts
    /// Suspended or otherwise neither running nor queued.
    let otherJobCount: Int
    /// Whether every one of `otherJobCount` is suspended.
    let otherJobsAreSuspended: Bool
    /// One entry per GPU model, largest first. Never summed across models.
    let gpuPools: [MenuBarGPUPool]
    /// This cluster's own spaces (scratch, flash, …) in display order. The
    /// shared /users home is excluded on purpose: it is one NFS quota mounted
    /// on every cluster and `MenuBarDigest.sharedHome` shows it once.
    let storage: [MenuBarStorageRow]
    /// The shared home as this cluster's snapshot reported it.
    let sharedHome: StorageSummary?
    /// The job this cluster would put in the menu bar title: most recent
    /// start time, then highest Slurm id. Ids are compared only within this
    /// cluster, never across clusters.
    let newestRunningJob: MenuBarRunningJob?
    /// When the live SSH session was signed in (its master's start), for
    /// the "session up 10 h 12 min" line; nil when not live or unknown.
    let sessionSince: Date?
    /// The session dropped on its own and has not come back (nil after a
    /// Disconnect, a route change or once live again).
    let drop: MenuBarDrop?
    /// The latest resource-use sample of each running job, by `Job.jobId`.
    let jobUsage: [String: JobUsageSummary]

    var id: ClusterID { profile.id }
    var displayName: String { profile.displayName }
    var isEnabled: Bool { status.isEnabled }
    var isLive: Bool { status.isLive }

    /// Connected, but Slurm is not answering. The session stays live (there
    /// is nothing to sign in again for), yet the sections that failed carry
    /// the previous jobs, nodes and partitions forward under a fresh
    /// `collected_at`: a job that ended during the outage still reads as
    /// running, with its elapsed time frozen. So none of it counts as current.
    var isDegraded: Bool { isLive && schedulerIssue != nil }

    /// Live and Slurm answering: the only figures the status item may show
    /// (job title, counts, idle GPUs) and the dropdown may colour as live.
    var hasCurrentFigures: Bool { isLive && schedulerIssue == nil }

    /// Lower-case phrase for the dropdown header line.
    var headerPhrase: String {
        isDegraded ? "Slurm not answering" : status.headerPhrase
    }

    /// The live session has been up long enough to suggest renewing
    /// (`SessionAge.renewSuggestedAfter`).
    func isAging(now: Date) -> Bool {
        guard isLive, let sessionSince else {
            return false
        }
        return now.timeIntervalSince(sessionSince) >= SessionAge.renewSuggestedAfter
    }

    /// The session's own record that its last sign-in failed (wrong
    /// password, Duo declined, …) — never just a failed refresh.
    let lastSignInFailed: Bool

    /// A sign-in that failed and has not been retried: nothing is live,
    /// nothing runs, and the cluster is not paused (Resume wins there).
    var signInFailed: Bool {
        isEnabled && !isLive && !status.isBusy && status.phase != .paused && lastSignInFailed && drop == nil
    }

    @MainActor
    init(session: ClusterSession, sessionSince: Date? = nil, drop: MenuBarDrop? = nil) {
        self.init(
            profile: session.profile,
            status: MenuBarClusterStatus(session.presentation),
            isRefreshing: session.isRefreshing,
            refreshIntervalText: session.refreshIntervalText,
            errorMessage: session.errorMessage,
            schedulerIssue: session.schedulerIssue,
            snapshot: session.snapshot,
            gpuFleet: session.gpuFleet,
            sessionSince: session.isLoggedIn ? sessionSince : nil,
            drop: session.droppedAt != nil && !session.isLoggedIn ? drop : nil,
            jobUsage: session.jobUsage,
            lastSignInFailed: session.signInFailed
        )
    }

    /// `gpuFleet` defaults to one built from the snapshot; sessions pass
    /// their per-snapshot cache. A cluster that is off contributes nothing:
    /// its last snapshot may be days old and none of it is shown.
    init(
        profile: ClusterProfile,
        status: MenuBarClusterStatus,
        isRefreshing: Bool = false,
        refreshIntervalText: String = "10s",
        errorMessage: String? = nil,
        schedulerIssue: String? = nil,
        snapshot: ClusterSnapshot?,
        gpuFleet: GPUFleet? = nil,
        sessionSince: Date? = nil,
        drop: MenuBarDrop? = nil,
        jobUsage: [String: JobUsageSummary] = [:],
        lastSignInFailed: Bool = false
    ) {
        self.profile = profile
        self.lastSignInFailed = lastSignInFailed
        self.sessionSince = status.isLive ? sessionSince : nil
        self.drop = status.isLive || !status.isEnabled ? nil : drop
        self.status = status
        self.isRefreshing = isRefreshing
        self.refreshIntervalText = refreshIntervalText
        self.errorMessage = errorMessage?.menuTrimmed.menuNilIfEmpty
        self.schedulerIssue = status.isLive ? schedulerIssue?.menuTrimmed.menuNilIfEmpty : nil

        let snapshot = status.isEnabled ? snapshot : nil
        hasSnapshot = snapshot != nil
        collectedAt = snapshot.flatMap { SlurmTimestamp.parse($0.collectedAt) }

        let queued = (snapshot?.jobs ?? [])
            .filter { !$0.jobState.isFinished }
            .sorted(by: jobDisplayOrder)
        jobs = queued
        let running = queued.filter { $0.jobState.occupiesNodes }
        let pending = queued.filter { $0.jobState.isPending }
        runningJobs = running
        pendingJobs = pending
        let runningIDs = Set(running.map(\.jobId))
        self.jobUsage = status.isLive ? jobUsage.filter { runningIDs.contains($0.key) } : [:]
        queueCounts = JobQueueCounts(jobs: queued)
        let others = queued.filter { !$0.jobState.occupiesNodes && !$0.jobState.isPending }
        otherJobCount = others.count
        otherJobsAreSuspended = others.allSatisfy { $0.jobState == .suspended }

        if let snapshot {
            let fleet = gpuFleet ?? GPUFleet(nodes: snapshot.nodes)
            gpuPools = fleet.pools.map(MenuBarGPUPool.init(pool:))
        } else {
            gpuPools = []
        }

        let spaces = snapshot?.sortedStorage ?? []
        storage = spaces
            .filter { !$0.kind.isSharedAcrossClusters }
            .map(MenuBarStorageRow.init(storage:))
        sharedHome = spaces.first { $0.kind.isSharedAcrossClusters }
        newestRunningJob = Self.newestRunning(in: running)
    }

    private static func newestRunning(in jobs: [Job]) -> MenuBarRunningJob? {
        jobs
            .map { MenuBarRunningJob(job: $0, start: $0.startTime.flatMap(SlurmTimestamp.parse)) }
            .max { lhs, rhs in
                switch (lhs.start, rhs.start) {
                case let (left?, right?) where left != right:
                    return left < right
                case (nil, .some):
                    return true
                case (.some, nil):
                    return false
                default:
                    return lhs.job.jobId.localizedStandardCompare(rhs.job.jobId) == .orderedAscending
                }
            }
    }

    /// The primary pool (largest), e.g. Calder's H200s beside a few L40s.
    var primaryGPUPool: MenuBarGPUPool? { gpuPools.first }

    /// Queued jobs waiting to start (array tasks counted individually);
    /// held jobs are not among them.
    var pendingTaskCount: Int { queueCounts.pending }
    /// Held jobs (array tasks counted individually).
    var heldTaskCount: Int { queueCounts.held }

    /// Whether the dropdown's count line names pending jobs: always, except
    /// a zero next to held or other jobs ("2 running · 11 held"), as
    /// `JobQueueCounts.summary` words it.
    var showsPendingCount: Bool {
        pendingTaskCount > 0 || (heldTaskCount == 0 && queueCounts.other == 0)
    }

    /// "9 running · 1 pending · 11 held" (+ "· 1 suspended"): the overview's
    /// and the sidebar's wording for the same queue. Queued array tasks are
    /// counted individually, as squeue would list them.
    var jobCountsText: String {
        queueCounts.summary(otherLabel: otherJobsAreSuspended ? "suspended" : "other")
    }

    /// The line under the first `visible` job rows: "+16 more on AIRE", or
    /// "+37 more jobs in 16 rows on AIRE" once a hidden array remainder
    /// stands for several queued tasks — so the rows shown and the hidden
    /// count add up to the count line above them. Nil when nothing is
    /// hidden. `compact` drops the cluster name.
    func hiddenJobsText(afterFirst visible: Int, compact: Bool = false) -> String? {
        let hidden = jobs.dropFirst(max(visible, 0))
        guard !hidden.isEmpty else {
            return nil
        }
        let hiddenJobs = hidden.reduce(0) { $0 + $1.taskMultiplicity }
        let count = hiddenJobs == hidden.count
            ? "+\(hiddenJobs) more"
            : "+\(hiddenJobs) more jobs in \(hidden.count) row\(hidden.count == 1 ? "" : "s")"
        return compact ? count : "\(count) on \(displayName)"
    }

    /// Sign-in text that names the cluster ("Calder: Waiting for Duo
    /// approval on your phone"), or nil when this cluster is not signing in.
    /// The progress line comes from ClusterPresentation, which already drops
    /// the login script's "(Calder)" suffix; a suffix naming another host
    /// (the shared rash jump host) is kept, since it says which push it is.
    var signInText: String? {
        switch status.phase {
        case .signingIn:
            let detail = status.detail.menuTrimmed
            if detail.lowercased().hasPrefix(displayName.lowercased()) {
                return detail
            }
            return "\(displayName): \(detail.isEmpty ? "signing in — watch for a Duo push" : detail)"
        case .queued:
            return "\(displayName): waiting for the previous sign-in to finish"
        default:
            return nil
        }
    }

    /// One-line connection description for the tooltip.
    var connectionText: String {
        switch status.phase {
        case .off:
            return "monitoring off"
        case .notConnected:
            return "not connected"
        case .checking:
            return "checking for an open SSH session"
        case .queued:
            return "waiting to sign in"
        case .signingIn:
            return "signing in"
        case .loadingFirstSnapshot:
            return "signed in, collecting the first snapshot"
        case .live:
            return isDegraded
                ? "connected, but Slurm is not answering — previous figures shown, retrying every \(refreshIntervalText)"
                : "live, refreshes every \(refreshIntervalText)"
        case .paused:
            return "paused"
        case .stale:
            return status.allowsRefresh
                ? "showing cached data, retrying every \(refreshIntervalText)"
                : "showing cached data — sign in for live updates"
        }
    }

    /// "as of 14:05" for figures that are not live; nil while live.
    var asOfText: String? {
        guard !isLive, let collectedAt else {
            return nil
        }
        return "as of \(MenuBarDates.clockText(collectedAt))"
    }
}

// MARK: - GPU pools

/// One GPU model's pool on one cluster, as the menu shows it. Built from
/// HPCCore's `GPUFleet`, the app's single GPU accounting: "idle" means
/// startable now (an idle GPU on a node whose CPUs are all taken is
/// "stranded", not free), and L40 and H200 are never added together.
struct MenuBarGPUPool: Equatable, Identifiable {
    let pool: GPUPool

    var id: String { pool.id }

    /// "H200 GPUs", or "GPUs" when gres names no model.
    var title: String {
        pool.model.map { "\($0) GPUs" } ?? "GPUs"
    }

    /// HPCCore's `GPUPool.idleTone`, the rule the overview tile and the
    /// cluster header chip use for the same pool: green while a GPU can
    /// start a job now, orange (never red) when the pool is known to be
    /// full, grey while nothing can start there (every node out of service)
    /// or while idle is unknown. The meter itself always shows the pool's
    /// make-up (`GPUPoolMeter`), so the tone colours only the figure.
    var tone: StatusTone {
        pool.idleTone
    }

    /// "1 of 84 idle" — the headline every surface leads with (overview
    /// tile, header chip, status item), "? of 84 idle" while nothing is
    /// known idle only because allocation is unknown
    /// (`GPUPool.idleIsUnknown`): "0 idle" would claim a full pool for GPUs
    /// nobody reported on.
    var valueText: String {
        "\(pool.idleFigure) of \(pool.total) idle"
    }

    /// The line under the meter: every GPU that is not idle, by why
    /// (`GPUPool.capacityCaption`) — "34 in use · 7 stranded · 15
    /// unavailable" — so the stranded and unavailable GPUs that the meter
    /// draws in grey are also in plain text, as on the overview tile.
    var detailText: String {
        pool.capacityCaption
    }

    /// `valueText` and `detailText` for VoiceOver, which would read "?" as
    /// "question mark".
    var spokenValueText: String {
        let idle = pool.idleIsUnknown ? pool.idleSpokenSummary : valueText
        return "\(idle); \(detailText)"
    }

    /// "0 idle L40S GPUs" for the status item's VoiceOver label, or "idle
    /// L40S GPUs unknown" while `idleIsUnknown`.
    var spokenIdleText: String {
        pool.idleIsUnknown ? "idle \(title) unknown" : "\(pool.idle) idle \(title)"
    }

    /// Tooltip line: "L40S: 0 of 3 idle · 2 in use · 1 stranded".
    var summaryLine: String {
        "\(pool.label): \(valueText) · \(detailText)"
    }

    func helpText(clusterName: String) -> String {
        var parts: [String]
        if pool.idleIsUnknown {
            parts = [
                "\(clusterName) \(title): idle GPUs unknown — node details are missing, so the allocation "
                    + "of \(pool.unknown) of \(pool.total) is unknown (\(pool.allocated) known to be in use)"
            ]
        } else {
            parts = [
                "\(clusterName) \(title): \(pool.allocated) of \(pool.total) in use, "
                    + "\(pool.idle) idle and startable now"
            ]
        }
        if pool.stranded > 0 {
            parts.append("\(pool.stranded) idle on nodes whose CPUs are all taken (no job can start there)")
        }
        if pool.unavailable > 0 {
            parts.append("\(pool.unavailable) on unavailable nodes (drained, down or in maintenance)")
        }
        if pool.unknown > 0, !pool.idleIsUnknown {
            parts.append("\(pool.unknown) with unknown allocation")
        }
        let nodes = pool.nodeCount == 1 ? "1 node" : "\(pool.nodeCount) nodes"
        let partitions = pool.partitions.isEmpty ? "" : " in \(pool.partitions.joined(separator: ", "))"
        parts.append("\(nodes)\(partitions)")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Storage

/// Presentation of one storage space, shared by the dropdown rows and the
/// status item tooltip so both report the same dominant pressure.
struct MenuBarStorageRow: Identifiable, Equatable {
    let id: String
    let kind: StorageKind
    let label: String
    /// max(space, files) as 0...1; nil when the collector had no numbers.
    let riskFraction: Double?
    /// Dominant pressure alone: "42%", "95% files", "over quota", "n/a".
    let percentLabel: String
    /// Dropdown value column: the percentage plus free space when known.
    /// Too long for the column? The row falls back to `percentLabel`.
    let valueLabel: String
    let detail: String
    /// `StorageSummary.usageTone`, the Storage tab's own verdict: 75 %
    /// warning, 90 % or over quota critical, on max(space, files).
    let tone: StatusTone

    init(storage: StorageSummary) {
        id = storage.label
        kind = storage.kind
        label = storage.label.capitalized

        // The Storage tab's own figures (HPCCore), clamped to the bar:
        // space, files against the hard limit (else the soft quota), and
        // whichever of the two is closer to its limit.
        let unit = { (percent: Double) in min(max(percent / 100, 0), 1) }
        let spaceFraction = storage.usedPercent.map(unit)
        let fileFraction = storage.fileUsedPercent.map(unit)
        riskFraction = storage.pressurePercent.map(unit)

        // Show whichever pressure dominates, qualified so the row never
        // appears to disagree with its bar (e.g. "95% files" vs 40% space).
        if storage.overQuota == true {
            percentLabel = "over quota"
        } else if storage.fileCountDominates, let fileFraction {
            percentLabel = "\(Int((fileFraction * 100).rounded()))% files"
        } else if let spaceFraction {
            percentLabel = "\(Int((spaceFraction * 100).rounded()))%"
        } else {
            percentLabel = "n/a"
        }
        if let available = storage.availableGB, riskFraction != nil, storage.overQuota != true {
            valueLabel = "\(percentLabel) · \(formatGB(available)) free"
        } else {
            valueLabel = percentLabel
        }

        if riskFraction == nil, storage.unavailableReason != nil {
            detail = storage.path.isEmpty ? storage.unavailableCaption : "\(storage.unavailableCaption) · \(storage.path)"
        } else {
            var parts = [
                "\(formatGB(storage.availableGB)) free",
                "\(formatGB(storage.quotaGB)) quota",
                "\(formatGB(storage.limitGB)) limit"
            ]
            if let fileFraction {
                parts.append("files \(Int((fileFraction * 100).rounded()))%")
            }
            if !storage.path.isEmpty {
                parts.append(storage.path)
            }
            detail = parts.joined(separator: " · ")
        }

        tone = storage.usageTone
    }

    /// "Scratch 42%" / "Flash 91% files" for the tooltip; nil when unknown.
    var pressureText: String? {
        guard riskFraction != nil else {
            return nil
        }
        return "\(label) \(percentLabel)"
    }
}

/// The /users home quota: one NFS export shared by every cluster, so it is
/// listed once - never once per cluster, and never summed.
struct MenuBarSharedHome: Equatable {
    let row: MenuBarStorageRow
    /// Cluster whose snapshot supplied the figure (the freshest one).
    let source: ClusterProfile
    /// Clusters that mount this home.
    let sharedBy: [ClusterProfile]

    /// "shared by AIRE and Calder".
    var sharedByText: String {
        let names = sharedBy.map(\.displayName)
        switch names.count {
        case 0:
            return "shared by every cluster"
        case 1:
            return "used by \(names[0])"
        case 2:
            return "shared by \(names[0]) and \(names[1])"
        default:
            return "shared by all \(names.count) clusters"
        }
    }

    var caption: String {
        let text = sharedByText
        return text.prefix(1).uppercased() + text.dropFirst() + " — one quota, counted once"
    }
}

// MARK: - Health

/// Combined connection health of the enabled clusters; drives the status
/// item tint and the dropdown header dot.
enum MenuBarHealth: Equatable {
    /// No cluster is enabled.
    case off
    case allLive
    /// Some clusters live, others not (yet).
    case partial
    /// Nothing live yet, but a check, sign-in or first collection is running.
    case connecting
    /// Nothing live; only cached or paused figures are on show.
    case stale
    /// Nothing live, nothing shown, and a cluster reports an error.
    case failing
    case offline
}

// MARK: - Drops and attention

/// A cluster whose session dropped on its own, as the menu words it.
struct MenuBarDrop: Equatable {
    let at: Date
    let note: SessionDropNote
}

/// Something that earns the status item its badge.
struct MenuBarAttention: Equatable, Identifiable {
    enum Kind: String, Equatable {
        case dropped
        case signInFailed
        case slurmDown
    }

    let cluster: ClusterID
    let kind: Kind
    /// "Calder session dropped at 14:05", for the tooltip and VoiceOver.
    let text: String

    var id: String { "\(cluster.rawValue).\(kind.rawValue)" }
}

// MARK: - Digest

/// Everything the menu bar shows, for all clusters at once.
struct MenuBarDigest: Equatable {
    /// Every cluster in catalog order, disabled ones included (the dropdown
    /// offers to turn them on). Status totals use `live` or `enabled` only.
    let clusters: [MenuBarClusterDigest]
    let sharedHome: MenuBarSharedHome?
    /// App-level problems, e.g. Connect pressed with no saved password.
    let appErrorMessage: String?
    /// When the shared rash jump session was signed in, on the rash route.
    let jumpSince: Date?
    /// "Renew All Sessions…" would do something now (mirrors
    /// `AppModel.renewConfirmation() != nil`).
    let canRenew: Bool

    @MainActor
    init(model: AppModel) {
        let clusterNames = Set(model.sessions.map(\.id.rawValue))
        let jump = model.sharingReport.sessions.filter { !clusterNames.contains($0.name) }.compactMap(\.since).min()
        self.init(
            clusters: model.sessions.map { session in
                MenuBarClusterDigest(
                    session: session,
                    sessionSince: model.sharingReport.session(named: session.id.rawValue)?.since,
                    drop: model.lastDrops[session.id].map { drop in
                        MenuBarDrop(
                            at: drop.at,
                            note: SessionDropNote.make(
                                drop: drop,
                                state: model.autoReconnect.state(of: session.id),
                                reconnectAutomatically: model.reconnectAutomatically,
                                isSigningIn: session.isLoggingIn || session.isLoginQueued
                            )
                        )
                    }
                )
            },
            appErrorMessage: model.errorMessage,
            jumpSince: jump,
            canRenew: model.renewConfirmation() != nil
        )
    }

    @MainActor
    init(sessions: [ClusterSession]) {
        self.init(clusters: sessions.map { MenuBarClusterDigest(session: $0) })
    }

    init(
        clusters: [MenuBarClusterDigest],
        appErrorMessage: String? = nil,
        jumpSince: Date? = nil,
        canRenew: Bool = false
    ) {
        self.clusters = clusters
        self.appErrorMessage = appErrorMessage?.menuTrimmed.menuNilIfEmpty
        self.jumpSince = clusters.contains(where: \.isLive) ? jumpSince : nil
        self.canRenew = canRenew
        sharedHome = Self.freshestSharedHome(in: clusters)
    }

    /// Nothing is live with Slurm answering: the status item dims.
    var isDimmed: Bool {
        live.isEmpty
    }

    /// What earns the status item its "!" badge: something only the user
    /// can fix. Deliberately rare — not connected, off, paused, cached, an
    /// ageing session, storage or GPU verdicts never badge; the menu shows
    /// those.
    var attention: [MenuBarAttention] {
        enabled.compactMap { cluster in
            if cluster.isDegraded {
                return MenuBarAttention(cluster: cluster.id, kind: .slurmDown, text: "\(cluster.displayName): Slurm not answering")
            }
            if let drop = cluster.drop, !cluster.status.isBusy {
                return MenuBarAttention(
                    cluster: cluster.id,
                    kind: .dropped,
                    text: "\(cluster.displayName) session dropped at \(drop.note.when)"
                )
            }
            if cluster.signInFailed {
                return MenuBarAttention(cluster: cluster.id, kind: .signInFailed, text: "\(cluster.displayName): sign-in failed")
            }
            return nil
        }
    }

    /// The oldest live leg's sign-in, the rash jump session included: what
    /// "renew soon" is judged on.
    var oldestLiveSince: Date? {
        // Every connected cluster, Slurm answering or not: the session
        // ages either way.
        (clusters.filter(\.isLive).compactMap(\.sessionSince) + [jumpSince].compactMap { $0 }).min()
    }

    var enabled: [MenuBarClusterDigest] {
        clusters.filter(\.isEnabled)
    }

    /// Clusters whose figures are current. Job counts, elapsed times and
    /// idle GPUs in the status item come from these only: a cached or
    /// paused snapshot may describe jobs that finished hours ago, and so may
    /// a live cluster whose Slurm is not answering (`isDegraded`).
    var live: [MenuBarClusterDigest] {
        clusters.filter(\.hasCurrentFigures)
    }

    var runningCount: Int {
        live.reduce(0) { $0 + $1.runningJobs.count }
    }

    var isAnyRefreshing: Bool {
        enabled.contains(where: \.isRefreshing)
    }

    /// Whether "Refresh all" could do anything: some cluster allows a
    /// refresh (per ClusterPresentation) and is not already refreshing.
    var canRefreshAny: Bool {
        enabled.contains { $0.status.allowsRefresh && !$0.isRefreshing }
    }

    var health: MenuBarHealth {
        let active = enabled
        if active.isEmpty {
            return .off
        }
        // A live cluster whose Slurm is failing is not "all live": the
        // icon turns amber, as it does while only some clusters are live.
        if active.allSatisfy(\.hasCurrentFigures) {
            return .allLive
        }
        if active.contains(where: \.isLive) {
            return .partial
        }
        if active.contains(where: { $0.status.isBusy }) {
            return .connecting
        }
        if active.contains(where: { $0.status.phase == .stale || $0.status.phase == .paused }) {
            return .stale
        }
        if active.contains(where: { $0.errorMessage != nil }) {
            return .failing
        }
        return .offline
    }

    /// The cluster whose sign-in is currently in progress (or next in line).
    var busyCluster: MenuBarClusterDigest? {
        enabled.first { $0.status.phase == .signingIn } ?? enabled.first { $0.status.phase == .queued }
    }

    /// The running job to name in the status item, from live clusters only.
    /// Most recent start time wins across clusters (times are absolute, so
    /// that comparison is meaningful); Slurm job ids are not comparable
    /// across clusters and are never used here. No start time anywhere:
    /// first cluster in catalog order.
    var primaryRunningJob: (cluster: MenuBarClusterDigest, job: Job)? {
        var best: (cluster: MenuBarClusterDigest, candidate: MenuBarRunningJob)?
        for cluster in live {
            guard let candidate = cluster.newestRunningJob else {
                continue
            }
            guard let current = best else {
                best = (cluster, candidate)
                continue
            }
            if let start = candidate.start, current.candidate.start.map({ start > $0 }) ?? true {
                best = (cluster, candidate)
            }
        }
        return best.map { ($0.cluster, $0.candidate.job) }
    }

    /// "AIRE live · Calder collecting first snapshot", or the sign-in in
    /// progress.
    var headerStatusLine: String {
        if let signIn = busyCluster?.signInText {
            return signIn
        }
        let active = enabled
        switch health {
        case .off:
            return "Monitoring is off for every cluster"
        case .allLive:
            let names = active.map(\.displayName)
            return names.count == 2 ? "\(names[0]) and \(names[1]) live" : "\(names.joined(separator: ", ")) live"
        default:
            return active
                .map { "\($0.displayName) \($0.headerPhrase)" }
                .joined(separator: " · ")
        }
    }

    /// Picks one enabled cluster's report of the shared home: live ones
    /// first, then the most recently collected; ties go to catalog order.
    /// Disabled clusters contribute no snapshot data at all.
    private static func freshestSharedHome(in clusters: [MenuBarClusterDigest]) -> MenuBarSharedHome? {
        let candidates = clusters.filter(\.isEnabled).compactMap { cluster in
            cluster.sharedHome.map { (cluster: cluster, storage: $0) }
        }
        func rank(_ cluster: MenuBarClusterDigest) -> (Int, Date) {
            (cluster.isLive ? 1 : 0, cluster.collectedAt ?? .distantPast)
        }
        var best: (cluster: MenuBarClusterDigest, storage: StorageSummary)?
        for candidate in candidates {
            guard let current = best else {
                best = candidate
                continue
            }
            if rank(candidate.cluster) > rank(current.cluster) {
                best = candidate
            }
        }
        guard let best else {
            return nil
        }
        let sharedBy = clusters
            .filter { cluster in
                cluster.profile.storage.contains { StorageKind(label: $0.label).isSharedAcrossClusters }
            }
            .map(\.profile)
        return MenuBarSharedHome(
            row: MenuBarStorageRow(storage: best.storage),
            source: best.cluster.profile,
            sharedBy: sharedBy
        )
    }
}

// MARK: - Dates

/// Clock text for the menu bar. Timestamps are parsed by HPCCore's
/// `SlurmTimestamp.parse` directly (zone-less Slurm times in the clusters'
/// zone), so ages and start times read the same as on every other surface.
enum MenuBarDates {
    /// "14:05" today, "12 Oct 14:05" on another day. Absolute on purpose:
    /// unlike a relative age it does not change every second, so the status
    /// item's tooltip signature stays stable between refreshes.
    static func clockText(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

// MARK: - Helpers

extension String {
    var menuTrimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var menuNilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
