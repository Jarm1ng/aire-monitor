import Foundation
import SwiftUI

// MARK: - Slurm state

/// Single source of truth for Slurm state parsing, coloring, and availability.
/// Used by the dashboard, menu bar, and status capsule so the surfaces never drift.
enum SlurmState: Equatable {
    case unavailable
    case mixed
    case allocated
    case completing
    case running
    case pending
    case idle
    case up
    case unknown

    init(parsing raw: String) {
        let value = raw.lowercased()
        if value.contains("maint")
            || value.contains("down")
            || value.contains("drain")
            || value.contains("drng")
            || value.contains("fail")
            || value.contains("not_responding")
            || value.contains("inval")
            || value.contains("boot")
            || value.contains("cancel")
            || value.contains("timeout")
            || value.contains("out_of_me") {
            self = .unavailable
        } else if value.contains("mix") {
            self = .mixed
        } else if value.contains("alloc") {
            self = .allocated
        } else if value.contains("comp") {
            self = .completing
        } else if value.contains("run") {
            self = .running
        } else if value.contains("pend") {
            self = .pending
        } else if value.contains("idle") {
            self = .idle
        } else if value.contains("up") {
            self = .up
        } else {
            self = .unknown
        }
    }

    var color: Color {
        switch self {
        case .unavailable:
            return .red
        case .mixed, .pending:
            return .orange
        case .allocated:
            return .blue
        case .completing:
            return .teal
        case .running, .idle, .up:
            return .green
        case .unknown:
            return .secondary
        }
    }

    var isAvailable: Bool {
        self != .unavailable
    }

    var label: String {
        switch self {
        case .unavailable:
            return "Unavailable"
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
        case .idle:
            return "Idle"
        case .up:
            return "Up"
        case .unknown:
            return "Unknown"
        }
    }
}

func colorForState(_ state: String) -> Color {
    SlurmState(parsing: state).color
}

func isAvailable(_ node: NodeSummary) -> Bool {
    SlurmState(parsing: node.state).isAvailable
}

// MARK: - GRES / GPU parsing

/// Sums GPU counts from a Slurm GRES string.
/// Handles `gpu:4`, `gpu:l40s:3`, `gpu:l40s:3(S:0-1)`, `gpu:a100:4,mps:400`, and `(null)`.
func slurmGPUTotal(from gres: String) -> Int {
    let trimmed = gres.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.lowercased() != "(null)" else {
        return 0
    }
    var total = 0
    for rawEntry in splitOutsideParentheses(trimmed, separator: ",") {
        let entry = rawEntry.trimmingCharacters(in: .whitespaces)
        // Drop any parenthesised suffix like (S:0-1) or (IDX:0-3).
        let core = entry.prefix { $0 != "(" }
        let pieces = core.split(separator: ":")
        guard let first = pieces.first, first.lowercased() == "gpu" else {
            continue
        }
        guard pieces.count >= 2, let last = pieces.last else {
            continue
        }
        let digits = last.prefix { $0.isNumber }
        total += Int(digits) ?? 0
    }
    return total
}

/// Model name from a GRES string, e.g. "l40s" for `gpu:l40s:3(S:0-1)`.
func slurmGPUModel(from gres: String) -> String? {
    for rawEntry in splitOutsideParentheses(gres, separator: ",") {
        let core = rawEntry.trimmingCharacters(in: .whitespaces).prefix { $0 != "(" }
        let pieces = core.split(separator: ":")
        guard pieces.count >= 3, pieces[0].lowercased() == "gpu" else {
            continue
        }
        return String(pieces[1])
    }
    return nil
}

func gpuTotal(_ node: NodeSummary) -> Int {
    node.gpuTotal ?? slurmGPUTotal(from: node.gres)
}

func gpuAllocated(_ node: NodeSummary) -> Int {
    node.gpuAllocated ?? 0
}

func gpuIdle(_ node: NodeSummary) -> Int {
    if let idle = node.gpuIdle {
        return idle
    }
    return max(gpuTotal(node) - gpuAllocated(node), 0)
}

// MARK: - Node list expansion

