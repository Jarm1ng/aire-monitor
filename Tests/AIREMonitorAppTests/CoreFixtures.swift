import HPCCore
import Foundation

/// Snapshots modelled on real AIRE and Calder rows collected on 13 October
/// 2026, trimmed to a representative subset and anonymised (user, job names,
/// paths and project ids are made up). Built in Swift rather than read from
/// JSON so the tests need no resource bundle, and so every figure a test
/// asserts can be traced to one row below.
///
/// The rows deliberately keep the awkward cases the dashboards got wrong:
/// - AIRE `gpu018`: allocated node with every CPU taken but one GPU idle —
///   a *stranded* GPU no new job can start on.
/// - AIRE `gpu021`/`gpu028`: `down$` (not responding, in a maintenance
///   reservation) with no allocation reported — unknown, never idle.
/// - Calder's H200 nodes report AllocMem=0 and CurrentWatts=0 even when busy,
///   and most are `mix-` (planned by backfill).
/// - Calder also hosts one drained, not-responding L40 node from AIRE
///   (`gpu028`, partition `aire-gpu-lovelace`): a second GPU model, so its
///   pools are "H200 + L40", never one summed figure.
/// - Calder's `aire-cpu-genoa` partition is entirely drained (`drain$`,
///   `drain*`, `drain`) although sinfo reports it "up".
enum CoreFixtures {
    static let collectedAt = "2026-10-13T11:49:45.636173+00:00"

    // MARK: - AIRE

    static func aireGPUNode(
        _ name: String,
        state: String = "mix",
        cpuAllocated: Int,
        gpuAllocated: Int?,
        reason: String = "none"
    ) -> NodeSummary {
        let down = !NodeStateInfo(state).isAvailable
        return NodeSummary(
            node: name,
            partitions: ["gpu"],
            state: state,
            cpuAllocated: down ? 0 : cpuAllocated,
            cpuIdle: down ? 0 : 24 - cpuAllocated,
            cpuOther: down ? 24 : 0,
            cpuTotal: 24,
            memoryMB: 256656,
            gres: "gpu:l40s:3",
            reason: reason,
            gpuTotal: 3,
            gpuAllocated: gpuAllocated,
            gpuIdle: gpuAllocated.map { 3 - $0 },
            memoryAllocatedMB: down ? 0 : 81920,
            memoryFreeMB: down ? nil : 150000,
            cpuLoad: down ? 0 : Double(cpuAllocated),
            currentWatts: down ? 0 : 1100,
            averageWatts: down ? 0 : 950
        )
    }

    static func aireCPUNode(_ name: String, partitions: [String], state: String, cpuAllocated: Int, memoryMB: Int = 772968) -> NodeSummary {
        NodeSummary(
            node: name,
            partitions: partitions,
            state: state,
            cpuAllocated: cpuAllocated,
            cpuIdle: 168 - cpuAllocated,
            cpuOther: 0,
            cpuTotal: 168,
            memoryMB: memoryMB,
            gpuTotal: 0,
            gpuAllocated: 0,
            gpuIdle: 0,
            memoryAllocatedMB: 600000,
            memoryFreeMB: 650000,
            cpuLoad: Double(cpuAllocated),
            currentWatts: 790,
            averageWatts: 690
        )
    }

