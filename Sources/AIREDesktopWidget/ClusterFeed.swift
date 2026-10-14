import Foundation
import HPCCore
import SwiftUI

enum WidgetDataStatus: Equatable {
    case connecting
    case live
    case cached
    case offline
    /// Paused in the app: the widget shows the last data and never collects.
    case paused
    /// Monitoring switched off in the app.
    case off

    var title: String {
        switch self {
        case .connecting: return "connecting"
        case .live: return "live"
        case .cached: return "cached"
        case .offline: return "offline"
        case .paused: return "paused"
        case .off: return "off"
        }
    }

    var color: Color {
        switch self {
        case .connecting, .paused, .off: return WidgetPalette.neutral
        case .live: return WidgetPalette.green
        case .cached: return WidgetPalette.orange
        case .offline: return WidgetPalette.red
        }
    }

    /// Paused and off are the user's choice in the app, not a problem.
    var isUserChoice: Bool {
        self == .paused || self == .off
    }
}

/// What a manual Refresh did for one cluster, shown briefly in the footer.
struct RefreshReply: Equatable {
    let clusterName: String
    /// Set when the reply is "the app refreshes this cluster every N s", so
    /// the footer can name several clusters in one sentence.
    let appInterval: TimeInterval?
    let text: String

    /// Replies in order, with the "the app refreshes it" ones merged per
    /// cadence: "Leeds HPC Monitor refreshes AIRE and Calder every 10 s."
    static func summary(_ replies: [RefreshReply]) -> String {
        var sentences: [String] = []
        var merged: [TimeInterval: [String]] = [:]
        var mergedOrder: [TimeInterval] = []
        for reply in replies {
            guard let interval = reply.appInterval else {
                sentences.append(reply.text)
                continue
            }
            if merged[interval] == nil {
                mergedOrder.append(interval)
            }
            merged[interval, default: []].append(reply.clusterName)
        }
        let appSentences = mergedOrder.map { interval in
            let names = merged[interval] ?? []
            let list = names.count > 1
                ? names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
                : names.joined()
            return "Leeds HPC Monitor refreshes \(list) every \(Int(interval.rounded())) s."
        }
        return (appSentences + sentences).joined(separator: " ")
    }
}

/// Fallback-collection bookkeeping, keyed by cluster id instead of stored on
/// a ClusterFeed. A feed is dropped and recreated when its cluster is
/// disabled and re-enabled in the app, or its directory briefly disappears;
/// the replacement must still see a collection the old feed started (its
/// process keeps running until it finishes or the watchdog kills it), that
/// collection's place in the cadence and any failure backoff, otherwise one
/// cluster could end up with two collectors racing through the same
/// ControlMaster, or a dead master retried at full rate.
@MainActor
enum CollectionLedger {
    /// Clusters with a collector process running right now.
    static var inFlight: Set<String> = []
    /// When each cluster's last collection (or rejected attempt) started.
    static var lastAttempt: [String: Date] = [:]
    static var consecutiveFailures: [String: Int] = [:]
    /// Failure backoff: no automatic attempt before this date.
    static var nextAllowed: [String: Date] = [:]

    static func recordAttempt(_ id: String, at date: Date) {
        lastAttempt[id] = date
    }

    static func recordSuccess(_ id: String) {
        consecutiveFailures[id] = nil
        nextAllowed[id] = nil
    }

    /// Returns the delay before the next automatic attempt.
    @discardableResult
    static func recordFailure(_ id: String, at now: Date) -> TimeInterval {
        let failures = (consecutiveFailures[id] ?? 0) + 1
        consecutiveFailures[id] = failures
        let delay = WidgetFeedPolicy.retryDelay(afterConsecutiveFailures: failures)
        nextAllowed[id] = now.addingTimeInterval(delay)
        return delay
    }

    /// Someone else is feeding the cluster again: forget our failures.
    static func clearBackoff(_ id: String) {
        recordSuccess(id)
    }
}

/// One cluster's data path. It follows `.runtime/clusters/<id>/latest_snapshot.json`
/// as written by the app, reads the app's `app_state.json` lease to learn
/// whether the app is running and owns this cluster's collection (and
/// whether it is paused or off there), and only when the app does not own
/// it and the file is missing or stale runs the collector itself, with
/// backoff. Everything is per cluster, so a stale Calder file never
/// triggers an AIRE collection and the reverse.
@MainActor
final class ClusterFeed: ObservableObject, Identifiable {
    /// How long a reply to a manual Refresh stays in the footer.
    private static let transientMessageDuration: TimeInterval = 6
    /// The app and the widget decode with the same HPCCore schema, so this
    /// means a truncated file or a widget older than the app.
    private static let unreadableFileMessage = "Cannot read the snapshot Leeds HPC Monitor wrote (format mismatch); rebuild the widget with scripts/run_desktop_widget.sh."

