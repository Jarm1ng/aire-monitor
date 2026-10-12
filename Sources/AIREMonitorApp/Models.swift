import Foundation

struct RemoteInfo: Codable {
    let host: String
    let hostname: String
    let user: String
    let cwd: String
    let remoteTime: String

    enum CodingKeys: String, CodingKey {
        case host
        case hostname
        case user
        case cwd
        case remoteTime = "remote_time"
    }

    init(host: String = "", hostname: String = "", user: String = "", cwd: String = "", remoteTime: String = "") {
        self.host = host
        self.hostname = hostname
        self.user = user
        self.cwd = cwd
        self.remoteTime = remoteTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        hostname = try container.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        user = try container.decodeIfPresent(String.self, forKey: .user) ?? ""
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        remoteTime = try container.decodeIfPresent(String.self, forKey: .remoteTime) ?? ""
    }
}

struct Job: Codable, Identifiable {
    let jobId: String
    let partition: String
    let name: String
    let user: String
    let state: String
    let elapsed: String
    let timeLimit: String
    let nodes: String
    let reasonOrNodeList: String
    let submitTime: String?
    let startTime: String?
    let endTime: String?
    let workDir: String?
    let command: String?
    let stdoutPath: String?
    let stderrPath: String?
    let batchHost: String?
    let nodeList: String?
    let numCpus: Int?
    let numTasks: Int?
    let reqTres: String?
    let allocTres: String?
    let tresPerNode: String?

    var id: String { jobId }

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case partition
        case name
        case user
        case state
        case elapsed
        case timeLimit = "time_limit"
        case nodes
        case reasonOrNodeList = "reason_or_node_list"
        case submitTime = "submit_time"
        case startTime = "start_time"
        case endTime = "end_time"
        case workDir = "work_dir"
        case command
        case stdoutPath = "stdout_path"
        case stderrPath = "stderr_path"
        case batchHost = "batch_host"
        case nodeList = "node_list"
        case numCpus = "num_cpus"
        case numTasks = "num_tasks"
        case reqTres = "req_tres"
        case allocTres = "alloc_tres"
        case tresPerNode = "tres_per_node"
    }
}

struct PartitionSummary: Codable, Identifiable {
    let partition: String
    let availability: String
    let nodeCount: Int?
    let state: String
    let gres: String
    let cpusPerNode: Int?
    let memoryMBPerNode: Int?
    let features: String
    /// sinfo %l, e.g. "2-00:00:00" or "infinite". Absent in older caches.
    let timeLimit: String?

    // sinfo summary output can emit multiple rows sharing partition/state/gres
    // (differing only in features or node count); include those so SwiftUI
    // identity stays unique.
    var id: String { "\(partition)-\(state)-\(gres)-\(features)-\(nodeCount.map(String.init) ?? "na")" }

    enum CodingKeys: String, CodingKey {
        case partition
        case availability
        case nodeCount = "node_count"
        case state
        case gres
        case cpusPerNode = "cpus_per_node"
        case memoryMBPerNode = "memory_mb_per_node"
        case features
        case timeLimit = "time_limit"
    }
}

struct NodeSummary: Codable, Identifiable {
    let node: String
    let partitions: [String]
    let state: String
    let cpuAllocated: Int?
    let cpuIdle: Int?
    let cpuOther: Int?
    let cpuTotal: Int?
    let memoryMB: Int?
    let gres: String
    let features: String
    let reason: String
    let gpuTotal: Int?
    let gpuAllocated: Int?
    let gpuIdle: Int?
    let memoryAllocatedMB: Int?
    let memoryFreeMB: Int?
    let cpuLoad: Double?
    let currentWatts: Int?
    let averageWatts: Int?

    var id: String { node }

    enum CodingKeys: String, CodingKey {
        case node
        case partitions
        case state
        case cpuAllocated = "cpu_allocated"
        case cpuIdle = "cpu_idle"
        case cpuOther = "cpu_other"
        case cpuTotal = "cpu_total"
        case memoryMB = "memory_mb"
        case gres
        case features
        case reason
        case gpuTotal = "gpu_total"
        case gpuAllocated = "gpu_allocated"
        case gpuIdle = "gpu_idle"
        case memoryAllocatedMB = "memory_allocated_mb"
        case memoryFreeMB = "memory_free_mb"
        case cpuLoad = "cpu_load"
        case currentWatts = "current_watts"
        case averageWatts = "average_watts"
    }
}

