import Foundation
import Testing
@testable import AIREMonitorApp

/// Fixtures mirror real files. The legacy snapshot is what the single-cluster
/// release wrote to `.runtime/latest_snapshot.json` (it is migrated into
/// `.runtime/clusters/aire/` and must still load, or the first launch after
/// the upgrade shows an empty dashboard). The new snapshot is what
/// `scripts/hpc_snapshot.py` prints for Calder.
enum SnapshotFixtures {
    static let legacyAIRESnapshot = """
    {
      "collected_at": "2026-10-11T21:14:03+00:00",
      "remote": {
        "host": "aire",
        "hostname": "login2.aire.lee.alces.network",
        "user": "abcd1234",
        "cwd": "/users/abcd1234",
        "remote_time": "2026-10-11T22:14:03+01:00"
      },
      "jobs": [
        {
          "job_id": "4410921",
          "partition": "gpu",
          "name": "train-l40s",
          "user": "abcd1234",
          "state": "RUNNING",
          "elapsed": "3:02:11",
          "time_limit": "2-00:00:00",
          "nodes": "1",
          "reason_or_node_list": "gpu003"
        }
      ],
      "partitions": [
        {
          "partition": "gpu",
          "availability": "up",
          "node_count": 4,
          "state": "mix",
          "gres": "gpu:l40s:3",
          "cpus_per_node": 168,
          "memory_mb_per_node": 773000,
          "features": "(null)"
        }
      ],
      "nodes": [
        {
          "node": "gpu003",
          "partitions": ["gpu"],
          "state": "mixed",
          "cpu_allocated": 24,
          "cpu_idle": 144,
          "cpu_other": 0,
          "cpu_total": 168,
          "memory_mb": 773000,
          "gres": "gpu:l40s:3(S:0-1)",
          "features": "(null)",
          "reason": "",
          "gpu_total": 3,
          "gpu_allocated": 1,
          "gpu_idle": 2,
          "memory_allocated_mb": 64000,
          "memory_free_mb": 700000,
          "cpu_load": 12.5,
          "current_watts": null,
          "average_watts": null
        }
      ],
      "storage": [
        {
          "label": "Scratch",
          "path": "/mnt/scratch/abcd1234",
          "filesystem": "10.10.0.40@o2ib:/scratch",
          "source": "lfs quota",
          "used_gb": 812.4,
          "quota_gb": 1024.0,
          "limit_gb": 1126.4,
          "available_gb": 211.6,
          "used_percent": 79.3,
          "file_count": 120034,
          "file_quota": null,
          "file_limit": null
        },
        {
          "label": "Home",
          "path": "/users/abcd1234",
          "filesystem": "10.10.0.15:/export/users",
          "source": "quota",
          "used_gb": 41.2,
          "quota_gb": 65.0,
          "limit_gb": 70.0,
          "available_gb": 23.8,
          "used_percent": 63.4,
          "file_count": null,
          "file_quota": null,
          "file_limit": null
        }
      ],
      "errors": []
    }
    """

    static let calderSnapshot = """
    {
      "collected_at": "2026-10-12T09:30:00+00:00",
      "cluster": {"id": "calder", "name": "Calder"},
      "remote": {
        "host": "calder.leeds.ac.uk",
        "hostname": "calder-login-2",
        "user": "abcd1234",
        "cwd": "/users/abcd1234",
        "remote_time": "2026-10-12T10:30:00+01:00"
      },
      "jobs": [],
      "partitions": [
        {
          "partition": "calder-gpu-hopper",
          "availability": "up",
          "node_count": 7,
          "state": "idle",
          "gres": "gpu:nvidia_h200:8",
          "cpus_per_node": 128,
          "memory_mb_per_node": 1546000,
          "features": "(null)",
          "time_limit": "2-00:00:00"
        },
        {
          "partition": "calder-cpu-turin",
          "availability": "up",
          "node_count": 98,
          "state": "idle",
          "gres": "(null)",
          "cpus_per_node": 128,
          "memory_mb_per_node": 772000,
          "features": "(null)",
          "time_limit": "2-00:00:00"
        }
      ],
      "nodes": [
        {
          "node": "calder-h200-01",
          "partitions": ["calder-gpu-hopper"],
          "state": "idle",
          "cpu_allocated": 0,
          "cpu_idle": 128,
          "cpu_other": 0,
          "cpu_total": 128,
          "memory_mb": 1546000,
          "gres": "gpu:nvidia_h200:8",
          "features": "(null)",
          "reason": "",
          "gpu_total": 8,
          "gpu_allocated": 2,
          "gpu_idle": 6,
          "memory_allocated_mb": 0,
          "memory_free_mb": 1500000,
          "cpu_load": 0.01,
          "current_watts": 610,
          "average_watts": 590
        }
      ],
      "storage": [
        {
          "label": "Flash",
          "path": "/flash-calder/users/abcd1234",
          "filesystem": "10.20.0.11@o2ib:/flash",
          "source": "lfs quota",
          "used_gb": 0.0,
          "quota_gb": 500.0,
          "limit_gb": 550.0,
          "available_gb": 500.0,
          "used_percent": 0.0,
          "file_count": 1,
          "file_quota": 1000000,
          "file_limit": 1100000,
          "over_quota": false,
          "quota_type": "lustre-project",
          "project_id": 210042,
          "mount": "/flash-calder"
        },
        {
          "label": "Scratch",
          "path": "/scratch-calder/users/abcd1234",
          "filesystem": "10.20.0.10@o2ib:/scratch",
          "source": "lfs quota",
          "used_gb": 12.5,
          "quota_gb": 5120.0,
          "limit_gb": 5632.0,
          "available_gb": 5107.5,
          "used_percent": 0.2,
          "file_count": 4210,
          "file_quota": null,
          "file_limit": null,
          "over_quota": false,
          "quota_type": "lustre-project",
          "project_id": 110042,
          "mount": "/scratch-calder"
        },
        {
          "label": "Home",
          "path": "/users/abcd1234",
          "filesystem": "10.10.0.15:/export/users",
          "source": "quota",
          "used_gb": 41.2,
          "quota_gb": 65.0,
          "limit_gb": 70.0,
          "available_gb": 23.8,
          "used_percent": 63.4,
          "file_count": null,
          "file_quota": null,
          "file_limit": null,
          "over_quota": false,
          "quota_type": "nfs",
          "project_id": null,
          "mount": "/users"
        }
      ],
      "errors": [],
      "warnings": ["node_power: scontrol show node reported no CurrentWatts on 3 nodes"]
    }
    """

