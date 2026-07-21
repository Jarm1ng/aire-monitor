import Foundation
import UserNotifications
import os

private let cacheLogger = Logger(subsystem: "AIREMonitor", category: "SnapshotCache")

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

struct ConnectionProfile: Codable {
    let updatedAt: String
    let useSSHAlias: Bool
    let sshAlias: String
    let username: String
    let aireHostname: String
    let useJumpHost: Bool
    let jumpHostname: String
    let controlPath: String
    let jumpControlPath: String

    init(settings: ServerSettings) {
        updatedAt = iso8601Formatter.string(from: Date())
        useSSHAlias = settings.useSSHAlias
        sshAlias = settings.sshAlias
        username = settings.username
        aireHostname = settings.aireHostname
        useJumpHost = settings.useJumpHost
        jumpHostname = settings.jumpHostname
        controlPath = settings.controlPath
        jumpControlPath = settings.jumpControlPath
    }
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

    var id: String { collectedAt }
}

struct SnapshotCache {
    let projectRoot: String

    private var runtimeURL: URL {
        URL(fileURLWithPath: projectRoot).appendingPathComponent(".runtime")
    }

    var latestSnapshotURL: URL {
        runtimeURL.appendingPathComponent("latest_snapshot.json")
    }

    private var jobStateURL: URL {
        runtimeURL.appendingPathComponent("job_state.json")
    }

    private var historyURL: URL {
        runtimeURL.appendingPathComponent("snapshot_history.json")
    }

    private var connectionProfileURL: URL {
        runtimeURL.appendingPathComponent("connection_profile.json")
    }

    /// Decodes the JSON file at `url`. A file that exists but no longer
    /// decodes is moved aside (".bad" suffix) and logged rather than being
    /// silently discarded and overwritten on the next save.
    private func decodeQuarantining<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
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

    func loadLatestSnapshot() -> ClusterSnapshot? {
        decodeQuarantining(ClusterSnapshot.self, from: latestSnapshotURL)
    }

    func saveLatestSnapshot(_ snapshot: ClusterSnapshot) throws {
        try FileManager.default.createDirectory(at: runtimeURL, withIntermediateDirectories: true)
        let data = try JSONEncoder.prettyAIRE.encode(snapshot)
        try data.write(to: latestSnapshotURL, options: .atomic)
    }

    func loadConnectionProfile() -> ConnectionProfile? {
        decodeQuarantining(ConnectionProfile.self, from: connectionProfileURL)
    }

    func saveConnectionProfile(_ profile: ConnectionProfile) throws {
        try FileManager.default.createDirectory(at: runtimeURL, withIntermediateDirectories: true)
        let data = try JSONEncoder.prettyAIRE.encode(profile)
        try data.write(to: connectionProfileURL, options: .atomic)
    }

    func loadHistory() -> [TrendPoint] {
        decodeQuarantining([TrendPoint].self, from: historyURL) ?? []
    }

    func recordHistory(from snapshot: ClusterSnapshot) throws -> [TrendPoint] {
        try FileManager.default.createDirectory(at: runtimeURL, withIntermediateDirectories: true)
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
        let data = try JSONEncoder.prettyAIRE.encode(history)
        try data.write(to: historyURL, options: .atomic)
        return history
    }

    func loadJobStateSnapshot() -> JobStateSnapshot? {
        decodeQuarantining(JobStateSnapshot.self, from: jobStateURL)
    }

    func saveJobStates(from jobs: [Job]) throws {
        try FileManager.default.createDirectory(at: runtimeURL, withIntermediateDirectories: true)
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
        let data = try JSONEncoder.prettyAIRE.encode(state)
        try data.write(to: jobStateURL, options: .atomic)
    }
}

