import Darwin
import Foundation
import HPCCore

/// Runs a login helper as a one-shot launchd job in the user's GUI domain
/// instead of as a child of the app.
///
/// Every process the app starts stays in the app's coalition and keeps the
/// app as its responsible process, even after it daemonizes, and macOS
/// ends what an app leaves there. Force Quit (Activity Monitor, the Dock,
/// the Force Quit window) takes down the whole coalition: on 2026-11-11 a
/// force quit during an update ended every session within 3 ms. After a
/// normal quit, loginwindow asks Background Task Management whether the
/// app may run in the background and ends the leftovers about 1 s later
/// when it may not or the check fails: later that day an update moved the
/// bundle aside as the app quit, the check could not read it, and both
/// sessions ended. Started by launchd, the helper and every master it
/// starts belong to the job's own coalition and are responsible for
/// themselves, so nothing that happens to the app reaches them.
///
/// The job is plumbed like a child process. The password goes in through
/// a FIFO on stdin, never argv or the job's environment. stdout and stderr
/// come back through FIFOs, line by line, and a wrapper shell records the
/// helper's exit status in a file. Cancellation signals the job's process
/// group at once, as `ProcessSignalState` does for a child, so a sign-in
/// cancelled as the app quits cannot finish from a late Duo approval. The
/// watchdog sends TERM, then KILL to whatever of the group is left 2 s
/// later. A helper that finished is never signalled: on the rash route its
/// process group still holds the new master's ProxyCommand.
/// AbandonProcessGroup stops launchd from killing that leftover when the
/// helper exits, and the job is booted out once the helper has exited,
/// which leaves it alone.
enum DetachedHelper {
    static let labelPrefix = "\(WidgetAppLauncher.appBundleIdentifier).helper."