    /// 14 GPU nodes (42 L40S) plus CPU, high-memory and teaching nodes.
    /// GPU tally: 31 allocated, 4 idle and startable (gpu001 1, gpu002 2,
    /// gpu010 1), 1 stranded (gpu018), 6 unavailable on 2 `down$` nodes.
    static let aireNodes: [NodeSummary] = [
        aireGPUNode("gpu001", cpuAllocated: 23, gpuAllocated: 2),
        aireGPUNode("gpu002", cpuAllocated: 10, gpuAllocated: 1),
        aireGPUNode("gpu003", state: "alloc", cpuAllocated: 24, gpuAllocated: 3),
        aireGPUNode("gpu004", cpuAllocated: 22, gpuAllocated: 3),
        aireGPUNode("gpu005", cpuAllocated: 12, gpuAllocated: 3),
        aireGPUNode("gpu006", cpuAllocated: 22, gpuAllocated: 3),
        aireGPUNode("gpu007", cpuAllocated: 17, gpuAllocated: 3),
        aireGPUNode("gpu008", cpuAllocated: 17, gpuAllocated: 3),
        aireGPUNode("gpu009", cpuAllocated: 22, gpuAllocated: 3),
        aireGPUNode("gpu010", cpuAllocated: 21, gpuAllocated: 2),
        aireGPUNode("gpu018", state: "alloc", cpuAllocated: 24, gpuAllocated: 2),
        aireGPUNode("gpu020", state: "alloc", cpuAllocated: 24, gpuAllocated: 3),
        aireGPUNode("gpu021", state: "down$", cpuAllocated: 0, gpuAllocated: nil, reason: "Not responding"),
        aireGPUNode("gpu028", state: "down$", cpuAllocated: 0, gpuAllocated: nil, reason: "Not responding"),
        aireCPUNode("node001", partitions: ["nodes"], state: "mix", cpuAllocated: 133),
        aireCPUNode("node002", partitions: ["nodes"], state: "alloc", cpuAllocated: 168),
        aireCPUNode("node003", partitions: ["nodes"], state: "mix", cpuAllocated: 96),
        aireCPUNode("node042", partitions: ["nodes", "teachingnodes"], state: "mix", cpuAllocated: 149),
        aireCPUNode("node049", partitions: ["nodes", "teachingnodes"], state: "alloc", cpuAllocated: 168),
        aireCPUNode("himem01", partitions: ["himem"], state: "mix", cpuAllocated: 60, memoryMB: 2321256),
        aireCPUNode("himem02", partitions: ["himem"], state: "mix", cpuAllocated: 24, memoryMB: 2321256)
    ]

    static let airePartitions: [PartitionSummary] = [
        PartitionSummary(partition: "nodes", nodeCount: 35, state: "mix", cpusPerNode: 168, memoryMBPerNode: 772968, timeLimit: "2-00:00:00"),
        PartitionSummary(partition: "nodes", nodeCount: 17, state: "alloc", cpusPerNode: 168, memoryMBPerNode: 772968, timeLimit: "2-00:00:00"),
        PartitionSummary(partition: "gpu", nodeCount: 2, state: "down$", gres: "gpu:l40s:3", cpusPerNode: 24, memoryMBPerNode: 256656, timeLimit: "2-00:00:00"),
        PartitionSummary(partition: "gpu", nodeCount: 19, state: "mix", gres: "gpu:l40s:3", cpusPerNode: 24, memoryMBPerNode: 256656, timeLimit: "2-00:00:00"),
        PartitionSummary(partition: "gpu", nodeCount: 7, state: "alloc", gres: "gpu:l40s:3", cpusPerNode: 24, memoryMBPerNode: 256656, timeLimit: "2-00:00:00"),
        PartitionSummary(partition: "himem", nodeCount: 2, state: "mix", cpusPerNode: 168, memoryMBPerNode: 2321256, timeLimit: "2-00:00:00"),
        PartitionSummary(partition: "teachingnodes", nodeCount: 9, state: "mix", cpusPerNode: 168, memoryMBPerNode: 772968, timeLimit: "8:00:00"),
        PartitionSummary(partition: "teachingnodes", nodeCount: 2, state: "alloc", cpusPerNode: 168, memoryMBPerNode: 772968, timeLimit: "8:00:00")
    ]

