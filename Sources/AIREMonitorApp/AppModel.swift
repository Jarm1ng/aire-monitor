import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var useSSHAlias: Bool = true
    @Published var sshAlias: String = "aire"
    @Published var username: String = ""
    @Published var password: String = ""
    @Published var aireHostname: String = "aire.leeds.ac.uk"
    @Published var jumpHostname: String = "rash.leeds.ac.uk"
    @Published var duoOption: String = "1"
    @Published var projectRoot: String = AppModel.defaultProjectRoot()

    @Published var isLoggingIn = false
    @Published var isRefreshing = false
    @Published var isLoggedIn = false
    @Published var hasCachedSnapshot = false
    @Published var statusMessage = "Not connected"
    @Published var errorMessage: String?
    @Published var snapshot: ClusterSnapshot?
    @Published var history: [TrendPoint] = []

    private let service = MonitorService()
    private let notificationService = JobNotificationService()
    private var backgroundTimer: Timer?
    private let backgroundRefreshInterval: TimeInterval = 10

    init() {
        notificationService.configure()
        let cache = SnapshotCache(projectRoot: projectRoot)
        history = cache.loadHistory()
        if let cachedSnapshot = cache.loadLatestSnapshot() {
            snapshot = cachedSnapshot
            hasCachedSnapshot = true
            statusMessage = "Cached snapshot available • auto-refreshing every 10s"
            history = (try? cache.recordHistory(from: cachedSnapshot)) ?? history
            if cache.loadJobStateSnapshot() == nil {
                try? cache.saveJobStates(from: cachedSnapshot.jobs)
            }
        }
        startBackgroundRefresh()
        refresh(reason: .startupProbe)
    }

    var settings: ServerSettings {
        ServerSettings(
            useSSHAlias: useSSHAlias,
            sshAlias: sshAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "aire" : sshAlias,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            aireHostname: aireHostname.trimmingCharacters(in: .whitespacesAndNewlines),
            jumpHostname: jumpHostname.trimmingCharacters(in: .whitespacesAndNewlines),
            duoOption: duoOption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "1" : duoOption,
            projectRoot: projectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func login() {
        if useSSHAlias {
            guard !sshAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errorMessage = "SSH alias is required."
                return
            }
        } else {
            guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errorMessage = "Username is required in explicit jump-host mode."
                return
            }
        }
        guard !password.isEmpty else {
            errorMessage = "Password is required."
            return
        }
        isLoggingIn = true
        errorMessage = nil
        statusMessage = useSSHAlias
            ? "Logging in with SSH alias \(settings.sshAlias)"
            : "Logging in through \(settings.jumpHostname)"

        Task {
            do {
                let output = try await service.login(settings: settings, password: password)
                isLoggedIn = true
                password = ""
                statusMessage = loginSummary(from: output)
                isLoggingIn = false
                refresh(reason: .login)
            } catch {
                isLoggedIn = false
                isLoggingIn = false
                errorMessage = error.localizedDescription
                statusMessage = "Login failed"
            }
        }
    }

    func refresh() {
        refresh(reason: .manual)
    }

    private func refresh(reason: RefreshReason) {
        guard !isRefreshing else {
            return
        }
        isRefreshing = true
        if reason.showsErrors {
            errorMessage = nil
        }
        if reason == .startupProbe && snapshot != nil {
            statusMessage = "Cached snapshot available • checking SSH session"
        }
        let currentSettings = settings

        Task {
            defer {
                isRefreshing = false
            }
            do {
                let nextSnapshot = try await service.collectSnapshot(settings: currentSettings)
                guard nextSnapshot.errors.isEmpty else {
                    handleRefreshFailure(
                        message: nextSnapshot.errors.joined(separator: "\n"),
                        settings: currentSettings,
                        showsErrors: reason.showsErrors
                    )
                    return
                }

                let cache = SnapshotCache(projectRoot: currentSettings.projectRoot)
                let previousJobState = cache.loadJobStateSnapshot()
                try? cache.saveLatestSnapshot(nextSnapshot)
                history = (try? cache.recordHistory(from: nextSnapshot)) ?? cache.loadHistory()
                notificationService.notifyChanges(previous: previousJobState, current: nextSnapshot.jobs)
                try? cache.saveJobStates(from: nextSnapshot.jobs)

                snapshot = nextSnapshot
                hasCachedSnapshot = true
                isLoggedIn = true
                errorMessage = nil
                statusMessage = "Last refresh \(Date().formatted(date: .omitted, time: .standard)) • cache updated"
                startBackgroundRefresh()
            } catch {
                handleRefreshFailure(
                    message: error.localizedDescription,
                    settings: currentSettings,
                    showsErrors: reason.showsErrors
                )
            }
        }
    }

    private func startBackgroundRefresh() {
        guard backgroundTimer == nil else {
            return
        }
        let timer = Timer(timeInterval: backgroundRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(reason: .automatic)
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        backgroundTimer = timer
    }

    private func handleRefreshFailure(message: String, settings: ServerSettings, showsErrors: Bool) {
        let cache = SnapshotCache(projectRoot: settings.projectRoot)
        if let cachedSnapshot = cache.loadLatestSnapshot() {
            snapshot = cachedSnapshot
            hasCachedSnapshot = true
            statusMessage = "Cached snapshot offline • retrying every 10s"
        } else if snapshot != nil {
            hasCachedSnapshot = true
            statusMessage = "Previous snapshot offline • retrying every 10s"
        } else {
            hasCachedSnapshot = false
            statusMessage = "Offline • retrying every 10s"
        }
        isLoggedIn = false
        errorMessage = showsErrors ? message : nil
    }

    func openDesktopWidget() {
        let widgetApp = "\(settings.projectRoot)/.runtime/AIREDesktopWidget.app"
        let launcher = "\(settings.projectRoot)/scripts/run_desktop_widget.sh"

        if FileManager.default.fileExists(atPath: widgetApp) {
            runDetached(executable: "/usr/bin/open", arguments: [widgetApp])
            statusMessage = "Opening desktop widget"
            return
        }

        guard FileManager.default.fileExists(atPath: launcher) else {
            errorMessage = "Desktop widget launcher is missing: \(launcher)"
            return
        }

        runDetached(executable: "/bin/bash", arguments: [launcher])
        statusMessage = "Building desktop widget"
    }

    private func loginSummary(from output: String) -> String {
        guard let line = output.split(separator: "\n").last else {
            return "Connected"
        }
        return String(line)
    }

    private func runDetached(executable: String, arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: settings.projectRoot)
        try? process.run()
    }

    private static func defaultProjectRoot() -> String {
        if let environmentRoot = ProcessInfo.processInfo.environment["AIRE_PROJECT_ROOT"],
           FileManager.default.fileExists(atPath: "\(environmentRoot)/scripts/aire_monitor_snapshot.py") {
            return environmentRoot
        }

        let current = FileManager.default.currentDirectoryPath
        if FileManager.default.fileExists(atPath: "\(current)/scripts/aire_monitor_snapshot.py") {
            return current
        }

        let bundleRoot = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        if FileManager.default.fileExists(atPath: "\(bundleRoot)/scripts/aire_monitor_snapshot.py") {
            return bundleRoot
        }

        return current
    }
}

private enum RefreshReason {
    case startupProbe
    case login
    case manual
    case automatic

    var showsErrors: Bool {
        self == .login || self == .manual
    }
}
