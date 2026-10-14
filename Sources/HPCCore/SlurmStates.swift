import Foundation

// Job and node states are different vocabularies and are parsed separately:
// mixing them by substring once counted SUSPENDED jobs as pending ("pend"),
// node maintenance reservations ("idle$") as free capacity, and job TIMEOUT
// as a node fault.

/// A Slurm job state, from squeue's long form (`RUNNING`, `PENDING`, …) or
/// its compact codes (`R`, `PD`, …). Flags after "+" or a space are ignored.
public enum JobState: Equatable, Sendable {
    case pending
    case running
    case suspended
    case completing
    case configuring
    /// Requeued or held for requeue: waiting to run again.
    case requeued
    /// A terminal state (COMPLETED, FAILED, CANCELLED, TIMEOUT, …).
    case finished(String)
    case other(String)

    public init(_ raw: String) {
        let base = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .prefix { $0 != "+" && $0 != " " }
        switch base {
        case "PENDING", "PD":
            self = .pending
        case "RUNNING", "R":
            self = .running
        case "SUSPENDED", "S", "STOPPED", "ST":
            self = .suspended
        case "COMPLETING", "CG":
            self = .completing
        case "CONFIGURING", "CF":
            self = .configuring
        case "REQUEUED", "RQ", "REQUEUE_HOLD", "RH", "REQUEUE_FED", "RF":
            self = .requeued
        case "COMPLETED", "CD", "CANCELLED", "CA", "FAILED", "F", "TIMEOUT", "TO",
             "NODE_FAIL", "NF", "PREEMPTED", "PR", "BOOT_FAIL", "BF", "DEADLINE", "DL",
             "OUT_OF_MEMORY", "OOM", "REVOKED", "RV", "SPECIAL_EXIT", "SE":
            self = .finished(String(base))
        default:
            self = .other(String(base))
        }
    }

    /// Holding resources and doing work.
    public var isRunning: Bool { self == .running }

    /// Waiting in the queue (including requeued jobs).
    public var isPending: Bool { self == .pending || self == .requeued }

    /// Occupies nodes right now: running, completing or still configuring.
    public var occupiesNodes: Bool {
        switch self {
        case .running, .completing, .configuring:
            return true
        default:
            return false
        }
    }

    public var isFinished: Bool {
        if case .finished = self {
            return true
        }
        return false
    }

    public var label: String {
        switch self {
        case .pending: return "Pending"
        case .running: return "Running"
        case .suspended: return "Suspended"
        case .completing: return "Completing"
        case .configuring: return "Configuring"
        case .requeued: return "Requeued"
        case .finished(let raw): return raw.capitalized.replacingOccurrences(of: "_", with: " ")
        case .other(let raw): return raw.isEmpty ? "Unknown" : raw.capitalized.replacingOccurrences(of: "_", with: " ")
        }
    }
}

/// A Slurm node state from `sinfo %t` (compact: `mix-`, `drain*`, `down$`,
/// `plnd`) or `%T`/scontrol (long: `MIXED+PLANNED`, `IDLE+DRAIN`).
public struct NodeStateInfo: Equatable, Sendable {
    public enum Base: String, Sendable {
        case idle
        case mixed
        case allocated
        case completing
        /// IDLE+PLANNED: idle, earmarked by backfill for a queued job.
        case planned
        case draining
        case drained
        case down
        case failing
        case failed
        case maintenance
        case reserved
        case future
        case blocked
        case invalid
        case booting
        case rebooting
        case poweredDown
        case unknown
    }

    public let raw: String
    public let base: Base
    /// "*": the node is not responding.
    public let notResponding: Bool
    /// "$": the node is in a maintenance reservation.
    public let maintenanceReservation: Bool
    /// "-": planned by the backfill scheduler for a higher-priority job.
    public let plannedByBackfill: Bool
    /// "~" powered off (the scheduler can resume it), "#" powering up.
    public let powerSaving: Bool
    /// "%" powering down, "!" pending power down.
    public let poweringDown: Bool
    /// "@" reboot pending, "^" reboot issued.
    public let rebootPending: Bool

