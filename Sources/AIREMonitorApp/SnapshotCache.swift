import Foundation
import UserNotifications
import os

private let cacheLogger = Logger(subsystem: "HPCMonitor", category: "SnapshotCache")

// ISO8601DateFormatter is documented as thread-safe; share one instance
// instead of allocating a formatter per call.
nonisolated(unsafe) private let iso8601Formatter = ISO8601DateFormatter()

struct JobStateRecord: Codable {
    let jobId: String
    let name: String
    let partition: String
    let state: String
    let lastSeenAt: String
}

struct JobStateSnapshot: Codable {
    let updatedAt: String
    let jobs: [String: JobStateRecord]
}

struct TrendPoint: Codable, Identifiable {
    let collectedAt: String
    let totalJobs: Int
    let runningJobs: Int
    let pendingJobs: Int
    let gpuTotal: Int
    let gpuAllocated: Int
    let gpuIdle: Int
    let unavailableGpuNodes: Int
    let homeUsedPercent: Double?
    let scratchUsedPercent: Double?
    let homeAvailableGB: Double?
    let scratchAvailableGB: Double?
    // Optional so history files written before flash was collected decode.
    let flashUsedPercent: Double?
    let flashAvailableGB: Double?

    var id: String { collectedAt }
}

/// Reads and writes one file atomically, quarantining files that no longer
/// decode instead of silently discarding (and later overwriting) them.
private enum JSONFile {
    static func decodeQuarantining<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            cacheLogger.error(
                "Failed to decode \(url.lastPathComponent, privacy: .public); moving corrupt file aside: \(String(describing: error), privacy: .public)"
            )
            let quarantineURL = url.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: quarantineURL)
            try? FileManager.default.moveItem(at: url, to: quarantineURL)
            return nil
        }
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.prettySorted.encode(value)
        try data.write(to: url, options: .atomic)
    }
}

/// Per-cluster cache under `.runtime/clusters/<id>/`. Every cluster has its
/// own snapshot, history and job-state baseline: Slurm job ids are only
/// unique within one cluster, so a shared baseline would mis-fire
/// start/end notifications across clusters.
struct SnapshotCache {
    let projectRoot: String
    let clusterID: ClusterID

    static func clustersRoot(projectRoot: String) -> URL {
        URL(fileURLWithPath: projectRoot)
            .appendingPathComponent(".runtime")
            .appendingPathComponent("clusters")
    }

    var directoryURL: URL {
        Self.clustersRoot(projectRoot: projectRoot).appendingPathComponent(clusterID.rawValue)
    }

    var latestSnapshotURL: URL {
        directoryURL.appendingPathComponent("latest_snapshot.json")
    }

    private var jobStateURL: URL {
        directoryURL.appendingPathComponent("job_state.json")
    }

    private var historyURL: URL {
        directoryURL.appendingPathComponent("snapshot_history.json")
    }

    private var collectorURL: URL {
        directoryURL.appendingPathComponent("collector.json")
    }

    func loadLatestSnapshot() -> ClusterSnapshot? {
        JSONFile.decodeQuarantining(ClusterSnapshot.self, from: latestSnapshotURL)
    }

    func saveLatestSnapshot(_ snapshot: ClusterSnapshot) throws {
        try JSONFile.write(snapshot, to: latestSnapshotURL)
    }

    func loadHistory() -> [TrendPoint] {
        JSONFile.decodeQuarantining([TrendPoint].self, from: historyURL) ?? []
    }

    func recordHistory(from snapshot: ClusterSnapshot) throws -> [TrendPoint] {
        var history = loadHistory()
        let point = TrendPoint(snapshot: snapshot)
        // Dedupe by membership, not just the last entry: a stale collectedAt
        // can reappear non-adjacently after an error gap, and TrendPoint.id is
        // collectedAt, so duplicates would break SwiftUI identity.
        let seenTimestamps = Set(history.map(\.collectedAt))
        if !seenTimestamps.contains(point.collectedAt) {
            history.append(point)
        }
        if history.count > 1440 {
            history = Array(history.suffix(1440))
        }
        try JSONFile.write(history, to: historyURL)
        return history
    }

    func loadJobStateSnapshot() -> JobStateSnapshot? {
        JSONFile.decodeQuarantining(JobStateSnapshot.self, from: jobStateURL)
    }

    func saveJobStates(from jobs: [Job]) throws {
        let now = iso8601Formatter.string(from: Date())
        let records = Dictionary(
            jobs.map { job in
                (
                    job.jobId,
                    JobStateRecord(
                        jobId: job.jobId,
                        name: job.name,
                        partition: job.partition,
                        state: job.state,
                        lastSeenAt: now
                    )
                )
            },
            uniquingKeysWith: { _, last in last }
        )
        let state = JobStateSnapshot(updatedAt: now, jobs: records)
        try JSONFile.write(state, to: jobStateURL)
    }