    /// The per-user temporary folder: 0700, never privacy-protected, never
    /// backed up, so a job can always open its files there.
    static var defaultJobRoot: String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("aire-monitor-helpers")
    }

    /// Whether a launchd job can read the checkout. The app holds the
    /// user's Files & Folders permission for privacy-protected folders, but
    /// a job is its own responsible process and does not. A checkout under
    /// Documents, Desktop, Downloads, iCloud Drive or another cloud
    /// provider, or on another volume, would leave the job's helper unable
    /// to read its scripts, so those checkouts run the helpers from the app.
    static func canRunOutsideApp(projectRoot: String, home: String = NSHomeDirectory()) -> Bool {
        let root = (projectRoot as NSString).standardizingPath
        let protected = ["Documents", "Desktop", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]
            .map { (home as NSString).appendingPathComponent($0) } + ["/Volumes"]
        return !protected.contains { root == $0 || root.hasPrefix($0 + "/") }
    }

    /// Names the wrapper and the job's files share.
    struct JobFiles: Equatable {
        let directory: String
        var plist: String { directory + "/job.plist" }
        var stdin: String { directory + "/stdin" }
        var stdout: String { directory + "/stdout" }
        var stderr: String { directory + "/stderr" }
        var pid: String { directory + "/pid" }
        var status: String { directory + "/status" }
    }

    /// Records its own pid (the job's process group), runs the helper, and
    /// writes the helper's exit status atomically once it is done.
    static let wrapperScript = """
        echo $$ > "$HPC_HELPER_JOB_DIR/pid"
        "$@"
        status=$?
        echo "$status" > "$HPC_HELPER_JOB_DIR/status.tmp" && mv -f "$HPC_HELPER_JOB_DIR/status.tmp" "$HPC_HELPER_JOB_DIR/status"
        """

    /// The job definition (testable form). `hasStdin` false reads
    /// /dev/null, as a child without input does.
    static func jobDefinition(
        label: String,
        files: JobFiles,
        executable: String,
        arguments: [String],
        currentDirectory: String,
        environment: [String: String],
        hasStdin: Bool
    ) -> [String: Any] {
        var jobEnvironment = environment
        jobEnvironment["HPC_HELPER_JOB_DIR"] = files.directory
        return [
            "Label": label,
            "ProgramArguments": ["/bin/sh", "-c", wrapperScript, "sh", executable] + arguments,
            "EnvironmentVariables": jobEnvironment,
            "WorkingDirectory": currentDirectory,
            "StandardInPath": hasStdin ? files.stdin : "/dev/null",
            "StandardOutPath": files.stdout,
            "StandardErrorPath": files.stderr,
            "RunAtLoad": true,
            "KeepAlive": false,
            "AbandonProcessGroup": true,
            // A sign-in the user waits on, not background work to throttle.
            "ProcessType": "Interactive",
        ]
    }

    private enum Outcome {
        case ran
        /// launchd refused the job or never started it: run it as a child.
        case notStarted
        /// Cancelled before the job was started; nothing ran.
        case cancelledBeforeStart
    }

    /// Runs `executable` as a launchd job and returns what a child process
    /// run would: its output and exit status, 124 when the watchdog stopped
    /// it. nil when launchd did not take or start the job (no GUI session,
    /// bootstrap refused, a job that never ran); the caller then runs the
    /// helper as a child instead.
    static func run(
        executable: String,
        arguments: [String],
        currentDirectory: String,
        environment: [String: String],
        stdin: String?,
        timeout: TimeInterval,
        jobRoot: String = defaultJobRoot,
        onOutputLine: (@Sendable (String) -> Void)? = nil
    ) async -> ProcessResult? {
        let cancelled = ProcessResult(stdout: "", stderr: "", exitCode: 128 + SIGTERM)
        if Task.isCancelled {
            return cancelled
        }
        let identifier = UUID().uuidString.lowercased()
        let label = labelPrefix + identifier
        let files = JobFiles(directory: (jobRoot as NSString).appendingPathComponent("helper-\(identifier)"))
        let manager = FileManager.default
        do {
            try manager.createDirectory(atPath: jobRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.createDirectory(atPath: files.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            Log.login.error("helper job: could not create \(files.directory, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        defer { try? manager.removeItem(atPath: files.directory) }

        for fifo in [files.stdin, files.stdout, files.stderr] where mkfifo(fifo, 0o600) != 0 {
            Log.login.error("helper job: mkfifo failed: \(String(cString: strerror(errno)), privacy: .public)")
            return nil
        }
        let definition = jobDefinition(
            label: label,
            files: files,
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: environment,
            hasStdin: stdin != nil
        )
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: files.plist), options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: files.plist)
        } catch {
            Log.login.error("helper job: could not write the job definition: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        // O_RDWR never blocks and keeps the password in the FIFO until the
        // helper reads it; the descriptor stays open until the job is done.
        var stdinDescriptor: Int32 = -1
        if let stdin {
            stdinDescriptor = open(files.stdin, O_RDWR | O_CLOEXEC)
            guard stdinDescriptor >= 0, writeAll(stdinDescriptor, Data(stdin.utf8)) else {
                if stdinDescriptor >= 0 {
                    close(stdinDescriptor)
                }
                return nil
            }
        }
        defer {
            if stdinDescriptor >= 0 {
                close(stdinDescriptor)
            }
        }

        let stdoutCollector = PipeCollector(onLine: onOutputLine)
        let stderrCollector = PipeCollector()
        let readers = FIFOReaders()
        readers.start(fifo: files.stdout, into: stdoutCollector)
        readers.start(fifo: files.stderr, into: stderrCollector)

        // The job's whole life runs on its own thread: launchctl and the
        // bounded waits below block, which no Swift concurrency thread may.
        let state = DetachedJobState(files: files)
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                Thread.detachNewThread {
                    removeStaleJobs(jobRoot: jobRoot)
                    guard !state.cancelled else {
                        readers.wake(files: files)
                        continuation.resume(returning: .cancelledBeforeStart)
                        return
                    }
                    guard bootstrap(plist: files.plist) else {
                        readers.wake(files: files)
                        continuation.resume(returning: .notStarted)
                        return
                    }
                    // launchd starts a RunAtLoad job at once. One that has
                    // neither recorded its pid nor opened its output within
                    // 5 s never ran (launchd could not set it up).
                    let deadline = Date().addingTimeInterval(5)
                    while state.resolvePID() <= 0, !readers.anyOpened, Date() < deadline {
                        usleep(50_000)
                    }
                    guard state.resolvePID() > 0 || readers.anyOpened else {
                        bootout(label: label)
                        readers.wake(files: files)
                        Log.login.error("helper job \(label, privacy: .public) never started")
                        continuation.resume(returning: .notStarted)
                        return
                    }
                    waitForExit(state: state, timeout: timeout)
                    // Late output, as for a child: bounded, since a process
                    // the helper left running may hold a FIFO open a while.
                    _ = readers.wait(seconds: 3)
                    bootout(label: label)
                    continuation.resume(returning: .ran)
                }
            }
        } onCancel: {
            state.cancel()
        }

        switch outcome {
        case .cancelledBeforeStart:
            return cancelled
        case .notStarted:
            return state.cancelled ? cancelled : nil
        case .ran:
            break
        }
        let stdout = stdoutCollector.text
        let stderr = stderrCollector.text
        let status = (try? String(contentsOfFile: files.status, encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if state.timedOut, status != 0 {
            return ProcessResult(
                stdout: stdout,
                stderr: stderr + "\nProcess timed out after \(Int(timeout))s: \(executable)",
                exitCode: MonitorService.processTimedOutExitCode
            )
        }
        // No status: the wrapper was signalled (cancelled) before it could
        // record one; report it the way a shell does.
        return ProcessResult(stdout: stdout, stderr: stderr, exitCode: status ?? 128 + SIGTERM)
    }

    // MARK: - launchd

    private static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.environment = MonitorService.childEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    private static var domain: String { "gui/\(getuid())" }

    private static func bootstrap(plist: String) -> Bool {
        let result = launchctl(["bootstrap", domain, plist])
        if result.status != 0 {
            Log.login.error("helper job: launchctl bootstrap failed (\(result.status, privacy: .public)): \(result.output, privacy: .public)")
        }
        return result.status == 0
    }

    private static func bootout(label: String) {
        _ = launchctl(["bootout", "\(domain)/\(label)"])
    }

    /// Clears what an earlier run left when the app quit, crashed or was
    /// force-quit mid-sign-in, before its own bootout and cleanup: helper
    /// jobs whose wrapper no longer runs (`launchctl list` prints "-" for
    /// their pid), and job folders older than any sign-in can last.
    private static func removeStaleJobs(jobRoot: String) {
        for line in launchctl(["list"]).output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, fields[0] == "-", fields[2].hasPrefix(labelPrefix) else {
                continue
            }
            bootout(label: String(fields[2]))
        }
        let manager = FileManager.default
        let cutoff = Date().addingTimeInterval(-(HPCDefaults.loginWatchdog + 120))
        for name in (try? manager.contentsOfDirectory(atPath: jobRoot)) ?? [] where name.hasPrefix("helper-") {
            let path = (jobRoot as NSString).appendingPathComponent(name)
            if let modified = (try? manager.attributesOfItem(atPath: path))?[.modificationDate] as? Date, modified < cutoff {
                try? manager.removeItem(atPath: path)
            }
        }
    }

    // MARK: - Waiting

    /// Blocks until the wrapper has exited (its status file exists, or its
    /// process is gone). On timeout or cancellation it signals the job's
    /// process group with TERM, then KILLs whatever of the group is left
    /// 2 s later; a wrapper with no trap dies at the first TERM, but a
    /// helper cleaning up might not.
    private static func waitForExit(state: DetachedJobState, timeout: TimeInterval) {
        let started = Date()
        var terminatedAt: Date?
        while true {
            if state.isFinished() {
                return
            }
            let pid = state.resolvePID()
            let now = Date()
            if let terminatedAt {
                let groupLeft = pid > 1 && processGroupExists(pid)
                if !groupLeft {
                    return
                }
                if now.timeIntervalSince(terminatedAt) >= 2 {
                    state.signal(SIGKILL)
                    if now.timeIntervalSince(terminatedAt) >= 4 {
                        return
                    }
                }
            } else {
                if pid > 1, !processExists(pid) {
                    // Gone without a status: nothing of ours stopped it.
                    state.markFinished()
                    return
                }
                if now.timeIntervalSince(started) >= timeout {
                    state.markTimedOut()
                }
                if pid > 1, state.timedOut || state.cancelled {
                    state.signal(SIGTERM)
                    terminatedAt = now
                }
            }
            usleep(100_000)
        }
    }

    private static func processExists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func processGroupExists(_ pgid: pid_t) -> Bool {
        kill(-pgid, 0) == 0 || errno == EPERM
    }

    // MARK: - FIFOs

    private static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else {
                return true
            }
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, base + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    return false
                }
                offset += written
            }
            return true
        }
    }
}

