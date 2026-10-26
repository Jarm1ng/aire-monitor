import Foundation

// The collector's JSON schema (scripts/hpc_snapshot.py). Decoding is lenient
// at every level: a missing or null peripheral field falls back to a neutral
// value, and an element that still cannot be decoded is skipped (and counted
// in `warnings`) instead of discarding the whole snapshot — a single odd job
// must never look like a lost connection.

public struct RemoteInfo: Codable, Equatable, Sendable {
    public let host: String
    public let hostname: String
    public let user: String
    public let cwd: String
    public let remoteTime: String

    enum CodingKeys: String, CodingKey {
        case host
        case hostname
        case user
        case cwd
        case remoteTime = "remote_time"
    }

    public init(host: String = "", hostname: String = "", user: String = "", cwd: String = "", remoteTime: String = "") {
        self.host = host
        self.hostname = hostname
        self.user = user
        self.cwd = cwd
        self.remoteTime = remoteTime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = container.lenientString(.host)
        hostname = container.lenientString(.hostname)
        user = container.lenientString(.user)
        cwd = container.lenientString(.cwd)
        remoteTime = container.lenientString(.remoteTime)
    }
}

public struct Job: Codable, Identifiable, Equatable, Sendable {
    public let jobId: String
    public let partition: String
    public let name: String
    public let user: String
    public let state: String
    public let elapsed: String
    public let timeLimit: String
    public let nodes: String
    public let reasonOrNodeList: String
    public let submitTime: String?
    public let startTime: String?
    public let endTime: String?
    public let workDir: String?
    public let command: String?
    public let stdoutPath: String?
    public let stderrPath: String?
    public let batchHost: String?
    public let nodeList: String?
    public let numCpus: Int?
    public let numTasks: Int?
    public let reqTres: String?
    public let allocTres: String?
    public let tresPerNode: String?
    /// Set for every element of a job array (running tasks and the pending
    /// remainder alike).
    public let arrayJobID: Int?
    /// Only on the pending remainder of an array: the task ids still queued,
    /// throttle stripped, e.g. "2-58" or "1,3,5-9".
    public let arrayPendingTasks: String?
    /// The array's concurrency throttle ("%4"), when one is set.
    public let arrayThrottle: Int?
    /// How many queued tasks the pending remainder stands for.
    public let pendingTaskCount: Int?

