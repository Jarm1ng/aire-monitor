import Foundation

// The desktop widget's fallback collector: how it reads and validates the
// app's password-free `collector.json`, runs the collector, and judges the
// result. The widget never authenticates; it only reuses a ControlMaster the
// app left behind.

/// `.runtime/clusters/<id>/collector.json`, written by the app's
/// MonitorService: exactly the invocation the app itself runs.
public struct WidgetCollectorRecord: Decodable, Equatable, Sendable {
    public let updatedAt: String?
    public let script: String
    public let arguments: [String]

    public init(updatedAt: String? = nil, script: String, arguments: [String]) {
        self.updatedAt = updatedAt
        self.script = script
        self.arguments = arguments
    }
}

/// A collector invocation that passed validation and is safe to execute.
public struct WidgetValidatedCollector: Equatable, Sendable {
    public let scriptPath: String
    public let arguments: [String]
    public let deadline: TimeInterval

    public init(scriptPath: String, arguments: [String], deadline: TimeInterval) {
        self.scriptPath = scriptPath
        self.arguments = arguments
        self.deadline = deadline
    }

    /// The cluster ControlMaster's socket, when the arguments name one.
    public var controlPath: String? {
        WidgetCollector.argumentValue("--control-path", in: arguments)
    }
}

public enum WidgetCollectorLoadResult: Equatable, Sendable {
    /// No record: the app has never connected this cluster.
    case missing
    case invalid(String)
    case ready(WidgetValidatedCollector)
}

public struct WidgetCollectorError: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// The outcome of one fallback collection.
public struct WidgetCollectionResult: Equatable, Sendable {
    /// Collector stdout byte for byte; this is what gets written to disk.
    public let output: Data
    public let snapshot: ClusterSnapshot?
    /// Exit 0, decoded, no collector errors and no watchdog timeout: the only
    /// outcome that may replace the cluster's snapshot file.
    public let isClean: Bool
    public let failureMessage: String?

    public init(output: Data, snapshot: ClusterSnapshot?, isClean: Bool, failureMessage: String?) {
        self.output = output
        self.snapshot = snapshot
        self.isClean = isClean
        self.failureMessage = failureMessage
    }

    /// The collector found the cluster's ControlMaster dead: only a sign-in
    /// in the app can fix that, so retrying soon is pointless.
    public var isMissingMaster: Bool {
        failureMessage.map(WidgetCollector.isMissingMasterMessage) ?? false
    }
}

public enum WidgetCollector {
    /// Watchdog headroom above the collector's own budget: interpreter
    /// start-up, the collector reaping its timed-out ssh child, and JSON
    /// assembly. Deliberately twice the app's (HPCDefaults.collectorWatchdog
    /// allows budget + 10 s): killing a slow but healthy collection throws a
    /// good snapshot away and the next attempt cannot start for another
    /// refresh period anyway, while a wedged child still gets killed.
    public static let deadlineHeadroom: TimeInterval = 20
    private static let maxMessageLength = 400

    public static func load(clusterID: String, directory: String, projectRoot: String) -> WidgetCollectorLoadResult {
        let path = "\(directory)/collector.json"
        guard let data = FileManager.default.contents(atPath: path) else {
            return .missing
        }
        let record: WidgetCollectorRecord
        do {
            record = try JSONDecoder().decode(WidgetCollectorRecord.self, from: data)
        } catch {
            return .invalid("Unreadable collector record \(path): \(error.localizedDescription)")
        }
        // The file sits in this cluster's directory, so it must describe this
        // cluster; anything else would write one cluster's data into
        // another's snapshot.
        if let recorded = argumentValue("--cluster-id", in: record.arguments), recorded != clusterID {
            return .invalid("\(path) is for cluster '\(recorded)', not '\(clusterID)'; reconnect in Leeds HPC Monitor.")
        }
        do {
            let scriptPath = try validatedScriptPath(record.script, projectRoot: projectRoot)
            return .ready(
                WidgetValidatedCollector(
                    scriptPath: scriptPath,
                    arguments: record.arguments,
                    deadline: processDeadline(arguments: record.arguments)
                )
            )
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    /// The recorded script must be a relative path inside the project root
    /// (no absolute path, no `~`, no `..`, and not a symlink escaping the
    /// checkout) and must be an existing file: `.runtime` is a plain
    /// directory, and this is the only thing the widget ever executes from it.
    public static func validatedScriptPath(_ script: String, projectRoot: String) throws -> String {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~"),
              !trimmed.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            throw WidgetCollectorError("Refusing collector script '\(script)': it must be a relative path inside the project.")
        }
        let root = URL(fileURLWithPath: projectRoot).standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = URL(fileURLWithPath: root)
            .appendingPathComponent(trimmed)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        guard candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
            throw WidgetCollectorError("Refusing collector script '\(script)': it resolves outside \(root).")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw WidgetCollectorError("Missing collector script at \(candidate).")
        }
        return candidate
    }