struct StorageSummary: Codable, Identifiable {
    let label: String
    let path: String
    let filesystem: String
    let source: String
    let usedGB: Double?
    let quotaGB: Double?
    let limitGB: Double?
    let availableGB: Double?
    let usedPercent: Double?
    let fileCount: Int?
    let fileQuota: Int?
    let fileLimit: Int?
    let overQuota: Bool?
    /// "nfs", "lustre-project", "lustre-user" or "df". Absent in older caches.
    let quotaType: String?
    /// Lustre project id when the space is governed by a project quota.
    let projectID: Int?
    let mount: String?
    /// For source "unavailable" only: "missing" (no directory), "no-figures"
    /// (directory exists, df/quota printed nothing — usually a slow
    /// filesystem) or "not-collected" (the storage output never got there).
    let unavailableReason: String?

    var id: String { label }

    /// Short, honest caption for a row the collector could not read.
    var unavailableCaption: String {
        switch unavailableReason {
        case "missing":
            return "Not readable — no directory found"
        default:
            return "Usage could not be read this refresh"
        }
    }

    var unavailableHelp: String {
        switch unavailableReason {
        case "missing":
            return "None of the configured directories exist on the login node, so no usage could be read."
        case "no-figures":
            return "The directory exists, but df/quota returned nothing in time — the filesystem may be slow. It is retried on the next refresh."
        default:
            return "The storage report did not reach this space before the collection budget ran out. It is retried on the next refresh."
        }
    }
    var kind: StorageKind { StorageKind(label: label) }

    enum CodingKeys: String, CodingKey {
        case label
        case path
        case filesystem
        case source
        case usedGB = "used_gb"
        case quotaGB = "quota_gb"
        case limitGB = "limit_gb"
        case availableGB = "available_gb"
        case usedPercent = "used_percent"
        case fileCount = "file_count"
        case fileQuota = "file_quota"
        case fileLimit = "file_limit"
        case overQuota = "over_quota"
        case quotaType = "quota_type"
        case projectID = "project_id"
        case mount
        case unavailableReason = "unavailable_reason"
    }
}

/// Which cluster a snapshot came from, as echoed by the collector.
struct SnapshotClusterInfo: Codable, Equatable {
    let id: String
    let name: String
}

struct ClusterSnapshot: Codable {
    let collectedAt: String
    let cluster: SnapshotClusterInfo?
    let remote: RemoteInfo
    let jobs: [Job]
    let partitions: [PartitionSummary]
    let nodes: [NodeSummary]
    let storage: [StorageSummary]?
    let errors: [String]
    /// Non-fatal collector issues (an enrichment section failed). Never a
    /// reason to treat a refresh as failed.
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case collectedAt = "collected_at"
        case cluster
        case remote
        case jobs
        case partitions
        case nodes
        case storage
        case errors
        case warnings
    }

    init(
        collectedAt: String,
        cluster: SnapshotClusterInfo? = nil,
        remote: RemoteInfo,
        jobs: [Job],
        partitions: [PartitionSummary],
        nodes: [NodeSummary],
        storage: [StorageSummary]?,
        errors: [String],
        warnings: [String] = []
    ) {
        self.collectedAt = collectedAt
        self.cluster = cluster
        self.remote = remote
        self.jobs = jobs
        self.partitions = partitions
        self.nodes = nodes
        self.storage = storage
        self.errors = errors
        self.warnings = warnings
    }

    // Resilient decoding: a missing or renamed peripheral key from the python
    // emitter should not discard the whole snapshot (and with it the cache).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        collectedAt = try container.decodeIfPresent(String.self, forKey: .collectedAt) ?? ""
        cluster = try? container.decodeIfPresent(SnapshotClusterInfo.self, forKey: .cluster)
        remote = try container.decodeIfPresent(RemoteInfo.self, forKey: .remote) ?? RemoteInfo()
        jobs = try container.decodeIfPresent([Job].self, forKey: .jobs) ?? []
        partitions = try container.decodeIfPresent([PartitionSummary].self, forKey: .partitions) ?? []
        nodes = try container.decodeIfPresent([NodeSummary].self, forKey: .nodes) ?? []
        storage = try container.decodeIfPresent([StorageSummary].self, forKey: .storage)
        errors = try container.decodeIfPresent([String].self, forKey: .errors) ?? []
        warnings = (try? container.decodeIfPresent([String].self, forKey: .warnings)) ?? []
    }

    /// Storage spaces in display order (home, scratch, flash, others).
    var sortedStorage: [StorageSummary] {
        (storage ?? []).sorted { lhs, rhs in
            lhs.kind == rhs.kind ? lhs.label < rhs.label : lhs.kind < rhs.kind
        }
    }
}