    public var id: String { jobId }

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
        case arrayJobID = "array_job_id"
        case arrayPendingTasks = "array_pending_tasks"
        case arrayThrottle = "array_throttle"
        case pendingTaskCount = "pending_task_count"
    }

    public init(
        jobId: String,
        partition: String = "",
        name: String = "",
        user: String = "",
        state: String = "",
        elapsed: String = "",
        timeLimit: String = "",
        nodes: String = "",
        reasonOrNodeList: String = "",
        submitTime: String? = nil,
        startTime: String? = nil,
        endTime: String? = nil,
        workDir: String? = nil,
        command: String? = nil,
        stdoutPath: String? = nil,
        stderrPath: String? = nil,
        batchHost: String? = nil,
        nodeList: String? = nil,
        numCpus: Int? = nil,
        numTasks: Int? = nil,
        reqTres: String? = nil,
        allocTres: String? = nil,
        tresPerNode: String? = nil,
        arrayJobID: Int? = nil,
        arrayPendingTasks: String? = nil,
        arrayThrottle: Int? = nil,
        pendingTaskCount: Int? = nil
    ) {
        self.jobId = jobId
        self.partition = partition
        self.name = name
        self.user = user
        self.state = state
        self.elapsed = elapsed
        self.timeLimit = timeLimit
        self.nodes = nodes
        self.reasonOrNodeList = reasonOrNodeList
        self.submitTime = submitTime
        self.startTime = startTime
        self.endTime = endTime
        self.workDir = workDir
        self.command = command
        self.stdoutPath = stdoutPath
        self.stderrPath = stderrPath
        self.batchHost = batchHost
        self.nodeList = nodeList
        self.numCpus = numCpus
        self.numTasks = numTasks
        self.reqTres = reqTres
        self.allocTres = allocTres
        self.tresPerNode = tresPerNode
        self.arrayJobID = arrayJobID
        self.arrayPendingTasks = arrayPendingTasks
        self.arrayThrottle = arrayThrottle
        self.pendingTaskCount = pendingTaskCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The id is the one field a job cannot do without.
        jobId = try container.decode(String.self, forKey: .jobId)
        partition = container.lenientString(.partition)
        name = container.lenientString(.name)
        user = container.lenientString(.user)
        state = container.lenientString(.state)
        elapsed = container.lenientString(.elapsed)
        timeLimit = container.lenientString(.timeLimit)
        nodes = container.lenientString(.nodes)
        reasonOrNodeList = container.lenientString(.reasonOrNodeList)
        submitTime = container.lenientOptional(String.self, .submitTime)
        startTime = container.lenientOptional(String.self, .startTime)
        endTime = container.lenientOptional(String.self, .endTime)
        workDir = container.lenientOptional(String.self, .workDir)
        command = container.lenientOptional(String.self, .command)
        stdoutPath = container.lenientOptional(String.self, .stdoutPath)
        stderrPath = container.lenientOptional(String.self, .stderrPath)
        batchHost = container.lenientOptional(String.self, .batchHost)
        nodeList = container.lenientOptional(String.self, .nodeList)
        numCpus = container.lenientOptional(Int.self, .numCpus)
        numTasks = container.lenientOptional(Int.self, .numTasks)
        reqTres = container.lenientOptional(String.self, .reqTres)
        allocTres = container.lenientOptional(String.self, .allocTres)
        tresPerNode = container.lenientOptional(String.self, .tresPerNode)
        arrayJobID = container.lenientOptional(Int.self, .arrayJobID)
        arrayPendingTasks = container.lenientOptional(String.self, .arrayPendingTasks)
        arrayThrottle = container.lenientOptional(Int.self, .arrayThrottle)
        pendingTaskCount = container.lenientOptional(Int.self, .pendingTaskCount)
    }
}

public struct PartitionSummary: Codable, Identifiable, Equatable, Sendable {
    public let partition: String
    public let availability: String
    public let nodeCount: Int?
    public let state: String
    public let gres: String
    public let cpusPerNode: Int?
    public let memoryMBPerNode: Int?
    public let features: String
    /// sinfo %l, e.g. "2-00:00:00" or "infinite". Absent in older caches.
    public let timeLimit: String?

    // sinfo summary output can emit multiple rows sharing partition/state/gres
    // (differing only in features or node count); include those so SwiftUI
    // identity stays unique.
    public var id: String { "\(partition)-\(state)-\(gres)-\(features)-\(nodeCount.map(String.init) ?? "na")" }

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

    public init(
        partition: String,
        availability: String = "up",
        nodeCount: Int? = nil,
        state: String = "",
        gres: String = "(null)",
        cpusPerNode: Int? = nil,
        memoryMBPerNode: Int? = nil,
        features: String = "(null)",
        timeLimit: String? = nil
    ) {
        self.partition = partition
        self.availability = availability
        self.nodeCount = nodeCount
        self.state = state
        self.gres = gres
        self.cpusPerNode = cpusPerNode
        self.memoryMBPerNode = memoryMBPerNode
        self.features = features
        self.timeLimit = timeLimit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        partition = try container.decode(String.self, forKey: .partition)
        availability = container.lenientString(.availability)
        nodeCount = container.lenientOptional(Int.self, .nodeCount)
        state = container.lenientString(.state)
        gres = container.lenientString(.gres)
        cpusPerNode = container.lenientOptional(Int.self, .cpusPerNode)
        memoryMBPerNode = container.lenientOptional(Int.self, .memoryMBPerNode)
        features = container.lenientString(.features)
        timeLimit = container.lenientOptional(String.self, .timeLimit)
    }
}