    /// History written by the single-cluster release: synthesized Codable
    /// keys, no flash series.
    static let legacyHistory = """
    [
      {
        "collectedAt": "2026-10-11T21:13:03+00:00",
        "totalJobs": 2, "runningJobs": 1, "pendingJobs": 1,
        "gpuTotal": 12, "gpuAllocated": 7, "gpuIdle": 5, "unavailableGpuNodes": 0,
        "homeUsedPercent": 63.4, "scratchUsedPercent": 79.3,
        "homeAvailableGB": 23.8, "scratchAvailableGB": 211.6
      },
      {
        "collectedAt": "2026-10-11T21:14:03+00:00",
        "totalJobs": 1, "runningJobs": 1, "pendingJobs": 0,
        "gpuTotal": 12, "gpuAllocated": 6, "gpuIdle": 6, "unavailableGpuNodes": 1,
        "homeUsedPercent": null, "scratchUsedPercent": null,
        "homeAvailableGB": null, "scratchAvailableGB": null
      }
    ]
    """
}

@Suite("Snapshot decoding")
struct SnapshotDecodingTests {
    @Test("Legacy single-cluster cache decodes with defaults")
    func legacySnapshotDecodes() throws {
        let snapshot = try decode(ClusterSnapshot.self, from: SnapshotFixtures.legacyAIRESnapshot)

        #expect(snapshot.collectedAt == "2026-10-11T21:14:03+00:00")
        #expect(snapshot.cluster == nil)
        #expect(snapshot.warnings.isEmpty)
        #expect(snapshot.errors.isEmpty)
        #expect(snapshot.jobs.map(\.jobId) == ["4410921"])
        #expect(snapshot.nodes.first?.gpuIdle == 2)

        let partition = try #require(snapshot.partitions.first)
        #expect(partition.partition == "gpu")
        #expect(partition.timeLimit == nil)

        let storage = try #require(snapshot.storage)
        #expect(storage.count == 2)
        for volume in storage {
            #expect(volume.quotaType == nil)
            #expect(volume.projectID == nil)
            #expect(volume.mount == nil)
            #expect(volume.overQuota == nil)
        }
    }

    @Test("A snapshot without a storage section decodes")
    func snapshotWithoutStorage() throws {
        // The oldest caches predate storage collection entirely.
        let snapshot = try decode(
            ClusterSnapshot.self,
            from: #"{"collected_at": "2026-01-01T00:00:00+00:00", "jobs": [], "partitions": [], "nodes": [], "errors": []}"#
        )
        #expect(snapshot.storage == nil)
        #expect(snapshot.sortedStorage.isEmpty)
        #expect(snapshot.remote.hostname == "")
    }

    @Test("A malformed peripheral key does not discard the snapshot")
    func malformedClusterAndWarningsAreTolerated() throws {
        // `cluster` and `warnings` are decoded leniently: a collector bug in
        // either must not throw away the jobs/nodes the user is watching.
        let snapshot = try decode(
            ClusterSnapshot.self,
            from: #"{"collected_at": "x", "cluster": "calder", "warnings": "oops", "jobs": [], "partitions": [], "nodes": [], "errors": []}"#
        )
        #expect(snapshot.cluster == nil)
        #expect(snapshot.warnings.isEmpty)
        #expect(snapshot.collectedAt == "x")
    }

