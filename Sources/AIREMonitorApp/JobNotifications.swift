import HPCCore
import AppKit
import Foundation
import UserNotifications

/// Notification permission as the app understands it, including the
/// failure modes the system API reports only through a completion handler
/// (which used to be ignored, so a failing request looked like "Not
/// requested yet" forever and no alert ever fired).
enum NotificationAuthorization: Equatable, Sendable {
    /// Running as a bare binary without a bundle identifier
    /// (UNUserNotificationCenter aborts the process there).
    case unsupported
    case checking
    case notDetermined
    /// The permission request itself failed (the system's error text).
    case requestFailed(String)
    case denied
    case authorized
    case provisional
    case ephemeral

    var canPost: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    /// Sidebar wording.
    var summary: String {
        switch self {
        case .unsupported:
            return "Unavailable outside the app bundle"
        case .checking:
            return "Checking…"
        case .notDetermined:
            return "Not requested yet"
        case .requestFailed(let reason):
            return "Request failed: \(reason)"
        case .denied:
            return "Denied — enable in System Settings"
        case .authorized:
            return "Allowed"
        case .provisional:
            return "Allowed (provisional)"
        case .ephemeral:
            return "Ephemeral"
        }
    }

    /// What a button next to the summary should offer, if anything.
    var permissionAction: NotificationPermissionAction? {
        switch self {
        case .notDetermined, .requestFailed:
            return .request
        case .denied:
            return .openSystemSettings
        default:
            return nil
        }
    }
}

enum NotificationPermissionAction: Equatable, Sendable {
    case request
    case openSystemSettings

    var title: String {
        switch self {
        case .request:
            return "Request permission"
        case .openSystemSettings:
            return "Open System Settings"
        }
    }
}

/// One local notification, independent of UserNotifications types so tests
/// can inspect what would have been posted.
struct LocalNotification: Equatable, Sendable {
    let title: String
    let subtitle: String
    let body: String
    let identifier: String
    let thread: String
}

/// The slice of UNUserNotificationCenter the app uses. Tests inject a fake:
/// the real center aborts or prompts inside a test runner.
@MainActor
protocol NotificationPosting: AnyObject {
    func install(delegate: UNUserNotificationCenterDelegate)
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func post(_ notification: LocalNotification)
}

@MainActor
final class UserNotificationCenterPoster: NotificationPosting {
    // Resolved lazily: merely creating the poster must not touch the
    // notification center (AppModel is built before launch finishes).
    private var center: UNUserNotificationCenter { .current() }

