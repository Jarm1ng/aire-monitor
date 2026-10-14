import Foundation
import HPCCore
import Testing
@testable import AIREMonitorApp

/// The collector (`scripts/hpc_snapshot.py`) and the Swift decoders are the
/// two ends of one schema, written in two languages. These tests pin that
/// contract from the Swift side:
///
/// - `Tests/Fixtures/collector_snapshot.json` is the collector's REAL output
///   for a canned Calder refresh (job array remainder beside its running
///   tasks, an idle GPU node, a node without GPU TRES, an NHC reason with a
///   '|', NFS and Lustre-project quotas). The Python suite regenerates it
///   and fails when the checked-in copy is stale, so any change to the
///   collector's output has to pass through this file.
/// - `Tests/Fixtures/collector_contract.json` records the collector's
///   constants that must equal `HPCDefaults` / the cluster catalogue.
///
/// Decoding is lossy by design (one odd element must not discard a
/// snapshot), so "it decodes" proves little: the tests also check that no
/// element was skipped and that every field the collector emits survives a
/// decode/encode round trip with its value intact. A field the app does not
/// decode yet must be listed in `notYetDecoded` with a reason.
///
/// The fixtures live outside the test target (no SwiftPM resources) and are
/// read relative to this source file.
@Suite("Collector contract")
struct CollectorContractTests {
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // AIREMonitorAppTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent()