    static func gpuJob(
        _ id: String,
        state: String,
        reason: String,
        elapsed: String = "0:00",
        timeLimit: String = "4:00:00",
        name: String = "train-resnet50",
        partition: String = "gpu",
        nodeList: String? = nil,
        arrayJobID: Int? = nil,
        arrayPendingTasks: String? = nil,
        arrayThrottle: Int? = nil,
        pendingTaskCount: Int? = nil
    ) -> Job {
        let running = JobState(state).occupiesNodes
        return Job(
            jobId: id,
            partition: partition,
            name: name,
            user: "abcd1234",
            state: state,
            elapsed: elapsed,
            timeLimit: timeLimit,
            nodes: "1",
            reasonOrNodeList: running ? (nodeList ?? "") : reason,
            submitTime: "2026-10-13T10:19:01",
            startTime: running ? "2026-10-13T11:41:38" : nil,
            workDir: "/mnt/scratch/abcd1234/experiments/\(name)",
            command: "/mnt/scratch/abcd1234/experiments/\(name)/run.sh",
            stdoutPath: "/mnt/scratch/abcd1234/experiments/\(name)/slurm-\(id).out",
            stderrPath: "/mnt/scratch/abcd1234/experiments/\(name)/slurm-\(id).out",
            batchHost: running ? nodeList : nil,
            nodeList: running ? nodeList : nil,
            numCpus: 8,
            numTasks: 1,
            reqTres: "cpu=8,mem=80G,node=1,billing=8,gres/gpu=1",
            allocTres: running ? "cpu=8,mem=80G,node=1,billing=8,gres/gpu=1" : nil,
            tresPerNode: "gres/gpu:1",
            arrayJobID: arrayJobID,
            arrayPendingTasks: arrayPendingTasks,
            arrayThrottle: arrayThrottle,
            pendingTaskCount: pendingTaskCount
        )
    }

    static func cpuJob(_ id: String, state: String, reason: String, timeLimit: String, cpus: Int, nodeList: String? = nil, partition: String = "nodes", name: String = "preprocess-shards") -> Job {
        let running = JobState(state).occupiesNodes
        return Job(
            jobId: id,
            partition: partition,
            name: name,
            user: "abcd1234",
            state: state,
            elapsed: running ? "1:16:57" : "0:00",
            timeLimit: timeLimit,
            nodes: "1",
            reasonOrNodeList: running ? (nodeList ?? "") : reason,
            submitTime: "2026-10-13T01:31:35",
            startTime: running ? "2026-10-13T11:32:53" : nil,
            workDir: "/users/abcd1234/projects/\(name)",
            nodeList: running ? nodeList : nil,
            numCpus: cpus,
            numTasks: 1,
            reqTres: "cpu=\(cpus),mem=48G,node=1,billing=\(cpus)",
            allocTres: running ? "cpu=\(cpus),node=1,billing=\(cpus)" : nil
        )
    }

    /// A GPU array (two running tasks plus a pending remainder of 57 tasks,
    /// throttled to 4), single GPU jobs waiting on priority and on a
    /// dependency, and CPU jobs blocked on dependencies.
    static let aireJobs: [Job] = [
        cpuJob("8247672", state: "PENDING", reason: "(Dependency)", timeLimit: "4:00:00", cpus: 16),
        gpuJob("8248307_0", state: "RUNNING", reason: "", elapsed: "1:08:18", nodeList: "gpu003", arrayJobID: 8248307),
        gpuJob("8248326", state: "PENDING", reason: "(Priority)", timeLimit: "3:00:00", name: "eval-sweep"),
        gpuJob("8248328", state: "PENDING", reason: "(Dependency)", timeLimit: "3:00:00", name: "eval-sweep-followup"),
        cpuJob("8248684", state: "PENDING", reason: "(Dependency)", timeLimit: "1-00:00:00", cpus: 32, name: "a-rather-long-experiment-name-that-tests-truncation-seed-42"),
        gpuJob("8248307_1", state: "RUNNING", reason: "", elapsed: "1:05:13", nodeList: "gpu020", arrayJobID: 8248307),
        gpuJob(
            "8248307", state: "PENDING", reason: "(Priority)",
            arrayJobID: 8248307, arrayPendingTasks: "2-58", arrayThrottle: 4, pendingTaskCount: 57
        )
    ]

    static let aireStorage: [StorageSummary] = [
        StorageSummary(
            label: "Home", path: "/users/abcd1234", filesystem: "10.10.0.15:/export/users", source: "quota",
            usedGB: 44.53, quotaGB: 65, limitGB: 65, availableGB: 20.47, usedPercent: 68.5,
            fileCount: 294000, fileQuota: 1500000, fileLimit: 1500000, overQuota: false,
            quotaType: "nfs", mount: "/users"
        ),
        StorageSummary(
            label: "Scratch", path: "/mnt/scratch/abcd1234", filesystem: "10.10.0.40@o2ib:/scratch", source: "lfs quota",
            usedGB: 3603.8, quotaGB: nil, limitGB: 4096, availableGB: 492.2, usedPercent: 87.98,
            fileCount: 2934538, fileQuota: nil, fileLimit: 5000000, overQuota: false,
            quotaType: "lustre-user", mount: "/mnt/scratch"
        )
    ]

