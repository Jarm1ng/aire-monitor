import HPCCore
import Foundation
import Testing

// The snapshot schema is decoded leniently: one odd job, node or field must
// never discard the whole snapshot (which the app would show as a lost
// connection), and anything skipped is reported in `warnings`.

@Suite("Core · lenient snapshot decoding")
struct CoreSnapshotSchemaTests {
    private func snapshot(_ body: String) throws -> ClusterSnapshot {
        try JSONDecoder().decode(ClusterSnapshot.self, from: Data(body.utf8))
    }

    @Test("A malformed job is skipped and reported; the rest survive")
    func malformedJob() throws {
        let decoded = try snapshot("""
        {"collected_at": "2026-10-13T11:49:45+00:00",
         "jobs": [
           {"job_id": "1", "state": "RUNNING"},
           {"state": "PENDING"},
           {"job_id": "3", "state": "PENDING"}
         ],
         "partitions": [], "nodes": [], "errors": []}
        """)
        #expect(decoded.jobs.map(\.jobId) == ["1", "3"])
        #expect(decoded.warnings == ["Skipped 1 malformed job in the snapshot"])
    }

    @Test("Several malformed elements are counted per section")
    func malformedElements() throws {
        let decoded = try snapshot("""
        {"collected_at": "x",
         "jobs": [],
         "partitions": [{"partition": "gpu"}, {"availability": "up"}],
         "nodes": [{"node": "gpu001"}, 7, {"state": "idle"}],
         "storage": [{"path": "/x"}],
         "errors": [], "warnings": ["node_power: no CurrentWatts"]}
        """)
        #expect(decoded.partitions.map(\.partition) == ["gpu"])
        #expect(decoded.nodes.map(\.node) == ["gpu001"])
        #expect(decoded.storage?.isEmpty == true)
        #expect(decoded.warnings == [
            "node_power: no CurrentWatts",
            "Skipped 1 malformed partition row in the snapshot",
            "Skipped 2 malformed nodes in the snapshot",
            "Skipped 1 malformed storage row in the snapshot"
        ])
    }

    @Test("Wrong-typed peripheral fields fall back to neutral values")
    func wrongTypes() throws {
        let decoded = try snapshot("""
        {"collected_at": 12,
         "remote": "login1",
         "jobs": [{"job_id": "1", "state": 5, "num_cpus": "eight", "nodes": null, "array_throttle": "x"}],
         "partitions": [{"partition": "gpu", "node_count": "many", "time_limit": 3}],
         "nodes": [{"node": "gpu001", "partitions": "gpu", "cpu_load": "high", "gpu_total": 3}],
         "errors": "boom"}
        """)
        #expect(decoded.collectedAt == "")
        #expect(decoded.remote == RemoteInfo())
        let job = try #require(decoded.jobs.first)
        #expect(job.state == "")
        #expect(job.numCpus == nil)
        #expect(job.nodes == "")
        #expect(job.arrayThrottle == nil)
        let partition = try #require(decoded.partitions.first)
        #expect(partition.nodeCount == nil)
        #expect(partition.timeLimit == nil)
        let node = try #require(decoded.nodes.first)
        #expect(node.partitions.isEmpty)
        #expect(node.cpuLoad == nil)
        #expect(node.gpuTotal == 3)
        #expect(decoded.errors.isEmpty)
        #expect(decoded.warnings.isEmpty)
    }

    @Test("Missing or null sections decode as empty")
    func missingSections() throws {
        let decoded = try snapshot(#"{"collected_at": "x", "jobs": null, "storage": null}"#)
        #expect(decoded.jobs.isEmpty)
        #expect(decoded.partitions.isEmpty)
        #expect(decoded.nodes.isEmpty)
        #expect(decoded.storage == nil)
        #expect(decoded.schemaVersion == nil)
        #expect(decoded.cluster == nil)
        #expect(decoded.warnings.isEmpty)
    }

    @Test("A newer schema is a warning, never a failure", arguments: [
        (nil as Int?, false), (1, false), (2, true)
    ])
    func schemaVersion(version: Int?, warns: Bool) throws {
        let versionField = version.map { #""schema_version": \#($0), "# } ?? ""
        let decoded = try snapshot(#"{\#(versionField)"collected_at": "x", "jobs": [{"job_id": "1"}]}"#)
        #expect(decoded.schemaVersion == version)
        #expect(decoded.jobs.count == 1)
        #expect(decoded.warnings.contains { $0.contains("newer than this app understands") } == warns)
    }

    @Test("Job-array fields decode (collector schema 1)")
    func arrayFields() throws {
        let decoded = try snapshot("""
        {"schema_version": 1, "collected_at": "x",
         "jobs": [
           {"job_id": "8248307", "state": "PENDING", "array_job_id": 8248307,
            "array_pending_tasks": "2-58", "array_throttle": 4, "pending_task_count": 57},
           {"job_id": "8248307_0", "state": "RUNNING", "array_job_id": 8248307,
            "array_pending_tasks": null, "array_throttle": null}
         ]}
        """)
        let remainder = try #require(decoded.jobs.first)
        #expect(remainder.arrayJobID == 8248307)
        #expect(remainder.arrayPendingTasks == "2-58")
        #expect(remainder.arrayThrottle == 4)
        #expect(remainder.pendingTaskCount == 57)
        #expect(remainder.isArrayRemainder)
        #expect(remainder.displayJobID == "8248307_[2-58]")

        let task = try #require(decoded.jobs.last)
        #expect(task.arrayJobID == 8248307)
        #expect(task.arrayPendingTasks == nil)
        #expect(!task.isArrayRemainder)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.warnings.isEmpty)
    }

    @Test("The fixture snapshots survive an encode/decode round trip", arguments: [ClusterID.aire, .calder])
    func roundTrip(id: ClusterID) throws {
        // The app re-encodes snapshots into latest_snapshot.json, which the
        // widget decodes again: nothing may be lost or renamed on the way.
        let original = try #require(CoreFixtures.snapshot(for: id))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ClusterSnapshot.self, from: data)
        #expect(decoded == original)

        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["schema_version"] as? Int == ClusterSnapshot.supportedSchemaVersion)
        #expect(json["collected_at"] as? String == original.collectedAt)
    }

    @Test("Job and node ids are their Slurm names")
    func identifiers() {
        #expect(CoreFixtures.aireJobs.map(\.id) == CoreFixtures.aireJobs.map(\.jobId))
        #expect(CoreFixtures.calderNodes.first?.id == "calder-h200-01")
        let ids = CoreFixtures.calderPartitions.map(\.id)
        #expect(Set(ids).count == ids.count, "sinfo rows of one partition stay distinct")
    }
}
