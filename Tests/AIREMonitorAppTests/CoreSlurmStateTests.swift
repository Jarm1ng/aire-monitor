import HPCCore
import Foundation
import Testing
@testable import AIREMonitorApp

// Job and node states are separate Slurm vocabularies. Matching them by
// substring once counted SUSPENDED jobs as pending ("pend"), a node in a
// maintenance reservation ("idle$") as free capacity, and job TIMEOUT as a
// node fault. These tables pin the parsing in HPCCore (JobState,
// NodeStateInfo) to the strings the collector really emits: squeue %T for
// jobs, sinfo %t (compact, flags as trailing symbols) for nodes.

@Suite("Core · job states")
struct CoreJobStateTests {
    @Test("Long names and squeue's compact codes parse to the same state", arguments: [
        ("RUNNING", JobState.running), ("R", .running),
        ("PENDING", .pending), ("PD", .pending),
        ("SUSPENDED", .suspended), ("S", .suspended), ("STOPPED", .suspended), ("ST", .suspended),
        ("COMPLETING", .completing), ("CG", .completing),
        ("CONFIGURING", .configuring), ("CF", .configuring),
        ("REQUEUED", .requeued), ("RQ", .requeued), ("REQUEUE_HOLD", .requeued), ("RH", .requeued),
        ("REQUEUE_FED", .requeued), ("RF", .requeued),
        ("COMPLETED", .finished("COMPLETED")), ("CD", .finished("CD")),
        ("FAILED", .finished("FAILED")), ("TIMEOUT", .finished("TIMEOUT")),
        ("OUT_OF_MEMORY", .finished("OUT_OF_MEMORY")), ("NODE_FAIL", .finished("NODE_FAIL")),
        ("PREEMPTED", .finished("PREEMPTED")), ("BOOT_FAIL", .finished("BOOT_FAIL")),
        ("DEADLINE", .finished("DEADLINE")), ("REVOKED", .finished("REVOKED")),
        ("SPECIAL_EXIT", .finished("SPECIAL_EXIT"))
    ])
    func parsing(raw: String, expected: JobState) {
        #expect(JobState(raw) == expected)
    }

    @Test("Case, surrounding whitespace and trailing flags are ignored", arguments: [
        ("running", JobState.running),
        (" PENDING\n", .pending),
        ("CANCELLED by 12345", .finished("CANCELLED")),
        ("RUNNING+SIGNALING", .running)
    ])
    func normalisation(raw: String, expected: JobState) {
        #expect(JobState(raw) == expected)
    }

    @Test("SUSPENDED is neither pending nor running")
    func suspendedIsItsOwnState() {
        // The substring parser read "SUSPENDED" as pending because of "pend".
        let state = JobState("SUSPENDED")
        #expect(!state.isPending)
        #expect(!state.isRunning)
        #expect(!state.occupiesNodes)
        #expect(!state.isFinished)
        #expect(state.label == "Suspended")
    }

    @Test("Which states hold nodes, wait in the queue or are over")
    func predicates() {
        #expect(JobState.running.isRunning && JobState.running.occupiesNodes)
        // Completing and configuring jobs still hold their nodes but are not
        // "running" in the job counts.
        for state in [JobState.completing, .configuring] {
            #expect(state.occupiesNodes)
            #expect(!state.isRunning)
            #expect(!state.isPending)
        }
        // A requeued job waits in the queue again.
        #expect(JobState.requeued.isPending)
        #expect(JobState.pending.isPending)
        #expect(!JobState.pending.occupiesNodes)
        for raw in ["COMPLETED", "FAILED", "TIMEOUT", "CANCELLED"] {
            let state = JobState(raw)
            #expect(state.isFinished)
            #expect(!state.occupiesNodes)
            #expect(!state.isPending)
        }
    }

    @Test("Labels read as words, never as raw identifiers")
    func labels() {
        #expect(JobState("PD").label == "Pending")
        #expect(JobState("R").label == "Running")
        #expect(JobState("CG").label == "Completing")
        #expect(JobState("RH").label == "Requeued")
        #expect(JobState("TIMEOUT").label == "Timeout")
        #expect(JobState("OUT_OF_MEMORY").label.lowercased() == "out of memory")
        #expect(JobState("NODE_FAIL").label.lowercased() == "node fail")
        #expect(JobState("").label == "Unknown")
        #expect(JobState("SIGNALING").label == "Signaling")
    }