    /// Directory name, e.g. "aire" or "calder".
    let id: String
    let directory: String
    private let projectRoot: String

    @Published private(set) var snapshot: ClusterSnapshot?
    /// When the displayed snapshot was collected on the cluster.
    @Published private(set) var snapshotDate: Date?
    @Published private(set) var status: WidgetDataStatus = .connecting
    @Published private(set) var errorMessage: String?
    /// Informational: why no fresh data is coming (paused or off in the app,
    /// the app is reconnecting, a sign-in is needed, nothing to run).
    @Published private(set) var notice: String?
    /// A short-lived reply to a manual Refresh ("Next refresh in 6 s").
    @Published private(set) var refreshReply: RefreshReply?
    @Published private(set) var isRefreshing = false
    @Published private(set) var ownership: WidgetAppOwnership = .none

    private var transientExpiry: Date?
    private var watcher: DirectoryWatcher?
    private var isActive = true
    private var appState: WidgetAppStateReader
    /// Modification date of the snapshot file at the last check.
    private var currentFileModificationDate: Date?
    private var loadedModificationDate: Date?
    /// A write that could not be decoded; not retried until it changes (or
    /// a manual Refresh asks).
    private var failedModificationDate: Date?
    /// True when the displayed snapshot came from this widget's own fallback
    /// collection (rather than the main app writing the snapshot file).
    private var lastDataFromFallback = false
    /// Modification date of the snapshot file as last written by this
    /// widget's own fallback collection; reloading that same write must not
    /// be mistaken for the main app feeding the file.
    private var ownWriteModificationDate: Date?
    /// The missing socket last logged, so the 2 s poll logs it once.
    private var loggedMissingSocket: String?

    init(id: String, directory: String, projectRoot: String) {
        self.id = id
        self.directory = directory
        self.projectRoot = projectRoot
        appState = WidgetAppStateReader(path: "\(directory)/app_state.json")
    }

    /// Catalogue identity (name, monogram, accent) for known clusters. For
    /// any other cluster the collector's echoed name is used once a snapshot
    /// for this cluster arrives, else a name derived from the directory.
    var identity: ClusterIdentity {
        var echoedName: String?
        if let info = snapshot?.cluster, info.id == id {
            let name = info.name.trimmingCharacters(in: .whitespacesAndNewlines)
            echoedName = name.isEmpty ? nil : String(name.prefix(24))
        }
        return ClusterIdentity.resolve(ClusterID(id), name: echoedName)
    }

    var displayName: String {
        identity.displayName
    }

    /// Login node that produced the snapshot, shown in the status chip.
    var remoteName: String? {
        guard let remote = snapshot?.remote else {
            return nil
        }
        let name = remote.hostname.isEmpty ? remote.host : remote.hostname
        return name.isEmpty ? nil : name
    }

    /// When the widget's own collector may next run automatically, while it
    /// is backing off after failures.
    var nextAutomaticAttempt: Date? {
        guard !ownership.appOwnsCollection, let next = CollectionLedger.nextAllowed[id], next > Date() else {
            return nil
        }
        return next
    }

    /// How often this cluster's data is refreshed right now: the app's
    /// cadence (including its backoff) when the app owns it, the widget's own
    /// cadence (including backoff) otherwise, nil while paused or off.
    var refreshCadence: TimeInterval? {
        switch ownership {
        case .live(let interval), .retrying(let interval):
            return interval
        case .paused, .off:
            return nil
        case .none:
            return WidgetFeedPolicy.retryDelay(afterConsecutiveFailures: CollectionLedger.consecutiveFailures[id] ?? 0)
        }
    }

    private var snapshotPath: String {
        "\(directory)/latest_snapshot.json"
    }

    func stop() {
        isActive = false
        watcher?.cancel()
        watcher = nil
    }

    func installWatcherIfNeeded() {
        guard isActive, watcher == nil else {
            return
        }
        watcher = DirectoryWatcher(path: directory) { [weak self] flags in
            self?.handleDirectoryEvent(flags: flags)
        }
    }

    private func handleDirectoryEvent(flags: DispatchSource.FileSystemEvent) {
        if DirectoryWatcher.invalidatesWatcher(flags) {
            watcher?.cancel()
            watcher = nil
        }
        sync()
    }

