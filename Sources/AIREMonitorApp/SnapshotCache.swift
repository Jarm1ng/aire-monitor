import HPCCore
import Foundation
import os

// ISO8601DateFormatter is documented as thread-safe; share one instance
// instead of allocating a formatter per call.
nonisolated(unsafe) private let iso8601Formatter = ISO8601DateFormatter()

struct TrendPoint: Codable, Identifiable, Equatable, Sendable {
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
    /// GPUs whose allocation was unknown at this point (node_details failed
    /// or was cut). They are in `gpuTotal` but neither allocated nor idle,
    /// so a point with unknown GPUs must not be drawn as a utilisation
    /// figure. nil in history written before this field existed.
    var gpuUnknown: Int? = nil

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
            Log.cache.error(
                "Failed to decode \(url.lastPathComponent, privacy: .public); moving corrupt file aside: \(String(describing: error), privacy: .public)"
            )
            let quarantineURL = url.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: quarantineURL)
            try? FileManager.default.moveItem(at: url, to: quarantineURL)
            return nil
        }
    }

    /// `pretty` only for small files a person may read or edit
    /// (preferences, collector invocation, the widget lease). Machine-only
    /// files are written compactly: the snapshot is rewritten every refresh.
    static func write<T: Encodable>(_ value: T, to url: URL, pretty: Bool = false) throws {
        let data = try (pretty ? JSONEncoder.prettySorted : JSONEncoder.compact).encode(value)
        try writeData(data, to: url)
    }

    static func writeData(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}

/// Per-cluster cache under `.runtime/clusters/<id>/`. Every cluster has its
/// own snapshot, history and job-state baseline: Slurm job ids are only
/// unique within one cluster, so a shared baseline would mis-fire
/// start/end notifications across clusters.
///
/// All methods are synchronous file operations. The running app calls the
/// writers only through `ClusterCacheWriter` (a serial background queue),
/// never on the main actor during a refresh.
struct SnapshotCache: Sendable {
    /// Lines the append-only history log may hold beyond the points
    /// `HistoryRetention` keeps before it is rewritten: about one rewrite
    /// an hour at the 10 s cadence.
    static let historyCompactionSlack = 360

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

    var appStateURL: URL {
        directoryURL.appendingPathComponent(ClusterAppState.fileName)
    }

    /// Append-only history: one compact TrendPoint per line.
    var historyLogURL: URL {
        directoryURL.appendingPathComponent("snapshot_history.jsonl")
    }

    /// The pre-jsonl history (one pretty-printed array rewritten on every
    /// refresh). Read once and migrated into the log by the first rewrite.
    var legacyHistoryURL: URL {
        directoryURL.appendingPathComponent("snapshot_history.json")
    }

    private var jobStateURL: URL {
        directoryURL.appendingPathComponent("job_state.json")
    }

    private var collectorURL: URL {
        directoryURL.appendingPathComponent("collector.json")
    }

    // MARK: Snapshot

    func loadLatestSnapshot() -> ClusterSnapshot? {
        JSONFile.decodeQuarantining(ClusterSnapshot.self, from: latestSnapshotURL)
    }

    /// Rewritten after every refresh, even when only `collected_at` moved:
    /// the desktop widget shows this file and dates it by its contents.
    func saveLatestSnapshot(_ snapshot: ClusterSnapshot) throws {
        try JSONFile.write(snapshot, to: latestSnapshotURL)
    }

    // MARK: History

    struct HistoryLog: Equatable {
        /// Deduplicated by collection time, oldest first, as
        /// `HistoryRetention` keeps them.
        var points: [TrendPoint]
        /// Lines currently in the jsonl log (what a rewrite would shrink).
        var lineCount: Int
        /// The legacy JSON array exists, or the log holds malformed lines or
        /// more than `historyCompactionSlack` lines retention dropped: the
        /// next write should be a rewrite.
        var needsCompaction: Bool
    }

