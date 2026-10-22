import Foundation

/// What a bounded child process produced.
public struct WidgetProcessOutcome: Equatable, Sendable {
    /// Exit status, or -1 when the run was completed before the exit status
    /// arrived (it never does for a child that cannot be reaped).
    public let terminationStatus: Int32
    public let stdout: Data
    public let stderr: Data
    /// The deadline passed while the child was still running, so it was
    /// signalled. Never set for a child that had already exited, so output
    /// it wrote completely before exiting can still count as clean.
    public let timedOut: Bool
    /// Completed without both pipes closing: a descendant (for example an
    /// ssh the child spawned) still held stdout or stderr open.
    public let forcedCompletion: Bool

    public init(terminationStatus: Int32, stdout: Data, stderr: Data, timedOut: Bool, forcedCompletion: Bool) {
        self.terminationStatus = terminationStatus
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.forcedCompletion = forcedCompletion
    }
}

/// Runs a child process without blocking a cooperative-pool thread, and with
/// a guarantee that the caller always gets an outcome:
/// - both pipes are drained while the child runs (a full pipe buffer would
///   otherwise deadlock it), capped at `outputLimit` bytes each;
/// - termination is observed through `terminationHandler` before the exit
///   status is read;
/// - at the deadline a still-running child gets SIGTERM, then SIGKILL after
///   `killGracePeriod`;
/// - once the child has exited (normally or killed), the pipes get one more
///   `killGracePeriod` to reach EOF, then the run completes with whatever
///   was captured — a descendant holding an inherited pipe descriptor can
///   never wedge the caller (and with it the widget's per-cluster in-flight
///   gate and spinner).
public enum WidgetProcessRunner {
    public static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        deadline: TimeInterval,
        killGracePeriod: TimeInterval = 3,
        outputLimit: Int = 8 * 1024 * 1024
    ) async throws -> WidgetProcessOutcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // Without SDKROOT (exported by xcrun to anything a build or a shell
        // started): with it set, /usr/bin/python3 on a Mac with full Xcode
        // resolves itself through xcodebuild on every run.
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SDKROOT")
        process.environment = environment
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let state = WidgetRunnerState(outputLimit: outputLimit)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            if state.received(handle.availableData, on: .stdout) {
                handle.readabilityHandler = nil
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            if state.received(handle.availableData, on: .stderr) {
                handle.readabilityHandler = nil
            }
        }
        // Floored so the post-exit drain below can never cut off the last
        // buffered bytes of a child that exited normally.
        let grace = max(killGracePeriod, 0.2)
        process.terminationHandler = { finished in
            state.processExited(status: finished.terminationStatus)
            // Pipes still open after the exit belong to a descendant: allow
            // a moment for the last buffered bytes (at most one pipe buffer,
            // since the child could not exit while blocked writing), then
            // stop waiting for an EOF that may never come.
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: nanoseconds(grace))
                state.forceFinish()
            }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        let pid = process.processIdentifier

        let watchdog = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(nanoseconds: nanoseconds(max(deadline, 0)))
            } catch {
                return // Cancelled: the run completed in time.
            }
            if state.markTimedOutIfRunning() {
                kill(pid, SIGTERM)
                do {
                    try await Task.sleep(nanoseconds: nanoseconds(grace))
                } catch {
                    return
                }
                if !state.hasExited {
                    kill(pid, SIGKILL)
                }
            }
            // Normally the exit handler completes the run; this is the
            // backstop for a child whose exit is never reported, and runs
            // whether or not the child was still running at the deadline.
            guard !state.isFinished else {
                return
            }
            do {
                try await Task.sleep(nanoseconds: nanoseconds(grace * 2))
            } catch {
                return
            }
            state.forceFinish()
        }

        let outcome = await withCheckedContinuation { continuation in
            state.install(continuation)
        }
        watchdog.cancel()
        return outcome
    }

    static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(seconds, 0) * 1_000_000_000)
    }
}

/// The completion bookkeeping of one run, shared by the pipe handlers, the
/// termination handler and the watchdog (all on different threads), so every
/// field is guarded by one lock. Whichever event completes the run resumes
/// the continuation exactly once; later events are no-ops.
public final class WidgetRunnerState: @unchecked Sendable {
    public enum Stream: Sendable {
        case stdout
        case stderr
    }

    private let lock = NSLock()
    private let outputLimit: Int
    private var stdoutData = Data()
    private var stderrData = Data()
    private var stdoutClosed = false
    private var stderrClosed = false
    private var exitStatus: Int32?
    private var timedOut = false
    private var finished = false
    private var continuation: CheckedContinuation<WidgetProcessOutcome, Never>?

    public init(outputLimit: Int) {
        self.outputLimit = max(outputLimit, 0)
    }

    public var hasExited: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exitStatus != nil
    }

    public var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    /// Records a chunk read from one pipe; an empty chunk is EOF. Returns
    /// true when the caller should stop reading that pipe (EOF, or the run
    /// already completed and further output is discarded).
    @discardableResult
    public func received(_ chunk: Data, on stream: Stream) -> Bool {
        lock.lock()
        var detach = finished
        if chunk.isEmpty {
            detach = true
            switch stream {
            case .stdout:
                stdoutClosed = true
            case .stderr:
                stderrClosed = true
            }
        } else if !finished {
            switch stream {
            case .stdout:
                if stdoutData.count < outputLimit {
                    stdoutData.append(chunk.prefix(outputLimit - stdoutData.count))
                }
            case .stderr:
                if stderrData.count < outputLimit {
                    stderrData.append(chunk.prefix(outputLimit - stderrData.count))
                }
            }
        }
        let resume = completionIfReadyLocked()
        lock.unlock()
        resume?()
        return detach
    }

    public func processExited(status: Int32) {
        lock.lock()
        exitStatus = status
        let resume = completionIfReadyLocked()
        lock.unlock()
        resume?()
    }

    /// Marks the run as timed out if the child is still running; false once
    /// it has exited or the run completed (nothing left to signal).
    public func markTimedOutIfRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, exitStatus == nil else {
            return false
        }
        timedOut = true
        return true
    }

    /// Completes the run with whatever was captured. A no-op once finished.
    public func forceFinish() {
        lock.lock()
        let resume = finishLocked(forced: true)
        lock.unlock()
        resume?()
    }

    public func install(_ continuation: CheckedContinuation<WidgetProcessOutcome, Never>) {
        lock.lock()
        self.continuation = continuation
        let resume = completionIfReadyLocked()
        lock.unlock()
        resume?()
    }

    private func completionIfReadyLocked() -> (() -> Void)? {
        guard stdoutClosed, stderrClosed, exitStatus != nil else {
            return nil
        }
        return finishLocked(forced: false)
    }

    /// Without an installed continuation there is nobody to resume yet;
    /// `install` re-checks, and a forced finish before then is retried by
    /// the watchdog's later pass.
    private func finishLocked(forced: Bool) -> (() -> Void)? {
        guard !finished, let continuation else {
            return nil
        }
        finished = true
        self.continuation = nil
        let outcome = WidgetProcessOutcome(
            terminationStatus: exitStatus ?? -1,
            stdout: stdoutData,
            stderr: stderrData,
            timedOut: timedOut,
            forcedCompletion: forced && !(stdoutClosed && stderrClosed)
        )
        return {
            continuation.resume(returning: outcome)
        }
    }
}