    @Test("Unfamiliar states are kept, not guessed")
    func unknownStates() {
        #expect(JobState("RESIZING") == .other("RESIZING"))
        #expect(JobState("") == .other(""))
        let state = JobState("STAGE_OUT")
        #expect(!state.isPending && !state.isRunning && !state.occupiesNodes && !state.isFinished)
    }

    @Test("A job's state comes from its squeue state column")
    func jobAccessor() {
        let job = Job(jobId: "1", state: "SUSPENDED")
        #expect(job.jobState == .suspended)
    }
}

@Suite("Core · node states")
struct CoreNodeStateTests {
    /// Every compact sinfo %t base state, with the availability rule: only
    /// idle, mixed, allocated, completing and planned nodes accept work.
    @Test("Compact base states", arguments: [
        ("idle", NodeStateInfo.Base.idle, true),
        ("mix", .mixed, true),
        ("alloc", .allocated, true),
        ("comp", .completing, true),
        ("plnd", .planned, true),
        ("drng", .draining, false),
        ("drain", .drained, false),
        ("down", .down, false),
        ("fail", .failed, false),
        ("failg", .failing, false),
        ("maint", .maintenance, false),
        ("resv", .reserved, false),
        ("futr", .future, false),
        ("blocked", .blocked, false),
        ("inval", .invalid, false),
        ("boot", .booting, false),
        ("pow_dn", .poweredDown, false),
        ("unk", .unknown, false),
        ("", .unknown, false),
        ("npc", .unknown, false)
    ])
    func compactBases(raw: String, base: NodeStateInfo.Base, available: Bool) {
        let info = NodeStateInfo(raw)
        #expect(info.base == base)
        #expect(info.isAvailable == available)
        #expect(info.raw == raw)
    }

    @Test("Compact states seen on AIRE and Calder, with their trailing flags", arguments: [
        // raw, base, available, not responding, maintenance, planned
        ("mix-", NodeStateInfo.Base.mixed, true, false, false, true),
        ("down$", .down, false, false, true, false),
        ("down*", .down, false, true, false, false),
        ("drain", .drained, false, false, false, false),
        ("drain*", .drained, false, true, false, false),
        ("drain$", .drained, false, false, true, false),
        ("idle$", .idle, false, false, true, false),
        ("idle*", .idle, false, true, false, false),
        ("mix*", .mixed, false, true, false, false),
        ("alloc$", .allocated, false, false, true, false),
        ("drain$*", .drained, false, true, true, false)
    ])
    func flaggedStates(raw: String, base: NodeStateInfo.Base, available: Bool, notResponding: Bool, maintenance: Bool, planned: Bool) {
        let info = NodeStateInfo(raw)
        #expect(info.base == base)
        #expect(info.isAvailable == available)
        #expect(info.notResponding == notResponding)
        #expect(info.maintenanceReservation == maintenance)
        #expect(info.plannedByBackfill == planned)
    }

    @Test("A maintenance reservation is never free capacity")
    func maintenanceReservation() {
        // The old parser read "idle$" as idle and counted it as free.
        let info = NodeStateInfo("idle$")
        #expect(info.base == .idle)
        #expect(!info.isAvailable)
        #expect(info.flagDescriptions == ["in a maintenance reservation"])
    }

    @Test("Power and reboot flags", arguments: [
        // raw, available, power saving, powering down, reboot pending
        ("idle~", true, true, false, false),
        ("idle#", true, true, false, false),
        ("idle%", false, false, true, false),
        ("idle!", false, false, true, false),
        ("mix@", false, false, false, true),
        ("idle^", false, false, false, true)
    ])
    func powerFlags(raw: String, available: Bool, powerSaving: Bool, poweringDown: Bool, reboot: Bool) {
        // "~"/"#": powered off or powering up for energy saving, which the
        // scheduler resumes on demand, so the node still counts.
        let info = NodeStateInfo(raw)
        #expect(info.base == .idle || info.base == .mixed)
        #expect(info.isAvailable == available)
        #expect(info.powerSaving == powerSaving)
        #expect(info.poweringDown == poweringDown)
        #expect(info.rebootPending == reboot)
    }