    /// Value of `--flag value` or `--flag=value`; nil when the flag is absent
    /// or is the last argument.
    public static func argumentValue(_ flag: String, in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == flag {
                return index + 1 < arguments.count ? arguments[index + 1] : nil
            }
            if argument.hasPrefix(flag + "=") {
                return String(argument.dropFirst(flag.count + 1))
            }
        }
        return nil
    }

    /// hpc_snapshot.py collects everything in ONE batched SSH round trip and
    /// its `--timeout` is the budget for the WHOLE run, socket probe
    /// included, so the watchdog only has to sit comfortably above it: the
    /// recorded budget (HPCDefaults.collectorTimeout when absent, clamped to
    /// 1–300 s) plus `deadlineHeadroom`. 50 s with the app's arguments.
    public static func processDeadline(arguments: [String]) -> TimeInterval {
        let recorded = argumentValue("--timeout", in: arguments).flatMap { Int($0) }
        let budget = min(max(recorded ?? HPCDefaults.collectorTimeout, 1), 300)
        return TimeInterval(budget) + deadlineHeadroom
    }

    /// The `--control-path` socket when it is named but nothing exists there.
    /// The collector then fails anyway ("control master is not running"), so
    /// a stat here saves starting python and ssh just to learn that. Only the
    /// cluster socket matters: every refresh multiplexes over that master,
    /// and the jump host's socket is only used to (re)establish it, which the
    /// widget never does.
    public static func missingControlSocket(
        for collector: WidgetValidatedCollector,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        guard let path = collector.controlPath, !path.isEmpty, !fileExists(path) else {
            return nil
        }
        return path
    }

    /// The collector's definitive "no master" error ("connection lost: SSH
    /// control master is not running …"), the same test the app uses.
    public static func isMissingMasterMessage(_ message: String) -> Bool {
        message.lowercased().contains("control master is not running")
    }

    /// Runs `/usr/bin/python3 <script> <arguments>` in the project root.
    public static func collect(
        projectRoot: String,
        collector: WidgetValidatedCollector,
        killGracePeriod: TimeInterval = 3
    ) async throws -> WidgetCollectionResult {
        let outcome = try await WidgetProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [collector.scriptPath] + collector.arguments,
            currentDirectory: URL(fileURLWithPath: projectRoot),
            deadline: collector.deadline,
            killGracePeriod: killGracePeriod
        )
        return interpret(outcome, deadline: collector.deadline)
    }

    /// Judges a finished run. Only exit 0 with a decodable snapshot, no
    /// collector errors and no timeout is clean; everything else carries the
    /// most useful message available (collector errors, else stderr).
    public static func interpret(_ outcome: WidgetProcessOutcome, deadline: TimeInterval) -> WidgetCollectionResult {
        let stderrText = String(data: outcome.stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let timeoutText = outcome.timedOut
            ? "Snapshot collection timed out after \(Int(deadline)) seconds."
            : nil

        guard let snapshot = try? JSONDecoder().decode(ClusterSnapshot.self, from: outcome.stdout) else {
            let message = combinedMessage([timeoutText, stderrText])
            return WidgetCollectionResult(
                output: outcome.stdout,
                snapshot: nil,
                isClean: false,
                failureMessage: message.isEmpty
                    ? "Refresh failed (collector exited with status \(outcome.terminationStatus))."
                    : message
            )
        }
        let scriptErrors = snapshot.errors.joined(separator: "\n")
        let isClean = outcome.terminationStatus == 0 && scriptErrors.isEmpty && !outcome.timedOut
        let message = combinedMessage([timeoutText, scriptErrors.isEmpty ? stderrText : scriptErrors])
        return WidgetCollectionResult(
            output: outcome.stdout,
            snapshot: snapshot,
            isClean: isClean,
            failureMessage: isClean ? nil : (message.isEmpty ? "Refresh failed." : message)
        )
    }

    private static func combinedMessage(_ parts: [String?]) -> String {
        let joined = parts
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard joined.count > maxMessageLength else {
            return joined
        }
        return String(joined.prefix(maxMessageLength)) + "…"
    }
}
