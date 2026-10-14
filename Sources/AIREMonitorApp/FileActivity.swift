import HPCCore
import AppKit
import Foundation

/// Transfers and long-running remote operations of ONE cluster's file
/// browser: a FIFO transfer queue with a small concurrency limit, progress
/// and cancel, plus detached remote jobs (permanent deletes, confirmed
/// copies into the home trash) followed by polling.
///
/// A separate object from `FileBrowserModel` on purpose: progress ticks
/// several times a second during a transfer, and only the transfer strip
/// and the preview sheet observe this object — the 4,000-row file table
/// does not re-render for every tick.
///
/// Every transfer and job captures the cluster's `ConnectionSettings` when
/// it is queued, so it can only ever run over that cluster's session.
@MainActor
final class FileActivity: ObservableObject {

    // MARK: Types

    struct TransferItem: Identifiable, Equatable {
        enum Direction: Equatable {
            case upload
            case download
        }

        enum Phase: Equatable {
            case waiting
            case running
            case done
            case failed(String)
            case cancelled
        }

        let id: UUID
        let filename: String
        let direction: Direction
        /// Cluster the transfer runs against, for status text.
        let clusterName: String
        /// Download: the remote source file. Upload: the remote folder.
        let remotePath: String
        let batchID: UUID
        var phase: Phase = .waiting
        var cancelRequested = false
        var totalBytes: Int64?
        var transferredBytes: Int64 = 0
        /// Smoothed rate, once two samples exist.
        var bytesPerSecond: Double?
        /// Download destination, once finished.
        var localURL: URL?

        var isActive: Bool { phase == .waiting || phase == .running }

        var fractionCompleted: Double? {
            guard let totalBytes, totalBytes > 0 else {
                return nil
            }
            return min(1, max(0, Double(transferredBytes) / Double(totalBytes)))
        }
    }

    /// A detached remote job the browser is following.
    struct BackgroundOperation: Identifiable, Equatable {
        enum Kind: Equatable {
            case delete
            case quotaCopy
        }

        let id: UUID
        let kind: Kind
        let title: String
        let clusterName: String
        let job: RemoteJob
        var done = 0
        var total: Int
        var current: String?
        var cancelRequested = false
        /// Consecutive polls that failed (no answer from the login node).
        var unansweredPolls = 0
    }

    /// How a followed job ended, as far as the app could tell.
    enum OperationResult: Equatable {
        case finished(RemoteJobStatus)
        /// The worker stopped without finishing; detail from its stderr.
        case crashed(String)
        /// The app lost track (session ended, repeated poll failures). The
        /// job may well still be running on the login node.
        case lost(String)
    }

    private enum TransferWork {
        case download(remotePath: String, directory: URL)
        case upload(localURL: URL, remoteDirectory: String)
    }

    private struct TransferContext {
        let settings: ConnectionSettings
        let work: TransferWork
        let scratch = TransferScratch()
    }

    private struct Batch {
        var remaining: Int
        var finishedURLs: [URL] = []
    }

    // MARK: State

    @Published private(set) var transfers: [TransferItem] = []
    @Published private(set) var operations: [BackgroundOperation] = []

    /// Concurrent scp sessions per cluster. Each one is a session on the
    /// cluster's single ControlMaster — shared with the collector, terminals
    /// and the file browser itself, under the server's MaxSessions limit
    /// (OpenSSH default 10; `TerminalManager.reservedAppSessions` budgets
    /// these two) — and parallel streams through rash gain nothing anyway.
    static let maxConcurrentTransfers = 2

    private let service: RemoteFileService
    private var contexts: [UUID: TransferContext] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var batches: [UUID: Batch] = [:]
    private var rateSamples: [UUID: (time: Date, bytes: Int64)] = [:]
    private var operationTasks: [UUID: Task<Void, Never>] = [:]
    private var operationSettings: [UUID: ConnectionSettings] = [:]
    private var terminationObserver: ObserverToken?