    // MARK: Sync

    /// One pass over this cluster: re-read the snapshot file and the app's
    /// lease when they changed, then let WidgetFeedPolicy decide whether the
    /// fallback collector runs. `manual` is a Refresh the user asked for; it
    /// always gets a visible reply, even when nothing can be collected.
    func sync(manual: Bool = false) {
        guard isActive else {
            return
        }
        let now = Date()
        expireTransientMessage(now: now)
        reloadIfChanged(retryFailed: manual)
        updateOwnership(now: now)

        let facts = WidgetFeedFacts(
            ownership: ownership,
            snapshotAge: snapshotAge(now: now),
            feedingItself: lastDataFromFallback,
            unreadableForeignFile: hasUnreadableForeignFile,
            manual: manual,
            lastAttempt: CollectionLedger.lastAttempt[id],
            nextAllowed: CollectionLedger.nextAllowed[id]
        )
        switch WidgetFeedPolicy.decide(facts, now: now) {
        case .deferToApp:
            // Whatever the widget's own collector reported no longer applies;
            // a file the app wrote that this build cannot read still does,
            // or the row would sit on old data without saying why.
            setError(hasUnreadableForeignFile ? Self.unreadableFileMessage : nil)
            setNotice(ownershipNotice)
            if manual {
                flash(appOwnedRefreshReply, appInterval: ownership.appRefreshInterval)
            }
        case .blockedByUnreadableFile:
            setNotice(nil)
            setError(Self.unreadableFileMessage)
        case .notNeeded:
            setNotice(nil)
            if manual, let snapshotDate {
                flash("\(displayName) is up to date (data from \(snapshotDate.formatted(date: .omitted, time: .standard))).")
            }
        case .wait(let until):
            if manual {
                let seconds = max(Int(until.timeIntervalSince(now).rounded(.up)), 1)
                let running = CollectionLedger.inFlight.contains(id)
                flash(running ? "\(displayName) is refreshing now." : "Next \(displayName) refresh in \(seconds) s.")
            }
        case .collect:
            collect(manual: manual, now: now)
        }
        recomputeStatus(now: now)
    }

    private func snapshotAge(now: Date) -> TimeInterval? {
        guard snapshot != nil, let snapshotDate else {
            return nil
        }
        return now.timeIntervalSince(snapshotDate)
    }

    /// The file on disk failed to decode and is not the widget's own write
    /// (the widget only ever writes output that decoded).
    private var hasUnreadableForeignFile: Bool {
        guard let failed = failedModificationDate else {
            return false
        }
        return failed == currentFileModificationDate && failed != ownWriteModificationDate
    }

    private func updateOwnership(now: Date) {
        appState.reloadIfChanged()
        let next = appState.ownership(now: now)
        guard next != ownership else {
            return
        }
        WidgetLog.feed.info("\(self.id, privacy: .public): app ownership \(String(describing: self.ownership), privacy: .public) -> \(String(describing: next), privacy: .public)")
        ownership = next
        // The notice described the old situation; the caller's decision
        // sets the one that fits the new one.
        setNotice(nil)
    }

    private var ownershipNotice: String? {
        switch ownership {
        case .none, .live:
            return nil
        case .retrying:
            return "\(displayName) is not connected in Leeds HPC Monitor; data resumes when the app reconnects."
        case .paused:
            return "\(displayName) is paused in Leeds HPC Monitor."
        case .off:
            return "\(displayName) monitoring is off in Leeds HPC Monitor."
        }
    }

    private var appOwnedRefreshReply: String {
        switch ownership {
        case .live(let interval), .retrying(let interval):
            return "Leeds HPC Monitor refreshes \(displayName) every \(Int(interval.rounded())) s."
        case .paused:
            return "\(displayName) is paused; resume it in Leeds HPC Monitor to refresh."
        case .off:
            return "\(displayName) is switched off in Leeds HPC Monitor."
        case .none:
            return "Refreshing \(displayName)."
        }
    }

    // MARK: Snapshot file

    /// Reloads only a write that changed since the last load: a reload of
    /// the same write would change nothing. A write that failed to decode is
    /// retried only when it changes or `retryFailed` (a manual Refresh).
    private func reloadIfChanged(retryFailed: Bool) {
        let modificationDate = fileModificationDate(atPath: snapshotPath)
        currentFileModificationDate = modificationDate
        guard let modificationDate, modificationDate != loadedModificationDate else {
            return
        }
        if modificationDate == failedModificationDate && !retryFailed {
            return
        }
        loadSnapshotFile(modificationDate: modificationDate)
    }

