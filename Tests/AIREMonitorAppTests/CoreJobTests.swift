import HPCCore
import Foundation
import Testing

// Job-level logic shared by the Jobs tab, the overview and the menu bar:
// GPUs read from Slurm's TRES strings, job-array rows, the one display
// order, and hostlist expansion for "which nodes are mine".

@Suite("Core · TRES GPU requests")
struct CoreTRESTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var reqTres: String? = nil
        var allocTres: String? = nil
        var tresPerNode: String? = nil
        var nodes = "1"
        let count: Int?
        let model: String?
        let note: String

        var testDescription: String { note }
    }

    @Test("GPU count and model from the TRES strings Slurm prints", arguments: [
        Case(allocTres: "cpu=8,mem=80G,node=1,billing=8,gres/gpu=1", count: 1, model: nil,
             note: "AIRE running job: AllocTRES"),
        Case(reqTres: "cpu=12,mem=96G,node=1,billing=12,gres/gpu=1", tresPerNode: "gres/gpu:1", count: 1, model: nil,
             note: "Calder pending job: ReqTRES"),
        Case(allocTres: "cpu=8,gres/gpu=2,gres/gpu:nvidia_h200=2", count: 2, model: "nvidia_h200",
             note: "untyped total plus per-type split is not counted twice"),
        Case(allocTres: "cpu=8,gres/gpu:nvidia_h200=2,gres/gpu=2", count: 2, model: "nvidia_h200",
             note: "same, typed entry first"),
        Case(reqTres: "cpu=8,gres/gpu:a100=1,gres/gpu:v100=2", count: 3, model: "a100",
             note: "two typed entries add up; the first model names the request"),
        Case(reqTres: "cpu=4,gres/gpu=2,gres/gpu:l40s=2(IDX:0-1)", count: 2, model: "l40s",
             note: "index suffixes are ignored"),
        Case(reqTres: "CPU=4,GRES/GPU=1", count: 1, model: nil,
             note: "case does not matter"),
        Case(tresPerNode: "gres/gpu:nvidia_h200:2", nodes: "2", count: 4, model: "nvidia_h200",
             note: "TresPerNode (23.02+) is per node and scaled by the node count"),
        Case(tresPerNode: "gres:gpu:2", count: 2, model: nil,
             note: "TresPerNode as printed by 21.08-22.05"),
        Case(tresPerNode: "gpu:l40s:1", count: 1, model: "l40s",
             note: "bare per-node gres from older releases"),
        Case(tresPerNode: "gres/gpu", count: nil, model: nil,
             note: "GPUs named without a count"),
        Case(tresPerNode: "gres/gpu:nvidia_h200", count: nil, model: "nvidia_h200",
             note: "typed GPUs without a count"),
        Case(reqTres: "cpu=8,gres/gpu=4", allocTres: "cpu=8,gres/gpu=2", count: 2, model: nil,
             note: "what Slurm granted wins over what was asked for"),
        Case(reqTres: "cpu=8,gres/gpu=2", tresPerNode: "gres/gpu:1", nodes: "4", count: 2, model: nil,
             note: "a whole-job total wins over the per-node fallback")
    ])
    func gpuRequests(testCase: Case) throws {
        let job = Job(
            jobId: "1", nodes: testCase.nodes,
            reqTres: testCase.reqTres, allocTres: testCase.allocTres, tresPerNode: testCase.tresPerNode
        )
        let request = try #require(job.gpuRequest)
        #expect(request.count == testCase.count)
        #expect(request.model == testCase.model)
    }

    @Test("Jobs without GPUs have no request", arguments: [
        Case(reqTres: "cpu=16,mem=48G,node=1,billing=16", count: nil, model: nil, note: "plain CPU job"),
        Case(reqTres: "cpu=1,gres/gpu=0", count: nil, model: nil, note: "explicit zero GPUs"),
        Case(reqTres: "cpu=1,gres/gpu:nvidia_h200=0", count: nil, model: nil, note: "explicit zero typed GPUs"),
        Case(reqTres: "cpu=4,gres/gpumem=10G,gres/gpuutil=50", count: nil, model: nil, note: "gpumem/gpuutil are not GPU counts"),
        Case(count: nil, model: nil, note: "no TRES at all")
    ])
    func noGPUs(testCase: Case) {
        let job = Job(jobId: "1", nodes: testCase.nodes, reqTres: testCase.reqTres, allocTres: testCase.allocTres, tresPerNode: testCase.tresPerNode)
        #expect(job.gpuRequest == nil)
        #expect(job.requestedGPUCount == 0)
    }

    @Test("A non-numeric node count falls back to one node")
    func nodeCountFallback() {
        let job = Job(jobId: "1", nodes: "", tresPerNode: "gres/gpu:2")
        #expect(job.gpuRequest?.count == 2)
    }

    @Test("Request summaries", arguments: [
        (2 as Int?, "nvidia_h200" as String?, "2 × H200"),
        (1, nil, "1 GPU"),
        (3, nil, "3 GPUs"),
        (nil, "l40s", "L40S GPU"),
        (nil, nil, "GPU")
    ])
    func summaries(count: Int?, model: String?, expected: String) {
        let request = JobGPURequest(count: count, model: model)
        #expect(request.summary == expected)
        #expect(request.modelDisplayName == model.map(gpuModelDisplayName))
    }
}