    /// Called with the remote folder after an upload lands there.
    var onUploadFinished: ((String) -> Void)?
    /// Where downloads land: the user's Downloads folder (replaceable for
    /// tests, which must never write there).
    var downloadsDirectory: URL = FileManager.default
        .urls(for: .downloadsDirectory, in: .userDomainMask)
        .first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    /// Reveals finished downloads (once per batch). Replaceable for tests.
    var revealDownloads: ([URL]) -> Void = { urls in
        guard NSApplication.shared.isActive else {
            // Never yank the user out of another app when a long download
            // finishes in the background; the chip offers Show in Finder.
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private static let doneDownloadLinger: UInt64 = 10_000_000_000
    private static let doneUploadLinger: UInt64 = 4_000_000_000
    private static let cancelledLinger: UInt64 = 3_000_000_000

    init(service: RemoteFileService) {
        self.service = service
        terminationObserver = ObserverToken(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelEverythingForTermination()
            }
        })
    }

    // MARK: Queue

    var hasActiveTransfers: Bool { transfers.contains(where: \.isActive) }

    func isDownloading(remotePath: String) -> Bool {
        transfers.contains { $0.direction == .download && $0.remotePath == remotePath && $0.isActive }
    }

    /// Queues downloads into ~/Downloads. Returns the names skipped because
    /// the same file is already waiting or downloading.
    @discardableResult
    func enqueueDownloads(
        _ entries: [RemoteFileEntry],
        settings: ConnectionSettings,
        clusterName: String
    ) -> [String] {
        let directory = downloadsDirectory
        var skipped: [String] = []
        var accepted: [(RemoteFileEntry, UUID)] = []
        for entry in entries {
            if isDownloading(remotePath: entry.path) || accepted.contains(where: { $0.0.path == entry.path }) {
                skipped.append(entry.name)
                continue
            }
            accepted.append((entry, UUID()))
        }
        guard !accepted.isEmpty else {
            return skipped
        }
        let batchID = UUID()
        batches[batchID] = Batch(remaining: accepted.count)
        for (entry, id) in accepted {
            contexts[id] = TransferContext(settings: settings, work: .download(remotePath: entry.path, directory: directory))
            transfers.append(TransferItem(
                id: id,
                filename: entry.name,
                direction: .download,
                clusterName: clusterName,
                remotePath: entry.path,
                batchID: batchID,
                totalBytes: entry.kind == .file ? entry.size : nil
            ))
        }
        pump()
        return skipped
    }

    /// Queues uploads into `remoteDirectory`. Returns the names skipped
    /// because a file of that name is already being uploaded there.
    @discardableResult
    func enqueueUploads(
        _ urls: [URL],
        remoteDirectory: String,
        settings: ConnectionSettings,
        clusterName: String
    ) -> [String] {
        var skipped: [String] = []
        var accepted: [(URL, UUID)] = []
        for url in urls where url.isFileURL {
            let name = url.lastPathComponent
            let busy = transfers.contains {
                $0.direction == .upload && $0.isActive && $0.remotePath == remoteDirectory && $0.filename == name
            }
            if busy || accepted.contains(where: { $0.0.lastPathComponent == name }) {
                skipped.append(name)
                continue
            }
            accepted.append((url, UUID()))
        }
        guard !accepted.isEmpty else {
            return skipped
        }
        let batchID = UUID()
        batches[batchID] = Batch(remaining: accepted.count)
        for (url, id) in accepted {
            contexts[id] = TransferContext(settings: settings, work: .upload(localURL: url, remoteDirectory: remoteDirectory))
            transfers.append(TransferItem(
                id: id,
                filename: url.lastPathComponent,
                direction: .upload,
                clusterName: clusterName,
                remotePath: remoteDirectory,
                batchID: batchID,
                totalBytes: RemoteFileService.localFileSize(url)
            ))
        }
        pump()
        return skipped
    }

    /// A waiting transfer simply leaves the queue; a running one is
    /// stopped (scp gets SIGTERM through task cancellation) and its partial
    /// file is removed by the service.
    func cancelTransfer(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else {
            return
        }
        switch transfers[index].phase {
        case .waiting:
            transfers[index].phase = .cancelled
            contexts[id] = nil
            completeBatchMember(transfers[index].batchID, url: nil)
            scheduleRemoval(id, after: Self.cancelledLinger)
        case .running:
            transfers[index].cancelRequested = true
            tasks[id]?.cancel()
        default:
            break
        }
    }