    func install(delegate: UNUserNotificationCenterDelegate) {
        center.delegate = delegate
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        // Only the status crosses back to the main actor: UNNotificationSettings
        // is not Sendable in the macOS 15 SDK (CI's), so it never leaves the
        // callback.
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func post(_ notification: LocalNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle
        content.body = notification.body
        content.sound = .default
        content.threadIdentifier = notification.thread
        let request = UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil)
        let identifier = notification.identifier
        center.add(request) { error in
            if let error {
                Log.notifications.error(
                    "Could not post \(identifier, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
    }
}

/// What a session needs to announce events. AppModel hands sessions the
/// shared JobNotificationService; tests hand them a recorder.
@MainActor
protocol ClusterEventNotifying: AnyObject {
    /// Posts the given job events (asynchronously; never touches session
    /// state, so it cannot cause an extra render pass).
    func notifyJobChanges(_ changes: JobStateChanges, cluster: ClusterProfile)
    /// Posts the "a GPU freed up" alert. True when it was actually queued,
    /// so the caller can start its cooldown.
    func notifyGPUBecameAvailable(
        cluster: ClusterProfile,
        idleCount: Int,
        gpuModel: String?,
        partitions: [String]
    ) async -> Bool
}

/// Posts job start/end and GPU-free alerts and tracks the permission.
///
/// The authorization status is queried only when something is about to be
/// posted, at launch and when the app becomes active — never once per
/// refresh (that used to cost two notification-settings XPC round trips per
/// cluster every 10 s and an extra app-wide render pass for an unchanged
/// summary).
@MainActor
final class JobNotificationService: NSObject, UNUserNotificationCenterDelegate, ClusterEventNotifying {
    static let notificationsSupported = Bundle.main.bundleIdentifier != nil

    private let poster: NotificationPosting?
    private let now: () -> Date
    private(set) var authorization: NotificationAuthorization
    /// Called on the main actor whenever `authorization` changes.
    var onAuthorizationChange: ((NotificationAuthorization) -> Void)?
    private var isRequesting = false
    private var lastRequestError: String?

    private static let iso8601 = ISO8601DateFormatter()

    /// `poster` defaults to the real notification center when the process
    /// has a bundle identifier, and to nothing (alerts unsupported) for a
    /// bare `swift run` binary.
    init(poster: NotificationPosting?, now: @escaping () -> Date = Date.init) {
        self.poster = poster
        self.now = now
        self.authorization = poster == nil ? .unsupported : .checking
        super.init()
    }

    convenience override init() {
        let poster: NotificationPosting? = Self.notificationsSupported ? UserNotificationCenterPoster() : nil
        self.init(poster: poster)
    }

    /// Installs the delegate and asks for permission when it has never been
    /// decided. Called from applicationDidFinishLaunching (via
    /// AppModel.start()): a request made while the app is still launching
    /// failed on every launch.
    func configure() {
        guard let poster else {
            update(.unsupported)
            return
        }
        poster.install(delegate: self)
        refreshAuthorization(requestIfUndetermined: true)
    }

    /// Re-reads the permission; while it is still undetermined (the last
    /// request failed, or was never answered) asks again. Called when the
    /// app becomes active, which also catches changes made in System
    /// Settings.
    func refreshAuthorization(requestIfUndetermined: Bool) {
        guard let poster else {
            return
        }
        Task {
            let status = await poster.authorizationStatus()
            if status == .notDetermined, requestIfUndetermined, !isRequesting {
                await request(using: poster)
            } else {
                update(from: status)
            }
        }
    }

    /// The sidebar's permission button.
    func performPermissionAction() {
        switch authorization.permissionAction {
        case .request:
            guard let poster, !isRequesting else {
                return
            }
            Task {
                await request(using: poster)
            }
        case .openSystemSettings:
            let settings = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
            if let settings {
                NSWorkspace.shared.open(settings)
            }
        case nil:
            break
        }
    }

    private func request(using poster: NotificationPosting) async {
        isRequesting = true
        defer { isRequesting = false }
        do {
            let granted = try await poster.requestAuthorization()
            lastRequestError = nil
            Log.notifications.info("Notification authorization answered: granted=\(granted, privacy: .public)")
        } catch {
            let nsError = error as NSError
            lastRequestError = nsError.localizedDescription
            Log.notifications.error(
                "Notification authorization request failed: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public) \(nsError.localizedDescription, privacy: .public)"
            )
        }
        update(from: await poster.authorizationStatus())
    }

    private func update(from status: UNAuthorizationStatus) {
        let value: NotificationAuthorization
        switch status {
        case .authorized:
            value = .authorized
        case .provisional:
            value = .provisional
        case .ephemeral:
            value = .ephemeral
        case .denied:
            value = .denied
        case .notDetermined:
            value = lastRequestError.map { .requestFailed($0) } ?? .notDetermined
        @unknown default:
            value = .notDetermined
        }
        update(value)
    }

    private func update(_ value: NotificationAuthorization) {
        guard value != authorization else {
            return
        }
        authorization = value
        onAuthorizationChange?(value)
    }

    /// Fresh status right before posting, so a grant or revocation made in
    /// System Settings takes effect without relaunching.
    private func postingAllowed(_ poster: NotificationPosting) async -> Bool {
        update(from: await poster.authorizationStatus())
        return authorization.canPost
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // MARK: - ClusterEventNotifying

    func notifyJobChanges(_ changes: JobStateChanges, cluster: ClusterProfile) {
        guard let poster, !changes.isEmpty else {
            return
        }
        Task {
            guard await postingAllowed(poster) else {
                Log.notifications.debug("Job events for \(cluster.id.rawValue, privacy: .public) not posted: not authorized")
                return
            }
            for notification in Self.notifications(for: changes, cluster: cluster, timestamp: Self.iso8601.string(from: now())) {
                poster.post(notification)
            }
        }
    }

    func notifyGPUBecameAvailable(
        cluster: ClusterProfile,
        idleCount: Int,
        gpuModel: String?,
        partitions: [String]
    ) async -> Bool {
        guard let poster, await postingAllowed(poster) else {
            return false
        }
        let nodesText = partitions.isEmpty
            ? "GPU nodes"
            : "\(partitions.joined(separator: ", ")) partition nodes"
        let modelText = gpuModel.map { " \($0)" } ?? ""
        let countText = "\(idleCount)\(modelText) GPU\(idleCount == 1 ? "" : "s")"
        poster.post(LocalNotification(
            title: "GPU available on \(cluster.displayName)",
            subtitle: "Idle GPUs detected",
            body: "\(countText) idle across \(nodesText)",
            identifier: "\(cluster.id.rawValue)-gpu-available-\(Self.iso8601.string(from: now()))",
            thread: "\(cluster.id.rawValue)-gpu-availability"
        ))
        return true
    }

    // MARK: - Content

    /// The notifications one set of changes produces. Pure, for tests.
    nonisolated static func notifications(for changes: JobStateChanges, cluster: ClusterProfile, timestamp: String) -> [LocalNotification] {
        let id = cluster.id.rawValue
        let thread = "\(id)-job-events"
        switch changes.delivery {
        case .summary(let gap):
            return [catchUpSummary(changes, cluster: cluster, gap: gap, timestamp: timestamp, thread: thread)]
        case .individual:
            var result = changes.started.map { start in
                LocalNotification(
                    title: "\(cluster.displayName) · job started",
                    subtitle: "Your job started",
                    body: "\(displayName(name: start.name, jobId: start.jobId)) (#\(start.jobId))\nNow running on partition \(start.partition).",
                    identifier: "\(id)-job-started-\(start.jobId)-\(timestamp)",
                    thread: thread
                )
            }
            if changes.ended.count == 1, let ending = changes.ended.first {
                let subtitle = ending.finalState == JobEnding.leftQueue
                    ? "Job finished or left the queue"
                    : "Job ended: \(ending.finalState)"
                result.append(LocalNotification(
                    title: "\(cluster.displayName) · job ended",
                    subtitle: subtitle,
                    body: [
                        "\(displayName(name: ending.name, jobId: ending.jobId)) (#\(ending.jobId))",
                        "Partition \(ending.partition) • previous state \(ending.lastState)",
                        ending.detail
                    ].joined(separator: "\n"),
                    identifier: "\(id)-job-ended-\(ending.jobId)-\(ending.finalState)-\(timestamp)",
                    thread: thread
                ))
            } else if changes.ended.count > 1 {
                result.append(LocalNotification(
                    title: "\(cluster.displayName) · jobs ended",
                    subtitle: "\(changes.ended.count) jobs ended",
                    body: changes.ended.map(endingLine).joined(separator: "\n"),
                    identifier: "\(id)-jobs-ended-summary-\(timestamp)",
                    thread: thread
                ))
            }
            return result
        }
    }

    nonisolated private static func catchUpSummary(
        _ changes: JobStateChanges,
        cluster: ClusterProfile,
        gap: TimeInterval,
        timestamp: String,
        thread: String
    ) -> LocalNotification {
        var counts: [String] = []
        if !changes.ended.isEmpty {
            counts.append("\(changes.ended.count) job\(changes.ended.count == 1 ? "" : "s") ended or left the queue")
        }
        if !changes.started.isEmpty {
            counts.append("\(changes.started.count) started")
        }
        var lines = changes.ended.map(endingLine)
            + changes.started.map { "\(displayName(name: $0.name, jobId: $0.jobId)) (#\($0.jobId)) — started" }
        let limit = 6
        if lines.count > limit {
            let hidden = lines.count - limit
            lines = Array(lines.prefix(limit)) + ["… and \(hidden) more"]
        }
        return LocalNotification(
            title: "\(cluster.displayName) · while you were away",
            subtitle: "Not watched for \(slurmDurationText(seconds: Int(gap))): \(counts.joined(separator: ", "))",
            body: lines.joined(separator: "\n"),
            identifier: "\(cluster.id.rawValue)-jobs-catch-up-\(timestamp)",
            thread: thread
        )
    }

    nonisolated private static func endingLine(_ ending: JobEnding) -> String {
        "\(displayName(name: ending.name, jobId: ending.jobId)) (#\(ending.jobId)) — \(ending.finalState)"
    }

    nonisolated private static func displayName(name: String, jobId: String) -> String {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanName.isEmpty ? "Job \(jobId)" : cleanName
    }
}