    private func loadSnapshotFile(modificationDate: Date) {
        guard let data = FileManager.default.contents(atPath: snapshotPath),
              let decoded = try? JSONDecoder().decode(ClusterSnapshot.self, from: data) else {
            if failedModificationDate != modificationDate {
                WidgetLog.feed.error("\(self.id, privacy: .public): cannot decode \(self.snapshotPath, privacy: .private)")
            }
            failedModificationDate = modificationDate
            return
        }
        failedModificationDate = nil
        loadedModificationDate = modificationDate
        if modificationDate != ownWriteModificationDate {
            // Only a write by someone else (the main app) means we are no
            // longer feeding ourselves; a reload of our own write must keep
            // the self-feed cadence intact.
            lastDataFromFallback = false
            // Written after our last attempt began: the app is feeding this
            // cluster again, so our failures and their backoff are moot, and
            // so is any error our collector reported.
            if let lastAttempt = CollectionLedger.lastAttempt[id], modificationDate > lastAttempt {
                CollectionLedger.clearBackoff(id)
                setError(nil)
            }
        }
        snapshot = decoded
        snapshotDate = SlurmTimestamp.parse(decoded.collectedAt) ?? modificationDate
    }

    private func recomputeStatus(now: Date) {
        let next: WidgetDataStatus
        switch ownership {
        case .paused:
            next = .paused
        case .off:
            next = .off
        case .none, .live, .retrying:
            if snapshot == nil {
                next = (errorMessage == nil && notice == nil) ? .connecting : .offline
            } else if let age = snapshotAge(now: now), age <= HPCDefaults.snapshotStaleAfter {
                next = .live
            } else {
                next = .cached
            }
        }
        // Guarded: this runs on every 2 s poll and an unconditional
        // assignment would repaint the whole widget each time.
        if status != next {
            status = next
        }
    }

    private func setNotice(_ value: String?) {
        if notice != value {
            notice = value
        }
    }

    private func setError(_ value: String?) {
        if errorMessage != value {
            errorMessage = value
        }
    }

    private func flash(_ message: String, appInterval: TimeInterval? = nil) {
        refreshReply = RefreshReply(clusterName: displayName, appInterval: appInterval, text: message)
        transientExpiry = Date().addingTimeInterval(Self.transientMessageDuration)
    }

    private func expireTransientMessage(now: Date) {
        if let expiry = transientExpiry, now >= expiry {
            transientExpiry = nil
            refreshReply = nil
        }
    }

    // MARK: Fallback collection

    private var signInNotice: String {
        "Sign in to \(displayName) in Leeds HPC Monitor to refresh."
    }

    /// Runs the collector once WidgetFeedPolicy said it is due: never two at
    /// once for one cluster (kept in CollectionLedger, so it survives the
    /// feed being replaced mid-collection), never without a valid
    /// `collector.json`, and never when the ControlMaster socket is missing.
    private func collect(manual: Bool, now: Date) {
        guard !isRefreshing, !CollectionLedger.inFlight.contains(id) else {
            if manual {
                flash("\(displayName) is refreshing now.")
            }
            return
        }

        let collector: WidgetValidatedCollector
        switch WidgetCollector.load(clusterID: id, directory: directory, projectRoot: projectRoot) {
        case .missing:
            // The app has never connected to this cluster (or has not since
            // the upgrade), so there is no password-free invocation to reuse.
            setNotice(
                snapshot == nil
                    ? "Connect to \(displayName) in Leeds HPC Monitor to start monitoring it."
                    : "Leeds HPC Monitor is not updating \(displayName); reconnect it in the app."
            )
            return
        case .invalid(let message):
            // Counted as a failed attempt, so a broken record is re-validated
            // (and re-reported) on the backoff schedule, not every poll.
            CollectionLedger.recordAttempt(id, at: now)
            let delay = CollectionLedger.recordFailure(id, at: now)
            if errorMessage != message {
                WidgetLog.feed.error("\(self.id, privacy: .public): invalid collector record; next check in \(Int(delay)) s: \(message, privacy: .private)")
            }
            setNotice(nil)
            setError(message)
            return
        case .ready(let validated):
            collector = validated
        }

        if let socket = WidgetCollector.missingControlSocket(for: collector) {
            // No master: python would only confirm that. This costs a stat
            // per poll, so the row recovers as soon as the master is back.
            if loggedMissingSocket != socket {
                loggedMissingSocket = socket
                WidgetLog.feed.info("\(self.id, privacy: .public): control socket \(socket, privacy: .private) is missing; not collecting")
            }
            setError(nil)
            setNotice(signInNotice)
            return
        }
        loggedMissingSocket = nil

        setNotice(nil)
        let clusterID = id
        let fileDateAtStart = fileModificationDate(atPath: snapshotPath)
        CollectionLedger.recordAttempt(clusterID, at: now)
        CollectionLedger.inFlight.insert(clusterID)
        isRefreshing = true
        WidgetLog.feed.info("\(clusterID, privacy: .public): fallback collection started (\(manual ? "manual" : "automatic", privacy: .public))")
        Task {
            defer {
                isRefreshing = false
                CollectionLedger.inFlight.remove(clusterID)
            }
            do {
                let result = try await WidgetCollector.collect(projectRoot: projectRoot, collector: collector)
                apply(result, startedAt: now, fileDateAtStart: fileDateAtStart)
            } catch {
                recordFailure(error.localizedDescription, missingMaster: false, startedAt: now)
            }
            recomputeStatus(now: Date())
        }
    }

