import Foundation
import Testing
@testable import AIREMonitorApp

/// Exactly what the single-cluster release wrote to
/// `.runtime/connection_profile.json` (synthesized Codable of its
/// `ConnectionProfile`), parameterised on the fields migration reads.
private func legacyConnectionProfile(
    useJumpHost: Bool,
    useSSHAlias: Bool = false,
    aireHostname: String = "aire.leeds.ac.uk",
    jumpHostname: String = "rash.leeds.ac.uk"
) -> String {
    """
    {
      "updatedAt": "2026-10-11T21:00:00Z",
      "useSSHAlias": \(useSSHAlias),
      "sshAlias": "aire",
      "username": "\(testUsername)",
      "aireHostname": "\(aireHostname)",
      "useJumpHost": \(useJumpHost),
      "jumpHostname": "\(jumpHostname)",
      "controlPath": "/Users/someone/.ssh/ctl/aire-ad0d6854d832.sock",
      "jumpControlPath": ""
    }
    """
}

private let legacyCacheFiles = ["latest_snapshot.json", "snapshot_history.json", "job_state.json"]

private let legacyJobState = """
{"updatedAt": "2026-10-11T21:14:03Z", "jobs": {"4410921": {"jobId": "4410921", "name": "train-l40s", "partition": "gpu", "state": "RUNNING", "lastSeenAt": "2026-10-11T21:14:03Z"}}}
"""

/// Seeds a project root with a complete pre-multi-cluster `.runtime/`.
private func seedLegacyInstallation(in root: TemporaryProjectRoot, useJumpHost: Bool = true) throws {
    try root.write(legacyConnectionProfile(useJumpHost: useJumpHost), to: ".runtime/connection_profile.json")
    try root.write(SnapshotFixtures.legacyAIRESnapshot, to: ".runtime/latest_snapshot.json")
    try root.write(SnapshotFixtures.legacyHistory, to: ".runtime/snapshot_history.json")
    try root.write(legacyJobState, to: ".runtime/job_state.json")
}

@Suite("PreferencesStore")
struct PreferencesStoreTests {
    @Test("First launch migrates a single-cluster installation")
    func migratesLegacyInstallation() throws {
        let root = try TemporaryProjectRoot()
        defer { root.remove() }
        try seedLegacyInstallation(in: root)
        let originalSnapshot = try root.contents(of: ".runtime/latest_snapshot.json")

        let preferences = PreferencesStore(projectRoot: root.path).load()

        #expect(preferences.route == .rashJump)
        #expect(preferences.username == testUsername)
        #expect(preferences.jumpHostname == "rash.leeds.ac.uk")
        let aire = try #require(preferences.clusters[ClusterID.aire.rawValue])
        #expect(aire.hostname == "aire.leeds.ac.uk")
        #expect(aire.enabled)
        // Calder did not exist before the upgrade: no stored preference, so
        // the session falls back to the profile default.
        #expect(preferences.clusters[ClusterID.calder.rawValue] == nil)

        // The single-cluster cache belonged to AIRE, the only cluster then.
        for name in legacyCacheFiles {
            #expect(!root.exists(".runtime/\(name)"), "\(name) should have moved")
            #expect(root.exists(".runtime/clusters/aire/\(name)"), "\(name) should be in clusters/aire")
            #expect(!root.exists(".runtime/clusters/calder/\(name)"), "\(name) must not leak into Calder")
        }
        #expect(try root.contents(of: ".runtime/clusters/aire/latest_snapshot.json") == originalSnapshot)

        // The migrated files are readable through the per-cluster cache.
        let cache = SnapshotCache(projectRoot: root.path, clusterID: .aire)
        #expect(cache.loadLatestSnapshot()?.jobs.first?.jobId == "4410921")
        #expect(cache.loadHistory().count == 2)
        #expect(cache.loadJobStateSnapshot()?.jobs["4410921"]?.state == "RUNNING")
    }

    @Test("A second load is idempotent")
    func secondLoadIsIdempotent() throws {
        let root = try TemporaryProjectRoot()
        defer { root.remove() }
        try seedLegacyInstallation(in: root)
        let store = PreferencesStore(projectRoot: root.path)

        let first = store.load()
        let migratedHistory = try root.contents(of: ".runtime/clusters/aire/snapshot_history.json")
        let second = store.load()

        #expect(second.route == first.route)
        #expect(second.username == first.username)
        #expect(second.jumpHostname == first.jumpHostname)
        #expect(second.clusters[ClusterID.aire.rawValue]?.hostname == first.clusters[ClusterID.aire.rawValue]?.hostname)
        #expect(try root.contents(of: ".runtime/clusters/aire/snapshot_history.json") == migratedHistory)
        for name in legacyCacheFiles {
            #expect(root.exists(".runtime/clusters/aire/\(name)"))
            #expect(!root.exists(".runtime/clusters/aire/\(name).bad"))
        }
    }