/// The threads reading the job's stdout and stderr FIFOs. Each opens its
/// FIFO (blocking until launchd opens the write end) and reads it to EOF.
private final class FIFOReaders: @unchecked Sendable {
    private let lock = NSLock()
    private let group = DispatchGroup()
    private var openedCount = 0

    var anyOpened: Bool {
        lock.lock()
        defer { lock.unlock() }
        return openedCount > 0
    }

    func start(fifo path: String, into collector: PipeCollector) {
        group.enter()
        Thread.detachNewThread { [self] in
            let descriptor = open(path, O_RDONLY | O_CLOEXEC)
            if descriptor >= 0 {
                lock.lock()
                openedCount += 1
                lock.unlock()
                var buffer = [UInt8](repeating: 0, count: 16_384)
                while true {
                    let count = read(descriptor, &buffer, buffer.count)
                    if count > 0 {
                        collector.append(Data(buffer[0..<count]))
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
                close(descriptor)
            }
            collector.finish()
            group.leave()
        }
    }

    func wait(seconds: TimeInterval) -> Bool {
        group.wait(timeout: .now() + seconds) == .success
    }

    /// Unblocks readers still waiting in open(2) for a job that will never
    /// open the write ends: a writer that opens and closes gives them EOF.
    /// Repeated, since a reader thread may only reach open(2) later.
    func wake(files: DetachedHelper.JobFiles) {
        for _ in 0..<20 {
            for path in [files.stdout, files.stderr] {
                let descriptor = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
                if descriptor >= 0 {
                    close(descriptor)
                }
            }
            if wait(seconds: 0.1) {
                return
            }
        }
    }
}

/// The job's process group and why it is being stopped; read by the waiter
/// thread, written by it and by task cancellation.
private final class DetachedJobState: @unchecked Sendable {
    private let lock = NSLock()
    private let files: DetachedHelper.JobFiles
    private var processID: pid_t = -1
    private var cancelRequested = false
    private var timedOutFlag = false
    private var finished = false

    init(files: DetachedHelper.JobFiles) {
        self.files = files
    }

    var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelRequested
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOutFlag
    }

    /// The wrapper's pid, read from its pid file the first time it is
    /// there in full (the wrapper writes it before anything else).
    @discardableResult
    func resolvePID() -> pid_t {
        lock.lock()
        defer { lock.unlock() }
        return resolvePIDLocked()
    }

    private func resolvePIDLocked() -> pid_t {
        if processID <= 0,
           let text = try? String(contentsOfFile: files.pid, encoding: .utf8),
           text.hasSuffix("\n"),
           let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           value > 1 {
            processID = value
        }
        return processID
    }

    /// The helper exited and the wrapper recorded its status (or the
    /// wrapper is gone without one): from now on nothing is signalled.
    func isFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !finished, FileManager.default.fileExists(atPath: files.status) {
            finished = true
        }
        return finished
    }

    func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    func markTimedOut() {
        lock.lock()
        timedOutFlag = true
        lock.unlock()
    }

    /// Signals at once, not on the waiter's next tick: the app may be
    /// quitting (`AppModel.prepareForTermination` cancels sign-ins), and a
    /// helper outside the app would otherwise live on and build a master
    /// from a late Duo approval. Before the wrapper has recorded its pid
    /// the waiter signals as soon as it does; once the job is not started
    /// at all, it never will be.
    func cancel() {
        lock.lock()
        cancelRequested = true
        lock.unlock()
        signal(SIGTERM)
    }

    /// The wrapper leads the job's process group (launchd starts every job
    /// in its own session), so this reaches the helper and everything it
    /// started that is still in the group, never a master that daemonized.
    /// A finished helper is never signalled: its group may still hold a
    /// rash-route master's ProxyCommand.
    func signal(_ signal: Int32) {
        lock.lock()
        if !finished, FileManager.default.fileExists(atPath: files.status) {
            finished = true
        }
        let pid = finished ? -1 : resolvePIDLocked()
        lock.unlock()
        guard pid > 1 else {
            return
        }
        if kill(-pid, signal) != 0 {
            _ = kill(pid, signal)
        }
    }
}
