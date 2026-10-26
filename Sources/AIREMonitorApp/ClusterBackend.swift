import HPCCore
import Foundation

/// Everything a `ClusterSession` asks of the outside world over SSH. The
/// production implementation is `MonitorService` (real helper scripts,
/// ControlMaster sockets, the Python collector); tests inject a fake so the
/// session's state machine — login queueing and cancellation, refresh
/// supersession, backoff, logout rules, the job diff — can be exercised
/// without processes, timers or a network.
protocol ClusterBackend: Sendable {
    /// One collector run over the cluster's ControlMaster. `skipStorage`
    /// leaves out the storage section (df, quota, lfs); the snapshot then
    /// has `storage == nil` and the session keeps its previous rows.
    /// `jobUsage` adds the per-job sample on the compute nodes
    /// (`--job-usage`).
    func collectSnapshot(settings: ConnectionSettings, skipStorage: Bool, jobUsage: Bool) async throws -> ClusterSnapshot

    /// Interactive sign-in (password on the helpers' stdin, Duo). Reuses a
    /// healthy master unless `forceReplace` (the confirmed Reconnect), and
    /// says whether the password was actually checked on the way.
    /// `renewJumpHost` replaces the shared rash master too (the first
    /// cluster of a confirmed "Renew all"). Must stop its helper processes
    /// promptly when the calling task is cancelled.
    func login(
        settings: ConnectionSettings,
        password: String,
        forceReplace: Bool,
        renewJumpHost: Bool,
        onStatus: (@Sendable (String) -> Void)?
    ) async throws -> LoginResult

    func runRemoteCommand(
        settings: ConnectionSettings,
        command: String,
        timeout: TimeInterval
    ) async throws -> ProcessResult

    /// Closes this identity's ControlMaster. Never touches another
    /// cluster's master; the shared rash jump master only when
    /// `stopJumpIfUnused` and nothing else rides on it.
    func stopMaster(settings: ConnectionSettings, stopJumpIfUnused: Bool) async throws -> StopMasterReport

    /// Reuse-only starter run for a master the app found but did not start:
    /// never prompts, never pushes Duo, never tears anything down.
    func adoptMaster(settings: ConnectionSettings) async -> MasterAdoption

    /// `ssh -O check`: is a usable master listening on this identity's socket?
    func isMasterAlive(settings: ConnectionSettings) async -> Bool
}

extension ClusterBackend {
    func runRemoteCommand(settings: ConnectionSettings, command: String) async throws -> ProcessResult {
        try await runRemoteCommand(settings: settings, command: command, timeout: 30)
    }
}

extension MonitorService: ClusterBackend {}

/// Drives a session's background refresh cadence. Wrapping `Timer` lets a
/// test fire ticks by hand and read the interval the session chose (backoff
/// included) instead of sleeping.
@MainActor
protocol RefreshScheduling: AnyObject {
    var isScheduled: Bool { get }
    /// The interval of the current schedule; nil when nothing is scheduled.
    var interval: TimeInterval? { get }
    /// Replaces any existing schedule.
    func schedule(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Void)
    func cancel()
}

/// Production scheduler: a repeating main-run-loop timer in `.common` mode,
/// so refreshes keep firing while a menu is open or a scroll is tracking.
@MainActor
final class TimerRefreshScheduler: RefreshScheduling {
    private var timer: Timer?
    private(set) var interval: TimeInterval?

    var isScheduled: Bool { timer != nil }

    func schedule(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) {
        cancel()
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            // Scheduled on the main run loop, so this is the main thread.
            MainActor.assumeIsolated {
                tick()
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        self.interval = interval
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        interval = nil
    }
}