    @Test("Migration never overwrites a per-cluster cache that already exists")
    func migrationDoesNotClobber() throws {
        let root = try TemporaryProjectRoot()
        defer { root.remove() }
        try seedLegacyInstallation(in: root)
        try root.write(SnapshotFixtures.calderSnapshot, to: ".runtime/clusters/aire/latest_snapshot.json")

        _ = PreferencesStore(projectRoot: root.path).load()

        #expect(try root.contents(of: ".runtime/clusters/aire/latest_snapshot.json") == SnapshotFixtures.calderSnapshot)
        // The legacy file is left in place rather than destroyed.
        #expect(root.exists(".runtime/latest_snapshot.json"))
        // Files without a counterpart still move.
        #expect(root.exists(".runtime/clusters/aire/job_state.json"))
        #expect(!root.exists(".runtime/job_state.json"))
    }

    @Test("Legacy direct and alias profiles migrate to the direct route")
    func legacyDirectAndAliasRoutes() throws {
        for (useJumpHost, useSSHAlias) in [(false, false), (true, true), (false, true)] {
            let root = try TemporaryProjectRoot()
            defer { root.remove() }
            try root.write(
                legacyConnectionProfile(useJumpHost: useJumpHost, useSSHAlias: useSSHAlias),
                to: ".runtime/connection_profile.json"
            )
            let preferences = PreferencesStore(projectRoot: root.path).load()
            #expect(preferences.route == .directVPN, "useJumpHost=\(useJumpHost) useSSHAlias=\(useSSHAlias)")
        }
    }

    @Test("A fresh installation loads defaults")
    func freshInstallationDefaults() throws {
        let root = try TemporaryProjectRoot()
        defer { root.remove() }

        let preferences = PreferencesStore(projectRoot: root.path).load()

        #expect(preferences.username == "")
        #expect(preferences.route == .directVPN)
        #expect(preferences.jumpHostname == "rash.leeds.ac.uk")
        #expect(preferences.duoOption == "1")
        #expect(preferences.clusters.isEmpty)
        #expect(preferences.selection == nil)
    }

    @Test("save() then load() round-trips selection and per-cluster settings")
    func saveLoadRoundTrip() throws {
        let root = try TemporaryProjectRoot()
        defer { root.remove() }
        let store = PreferencesStore(projectRoot: root.path)

        var preferences = AppPreferences()
        preferences.username = testUsername
        preferences.route = .rashJump
        preferences.jumpHostname = "rash.leeds.ac.uk"
        preferences.duoOption = "2"
        preferences.selection = SidebarSelection.cluster(.calder).storageKey
        preferences.clusters = [
            ClusterID.aire.rawValue: .init(enabled: false, hostname: "login1.aire.leeds.ac.uk"),
            ClusterID.calder.rawValue: .init(enabled: true, hostname: "calder.leeds.ac.uk")
        ]
        try store.save(preferences)

        let loaded = store.load()
        #expect(loaded.username == testUsername)
        #expect(loaded.route == .rashJump)
        #expect(loaded.duoOption == "2")
        #expect(SidebarSelection(storageKey: loaded.selection) == .cluster(.calder))
        #expect(loaded.clusters[ClusterID.aire.rawValue]?.enabled == false)
        #expect(loaded.clusters[ClusterID.aire.rawValue]?.hostname == "login1.aire.leeds.ac.uk")
        #expect(loaded.clusters[ClusterID.calder.rawValue]?.enabled == true)
        #expect(loaded.clusters[ClusterID.calder.rawValue]?.hostname == "calder.leeds.ac.uk")

        // preferences.json is password-free by construction.
        let json = try root.contents(of: ".runtime/preferences.json")
        #expect(!json.lowercased().contains("password"))
    }

    @Test("preferences.json takes precedence over a leftover legacy profile")
    func preferencesWinOverLegacyProfile() throws {
        let root = try TemporaryProjectRoot()
        defer { root.remove() }
        try root.write(legacyConnectionProfile(useJumpHost: true), to: ".runtime/connection_profile.json")
        var preferences = AppPreferences()
        preferences.username = "abcd1234"
        preferences.route = .directVPN
        try PreferencesStore(projectRoot: root.path).save(preferences)

        let loaded = PreferencesStore(projectRoot: root.path).load()
        #expect(loaded.username == "abcd1234")
        #expect(loaded.route == .directVPN)
    }

    @Test("A corrupt preferences.json is quarantined, not fatal")
    func corruptPreferencesAreQuarantined() throws {
        let root = try TemporaryProjectRoot()
        defer { root.remove() }
        try root.write("{\"username\": \"abcd1234\", \"route\": ", to: ".runtime/preferences.json")

        let preferences = PreferencesStore(projectRoot: root.path).load()

        #expect(preferences.username == "")
        #expect(preferences.route == .directVPN)
        #expect(!root.exists(".runtime/preferences.json"))
        #expect(root.exists(".runtime/preferences.json.bad"))
        // The quarantined copy keeps the original bytes for diagnosis.
        #expect(try root.contents(of: ".runtime/preferences.json.bad").hasPrefix("{\"username\""))
    }

