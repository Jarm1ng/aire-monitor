import HPCCore
import Foundation

// What the overview page derives from the sessions, kept apart from the
// views so it can be unit-tested. Two rules run through all of it:
// - Capacity from different clusters is never added together: an L40S and
//   an H200 are different pools, and the /users home quota is one NFS
//   export every cluster reports. (The user's own job counts may be summed —
//   they are the same person's work.)
// - A cluster without a snapshot is named as missing, never counted as zero.

// MARK: - Inputs

/// The slice of one session the overview reads. `init(session:)` builds it
/// from the live session; tests build it directly.
struct OverviewClusterInput {
    let profile: ClusterProfile
    let isEnabled: Bool
    let phase: ClusterPresentation.Phase
    let snapshot: ClusterSnapshot?
    let fleet: GPUFleet
    let errorMessage: String?
    /// Slurm failing over a healthy connection ("Slurm error on Calder: …").
    let schedulerIssue: String?
    /// The last failed refresh (automatic ones included), until a success.
    let refreshFailure: RefreshFailure?

    init(
        profile: ClusterProfile,
        isEnabled: Bool = true,
        phase: ClusterPresentation.Phase,
        snapshot: ClusterSnapshot?,
        fleet: GPUFleet? = nil,
        errorMessage: String? = nil,
        schedulerIssue: String? = nil,
        refreshFailure: RefreshFailure? = nil
    ) {
        self.profile = profile
        self.isEnabled = isEnabled
        self.phase = phase
        self.snapshot = snapshot
        self.fleet = fleet ?? GPUFleet(nodes: snapshot?.nodes ?? [])
        self.errorMessage = errorMessage
        self.schedulerIssue = schedulerIssue
        self.refreshFailure = refreshFailure
    }

    @MainActor
    init(session: ClusterSession) {
        self.init(
            profile: session.profile,
            isEnabled: session.isEnabled,
            phase: session.presentation.phase,
            snapshot: session.snapshot,
            // Cached on the session per snapshot; never rebuilt per render.
            fleet: session.gpuFleet,
            errorMessage: session.errorMessage,
            schedulerIssue: session.schedulerIssue,
            refreshFailure: session.lastRefreshFailure
        )
    }

    var isLive: Bool { phase == .live }
}

// MARK: - Digest

/// Everything the page needs across clusters, computed once per render in a
/// single pass. Per-cluster headline figures are NOT computed here: each
/// card builds its own `OverviewClusterStats` once, so nothing is derived
/// twice.
struct OverviewDigest {
    let clusterCount: Int
    let liveCount: Int
    let signingInCount: Int
    /// Enabled clusters that have a snapshot (live or cached), in catalog order.
    let reporting: [OverviewClusterReport]
    /// Enabled clusters with no snapshot yet.
    let missing: [OverviewMissingCluster]
    /// Clusters the user switched off. Their cached data is not shown.
    let disabled: [ClusterProfile]
    /// Jobs from every reporting cluster, in the shared display order.
    let jobs: [OverviewJobEntry]
    /// The user's jobs across reporting clusters (array remainders count
    /// every queued task).
    let counts: JobQueueCounts
    /// One line per cluster with something that needs the user's attention.
    let attention: [OverviewAttentionLine]

    @MainActor
    init(sessions: [ClusterSession]) {
        self.init(clusters: sessions.map(OverviewClusterInput.init(session:)))
    }