    static let aireSnapshot = ClusterSnapshot(
        collectedAt: collectedAt,
        cluster: SnapshotClusterInfo(id: "aire", name: "AIRE"),
        remote: RemoteInfo(
            host: "aire.leeds.ac.uk", hostname: "login3.aire.lee.alces.network", user: "abcd1234",
            cwd: "/users/abcd1234", remoteTime: "2026-10-13T12:49:55+01:00"
        ),
        jobs: aireJobs,
        partitions: airePartitions,
        nodes: aireNodes,
        storage: aireStorage
    )

    // MARK: - Calder

    static func calderH200Node(_ name: String, state: String, cpuAllocated: Int, gpuAllocated: Int?, reason: String = "none") -> NodeSummary {
        let usable = NodeStateInfo(state).isAvailable
        return NodeSummary(
            node: name,
            partitions: ["calder-gpu-hopper"],
            state: state,
            cpuAllocated: usable ? cpuAllocated : 0,
            cpuIdle: usable ? 128 - cpuAllocated : 0,
            cpuOther: usable ? 0 : 128,
            cpuTotal: 128,
            memoryMB: 1546664,
            gres: "gpu:nvidia_h200:8",
            reason: reason,
            gpuTotal: 8,
            gpuAllocated: gpuAllocated,
            gpuIdle: gpuAllocated.map { 8 - $0 },
            // Calder's Slurm reports AllocMem=0 and CurrentWatts=0 on busy nodes.
            memoryAllocatedMB: 0,
            memoryFreeMB: usable ? 1400000 : nil,
            cpuLoad: Double(cpuAllocated),
            currentWatts: 0,
            averageWatts: 0
        )
    }

    static func calderCPUNode(_ name: String, partition: String = "calder-cpu-turin", state: String, cpuAllocated: Int, cpuTotal: Int = 128, reason: String = "none") -> NodeSummary {
        let usable = NodeStateInfo(state).isAvailable
        return NodeSummary(
            node: name,
            partitions: [partition],
            state: state,
            cpuAllocated: usable ? cpuAllocated : 0,
            cpuIdle: usable ? cpuTotal - cpuAllocated : 0,
            cpuOther: usable ? 0 : cpuTotal,
            cpuTotal: cpuTotal,
            memoryMB: cpuTotal == 168 ? 734374 : 772480,
            reason: reason,
            gpuTotal: 0,
            gpuAllocated: 0,
            gpuIdle: 0,
            memoryAllocatedMB: 0,
            memoryFreeMB: usable ? 713838 : nil,
            cpuLoad: Double(cpuAllocated),
            currentWatts: 0,
            averageWatts: 0
        )
    }

