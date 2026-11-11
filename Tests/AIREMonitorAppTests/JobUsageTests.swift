import HPCCore
import Foundation
import Testing
@testable import AIREMonitorApp

@Suite("Job usage")
struct JobUsageTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func gpu(_ index: Int, _ utilization: Double, used: Double = 40_000, total: Double = 143_771) -> GPUUsage {
        GPUUsage(index: index, name: "NVIDIA H200", utilizationPercent: utilization, memoryUsedMB: used, memoryTotalMB: total)
    }

    private func summary(_ gpus: [GPUUsage], indices: [Int]? = nil, cpus: Int? = 32, busy: Double? = 8, memory: Double? = 16_384, limit: Double? = 65_536) -> JobUsageSummary {
        JobUsageSummary(displayID: "1", sampledAt: t0, nodes: [
            JobNodeUsage(
                jobID: "1", displayID: "1", node: "gpu01",
                cpusAllocated: cpus, cpusBusy: busy,
                memoryUsedMB: memory, memoryLimitMB: limit,
                gpuIndices: indices ?? gpus.compactMap(\.index), gpus: gpus
            )
        ])
    }

    @Test("Verdicts: well used, some GPUs idle, partly used, mostly idle, unknown")
    func verdicts() {
        #expect(summary([gpu(0, 95), gpu(1, 88)]).gpuVerdict == .wellUsed)
        #expect(summary([gpu(0, 99), gpu(1, 0), gpu(2, 1), gpu(3, 97)]).gpuVerdict == .someIdle(idle: 2, of: 4))
        #expect(summary([gpu(0, 55)]).gpuVerdict == .partlyUsed)
        #expect(summary([gpu(0, 3), gpu(1, 2)]).gpuVerdict == .mostlyIdle)
        let unsampled = summary([], indices: [0, 1])
        #expect(unsampled.gpuVerdict == .unknown)
        #expect(unsampled.verdictText == "No GPU figures this time")
        #expect(summary([], indices: []).verdictText == "CPU job")
    }

    @Test("Fractions and the one-line GPU headline")
    func fractions() {
        let usage = summary([gpu(0, 90, used: 71_885.5), gpu(1, 70, used: 71_885.5)])
        #expect(usage.meanGPUUtilization == 80)
        #expect(usage.gpuMemoryFraction == 0.5)
        #expect(usage.cpuFraction == 0.25)
        #expect(usage.memoryFraction == 0.25)
        #expect(usage.gpuHeadline == "2 × H200 at 80% · 50% GPU memory")
        #expect(JobUsageSummary.shortGPUName("NVIDIA L40S") == "L40S")
    }

    @Test("Rows from several nodes group by the id the job list shows")
    func grouping() {
        let rows = [
            JobNodeUsage(jobID: "9", displayID: "5_2", node: "gpu02", cpusAllocated: 8, cpusBusy: 7, gpuIndices: [0], gpus: [gpu(0, 90)]),
            JobNodeUsage(jobID: "9", displayID: "5_2", node: "gpu01", cpusAllocated: 8, cpusBusy: 5, gpuIndices: [1], gpus: [gpu(1, 70)]),
            JobNodeUsage(jobID: "10", displayID: "10", node: "cpu01", note: "the job ended before the node could be sampled")
        ]
        let summaries = JobUsageSummary.summaries(from: rows, sampledAt: t0)
        #expect(summaries.keys.sorted() == ["10", "5_2"])
        let array = try! #require(summaries["5_2"])
        #expect(array.nodes.map(\.node) == ["gpu01", "gpu02"])
        #expect(array.cpusBusy == 12)
        #expect(array.cpusAllocated == 16)
        #expect(array.allocatedGPUCount == 2)
        #expect(summaries["10"]?.notes == ["the job ended before the node could be sampled"])
    }

    @Test("History keeps a bounded trend per running job and forgets finished ones")
    func history() {
        var history = JobUsageHistory()
        for minute in 0..<(JobUsageHistory.maximumPoints + 5) {
            let sample = JobUsageSummary(displayID: "1", sampledAt: t0.addingTimeInterval(Double(minute) * 60), nodes: summary([gpu(0, minute.isMultiple(of: 2) ? 100 : 50)]).nodes)
            history.record(["1": sample], running: ["1", "2"])
        }
        #expect(history.series(for: "1").count == JobUsageHistory.maximumPoints)
        #expect(history.sustainedGPUUtilization(for: "1") == 75)
        // The same sample twice is one point.
        let last = JobUsageSummary(displayID: "1", sampledAt: history.series(for: "1").last!.date, nodes: [])
        history.record(["1": last], running: ["1"])
        #expect(history.series(for: "1").count == JobUsageHistory.maximumPoints)
        history.record([:], running: [])
        #expect(history.points.isEmpty)
    }

    @Test("The collector's job_usage JSON decodes; a bad row is skipped, not fatal")
    func decoding() throws {
        let json = #"""
        {"collected_at": "2026-10-26T01:00:00+00:00", "remote": {}, "jobs": [], "partitions": [], "nodes": [], "errors": [],
         "job_usage": [
          {"job_id": "500", "display_id": "500", "node": "gpu01", "cpus_allocated": 4, "cpus_busy": 2.0,
           "memory_used_mb": 1024.0, "memory_charged_mb": 2048.0, "memory_peak_mb": 3072.0, "memory_limit_mb": 8000.0,
           "gpu_indices": [0, 1],
           "gpus": [{"index": 0, "name": "NVIDIA H200", "utilization_percent": 95.0, "memory_activity_percent": 40.0,
                     "memory_used_mb": 70000.0, "memory_total_mb": 143771.0, "power_watts": 650.5,
                     "power_limit_watts": 700.0, "temperature_c": 60.0}],
           "note": null},
          {"display_id": "broken"}
         ]}
        """#
        let snapshot = try JSONDecoder().decode(ClusterSnapshot.self, from: Data(json.utf8))
        let rows = try #require(snapshot.jobUsage)
        #expect(rows.count == 1)
        #expect(rows[0].gpus.first?.utilizationPercent == 95)
        #expect(rows[0].gpus.first?.memoryFraction ?? 0 > 0.48)
        #expect(snapshot.warnings.contains { $0.contains("job usage row") })

        let without = try JSONDecoder().decode(ClusterSnapshot.self, from: Data(#"{"collected_at": "x", "jobs": []}"#.utf8))
        #expect(without.jobUsage == nil)
    }

    @Test("--job-usage is added only when asked, never to the widget's collector.json arguments")
    func collectorFlag() {
        let settings = ConnectionSettings(
            clusterID: .calder, clusterName: "Calder", username: "u1", hostname: "calder.leeds.ac.uk",
            route: .directVPN, jumpHostname: HPCDefaults.jumpHostname, duoOption: "1", projectRoot: "/tmp/x",
            storage: ClusterProfile.calder.storage
        )
        #expect(!MonitorService.collectorArguments(settings: settings).contains(MonitorService.jobUsageFlag))
        #expect(MonitorService.collectorArguments(settings: settings, skipStorage: true, jobUsage: true).suffix(2)
            == [MonitorService.skipStorageFlag, MonitorService.jobUsageFlag])
    }
}

@MainActor
@Suite("ClusterSession · job usage cadence")
struct SessionJobUsageTests {
    private let running = Job(jobId: "500", name: "train", state: "RUNNING")
    private let pending = Job(jobId: "501", name: "next", state: "PENDING")

    private func usageRows(_ utilization: Double) -> [JobNodeUsage] {
        [JobNodeUsage(jobID: "500", displayID: "500", node: "gpu01", cpusAllocated: 8, cpusBusy: 4, gpuIndices: [0],
                      gpus: [GPUUsage(index: 0, name: "NVIDIA H200", utilizationPercent: utilization, memoryUsedMB: 1, memoryTotalMB: 2)])]
    }

    @Test("Sampled once a minute while a job runs, only when switched on")
    func cadence() async throws {
        let snapshot = makeSnapshot(jobs: [running, pending])
        let harness = try SessionHarness(backend: FakeBackend(snapshot: snapshot))
        harness.host.sampleJobUsage = true
        try await harness.startAndSettle()
        // The startup probe has no snapshot yet, so nothing is known to run.
        #expect(harness.backend.jobUsageFlags == [false])

        harness.backend.setFallback(.success(ClusterSnapshot(
            collectedAt: "2026-10-13T12:00:10Z", remote: snapshot.remote, jobs: [running, pending],
            jobUsage: usageRows(90)
        )))
        harness.clock.advance(10)
        try await harness.tick()
        #expect(harness.backend.jobUsageFlags.last == true)
        #expect(harness.session.jobUsage["500"]?.meanGPUUtilization == 90)
        #expect(harness.session.jobUsageHistory.series(for: "500").count == 1)

        // Within the minute: not asked again, the figures stay.
        harness.backend.setFallback(.success(ClusterSnapshot(collectedAt: "2026-10-13T12:00:20Z", remote: snapshot.remote, jobs: [running, pending])))
        harness.clock.advance(10)
        try await harness.tick()
        #expect(harness.backend.jobUsageFlags.last == false)
        #expect(harness.session.jobUsage["500"] != nil)

        harness.clock.advance(60)
        try await harness.tick()
        #expect(harness.backend.jobUsageFlags.last == true)

        // The job finished: its figures and trend go.
        harness.backend.setFallback(.success(ClusterSnapshot(collectedAt: "2026-10-13T12:02:00Z", remote: snapshot.remote, jobs: [pending])))
        harness.clock.advance(10)
        try await harness.tick()
        #expect(harness.session.jobUsage.isEmpty)
        #expect(harness.session.jobUsageHistory.points.isEmpty)

        // Switched off: never asked, even with a job running.
        harness.host.sampleJobUsage = false
        harness.backend.setFallback(.success(ClusterSnapshot(collectedAt: "2026-10-13T12:03:00Z", remote: snapshot.remote, jobs: [running])))
        harness.clock.advance(120)
        try await harness.tick()
        try await harness.tick()
        #expect(harness.backend.jobUsageFlags.suffix(2) == [false, false])
    }
}