    init(clusters: [OverviewClusterInput]) {
        var live = 0
        var signingIn = 0
        var reporting: [OverviewClusterReport] = []
        var missing: [OverviewMissingCluster] = []
        var disabled: [ClusterProfile] = []
        var jobsByCluster: [[OverviewJobEntry]] = []
        var attention: [OverviewAttentionLine] = []
        var counts = JobQueueCounts()

        for (order, cluster) in clusters.enumerated() {
            switch cluster.phase {
            case .live:
                live += 1
            case .signingIn, .queued:
                signingIn += 1
            default:
                break
            }
            guard cluster.isEnabled else {
                disabled.append(cluster.profile)
                continue
            }
            guard let snapshot = cluster.snapshot else {
                missing.append(OverviewMissingCluster(profile: cluster.profile, phase: cluster.phase))
                if let error = Self.nonEmpty(cluster.errorMessage) {
                    attention.append(OverviewAttentionLine(
                        profile: cluster.profile,
                        items: [OverviewAttention.errorItem(error, refreshFailure: cluster.refreshFailure, isLive: cluster.isLive)]
                    ))
                } else if let failure = cluster.refreshFailure, failure.kind == .configuration,
                          let item = OverviewAttention.refreshFailureItem(failure, isLive: cluster.isLive) {
                    // A setup problem stops every refresh before the first
                    // snapshot; "not connected" alone would hide why.
                    attention.append(OverviewAttentionLine(profile: cluster.profile, items: [item]))
                }
                continue
            }
            let clusterCounts = JobQueueCounts(jobs: snapshot.jobs)
            counts.running += clusterCounts.running
            counts.pending += clusterCounts.pending
            counts.held += clusterCounts.held
            counts.other += clusterCounts.other
            reporting.append(
                OverviewClusterReport(
                    profile: cluster.profile,
                    collectedAt: snapshot.collectedAt,
                    isLive: cluster.isLive,
                    counts: clusterCounts
                )
            )
            jobsByCluster.append(snapshot.jobs.map { job in
                OverviewJobEntry(
                    profile: cluster.profile,
                    clusterOrder: order,
                    job: job,
                    isFromLiveSession: cluster.isLive
                )
            })
            let items = OverviewAttention.items(
                snapshot: snapshot,
                fleet: cluster.fleet,
                counts: clusterCounts,
                errorMessage: cluster.errorMessage,
                schedulerIssue: cluster.schedulerIssue,
                refreshFailure: cluster.refreshFailure,
                isLive: cluster.isLive
            )
            if !items.isEmpty {
                attention.append(OverviewAttentionLine(profile: cluster.profile, items: items))
            }
        }
        let jobs = OverviewJobEntry.merged(jobsByCluster)

        clusterCount = clusters.count
        liveCount = live
        signingInCount = signingIn
        self.reporting = reporting
        self.missing = missing
        self.disabled = disabled
        self.jobs = jobs
        self.counts = counts
        self.attention = attention
    }

    /// Ages further apart than this are spelled out per cluster: a live
    /// cluster next to an hour-old cache must not read "updated just now".
    /// One maximum backoff interval covers ordinary timer skew.
    static let ageSpreadThreshold: TimeInterval = HPCDefaults.maximumRefreshInterval

    /// "2 clusters · 2 live · updated 12 s ago", or with diverging ages
    /// "2 clusters · 1 live · AIRE just now · Calder 1 h ago". The single
    /// age is the OLDEST snapshot, so it never flatters a stale cluster.
    func summary(now: Date) -> String {
        var parts = [clusterCount == 1 ? "1 cluster" : "\(clusterCount) clusters"]
        parts.append(liveCount == 0 ? "none live" : "\(liveCount) live")
        if signingInCount > 0 {
            parts.append("\(signingInCount) signing in")
        }
        if !disabled.isEmpty {
            parts.append("\(disabled.count) off")
        }
        let dated = reporting.compactMap { report in
            SlurmTimestamp.parse(report.collectedAt).map { (report.profile, $0) }
        }
        if dated.isEmpty {
            parts.append(reporting.isEmpty ? "no data yet" : "age unknown")
        } else {
            let dates = dated.map(\.1)
            let oldest = dates.min() ?? now
            let newest = dates.max() ?? now
            if dated.count > 1, newest.timeIntervalSince(oldest) > Self.ageSpreadThreshold {
                for (profile, date) in dated {
                    parts.append("\(profile.displayName) \(SlurmTimestamp.ageText(from: date, now: now))")
                }
            } else {
                parts.append("updated \(SlurmTimestamp.ageText(from: oldest, now: now))")
            }
        }
        return parts.joined(separator: " · ")
    }

    var jobsSubtitle: String {
        guard !reporting.isEmpty else {
            return "no snapshot yet"
        }
        let total = counts.total == 1 ? "1 job" : "\(counts.total) jobs"
        return "\(total) · \(counts.summary)"
    }

    /// Some row stands for several jobs (a queued array remainder), so the
    /// list has fewer rows than the header and the cluster tags count.
    var rowsStandForMoreJobs: Bool {
        counts.total != jobs.count
    }

