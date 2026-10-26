import Foundation
import os

/// Unified-log channels, one per component, under the app's bundle id so
/// `log stream --predicate 'subsystem == "local.aire.monitor"'` (or Console)
/// shows everything the app did around a problem. Before these existed,
/// refresh failures, backoff changes, superseded refreshes and swallowed
/// cache-write errors left no trace at all, so issues such as the false
/// disconnects fixed in 77be6b0 had to be reproduced to be diagnosed.
///
/// Hostnames and usernames are always logged with `privacy: .private`;
/// error text and cluster ids are public (they never contain secrets — the
/// password only ever travels on a helper's stdin).
enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "local.aire.monitor"

    /// Refresh attempts, outcomes, backoff and superseded generations.
    static let refresh = Logger(subsystem: subsystem, category: "refresh")
    /// Sign-in chain, outcomes, cancellation and master teardown.
    static let login = Logger(subsystem: subsystem, category: "login")
    /// Snapshot cache, history, job baseline, app_state.json, preferences.
    static let cache = Logger(subsystem: subsystem, category: "cache")
    /// Notification authorization and delivery.
    static let notifications = Logger(subsystem: subsystem, category: "notifications")
    /// App lifecycle: single-instance guard, termination, widget launcher.
    static let app = Logger(subsystem: subsystem, category: "app")
    /// Keychain access (never the secret itself).
    static let keychain = Logger(subsystem: subsystem, category: "keychain")
    /// Session sharing links, dropped sessions, wake/network changes and
    /// automatic sign-ins.
    static let sharing = Logger(subsystem: subsystem, category: "sharing")
}