    @Test("Case and whitespace do not matter", arguments: ["MIX-", " mix- ", "Mix-\n"])
    func normalisation(raw: String) {
        let info = NodeStateInfo(raw)
        #expect(info.base == .mixed)
        #expect(info.plannedByBackfill)
        #expect(info.isAvailable)
    }

    @Test("Long forms (sinfo %T, scontrol State=)", arguments: [
        ("MIXED", NodeStateInfo.Base.mixed, true),
        ("ALLOCATED", .allocated, true),
        ("IDLE+PLANNED", .planned, true),
        ("MIXED+PLANNED", .mixed, true),
        ("IDLE+DRAIN", .drained, false),
        ("DOWN+DRAIN", .drained, false),
        ("MIXED+DRAIN", .draining, false),
        ("ALLOCATED+DRAIN", .draining, false),
        ("IDLE+DRAIN+NOT_RESPONDING", .drained, false),
        ("DOWN+NOT_RESPONDING", .down, false),
        ("IDLE+MAINT", .idle, false),
        ("IDLE+REBOOT_REQUESTED", .idle, false),
        ("IDLE+CLOUD", .idle, true)
    ])
    func longForms(raw: String, base: NodeStateInfo.Base, available: Bool) {
        let info = NodeStateInfo(raw)
        #expect(info.base == base)
        #expect(info.isAvailable == available)
    }

    @Test("A long form agrees with its compact equivalent", arguments: [
        ("IDLE+DRAIN", "drain"),
        ("MIXED+DRAIN", "drng"),
        ("DOWN+NOT_RESPONDING", "down*"),
        ("IDLE+MAINT", "idle$"),
        ("MIXED+PLANNED", "mix-"),
        ("IDLE+REBOOT_REQUESTED", "idle@")
    ])
    func longAndCompactAgree(long: String, compact: String) {
        let longInfo = NodeStateInfo(long)
        let compactInfo = NodeStateInfo(compact)
        #expect(longInfo.base == compactInfo.base)
        #expect(longInfo.isAvailable == compactInfo.isAvailable)
        #expect(longInfo.flagDescriptions == compactInfo.flagDescriptions)
    }

    @Test("Long-form power, FAIL and RESERVED flags agree with their compact codes", arguments: [
        // POWERED_DOWN is "~" (the scheduler resumes it), not "%"/"!".
        ("IDLE+POWERED_DOWN", "idle~"),
        // FAIL is "fail"/"failg": the admins expect the node to fail.
        ("IDLE+FAIL", "fail"),
        ("MIXED+FAIL", "failg"),
        // A node in an advanced reservation is "resv".
        ("IDLE+RESERVED", "resv")
    ])
    func longFormFlagsAgree(long: String, compact: String) {
        // The collector reads sinfo %t, so these long forms do not reach the
        // dashboards today; they matter as soon as anything feeds scontrol's
        // State= into NodeStateInfo.
        let longInfo = NodeStateInfo(long)
        let compactInfo = NodeStateInfo(compact)
        #expect(longInfo.base == compactInfo.base)
        #expect(longInfo.isAvailable == compactInfo.isAvailable)
        #expect(longInfo.flagDescriptions == compactInfo.flagDescriptions)
    }

    @Test("Display labels are plain words")
    func displayLabels() {
        #expect(NodeStateInfo("mix-").displayLabel == "Mixed")
        #expect(NodeStateInfo("drain*").displayLabel == "Drained")
        #expect(NodeStateInfo("drng").displayLabel == "Draining")
        #expect(NodeStateInfo("down$").displayLabel == "Down")
        #expect(NodeStateInfo("plnd").displayLabel == "Idle (planned)")
        #expect(NodeStateInfo("alloc").displayLabel == "Allocated")
        #expect(NodeStateInfo("pow_dn").displayLabel == "Powered down")
        #expect(NodeStateInfo("").displayLabel == "Unknown")
        // An unfamiliar state is shown as Slurm spelled it rather than guessed.
        #expect(NodeStateInfo("npc").displayLabel == "NPC")
    }

    @Test("sinfo's own spelling of UNKNOWN reads as a word")
    func unknownLabel() {
        #expect(NodeStateInfo("unk").displayLabel == "Unknown")
        #expect(NodeStateInfo("UNKNOWN*").displayLabel == "Unknown")
    }