    /// The combined list's expand / collapse button. The list is capped by
    /// rows, while the header counts every queued array task as a job, so
    /// once those differ the button counts rows and names the job total
    /// ("Show all 9 rows (65 jobs)") instead of contradicting the header.
    func jobListToggleTitle(showingAll: Bool, limit: Int) -> String {
        guard rowsStandForMoreJobs else {
            return showingAll ? "Show the first \(limit) jobs" : "Show all \(jobs.count) jobs"
        }
        if showingAll {
            return "Show the first \(limit) rows"
        }
        return "Show all \(jobs.count) rows (\(counts.total == 1 ? "1 job" : "\(counts.total) jobs"))"
    }

    /// Explains an empty combined queue without overstating it: clusters
    /// that are not reporting are named as unknown, not as empty.
    var emptyQueueDetail: String {
        let reportingNames = SessionActionConfirmation.join(reporting.map(\.profile.displayName))
        var detail = "Nothing is queued or running for you on \(reportingNames)."
        // A signed-in cluster whose first snapshot is still on its way is
        // "loading", not "not connected": calling it disconnected would
        // invite a needless second sign-in and Duo push.
        let loading = missing.filter { $0.phase == .loadingFirstSnapshot || $0.phase == .checking }
        let unreachable = missing.filter { $0.phase != .loadingFirstSnapshot && $0.phase != .checking }
        if !loading.isEmpty {
            let names = SessionActionConfirmation.join(loading.map(\.profile.displayName))
            detail += " \(names) \(loading.count == 1 ? "is" : "are") still loading."
        }
        if !unreachable.isEmpty {
            let names = SessionActionConfirmation.join(unreachable.map(\.profile.displayName))
            detail += " \(names) \(unreachable.count == 1 ? "is" : "are") not connected, so \(unreachable.count == 1 ? "its" : "their") queue is unknown."
        }
        return detail
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }
}

/// An enabled cluster that has no snapshot yet.
struct OverviewMissingCluster: Identifiable {
    let profile: ClusterProfile
    let phase: ClusterPresentation.Phase

    var id: ClusterID { profile.id }

    var tagText: String {
        switch phase {
        case .queued, .signingIn:
            return "signing in"
        case .loadingFirstSnapshot:
            return "loading"
        case .checking:
            return "checking"
        case .paused:
            return "paused"
        default:
            return "not connected"
        }
    }
}

/// One enabled cluster that has a snapshot to report from.
struct OverviewClusterReport: Identifiable {
    let profile: ClusterProfile
    let collectedAt: String
    let isLive: Bool
    let counts: JobQueueCounts

    var id: ClusterID { profile.id }
}

// MARK: - Attention

/// Something on one cluster the user should act on or know about.
struct OverviewAttentionItem: Identifiable, Equatable {
    let id: String
    let text: String
    let help: String
    let tone: StatusTone
    let systemImage: String
    /// Where the details live; nil opens the cluster on its current tab.
    let tab: DashboardTab?
}

struct OverviewAttentionLine: Identifiable {
    let profile: ClusterProfile
    let items: [OverviewAttentionItem]

    var id: ClusterID { profile.id }
}

enum OverviewAttention {
    /// What needs attention on one cluster, most severe first. Deliberately
    /// short: nearly full storage, jobs that will not start on their own,
    /// GPU models with no usable node, and a failing refresh. A handful of
    /// down nodes is routine on a large cluster and stays on the card.
    static func items(
        snapshot: ClusterSnapshot,
        fleet: GPUFleet,
        counts: JobQueueCounts,
        errorMessage: String?,
        schedulerIssue: String? = nil,
        refreshFailure: RefreshFailure? = nil,
        isLive: Bool = true
    ) -> [OverviewAttentionItem] {
        var items: [OverviewAttentionItem] = []
        if let error = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            items.append(errorItem(error, refreshFailure: refreshFailure, isLive: isLive))
        } else if let failure = refreshFailure, let item = refreshFailureItem(failure, isLive: isLive) {
            items.append(item)
        } else if let issue = schedulerIssue?.trimmingCharacters(in: .whitespacesAndNewlines), !issue.isEmpty {
            items.append(OverviewAttentionItem(
                id: "scheduler-issue",
                text: "Slurm not answering",
                help: "\(issue). The SSH session is fine, so signing in again would not help; anything that could not be refreshed shows the previous data.",
                tone: .warning,
                systemImage: "server.rack",
                tab: nil
            ))
        }