    /// H200 pool: 7 nodes, 56 GPUs — 32 allocated, 16 idle and startable
    /// (h200-03 1, h200-04 5, h200-06 3, h200-07 7), 8 unavailable on the
    /// drained h200-05. L40 pool: 1 drained, not-responding node, 3 GPUs
    /// unavailable.
    static let calderNodes: [NodeSummary] = [
        calderH200Node("calder-h200-01", state: "mix-", cpuAllocated: 64, gpuAllocated: 8),
        calderH200Node("calder-h200-02", state: "mix-", cpuAllocated: 64, gpuAllocated: 8),
        calderH200Node("calder-h200-03", state: "mix-", cpuAllocated: 88, gpuAllocated: 7),
        calderH200Node("calder-h200-04", state: "mix-", cpuAllocated: 36, gpuAllocated: 3),
        calderH200Node("calder-h200-05", state: "drain", cpuAllocated: 0, gpuAllocated: nil, reason: "Kill task failed"),
        calderH200Node("calder-h200-06", state: "mix", cpuAllocated: 53, gpuAllocated: 5),
        calderH200Node("calder-h200-07", state: "mix", cpuAllocated: 16, gpuAllocated: 1),
        NodeSummary(
            node: "gpu028",
            partitions: ["aire-gpu-lovelace"],
            state: "drain*",
            cpuAllocated: 0, cpuIdle: 0, cpuOther: 24, cpuTotal: 24,
            memoryMB: 256859,
            gres: "gpu:nvidia_l40:3",
            reason: "NHC: check_cmd_output: kernel version failed to match \"uname -r\" output. : Not responding",
            gpuTotal: 3, gpuAllocated: nil, gpuIdle: nil,
            memoryAllocatedMB: 0, memoryFreeMB: nil, cpuLoad: 0, currentWatts: 0, averageWatts: 0
        ),
        calderCPUNode("calder-cpu001", state: "mix", cpuAllocated: 120),
        calderCPUNode("calder-cpu008", state: "alloc", cpuAllocated: 128),
        calderCPUNode("calder-cpu020", state: "idle", cpuAllocated: 0),
        calderCPUNode("calder-cpu021", state: "idle", cpuAllocated: 0),
        calderCPUNode("calder-cpu091", state: "down*", cpuAllocated: 0, reason: "Not responding"),
        calderCPUNode("calder-cpu098", state: "down$", cpuAllocated: 0, reason: "Not responding"),
        calderCPUNode("node056", partition: "aire-cpu-genoa", state: "drain$", cpuAllocated: 0, cpuTotal: 168, reason: "NHC: check_hw_ib: Version mismatch between kernel OFED drivers and userspace OFED libraries."),
        calderCPUNode("node057", partition: "aire-cpu-genoa", state: "drain*", cpuAllocated: 0, cpuTotal: 168, reason: "NHC: check_cmd_output: kernel version failed to match \"uname -r\" output."),
        calderCPUNode("node058", partition: "aire-cpu-genoa", state: "drain", cpuAllocated: 0, cpuTotal: 168, reason: "NHC: check_cmd_output: kernel version failed to match \"uname -r\" output.")
    ]

    static let calderPartitions: [PartitionSummary] = [
        PartitionSummary(partition: "aire-cpu-genoa", nodeCount: 1, state: "drain$", cpusPerNode: 168, memoryMBPerNode: 734374, timeLimit: "2-00:00:00"),
        PartitionSummary(partition: "aire-cpu-genoa", nodeCount: 2, state: "drain*", cpusPerNode: 168, memoryMBPerNode: 734374, timeLimit: "2-00:00:00"),
        PartitionSummary(partition: "aire-cpu-genoa", nodeCount: 5, state: "drain", cpusPerNode: 168, memoryMBPerNode: 734374, timeLimit: "2-00:00:00"),
        PartitionSummary(partition: "calder-cpu-turin", nodeCount: 1, state: "down$", cpusPerNode: 128, memoryMBPerNode: 772480, timeLimit: "2-00:00:00"),
        PartitionSummary(partition: "calder-cpu-turin", nodeCount: 1, state: "down*", cpusPerNode: 128, memoryMBPerNode: 772480, timeLimit: "2-00:00:00"),
        PartitionSummary(partition: "calder-cpu-turin", nodeCount: 36, state: "mix", cpusPerNode: 128, memoryMBPerNode: 772480, timeLimit: "2-00:00:00"),
        PartitionSummary(partition: "calder-cpu-turin", nodeCount: 2, state: "alloc", cpusPerNode: 128, memoryMBPerNode: 772480, timeLimit: "2-00:00:00"),
        PartitionSummary(partition: "calder-cpu-turin", nodeCount: 58, state: "idle", cpusPerNode: 128, memoryMBPerNode: 772480, timeLimit: "2-00:00:00"),
        PartitionSummary(partition: "aire-gpu-lovelace", nodeCount: 1, state: "drain*", gres: "gpu:nvidia_l40:3", cpusPerNode: 24, memoryMBPerNode: 256859, timeLimit: "2-00:00:00"),
        PartitionSummary(partition: "calder-gpu-hopper", nodeCount: 4, state: "mix-", gres: "gpu:nvidia_h200:8", cpusPerNode: 128, memoryMBPerNode: 1546664, timeLimit: "2-00:00:00"),
        PartitionSummary(partition: "calder-gpu-hopper", nodeCount: 1, state: "drain", gres: "gpu:nvidia_h200:8", cpusPerNode: 128, memoryMBPerNode: 1546664, timeLimit: "2-00:00:00"),
        PartitionSummary(partition: "calder-gpu-hopper", nodeCount: 2, state: "mix", gres: "gpu:nvidia_h200:8", cpusPerNode: 128, memoryMBPerNode: 1546664, timeLimit: "2-00:00:00")
    ]