public struct NodeSummary: Codable, Identifiable, Equatable, Sendable {
    public let node: String
    public let partitions: [String]
    public let state: String
    public let cpuAllocated: Int?
    public let cpuIdle: Int?
    public let cpuOther: Int?
    public let cpuTotal: Int?
    public let memoryMB: Int?
    public let gres: String
    public let features: String
    public let reason: String
    public let gpuTotal: Int?
    public let gpuAllocated: Int?
    public let gpuIdle: Int?
    public let memoryAllocatedMB: Int?
    public let memoryFreeMB: Int?
    public let cpuLoad: Double?
    public let currentWatts: Int?
    public let averageWatts: Int?

    public var id: String { node }

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

    public init(
        node: String,
        partitions: [String] = [],
        state: String = "",
        cpuAllocated: Int? = nil,
        cpuIdle: Int? = nil,
        cpuOther: Int? = nil,
        cpuTotal: Int? = nil,
        memoryMB: Int? = nil,
        gres: String = "(null)",
        features: String = "(null)",
        reason: String = "none",
        gpuTotal: Int? = nil,
        gpuAllocated: Int? = nil,
        gpuIdle: Int? = nil,
        memoryAllocatedMB: Int? = nil,
        memoryFreeMB: Int? = nil,
        cpuLoad: Double? = nil,
        currentWatts: Int? = nil,
        averageWatts: Int? = nil
    ) {
        self.node = node
        self.partitions = partitions
        self.state = state
        self.cpuAllocated = cpuAllocated
        self.cpuIdle = cpuIdle
        self.cpuOther = cpuOther
        self.cpuTotal = cpuTotal
        self.memoryMB = memoryMB
        self.gres = gres
        self.features = features
        self.reason = reason
        self.gpuTotal = gpuTotal
        self.gpuAllocated = gpuAllocated
        self.gpuIdle = gpuIdle
        self.memoryAllocatedMB = memoryAllocatedMB
        self.memoryFreeMB = memoryFreeMB
        self.cpuLoad = cpuLoad
        self.currentWatts = currentWatts
        self.averageWatts = averageWatts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        node = try container.decode(String.self, forKey: .node)
        partitions = container.lenientOptional([String].self, .partitions) ?? []
        state = container.lenientString(.state)
        cpuAllocated = container.lenientOptional(Int.self, .cpuAllocated)
        cpuIdle = container.lenientOptional(Int.self, .cpuIdle)
        cpuOther = container.lenientOptional(Int.self, .cpuOther)
        cpuTotal = container.lenientOptional(Int.self, .cpuTotal)
        memoryMB = container.lenientOptional(Int.self, .memoryMB)
        gres = container.lenientString(.gres)
        features = container.lenientString(.features)
        reason = container.lenientString(.reason)
        gpuTotal = container.lenientOptional(Int.self, .gpuTotal)
        gpuAllocated = container.lenientOptional(Int.self, .gpuAllocated)
        gpuIdle = container.lenientOptional(Int.self, .gpuIdle)
        memoryAllocatedMB = container.lenientOptional(Int.self, .memoryAllocatedMB)
        memoryFreeMB = container.lenientOptional(Int.self, .memoryFreeMB)
        cpuLoad = container.lenientOptional(Double.self, .cpuLoad)
        currentWatts = container.lenientOptional(Int.self, .currentWatts)
        averageWatts = container.lenientOptional(Int.self, .averageWatts)
    }
}

public struct StorageSummary: Codable, Identifiable, Equatable, Sendable {
    public let label: String
    public let path: String
    public let filesystem: String
    public let source: String
    public let usedGB: Double?
    public let quotaGB: Double?
    public let limitGB: Double?
    public let availableGB: Double?
    public let usedPercent: Double?
    public let fileCount: Int?
    public let fileQuota: Int?
    public let fileLimit: Int?
    public let overQuota: Bool?
    /// "nfs", "lustre-project", "lustre-user" or "df". Absent in older caches.
    public let quotaType: String?
    /// Lustre project id when the space is governed by a project quota.
    public let projectID: Int?
    public let mount: String?
    /// For source "unavailable" only: "missing" (no directory), "no-figures"
    /// (directory exists, df/quota printed nothing — usually a slow
    /// filesystem) or "not-collected" (the storage output never got there).
    public let unavailableReason: String?
    /// Echo of the storage spec's "optional" flag: a volume the cluster may
    /// not have (AIRE's Flash). Such a row is only worth showing when it
    /// carries figures or the label had a real row before.
    public let optional: Bool