        // The Storage tab's own pressure rule (`usageTone`): over quota, or
        // space or file count past 90 % — whichever is closer to its limit.
        for item in snapshot.sortedStorage where item.usageTone == .critical {
            if item.overQuota == true {
                items.append(OverviewAttentionItem(
                    id: "storage-over-\(item.label)",
                    text: "\(item.label) over quota",
                    help: "\(item.label) is over its quota: new writes there will fail until you free space.",
                    tone: .critical,
                    systemImage: "externaldrive.badge.xmark",
                    tab: .storage
                ))
            } else if let percent = item.pressurePercent {
                let rounded = Int(percent.rounded())
                let filesBound = item.fileCountDominates
                items.append(OverviewAttentionItem(
                    id: "storage-full-\(item.label)",
                    text: filesBound ? "\(item.label) \(rounded)% of file quota" : "\(item.label) \(rounded)% full",
                    help: filesBound
                        ? "\(item.label) has used \(rounded)% of its file-count quota. Jobs that create files there may fail once it is reached."
                        : "\(item.label) is \(rounded)% full (\(OverviewFormat.usageText(item))). Jobs writing there may fail once it is full.",
                    tone: .critical,
                    systemImage: "externaldrive.badge.exclamationmark",
                    tab: .storage
                ))
            }
        }

        let neverStart = snapshot.jobs
            .filter { $0.reasonOrNodeList.lowercased().contains("dependencyneversatisfied") }
            .reduce(0) { $0 + $1.taskMultiplicity }
        if neverStart > 0 {
            items.append(OverviewAttentionItem(
                id: "jobs-never",
                text: neverStart == 1 ? "1 job can never start" : "\(neverStart) jobs can never start",
                help: "Their dependency can no longer be satisfied (the job it waits for failed or was cancelled). Cancel and resubmit them.",
                tone: .critical,
                systemImage: "link.badge.plus",
                tab: .jobs
            ))
        }

        if counts.held > 0 {
            items.append(OverviewAttentionItem(
                id: "jobs-held",
                text: counts.held == 1 ? "1 job held" : "\(counts.held) jobs held",
                help: "Held by you or an administrator: \(counts.held == 1 ? "it" : "they") will not start until released.",
                tone: .warning,
                systemImage: "pause.circle",
                tab: .jobs
            ))
        }

