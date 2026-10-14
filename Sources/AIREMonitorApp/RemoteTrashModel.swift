import HPCCore
import Foundation

/// State of one cluster's Trash sheet: every trash run the app can find —
/// the shared home trash, plus the run folders beside scratch and flash
/// items that the home trash's index records for this cluster — with sizes
/// on demand, Restore and Empty.
///
/// Trashed scratch data stays on scratch and keeps counting against its
/// quota until emptied; this sheet is where a user finds and frees it.
/// Emptying goes through the browser's permanent-delete path (validated,
/// re-checked on the login node, detached, with progress and Cancel).
@MainActor
final class RemoteTrashModel: ObservableObject {
    @Published private(set) var runs: [TrashRun] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var sizes: [String: Int64] = [:]
    @Published private(set) var isMeasuring = false
    /// Run folders with a restore or empty in flight.
    @Published private(set) var busyDirectories = Set<String>()
    @Published private(set) var message: String?
    @Published private(set) var messageIsError = false

    weak var browser: FileBrowserModel?
    private let service: RemoteFileService
    /// Bumped by every load and reset: a reply for an older generation
    /// describes a list that is no longer on screen and is dropped.
    private var generation = 0
    /// Bumped by every measurement and reset. Kept apart from `generation`
    /// because a reload during a measurement (Refresh, a Restore, the
    /// browser trashing something) must discard the sizes but must still
    /// end the measurement; otherwise Calculate Sizes stayed "Measuring…"
    /// and disabled until the connection changed.
    private var measurement = 0

    init(service: RemoteFileService) {
        self.service = service
    }

    var totalItemCount: Int { runs.reduce(0) { $0 + $1.itemCount } }

    /// Runs whose folder the login node can reach: the only ones that can be
    /// measured, restored from or emptied (see `TrashRun.Reachability`).
    var reachableRuns: [TrashRun] { runs.filter(\.isReachable) }

    var totalMeasuredBytes: Int64? {
        let measurable = reachableRuns
        guard !measurable.isEmpty, measurable.allSatisfy({ sizes[$0.directory] != nil }) else {
            return nil
        }
        return measurable.reduce(0) { $0 + (sizes[$1.directory] ?? 0) }
    }

    /// Forgets everything (the connection identity changed).
    func reset() {
        generation += 1
        measurement += 1
        runs = []
        sizes = [:]
        busyDirectories = []
        hasLoaded = false
        isLoading = false
        isMeasuring = false
        message = nil
    }

    /// `forgetting`: index entries of missing runs to drop first (see
    /// `forget(_:)`).
    func load(forgetting pointers: [String] = [], onLoaded: (@MainActor () -> Void)? = nil) {
        guard let browser, let settings = browser.currentSettings() else {
            return
        }
        generation += 1
        let current = generation
        let roots = browser.protectedRoots()
        isLoading = true
        Task {
            do {
                let found = try await service.listTrash(settings: settings, storageRoots: roots, forgetting: pointers)
                guard current == generation else {
                    return
                }
                runs = found
                sizes = sizes.filter { size in found.contains { $0.directory == size.key } }
                hasLoaded = true
                onLoaded?()
            } catch {
                guard current == generation else {
                    return
                }
                show("Could not list the trash on \(browser.clusterName) — \(error.localizedDescription)", isError: true)
            }
            isLoading = false
        }
    }

    /// Reloads after the browser trashed or restored something, but only
    /// when the sheet has been opened before (no remote work otherwise).
    func reloadIfLoaded() {
        if hasLoaded {
            load()
        }
    }

    func measureSizes() {
        let directories = reachableRuns.map(\.directory)
        guard let browser, let settings = browser.currentSettings(), !directories.isEmpty else {
            return
        }
        let current = generation
        measurement += 1
        let token = measurement
        isMeasuring = true
        Task {
            defer {
                if token == measurement {
                    isMeasuring = false
                }
            }
            do {
                let measured = try await service.trashSizes(settings: settings, directories: directories)
                guard current == generation else {
                    return
                }
                sizes.merge(measured) { _, new in new }
            } catch {
                guard current == generation else {
                    return
                }
                show(error.localizedDescription, isError: true)
            }
        }
    }

    /// Drops a missing run's index entry (the user chose Forget): nothing is
    /// deleted, and the login node keeps the entry if the run turned up
    /// again meanwhile.
    func forget(_ run: TrashRun) {
        guard case .missing(let pointer) = run.reachability else {
            return
        }
        let name = browser?.displayPath(run.directory) ?? run.directory
        load(forgetting: [pointer]) { [weak self] in
            guard let self else {
                return
            }
            switch self.runs.first(where: { $0.directory == run.directory })?.reachability {
            case nil:
                self.show("Stopped listing \(name). Nothing was deleted.", isError: false)
            case .reachable?:
                self.show("\(name) is reachable again, so it is still listed.", isError: false)
            case .missing?, .unavailable?:
                self.show("Could not remove the entry for \(name) from \(RemoteFileService.homeTrashDisplayPath)/.index.", isError: true)
            }
        }
    }

    func restore(_ run: TrashRun, items: [TrashRun.Item]) {
        guard let browser, let settings = browser.currentSettings(), !busyDirectories.contains(run.directory) else {
            return
        }
        let name = browser.clusterName
        busyDirectories.insert(run.directory)
        Task {
            do {
                let outcome = try await service.restore(settings: settings, run: run, items: items)
                var text = "Restored \(FileBrowserModel.itemCount(outcome.restored.count)) on \(name)"
                if !outcome.failed.isEmpty {
                    text += "; \(outcome.failed.count) could not be restored: \(FileBrowserModel.failureSummary(outcome.failed))"
                }
                show(text + ".", isError: !outcome.failed.isEmpty)
            } catch {
                show("Restore on \(name) failed — \(error.localizedDescription)", isError: true)
            }
            busyDirectories.remove(run.directory)
            load()
            browser.refreshCurrent()
        }
    }

    /// Permanently deletes whole run folders (the user confirmed in the UI).
    /// Never an unreachable run: what is at its path now is unknown. The
    /// delete job drops the index entry of each run folder it removed (see
    /// `RemoteFileScripts.jobWorker`), so the reload does not list an
    /// emptied scratch run as missing.
    func empty(_ selected: [TrashRun]) {
        guard let browser else {
            return
        }
        let selected = selected.filter(\.isReachable)
        let directories = selected.map(\.directory).filter { !busyDirectories.contains($0) }
        guard !directories.isEmpty else {
            return
        }
        busyDirectories.formUnion(directories)
        let count = selected.reduce(0) { $0 + $1.itemCount }
        browser.startDelete(
            paths: directories,
            title: "Emptying \(FileBrowserModel.itemCount(count)) from the trash"
        ) { [weak self] in
            self?.busyDirectories.subtract(directories)
            self?.load()
        }
    }

    func dismissMessage() {
        message = nil
    }

    private func show(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }
}