    @Test("Flag descriptions explain every trailing symbol, in a fixed order")
    func flagDescriptions() {
        #expect(NodeStateInfo("mix").flagDescriptions.isEmpty)
        #expect(NodeStateInfo("down*").flagDescriptions == ["not responding"])
        #expect(NodeStateInfo("mix-").flagDescriptions == ["planned by backfill for a queued job"])
        #expect(NodeStateInfo("drain$*").flagDescriptions == ["not responding", "in a maintenance reservation"])
        #expect(NodeStateInfo("idle~").flagDescriptions == ["powered down to save energy"])
        #expect(NodeStateInfo("idle%").flagDescriptions == ["powering down"])
        #expect(NodeStateInfo("mix@").flagDescriptions == ["reboot pending"])
    }

    @Test("Every fixture node's availability follows its state")
    func fixtureAvailability() {
        let unavailable = (CoreFixtures.aireNodes + CoreFixtures.calderNodes)
            .filter { !$0.stateInfo.isAvailable }
            .map(\.node)
        #expect(unavailable == [
            "gpu021", "gpu028",
            "calder-h200-05", "gpu028", "calder-cpu091", "calder-cpu098", "node056", "node057", "node058"
        ])
        #expect(isAvailable(CoreFixtures.node("calder-h200-04", in: CoreFixtures.calderNodes)))
    }

    @Test("An \"up\" partition whose every sinfo row is drained offers no capacity")
    func allDrainedPartition() {
        // Calder's aire-cpu-genoa: sinfo says "up", but its rows are drain$,
        // drain* and drain. Partition health must come from the row states,
        // never from the availability column alone.
        let rows = CoreFixtures.calderPartitions.filter { $0.partition == "aire-cpu-genoa" }
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.availability == "up" })
        #expect(rows.allSatisfy { !NodeStateInfo($0.state).isAvailable })
        #expect(rows.reduce(0) { $0 + ($1.nodeCount ?? 0) } == 8)

        let nodes = CoreFixtures.calderNodes.filter { $0.partitions.contains("aire-cpu-genoa") }
        #expect(!nodes.isEmpty)
        #expect(nodes.allSatisfy { !$0.stateInfo.isAvailable })

        // A partition with some usable rows does offer capacity.
        let turin = CoreFixtures.calderPartitions.filter { $0.partition == "calder-cpu-turin" }
        let usable = turin.filter { NodeStateInfo($0.state).isAvailable }.reduce(0) { $0 + ($1.nodeCount ?? 0) }
        #expect(usable == 96)
    }
}

/// The app's colour layer must agree with HPCCore's availability rule: a node
/// that accepts no work never gets a "usable capacity" colour, and a
/// suspended job never looks pending.
@Suite("Core · state colours follow the parsed state")
struct CoreSlurmStateColourTests {
    @Test("Nodes that accept no work are drawn as unavailable", arguments: [
        "down$", "down*", "drain", "drain*", "drain$", "drng", "idle$", "idle*", "mix@", "idle%", "resv", "maint", "fail"
    ])
    func unavailableNodes(raw: String) {
        #expect(SlurmState(node: raw) == .unavailable)
        #expect(SlurmState(parsing: raw) == .unavailable)
    }

    @Test("Usable nodes keep their occupancy colour", arguments: [
        ("idle", SlurmState.idle), ("plnd", .idle), ("idle~", .idle),
        ("mix", .mixed), ("mix-", .mixed), ("alloc", .allocated), ("comp", .completing)
    ])
    func usableNodes(raw: String, expected: SlurmState) {
        #expect(SlurmState(node: raw) == expected)
        #expect(SlurmState(parsing: raw) == expected)
    }

    @Test("Job states map onto the job palette", arguments: [
        ("RUNNING", SlurmState.running), ("CONFIGURING", .running),
        ("PENDING", .pending), ("REQUEUED", .pending),
        ("SUSPENDED", .suspended), ("COMPLETING", .completing),
        ("COMPLETED", .finished), ("FAILED", .failed), ("TIMEOUT", .failed)
    ])
    func jobs(raw: String, expected: SlurmState) {
        #expect(SlurmState(job: raw) == expected)
        #expect(SlurmState(parsing: raw) == expected)
    }

    @Test("An unfamiliar node state is unknown, not a fault")
    func unknownNode() {
        #expect(SlurmState(node: "npc") == .unknown)
        #expect(SlurmState(node: "unk*") == .unavailable)
    }
}