        for pool in fleet.pools where pool.isWhollyUnavailable {
            let nodes = pool.nodeCount == 1 ? "its only node" : "all \(pool.nodeCount) of its nodes"
            let partitions = pool.partitions.isEmpty ? "" : " Nothing in \(pool.partitions.joined(separator: ", ")) can start."
            items.append(OverviewAttentionItem(
                id: "gpu-pool-\(pool.id)",
                text: "\(pool.label) GPUs unavailable",
                help: "The \(pool.label) pool has no usable node: \(nodes) accept\(pool.nodeCount == 1 ? "s" : "") no work (down, drained or in maintenance).\(partitions)",
                // Grey like the same pool on the header chip, in Partitions
                // and in the capacity signal: out of service, not a fault.
                tone: .unavailable,
                systemImage: "memorychip",
                tab: .nodes
            ))
        }
        return items
    }

    /// An automatic refresh failure worth the overview's attention panel,
    /// by what can fix it. A connection failure only counts while the
    /// session still reads as live and it has failed twice in a row: a
    /// single blip heals on the next refresh, and a cluster that dropped to
    /// "cached" already says so on its card.
    static func refreshFailureItem(_ failure: RefreshFailure, isLive: Bool) -> OverviewAttentionItem? {
        switch failure.kind {
        case .configuration:
            return OverviewAttentionItem(
                id: "refresh-setup",
                text: "Setup problem",
                help: isLive
                    ? "\(failure.message). Fix it in the sidebar settings; signing in again will not help."
                    : "\(failure.message). Fix it in the sidebar settings; signing in will not fix it.",
                tone: .critical,
                systemImage: "wrench.and.screwdriver.fill",
                tab: nil
            )
        case .clusterSide:
            return OverviewAttentionItem(
                id: "scheduler-issue",
                text: "Slurm not answering",
                help: "\(failure.message). The SSH session is fine, so signing in again would not help; anything that could not be refreshed shows the previous data.",
                tone: .warning,
                systemImage: "server.rack",
                tab: nil
            )
        case .transport:
            guard isLive, failure.consecutiveCount >= 2 else {
                return nil
            }
            return OverviewAttentionItem(
                id: "refresh-failing",
                text: "Refreshes failing",
                help: "\(failure.message) — \(failure.consecutiveCount) failures in a row. The last snapshot stays on screen while the app retries.",
                tone: .warning,
                systemImage: "wifi.exclamationmark",
                tab: nil
            )
        }
    }

    /// The item for a session's `errorMessage`, labelled by what failed. A
    /// manual refresh reports its failure there AND records it as the
    /// refresh failure (`describes` tells them apart), so it keeps that
    /// failure's own wording — a Slurm outage stays the warning "Slurm not
    /// answering" after ⌘R. Anything else there (a failed sign-in, job
    /// cancel or sign-out) did not come from a refresh, so it is named by
    /// its own first line, never "Refresh failed".
    static func errorItem(_ error: String, refreshFailure: RefreshFailure?, isLive: Bool) -> OverviewAttentionItem {
        if let refreshFailure, refreshFailure.describes(error) {
            // A single connection failure is no attention item on its own
            // account, but the user asked for this refresh: say it failed.
            return refreshFailureItem(refreshFailure, isLive: isLive) ?? refreshFailed(error)
        }
        let firstLine = ClusterStatusContent.firstLine(error)
        return OverviewAttentionItem(
            id: "error",
            text: shortened(firstLine),
            help: firstLine,
            tone: .critical,
            systemImage: "exclamationmark.triangle.fill",
            tab: nil
        )
    }

    static func refreshFailed(_ error: String) -> OverviewAttentionItem {
        OverviewAttentionItem(
            id: "refresh-failed",
            text: "Refresh failed",
            help: ClusterStatusContent.firstLine(error),
            tone: .critical,
            systemImage: "exclamationmark.triangle.fill",
            tab: nil
        )
    }

    /// Chip-sized: at most `limit` characters, cut at a word boundary with
    /// an ellipsis; the full line is in the tooltip.
    static func shortened(_ text: String, limit: Int = 48) -> String {
        guard text.count > limit else {
            return text
        }
        let head = text.prefix(limit - 1)
        let cut = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        return cut.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }
}

// MARK: - Per-cluster figures

/// Headline numbers for one cluster's snapshot. Each figure stays within
/// its cluster; nothing here is ever summed across clusters, and GPU
/// figures stay per model (`fleet.pools`).
struct OverviewClusterStats {
    let counts: JobQueueCounts
    /// The session's per-snapshot GPU accounting: idle (startable), in use,
    /// stranded (idle on a node whose CPUs are full), unavailable and
    /// unknown, per model.
    let fleet: GPUFleet

    /// Cores on available non-GPU nodes only: GPU nodes' CPUs are meant to
    /// feed their GPUs, so counting them would overstate CPU capacity.
    let cpuIdle: Int
    let cpuTotal: Int
    let cpuNodesReporting: Int

    let nodeCount: Int
    /// Nodes that accept no new work (the NodeStateInfo allow-list: down,
    /// drained, maintenance reservation, not responding, unknown…).
    let unavailableNodes: Int
    let partitionCount: Int
    let walltime: (display: String, detail: String)?

    init(profile: ClusterProfile, snapshot: ClusterSnapshot, fleet: GPUFleet) {
        counts = JobQueueCounts(jobs: snapshot.jobs)
        self.fleet = fleet

        var cpuIdleSum = 0
        var cpuTotalSum = 0
        var cpuNodes = 0
        var unavailable = 0
        for node in snapshot.nodes {
            let available = node.stateInfo.isAvailable
            if !available {
                unavailable += 1
            }
            guard available, node.gpuCount == 0, let total = node.cpuTotal else {
                continue
            }
            cpuTotalSum += total
            cpuIdleSum += node.cpuIdle
                ?? max(total - (node.cpuAllocated ?? 0) - (node.cpuOther ?? 0), 0)
            cpuNodes += 1
        }
        cpuIdle = cpuIdleSum
        cpuTotal = cpuTotalSum
        cpuNodesReporting = cpuNodes
        nodeCount = snapshot.nodes.count
        unavailableNodes = unavailable
        partitionCount = Set(snapshot.partitions.map(\.partition)).count
        walltime = OverviewFormat.maximumWalltime(partitions: snapshot.partitions, profile: profile)
    }
}

