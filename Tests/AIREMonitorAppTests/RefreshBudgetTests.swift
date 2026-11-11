import Combine
import Darwin
import HPCCore
import Foundation
import Testing
@testable import AIREMonitorApp

/// Guards the refresh rendering and I/O budget at the model level (counting
/// objectWillChange, not SwiftUI body runs, which would be brittle across OS
/// releases): an unchanged background refresh publishes nothing, a manual
/// one at most its spinner on and off, one cluster's refresh never touches
/// another cluster, and history is appended, never rewritten per refresh.
@MainActor
@Suite("Refresh budget")
struct RefreshBudgetTests {
    private func countPublishes(of session: ClusterSession, during body: () async throws -> Void) async rethrows -> Int {
        var count = 0
        let subscription = session.objectWillChange.sink { _ in count += 1 }
        try await body()
        subscription.cancel()
        return count
    }

    @Test("A background refresh with identical data publishes nothing")
    func identicalAutomaticRefreshIsSilent() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        try await harness.tick()

        let publishes = try await countPublishes(of: harness.session) {
            try await harness.tick()
        }
        #expect(publishes == 0)
    }

    @Test("A manual refresh with identical data publishes only its spinner")
    func identicalManualRefresh() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()

        let publishes = try await countPublishes(of: harness.session) {
            let before = harness.backend.completedCollections
            harness.session.refresh()
            try await waitUntil("manual refresh") {
                harness.backend.completedCollections > before && !harness.session.refreshInFlight
            }
        }
        #expect(publishes <= 2)
    }

    @Test("New data is applied in a single publish")
    func newDataIsOnePublish() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        harness.backend.setFallback(.success(makeSnapshot(
            collectedAt: "2026-10-13T12:00:10Z",
            jobs: [Job(jobId: "1", state: "RUNNING")]
        )))

        var publishes = 0
        var turns = Set<Int>()
        var turn = 0
        let subscription = harness.session.objectWillChange.sink { _ in
            publishes += 1
            turns.insert(turn)
        }
        let before = harness.backend.completedCollections
        harness.scheduler.fire()
        while !(harness.backend.completedCollections > before && !harness.session.refreshInFlight) {
            turn += 1
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        subscription.cancel()
        #expect(publishes >= 1)
        #expect(turns.count == 1, "every change of one refresh lands in the same main-actor turn")
    }

    @Test("A refresh of one cluster never publishes on another")
    func noCrossClusterFanOut() async throws {
        let aire = try SessionHarness(cluster: .aire)
        let calder = try SessionHarness(cluster: .calder)
        try await aire.startAndSettle()
        try await calder.startAndSettle()
        aire.backend.setFallback(.success(makeSnapshot(collectedAt: "2026-10-13T12:00:20Z")))

        let calderPublishes = try await countPublishes(of: calder.session) {
            try await aire.tick()
        }
        #expect(calderPublishes == 0)
        #expect(aire.session.snapshot?.collectedAt == "2026-10-13T12:00:20Z")
    }

    @Test("History grows by one appended line per new point, never by rewriting")
    func historyAppends() async throws {
        let harness = try SessionHarness()
        try await harness.startAndSettle()
        harness.session.flushCacheWrites()
        let url = harness.cache.historyLogURL
        let inode = try #require(fileInode(url))
        let firstSize = try fileSize(url)

        for second in 1...5 {
            harness.backend.setFallback(.success(makeSnapshot(collectedAt: String(format: "2026-10-13T12:01:%02dZ", second))))
            try await harness.tick()
        }
        // The same collection time again adds nothing.
        try await harness.tick()
        harness.session.flushCacheWrites()

        #expect(fileInode(url) == inode, "appended in place, not atomically replaced")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 6)
        #expect(harness.session.history.count == 6)
        let growth = try fileSize(url) - firstSize
        #expect(growth > 0 && growth < firstSize * 6, "about one line per point")
    }

    @Test("SnapshotCache appends history lines and migrates the legacy array")
    func cacheHistoryLog() throws {
        let root = try TemporaryProjectRoot()
        defer { root.remove() }
        try root.write(SnapshotFixtures.legacyHistory, to: ".runtime/clusters/aire/snapshot_history.json")
        let cache = SnapshotCache(projectRoot: root.path, clusterID: .aire)

        let log = cache.loadHistoryLog()
        #expect(log.points.count == 2)
        #expect(log.needsCompaction, "the legacy file must be migrated")

        let snapshot = try decode(ClusterSnapshot.self, from: SnapshotFixtures.calderSnapshot)
        let history = try cache.recordHistory(from: snapshot)
        #expect(history.count == 3)
        #expect(!root.exists(".runtime/clusters/aire/snapshot_history.json"), "migrated into the jsonl log")
        #expect(cache.loadHistory().count == 3)

        // A torn last line costs one point, not the history.
        let handle = try FileHandle(forWritingTo: cache.historyLogURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"collectedAt\": \"2026-".utf8))
        try handle.close()
        #expect(cache.loadHistory().count == 3)
    }

    @Test("A long-running session keeps 24 h of history in bounded memory, and the log keeps the same points")
    func dayOfHistory() async throws {
        let harness = try SessionHarness()
        let formatter = ISO8601DateFormatter()
        // The first refresh collects at 12:00:00; the 25 hours before it
        // are in the log at the 10 s cadence, every point a line.
        let firstRefresh = try #require(formatter.date(from: "2026-10-13T12:00:00Z"))
        func stamp(_ offset: TimeInterval) -> String {
            formatter.string(from: firstRefresh.addingTimeInterval(offset))
        }
        try harness.cache.rewriteHistory((1...9_000).reversed().map {
            TrendPoint(snapshot: makeSnapshot(collectedAt: stamp(-Double($0) * 10)))
        })

        try await harness.startAndSettle()
        harness.session.flushCacheWrites()
        // Thinned on load, and the log compacted to match before the
        // refresh's point was appended.
        #expect(harness.session.history.count == 1_743)
        #expect(harness.cache.loadHistoryLog().lineCount == 1_743)

        for tick in 1...HistoryRetention.passInterval {
            harness.backend.setFallback(.success(makeSnapshot(collectedAt: stamp(Double(tick) * 10))))
            try await harness.tick()
        }
        let history = harness.session.history
        #expect(history.count < 1_743 + HistoryRetention.passInterval, "a retention pass ran")
        let timeline = TrendTimeline(history: history)
        let now = firstRefresh.addingTimeInterval(65)
        #expect(timeline.slice(.day, now: now).coveredSpan > 24 * 3600 - 60)
        #expect(timeline.slice(.day, now: now).gapCount == 0)
        #expect(timeline.slice(.sixHours, now: now).coveredSpan > 6 * 3600 - 60)

        harness.session.flushCacheWrites()
        #expect(harness.cache.loadHistoryLog().points == HistoryRetention.retained(history))
        // Quitting compacts the log to exactly the points retention keeps.
        harness.session.prepareForTermination()
        let log = harness.cache.loadHistoryLog()
        #expect(log.points == HistoryRetention.retained(history))
        #expect(log.lineCount == log.points.count)
    }

    private func fileInode(_ url: URL) -> UInt64? {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            return nil
        }
        return UInt64(info.st_ino)
    }

    private func fileSize(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}
