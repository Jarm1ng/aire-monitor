import HPCCore
import Foundation
import SwiftUI

// MARK: - Slurm state (presentation)

/// Colour and label layer for Slurm states. Parsing lives in HPCCore
/// (`JobState`, `NodeStateInfo`), which keeps the job and node vocabularies
/// apart; this enum only maps them onto the dashboard palette. Counting and
/// availability decisions never go through this type — they use
/// `JobState` / `NodeStateInfo.isAvailable` directly.
enum SlurmState: Equatable {
    /// A node that accepts no work: out of the pool, grey.
    case unavailable
    /// A job that ended badly (FAILED, TIMEOUT, CANCELLED, OUT_OF_MEMORY…):
    /// a fault, red. Kept apart from `unavailable` so no surface has to
    /// remember to repaint it.
    case failed
    case mixed
    case allocated
    case completing
    case running
    case pending
    case suspended
    case idle
    case finished
    case unknown

    init(node raw: String) {
        self.init(node: NodeStateInfo(raw))
    }

    init(node info: NodeStateInfo) {
        guard info.isAvailable else {
            self = info.base == .unknown && !info.notResponding ? .unknown : .unavailable
            return
        }
        switch info.base {
        case .mixed: self = .mixed
        case .allocated: self = .allocated
        case .completing: self = .completing
        case .idle, .planned: self = .idle
        default: self = .unknown
        }
    }

    init(job raw: String) {
        self.init(job: JobState(raw))
    }

    init(job state: JobState) {
        switch state {
        case .running, .configuring: self = .running
        case .pending, .requeued: self = .pending
        case .suspended: self = .suspended
        case .completing: self = .completing
        case .finished(let raw): self = raw == "COMPLETED" || raw == "CD" ? .finished : .failed
        case .other: self = .unknown
        }
    }

    /// For views that receive a bare state string: job states are matched
    /// exactly first (they are long upper-case words), anything else is read
    /// as a node state. Only for colouring a pill; dashboards that know
    /// whether a string is a job or a node state use the specific init.
    init(parsing raw: String) {
        if case .other = JobState(raw) {
            self.init(node: raw)
        } else {
            self.init(job: raw)
        }
    }

    /// Node occupancy is capacity, not health: idle green, mixed (partly
    /// allocated) a lighter shade of allocated's blue, allocated blue — the
    /// same "paler means partly used" ramp as the Nodes tab's GPU heatmap.
    /// No occupancy state takes a status tone, so orange keeps meaning a
    /// warning (a degraded partition, a full GPU pool) or a queued job
    /// instead of matching half of a healthy fleet.
    static let partlyAllocatedColor = Color(red: 0.40, green: 0.69, blue: 1.0)

    var color: Color {
        switch self {
        case .unavailable:
            // Grey, like every "accepts no work" figure (GPU meters, the
            // Nodes tab badge, `AppTheme.unavailable`): a drained or down
            // node is out of the pool, not an alarm.
            return AppTheme.unavailable
        case .failed:
            return StatusTone.critical.color
        case .mixed:
            return Self.partlyAllocatedColor
        case .pending:
            return .orange
        case .suspended:
            return .yellow
        case .allocated:
            return .blue
        case .completing:
            return .teal
        case .running, .idle, .finished:
            return .green
        case .unknown:
            return .secondary
        }
    }

    var label: String {
        switch self {
        case .unavailable:
            return "Unavailable"
        case .failed:
            return "Failed"
        case .mixed:
            return "Mixed"
        case .allocated:
            return "Allocated"
        case .completing:
            return "Completing"
        case .running:
            return "Running"
        case .pending:
            return "Pending"
        case .suspended:
            return "Suspended"
        case .idle:
            return "Idle"
        case .finished:
            return "Finished"
        case .unknown:
            return "Unknown"
        }
    }
}

// MARK: - Node state wording

extension NodeStateInfo {
    /// Order of node states in legends and state bars: busy, then idle, then
    /// the unavailable flavours — so a red "down" segment never lands
    /// between the allocated and mixed ones the way an alphabetical sort
    /// put it.
    var displayRank: Int {
        if isAvailable {
            switch base {
            case .allocated: return 0
            case .mixed: return 1
            case .completing: return 2
            case .planned: return 3
            case .idle: return 4
            default: return 5
            }
        }
        // Unavailable: still-busy draining nodes first, then out-of-service
        // flavours roughly by how long they tend to last.
        switch base {
        case .draining: return 10
        case .mixed, .allocated, .completing: return 11
        case .idle, .planned: return 12
        case .drained: return 13
        case .reserved, .maintenance: return 14
        case .booting, .rebooting, .poweredDown: return 15
        case .down, .failing, .failed: return 16
        default: return 17
        }
    }

