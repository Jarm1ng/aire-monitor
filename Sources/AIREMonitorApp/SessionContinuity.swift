import HPCCore
import AppKit
import CoreGraphics
import Foundation
import Network

// MARK: - Keeping sessions going on a Mac that moves around
//
// A laptop sleeps, changes networks and drops off the VPN, and every one of
// those can end the app's ControlMasters — and with them every `ssh aire`
// other programs run over the shared sessions. Three pieces keep that
// graceful:
//
// - `ConnectivityMonitor` notices wake and network changes, so the app
//   checks its sessions at once instead of on the next (possibly backed-off)
//   refresh tick, and sharing drops links to masters that died.
// - `ClusterSession.droppedAt` tells a lost session from a Disconnect.
// - `AutoReconnectPolicy` decides when the app may sign a dropped cluster in
//   again by itself. Each sign-in can send a Duo push, so it is bounded:
//   only with a saved password that was not rejected, only while the user is
//   at the Mac and the network is up, a few attempts per drop at most, and
//   never again after a push was declined or went unanswered until the user
//   signs in themselves.

/// When the app may sign a dropped cluster in again by itself.
struct AutoReconnectPolicy: Equatable {
    enum State: Equatable {
        /// Dropped; the next automatic attempt may start at `notBefore`.
        case pending(attempts: Int, notBefore: Date)
        /// An automatic sign-in was queued at `since`.
        case attempting(attempts: Int, since: Date)
        /// Waiting for the user: a push was declined or unanswered, the
        /// password was rejected, the user cancelled, or the attempts ran
        /// out. Cleared by any successful sign-in.
        case suspended
    }

    /// A failed attempt that sent no push (the old master still answering
    /// on its socket while its link is dead, the network still coming up)
    /// is retried after this long. OpenSSH closes a dead master within five
    /// minutes (ServerAlive 30 s x 10), so three attempts cover it.
    static let retryDelay: TimeInterval = 150
    static let maximumAttempts = 3
    /// An attempt that never reported an outcome (its Keychain read was
    /// denied, say, so no sign-in ran) is retried after this long — well
    /// past the login watchdog, so a sign-in still waiting on Duo is never
    /// taken for a lost one.
    static let lostAttemptAfter: TimeInterval = 600
    /// Recent keyboard or mouse input that counts as "at the Mac".
    static let presenceWindow: TimeInterval = 120

    private(set) var states: [ClusterID: State] = [:]

    var isEmpty: Bool { states.isEmpty }

    func state(of id: ClusterID) -> State? {
        states[id]
    }

    /// A live session was lost. A cluster already waiting for the user stays
    /// suspended: the drop of a session nobody approved is not news.
    mutating func sessionDropped(_ id: ClusterID, at date: Date) {
        if states[id] == .suspended {
            return
        }
        states[id] = .pending(attempts: 0, notBefore: date)
    }

    /// The user disconnected, switched the cluster off, or the setting was
    /// turned off: nothing to come back to.
    mutating func forget(_ id: ClusterID) {
        states[id] = nil
    }

    mutating func reset() {
        states = [:]
    }

    /// Pending clusters whose next attempt is due.
    func due(at date: Date) -> [ClusterID] {
        states.compactMap { id, state in
            if case .pending(_, let notBefore) = state, notBefore <= date {
                return id
            }
            return nil
        }
        .sorted { $0.rawValue < $1.rawValue }
    }

    mutating func attemptStarted(_ id: ClusterID, at date: Date) {
        guard case .pending(let attempts, _) = states[id] else {
            return
        }
        states[id] = .attempting(attempts: attempts + 1, since: date)
    }

    /// Attempts that never reported back go back to pending (see
    /// `lostAttemptAfter`), or to the user once the attempts ran out.
    mutating func sweepLostAttempts(at date: Date) {
        for (id, state) in states {
            guard case .attempting(let attempts, let since) = state,
                  date.timeIntervalSince(since) >= Self.lostAttemptAfter else {
                continue
            }
            states[id] = attempts < Self.maximumAttempts ? .pending(attempts: attempts, notBefore: date) : .suspended
        }
    }

