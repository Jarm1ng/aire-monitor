import Foundation

// The desktop widget's decisions about one cluster's data feed: does the app
// own this cluster's collection, may the widget's fallback collector run
// now, and how long does it back off after a failure. Kept here, free of
// AppKit and SwiftUI, so the rules are unit-tested; the widget target only
// gathers the facts (file reads, the ledger) and acts on the answer.

// MARK: - app_state.json

/// `.runtime/clusters/<id>/app_state.json`, written atomically by the app's
/// ClusterSession whenever the cluster is switched on or off, paused or
/// resumed, goes live or offline, and after every refresh attempt (success
/// or failure).
///
/// It exists because snapshot age cannot tell "the app quit" from "the app
/// is paused, backing off, or mid-way through a slow refresh": the app writes
/// `latest_snapshot.json` only after a *successful* refresh, so every one of
/// those looked stale and the widget started its own collection every 10 s
/// through the same ControlMaster, overriding Pause.
///
/// Decoding is lenient: a missing flag takes the value that keeps the widget
/// from collecting behind the app's back (enabled, not paused, not live), and
/// an unparsable `updatedAt` falls back to the file's modification date.
public struct WidgetAppState: Codable, Equatable, Sendable {
    public let updatedAt: String?
    public let enabled: Bool
    public let paused: Bool
    public let live: Bool
    /// The app's current refresh cadence in seconds, including any failure
    /// backoff, so the lease window stretches while the app backs off.
    public let refreshInterval: TimeInterval

    enum CodingKeys: String, CodingKey {
        case updatedAt
        case enabled
        case paused
        case live
        case refreshInterval
    }

    public init(
        updatedAt: String? = nil,
        enabled: Bool = true,
        paused: Bool = false,
        live: Bool = true,
        refreshInterval: TimeInterval = HPCDefaults.refreshInterval
    ) {
        self.updatedAt = updatedAt
        self.enabled = enabled
        self.paused = paused
        self.live = live
        self.refreshInterval = Self.sanitizedInterval(refreshInterval)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = container.lenientOptional(String.self, .updatedAt)
        enabled = container.lenientOptional(Bool.self, .enabled) ?? true
        paused = container.lenientOptional(Bool.self, .paused) ?? false
        live = container.lenientOptional(Bool.self, .live) ?? false
        refreshInterval = Self.sanitizedInterval(
            container.lenientOptional(Double.self, .refreshInterval) ?? HPCDefaults.refreshInterval
        )
    }

    /// Decodes the file's bytes; nil for anything that is not a JSON object.
    public static func decode(_ data: Data) -> WidgetAppState? {
        try? JSONDecoder().decode(WidgetAppState.self, from: data)
    }

    /// How long a write keeps meaning "the app is running and owns this
    /// cluster": three refresh periods, never under 90 s, so one slow or
    /// failed refresh (up to the collector watchdog) never hands collection
    /// to the widget while the app is still alive.
    public var leaseWindow: TimeInterval {
        max(WidgetFeedPolicy.minimumLeaseWindow, 3 * refreshInterval)
    }

    /// When the record was written: `updatedAt`, else the file's mtime.
    public func writtenAt(fileModificationDate: Date?) -> Date? {
        updatedAt.flatMap(SlurmTimestamp.parse) ?? fileModificationDate
    }

    /// A zero, negative or absurd interval (a hand-edited file) must not
    /// shrink the lease window below its floor or stretch it for days.
    private static func sanitizedInterval(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite, value > 0 else {
            return HPCDefaults.refreshInterval
        }
        return min(value, 3600)
    }
}

/// What the app is doing with one cluster, as far as the widget can tell.
public enum WidgetAppOwnership: Equatable, Sendable {
    /// No current app_state.json: the app is not running (or predates the
    /// file). The widget's stale-snapshot fallback applies.
    case none
    /// The app is running and its last refresh of this cluster succeeded.
    case live(refreshInterval: TimeInterval)
    /// The app is running but its last refresh failed: backing off, waiting
    /// for a sign-in, or the master is gone. The app retries on its own
    /// cadence; the widget adding attempts would only add load.
    case retrying(refreshInterval: TimeInterval)
    /// The user paused this cluster in the app.
    case paused
    /// Monitoring is switched off for this cluster in the app.
    case off

    /// Whether the widget must leave collection to the app.
    public var appOwnsCollection: Bool {
        self != .none
    }

    /// The app's refresh cadence while it is actively refreshing.
    public var appRefreshInterval: TimeInterval? {
        switch self {
        case .live(let interval), .retrying(let interval):
            return interval
        case .none, .paused, .off:
            return nil
        }
    }

    /// Reads the record against the clock.
    ///
    /// `paused` and `enabled: false` are honoured whatever the record's age.
    /// The app writes nothing while a cluster is paused (there are no refresh
    /// attempts), so an age-gated pause would expire after the lease window
    /// and the widget would start polling a cluster the user paused — the
    /// exact failure this file exists to prevent. The last word the user gave
    /// for that cluster stands until the app writes again (on resume, or its
    /// next refresh after launch).
    public static func resolve(_ state: WidgetAppState?, fileModificationDate: Date?, now: Date) -> WidgetAppOwnership {
        guard let state else {
            return .none
        }
        if !state.enabled {
            return .off
        }
        if state.paused {
            return .paused
        }
        guard let written = state.writtenAt(fileModificationDate: fileModificationDate) else {
            return .none
        }
        let age = now.timeIntervalSince(written)
        // A record from the future means the clock moved; it proves nothing
        // about the app being alive now.
        guard age >= -WidgetFeedPolicy.maximumClockSkew, age <= state.leaseWindow else {
            return .none
        }
        return state.live
            ? .live(refreshInterval: state.refreshInterval)
            : .retrying(refreshInterval: state.refreshInterval)
    }
}