/// Expands a compressed Slurm node list into concrete hostnames.
/// `gpu[001-004,007],cpu01` -> `["gpu001", "gpu002", "gpu003", "gpu004", "gpu007", "cpu01"]`.
func expandNodeList(_ compressed: String) -> [String] {
    let trimmed = compressed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.lowercased() != "(null)" else {
        return []
    }
    var result: [String] = []
    for token in splitOutsideBrackets(trimmed) {
        guard let open = token.firstIndex(of: "["),
              let close = token.lastIndex(of: "]"),
              open < close else {
            let name = token.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                result.append(name)
            }
            continue
        }
        let prefix = String(token[..<open])
        let suffix = String(token[token.index(after: close)...])
        let inner = token[token.index(after: open)..<close]
        for part in inner.split(separator: ",") {
            if let dash = part.firstIndex(of: "-") {
                let startText = part[..<dash]
                let endText = part[part.index(after: dash)...]
                if let start = Int(startText), let end = Int(endText), start <= end, end - start < 100_000 {
                    let width = startText.count
                    for value in start...end {
                        result.append(prefix + String(format: "%0\(width)d", value) + suffix)
                    }
                    continue
                }
            }
            result.append(prefix + String(part) + suffix)
        }
    }
    return result
}

/// Set of nodes running the given jobs, built from exact expanded hostnames.
/// Never substring-matches, so `gpu1` can not collide with `gpu10`.
func busyNodeSet(for jobs: [Job]) -> Set<String> {
    var nodes = Set<String>()
    for job in jobs {
        let state = SlurmState(parsing: job.state)
        guard state == .running || state == .completing else {
            continue
        }
        if let list = job.nodeList, !list.isEmpty {
            nodes.formUnion(expandNodeList(list))
        } else if state == .running {
            // For running jobs squeue's %R column is the node list.
            nodes.formUnion(expandNodeList(job.reasonOrNodeList))
        }
    }
    return nodes
}

// MARK: - Value formatting

/// Canonical placeholder for missing values across every surface.
let missingValuePlaceholder = "—"

func number(_ value: Int?) -> String {
    value.map(String.init) ?? missingValuePlaceholder
}

func percentText(_ value: Double?) -> String {
    guard let value else {
        return missingValuePlaceholder
    }
    return "\(Int(value.rounded()))%"
}

func formatGB(_ value: Double?) -> String {
    guard let value else {
        return missingValuePlaceholder
    }
    if value >= 1024 {
        return String(format: "%.1f TB", value / 1024)
    }
    if value >= 100 {
        return String(format: "%.0f GB", value)
    }
    return String(format: "%.1f GB", value)
}

func cpuText(_ node: NodeSummary) -> String {
    guard let allocated = node.cpuAllocated, let total = node.cpuTotal else {
        return missingValuePlaceholder
    }
    return "\(allocated)/\(total)"
}

func gpuText(_ node: NodeSummary) -> String {
    let total = gpuTotal(node)
    guard total > 0 else {
        return missingValuePlaceholder
    }
    return "\(gpuAllocated(node))/\(total)"
}

// MARK: - Timestamps

/// Humane timestamp presentation: relative text for display, absolute for tooltips.
@MainActor
enum AIRETimestamp {
    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let plain: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter
    }()

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func parse(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return isoWithFraction.date(from: trimmed)
            ?? iso.date(from: trimmed)
            ?? plain.date(from: trimmed)
    }

    /// "just now", "2 min. ago", … falling back to the raw string when unparsable.
    static func relativeText(_ raw: String, reference: Date = Date()) -> String {
        guard let date = parse(raw) else {
            return raw
        }
        if abs(date.timeIntervalSince(reference)) < 15 {
            return "just now"
        }
        return relative.localizedString(for: date, relativeTo: reference)
    }

    /// Absolute rendering for tooltips, falling back to the raw string.
    static func absoluteText(_ raw: String) -> String {
        guard let date = parse(raw) else {
            return raw
        }
        return date.formatted(date: .abbreviated, time: .standard)
    }
}

// MARK: - Private splitting helpers

private func splitOutsideParentheses(_ text: String, separator: Character) -> [String] {
    var parts: [String] = []
    var current = ""
    var depth = 0
    for character in text {
        if character == "(" {
            depth += 1
        } else if character == ")" {
            depth = max(depth - 1, 0)
        }
        if character == separator && depth == 0 {
            parts.append(current)
            current = ""
        } else {
            current.append(character)
        }
    }
    if !current.isEmpty {
        parts.append(current)
    }
    return parts
}

private func splitOutsideBrackets(_ text: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var depth = 0
    for character in text {
        if character == "[" {
            depth += 1
        } else if character == "]" {
            depth = max(depth - 1, 0)
        }
        if character == "," && depth == 0 {
            parts.append(current)
            current = ""
        } else {
            current.append(character)
        }
    }
    if !current.isEmpty {
        parts.append(current)
    }
    return parts
}