@Suite("Core · job arrays")
struct CoreJobArrayTests {
    private var remainder: Job { CoreFixtures.aireJobs.first { $0.jobId == "8248307" }! }
    private var firstTask: Job { CoreFixtures.aireJobs.first { $0.jobId == "8248307_0" }! }

    @Test("The pending remainder stands for every queued task")
    func pendingRemainder() {
        #expect(remainder.isArrayRemainder)
        #expect(remainder.taskMultiplicity == 57)
        #expect(remainder.displayJobID == "8248307_[2-58]")
        // One GPU per task, 57 tasks queued.
        #expect(remainder.requestedGPUCount == 57)
        #expect(remainder.arrayThrottle == 4)
    }

    @Test("A running array task is one job with its own id")
    func runningTask() {
        #expect(!firstTask.isArrayRemainder)
        #expect(firstTask.taskMultiplicity == 1)
        #expect(firstTask.displayJobID == "8248307_0")
        #expect(firstTask.requestedGPUCount == 1)
        #expect(firstTask.arrayJobID == 8248307)
    }

    @Test("Plain jobs and incomplete remainders never count as zero jobs")
    func edgeCases() {
        let plain = Job(jobId: "8248326")
        #expect(!plain.isArrayRemainder)
        #expect(plain.taskMultiplicity == 1)
        #expect(plain.displayJobID == "8248326")

        let noCount = Job(jobId: "77", arrayJobID: 77, arrayPendingTasks: "1-3")
        #expect(noCount.isArrayRemainder)
        #expect(noCount.taskMultiplicity == 1)

        let zeroCount = Job(jobId: "77", arrayJobID: 77, arrayPendingTasks: "1-3", pendingTaskCount: 0)
        #expect(zeroCount.taskMultiplicity == 1)

        let noTasks = Job(jobId: "77", arrayJobID: 77, arrayPendingTasks: "", pendingTaskCount: 3)
        #expect(noTasks.displayJobID == "77")
    }

    @Test("Queue totals count array tasks, not rows")
    func queueTotals() {
        let pending = CoreFixtures.aireJobs.filter { $0.jobState.isPending }
        #expect(pending.count == 5)
        #expect(pending.reduce(0) { $0 + $1.taskMultiplicity } == 61)
        #expect(pending.reduce(0) { $0 + $1.requestedGPUCount } == 59)
    }
}

@Suite("Core · job display order")
struct CoreJobOrderTests {
    @Test("Running, then waiting on resources, then dependencies, then held, then the rest")
    func fixtureOrder() {
        let ordered = CoreFixtures.aireJobs.sorted(by: jobDisplayOrder).map(\.jobId)
        #expect(ordered == ["8248307_0", "8248307_1", "8248307", "8248326", "8247672", "8248328", "8248684"])
    }