// MARK: - Jobs

/// A job tagged with the cluster it belongs to. Slurm job ids are only
/// unique within one controller — AIRE and Calder can both have a job
/// 123456 — so the identity is cluster-qualified.
struct OverviewJobEntry: Identifiable {
    let profile: ClusterProfile
    let job: Job
    let state: JobState
    let isFromLiveSession: Bool
    let isGPU: Bool
    let timeText: String
    let placementText: String
    let clusterOrder: Int

    var id: String { "\(profile.id.rawValue):\(job.jobId)" }

    /// What the row's pill says ("Held" for a held job, as on the Jobs
    /// tab), for VoiceOver.
    var stateLabel: String {
        StatePillPresentation(job: job).label
    }

    init(profile: ClusterProfile, clusterOrder: Int, job: Job, isFromLiveSession: Bool) {
        self.profile = profile
        self.job = job
        self.isFromLiveSession = isFromLiveSession
        self.clusterOrder = clusterOrder
        state = job.jobState

        // Prefer the cluster's own partition knowledge; fall back to the
        // job's GPU request for partitions the profile does not know (or
        // multi-partition pending jobs like "gpu,nodes").
        if let role = profile.role(forPartition: job.partition) {
            isGPU = role == .gpu
        } else {
            isGPU = job.gpuRequest != nil
        }

        timeText = Self.timeText(job: job, state: state)

        let reason = job.reasonOrNodeList.trimmingCharacters(in: .whitespaces)
        if job.isArrayRemainder {
            let tasks = job.taskMultiplicity
            placementText = [tasks == 1 ? "1 task queued" : "\(tasks) tasks queued", reason.isEmpty ? nil : reason]
                .compactMap { $0 }
                .joined(separator: " · ")
        } else {
            let nodeCount = job.nodes.trimmingCharacters(in: .whitespaces)
            let nodesLabel = nodeCount.isEmpty ? nil : (nodeCount == "1" ? "1 node" : "\(nodeCount) nodes")
            placementText = [nodesLabel, reason.isEmpty ? nil : reason]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
    }

    /// "1 h 23 min of 2 days" for a running job, "limit 2 days" for a
    /// queued one — the same duration wording as the Partitions tab.
    static func timeText(job: Job, state: JobState) -> String {
        let limit = job.timeLimit.trimmingCharacters(in: .whitespaces)
        let limitText = limit.isEmpty ? nil : formatSlurmTimeLimit(limit)
        if state.occupiesNodes || state == .suspended {
            let elapsed = slurmElapsedSeconds(job.elapsed).map { slurmDurationText(seconds: $0) } ?? job.elapsed
            guard let limitText else {
                return elapsed
            }
            // "5 min of no limit" reads oddly; an unlimited job just runs.
            return slurmDurationSeconds(limit) == nil ? "\(elapsed) · \(limitText)" : "\(elapsed) of \(limitText)"
        }
        if let limitText, state.isPending {
            return "limit \(limitText)"
        }
        return limitText.map { "\(job.elapsed) of \($0)" } ?? job.elapsed
    }

    /// One list from every cluster's jobs. Each cluster keeps the shared
    /// order of the Jobs tab and the menu bar (HPCCore `jobDisplayOrder`:
    /// running, then waiting on resources, dependencies, holds; then by
    /// id). Across clusters the group decides first (every running job
    /// before any queued one), then submit time: Slurm ids come from two
    /// independent controllers and are not comparable — Calder's 5-digit
    /// ids would always sort before AIRE's 7-digit ones and take every row
    /// of the collapsed list — while submit time is the cross-cluster
    /// equivalent of an id (both count submissions). A job without a submit
    /// time goes after those with one; full ties go to catalog order.
    ///
    /// A merge, not a sort with a mixed comparator: within a cluster the
    /// order stays exactly the Jobs tab's, even where submit times and ids
    /// disagree (a requeued job), and no comparison ever mixes the two keys.
    static func merged(_ clusters: [[OverviewJobEntry]]) -> [OverviewJobEntry] {
        let lists = clusters.map { $0.sorted { jobDisplayOrder($0.job, $1.job) } }
        // Parsed once per job, not once per comparison.
        let keys = lists.map { list in
            list.map { entry in
                (rank: queueRank(entry.job), submitted: entry.job.submitTime.flatMap(SlurmTimestamp.parse) ?? .distantFuture)
            }
        }
        var next = Array(repeating: 0, count: lists.count)
        var merged: [OverviewJobEntry] = []
        merged.reserveCapacity(lists.reduce(0) { $0 + $1.count })
        while true {
            var best: Int?
            for index in lists.indices where next[index] < lists[index].count {
                guard let current = best else {
                    best = index
                    continue
                }
                let candidate = keys[index][next[index]]
                let leader = keys[current][next[current]]
                if (candidate.rank, candidate.submitted) < (leader.rank, leader.submitted) {
                    best = index
                }
            }
            guard let chosen = best else {
                break
            }
            merged.append(lists[chosen][next[chosen]])
            next[chosen] += 1
        }
        return merged
    }

    /// The group `jobDisplayOrder` sorts by first (HPCCore's
    /// `jobDisplayRank`), so the merge's groups are the Jobs tab's.
    static func queueRank(_ job: Job) -> Int {
        jobDisplayRank(job)
    }
}

// MARK: - Formatting

enum OverviewFormat {
    /// Seconds for comparing time limits: "infinite"/"UNLIMITED" sorts
    /// above every finite limit, anything unparsable below.
    static func limitRank(_ raw: String) -> Double {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered == "infinite" || lowered == "unlimited" {
            return .infinity
        }
        return slurmDurationSeconds(raw).map(Double.init) ?? -1
    }

