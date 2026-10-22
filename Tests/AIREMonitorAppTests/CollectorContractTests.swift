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
        let script = Self.repositoryRoot.appendingPathComponent("scripts/tests/test_snapshot.py").path
        let run = try Self.runSystemPython([script, "-k", "ContractFixtureTests"])

        #expect(run.succeeded,
                "\(run.output.suffix(4000))\nRegenerate with: python3 scripts/tests/test_snapshot.py --write-fixture")
        // A filter that matched nothing would "pass" with zero tests.
        #expect(!run.output.contains("Ran 0 tests"), "no fixture test ran:\n\(run.output.suffix(2000))")
    }

    /// Three apps describe the same clusters. The macOS app sends each
    /// profile's storage as `--storage-spec`; the Windows and Linux app
    /// (desktop/) never sees the Swift profiles: it imports the collector
    /// and takes its storage specs from `AIRE_SPEC`/`CALDER_SPEC` (one
    /// `<ID>_SPEC` per cluster) and its cluster names and login hosts from
    /// `KNOWN_CLUSTER_NAMES`/`KNOWN_CLUSTER_HOSTNAMES`, which
    /// desktop/tests/test_core.py pins. So all three agree exactly when the
    /// collector's tables equal the catalogue, which is what this checks,
    /// against the module itself rather than a fixture: a spec edited on one
    /// side only fails here, with the cluster named.
    ///
    /// Both specs are compared after the collector's own `parse_storage_spec`
    /// (which fills in defaults such as `"optional": false`): that is what
    /// the remote script is built from, so "equal" means "probes the same
    /// paths with the same quota method". Running the app's real argument
    /// through it also proves the collector reads every key the Swift
    /// encoder writes.
    @Test("the collector's storage specs, names and hosts (the desktop app's) equal the catalogue")
    func desktopClusterTablesAgree() throws {
        var sent: [String: String] = [:]
        for id in catalogIDs {
            let arguments = MonitorService.collectorArguments(settings: makeSettings(catalogProfile(id)))
            sent[id.rawValue] = try #require(value(after: "--storage-spec", in: arguments))
        }
        let sentJSON = try #require(String(data: JSONSerialization.data(withJSONObject: sent), encoding: .utf8))
        let collector = Self.repositoryRoot.appendingPathComponent("scripts/hpc_snapshot.py").path

        let run = try Self.runSystemPython(["-c", Self.clusterTablesScript, collector, sentJSON])
        try #require(run.succeeded, "\(run.output.suffix(4000))")
        // The JSON is the last line; anything Python printed to stderr
        // first (a warning, say) is not part of it.
        let json = try #require(run.output.split(separator: "\n").last, "no output")
        let tables = try JSONDecoder().decode(CollectorClusterTables.self, from: Data(json.utf8))

        #expect(Set(tables.knownIDs) == Set(catalogIDs.map(\.rawValue)),
                "KNOWN_CLUSTER_NAMES in scripts/hpc_snapshot.py lists \(tables.knownIDs)")
        for id in catalogIDs {
            let profile = catalogProfile(id)
            let constant = "\(id.rawValue.uppercased())_SPEC"
            let entry = try #require(tables.clusters[id.rawValue], "\(id)")
            #expect(entry.collector.error == nil, "scripts/hpc_snapshot.py \(constant): \(entry.collector.error ?? "")")
            #expect(entry.collector.volumes == profile.storage,
                    "scripts/hpc_snapshot.py \(constant) differs from ClusterProfile.\(id.rawValue).storage")
            #expect(entry.sent.error == nil, "the app's --storage-spec for \(id): \(entry.sent.error ?? "")")
            #expect(entry.sent.volumes == profile.storage,
                    "the collector reads the app's --storage-spec for \(id) differently from the profile")
            #expect(entry.name == profile.displayName, "KNOWN_CLUSTER_NAMES[\(id.rawValue)]")
            #expect(entry.hostname == profile.defaultHostname, "KNOWN_CLUSTER_HOSTNAMES[\(id.rawValue)]")
        }
    }

    /// argv: the collector's path, then a JSON object of cluster id -> the
    /// `--storage-spec` the app sends. Prints `CollectorClusterTables` JSON
    /// on one line.
    /// Standard library only, and Python 3.9 (the Mac's /usr/bin/python3).
    private static let clusterTablesScript = #"""
        import importlib.util, json, sys

        path, sent = sys.argv[1], json.loads(sys.argv[2])
        spec = importlib.util.spec_from_file_location("hpc_snapshot", path)
        hs = importlib.util.module_from_spec(spec)
        sys.modules["hpc_snapshot"] = hs  # dataclasses resolve annotations through it
        spec.loader.exec_module(hs)

        def parsed(text):
            if not isinstance(text, str):
                return {"error": "missing"}
            volumes, error = hs.parse_storage_spec(text)
            if error:
                return {"error": error}
            return {"volumes": [{"label": v.label, "paths": list(v.paths), "quota": v.quota,
                                 "optional": v.optional} for v in volumes]}

        clusters = {
            cluster_id: {
                "collector": parsed(getattr(hs, cluster_id.upper() + "_SPEC", None)),
                "sent": parsed(spec_text),
                "name": hs.KNOWN_CLUSTER_NAMES.get(cluster_id),
                "hostname": hs.KNOWN_CLUSTER_HOSTNAMES.get(cluster_id),
            }
            for cluster_id, spec_text in sent.items()
        }
        print(json.dumps({"clusters": clusters, "known_ids": sorted(hs.KNOWN_CLUSTER_NAMES)}))
        """#

    private struct CollectorClusterTables: Decodable {
        struct Spec: Decodable {
            let volumes: [StorageVolumeSpec]?
            let error: String?
        }

        struct Cluster: Decodable {
            let collector: Spec
            let sent: Spec
            let name: String?
            let hostname: String?
        }

        let clusters: [String: Cluster]
        let knownIDs: [String]

        enum CodingKeys: String, CodingKey {
            case clusters
            case knownIDs = "known_ids"
        }
    }

    // MARK: - Helpers

    /// Runs the Mac's /usr/bin/python3 (the interpreter the app runs the
    /// collector with) isolated (`-I`: no user site, no PYTHON* variables, no
    /// current directory on sys.path) from the repository root, with
    /// `arguments` after `-I`. stdout and stderr are combined.
    private static func runSystemPython(_ arguments: [String]) throws -> (succeeded: Bool, output: String) {
        let python = "/usr/bin/python3"
        try #require(FileManager.default.isExecutableFile(atPath: python), "\(python) is required by the app")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-I"] + arguments
        process.currentDirectoryURL = repositoryRoot
        // Without xcrun's SDKROOT, which sends /usr/bin/python3 through
        // xcodebuild on a Mac with full Xcode (see FileScriptTests).
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SDKROOT")
        process.environment = environment
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

        let succeeded = process.terminationReason == .exit && process.terminationStatus == 0
        return (succeeded, String(decoding: data, as: UTF8.self))
    }

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
