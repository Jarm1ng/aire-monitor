import Foundation

/// The app's per-cluster liveness lease, `.runtime/clusters/<id>/app_state.json`.
///
/// Written atomically by the app (ClusterSession) whenever monitoring is
/// switched on or off, paused or resumed, the session goes live or drops,
/// after every refresh attempt (success or failure), and on a 30 s
/// heartbeat; removed when the app quits. The desktop widget reads it to
/// decide who owns collection: while the lease is fresh the app is running
/// and feeding this cluster (or deliberately not — paused, off, backing
/// off), so the widget must never start its own collector for it. Inferring
/// that from the snapshot's age instead made the widget poll every 10 s
/// whenever the app was paused, backing off, or slow.
///
/// JSON keys are part of the app/widget contract:
/// `{"updatedAt": ISO8601, "enabled": bool, "paused": bool, "live": bool,
///   "refreshInterval": seconds}`.
public struct ClusterAppState: Codable, Equatable, Sendable {
    public static let fileName = "app_state.json"
    /// Lower bound of the freshness window: comfortably above the app's
    /// 30 s heartbeat, so a busy main thread never hands collection to the
    /// widget by accident.
    public static let minimumFreshness: TimeInterval = 90
    /// How often the running app rewrites the lease even when nothing
    /// changes (paused and disabled clusters do not refresh at all).
    public static let heartbeatInterval: TimeInterval = 30

    public var updatedAt: String
    public var enabled: Bool
    public var paused: Bool
    public var live: Bool
    /// The app's current background cadence in seconds, backoff included.
    public var refreshInterval: Double

    public init(updatedAt: String, enabled: Bool, paused: Bool, live: Bool, refreshInterval: Double) {
        self.updatedAt = updatedAt
        self.enabled = enabled
        self.paused = paused
        self.live = live
        self.refreshInterval = refreshInterval
    }

    public init(updatedAt date: Date, enabled: Bool, paused: Bool, live: Bool, refreshInterval: Double) {
        self.init(
            updatedAt: ISO8601DateFormatter().string(from: date),
            enabled: enabled,
            paused: paused,
            live: live,
            refreshInterval: refreshInterval
        )
    }

    public var updatedAtDate: Date? {
        ISO8601DateFormatter().date(from: updatedAt)
    }

    /// max(90 s, 3 × refreshInterval): three missed refreshes, never less
    /// than three missed heartbeats.
    public var freshnessWindow: TimeInterval {
        max(Self.minimumFreshness, 3 * max(refreshInterval, 0))
    }

    /// True while the app that wrote this lease should be considered
    /// running and in charge of the cluster. An unreadable timestamp or one
    /// in the future beyond clock-skew tolerance is treated as expired.
    public func isFresh(now: Date = Date()) -> Bool {
        guard let updated = updatedAtDate else {
            return false
        }
        let age = now.timeIntervalSince(updated)
        return age >= -60 && age <= freshnessWindow
    }
}