    /// Records how a sign-in of `id` ended. Any success clears the cluster;
    /// a manual failure leaves it to the user; an automatic one either waits
    /// for the user or retries later.
    mutating func record(_ outcome: LoginOutcome, for id: ClusterID, automatic: Bool, at date: Date) {
        switch outcome {
        case .succeeded:
            states[id] = nil
            return
        case .skipped:
            if case .attempting(let attempts, _) = states[id] {
                states[id] = .pending(attempts: attempts, notBefore: date.addingTimeInterval(Self.retryDelay))
            }
            return
        default:
            break
        }
        guard automatic, case .attempting(let attempts, _) = states[id] else {
            if outcome == .cancelled, states[id] != nil {
                states[id] = .suspended
            }
            return
        }
        switch outcome {
        case .failed where attempts < Self.maximumAttempts:
            states[id] = .pending(attempts: attempts, notBefore: date.addingTimeInterval(Self.retryDelay))
        default:
            // Declined, unanswered, rejected, cancelled, rash failed, or out
            // of attempts: another push now would only be noise.
            states[id] = .suspended
        }
    }
}

/// Seconds since the last keyboard, mouse or trackpad input in this login
/// session. Needs no permission.
enum UserPresence {
    static func secondsSinceLastInput() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: UInt32.max) else {
            return .infinity
        }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    static func isActive(within window: TimeInterval = AutoReconnectPolicy.presenceWindow) -> Bool {
        secondsSinceLastInput() <= window
    }
}

/// Wake and network-path changes, delivered on the main actor (debounced by
/// the caller), plus whether a usable network path exists right now.
@MainActor
final class ConnectivityMonitor {
    enum Change: String {
        case wake
        case network
    }

    private(set) var isNetworkAvailable = true
    private var pathMonitor: NWPathMonitor?
    private var wakeObserver: NSObjectProtocol?
    private var lastPathSignature: String?
    private let onChange: @MainActor (Change) -> Void

    init(onChange: @escaping @MainActor (Change) -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard pathMonitor == nil else {
            return
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onChange(.wake)
            }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            // Interfaces in use plus the status: a Wi-Fi network change
            // keeps the interface name, so also note whether IPv4/IPv6
            // gateways exist (they flip while a new network is joined).
            let signature = "\(path.status)|"
                + path.availableInterfaces.map(\.name).joined(separator: ",")
                + "|\(path.supportsIPv4)|\(path.supportsIPv6)|\(path.gateways.count)"
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.isNetworkAvailable = available
                let changed = self.lastPathSignature != nil && self.lastPathSignature != signature
                self.lastPathSignature = signature
                if changed {
                    self.onChange(.network)
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "local.aire.monitor.network-path"))
        pathMonitor = monitor
    }

    func stop() {
        pathMonitor?.cancel()
        pathMonitor = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
    }
}

/// "3 h 12 min", "45 min", "under a minute": how long a session has been up
/// or lasted.
enum SessionAge {
    /// Past this age the Sessions card suggests renewing. The university
    /// VPN session has been seen ending about 12 h after it started,
    /// taking every SSH session over it along.
    static let renewSuggestedAfter: TimeInterval = 11 * 3600

    static func text(_ interval: TimeInterval) -> String {
        let minutes = Int(max(interval, 0) / 60)
        if minutes < 1 {
            return "under a minute"
        }
        let hours = minutes / 60
        if hours == 0 {
            return "\(minutes) min"
        }
        if hours >= 48 {
            return "\(hours / 24) d \(hours % 24) h"
        }
        return minutes % 60 == 0 ? "\(hours) h" : "\(hours) h \(minutes % 60) min"
    }

    /// "4:12" style clock for compact places (menu bar rows).
    static func clock(_ interval: TimeInterval) -> String {
        let minutes = Int(max(interval, 0) / 60)
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}

/// One lost session: when, and how long it had been up (nil when the app
/// never saw its master's start).
struct SessionDrop: Equatable {
    let at: Date
    let lasted: TimeInterval?
}