    @Test("Partial or unknown preference values fall back field by field")
    func partialPreferencesDecode() throws {
        let root = try TemporaryProjectRoot()
        defer { root.remove() }
        // A route written by a future build must not wipe the username.
        try root.write(#"{"username": "abcd1234", "route": "teleport"}"#, to: ".runtime/preferences.json")

        let preferences = PreferencesStore(projectRoot: root.path).load()

        #expect(preferences.username == testUsername)
        #expect(preferences.route == .directVPN)
        #expect(preferences.jumpHostname == "rash.leeds.ac.uk")
        #expect(preferences.duoOption == "1")
        #expect(!root.exists(".runtime/preferences.json.bad"))
    }
}

@Suite("SnapshotCache")
struct SnapshotCacheTests {
    @Test("Each cluster has its own cache directory")
    func cachesArePerCluster() throws {
        let root = try TemporaryProjectRoot()
        defer { root.remove() }
        let calderSnapshot = try decode(ClusterSnapshot.self, from: SnapshotFixtures.calderSnapshot)
        let aire = SnapshotCache(projectRoot: root.path, clusterID: .aire)
        let calder = SnapshotCache(projectRoot: root.path, clusterID: .calder)

        #expect(calder.latestSnapshotURL.path == root.clusterDirectory(.calder).appendingPathComponent("latest_snapshot.json").path)

        try calder.saveLatestSnapshot(calderSnapshot)
        _ = try calder.recordHistory(from: calderSnapshot)

        #expect(calder.loadLatestSnapshot()?.cluster?.id == "calder")
        #expect(calder.loadHistory().count == 1)
        // Nothing written for Calder is visible to AIRE.
        #expect(aire.loadLatestSnapshot() == nil)
        #expect(aire.loadHistory().isEmpty)
        #expect(!root.exists(".runtime/latest_snapshot.json"))
    }

    @Test("History is deduplicated by collection time")
    func historyDeduplicates() throws {
        let root = try TemporaryProjectRoot()
        defer { root.remove() }
        let snapshot = try decode(ClusterSnapshot.self, from: SnapshotFixtures.calderSnapshot)
        let cache = SnapshotCache(projectRoot: root.path, clusterID: .calder)

        _ = try cache.recordHistory(from: snapshot)
        let history = try cache.recordHistory(from: snapshot)

        #expect(history.count == 1)
        #expect(cache.loadHistory().count == 1)
    }

    @Test("Job-state baselines are separate per cluster")
    func jobStatesArePerCluster() throws {
        // Slurm job ids are only unique within one controller: AIRE job 101
        // and Calder job 101 are different jobs.
        let root = try TemporaryProjectRoot()
        defer { root.remove() }
        let legacy = try decode(ClusterSnapshot.self, from: SnapshotFixtures.legacyAIRESnapshot)
        let aire = SnapshotCache(projectRoot: root.path, clusterID: .aire)
        let calder = SnapshotCache(projectRoot: root.path, clusterID: .calder)

        try aire.saveJobStates(from: legacy.jobs)

        #expect(aire.loadJobStateSnapshot()?.jobs.keys.sorted() == ["4410921"])
        #expect(calder.loadJobStateSnapshot() == nil)
    }

    @Test("A corrupt snapshot cache is quarantined")
    func corruptSnapshotQuarantined() throws {
        let root = try TemporaryProjectRoot()
        defer { root.remove() }
        try root.write("not json", to: ".runtime/clusters/calder/latest_snapshot.json")
        let cache = SnapshotCache(projectRoot: root.path, clusterID: .calder)

        #expect(cache.loadLatestSnapshot() == nil)
        #expect(root.exists(".runtime/clusters/calder/latest_snapshot.json.bad"))
        #expect(!root.exists(".runtime/clusters/calder/latest_snapshot.json"))
    }

    @Test("collector.json records the exact argv for the widget")
    func collectorInvocationFile() throws {
        let root = try TemporaryProjectRoot()
        defer { root.remove() }
        let settings = makeSettings(.calder, route: .rashJump, projectRoot: root.path)
        let arguments = MonitorService.collectorArguments(settings: settings)
        let cache = SnapshotCache(projectRoot: root.path, clusterID: .calder)

        try cache.saveCollectorArguments(arguments)

        struct Invocation: Decodable {
            let script: String
            let arguments: [String]
        }
        let json = try root.contents(of: ".runtime/clusters/calder/collector.json")
        let invocation = try decode(Invocation.self, from: json)
        #expect(invocation.arguments == arguments)
        #expect(invocation.script == MonitorService.collectorScript)
        // The settings' runtime directory and the cache agree on where the
        // per-cluster files live.
        #expect(settings.runtimeDirectory == root.clusterDirectory(.calder).path)
    }
}