    /// The longest limit any partition allows, plus a per-partition
    /// breakdown for the tooltip. Nil when the snapshot predates time limits.
    static func maximumWalltime(
        partitions: [PartitionSummary],
        profile: ClusterProfile
    ) -> (display: String, detail: String)? {
        // sinfo emits one row per partition *and* state; the limit is a
        // partition property, so keep the first non-empty one per name.
        var limits: [String: String] = [:]
        for row in partitions {
            guard limits[row.partition] == nil,
                  let limit = row.timeLimit?.trimmingCharacters(in: .whitespaces),
                  !limit.isEmpty else {
                continue
            }
            limits[row.partition] = limit
        }
        guard let longest = limits.max(by: { limitRank($0.value) < limitRank($1.value) }) else {
            return nil
        }
        let ordered = limits.keys.sorted { lhs, rhs in
            let lhsRank = profile.hint(forPartition: lhs)?.sortRank ?? Int.max
            let rhsRank = profile.hint(forPartition: rhs)?.sortRank ?? Int.max
            return lhsRank == rhsRank ? lhs < rhs : lhsRank < rhsRank
        }
        let detail = ordered
            .map { "\($0): \(formatSlurmTimeLimit(limits[$0] ?? ""))" }
            .joined(separator: "\n")
        return (formatSlurmTimeLimit(longest.value), "Longest job a partition allows\n\(detail)")
    }

    static func usedPercent(_ item: StorageSummary) -> Double? {
        if let percent = item.usedPercent {
            return percent
        }
        guard let used = item.usedGB, let limit = item.limitGB ?? item.quotaGB, limit > 0 else {
            return nil
        }
        return used / limit * 100
    }

    /// "12.3 GiB of 65.0 GiB", falling back gracefully when the limit or the
    /// usage is unknown.
    static func usageText(_ item: StorageSummary) -> String {
        let limit = item.limitGB ?? item.quotaGB
        switch (item.usedGB, limit) {
        case let (used?, limit?):
            return "\(formatGB(used)) of \(formatGB(limit))"
        case let (used?, nil):
            return "\(formatGB(used)) used"
        default:
            return missingValuePlaceholder
        }
    }

    /// Which mechanism governs the space. Older caches carry no quota type.
    static func quotaCaption(_ item: StorageSummary) -> String? {
        if item.source == "unavailable" {
            // The collector tags unreadable rows quota_type "df"; captioning
            // them "Filesystem usage" would claim figures that do not exist.
            return item.unavailableCaption
        }
        switch item.quotaType?.lowercased() {
        case "nfs":
            return "NFS quota"
        case "lustre-project":
            return "Lustre project quota"
        case "lustre-user":
            return "Lustre user quota"
        case "df":
            return "Filesystem usage, no quota"
        default:
            return nil
        }
    }
}