    @Test("Every rank, with natural id order inside a rank")
    func ranks() {
        let jobs = [
            Job(jobId: "10", state: "SUSPENDED"),
            Job(jobId: "9", state: "PENDING", reasonOrNodeList: "(JobHeldAdmin)"),
            Job(jobId: "8", state: "PENDING", reasonOrNodeList: "(DependencyNeverSatisfied)"),
            Job(jobId: "7", state: "PENDING", reasonOrNodeList: "(Resources)"),
            Job(jobId: "123_10", state: "RUNNING", reasonOrNodeList: "gpu010"),
            Job(jobId: "123_2", state: "RUNNING", reasonOrNodeList: "gpu002"),
            Job(jobId: "5", state: "COMPLETING"),
            Job(jobId: "6", state: "CONFIGURING"),
            Job(jobId: "11", state: "REQUEUED", reasonOrNodeList: "(BeginTime)"),
            Job(jobId: "4", state: "PENDING", reasonOrNodeList: "(JobHeldUser)"),
            Job(jobId: "3", state: "COMPLETED")
        ]
        let ordered = jobs.sorted(by: jobDisplayOrder).map(\.jobId)
        #expect(ordered == ["5", "6", "123_2", "123_10", "7", "11", "8", "4", "9", "3", "10"])
    }

    @Test("The order does not depend on the input order")
    func deterministic() {
        let jobs = CoreFixtures.aireJobs + CoreFixtures.calderJobs
        let forward = jobs.sorted(by: jobDisplayOrder).map(\.jobId)
        let backward = jobs.reversed().sorted(by: jobDisplayOrder).map(\.jobId)
        #expect(forward == backward)
        for job in jobs {
            #expect(!jobDisplayOrder(job, job), "a strict order is irreflexive")
        }
    }
}

@Suite("Core · node lists")
struct CoreHostlistTests {
    @Test("Compressed Slurm hostlists expand to exact hostnames", arguments: [
        ("gpu[001-004,007]", ["gpu001", "gpu002", "gpu003", "gpu004", "gpu007"]),
        ("calder-h200-[01-03]", ["calder-h200-01", "calder-h200-02", "calder-h200-03"]),
        ("gpu[001-002],cpu[01-03]", ["gpu001", "gpu002", "cpu01", "cpu02", "cpu03"]),
        ("gpu[001-004,007],cpu01", ["gpu001", "gpu002", "gpu003", "gpu004", "gpu007", "cpu01"]),
        ("node[8-11]", ["node8", "node9", "node10", "node11"]),
        ("node[08-11]", ["node08", "node09", "node10", "node11"]),
        ("node[1-2]-ib", ["node1-ib", "node2-ib"]),
        ("gpu003", ["gpu003"]),
        ("calder-cpu093,calder-h200-06", ["calder-cpu093", "calder-h200-06"]),
        (" gpu003\n", ["gpu003"]),
        ("(null)", []),
        ("", [])
    ])
    func expansion(compressed: String, expected: [String]) {
        #expect(expandNodeList(compressed) == expected)
    }

    @Test("Nodes in use come from jobs that hold nodes")
    func busyNodes() {
        let jobs = [
            Job(jobId: "1", state: "RUNNING", reasonOrNodeList: "gpu[001-002]", nodeList: "gpu[001-002]"),
            // No node_list (older collector): squeue's %R is the node list.
            Job(jobId: "2", state: "RUNNING", reasonOrNodeList: "gpu010"),
            Job(jobId: "3", state: "COMPLETING", nodeList: "gpu003"),
            // A completing job without node_list: %R may be a reason.
            Job(jobId: "4", state: "COMPLETING", reasonOrNodeList: "(None)"),
            Job(jobId: "5", state: "PENDING", reasonOrNodeList: "(Priority)"),
            Job(jobId: "6", state: "SUSPENDED", nodeList: "gpu004")
        ]
        #expect(busyNodeSet(for: jobs) == ["gpu001", "gpu002", "gpu010", "gpu003"])
    }

    @Test("Membership is exact: gpu1 never matches gpu10")
    func exactMatching() {
        let busy = busyNodeSet(for: [Job(jobId: "1", state: "RUNNING", nodeList: "gpu1")])
        #expect(busy.contains("gpu1"))
        #expect(!busy.contains("gpu10"))
        #expect(!busy.contains("gpu11"))
    }

    @Test("Calder fixture: the nodes running the user's jobs")
    func calderBusyNodes() {
        #expect(busyNodeSet(for: CoreFixtures.calderJobs) == ["calder-cpu001", "calder-h200-06", "calder-h200-03", "calder-cpu008"])
    }
}