    private func apply(_ result: WidgetCollectionResult, startedAt: Date, fileDateAtStart: Date?) {
        guard isActive else {
            // The cluster was disabled or its directory removed while the
            // collector ran; do not resurrect its snapshot file.
            return
        }
        let now = Date()
        updateOwnership(now: now)
        if ownership.appOwnsCollection {
            // The app started or resumed while the collector ran; its own
            // refresh supersedes ours, and writing could race it.
            WidgetLog.feed.info("\(self.id, privacy: .public): the app took over during the fallback collection; result dropped")
            return
        }
        // Pick up anything the main app wrote while the collector ran.
        reloadIfChanged(retryFailed: false)

        guard result.isClean, let collected = result.snapshot else {
            recordFailure(result.failureMessage ?? "Refresh failed.", missingMaster: result.isMissingMaster, startedAt: startedAt)
            return
        }
        if let info = collected.cluster, info.id != id {
            recordFailure(
                "The collector answered for cluster '\(info.id)', not '\(id)'; check \(directory)/collector.json.",
                missingMaster: false,
                startedAt: startedAt
            )
            return
        }
        CollectionLedger.recordSuccess(id)
        setError(nil)
        loggedMissingSocket = nil

        if fileModificationDate(atPath: snapshotPath) != fileDateAtStart {
            // Someone else (the app) wrote the file while the collector ran.
            // Never overwrite another writer's file: its data, when
            // decodable, was loaded just above.
            WidgetLog.feed.info("\(self.id, privacy: .public): snapshot file changed during the fallback collection; not overwriting it")
            return
        }
        let collectedDate = SlurmTimestamp.parse(collected.collectedAt)
        if let existing = snapshotDate, let collectedDate, collectedDate <= existing {
            return
        }

        do {
            // Atomic replace: the app (and the directory watchers) only ever
            // see a complete file.
            try result.output.write(to: URL(fileURLWithPath: snapshotPath), options: .atomic)
            // Remember our own write so the watcher does not redundantly
            // reload it and so it is never mistaken for the app feeding.
            loadedModificationDate = fileModificationDate(atPath: snapshotPath)
            ownWriteModificationDate = loadedModificationDate
            currentFileModificationDate = loadedModificationDate
            failedModificationDate = nil
        } catch {
            WidgetLog.feed.error("\(self.id, privacy: .public): cannot save the collected snapshot: \(error.localizedDescription, privacy: .public)")
            setError("Collected a snapshot but could not save it: \(error.localizedDescription)")
        }
        snapshot = collected
        snapshotDate = collectedDate ?? now
        lastDataFromFallback = true
        WidgetLog.feed.info("\(self.id, privacy: .public): fallback collection succeeded in \(String(format: "%.1f", now.timeIntervalSince(startedAt)), privacy: .public) s")
    }

    private func recordFailure(_ message: String, missingMaster: Bool, startedAt: Date) {
        let now = Date()
        let delay = CollectionLedger.recordFailure(id, at: now)
        let failures = CollectionLedger.consecutiveFailures[id] ?? 1
        WidgetLog.feed.error("\(self.id, privacy: .public): fallback collection failed after \(String(format: "%.1f", now.timeIntervalSince(startedAt)), privacy: .public) s (\(failures) in a row; next attempt in \(Int(delay)) s): \(message, privacy: .private)")
        if missingMaster {
            // Only a sign-in in the app can fix this; say so instead of
            // showing the collector's raw error.
            setError(nil)
            setNotice(signInNotice)
        } else {
            setError(message)
        }
    }
}
