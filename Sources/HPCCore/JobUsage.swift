import Foundation

// What running jobs actually use on their compute nodes, sampled by the
// collector's job_usage section (`--job-usage`): nvidia-smi for the GPUs a
// job holds, the job's cgroup for CPU and memory. The point is one question
// — is this job using what it asked for? — so the summaries below reduce a
// job's nodes and GPUs to a few fractions and a plain-words verdict.

/// One GPU as nvidia-smi reported it.
public struct GPUUsage: Codable, Equatable, Sendable, Identifiable {
    /// nvidia-smi's minor number, the index Slurm's GRES IDX uses.
    public let index: Int?
    public let name: String
    /// Percent of the last sample period a kernel was running.
    public let utilizationPercent: Double?
    /// Percent of the period device memory was being read or written.
    public let memoryActivityPercent: Double?
    public let memoryUsedMB: Double?
    public let memoryTotalMB: Double?
    public let powerWatts: Double?
    public let powerLimitWatts: Double?
    public let temperatureC: Double?

    public var id: Int { index ?? -1 }

    enum CodingKeys: String, CodingKey {
        case index
        case name
        case utilizationPercent = "utilization_percent"
        case memoryActivityPercent = "memory_activity_percent"
        case memoryUsedMB = "memory_used_mb"
        case memoryTotalMB = "memory_total_mb"
        case powerWatts = "power_watts"
        case powerLimitWatts = "power_limit_watts"
        case temperatureC = "temperature_c"
    }

    public init(
        index: Int?,
        name: String,
        utilizationPercent: Double?,
        memoryActivityPercent: Double? = nil,
        memoryUsedMB: Double?,
        memoryTotalMB: Double?,
        powerWatts: Double? = nil,
        powerLimitWatts: Double? = nil,
        temperatureC: Double? = nil
    ) {
        self.index = index
        self.name = name
        self.utilizationPercent = utilizationPercent
        self.memoryActivityPercent = memoryActivityPercent
        self.memoryUsedMB = memoryUsedMB
        self.memoryTotalMB = memoryTotalMB
        self.powerWatts = powerWatts
        self.powerLimitWatts = powerLimitWatts
        self.temperatureC = temperatureC
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = container.lenientOptional(Int.self, .index)
        name = container.lenientString(.name)
        utilizationPercent = container.lenientOptional(Double.self, .utilizationPercent)
        memoryActivityPercent = container.lenientOptional(Double.self, .memoryActivityPercent)
        memoryUsedMB = container.lenientOptional(Double.self, .memoryUsedMB)
        memoryTotalMB = container.lenientOptional(Double.self, .memoryTotalMB)
        powerWatts = container.lenientOptional(Double.self, .powerWatts)
        powerLimitWatts = container.lenientOptional(Double.self, .powerLimitWatts)
        temperatureC = container.lenientOptional(Double.self, .temperatureC)
    }

    /// Device memory in use, 0...1.
    public var memoryFraction: Double? {
        guard let used = memoryUsedMB, let total = memoryTotalMB, total > 0 else {
            return nil
        }
        return min(max(used / total, 0), 1)
    }
}

/// One running job on one of its nodes.
public struct JobNodeUsage: Codable, Equatable, Sendable, Identifiable {
    /// Slurm's own id (the cgroup's job_<id>).
    public let jobID: String
    /// The id the job list shows: `Job.jobId` ("123_4" for an array task).
    public let displayID: String
    public let node: String
    public let cpusAllocated: Int?
    /// CPUs busy on average over the ~1 s sample window.
    public let cpusBusy: Double?
    /// Anonymous (process) memory.
    public let memoryUsedMB: Double?
    /// Everything charged to the job, page cache included.
    public let memoryChargedMB: Double?
    public let memoryPeakMB: Double?
    public let memoryLimitMB: Double?
    /// GRES indices Slurm allocated on this node.
    public let gpuIndices: [Int]
    /// The sampled ones among them.
    public let gpus: [GPUUsage]
    /// Why something is missing; nil when the sample is complete.
    public let note: String?