    func dismissTransfer(_ id: UUID) {
        guard let item = transfers.first(where: { $0.id == id }), !item.isActive else {
            return
        }
        transfers.removeAll { $0.id == id }
    }

    func revealInFinder(_ id: UUID) {
        guard let url = transfers.first(where: { $0.id == id })?.localURL else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func pump() {
        while transfers.filter({ $0.phase == .running }).count < Self.maxConcurrentTransfers,
              let next = transfers.firstIndex(where: { $0.phase == .waiting }) {
            let id = transfers[next].id
            guard let context = contexts[id] else {
                transfers[next].phase = .failed("Internal error: the transfer lost its settings.")
                continue
            }
            transfers[next].phase = .running
            tasks[id] = Task { [weak self] in
                await self?.run(id, context: context)
            }
        }
    }

    private func run(_ id: UUID, context: TransferContext) async {
        let service = self.service
        let progress: TransferProgressHandler = { [weak self] update in
            Task { @MainActor in
                self?.record(update, for: id)
            }
        }
        do {
            switch context.work {
            case .download(let remotePath, let directory):
                let url = try await service.download(
                    settings: context.settings,
                    remotePath: remotePath,
                    toLocalDirectory: directory,
                    scratch: context.scratch,
                    progress: progress
                )
                finish(id, phase: .done, url: url)
            case .upload(let localURL, let remoteDirectory):
                let accessing = localURL.startAccessingSecurityScopedResource()
                defer {
                    if accessing {
                        localURL.stopAccessingSecurityScopedResource()
                    }
                }
                try await service.upload(
                    settings: context.settings,
                    localFile: localURL,
                    toRemoteDirectory: remoteDirectory,
                    scratch: context.scratch,
                    progress: progress
                )
                finish(id, phase: .done, url: nil)
                onUploadFinished?(remoteDirectory)
            }
        } catch is CancellationError {
            finish(id, phase: .cancelled, url: nil)
        } catch {
            finish(id, phase: Task.isCancelled ? .cancelled : .failed(error.localizedDescription), url: nil)
        }
    }

    private func record(_ update: TransferProgress, for id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }), transfers[index].phase == .running else {
            return
        }
        let now = Date()
        if let previous = rateSamples[id] {
            let elapsed = now.timeIntervalSince(previous.time)
            if elapsed >= 0.5, update.transferredBytes >= previous.bytes {
                let instant = Double(update.transferredBytes - previous.bytes) / elapsed
                let smoothed = transfers[index].bytesPerSecond.map { $0 * 0.6 + instant * 0.4 } ?? instant
                transfers[index].bytesPerSecond = smoothed
                rateSamples[id] = (now, update.transferredBytes)
            }
        } else {
            rateSamples[id] = (now, update.transferredBytes)
        }
        transfers[index].transferredBytes = update.transferredBytes
        if let total = update.totalBytes {
            transfers[index].totalBytes = total
        }
    }

    private func finish(_ id: UUID, phase: TransferItem.Phase, url: URL?) {
        tasks[id] = nil
        contexts[id] = nil
        rateSamples[id] = nil
        guard let index = transfers.firstIndex(where: { $0.id == id }) else {
            pump()
            return
        }
        transfers[index].phase = phase
        transfers[index].localURL = url
        transfers[index].bytesPerSecond = nil
        let item = transfers[index]
        completeBatchMember(item.batchID, url: url)
        switch phase {
        case .done:
            scheduleRemoval(id, after: item.direction == .download ? Self.doneDownloadLinger : Self.doneUploadLinger)
        case .cancelled:
            scheduleRemoval(id, after: Self.cancelledLinger)
        default:
            // Failures stay until dismissed, so their message is never lost.
            break
        }
        pump()
    }

    /// Reveals a batch's downloads together when its last member ends, so a
    /// 20-file download brings Finder forward once, not 20 times.
    private func completeBatchMember(_ batchID: UUID, url: URL?) {
        guard var batch = batches[batchID] else {
            return
        }
        batch.remaining -= 1
        if let url {
            batch.finishedURLs.append(url)
        }
        if batch.remaining <= 0 {
            batches[batchID] = nil
            if !batch.finishedURLs.isEmpty {
                revealDownloads(batch.finishedURLs)
            }
        } else {
            batches[batchID] = batch
        }
    }

    private func scheduleRemoval(_ id: UUID, after delay: UInt64) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            self?.transfers.removeAll { $0.id == id && !$0.isActive && !Self.isFailure($0.phase) }
        }
    }

    private static func isFailure(_ phase: TransferItem.Phase) -> Bool {
        if case .failed = phase {
            return true
        }
        return false
    }

    /// Quit: stop every scp now (task cancellation signals it
    /// synchronously) and remove partial files without waiting — the async
    /// cleanup inside each transfer never runs once the app is exiting.
    /// Foundation does not kill child processes when the app exits, so
    /// without this a mistaken 30 GB transfer would carry on after quit.
    /// Detached remote jobs are left running on purpose: they are designed
    /// to finish on the login node without the app.
    func cancelEverythingForTermination() {
        for (id, task) in tasks {
            task.cancel()
            contexts[id]?.scratch.cleanUpForTermination()
        }
        for (id, context) in contexts where tasks[id] == nil {
            context.scratch.cleanUpForTermination()
        }
    }

    // MARK: Background operations

    /// Follows a detached job: first poll quickly (small deletes finish in
    /// a second), then every few seconds. `completion` runs once.
    @discardableResult
    func track(
        _ job: RemoteJob,
        kind: BackgroundOperation.Kind,
        title: String,
        settings: ConnectionSettings,
        clusterName: String,
        completion: @escaping @MainActor (OperationResult) -> Void
    ) -> UUID {
        let id = UUID()
        operations.append(BackgroundOperation(
            id: id,
            kind: kind,
            title: title,
            clusterName: clusterName,
            job: job,
            total: job.paths.count
        ))
        operationSettings[id] = settings
        let service = self.service
        operationTasks[id] = Task { [weak self] in
            var delay: UInt64 = 800_000_000
            var failures = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: delay)
                delay = min(delay + 1_000_000_000, 5_000_000_000)
                do {
                    let status = try await service.pollJob(settings: settings, job: job)
                    failures = 0
                    guard let self else {
                        return
                    }
                    switch status.state {
                    case .running:
                        self.updateOperation(id, status: status)
                    case .finished:
                        self.endOperation(id, result: .finished(status), completion: completion)
                        return
                    case .crashed:
                        let detail = status.detail.isEmpty ? "the background process stopped unexpectedly" : status.detail
                        self.endOperation(id, result: .crashed(detail), completion: completion)
                        return
                    case .missing:
                        self.endOperation(id, result: .lost("its progress record is gone"), completion: completion)
                        return
                    }
                } catch {
                    failures += 1
                    self?.noteUnansweredPoll(id, count: failures)
                    if failures >= 4 {
                        self?.endOperation(id, result: .lost(error.localizedDescription), completion: completion)
                        return
                    }
                }
            }
        }
        return id
    }

    func cancelOperation(_ id: UUID) {
        guard let index = operations.firstIndex(where: { $0.id == id }),
              !operations[index].cancelRequested,
              let settings = operationSettings[id] else {
            return
        }
        operations[index].cancelRequested = true
        let job = operations[index].job
        let service = self.service
        Task {
            try? await service.cancelJob(settings: settings, job: job)
        }
    }

    private func updateOperation(_ id: UUID, status: RemoteJobStatus) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else {
            return
        }
        operations[index].done = status.done
        operations[index].total = max(status.total, 1)
        operations[index].current = status.current
        operations[index].unansweredPolls = 0
    }

    private func noteUnansweredPoll(_ id: UUID, count: Int) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else {
            return
        }
        operations[index].unansweredPolls = count
    }

    private func endOperation(
        _ id: UUID,
        result: OperationResult,
        completion: @MainActor (OperationResult) -> Void
    ) {
        operations.removeAll { $0.id == id }
        operationTasks[id] = nil
        operationSettings[id] = nil
        completion(result)
    }
}

/// Unregisters a block-based notification observer when released, so the
/// owner needs no (nonisolated) deinit of its own.
private final class ObserverToken: @unchecked Sendable {
    private let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
