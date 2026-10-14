import Foundation

/// Canonical placeholder for missing values across every surface.
public let missingValuePlaceholder = "—"

// MARK: - Slurm durations

/// Seconds in a Slurm duration. Slurm accepts "M", "M:S", "H:M:S", "D-H",
/// "D-H:M" and "D-H:M:S": without a day part a lone field is minutes, with
/// one the clock fields are hours[:minutes[:seconds]]. nil for "infinite",
/// "UNLIMITED", "n/a" and anything unparsable.
public func slurmDurationSeconds(_ text: String) -> Int? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
        return nil
    }
    var days = 0
    var clock = Substring(text)
    let hasDayPart = text.contains("-")
    if hasDayPart {
        let pieces = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2, let parsedDays = Int(pieces[0]), parsedDays >= 0 else {
            return nil
        }
        days = parsedDays
        clock = pieces[1]
    }
    var values: [Int] = []
    for field in clock.split(separator: ":", omittingEmptySubsequences: false) {
        guard let value = Int(field), value >= 0 else {
            return nil
        }
        values.append(value)
    }
    let clockSeconds: Int
    if hasDayPart {
        guard (1...3).contains(values.count) else {
            return nil
        }
        let padded = values + Array(repeating: 0, count: 3 - values.count)
        clockSeconds = padded[0] * 3600 + padded[1] * 60 + padded[2]
    } else {
        switch values.count {
        case 1:
            clockSeconds = values[0] * 60
        case 2:
            clockSeconds = values[0] * 60 + values[1]
        case 3:
            clockSeconds = values[0] * 3600 + values[1] * 60 + values[2]
        default:
            return nil
        }
    }
    return days * 86_400 + clockSeconds
}

/// Seconds in squeue's elapsed column ("1-02:03:04", "3:04:05", "4:05").
/// Same grammar as a time limit; kept as a name that says what it reads.
public func slurmElapsedSeconds(_ text: String) -> Int? {
    slurmDurationSeconds(text)
}

/// "2 days", "1 day 12 h", "1 h 30 min", "45 s". Seconds only appear for
/// sub-hour values; a walltime is never meaningfully "2 days 0 h 0 min 5 s".
public func slurmDurationText(seconds total: Int) -> String {
    let days = total / 86_400
    let hours = total % 86_400 / 3600
    let minutes = total % 3600 / 60
    let seconds = total % 60
    var parts: [String] = []
    if days > 0 {
        parts.append(days == 1 ? "1 day" : "\(days) days")
    }
    if hours > 0 {
        parts.append("\(hours) h")
    }
    if minutes > 0 {
        parts.append("\(minutes) min")
    }
    if seconds > 0 && days == 0 && hours == 0 {
        parts.append("\(seconds) s")
    }
    return parts.isEmpty ? "0 min" : parts.joined(separator: " ")
}

/// Human text for a Slurm time limit (`sinfo %l` / `squeue %l`):
/// "2-00:00:00" -> "2 days", "12:00:00" -> "12 h", "30:00" -> "30 min",
/// "infinite" / "UNLIMITED" -> "no limit"; empty and "n/a" give the
/// placeholder. Anything unparsable is returned unchanged.
public func formatSlurmTimeLimit(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowered = trimmed.lowercased()
    if trimmed.isEmpty || lowered == "n/a" {
        return missingValuePlaceholder
    }
    if lowered == "infinite" || lowered == "unlimited" {
        return "no limit"
    }
    guard let seconds = slurmDurationSeconds(trimmed) else {
        return trimmed
    }
    return slurmDurationText(seconds: seconds)
}

// MARK: - Timestamps

/// Parses the timestamps the collector and Slurm produce, and renders ages
/// the same way on every surface (app, menu bar, widget).
public enum SlurmTimestamp {
    /// The zone Slurm's zone-less timestamps are written in.
    public static let clusterTimeZone = TimeZone(identifier: "Europe/London") ?? .current

    // Formatters are documented thread-safe on current macOS; they are only
    // ever read after creation.
    nonisolated(unsafe) private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Slurm's zone-less local times ("2026-10-12T14:05:20") and the
    /// space-separated variant. Slurm prints them in the cluster's zone, and
    /// both clusters are in Leeds, so a Mac set to another zone (a user
    /// travelling) still gets the right ages.
    private static let plainFormatters: [DateFormatter] = {
        ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss"].map { pattern in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = pattern
            formatter.timeZone = clusterTimeZone
            return formatter
        }
    }()

    public static func parse(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if let date = isoWithFraction.date(from: trimmed) ?? iso.date(from: trimmed) {
            return date
        }
        for formatter in plainFormatters {
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }

    /// "just now", "41 s ago", "5 min ago", "2 h ago", "3 d ago".
    public static func ageText(from date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 15 {
            return "just now"
        }
        if seconds < 60 {
            return "\(seconds) s ago"
        }
        if seconds < 3600 {
            return "\(seconds / 60) min ago"
        }
        if seconds < 86_400 {
            return "\(seconds / 3600) h ago"
        }
        return "\(seconds / 86_400) d ago"
    }

    /// Relative text for a raw timestamp, falling back to the raw string
    /// when it cannot be parsed.
    public static func relativeText(_ raw: String, reference: Date = Date()) -> String {
        guard let date = parse(raw) else {
            return raw
        }
        return ageText(from: date, now: reference)
    }

    /// Absolute rendering for tooltips, falling back to the raw string.
    public static func absoluteText(_ raw: String) -> String {
        guard let date = parse(raw) else {
            return raw
        }
        return date.formatted(date: .abbreviated, time: .standard)
    }
}