    /// Short words for the trailing flags, for legends: "not responding",
    /// "maintenance", "planned".
    var shortFlagWords: [String] {
        var words: [String] = []
        if notResponding { words.append("not responding") }
        if maintenanceReservation { words.append("maintenance") }
        if plannedByBackfill && base != .planned { words.append("planned") }
        if powerSaving { words.append("powered down") }
        if poweringDown { words.append("powering down") }
        if rebootPending { words.append("reboot pending") }
        return words
    }

    /// Legend text: "Mixed · planned", "Drained · not responding", "Down ·
    /// maintenance". The raw code belongs in the tooltip (`helpText`).
    var legendText: String {
        ([displayLabel] + shortFlagWords).joined(separator: " · ")
    }

    /// "drain* — Drained: not responding" for tooltips, keeping the raw
    /// Slurm code visible for people who know it.
    var helpText: String {
        let flags = flagDescriptions
        let meaning = flags.isEmpty ? displayLabel : "\(displayLabel): \(flags.joined(separator: ", "))"
        let raw = self.raw.trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? meaning : "\(raw) — \(meaning)"
    }
}

// MARK: - Value formatting

func number(_ value: Int?) -> String {
    value.map(String.init) ?? missingValuePlaceholder
}

/// Grouped thousands ("13,888") for counts in running text.
func groupedNumber(_ value: Int) -> String {
    value.formatted(.number.grouping(.automatic))
}

/// "1 node", "3 nodes", "1,600 cores". `plural` defaults to noun + "s".
func pluralized(_ count: Int, _ noun: String, plural: String? = nil) -> String {
    "\(groupedNumber(count)) \(count == 1 ? noun : (plural ?? noun + "s"))"
}

func percentText(_ value: Double?) -> String {
    guard let value else {
        return missingValuePlaceholder
    }
    return "\(Int(value.rounded()))%"
}

/// A storage size the collector reports in GiB (quota, lfs and df figures
/// all use powers of 1024), labelled in binary units: "44.5 GiB", "999
/// GiB", "1,024 GiB", "12.5 TiB". Below 10 TiB a size stays in whole GiB
/// rather than rounding to "1.0 TB": a 1,024 GiB limit printed as "1.0 TB"
/// beside "999 GB used" and "24.9 GB free" read as 99.9 % full with 1 GB
/// left, against the 98 % shown, and the figures no longer added up.
func formatGB(_ value: Double?) -> String {
    binarySizeText(value, tebibytesFrom: 10 * 1024)
}

/// Node memory (Slurm's MiB divided by 1024), in the same binary units but
/// coarser — "754 GiB", "1.5 TiB" — since it is never set against a used
/// figure, and nodes a few MiB apart should not print "1,510–1,511 GiB".
func formatMemoryGB(_ value: Double?) -> String {
    binarySizeText(value, tebibytesFrom: 1024)
}

private func binarySizeText(_ value: Double?, tebibytesFrom threshold: Double) -> String {
    guard let value, value.isFinite else {
        return missingValuePlaceholder
    }
    if abs(value) >= threshold {
        return String(format: "%.1f TiB", value / 1024)
    }
    if abs(value) >= 100 {
        return "\(groupedNumber(Int(value.rounded()))) GiB"
    }
    return String(format: "%.1f GiB", value)
}

/// squeue's elapsed column as text: "1:11:17" -> "1 h 11 min". Unparsable
/// values are returned unchanged.
func elapsedText(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return missingValuePlaceholder
    }
    guard let seconds = slurmElapsedSeconds(trimmed) else {
        return trimmed
    }
    return slurmDurationText(seconds: seconds)
}

func cpuText(_ node: NodeSummary) -> String {
    guard let allocated = node.cpuAllocated, let total = node.cpuTotal else {
        return missingValuePlaceholder
    }
    return "\(allocated)/\(total)"
}

/// "2/3" allocated of configured GPUs; "?/3" when the snapshot carries no
/// allocation for the node (unknown is never shown as zero).
func gpuText(_ node: NodeSummary) -> String {
    let total = node.gpuCount
    guard total > 0 else {
        return missingValuePlaceholder
    }
    guard let allocated = node.knownGPUAllocated else {
        return "?/\(total)"
    }
    return "\(min(allocated, total))/\(total)"
}

// MARK: - Status capsule

/// The pill used for states the dashboards derive themselves (a held job, a
/// partition's health), in the same capsule language as `StatePill`.
struct StatusCapsule: View {
    let text: String
    let color: Color
    var help: String?

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background {
                Capsule()
                    .fill(.thinMaterial)
                    .overlay {
                        Capsule()
                            .fill(color.opacity(0.14))
                    }
            }
            .foregroundStyle(color)
            .overlay(
                Capsule()
                    .stroke(color.opacity(0.20), lineWidth: 1)
            )
            .clipShape(Capsule())
            .fixedSize()
            .help(help ?? "")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("State")
            .accessibilityValue(help.map { "\(text), \($0)" } ?? text)
    }
}