    public var id: String { label }
    public var kind: StorageKind { StorageKind(label: label) }

    /// Short, honest caption for a row the collector could not read.
    public var unavailableCaption: String {
        switch unavailableReason {
        case "missing":
            return "Not readable — no directory found"
        default:
            return "Usage could not be read this refresh"
        }
    }

    public var unavailableHelp: String {
        switch unavailableReason {
        case "missing":
            return "None of the configured directories exist on the login node, so no usage could be read."
        case "no-figures":
            return "The directory exists, but df/quota returned nothing in time — the filesystem may be slow. It is retried on the next refresh."
        default:
            return "The storage report did not reach this space before the collection budget ran out. It is retried on the next refresh."
        }
    }

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
        case optional
    }

    public init(
        label: String,
        path: String = "",
        filesystem: String = "",
        source: String = "",
        usedGB: Double? = nil,
        quotaGB: Double? = nil,
        limitGB: Double? = nil,
        availableGB: Double? = nil,
        usedPercent: Double? = nil,
        fileCount: Int? = nil,
        fileQuota: Int? = nil,
        fileLimit: Int? = nil,
        overQuota: Bool? = nil,
        quotaType: String? = nil,
        projectID: Int? = nil,
        mount: String? = nil,
        unavailableReason: String? = nil,
        optional: Bool = false
    ) {
        self.label = label
        self.path = path
        self.filesystem = filesystem
        self.source = source
        self.usedGB = usedGB
        self.quotaGB = quotaGB
        self.limitGB = limitGB
        self.availableGB = availableGB
        self.usedPercent = usedPercent
        self.fileCount = fileCount
        self.fileQuota = fileQuota
        self.fileLimit = fileLimit
        self.overQuota = overQuota
        self.quotaType = quotaType
        self.projectID = projectID
        self.mount = mount
        self.unavailableReason = unavailableReason
        self.optional = optional
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        path = container.lenientString(.path)
        filesystem = container.lenientString(.filesystem)
        source = container.lenientString(.source)
        usedGB = container.lenientOptional(Double.self, .usedGB)
        quotaGB = container.lenientOptional(Double.self, .quotaGB)
        limitGB = container.lenientOptional(Double.self, .limitGB)
        availableGB = container.lenientOptional(Double.self, .availableGB)
        usedPercent = container.lenientOptional(Double.self, .usedPercent)
        fileCount = container.lenientOptional(Int.self, .fileCount)
        fileQuota = container.lenientOptional(Int.self, .fileQuota)
        fileLimit = container.lenientOptional(Int.self, .fileLimit)
        overQuota = container.lenientOptional(Bool.self, .overQuota)
        quotaType = container.lenientOptional(String.self, .quotaType)
        projectID = container.lenientOptional(Int.self, .projectID)
        mount = container.lenientOptional(String.self, .mount)
        unavailableReason = container.lenientOptional(String.self, .unavailableReason)
        optional = container.lenientOptional(Bool.self, .optional) ?? false
    }
}