    public init(_ raw: String) {
        self.raw = raw
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var notResponding = false
        var maintenance = false
        var planned = false
        var powerSaving = false
        var poweringDown = false
        var reboot = false
        // Compact flags are trailing symbols, possibly several.
        while let last = text.last, "*$-~#%!@^".contains(last) {
            switch last {
            case "*": notResponding = true
            case "$": maintenance = true
            case "-": planned = true
            case "~", "#": powerSaving = true
            case "%", "!": poweringDown = true
            case "@", "^": reboot = true
            default: break
            }
            text.removeLast()
        }
        // Long forms combine a base with "+FLAG" parts.
        let parts = text.split(separator: "+").map(String.init)
        let head = parts.first ?? ""
        let flags = Set(parts.dropFirst())
        var base = Self.base(named: head)
        if flags.contains("drain") {
            base = (base == .idle || base == .down || base == .planned) ? .drained : .draining
        } else if flags.contains("fail") {
            // Compact "fail" (nothing running) and "failg" (work still on it).
            base = (base == .idle || base == .down || base == .planned) ? .failed : .failing
        } else if flags.contains("reserved") || flags.contains("resv"), base == .idle {
            // An idle node in an advanced reservation is compact "resv".
            base = .reserved
        }
        if flags.contains("planned") || flags.contains("plnd") {
            planned = true
            if base == .idle {
                base = .planned
            }
        }
        if flags.contains("not_responding") || flags.contains("no_respond") {
            notResponding = true
        }
        if flags.contains("maint") {
            maintenance = true
        }
        // Same split as the compact codes: POWERED_DOWN ("~") and POWERING_UP
        // ("#") are power saving the scheduler can resume; POWERING_DOWN ("%")
        // and POWER_DOWN (pending power down, "!") take the node away.
        if flags.contains("powered_down") || flags.contains("powering_up") {
            powerSaving = true
        }
        if flags.contains("powering_down") || flags.contains("power_down") {
            poweringDown = true
        }
        if flags.contains("reboot_requested") || flags.contains("reboot_issued") {
            reboot = true
        }
        self.base = base
        self.notResponding = notResponding
        self.maintenanceReservation = maintenance
        self.plannedByBackfill = planned
        self.powerSaving = powerSaving
        self.poweringDown = poweringDown
        self.rebootPending = reboot
    }

    private static func base(named name: String) -> Base {
        switch name {
        case "idle": return .idle
        case "mix", "mixed": return .mixed
        case "alloc", "allocated": return .allocated
        case "comp", "completing": return .completing
        case "plnd", "planned": return .planned
        case "drng", "draining": return .draining
        case "drain", "drained": return .drained
        case "down": return .down
        case "failg", "failing": return .failing
        case "fail", "failed": return .failed
        case "maint": return .maintenance
        case "resv", "reserved": return .reserved
        case "futr", "future": return .future
        case "blocked": return .blocked
        case "inval", "invalid": return .invalid
        case "boot", "booting": return .booting
        case "reboot", "reboot_issued", "reboot_requested": return .rebooting
        case "pow_dn", "powered_down", "power_down", "powering_down": return .poweredDown
        // sinfo abbreviates UNKNOWN as "unk"; both read as the plain word.
        case "unk", "unknown": return .unknown
        default: return .unknown
        }
    }

    /// Whether the scheduler can start new work on the node — an allow-list,
    /// so an unfamiliar state never counts as free capacity.
    public var isAvailable: Bool {
        switch base {
        case .idle, .mixed, .allocated, .completing, .planned:
            return !notResponding && !maintenanceReservation && !rebootPending && !poweringDown
        default:
            return false
        }
    }

    /// Plain-language state for pills and legends: "Mixed", "Drained", …
    public var displayLabel: String {
        switch base {
        case .idle: return "Idle"
        case .mixed: return "Mixed"
        case .allocated: return "Allocated"
        case .completing: return "Completing"
        case .planned: return "Idle (planned)"
        case .draining: return "Draining"
        case .drained: return "Drained"
        case .down: return "Down"
        case .failing: return "Failing"
        case .failed: return "Failed"
        case .maintenance: return "Maintenance"
        case .reserved: return "Reserved"
        case .future: return "Future"
        case .blocked: return "Blocked"
        case .invalid: return "Invalid"
        case .booting: return "Booting"
        case .rebooting: return "Rebooting"
        case .poweredDown: return "Powered down"
        case .unknown:
            // An unfamiliar state is shown as Slurm spelled it rather than
            // guessed; Slurm's own UNKNOWN (and the empty string) is a word.
            let head = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .prefix { $0.isLetter || $0 == "_" }
            return head.isEmpty || head == "unk" || head == "unknown" ? "Unknown" : raw.uppercased()
        }
    }

    /// What the trailing flags mean, for tooltips.
    public var flagDescriptions: [String] {
        var descriptions: [String] = []
        if notResponding { descriptions.append("not responding") }
        if maintenanceReservation { descriptions.append("in a maintenance reservation") }
        if plannedByBackfill { descriptions.append("planned by backfill for a queued job") }
        if powerSaving { descriptions.append("powered down to save energy") }
        if poweringDown { descriptions.append("powering down") }
        if rebootPending { descriptions.append("reboot pending") }
        return descriptions
    }
}

extension NodeSummary {
    public var stateInfo: NodeStateInfo { NodeStateInfo(state) }
}

extension Job {
    public var jobState: JobState { JobState(state) }
}