    public var id: String { "\(jobID)@\(node)" }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case displayID = "display_id"
        case node
        case cpusAllocated = "cpus_allocated"
        case cpusBusy = "cpus_busy"
        case memoryUsedMB = "memory_used_mb"
        case memoryChargedMB = "memory_charged_mb"
        case memoryPeakMB = "memory_peak_mb"
        case memoryLimitMB = "memory_limit_mb"
        case gpuIndices = "gpu_indices"
        case gpus
        case note
    }

    public init(
        jobID: String,
        displayID: String,
        node: String,
        cpusAllocated: Int? = nil,
        cpusBusy: Double? = nil,
        memoryUsedMB: Double? = nil,
        memoryChargedMB: Double? = nil,
        memoryPeakMB: Double? = nil,
        memoryLimitMB: Double? = nil,
        gpuIndices: [Int] = [],
        gpus: [GPUUsage] = [],
        note: String? = nil
    ) {
        self.jobID = jobID
        self.displayID = displayID
        self.node = node
        self.cpusAllocated = cpusAllocated
        self.cpusBusy = cpusBusy
        self.memoryUsedMB = memoryUsedMB
        self.memoryChargedMB = memoryChargedMB
        self.memoryPeakMB = memoryPeakMB
        self.memoryLimitMB = memoryLimitMB
        self.gpuIndices = gpuIndices
        self.gpus = gpus
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try container.decode(String.self, forKey: .jobID)
        let shown = container.lenientString(.displayID)
        displayID = shown.isEmpty ? jobID : shown
        node = container.lenientString(.node)
        cpusAllocated = container.lenientOptional(Int.self, .cpusAllocated)
        cpusBusy = container.lenientOptional(Double.self, .cpusBusy)
        memoryUsedMB = container.lenientOptional(Double.self, .memoryUsedMB)
        memoryChargedMB = container.lenientOptional(Double.self, .memoryChargedMB)
        memoryPeakMB = container.lenientOptional(Double.self, .memoryPeakMB)
        memoryLimitMB = container.lenientOptional(Double.self, .memoryLimitMB)
        gpuIndices = container.lenientOptional([Int].self, .gpuIndices) ?? []
        var notes: [String] = []
        gpus = container.lossyArray(GPUUsage.self, .gpus, noun: "GPU", notes: &notes) ?? []
        note = container.lenientOptional(String.self, .note)
    }
}

/// A job's usage across all its nodes, reduced to what answers "is it using
/// what it asked for?".
public struct JobUsageSummary: Equatable, Sendable {
    public enum GPUVerdict: Equatable, Sendable {
        /// Average utilisation of at least `wellUsedThreshold`.
        case wellUsed
        /// Busy on average, but some allocated GPUs sit idle (a program
        /// that only uses one of several GPUs).
        case someIdle(idle: Int, of: Int)
        case partlyUsed
        case mostlyIdle
        /// No GPU figures this time (see `notes`).
        case unknown
    }

    public static let wellUsedThreshold = 80.0
    public static let mostlyIdleThreshold = 30.0
    /// A GPU below this utilisation counts as idle.
    public static let idleGPUThreshold = 5.0

    public let displayID: String
    public let sampledAt: Date
    public let nodes: [JobNodeUsage]

    public init(displayID: String, sampledAt: Date, nodes: [JobNodeUsage]) {
        self.displayID = displayID
        self.sampledAt = sampledAt
        self.nodes = nodes
    }

    /// Summaries keyed by `Job.jobId`.
    public static func summaries(from rows: [JobNodeUsage], sampledAt: Date) -> [String: JobUsageSummary] {
        Dictionary(grouping: rows, by: \.displayID).mapValues { nodes in
            JobUsageSummary(
                displayID: nodes[0].displayID,
                sampledAt: sampledAt,
                nodes: nodes.sorted { $0.node.localizedStandardCompare($1.node) == .orderedAscending }
            )
        }
    }

    public var gpus: [GPUUsage] { nodes.flatMap(\.gpus) }
    public var allocatedGPUCount: Int { nodes.reduce(0) { $0 + $1.gpuIndices.count } }

