import HPCCore
import Foundation

/// What a cache write was for, in log lines and problem reports.
enum CacheWriteOperation: String, Sendable {
    case snapshot = "latest_snapshot.json"
    case history = "snapshot_history.jsonl"
    case jobState = "job_state.json"
    case appState = "app_state.json"
    case collectorArguments = "collector.json"
}

/// One cluster's cache writes, on a serial background queue.
///
/// Every refresh used to decode, re-encode and atomically rewrite the whole
/// pretty-printed history and snapshot on the main actor (~12 GB of writes a
/// day, ~15-25 ms of main-thread time per refresh). Now the session keeps
/// the state in memory and hands each write here: a compact snapshot, one
/// appended history line, an occasional history compaction, the job
/// baseline and the widget lease. A serial queue (not an actor) because
/// writes must land in submission order — an older snapshot must never
/// overwrite a newer one.
///
/// Failures are logged; a write kind that keeps failing (full disk, lost
/// permissions) is reported once through `onProblem` so the user learns
/// that the widget and cache stopped updating, and again (with nil) when it
/// recovers.
final class ClusterCacheWriter: @unchecked Sendable {
    /// Consecutive failures of one kind before it is reported.
    static let failuresBeforeReport = 3

    private let queue: DispatchQueue
    private let clusterID: ClusterID
    private let onProblem: @Sendable (CacheWriteOperation, String?) -> Void
    // Confined to `queue`.
    private var consecutiveFailures: [CacheWriteOperation: Int] = [:]
    private var reported: Set<CacheWriteOperation> = []

    /// `onProblem` runs on the writer's queue; hop to the main actor there.
    init(clusterID: ClusterID, onProblem: @escaping @Sendable (CacheWriteOperation, String?) -> Void) {
        self.clusterID = clusterID
        self.onProblem = onProblem
        queue = DispatchQueue(label: "HPCMonitor.cache.\(clusterID.rawValue)", qos: .utility)
    }

    func saveSnapshot(_ snapshot: ClusterSnapshot, to cache: SnapshotCache) {
        perform(.snapshot) { try cache.saveLatestSnapshot(snapshot) }
    }

    func appendHistory(_ point: TrendPoint, to cache: SnapshotCache) {
        perform(.history) { try cache.appendHistory(point) }
    }

    func rewriteHistory(_ points: [TrendPoint], to cache: SnapshotCache) {
        perform(.history) { try cache.rewriteHistory(points) }
    }

    func saveJobStates(_ baseline: JobStateSnapshot, to cache: SnapshotCache) {
        perform(.jobState) { try cache.saveJobStates(baseline) }
    }

    func saveAppState(_ state: ClusterAppState, to cache: SnapshotCache) {
        perform(.appState) { try cache.saveAppState(state) }
    }

    func saveCollectorArguments(_ arguments: [String], to cache: SnapshotCache, completion: @escaping @Sendable (Bool) -> Void) {
        perform(.collectorArguments, completion: completion) { try cache.saveCollectorArguments(arguments) }
    }

    /// Runs `body` on the queue after every write submitted before it and
    /// waits for it. For termination and tests only.
    func sync(_ body: () -> Void = {}) {
        queue.sync(execute: body)
    }

    /// Writes the widget lease synchronously (app termination of a paused
    /// or switched-off cluster: the record must be on disk before the
    /// process exits, or the widget would never learn of the pause).
    func saveAppStateNow(_ state: ClusterAppState, to cache: SnapshotCache) {
        queue.sync {
            do {
                try cache.saveAppState(state)
            } catch {
                Log.cache.error(
                    "Could not write \(self.clusterID.rawValue, privacy: .public)/app_state.json at quit: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    /// Removes the widget lease synchronously (app termination), so the
    /// widget can take over collection at once instead of waiting for the
    /// lease to expire.
    func removeAppStateNow(from cache: SnapshotCache) {
        queue.sync {
            do {
                try cache.removeAppState()
            } catch {
                Log.cache.error(
                    "Could not remove \(self.clusterID.rawValue, privacy: .public)/app_state.json: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    private func perform(
        _ operation: CacheWriteOperation,
        completion: (@Sendable (Bool) -> Void)? = nil,
        _ body: @escaping @Sendable () throws -> Void
    ) {
        queue.async { [self] in
            do {
                try body()
                consecutiveFailures[operation] = 0
                if reported.remove(operation) != nil {
                    Log.cache.info("\(self.clusterID.rawValue, privacy: .public): writing \(operation.rawValue, privacy: .public) works again")
                    onProblem(operation, nil)
                }
                completion?(true)
            } catch {
                let count = (consecutiveFailures[operation] ?? 0) + 1
                consecutiveFailures[operation] = count
                Log.cache.error(
                    "\(self.clusterID.rawValue, privacy: .public): could not write \(operation.rawValue, privacy: .public) (failure \(count, privacy: .public)): \(String(describing: error), privacy: .public)"
                )
                if count >= Self.failuresBeforeReport, reported.insert(operation).inserted {
                    onProblem(operation, error.localizedDescription)
                }
                completion?(false)
            }
        }
    }
}