    /// Password-free record of the exact collector invocation, consumed by
    /// the desktop widget's fallback collection.
    func saveCollectorArguments(_ arguments: [String]) throws {
        struct CollectorInvocation: Encodable {
            let updatedAt: String
            let script: String
            let arguments: [String]
        }
        try JSONFile.write(
            CollectorInvocation(
                updatedAt: iso8601Formatter.string(from: Date()),
                script: MonitorService.collectorScript,
                arguments: arguments
            ),
            to: collectorURL
        )
    }
}

// MARK: - Preferences

/// Password-free settings persisted in `.runtime/preferences.json`.
struct AppPreferences: Codable {
    struct ClusterPreference: Codable {
        var enabled: Bool
        var hostname: String
    }

    var username: String = ""
    var route: ConnectionRoute = .directVPN
    var jumpHostname: String = "rash.leeds.ac.uk"
    var duoOption: String = "1"
    /// Keyed by ClusterID.rawValue.
    var clusters: [String: ClusterPreference] = [:]
    /// "overview" or "cluster:<id>".
    var selection: String?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        route = (try? container.decodeIfPresent(ConnectionRoute.self, forKey: .route)) ?? .directVPN
        jumpHostname = try container.decodeIfPresent(String.self, forKey: .jumpHostname) ?? "rash.leeds.ac.uk"
        duoOption = try container.decodeIfPresent(String.self, forKey: .duoOption) ?? "1"
        clusters = try container.decodeIfPresent([String: ClusterPreference].self, forKey: .clusters) ?? [:]
        selection = try container.decodeIfPresent(String.self, forKey: .selection)
    }
}

struct PreferencesStore {
    let projectRoot: String

    private var runtimeURL: URL {
        URL(fileURLWithPath: projectRoot).appendingPathComponent(".runtime")
    }

    private var preferencesURL: URL {
        runtimeURL.appendingPathComponent("preferences.json")
    }

    /// Loads preferences, migrating a pre-multi-cluster installation on
    /// first launch: the single-cluster connection profile seeds the shared
    /// sign-in fields and AIRE's host, and the single-cluster snapshot cache
    /// files move into `.runtime/clusters/aire/` (the only cluster that
    /// existed then).
    func load() -> AppPreferences {
        migrateLegacySnapshotFiles()
        if let preferences = JSONFile.decodeQuarantining(AppPreferences.self, from: preferencesURL) {
            return preferences
        }
        return legacyPreferences() ?? AppPreferences()
    }

    func save(_ preferences: AppPreferences) throws {
        try JSONFile.write(preferences, to: preferencesURL)
    }

    private func legacyPreferences() -> AppPreferences? {
        struct LegacyConnectionProfile: Decodable {
            let username: String?
            let aireHostname: String?
            let useJumpHost: Bool?
            let useSSHAlias: Bool?
            let jumpHostname: String?
        }
        let url = runtimeURL.appendingPathComponent("connection_profile.json")
        guard let legacy = JSONFile.decodeQuarantining(LegacyConnectionProfile.self, from: url) else {
            return nil
        }
        var preferences = AppPreferences()
        preferences.username = legacy.username ?? ""
        preferences.route = (legacy.useSSHAlias != true && legacy.useJumpHost == true) ? .rashJump : .directVPN
        if let jump = legacy.jumpHostname, !jump.isEmpty {
            preferences.jumpHostname = jump
        }
        if let host = legacy.aireHostname, !host.isEmpty {
            preferences.clusters[ClusterID.aire.rawValue] = .init(enabled: true, hostname: host)
        }
        return preferences
    }