// MARK: - Collection decision

/// Everything the widget knows about one cluster when deciding whether to
/// run its fallback collector.
public struct WidgetFeedFacts: Equatable, Sendable {
    public var ownership: WidgetAppOwnership
    /// Age of the displayed snapshot (from its `collected_at`); nil when the
    /// cluster has no decodable snapshot.
    public var snapshotAge: TimeInterval?
    /// The displayed snapshot came from the widget's own collection.
    public var feedingItself: Bool
    /// The snapshot file on disk was written by someone else (the app) and
    /// cannot be decoded. Collecting would overwrite it.
    public var unreadableForeignFile: Bool
    /// A Refresh the user asked for.
    public var manual: Bool
    /// When the last collection attempt started (from the ledger).
    public var lastAttempt: Date?
    /// Failure backoff: no automatic attempt before this date.
    public var nextAllowed: Date?

    public init(
        ownership: WidgetAppOwnership = .none,
        snapshotAge: TimeInterval? = nil,
        feedingItself: Bool = false,
        unreadableForeignFile: Bool = false,
        manual: Bool = false,
        lastAttempt: Date? = nil,
        nextAllowed: Date? = nil
    ) {
        self.ownership = ownership
        self.snapshotAge = snapshotAge
        self.feedingItself = feedingItself
        self.unreadableForeignFile = unreadableForeignFile
        self.manual = manual
        self.lastAttempt = lastAttempt
        self.nextAllowed = nextAllowed
    }
}

public enum WidgetCollectionDecision: Equatable, Sendable {
    /// The app owns this cluster's collection (see WidgetAppOwnership).
    case deferToApp
    /// Someone else's snapshot file cannot be decoded; the widget reports it
    /// instead of collecting over it.
    case blockedByUnreadableFile
    /// The data is fresh and was not collected by the widget: nothing to do.
    case notNeeded
    /// Due, but not before this date (minimum spacing or failure backoff).
    case wait(until: Date)
    /// Run the fallback collector now.
    case collect
}

public enum WidgetFeedPolicy {
    /// Floor of the app_state.json lease window.
    public static let minimumLeaseWindow: TimeInterval = 90
    /// How far in the future a record's timestamp may be before it is
    /// distrusted.
    public static let maximumClockSkew: TimeInterval = 120
    /// Ceiling of the failure backoff.
    public static let maximumRetryDelay: TimeInterval = 300

    /// The fallback rule, applied only while the app does not own the
    /// cluster:
    /// - a missing or stale snapshot (older than `snapshotStaleAfter`) is
    ///   collected; so is the widget's own data once it is a refresh period
    ///   old, so a self-fed row keeps the app's cadence;
    /// - fresh data the widget did not collect is left alone even without
    ///   app_state.json, so an app build that predates the file is never
    ///   double-collected;
    /// - attempts are at least `refreshInterval` apart, manual ones too:
    ///   each is an SSH round trip through the user's ControlMaster;
    /// - after a failure, automatic attempts wait for the backoff; a manual
    ///   Refresh skips it once (its own failure lengthens the next delay).
    public static func decide(_ facts: WidgetFeedFacts, now: Date) -> WidgetCollectionDecision {
        if facts.ownership.appOwnsCollection {
            return .deferToApp
        }
        if facts.unreadableForeignFile {
            return .blockedByUnreadableFile
        }
        let missingOrStale = facts.snapshotAge.map { $0 > HPCDefaults.snapshotStaleAfter } ?? true
        let ownFeedDue = facts.feedingItself
            && (facts.snapshotAge.map { $0 > HPCDefaults.refreshInterval } ?? true)
        let wanted = facts.manual
            ? (missingOrStale || facts.feedingItself)
            : (missingOrStale || ownFeedDue)
        guard wanted else {
            return .notNeeded
        }
        if let lastAttempt = facts.lastAttempt {
            let earliest = lastAttempt.addingTimeInterval(HPCDefaults.refreshInterval)
            if now < earliest {
                return .wait(until: earliest)
            }
        }
        if !facts.manual, let nextAllowed = facts.nextAllowed, now < nextAllowed {
            return .wait(until: nextAllowed)
        }
        return .collect
    }

    /// Delay before the next automatic attempt after `failures` consecutive
    /// failures: 10, 20, 40, 80, 160, then 300 s. A dead master costs one
    /// python start every five minutes instead of 8,640 a day.
    public static func retryDelay(afterConsecutiveFailures failures: Int) -> TimeInterval {
        guard failures > 0 else {
            return HPCDefaults.refreshInterval
        }
        let exponent = Double(min(failures - 1, 16))
        return min(HPCDefaults.refreshInterval * pow(2, exponent), maximumRetryDelay)
    }

    /// Directory names become file paths and UI text; accept only the plain
    /// lowercase ids the app writes (`aire`, `calder`, ...), never dot files,
    /// quarantine leftovers or anything path-like.
    public static func isValidClusterDirectoryName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.unicodeScalars.count <= 32 else {
            return false
        }
        let isPlain: (Unicode.Scalar) -> Bool = { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-" || scalar == "_"
        }
        return ("a"..."z").contains(first) && name.unicodeScalars.allSatisfy(isPlain)
    }
}