    @Test("New collector output decodes cluster, warnings, time limits and quota details")
    func newFormatDecodes() throws {
        let snapshot = try decode(ClusterSnapshot.self, from: SnapshotFixtures.calderSnapshot)

        #expect(snapshot.cluster == SnapshotClusterInfo(id: "calder", name: "Calder"))
        #expect(snapshot.warnings.count == 1)
        #expect(snapshot.errors.isEmpty)
        #expect(snapshot.partitions.map(\.timeLimit) == ["2-00:00:00", "2-00:00:00"])

        let node = try #require(snapshot.nodes.first)
        #expect(slurmGPUModel(from: node.gres).map(gpuModelDisplayName) == "H200")
        #expect(slurmGPUTotal(from: node.gres) == 8)

        let storage = try #require(snapshot.storage)
        let scratch = try #require(storage.first { $0.kind == .scratch })
        #expect(scratch.quotaType == "lustre-project")
        #expect(scratch.projectID == 110042)
        #expect(scratch.mount == "/scratch-calder")
        #expect(scratch.path == "/scratch-calder/users/abcd1234")
        #expect(scratch.overQuota == false)

        let home = try #require(storage.first { $0.kind == .home })
        #expect(home.quotaType == "nfs")
        #expect(home.projectID == nil)
        #expect(home.mount == "/users")
    }

    @Test("sortedStorage orders Home, Scratch, Flash, then others")
    func sortedStorageOrder() throws {
        let calder = try decode(ClusterSnapshot.self, from: SnapshotFixtures.calderSnapshot)
        #expect(calder.sortedStorage.map(\.label) == ["Home", "Scratch", "Flash"])

        let legacy = try decode(ClusterSnapshot.self, from: SnapshotFixtures.legacyAIRESnapshot)
        #expect(legacy.sortedStorage.map(\.label) == ["Home", "Scratch"])

        func volume(_ label: String) -> StorageSummary {
            StorageSummary(
                label: label, path: "/x/\(label)", filesystem: "fs", source: "df",
                usedGB: nil, quotaGB: nil, limitGB: nil, availableGB: nil, usedPercent: nil,
                fileCount: nil, fileQuota: nil, fileLimit: nil,
                overQuota: nil, quotaType: nil, projectID: nil, mount: nil,
                unavailableReason: nil
            )
        }
        let mixed = ClusterSnapshot(
            collectedAt: "t",
            remote: RemoteInfo(),
            jobs: [],
            partitions: [],
            nodes: [],
            storage: ["Projects", "Flash", "Archive", "Scratch", "Home"].map(volume),
            errors: []
        )
        // Unknown kinds keep a stable alphabetical order after the known ones.
        #expect(mixed.sortedStorage.map(\.label) == ["Home", "Scratch", "Flash", "Archive", "Projects"])
    }

    @Test("Re-encoding keeps the multi-cluster fields")
    func snapshotRoundTrip() throws {
        // The app re-encodes snapshots into latest_snapshot.json, which the
        // widget reads back; the cluster identity must survive the trip.
        let original = try decode(ClusterSnapshot.self, from: SnapshotFixtures.calderSnapshot)
        let data = try JSONEncoder.prettySorted.encode(original)
        let decoded = try JSONDecoder().decode(ClusterSnapshot.self, from: data)

        #expect(decoded.cluster == original.cluster)
        #expect(decoded.warnings == original.warnings)
        #expect(decoded.partitions.map(\.timeLimit) == original.partitions.map(\.timeLimit))
        #expect(decoded.sortedStorage.map(\.projectID) == original.sortedStorage.map(\.projectID))
        #expect(decoded.sortedStorage.map(\.quotaType) == original.sortedStorage.map(\.quotaType))
    }

    @Test("Legacy history without flash decodes")
    func legacyHistoryDecodes() throws {
        let history = try decode([TrendPoint].self, from: SnapshotFixtures.legacyHistory)

        #expect(history.count == 2)
        #expect(history.allSatisfy { $0.flashUsedPercent == nil && $0.flashAvailableGB == nil })
        #expect(history[0].scratchUsedPercent == 79.3)
        #expect(history[1].homeUsedPercent == nil)
        #expect(history[1].unavailableGpuNodes == 1)
    }

    @Test("TrendPoint picks up the flash series and GPU totals")
    func trendPointFromCalderSnapshot() throws {
        let snapshot = try decode(ClusterSnapshot.self, from: SnapshotFixtures.calderSnapshot)
        let point = TrendPoint(snapshot: snapshot)

        #expect(point.collectedAt == snapshot.collectedAt)
        #expect(point.gpuTotal == 8)
        #expect(point.gpuAllocated == 2)
        #expect(point.gpuIdle == 6)
        #expect(point.homeUsedPercent == 63.4)
        #expect(point.scratchUsedPercent == 0.2)
        #expect(point.flashUsedPercent == 0.0)
        #expect(point.flashAvailableGB == 500.0)
    }
}