    private func migrateLegacySnapshotFiles() {
        let fileManager = FileManager.default
        let aireDirectory = SnapshotCache.clustersRoot(projectRoot: projectRoot)
            .appendingPathComponent(ClusterID.aire.rawValue)
        for name in ["latest_snapshot.json", "snapshot_history.json", "job_state.json"] {
            let legacy = runtimeURL.appendingPathComponent(name)
            let migrated = aireDirectory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: legacy.path),
                  !fileManager.fileExists(atPath: migrated.path) else {
                continue
            }
            do {
                try fileManager.createDirectory(at: aireDirectory, withIntermediateDirectories: true)
                try fileManager.moveItem(at: legacy, to: migrated)
            } catch {
                cacheLogger.error(
                    "Could not migrate \(name, privacy: .public) into clusters/aire: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }
}

/// File-scope so it can call the global `gpuIdle(_:)`, which TrendPoint's
/// own `gpuIdle` property shadows inside the initializer.
private func idleGPUsOnAvailableNodes(_ nodes: [NodeSummary]) -> Int {
    nodes.filter { isAvailable($0) }.reduce(0) { $0 + gpuIdle($1) }
}

extension TrendPoint {
    init(snapshot: ClusterSnapshot) {
        let gpuNodes = snapshot.nodes.filter { ($0.gpuTotal ?? slurmGPUTotal(from: $0.gres)) > 0 }
        let gpuTotalValue = gpuNodes.reduce(0) { $0 + ($1.gpuTotal ?? slurmGPUTotal(from: $1.gres)) }
        let gpuAllocatedValue = gpuNodes.reduce(0) { $0 + ($1.gpuAllocated ?? 0) }
        let storage = snapshot.storage ?? []
        let home = storage.first { $0.kind == .home }
        let scratch = storage.first { $0.kind == .scratch }
        let flash = storage.first { $0.kind == .flash }

        collectedAt = snapshot.collectedAt
        totalJobs = snapshot.jobs.count
        runningJobs = snapshot.jobs.filter { $0.state.uppercased().contains("RUN") }.count
        pendingJobs = snapshot.jobs.filter { $0.state.uppercased().contains("PEND") }.count
        gpuTotal = gpuTotalValue
        gpuAllocated = gpuAllocatedValue
        // Free means startable now: idle GPUs on drained/down/not-responding
        // nodes are excluded, matching ClusterSession.gpuAvailability, the
        // Nodes tab and the widget (a drained 8-GPU node otherwise shows up
        // as 8 "free" GPUs in the trend).
        gpuIdle = idleGPUsOnAvailableNodes(gpuNodes)
        unavailableGpuNodes = gpuNodes.filter { !isAvailable($0) }.count
        homeUsedPercent = home?.usedPercent
        scratchUsedPercent = scratch?.usedPercent
        homeAvailableGB = home?.availableGB
        scratchAvailableGB = scratch?.availableGB
        flashUsedPercent = flash?.usedPercent
        flashAvailableGB = flash?.availableGB
    }
}

extension JSONEncoder {
    static let prettySorted: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

@MainActor
final class JobNotificationService: NSObject, UNUserNotificationCenterDelegate {
    private var didRequestAuthorization = false
    private let terminalStateKeywords = [
        "BOOT_FAIL",
        "CANCELLED",
        "COMPLETED",
        "DEADLINE",
        "FAILED",
        "NODE_FAIL",
        "OUT_OF_MEMORY",
        "PREEMPTED",
        "REVOKED",
        "SPECIAL_EXIT",
        "TIMEOUT"
    ]

    private struct JobEnding {
        let name: String
        let jobId: String
        let partition: String
        let lastState: String
        let finalState: String
        let detail: String
    }

    // UNUserNotificationCenter aborts when the process has no app bundle
    // (e.g. running the bare debug binary instead of the assembled .app).
    static let notificationsSupported = Bundle.main.bundleIdentifier != nil

    func configure() {
        guard Self.notificationsSupported, !didRequestAuthorization else {
            return
        }
        didRequestAuthorization = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Diffs the previous and current job lists and posts notifications for
    /// job starts and endings. Returns true when the diff was actually
    /// processed (or there was nothing to diff yet), so callers know whether
    /// it is safe to persist the current job states as the new baseline.
    func notifyChanges(
        cluster: ClusterProfile,
        previous: JobStateSnapshot?,
        current jobs: [Job]
    ) async -> Bool {
        guard Self.notificationsSupported else {
            return false
        }
        // Re-query authorization every time instead of caching a one-shot
        // flag, so a grant made later in System Settings takes effect without
        // relaunching.
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            break
        default:
            return false
        }
        guard let previous else {
            // First observation: nothing to diff, but the baseline may be
            // persisted.
            return true
        }

        let currentById = Dictionary(
            jobs.map { ($0.jobId, $0) },
            uniquingKeysWith: { _, last in last }
        )

        var endings: [JobEnding] = []
        var notifiedStartIds = Set<String>()
        for job in jobs {
            guard let old = previous.jobs[job.jobId], old.state != job.state else {
                continue
            }
            if isTerminalState(job.state) {
                endings.append(
                    JobEnding(
                        name: job.name,
                        jobId: job.jobId,
                        partition: job.partition,
                        lastState: old.state,
                        finalState: job.state,
                        detail: "Final state reported by Slurm."
                    )
                )
            } else if isPendingState(old.state),
                      isRunningState(job.state),
                      notifiedStartIds.insert(job.jobId).inserted {
                sendJobStartedNotification(cluster: cluster, name: job.name, jobId: job.jobId, partition: job.partition)
            }
        }

        for old in previous.jobs.values where currentById[old.jobId] == nil && !isTerminalState(old.state) {
            endings.append(
                JobEnding(
                    name: old.name,
                    jobId: old.jobId,
                    partition: old.partition,
                    lastState: old.state,
                    finalState: "Left queue",
                    detail: "The job is no longer visible in squeue."
                )
            )
        }

        if endings.count == 1, let ending = endings.first {
            sendJobEndedNotification(cluster: cluster, ending)
        } else if endings.count > 1 {
            sendJobsEndedSummaryNotification(cluster: cluster, endings)
        }
        return true
    }

    /// Human-readable summary of the notification permission state for
    /// display in the sidebar. Async because the authorization status has to
    /// be queried from UNUserNotificationCenter.
    func authorizationSummary() async -> String {
        guard Self.notificationsSupported else {
            return "Unavailable outside the app bundle"
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized:
            return "Allowed"
        case .provisional:
            return "Allowed (provisional)"
        case .denied:
            return "Denied — enable in System Settings"
        case .notDetermined:
            return "Not requested yet"
        case .ephemeral:
            return "Ephemeral"
        @unknown default:
            return "Unknown"
        }
    }

    /// Posts the fleet-wide "a GPU freed up" alert. Returns true when the
    /// notification was actually queued, so the caller can start its
    /// cooldown; the same support/authorization guards as job notifications
    /// apply.
    func notifyGPUBecameAvailable(
        cluster: ClusterProfile,
        idleCount: Int,
        gpuModel: String?,
        partitions: [String]
    ) async -> Bool {
        guard Self.notificationsSupported else {
            return false
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            break
        default:
            return false
        }
        let nodesText = partitions.isEmpty
            ? "GPU nodes"
            : "\(partitions.joined(separator: ", ")) partition nodes"
        let modelText = gpuModel.map { " \($0)" } ?? ""
        let countText = "\(idleCount)\(modelText) GPU\(idleCount == 1 ? "" : "s")"
        send(
            title: "GPU available on \(cluster.displayName)",
            subtitle: "Idle GPUs detected",
            body: "\(countText) idle across \(nodesText)",
            identifier: "\(cluster.id.rawValue)-gpu-available-\(iso8601Formatter.string(from: Date()))",
            thread: "\(cluster.id.rawValue)-gpu-availability"
        )
        return true
    }

    private func isTerminalState(_ state: String) -> Bool {
        let normalized = state.uppercased()
        return terminalStateKeywords.contains { normalized.contains($0) }
    }

    private func isPendingState(_ state: String) -> Bool {
        state.uppercased().contains("PEND")
    }

    private func isRunningState(_ state: String) -> Bool {
        state.uppercased().contains("RUN")
    }

    private func displayName(name: String, jobId: String) -> String {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanName.isEmpty ? "Job \(jobId)" : cleanName
    }

    private func sendJobStartedNotification(cluster: ClusterProfile, name: String, jobId: String, partition: String) {
        send(
            title: "\(cluster.displayName) · job started",
            subtitle: "Your job started",
            body: "\(displayName(name: name, jobId: jobId)) (#\(jobId))\nNow running on partition \(partition).",
            identifier: "\(cluster.id.rawValue)-job-started-\(jobId)-\(iso8601Formatter.string(from: Date()))",
            thread: "\(cluster.id.rawValue)-job-events"
        )
    }

    private func sendJobEndedNotification(cluster: ClusterProfile, _ ending: JobEnding) {
        let subtitle = ending.finalState == "Left queue"
            ? "Job finished or left the queue"
            : "Job ended: \(ending.finalState)"
        let body = [
            "\(displayName(name: ending.name, jobId: ending.jobId)) (#\(ending.jobId))",
            "Partition \(ending.partition) • previous state \(ending.lastState)",
            ending.detail
        ].joined(separator: "\n")

        send(
            title: "\(cluster.displayName) · job ended",
            subtitle: subtitle,
            body: body,
            identifier: "\(cluster.id.rawValue)-job-ended-\(ending.jobId)-\(ending.finalState)-\(iso8601Formatter.string(from: Date()))",
            thread: "\(cluster.id.rawValue)-job-events"
        )
    }

    private func sendJobsEndedSummaryNotification(cluster: ClusterProfile, _ endings: [JobEnding]) {
        let lines = endings.map { ending in
            "\(displayName(name: ending.name, jobId: ending.jobId)) (#\(ending.jobId)) — \(ending.finalState)"
        }
        send(
            title: "\(cluster.displayName) · jobs ended",
            subtitle: "\(endings.count) jobs ended",
            body: lines.joined(separator: "\n"),
            identifier: "\(cluster.id.rawValue)-jobs-ended-summary-\(iso8601Formatter.string(from: Date()))",
            thread: "\(cluster.id.rawValue)-job-events"
        )
    }

    private func send(
        title: String,
        subtitle: String,
        body: String,
        identifier: String,
        thread: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        content.threadIdentifier = thread

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