    static func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: repositoryRoot.appendingPathComponent("Tests/Fixtures/\(name)"))
    }

    static func decodedFixture() throws -> ClusterSnapshot {
        try JSONDecoder().decode(ClusterSnapshot.self, from: fixtureData("collector_snapshot.json"))
    }

    static func rawFixture() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: fixtureData("collector_snapshot.json")) as? [String: Any])
    }

    /// Keys the collector emits that HPCCore does not decode (yet). Anything
    /// else that does not survive the round trip fails the test.
    static let notYetDecoded: [String: Set<String>] = [:]

    @Test("the fixture decodes without skipping or warning about anything")
    func decodesCompletely() throws {
        let snapshot = try Self.decodedFixture()
        let raw = try Self.rawFixture()

        #expect(snapshot.schemaVersion == ClusterSnapshot.supportedSchemaVersion)
        #expect(snapshot.cluster == SnapshotClusterInfo(id: "calder", name: "Calder"))
        #expect(snapshot.errors.isEmpty)
        // Lossy decoding reports skipped elements (and a newer schema) here.
        #expect(snapshot.warnings.isEmpty, "decode notes: \(snapshot.warnings)")
        for (key, decodedCount) in [
            ("jobs", snapshot.jobs.count),
            ("partitions", snapshot.partitions.count),
            ("nodes", snapshot.nodes.count),
            ("storage", snapshot.storage?.count ?? -1),
        ] {
            let rawCount = (raw[key] as? [Any])?.count
            #expect(rawCount == decodedCount, "\(key): \(String(describing: rawCount)) emitted, \(decodedCount) decoded")
            #expect(decodedCount > 0, "the fixture should exercise \(key)")
        }
    }

    @Test("every emitted field survives a decode/encode round trip")
    func everyFieldIsDecoded() throws {
        let raw = try Self.rawFixture()
        let encoder = JSONEncoder()
        let reencoded = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(Self.decodedFixture())) as? [String: Any]
        )

        var problems: [String] = []
        compare(raw, reencoded, kind: "snapshot", path: "snapshot", problems: &problems, skipping: [
            "jobs", "partitions", "nodes", "storage",
        ])
        for key in ["jobs", "partitions", "nodes", "storage"] {
            let rawElements = raw[key] as? [[String: Any]] ?? []
            let decodedElements = reencoded[key] as? [[String: Any]] ?? []
            guard rawElements.count == decodedElements.count else {
                problems.append("\(key): \(rawElements.count) emitted, \(decodedElements.count) re-encoded")
                continue
            }
            for (index, (rawElement, decodedElement)) in zip(rawElements, decodedElements).enumerated() {
                compare(rawElement, decodedElement, kind: key, path: "\(key)[\(index)]", problems: &problems)
            }
        }
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test("a pending array remainder is one row standing for its queued tasks")
    func arrayRemainder() throws {
        let jobs = Dictionary(uniqueKeysWithValues: try Self.decodedFixture().jobs.map { ($0.jobId, $0) })

        let remainder = try #require(jobs["35796"])
        #expect(remainder.isArrayRemainder)
        #expect(remainder.arrayJobID == 35796)
        #expect(remainder.arrayPendingTasks == "3-58")
        #expect(remainder.arrayThrottle == 4)
        #expect(remainder.displayJobID == "35796_[3-58]")
        #expect(remainder.taskMultiplicity == 56)
        // One GPU per task, 56 tasks queued.
        #expect(remainder.requestedGPUCount == 56)
        #expect(remainder.jobState.isPending)

        let task = try #require(jobs["35796_1"])
        #expect(task.arrayJobID == 35796)
        #expect(!task.isArrayRemainder)
        #expect(task.taskMultiplicity == 1)
        #expect(task.jobState.isRunning)

        let plain = try #require(jobs["40188"])
        #expect(plain.arrayJobID == nil)
        #expect(!plain.isArrayRemainder)
        #expect(plain.requestedGPUCount == 1)
        #expect(Set(jobs.keys) == ["40188", "35796_1", "35796_2", "35796", "9918"])
    }

    @Test("GPU figures mean the same on both sides")
    func gpuSemantics() throws {
        let nodes = try Self.decodedFixture().nodes
        let byName = Dictionary(uniqueKeysWithValues: nodes.map { ($0.node, $0) })

        // The two gres parsers agree, including '(S:0,2)' socket lists.
        for node in nodes {
            if let total = node.gpuTotal {
                #expect(slurmGPUTotal(from: node.gres) == total, "\(node.node): gres \(node.gres)")
            }
        }
        // An idle node's empty AllocTRES is 0 in use, not unknown.
        let idle = try #require(byName["calder-h200-02"])
        #expect(idle.knownGPUAllocated == 0)
        #expect(gpuIdle(idle) == 8)
        // No GPU TRES at all: unknown, never counted as idle.
        let unaccounted = try #require(byName["calder-l40-01"])
        #expect(unaccounted.gpuCount == 4)
        #expect(unaccounted.knownGPUAllocated == nil)
        // A '|' inside the Reason keeps the node.
        #expect(byName["calder-h200-05"]?.reason == "NHC: check_cmd_output: 'nvidia-smi -L | wc -l' returned 7")

        let fleet = GPUFleet(nodes: nodes)
        let h200 = try #require(fleet.pools.first { $0.model == "H200" })
        #expect(h200.total == 24)
        #expect(h200.allocated == 5)
        #expect(h200.idle == 11)
        #expect(h200.unavailable == 8)
        #expect(h200.unknown == 0)
        #expect(fleet.hasUnknownAllocation)
    }

    @Test("collector constants match HPCDefaults and the cluster catalogue")
    func constantsAgree() throws {
        let data = try Self.fixtureData("collector_contract.json")
        let contract = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(contract["schema_version"] as? Int == ClusterSnapshot.supportedSchemaVersion)
        #expect(contract["default_timeout"] as? Int == HPCDefaults.collectorTimeout)
        #expect(contract["default_jump_hostname"] as? String == HPCDefaults.jumpHostname)

        let clusters = try #require(contract["known_clusters"] as? [String: [String: String]])
        #expect(Set(clusters.keys) == Set(ClusterIdentity.known.map(\.id.rawValue)))
        for identity in ClusterIdentity.known {
            let entry = clusters[identity.id.rawValue]
            #expect(entry?["name"] == identity.displayName, "\(identity.id)")
            #expect(entry?["hostname"] == catalogProfile(identity.id).defaultHostname, "\(identity.id)")
        }

        // Each unavailable reason the collector can emit has its own wording.
        let reasons = try #require(contract["storage_unavailable_reasons"] as? [String])
        let help = Set(reasons.map { StorageSummary(label: "Scratch", unavailableReason: $0).unavailableHelp })
        #expect(help.count == reasons.count, "some reasons share a fallback explanation: \(reasons)")

        // The app's --timeout is the shared constant and stays below the
        // watchdog that kills the collector.
        for id in catalogIDs {
            let arguments = MonitorService.collectorArguments(settings: makeSettings(catalogProfile(id)))
            let timeout = try #require(value(after: "--timeout", in: arguments).flatMap { Int($0) })
            #expect(timeout == HPCDefaults.collectorTimeout)
            #expect(TimeInterval(timeout) < HPCDefaults.collectorWatchdog)
        }
    }

    /// The fixtures above are only worth something while they are what the
    /// collector prints today. The collector's own suite checks that
    /// (`ContractFixtureTests` in scripts/tests/test_snapshot.py); running
    /// just that part here (a fraction of a second, no ssh, nothing written)
    /// means a plain `run_tests.sh` also catches a collector change whose
    /// fixture was not regenerated. The full Python suite runs through
    /// scripts/test_all.sh and CI.
    @Test("the fixtures are what the collector prints today")
    func fixturesAreCurrent() throws {
        let python = "/usr/bin/python3"
        try #require(FileManager.default.isExecutableFile(atPath: python), "\(python) is required by the app")
        let script = Self.repositoryRoot.appendingPathComponent("scripts/tests/test_snapshot.py").path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-I", script, "-k", "ContractFixtureTests"]
        process.currentDirectoryURL = Self.repositoryRoot
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()

        // Read before waiting so a chatty failure cannot fill the pipe and
        // deadlock; the watchdog bounds a wedged run.
        let watchdog = DispatchWorkItem { [process] in
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        let text = String(decoding: data, as: UTF8.self)
        #expect(process.terminationReason == .exit && process.terminationStatus == 0,
                "\(text.suffix(4000))\nRegenerate with: python3 scripts/tests/test_snapshot.py --write-fixture")
        // A filter that matched nothing would "pass" with zero tests.
        #expect(!text.contains("Ran 0 tests"), "no fixture test ran:\n\(text.suffix(2000))")
    }

    // MARK: - Helpers

    /// Records every key `raw` has (non-null) that `decoded` lacks or holds
    /// a different value for, except the known not-yet-decoded keys.
    private func compare(
        _ raw: [String: Any],
        _ decoded: [String: Any],
        kind: String,
        path: String,
        problems: inout [String],
        skipping: Set<String> = []
    ) {
        let ignored = (Self.notYetDecoded[kind] ?? []).union(skipping)
        for (key, value) in raw.sorted(by: { $0.key < $1.key }) where !(value is NSNull) && !ignored.contains(key) {
            guard let decodedValue = decoded[key] else {
                problems.append("\(path).\(key): emitted by the collector but not decoded by HPCCore")
                continue
            }
            if !(value as AnyObject).isEqual(decodedValue) {
                problems.append("\(path).\(key): emitted \(value), decoded \(decodedValue)")
            }
        }
    }
}