    func loadHistoryLog() -> HistoryLog {
        let fileManager = FileManager.default
        var points: [TrendPoint] = []
        let hasLegacy = fileManager.fileExists(atPath: legacyHistoryURL.path)
        if hasLegacy {
            points = JSONFile.decodeQuarantining([TrendPoint].self, from: legacyHistoryURL) ?? []
        }
        var lineCount = 0
        var malformed = 0
        if let data = try? Data(contentsOf: historyLogURL) {
            let decoder = JSONDecoder()
            for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
                lineCount += 1
                // A torn last line (crash mid-append) or a hand edit costs
                // one point, never the whole history.
                if let point = try? decoder.decode(TrendPoint.self, from: Data(line)) {
                    points.append(point)
                } else {
                    malformed += 1
                }
            }
        }
        if malformed > 0 {
            Log.cache.error(
                "Skipped \(malformed, privacy: .public) malformed line(s) in \(clusterID.rawValue, privacy: .public)/snapshot_history.jsonl"
            )
        }
        // Dedupe by membership, not just the last entry: a stale collectedAt
        // can reappear non-adjacently after an error gap, and TrendPoint.id
        // is collectedAt, so duplicates would break SwiftUI identity.
        var seen = Set<String>()
        points = HistoryRetention.retained(points.filter { seen.insert($0.collectedAt).inserted })
        return HistoryLog(
            points: points,
            lineCount: lineCount,
            needsCompaction: hasLegacy || malformed > 0 || lineCount > points.count + Self.historyCompactionSlack
        )
    }

    func loadHistory() -> [TrendPoint] {
        loadHistoryLog().points
    }

    /// Appends one point as one line: O(1) per refresh, where the old
    /// format re-read, re-encoded and atomically rewrote ~600 KB every 10 s.
    func appendHistory(_ point: TrendPoint) throws {
        var line = try JSONEncoder.compact.encode(point)
        line.append(UInt8(ascii: "\n"))
        guard FileManager.default.fileExists(atPath: historyLogURL.path) else {
            try JSONFile.writeData(line, to: historyLogURL)
            return
        }
        let handle = try FileHandle(forWritingTo: historyLogURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// Replaces the log with exactly `points` (atomically) and completes a
    /// migration from the legacy JSON array.
    func rewriteHistory(_ points: [TrendPoint]) throws {
        let encoder = JSONEncoder.compact
        var data = Data()
        for point in points {
            data.append(try encoder.encode(point))
            data.append(UInt8(ascii: "\n"))
        }
        try JSONFile.writeData(data, to: historyLogURL)
        if FileManager.default.fileExists(atPath: legacyHistoryURL.path) {
            try FileManager.default.removeItem(at: legacyHistoryURL)
        }
    }

    /// Load-append-return in one call (tests and one-off tools; the app
    /// keeps history in memory and appends through ClusterCacheWriter).
    @discardableResult
    func recordHistory(from snapshot: ClusterSnapshot) throws -> [TrendPoint] {
        let log = loadHistoryLog()
        let point = TrendPoint(snapshot: snapshot)
        guard !log.points.contains(where: { $0.collectedAt == point.collectedAt }) else {
            return log.points
        }
        let history = HistoryRetention.retained(log.points + [point])
        if log.needsCompaction || log.lineCount + 1 > history.count + Self.historyCompactionSlack {
            try rewriteHistory(history)
        } else {
            try appendHistory(point)
        }
        return history
    }

    // MARK: Job states

    func loadJobStateSnapshot() -> JobStateSnapshot? {
        JSONFile.decodeQuarantining(JobStateSnapshot.self, from: jobStateURL)
    }

    func saveJobStates(_ baseline: JobStateSnapshot) throws {
        try JSONFile.write(baseline, to: jobStateURL)
    }

    func saveJobStates(from jobs: [Job]) throws {
        try saveJobStates(JobStateSnapshot(jobs: jobs, observedAt: iso8601Formatter.string(from: Date())))
    }

    // MARK: App state (widget lease)

    func loadAppState() -> ClusterAppState? {
        guard let data = try? Data(contentsOf: appStateURL) else {
            return nil
        }
        return try? JSONDecoder().decode(ClusterAppState.self, from: data)
    }

    func saveAppState(_ state: ClusterAppState) throws {
        try JSONFile.write(state, to: appStateURL, pretty: true)
    }

    func removeAppState() throws {
        guard FileManager.default.fileExists(atPath: appStateURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: appStateURL)
    }

    // MARK: Collector invocation

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
            to: collectorURL,
            pretty: true
        )
    }
}

// MARK: - History retention

