import Foundation

// Presentation rules the per-cluster dashboards introduced and that other
// surfaces (overview, menu bar, widget) can share: why a pending job waits,
// relative times that may lie in the future, and one storage pressure rule.

// MARK: - Pending reasons

/// Why a pending job is waiting, read from squeue's `%R` column for a
/// pending job: "(Dependency)", "(Priority)", "(JobHeldUser)",
/// "(ReqNodeNotAvail, Reserved for maintenance)".
///
/// For running jobs the same column holds the node list, so only build this
/// for pending jobs (`Job.pendingReason` does that check).
public struct SlurmPendingReason: Equatable, Sendable {
    /// The reason without parentheses, e.g. "Dependency" or
    /// "ReqNodeNotAvail, Reserved for maintenance".
    public let raw: String
    /// The first reason word, e.g. "ReqNodeNotAvail".
    public let code: String

    /// Nil for an empty value and Slurm's "None".
    public init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("(") && trimmed.hasSuffix(")") {
            trimmed = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard !trimmed.isEmpty, trimmed.lowercased() != "none", trimmed.lowercased() != "(null)" else {
            return nil
        }
        raw = trimmed
        code = String(trimmed.prefix { $0 != "," && $0 != " " })
    }

    /// Held by the user or an administrator: it will not start until
    /// released, however much capacity frees up. Same rule as the "held"
    /// rank of `jobDisplayOrder` (JobHeldUser, JobHeldAdmin, JobHoldMaxRequeue,
    /// "launch failed requeued held").
    public var isHeld: Bool {
        let lowered = raw.lowercased()
        return lowered.contains("held") || lowered.contains("hold")
    }

    /// Blocked on another job, not on cluster capacity.
    public var isDependency: Bool {
        code.lowercased().hasPrefix("dependency")
    }

    /// Waiting for capacity in the ordinary way (free resources or its turn
    /// in the priority order) — the only reasons that say anything about how
    /// busy the cluster is.
    public var waitsForCapacity: Bool {
        let lowered = code.lowercased()
        return lowered == "resources" || lowered == "priority"
    }

    /// Plain-language explanation; the raw reason for anything unfamiliar.
    public var explanation: String {
        let lowered = code.lowercased()
        switch lowered {
        case "dependency":
            return "Waiting for another job to finish"
        case "dependencyneversatisfied":
            return "Its dependency can never be satisfied — cancel or fix it"
        case "priority":
            return "Queued behind higher-priority jobs"
        case "resources":
            return "Waiting for free resources"
        case "jobhelduser":
            return "Held by you — release it with scontrol release"
        case "jobheldadmin":
            return "Held by an administrator"
        case "begintime":
            return "Waiting for its requested start time"
        case "reqnodenotavail":
            return raw.lowercased().contains("maintenance")
                ? "Requested nodes are reserved for maintenance"
                : "Requested nodes are not available"
        case "reservation":
            return "Waiting for its reservation to start"
        case "partitiontimelimit":
            return "Time limit exceeds the partition's maximum"
        case "partitiondown", "partitioninactive":
            return "The partition is not accepting jobs"
        case "partitionnodelimit":
            return "Asks for more nodes than the partition allows"
        case "nodedown":
            return "A required node is down"
        case "badconstraints":
            return "No node can satisfy its constraints"
        case "launchfailedrequeuedheld":
            return "Requeued and held after a launch failure"
        default:
            if lowered.hasPrefix("qos") || lowered.hasPrefix("assoc") {
                return "Waiting on a usage limit (\(code))"
            }
            return raw
        }
    }
}

extension Job {
    /// Why this job waits; nil when it is not pending or Slurm gives no
    /// reason.
    public var pendingReason: SlurmPendingReason? {
        guard jobState.isPending else {
            return nil
        }
        return SlurmPendingReason(reasonOrNodeList)
    }

    /// A pending job held by the user or an administrator.
    public var isHeld: Bool {
        pendingReason?.isHeld ?? false
    }
}

// MARK: - Relative times

extension SlurmTimestamp {
    /// Like `ageText`, but also for times in the future (a backfill start
    /// estimate): "in 5 min", "in 2 h", "in 3 d", or "now" within 15 s.
    public static func distanceText(to date: Date, now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds >= 15 else {
            return seconds > -15 ? "now" : ageText(from: date, now: now)
        }
        if seconds < 60 {
            return "in \(seconds) s"
        }
        if seconds < 3600 {
            return "in \(seconds / 60) min"
        }
        if seconds < 86_400 {
            return "in \(seconds / 3600) h"
        }
        return "in \(seconds / 86_400) d"
    }
}

// MARK: - Storage pressure

extension StorageSummary {
    /// File-count use as a percentage of the hard file limit (or the soft
    /// quota when there is no limit); nil without figures.
    public var fileUsedPercent: Double? {
        guard let fileCount, let limit = fileLimit ?? fileQuota, limit > 0 else {
            return nil
        }
        return Double(fileCount) / Double(limit) * 100
    }

    /// The pressure that decides how worried to be: whichever of space and
    /// file count is closer to its limit. Nil when neither is known.
    public var pressurePercent: Double? {
        switch (usedPercent, fileUsedPercent) {
        case (nil, nil):
            return nil
        case let (space, files):
            return max(space ?? 0, files ?? 0)
        }
    }

    /// True when the file count, not the space, is the dominant pressure.
    public var fileCountDominates: Bool {
        guard let files = fileUsedPercent else {
            return false
        }
        return files > (usedPercent ?? 0)
    }

    /// One tone for this space on every screen: over quota is critical,
    /// otherwise the shared 75/90 thresholds on `pressurePercent`;
    /// `.unavailable` when the collector could not read the space.
    public var usageTone: StatusTone {
        if overQuota == true {
            return .critical
        }
        return StatusTone(usedPercent: pressurePercent)
    }
}