extension TrendPoint {
    init(snapshot: ClusterSnapshot) {
        let gpuNodes = snapshot.nodes.filter { ($0.gpuTotal ?? slurmGPUTotal(from: $0.gres)) > 0 }
        let gpuTotalValue = gpuNodes.reduce(0) { $0 + ($1.gpuTotal ?? slurmGPUTotal(from: $1.gres)) }
        let gpuAllocatedValue = gpuNodes.reduce(0) { $0 + ($1.gpuAllocated ?? 0) }
        let storage = snapshot.storage ?? []
        let home = storage.first { $0.label.lowercased() == "home" }
        let scratch = storage.first { $0.label.lowercased() == "scratch" }

        collectedAt = snapshot.collectedAt
        totalJobs = snapshot.jobs.count
        runningJobs = snapshot.jobs.filter { $0.state.uppercased().contains("RUN") }.count
        pendingJobs = snapshot.jobs.filter { $0.state.uppercased().contains("PEND") }.count
        gpuTotal = gpuTotalValue
        gpuAllocated = gpuAllocatedValue
        gpuIdle = Swift.max(gpuTotalValue - gpuAllocatedValue, 0)
        unavailableGpuNodes = gpuNodes.filter { !isAvailable($0) }.count
        homeUsedPercent = home?.usedPercent
        scratchUsedPercent = scratch?.usedPercent
        homeAvailableGB = home?.availableGB
        scratchAvailableGB = scratch?.availableGB
    }
}

extension JSONEncoder {
    static let prettyAIRE: JSONEncoder = {
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
    func notifyChanges(previous: JobStateSnapshot?, current jobs: [Job]) async -> Bool {
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
                sendJobStartedNotification(name: job.name, jobId: job.jobId, partition: job.partition)
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
            sendJobEndedNotification(ending)
        } else if endings.count > 1 {
            sendJobsEndedSummaryNotification(endings)
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
    func notifyGPUBecameAvailable(idleCount: Int, partitions: [String]) async -> Bool {
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
        let countText = "\(idleCount) GPU\(idleCount == 1 ? "" : "s")"
        send(
            title: "GPU available on AIRE",
            subtitle: "Idle GPUs detected",
            body: "\(countText) idle across \(nodesText)",
            identifier: "gpu-available-\(iso8601Formatter.string(from: Date()))",
            thread: "aire-gpu-availability"
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

    private func sendJobStartedNotification(name: String, jobId: String, partition: String) {
        send(
            title: "AIRE Monitor",
            subtitle: "Your job started",
            body: "\(displayName(name: name, jobId: jobId)) (#\(jobId))\nNow running on partition \(partition).",
            identifier: "job-started-\(jobId)-\(iso8601Formatter.string(from: Date()))"
        )
    }

    private func sendJobEndedNotification(_ ending: JobEnding) {
        let subtitle = ending.finalState == "Left queue"
            ? "Job finished or left the queue"
            : "Job ended: \(ending.finalState)"
        let body = [
            "\(displayName(name: ending.name, jobId: ending.jobId)) (#\(ending.jobId))",
            "Partition \(ending.partition) • previous state \(ending.lastState)",
            ending.detail
        ].joined(separator: "\n")

        send(
            title: "AIRE Monitor",
            subtitle: subtitle,
            body: body,
            identifier: "job-ended-\(ending.jobId)-\(ending.finalState)-\(iso8601Formatter.string(from: Date()))"
        )
    }

    private func sendJobsEndedSummaryNotification(_ endings: [JobEnding]) {
        let lines = endings.map { ending in
            "\(displayName(name: ending.name, jobId: ending.jobId)) (#\(ending.jobId)) — \(ending.finalState)"
        }
        send(
            title: "AIRE Monitor",
            subtitle: "\(endings.count) jobs ended",
            body: lines.joined(separator: "\n"),
            identifier: "jobs-ended-summary-\(iso8601Formatter.string(from: Date()))"
        )
    }

    private func send(
        title: String,
        subtitle: String,
        body: String,
        identifier: String,
        thread: String = "aire-job-events"
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
