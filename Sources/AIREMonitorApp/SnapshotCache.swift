import Foundation
import UserNotifications

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

    func loadLatestSnapshot() -> ClusterSnapshot? {
        guard let data = try? Data(contentsOf: latestSnapshotURL) else {
            return nil
        }
        return try? JSONDecoder().decode(ClusterSnapshot.self, from: data)
    }

    func saveLatestSnapshot(_ snapshot: ClusterSnapshot) throws {
        try FileManager.default.createDirectory(at: runtimeURL, withIntermediateDirectories: true)
        let data = try JSONEncoder.prettyAIRE.encode(snapshot)
        try data.write(to: latestSnapshotURL, options: .atomic)
    }

    func loadHistory() -> [TrendPoint] {
        guard let data = try? Data(contentsOf: historyURL) else {
            return []
        }
        return (try? JSONDecoder().decode([TrendPoint].self, from: data)) ?? []
    }

    func recordHistory(from snapshot: ClusterSnapshot) throws -> [TrendPoint] {
        try FileManager.default.createDirectory(at: runtimeURL, withIntermediateDirectories: true)
        var history = loadHistory()
        let point = TrendPoint(snapshot: snapshot)
        if history.last?.collectedAt != point.collectedAt {
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
        guard let data = try? Data(contentsOf: jobStateURL) else {
            return nil
        }
        return try? JSONDecoder().decode(JobStateSnapshot.self, from: data)
    }

    func saveJobStates(from jobs: [Job]) throws {
        try FileManager.default.createDirectory(at: runtimeURL, withIntermediateDirectories: true)
        let now = ISO8601DateFormatter().string(from: Date())
        let records = Dictionary(
            uniqueKeysWithValues: jobs.map { job in
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
            }
        )
        let state = JobStateSnapshot(updatedAt: now, jobs: records)
        let data = try JSONEncoder.prettyAIRE.encode(state)
        try data.write(to: jobStateURL, options: .atomic)
    }
}

extension TrendPoint {
    init(snapshot: ClusterSnapshot) {
        let gpuNodes = snapshot.nodes.filter { localGPUCapacity($0) > 0 }
        let gpuTotalValue = gpuNodes.reduce(0) { $0 + localGPUCapacity($1) }
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

private func localGPUCapacity(_ node: NodeSummary) -> Int {
    if let total = node.gpuTotal {
        return total
    }
    guard node.gres.lowercased().contains("gpu") else {
        return 0
    }
    return Int(node.gres.split(separator: ":").last ?? "") ?? 0
}

private func isAvailable(_ node: NodeSummary) -> Bool {
    let state = node.state.lowercased()
    return !state.contains("maint")
        && !state.contains("down")
        && !state.contains("drain")
        && !state.contains("fail")
}

extension JSONEncoder {
    static var prettyAIRE: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

@MainActor
final class JobNotificationService: NSObject, UNUserNotificationCenterDelegate {
    private var isAuthorized = false
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

    func configure() {
        guard !didRequestAuthorization else {
            return
        }
        didRequestAuthorization = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.isAuthorized = granted
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func notifyChanges(previous: JobStateSnapshot?, current jobs: [Job]) {
        guard isAuthorized, let previous else {
            return
        }

        let currentById = Dictionary(uniqueKeysWithValues: jobs.map { ($0.jobId, $0) })

        for job in jobs {
            guard let old = previous.jobs[job.jobId],
                  old.state != job.state,
                  isTerminalState(job.state) else {
                continue
            }
            sendJobEndedNotification(
                name: job.name,
                jobId: job.jobId,
                partition: job.partition,
                lastState: old.state,
                finalState: job.state,
                detail: "Final state reported by Slurm."
            )
        }

        for old in previous.jobs.values where currentById[old.jobId] == nil && !isTerminalState(old.state) {
            sendJobEndedNotification(
                name: old.name,
                jobId: old.jobId,
                partition: old.partition,
                lastState: old.state,
                finalState: "Left queue",
                detail: "The job is no longer visible in squeue."
            )
        }
    }

    private func isTerminalState(_ state: String) -> Bool {
        let normalized = state.uppercased()
        return terminalStateKeywords.contains { normalized.contains($0) }
    }

    private func sendJobEndedNotification(
        name: String,
        jobId: String,
        partition: String,
        lastState: String,
        finalState: String,
        detail: String
    ) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = cleanName.isEmpty ? "Job \(jobId)" : cleanName
        let subtitle = finalState == "Left queue"
            ? "Job finished or left the queue"
            : "Job ended: \(finalState)"
        let body = [
            "\(displayName) (#\(jobId))",
            "Partition \(partition) • previous state \(lastState)",
            detail
        ].joined(separator: "\n")

        send(
            title: "AIRE Monitor",
            subtitle: subtitle,
            body: body,
            identifier: "job-ended-\(jobId)-\(finalState)-\(ISO8601DateFormatter().string(from: Date()))"
        )
    }

    private func send(title: String, subtitle: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        content.threadIdentifier = "aire-job-events"

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