    static let calderJobs: [Job] = [
        gpuJob("9863", state: "PENDING", reason: "(JobHeldUser)", timeLimit: "3:00:00", name: "finetune-llm", partition: "calder-gpu-hopper"),
        cpuJob("9926", state: "RUNNING", reason: "", timeLimit: "12:00:00", cpus: 1, nodeList: "calder-cpu001", partition: "calder-cpu-turin", name: "monitor-loop"),
        gpuJob("35796_1", state: "RUNNING", reason: "", elapsed: "2:25:04", timeLimit: "3:00:00", name: "finetune-llm", partition: "calder-gpu-hopper", nodeList: "calder-h200-06", arrayJobID: 35796),
        gpuJob("38961_2", state: "RUNNING", reason: "", elapsed: "1:29:33", timeLimit: "3:00:00", name: "finetune-llm", partition: "calder-gpu-hopper", nodeList: "calder-h200-03", arrayJobID: 38961),
        cpuJob("48081", state: "RUNNING", reason: "", timeLimit: "3:00:00", cpus: 64, nodeList: "calder-cpu008", partition: "calder-cpu-turin"),
        gpuJob(
            "64375", state: "PENDING", reason: "(Resources)", timeLimit: "3:00:00", name: "finetune-llm", partition: "calder-gpu-hopper",
            arrayJobID: 64375, arrayPendingTasks: "4-20", pendingTaskCount: 17
        )
    ]

    static let calderStorage: [StorageSummary] = [
        StorageSummary(
            label: "Home", path: "/users/abcd1234", filesystem: "10.10.0.15:/export/users", source: "quota",
            usedGB: 44.53, quotaGB: 65, limitGB: 65, availableGB: 20.47, usedPercent: 68.5,
            fileCount: 294000, fileQuota: 1500000, fileLimit: 1500000, overQuota: false,
            quotaType: "nfs", mount: "/users"
        ),
        StorageSummary(
            label: "Scratch", path: "/scratch-calder/users/abcd1234", filesystem: "10.20.0.10@o2ib:/scratch", source: "lfs quota",
            usedGB: 926.8, quotaGB: nil, limitGB: 1024, availableGB: 97.2, usedPercent: 90.5,
            fileCount: 751065, fileQuota: nil, fileLimit: 1500000, overQuota: false,
            quotaType: "lustre-project", projectID: 110042, mount: "/scratch-calder"
        ),
        StorageSummary(
            label: "Flash", path: "/flash-calder/users/abcd1234", filesystem: "10.20.0.11@o2ib:/flash", source: "lfs quota",
            usedGB: 639.0, quotaGB: nil, limitGB: 1024, availableGB: 385.0, usedPercent: 62.4,
            fileCount: 271493, fileQuota: nil, fileLimit: 1500000, overQuota: false,
            quotaType: "lustre-project", projectID: 110042, mount: "/flash-calder"
        )
    ]

    static let calderSnapshot = ClusterSnapshot(
        collectedAt: "2026-10-13T11:49:50.285035+00:00",
        cluster: SnapshotClusterInfo(id: "calder", name: "Calder"),
        remote: RemoteInfo(
            host: "calder.leeds.ac.uk", hostname: "calder-login-2", user: "abcd1234",
            cwd: "/users/abcd1234", remoteTime: "2026-10-13T12:49:50+01:00"
        ),
        jobs: calderJobs,
        partitions: calderPartitions,
        nodes: calderNodes,
        storage: calderStorage
    )

    static func snapshot(for id: ClusterID) -> ClusterSnapshot? {
        switch id {
        case .aire: return aireSnapshot
        case .calder: return calderSnapshot
        default: return nil
        }
    }

    static func node(_ name: String, in nodes: [NodeSummary]) -> NodeSummary {
        guard let node = nodes.first(where: { $0.node == name }) else {
            preconditionFailure("fixture node \(name) is missing")
        }
        return node
    }
}