/// Which cluster a snapshot came from, as echoed by the collector.
public struct SnapshotClusterInfo: Codable, Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct ClusterSnapshot: Codable, Equatable, Sendable {
    /// Newest schema this build understands. The collector writes
    /// `schema_version`; a newer value produces a warning, not a failure.
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int?
    public let collectedAt: String
    /// When collection started (before the socket probe); `collectedAt` is
    /// taken when the round trip returns. Diagnostics only.
    public let startedAt: String?
    /// Wall time of the whole collection, and where it went (probe,
    /// round_trip, and each remote section). Diagnostics only.
    public let durationMs: Int?
    public let timings: [String: Int]
    /// The collector skipped storage on purpose (`--skip-storage`) or because
    /// an earlier df/quota/lfs was still stuck. `storage` is then nil and
    /// the previous rows stay valid.
    public let storageSkipped: Bool
    public let cluster: SnapshotClusterInfo?
    public let remote: RemoteInfo
    public let jobs: [Job]
    public let partitions: [PartitionSummary]
    public let nodes: [NodeSummary]
    public let storage: [StorageSummary]?
    public let errors: [String]
    /// Non-fatal collector issues (an enrichment section failed), plus any
    /// elements skipped while decoding. Never a reason to treat a refresh as
    /// failed.
    public let warnings: [String]
    /// What running jobs use on their nodes (`--job-usage` runs only). nil
    /// when not sampled this time: the previous figures stay valid.
    public let jobUsage: [JobNodeUsage]?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case collectedAt = "collected_at"
        case startedAt = "started_at"
        case durationMs = "duration_ms"
        case timings
        case storageSkipped = "storage_skipped"
        case cluster
        case remote
        case jobs
        case partitions
        case nodes
        case storage
        case errors
        case warnings
        case jobUsage = "job_usage"
    }

    public init(
        schemaVersion: Int? = ClusterSnapshot.supportedSchemaVersion,
        collectedAt: String,
        startedAt: String? = nil,
        durationMs: Int? = nil,
        timings: [String: Int] = [:],
        storageSkipped: Bool = false,
        cluster: SnapshotClusterInfo? = nil,
        remote: RemoteInfo = RemoteInfo(),
        jobs: [Job] = [],
        partitions: [PartitionSummary] = [],
        nodes: [NodeSummary] = [],
        storage: [StorageSummary]? = nil,
        errors: [String] = [],
        warnings: [String] = [],
        jobUsage: [JobNodeUsage]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.jobUsage = jobUsage
        self.collectedAt = collectedAt
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.timings = timings
        self.storageSkipped = storageSkipped
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
    // emitter must not discard the whole snapshot (and with it the cache),
    // and one malformed element is skipped and reported, not fatal.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var notes: [String] = []
        schemaVersion = container.lenientOptional(Int.self, .schemaVersion)
        collectedAt = container.lenientString(.collectedAt)
        startedAt = container.lenientOptional(String.self, .startedAt)
        durationMs = container.lenientOptional(Int.self, .durationMs)
        timings = container.lenientOptional([String: Int].self, .timings) ?? [:]
        storageSkipped = container.lenientOptional(Bool.self, .storageSkipped) ?? false
        cluster = container.lenientOptional(SnapshotClusterInfo.self, .cluster)
        remote = container.lenientOptional(RemoteInfo.self, .remote) ?? RemoteInfo()
        jobs = container.lossyArray(Job.self, .jobs, noun: "job", notes: &notes) ?? []
        partitions = container.lossyArray(PartitionSummary.self, .partitions, noun: "partition row", notes: &notes) ?? []
        nodes = container.lossyArray(NodeSummary.self, .nodes, noun: "node", notes: &notes) ?? []
        storage = container.lossyArray(StorageSummary.self, .storage, noun: "storage row", notes: &notes)
        errors = container.lenientOptional([String].self, .errors) ?? []
        jobUsage = container.lossyArray(JobNodeUsage.self, .jobUsage, noun: "job usage row", notes: &notes)
        if let version = schemaVersion, version > Self.supportedSchemaVersion {
            notes.append("Snapshot schema \(version) is newer than this app understands (\(Self.supportedSchemaVersion)); some details may be missing — update the app")
        }
        warnings = (container.lenientOptional([String].self, .warnings) ?? []) + notes
    }

    /// Storage spaces in display order (home, scratch, flash, others).
    public var sortedStorage: [StorageSummary] {
        (storage ?? []).sorted { lhs, rhs in
            lhs.kind == rhs.kind ? lhs.label < rhs.label : lhs.kind < rhs.kind
        }
    }
}