/// Which trend points a cluster's history keeps: every point from the
/// newest hour, then the first point of each clock minute back to 24 h
/// (whole minutes), and nothing older. That fills the Trends tab's 24 h
/// window with about
/// 1,740 points (360 + 1,380 at the 10 s cadence), where keeping every
/// point would take 8,640. Ages count back from the newest point, never
/// from the clock, so history read after a week offline still has its
/// full last hour. Memory and the compacted log hold the same points.
enum HistoryRetention {
    /// Points this close to the newest keep full resolution.
    static let fullResolutionSpan: TimeInterval = 3600
    /// Older points keep one per clock minute.
    static let thinnedSpacing: TimeInterval = 60
    /// The longest trend window; older points are dropped.
    static let maximumAge: TimeInterval = 24 * 3600
    /// Hard cap for refreshes far faster than every 10 s: the oldest
    /// points go first.
    static let capacity = 2_000
    /// New points a running session collects between retention passes
    /// (each parses every timestamp): one pass a minute at 10 s.
    static let passInterval = 6

    /// `points` (oldest first) after retention. Idempotent, and stable as
    /// history grows: a thinned minute keeps the same point until the whole
    /// minute ages out, so thinning in batches keeps what thinning on every
    /// append would. Points without a readable time are dropped: no chart
    /// can place them.
    static func retained(_ points: [TrendPoint]) -> [TrendPoint] {
        let dates = points.map(\.collectionDate)
        guard let newest = dates.compactMap({ $0 }).max() else {
            return []
        }
        let thinnedBefore = newest.addingTimeInterval(-fullResolutionSpan)
        let oldestMinute = minute(of: newest.addingTimeInterval(-maximumAge))
        var keptMinutes = Set<Int>()
        var kept: [TrendPoint] = []
        kept.reserveCapacity(min(points.count, capacity))
        for (point, date) in zip(points, dates) {
            guard let date else {
                continue
            }
            if date < thinnedBefore {
                let bucket = minute(of: date)
                guard bucket >= oldestMinute, keptMinutes.insert(bucket).inserted else {
                    continue
                }
            }
            kept.append(point)
        }
        return kept.count > capacity ? Array(kept.suffix(capacity)) : kept
    }

    private static func minute(of date: Date) -> Int {
        Int((date.timeIntervalSince1970 / thinnedSpacing).rounded(.down))
    }
}

extension TrendPoint {
    /// When the point was collected. Retention passes and chart timelines
    /// read every point's time, and ISO8601DateFormatter takes ~50 µs a
    /// stamp (~85 ms for a day of history), so the collector's own form is
    /// read by hand; anything else goes to SlurmTimestamp.parse.
    var collectionDate: Date? {
        CollectorTimestamp.parse(collectedAt) ?? SlurmTimestamp.parse(collectedAt)
    }
}

/// A strict reader for "2026-10-13T11:49:45.636173+00:00": a fraction is
/// optional, the zone ("Z" or ±HH:MM) is not. nil for anything else,
/// out-of-range fields included, so the general parser decides those.
enum CollectorTimestamp {
    static func parse(_ text: String) -> Date? {
        var text = text
        return text.withUTF8(parse(bytes:))
    }