    /// Mean utilisation over the sampled GPUs.
    public var meanGPUUtilization: Double? {
        let values = gpus.compactMap(\.utilizationPercent)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    public var gpuMemoryUsedMB: Double? {
        let values = gpus.compactMap(\.memoryUsedMB)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    public var gpuMemoryTotalMB: Double? {
        let values = gpus.compactMap(\.memoryTotalMB)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    public var gpuMemoryFraction: Double? {
        guard let used = gpuMemoryUsedMB, let total = gpuMemoryTotalMB, total > 0 else {
            return nil
        }
        return min(max(used / total, 0), 1)
    }

    public var idleGPUCount: Int {
        gpus.filter { ($0.utilizationPercent ?? 100) < Self.idleGPUThreshold }.count
    }

    public var gpuVerdict: GPUVerdict {
        guard let mean = meanGPUUtilization else {
            return .unknown
        }
        let sampled = gpus.filter { $0.utilizationPercent != nil }.count
        if sampled > 1, idleGPUCount > 0, idleGPUCount < sampled {
            return .someIdle(idle: idleGPUCount, of: sampled)
        }
        if mean >= Self.wellUsedThreshold {
            return .wellUsed
        }
        return mean < Self.mostlyIdleThreshold ? .mostlyIdle : .partlyUsed
    }

    public var cpusAllocated: Int? {
        let values = nodes.compactMap(\.cpusAllocated)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    public var cpusBusy: Double? {
        let values = nodes.compactMap(\.cpusBusy)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    /// Busy CPUs over allocated CPUs (may exceed 1 briefly: hyperthreads,
    /// a burst inside the window).
    public var cpuFraction: Double? {
        guard let busy = cpusBusy, let allocated = cpusAllocated, allocated > 0 else {
            return nil
        }
        return max(busy / Double(allocated), 0)
    }

    public var memoryUsedMB: Double? {
        let values = nodes.compactMap(\.memoryUsedMB)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    public var memoryPeakMB: Double? {
        let values = nodes.compactMap(\.memoryPeakMB)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    public var memoryLimitMB: Double? {
        let values = nodes.compactMap(\.memoryLimitMB)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    public var memoryFraction: Double? {
        guard let used = memoryUsedMB, let limit = memoryLimitMB, limit > 0 else {
            return nil
        }
        return min(max(used / limit, 0), 1)
    }

    public var notes: [String] {
        var seen = Set<String>()
        return nodes.compactMap(\.note).filter { seen.insert($0).inserted }
    }

    /// "4 × H200 at 92% · 61% GPU memory": the one line for a job row.
    public var gpuHeadline: String? {
        guard let mean = meanGPUUtilization else {
            return nil
        }
        let model = Self.shortGPUName(gpus.first?.name ?? "")
        let count = gpus.count
        var text = "\(count) × \(model.isEmpty ? "GPU" : model) at \(Int(mean.rounded()))%"
        if let memory = gpuMemoryFraction {
            text += " · \(Int((memory * 100).rounded()))% GPU memory"
        }
        return text
    }

    public var verdictText: String {
        switch gpuVerdict {
        case .wellUsed:
            return "Using its GPUs well"
        case .someIdle(let idle, let of):
            return "\(idle) of \(of) GPUs idle — the program may use only some of them"
        case .partlyUsed:
            return "GPUs partly used"
        case .mostlyIdle:
            return "GPUs mostly idle — waiting on data, CPU or I/O?"
        case .unknown:
            return allocatedGPUCount > 0 ? "No GPU figures this time" : "CPU job"
        }
    }

    /// "NVIDIA H200" -> "H200", "NVIDIA L40S" -> "L40S".
    public static func shortGPUName(_ name: String) -> String {
        name.replacingOccurrences(of: "NVIDIA ", with: "")
            .replacingOccurrences(of: "Tesla ", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// One point of a job's usage trend.
public struct JobUsagePoint: Equatable, Sendable, Identifiable {
    public let date: Date
    /// 0...100 or nil.
    public let gpuUtilization: Double?
    /// 0...1 or nil.
    public let gpuMemoryFraction: Double?
    public let cpuFraction: Double?
    public let memoryFraction: Double?

    public var id: Date { date }

    public init(date: Date, gpuUtilization: Double?, gpuMemoryFraction: Double?, cpuFraction: Double?, memoryFraction: Double?) {
        self.date = date
        self.gpuUtilization = gpuUtilization
        self.gpuMemoryFraction = gpuMemoryFraction
        self.cpuFraction = cpuFraction
        self.memoryFraction = memoryFraction
    }

    public init(_ summary: JobUsageSummary) {
        self.init(
            date: summary.sampledAt,
            gpuUtilization: summary.meanGPUUtilization,
            gpuMemoryFraction: summary.gpuMemoryFraction,
            cpuFraction: summary.cpuFraction.map { min($0, 1) },
            memoryFraction: summary.memoryFraction
        )
    }
}

/// Recent samples per job (in memory only), for the "is it sustained?"
/// trend in the job's details.
public struct JobUsageHistory: Equatable, Sendable {
    /// About two hours at one sample a minute.
    public static let maximumPoints = 120

    public private(set) var points: [String: [JobUsagePoint]] = [:]

    public init() {}

    /// Adds this sample's points and forgets jobs that are no longer
    /// running (`running` = their `Job.jobId`s).
    public mutating func record(_ summaries: [String: JobUsageSummary], running: Set<String>) {
        for (id, summary) in summaries {
            var series = points[id] ?? []
            if series.last?.date != summary.sampledAt {
                series.append(JobUsagePoint(summary))
            }
            if series.count > Self.maximumPoints {
                series.removeFirst(series.count - Self.maximumPoints)
            }
            points[id] = series
        }
        points = points.filter { running.contains($0.key) }
    }

    public func series(for jobID: String) -> [JobUsagePoint] {
        points[jobID] ?? []
    }

    /// Mean GPU utilisation over the recorded points, so one busy or quiet
    /// minute does not decide the verdict alone.
    public func sustainedGPUUtilization(for jobID: String) -> Double? {
        let values = series(for: jobID).compactMap(\.gpuUtilization)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
