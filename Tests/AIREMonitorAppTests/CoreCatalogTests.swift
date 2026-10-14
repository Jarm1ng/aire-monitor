import HPCCore
import Foundation
import Testing

// Identities, thresholds and defaults that the app, the menu bar and the
// separate widget process must agree on.

@Suite("Core · cluster identities")
struct CoreClusterIdentityTests {
    @Test("Cluster ids encode as bare strings")
    func idEncoding() throws {
        // Persisted in preferences and runtime paths: the spelling is stable.
        let data = try JSONEncoder().encode([ClusterID.aire, .calder])
        #expect(String(decoding: data, as: UTF8.self) == #"["aire","calder"]"#)
        #expect(try JSONDecoder().decode([ClusterID].self, from: data) == [.aire, .calder])
        #expect(ClusterID("aire") == .aire)
        #expect(ClusterID.calder.description == "calder")
        #expect(ClusterID.calder.id == "calder")
    }

    @Test("AIRE and Calder are known, in display order, and distinguishable")
    func knownIdentities() {
        #expect(ClusterIdentity.known.map(\.id) == [.aire, .calder])
        #expect(ClusterIdentity.known(.aire)?.displayName == "AIRE")
        #expect(ClusterIdentity.known(.calder)?.displayName == "Calder")
        #expect(ClusterIdentity.known(ClusterID("bede")) == nil)
        let identities = ClusterIdentity.known
        #expect(Set(identities.map(\.monogram)).count == identities.count)
        #expect(Set(identities.map { [$0.accentRed, $0.accentGreen, $0.accentBlue] }).count == identities.count)
    }

    @Test("Unknown clusters still get a name, monogram and neutral accent")
    func resolveUnknown() {
        let bede = ClusterIdentity.resolve(ClusterID("bede"))
        #expect(bede.displayName == "Bede")
        #expect(bede.monogram == "B")
        #expect(ClusterIdentity.resolve(ClusterID("bede"), name: "Bede HPC").displayName == "Bede HPC")
        #expect(ClusterIdentity.resolve(ClusterID("bede"), name: "").displayName == "Bede")
        for known in ClusterIdentity.known {
            #expect(bede.accentRed != known.accentRed || bede.accentGreen != known.accentGreen || bede.accentBlue != known.accentBlue)
        }
        // A known id resolves to its catalogued identity whatever name is passed.
        #expect(ClusterIdentity.resolve(.calder, name: "Something else") == .calder)
    }

    @Test("Known clusters sort first in catalog order, then alphabetically")
    func sortOrder() {
        let ids = [ClusterID("bede"), .calder, ClusterID("archer"), .aire]
        let sorted = ids.sorted { ClusterIdentity.sortKey($0) < ClusterIdentity.sortKey($1) }
        #expect(sorted == [.aire, .calder, ClusterID("archer"), ClusterID("bede")])
    }
}

@Suite("Core · status tones")
struct CoreStatusToneTests {
    @Test("Usage thresholds: warning from 75 %, critical from 90 %", arguments: [
        (nil as Double?, StatusTone.unavailable),
        (0, .normal),
        (62.4, .normal),
        (74.99, .normal),
        (75, .warning),
        (87.98, .warning),
        (89.999, .warning),
        (90, .critical),
        (90.5, .critical),
        (130, .critical)
    ])
    func thresholds(percent: Double?, expected: StatusTone) {
        #expect(StatusTone(usedPercent: percent) == expected)
    }

    @Test("Tones order by severity, with missing data last")
    func ordering() {
        #expect([StatusTone.unavailable, .critical, .normal, .warning].sorted() == [.normal, .warning, .critical, .unavailable])
    }

    @Test("Fixture storage rows land on the expected tones")
    func fixtureStorage() {
        let tones = (CoreFixtures.aireStorage + CoreFixtures.calderStorage).map { StatusTone(usedPercent: $0.usedPercent) }
        // AIRE home 68.5 %, AIRE scratch 88 %, Calder home 68.5 %, scratch 90.5 %, flash 62.4 %.
        #expect(tones == [.normal, .warning, .normal, .critical, .normal])
    }
}

@Suite("Core · storage kinds and rows")
struct CoreStorageTests {
    @Test("Each kind has its own icon")
    func icons() {
        let kinds: [StorageKind] = [.home, .scratch, .flash, .other]
        #expect(Set(kinds.map(\.systemImage)).count == kinds.count)
    }

    @Test("A row's kind comes from its label")
    func rowKind() {
        #expect(CoreFixtures.calderStorage.map(\.kind) == [.home, .scratch, .flash])
        #expect(CoreFixtures.calderSnapshot.sortedStorage.map(\.label) == ["Home", "Scratch", "Flash"])
    }

    @Test("Unreadable rows explain why", arguments: [
        ("missing" as String?, "Not readable — no directory found", "None of the configured directories"),
        ("no-figures", "Usage could not be read this refresh", "the filesystem may be slow"),
        ("not-collected", "Usage could not be read this refresh", "collection budget ran out"),
        (nil, "Usage could not be read this refresh", "collection budget ran out")
    ])
    func unavailableText(reason: String?, caption: String, helpFragment: String) {
        let row = StorageSummary(label: "Flash", source: "unavailable", unavailableReason: reason)
        #expect(row.unavailableCaption == caption)
        #expect(row.unavailableHelp.contains(helpFragment))
    }
}

@Suite("Core · shared defaults")
struct CoreDefaultsTests {
    @Test("Watchdogs always outlast the budgets they guard")
    func watchdogs() {
        // A healthy collection or login must never be killed by its caller.
        #expect(HPCDefaults.collectorWatchdog > TimeInterval(HPCDefaults.collectorTimeout))
        #expect(HPCDefaults.loginWatchdog > TimeInterval(HPCDefaults.loginPromptTimeout))
    }

    @Test("Refresh cadence and staleness thresholds are consistent")
    func cadence() {
        #expect(HPCDefaults.refreshInterval > 0)
        #expect(HPCDefaults.refreshInterval <= HPCDefaults.maximumRefreshInterval)
        // A snapshot refreshed on schedule must never look stale…
        #expect(HPCDefaults.snapshotStaleAfter > HPCDefaults.refreshInterval)
        // …and "old" (red) comes well after "stale".
        #expect(HPCDefaults.snapshotOldAfter > HPCDefaults.snapshotStaleAfter)
    }

    @Test("Jump host and Duo choice")
    func loginDefaults() {
        #expect(HPCDefaults.jumpHostname == "rash.leeds.ac.uk")
        #expect(HPCDefaults.duoOption == "1")
    }
}
