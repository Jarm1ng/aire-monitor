import HPCCore
import Foundation
import Testing

// Durations (time limits, elapsed times) and timestamps (collector stamps,
// Slurm submit/start times) appear on every surface; one parser and one
// relative-age style keep them consistent.

@Suite("Core · Slurm durations")
struct CoreDurationTests {
    @Test("Every duration shape Slurm prints", arguments: [
        ("25:00", 1_500),          // M:S — squeue prints 25 minutes like this
        ("0:45", 45),
        ("30", 1_800),             // a lone field is minutes
        ("1:08:18", 4_098),        // H:M:S
        ("44:49", 2_689),
        ("4:00:00", 14_400),
        ("12:00:00", 43_200),
        ("1-12", 129_600),         // D-H
        ("1-12:30", 131_400),      // D-H:M
        ("1-00:00:00", 86_400),    // D-H:M:S
        ("2-00:00:00", 172_800),
        ("0:00", 0),
        (" 8:00:00\n", 28_800)
    ])
    func seconds(text: String, expected: Int) {
        #expect(slurmDurationSeconds(text) == expected)
        #expect(slurmElapsedSeconds(text) == expected)
    }

    @Test("Limits without a number and malformed text are nil", arguments: [
        "UNLIMITED", "infinite", "n/a", "", "  ", "1-", "-5", "1:2:3:4", "1-1:2:3:4", "1-2-3", "1:-5", "abc", "NOT_SET"
    ])
    func unparsable(text: String) {
        #expect(slurmDurationSeconds(text) == nil)
    }

    @Test("Durations read as words; seconds only below an hour", arguments: [
        (0, "0 min"),
        (45, "45 s"),
        (60, "1 min"),
        (90, "1 min 30 s"),
        (1_500, "25 min"),
        (3_600, "1 h"),
        (3_605, "1 h"),
        (5_400, "1 h 30 min"),
        (86_400, "1 day"),
        (129_600, "1 day 12 h"),
        (172_800, "2 days"),
        (90_061, "1 day 1 h 1 min")
    ])
    func text(seconds: Int, expected: String) {
        #expect(slurmDurationText(seconds: seconds) == expected)
    }

    @Test("Time limits from sinfo %l and squeue %l", arguments: [
        ("2-00:00:00", "2 days"),
        ("1-00:00:00", "1 day"),
        ("1-12", "1 day 12 h"),
        ("12:00:00", "12 h"),
        ("8:00:00", "8 h"),
        ("4:00:00", "4 h"),
        ("30:00", "30 min"),
        ("25:00", "25 min"),
        ("UNLIMITED", "no limit"),
        ("infinite", "no limit"),
        ("Infinite", "no limit"),
        ("n/a", missingValuePlaceholder),
        ("N/A", missingValuePlaceholder),
        ("", missingValuePlaceholder),
        ("  ", missingValuePlaceholder),
        // Unparsable text is shown as Slurm printed it, never as a guess.
        ("NOT_SET", "NOT_SET")
    ])
    func timeLimits(raw: String, expected: String) {
        #expect(formatSlurmTimeLimit(raw) == expected)
    }

    @Test("The placeholder is the em dash everywhere")
    func placeholder() {
        #expect(missingValuePlaceholder == "—")
    }
}

@Suite("Core · timestamps")
struct CoreTimestampTests {
    private static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int, zone: TimeZone = TimeZone(identifier: "UTC")!) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    @Test("The collector's ISO 8601 stamps, with microseconds, an offset or Z")
    func isoStamps() throws {
        let reference = Self.utc(2026, 10, 13, 11, 49, 45)
        // Python's isoformat() writes six fractional digits.
        let micro = try #require(SlurmTimestamp.parse("2026-10-13T11:49:45.636173+00:00"))
        #expect(abs(micro.timeIntervalSince(reference) - 0.636) < 0.001)
        #expect(SlurmTimestamp.parse("2026-10-13T11:49:45.636+00:00").map { abs($0.timeIntervalSince(reference) - 0.636) < 0.001 } == true)
        #expect(SlurmTimestamp.parse("2026-10-13T11:49:45Z") == reference)
        // The remote clock's local time with its offset.
        #expect(SlurmTimestamp.parse("2026-10-13T12:49:45+01:00") == reference)
        #expect(SlurmTimestamp.parse("  2026-10-13T11:49:45+00:00\n") == reference)
    }

    @Test("Slurm's zone-less times are local wall-clock times")
    func slurmLocalTimes() throws {
        // squeue/scontrol print submit and start times without a zone, in
        // the cluster's local time. HPCCore reads them in the clusters' zone
        // (Leeds), whatever zone the Mac is set to.
        let parsed = try #require(SlurmTimestamp.parse("2026-10-13T01:31:35"))
        #expect(parsed == Self.utc(2026, 10, 13, 1, 31, 35, zone: TimeZone(identifier: "Europe/London")!))
        // The space-separated variant is the same instant.
        #expect(SlurmTimestamp.parse("2026-10-13 01:31:35") == parsed)
        #expect(SlurmTimestamp.parse("2026-10-13T01:32:05").map { $0.timeIntervalSince(parsed) } == 30)
    }

    @Test("Placeholders Slurm uses for missing times parse to nil", arguments: ["", "  ", "Unknown", "N/A", "None", "(null)", "not a date"])
    func missing(raw: String) {
        #expect(SlurmTimestamp.parse(raw) == nil)
    }

    @Test("One relative-age style", arguments: [
        (0, "just now"),
        (14, "just now"),
        (15, "15 s ago"),
        (59, "59 s ago"),
        (60, "1 min ago"),
        (3_599, "59 min ago"),
        (3_600, "1 h ago"),
        (86_399, "23 h ago"),
        (86_400, "1 d ago"),
        (3 * 86_400, "3 d ago"),
        // A cluster clock slightly ahead of the Mac never reads as negative.
        (-30, "just now")
    ])
    func ages(secondsAgo: Int, expected: String) {
        let now = Self.utc(2026, 10, 13, 12, 0, 0)
        #expect(SlurmTimestamp.ageText(from: now.addingTimeInterval(TimeInterval(-secondsAgo)), now: now) == expected)
    }

    @Test("Relative and absolute text fall back to the raw string")
    func fallbacks() {
        let reference = Self.utc(2026, 10, 13, 11, 54, 45)
        #expect(SlurmTimestamp.relativeText("2026-10-13T11:49:45+00:00", reference: reference) == "5 min ago")
        #expect(SlurmTimestamp.relativeText("Unknown", reference: reference) == "Unknown")
        #expect(SlurmTimestamp.absoluteText("Unknown") == "Unknown")
        let absolute = SlurmTimestamp.absoluteText("2026-10-13T11:49:45+00:00")
        #expect(!absolute.isEmpty)
        #expect(absolute != "2026-10-13T11:49:45+00:00")
    }
}
