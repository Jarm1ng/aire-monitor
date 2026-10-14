import Foundation

// MARK: - Cluster identity

/// Stable identifier of a monitored cluster. String-backed rather than an
/// enum so generic code never switches on a particular cluster.
public struct ClusterID: RawRepresentable, Hashable, Codable, Sendable, Identifiable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var id: String { rawValue }
    public var description: String { rawValue }

    public static let aire = ClusterID("aire")
    public static let calder = ClusterID("calder")
}

/// What every surface — app, menu bar and the separate widget process —
/// needs to present a cluster consistently. The app's richer ClusterProfile
/// builds on these.
public struct ClusterIdentity: Hashable, Sendable {
    public let id: ClusterID
    public let displayName: String
    public let monogram: String
    /// Accent colour as sRGB components (UI targets turn it into a Color).
    public let accentRed: Double
    public let accentGreen: Double
    public let accentBlue: Double

    public static let aire = ClusterIdentity(
        id: .aire, displayName: "AIRE", monogram: "A",
        accentRed: 0.16, accentGreen: 0.74, accentBlue: 0.48
    )
    public static let calder = ClusterIdentity(
        id: .calder, displayName: "Calder", monogram: "C",
        accentRed: 0.56, accentGreen: 0.45, accentBlue: 0.96
    )

    /// Display order everywhere.
    public static let known: [ClusterIdentity] = [.aire, .calder]

    public static func known(_ id: ClusterID) -> ClusterIdentity? {
        known.first { $0.id == id }
    }

    /// Identity for any cluster id, including ones this build does not know
    /// (shown with a neutral grey accent).
    public static func resolve(_ id: ClusterID, name: String? = nil) -> ClusterIdentity {
        if let identity = known(id) {
            return identity
        }
        let display = name?.isEmpty == false ? name! : id.rawValue.capitalized
        return ClusterIdentity(
            id: id, displayName: display, monogram: String(display.prefix(1)).uppercased(),
            accentRed: 0.55, accentGreen: 0.57, accentBlue: 0.60
        )
    }

    /// Sort key: known clusters in catalog order, then alphabetical.
    public static func sortKey(_ id: ClusterID) -> (Int, String) {
        (known.firstIndex { $0.id == id } ?? known.count, id.rawValue)
    }
}

// MARK: - Storage kinds

/// Coarse kind of a storage space, derived from its label. Drives icons,
/// colours, trend series and sort order everywhere storage is shown.
public enum StorageKind: Int, Comparable, Sendable {
    case home
    case scratch
    case flash
    case other

    public init(label: String) {
        let lowered = label.lowercased()
        if lowered.contains("home") {
            self = .home
        } else if lowered.contains("scratch") {
            self = .scratch
        } else if lowered.contains("flash") {
            self = .flash
        } else {
            self = .other
        }
    }

    public static func < (lhs: StorageKind, rhs: StorageKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var systemImage: String {
        switch self {
        case .home: return "house"
        case .scratch: return "externaldrive"
        case .flash: return "bolt.horizontal"
        case .other: return "internaldrive"
        }
    }

    /// /users is one NFS export mounted on every Leeds cluster: the same
    /// quota appears in each cluster's snapshot and must not be summed.
    public var isSharedAcrossClusters: Bool {
        self == .home
    }
}

// MARK: - Status tones

/// One threshold table for "how worried should the user be", so storage,
/// quota and pool meters agree on every screen.
public enum StatusTone: Int, Comparable, Sendable {
    case normal
    case warning
    case critical
    /// No data, or the resource cannot be used.
    case unavailable

    /// Storage/quota usage: warning from 75 %, critical from 90 %.
    public init(usedPercent: Double?) {
        guard let usedPercent else {
            self = .unavailable
            return
        }
        if usedPercent >= 90 {
            self = .critical
        } else if usedPercent >= 75 {
            self = .warning
        } else {
            self = .normal
        }
    }

    public static func < (lhs: StatusTone, rhs: StatusTone) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Defaults

/// Values that must stay in step between the app, the widget and the
/// collector/login helpers. Change them here, never as separate literals.
public enum HPCDefaults {
    public static let jumpHostname = "rash.leeds.ac.uk"
    public static let duoOption = "1"
    /// Background refresh cadence while healthy, and the backoff ceiling.
    public static let refreshInterval: TimeInterval = 10
    public static let maximumRefreshInterval: TimeInterval = 60
    /// The collector's `--timeout`: its TOTAL budget for one snapshot.
    public static let collectorTimeout = 30
    /// How long the caller waits before killing the collector. Always above
    /// the collector's own budget so a healthy collection is never killed.
    public static var collectorWatchdog: TimeInterval { TimeInterval(collectorTimeout) + 10 }
    /// `HPC_TIMEOUT` for the login helpers: the starter's deadline for
    /// connect + password + Duo, and the expect helper's per-prompt limit.
    public static let loginPromptTimeout = 180
    /// The caller's watchdog, only a backstop for a hung helper: the helpers
    /// enforce their own deadline, and a jump leg (per prompt) that ends near
    /// its limit must not be killed while Duo is being approved. Sign-in can
    /// be cancelled, so a generous margin costs little.
    public static var loginWatchdog: TimeInterval { TimeInterval(loginPromptTimeout) + 60 }
    /// A snapshot older than this is no longer being refreshed by the app.
    public static let snapshotStaleAfter: TimeInterval = 30
    /// Age at which cached data is shown as old (red).
    public static let snapshotOldAfter: TimeInterval = 3600
}