    private static func parse(bytes: UnsafeBufferPointer<UInt8>) -> Date? {
        func number(_ start: Int, _ count: Int) -> Int? {
            guard start + count <= bytes.count else {
                return nil
            }
            var value = 0
            for byte in bytes[start..<start + count] {
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else {
                    return nil
                }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            return value
        }
        guard bytes.count >= 20,
              bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"), bytes[10] == UInt8(ascii: "T"),
              bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"),
              let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2),
              (1...12).contains(month), (1...daysIn(month: month, year: year)).contains(day),
              hour < 24, minute < 60, second < 60 else {
            return nil
        }
        var index = 19
        var fraction = 0.0
        if bytes[index] == UInt8(ascii: ".") {
            index += 1
            var scale = 1.0
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                scale /= 10
                fraction += Double(bytes[index] - UInt8(ascii: "0")) * scale
                index += 1
            }
            guard scale < 1 else {
                return nil
            }
        }
        let offset: Int
        if index + 1 == bytes.count, bytes[index] == UInt8(ascii: "Z") {
            offset = 0
        } else if index + 6 == bytes.count,
                  bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-"),
                  bytes[index + 3] == UInt8(ascii: ":"),
                  let hours = number(index + 1, 2), let minutes = number(index + 4, 2),
                  hours < 24, minutes < 60 {
            offset = (hours * 3600 + minutes * 60) * (bytes[index] == UInt8(ascii: "-") ? -1 : 1)
        } else {
            return nil
        }
        let seconds = daysSince1970(year: year, month: month, day: day) * 86_400
            + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days from 1970-01-01 to a proleptic Gregorian date (Howard
    /// Hinnant's days_from_civil, for years 0 and later).
    private static func daysSince1970(year: Int, month: Int, day: Int) -> Int {
        let year = month <= 2 ? year - 1 : year
        let era = (year >= 0 ? year : year - 399) / 400
        let yearOfEra = year - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}

// MARK: - Preferences

/// Password-free settings persisted in `.runtime/preferences.json`.
struct AppPreferences: Codable, Equatable {
    struct ClusterPreference: Codable, Equatable {
        var enabled: Bool
        var hostname: String
    }

    var username: String = ""
    var route: ConnectionRoute = .directVPN
    var jumpHostname: String = HPCDefaults.jumpHostname
    var duoOption: String = HPCDefaults.duoOption
    /// "Remember in Keychain". Persisted so an opt-out survives relaunch;
    /// files written before it existed decode as true (the old default).
    var rememberPassword: Bool = true
    /// Link the live sessions into ~/.ssh so `ssh aire` and friends ride
    /// them (see SessionSharing.swift).
    var shareSessions: Bool = true
    /// Sign a dropped session in again by itself (AutoReconnectPolicy).
    var reconnectAutomatically: Bool = true
    /// Sample running jobs' GPU, CPU and memory use on their nodes.
    var sampleJobUsage: Bool = true
    /// Keyed by ClusterID.rawValue.
    var clusters: [String: ClusterPreference] = [:]
    /// "overview" or "cluster:<id>".
    var selection: String?

    enum CodingKeys: String, CodingKey {
        case username
        case route
        case jumpHostname
        case duoOption
        // Stored as "rememberInKeychain": preferences.json is password-free
        // by construction, and stays free of the word too.
        case rememberPassword = "rememberInKeychain"
        case shareSessions
        case reconnectAutomatically
        case sampleJobUsage
        case clusters
        case selection
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        route = (try? container.decodeIfPresent(ConnectionRoute.self, forKey: .route)) ?? .directVPN
        jumpHostname = try container.decodeIfPresent(String.self, forKey: .jumpHostname) ?? HPCDefaults.jumpHostname
        duoOption = try container.decodeIfPresent(String.self, forKey: .duoOption) ?? HPCDefaults.duoOption
        rememberPassword = (try? container.decodeIfPresent(Bool.self, forKey: .rememberPassword)) ?? true
        shareSessions = (try? container.decodeIfPresent(Bool.self, forKey: .shareSessions)) ?? true
        reconnectAutomatically = (try? container.decodeIfPresent(Bool.self, forKey: .reconnectAutomatically)) ?? true
        sampleJobUsage = (try? container.decodeIfPresent(Bool.self, forKey: .sampleJobUsage)) ?? true
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
        try JSONFile.write(preferences, to: preferencesURL, pretty: true)
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
                Log.cache.error(
                    "Could not migrate \(name, privacy: .public) into clusters/aire: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }
}

extension TrendPoint {
    init(snapshot: ClusterSnapshot) {
        let fleet = GPUFleet(nodes: snapshot.nodes)
        let storage = snapshot.storage ?? []
        let home = storage.first { $0.kind == .home }
        let scratch = storage.first { $0.kind == .scratch }
        let flash = storage.first { $0.kind == .flash }

        collectedAt = snapshot.collectedAt
        totalJobs = snapshot.jobs.reduce(0) { $0 + $1.taskMultiplicity }
        runningJobs = snapshot.jobs.filter { $0.jobState.isRunning }.count
        pendingJobs = snapshot.jobs.filter { $0.jobState.isPending }.reduce(0) { $0 + $1.taskMultiplicity }
        gpuTotal = fleet.total
        gpuAllocated = fleet.allocated
        // Startable idle GPUs only (same rule as every other surface):
        // nothing on unavailable nodes, stranded GPUs or unknown allocation.
        gpuIdle = fleet.idle
        unavailableGpuNodes = fleet.unavailableNodes
        homeUsedPercent = home?.usedPercent
        scratchUsedPercent = scratch?.usedPercent
        homeAvailableGB = home?.availableGB
        scratchAvailableGB = scratch?.availableGB
        flashUsedPercent = flash?.usedPercent
        flashAvailableGB = flash?.availableGB
        gpuUnknown = fleet.unknown
    }
}

extension JSONEncoder {
    static let prettySorted: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// No whitespace, no key sorting: the cheapest encoding for files only
    /// machines read.
    static let compact: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()
}
