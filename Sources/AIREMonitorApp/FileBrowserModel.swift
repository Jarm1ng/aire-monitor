import AppKit
import Foundation

// MARK: - Entry conveniences

/// View-facing conveniences over `RemoteFileEntry` (owned by
/// `RemoteFileService`). The sort keys are non-optional so they can back
/// `KeyPathComparator` table columns directly.
extension RemoteFileEntry {
    var sortName: String { name.lowercased() }
    var sortSize: Int64 { size ?? -1 }
    var sortModified: Date { modifiedAt ?? .distantPast }
    var sortOwner: String { owner ?? "" }
    var sortMode: String { permissions ?? "" }

    /// Double-clicking these attempts navigation. Symlinks are included
    /// because directory links (e.g. a scratch link in $HOME) are the common
    /// case on AIRE; a file symlink surfaces a listing error banner instead.
    var isNavigable: Bool {
        kind == .directory || kind == .symlink
    }

    /// Shared download gate for the context menu and `download(entries:)`:
    /// not a directory, and not a symlink that resolves to one — scp over
    /// SFTP dereferences the link server-side and cannot fetch a directory,
    /// so such entries get the same friendly treatment as plain folders.
    var isDownloadable: Bool {
        kind != .directory && !(kind == .symlink && linkIsDir == true)
    }

    /// SF Symbol by kind, then by extension for plain files.
    var systemIconName: String {
        switch kind {
        case .directory:
            return "folder.fill"
        case .symlink:
            return "link"
        case .other:
            return "questionmark.square.dashed"
        case .file:
            break
        }
        let ext = (name as NSString).pathExtension.lowercased()
        if ["sh", "bash", "zsh", "csh", "slurm", "sbatch"].contains(ext) {
            return "terminal"
        }
        if ["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "heic", "webp", "svg"].contains(ext) {
            return "photo"
        }
        if ["zip", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "tar"].contains(ext) {
            return "doc.zipper"
        }
        return "doc.text"
    }
}

// MARK: - Model

/// UI state for the Files tab. All remote I/O routes through
/// `RemoteFileService`, which owns shell quoting and the remote-python JSON
/// listing protocol — this model never interpolates remote file names into
/// command strings itself. Owned as a `@StateObject` by `ContentView` so
/// navigation history, listings, and transfers survive tab switches.
@MainActor
final class FileBrowserModel: ObservableObject {

    // MARK: Nested types

    struct TransferItem: Identifiable {
        enum Direction {
            case upload
            case download
        }

        enum Phase: Equatable {
            case running
            case done
            case failed(String)
        }

        let id = UUID()
        let filename: String
        let direction: Direction
        var state: Phase = .running
    }

    struct Shortcut: Identifiable {
        let label: String
        let path: String
        let icon: String
        var id: String { "\(label)|\(path)" }
    }

    struct DiskUsageResult: Equatable {
        let path: String
        let summary: String
        let isPending: Bool
    }

    enum PreviewContent {
        case loading
        case text(String)
        case binary(mimeType: String)
        case tooLarge(bytes: Int64)
        case failure(String)
    }

    struct PreviewState: Identifiable {
        let entry: RemoteFileEntry
        var content: PreviewContent = .loading
        var id: String { entry.path }
    }

    /// A trash request that needs user confirmation first: some items sit on
    /// a filesystem where no `.aire-trash` folder could be created, so
    /// trashing them would COPY the data into the home quota. The UI offers
    /// Copy to Home Trash / Delete Permanently / Cancel.
    struct PendingQuotaTrash {
        let entries: [RemoteFileEntry]
        /// Subset of paths that would be copied into ~/.aire-trash.
        let affectedPaths: [String]
    }

    // MARK: Published state

    @Published private(set) var currentPath = ""
    @Published private(set) var listing: RemoteDirectoryListing?
    @Published private(set) var isLoading = false
    /// Distinguishes "never browsed yet" (hero) from "empty directory".
    @Published private(set) var hasLoadedOnce = false
    @Published var errorBanner: String?
    @Published var infoBanner: String?
    @Published private(set) var backStack: [String] = []
    @Published private(set) var forwardStack: [String] = []
    @Published var showHidden = false {
        didSet {
            if oldValue != showHidden {
                refreshCurrent()
            }
        }
    }
    @Published var sortOrder: [KeyPathComparator<RemoteFileEntry>] = [
        KeyPathComparator(\RemoteFileEntry.sortName)
    ]
    @Published var filterText = "" {
        didSet {
            guard oldValue != filterText else {
                return
            }
            // The Table keeps rows selected after the filter hides them, so
            // Delete / a selection context menu could act on invisible rows.
            // Prune to what the user can actually see.
            selection.formIntersection(Set(visibleEntries.map(\.id)))
        }
    }
    @Published var selection = Set<RemoteFileEntry.ID>()
    @Published private(set) var transfers: [TransferItem] = []
    @Published var activePreview: PreviewState?
    /// Non-nil while a trash operation waits for quota-copy confirmation.
    @Published var pendingQuotaTrash: PendingQuotaTrash?
    @Published var diskUsageResult: DiskUsageResult?
    /// True while a mutation (mkdir/rename/trash/delete) is in flight.
    @Published private(set) var isMutating = false

    // MARK: Private state

    private let service = RemoteFileService()
    private weak var appModel: AppModel?
    /// Resolved once per attach from the remote side (`$HOME`); never derived
    /// from a hardcoded `/users/<name>` pattern.
    private var homePath: String?
    private var loadGeneration = 0
    private var bannerDismissTask: Task<Void, Never>?

    private static let previewMaxBytes = 262_144
    private static let bannerDismissDelay: UInt64 = 6_000_000_000
    private static let doneTransferLinger: UInt64 = 4_000_000_000

    // MARK: Wiring

    /// Idempotent: called from every entry point (tab appear, Jobs deep
    /// link) so the model always has settings and storage labels to hand.
    func attach(appModel: AppModel) {
        if self.appModel !== appModel {
            self.appModel = appModel
        }
    }

    private func settings() -> ServerSettings? {
        guard let appModel else {
            showError("File browser is not connected to the app model yet.")
            return nil
        }
        return appModel.settings
    }

    // MARK: Derived state

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// Toolbar chips: Home (resolved remotely) plus the labeled storage
    /// spaces from the latest snapshot, deduplicated by path.
    var shortcuts: [Shortcut] {
        var items: [Shortcut] = []
        var seenPaths = Set<String>()
        func add(label: String, path: String, icon: String) {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("/"), seenPaths.insert(trimmed).inserted else {
                return
            }
            items.append(Shortcut(label: label, path: trimmed, icon: icon))
        }
        if let homePath {
            add(label: "Home", path: homePath, icon: "house")
        }
        let user = (appModel?.snapshot?.remote.user ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        for space in appModel?.snapshot?.storage ?? [] {
            add(
                label: space.label,
                path: Self.personalPath(space.path, user: user),
                icon: Self.icon(forStorageLabel: space.label)
            )
        }
        return items
    }

    /// Storage snapshots report shared roots (e.g. `/mnt/scratch`), but users
    /// almost always want their own account subdirectory. Append the username
    /// unless the path already ends in it (home is already `/users/<user>`).
    private static func personalPath(_ path: String, user: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, trimmed.hasPrefix("/") else {
            return trimmed
        }
        let normalized = trimmed.count > 1 && trimmed.hasSuffix("/")
            ? String(trimmed.dropLast())
            : trimmed
        if normalized == "/\(user)" || normalized.hasSuffix("/\(user)") {
            return normalized
        }
        return "\(normalized)/\(user)"
    }

    /// Current listing filtered by the search text and sorted by the table's
    /// sort order.
    var visibleEntries: [RemoteFileEntry] {
        guard let listing else {
            return []
        }
        let filtered = filterText.isEmpty
            ? listing.entries
            : listing.entries.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
        return filtered.sorted(using: sortOrder)
    }

    var selectedEntries: [RemoteFileEntry] {
        entries(withIDs: selection)
    }

    func entries(withIDs ids: Set<RemoteFileEntry.ID>) -> [RemoteFileEntry] {
        listing?.entries.filter { ids.contains($0.id) } ?? []
    }

    // MARK: Navigation

    func openHome() {
        if let homePath {
            navigate(to: homePath)
            return
        }
        guard let settings = settings() else {
            return
        }
        Task {
            do {
                let home = try await service.homeDirectory(settings: settings)
                homePath = home
                navigate(to: home)
            } catch {
                showError("Could not resolve the remote home directory — \(error.localizedDescription)")
            }
        }
    }

    /// How a load was initiated. The matching back/forward stack mutations
    /// are committed ONLY in the load's success branch (after the generation
    /// guard) — a failed or superseded navigation must never corrupt
    /// history. `goBack`/`goForward` therefore peek rather than pop.
    private enum NavigationIntent {
        case push(previous: String)
        case back(from: String)
        case forward(from: String)
        case refresh
    }

    func navigate(to path: String) {
        let target = Self.normalize(path)
        guard target.hasPrefix("/") else {
            showError("Only absolute remote paths can be opened (got \(path.isEmpty ? "an empty path" : "'\(path)'")).")
            return
        }
        load(path: target, resetFilter: true, intent: .push(previous: lastLoadedPath))
    }

    func goBack() {
        guard let previous = backStack.last else {
            return
        }
        load(path: previous, resetFilter: true, intent: .back(from: lastLoadedPath))
    }

    func goForward() {
        guard let next = forwardStack.last else {
            return
        }
        load(path: next, resetFilter: true, intent: .forward(from: lastLoadedPath))
    }

    func refreshCurrent() {
        guard !currentPath.isEmpty else {
            return
        }
        load(path: currentPath, resetFilter: false, intent: .refresh)
    }

    /// The last path that actually produced a listing — unlike `currentPath`,
    /// never an in-flight or failed target. History entries only ever come
    /// from here.
    private var lastLoadedPath: String {
        listing?.requestedPath ?? ""
    }

    private func commitHistory(intent: NavigationIntent, loadedPath: String) {
        switch intent {
        case .push(let previous):
            if !previous.isEmpty, previous != loadedPath {
                backStack.append(previous)
                forwardStack.removeAll()
            }
        case .back(let from):
            if backStack.last == loadedPath {
                backStack.removeLast()
            }
            if !from.isEmpty {
                forwardStack.append(from)
            }
        case .forward(let from):
            if forwardStack.last == loadedPath {
                forwardStack.removeLast()
            }
            if !from.isEmpty {
                backStack.append(from)
            }
        case .refresh:
            break
        }
    }

    private func load(path: String, resetFilter: Bool, intent: NavigationIntent) {
        guard let settings = settings() else {
            return
        }
        let previousPath = lastLoadedPath
        currentPath = path
        isLoading = true
        if resetFilter {
            filterText = ""
            selection.removeAll()
        }
        loadGeneration += 1
        let generation = loadGeneration
        let includeHidden = showHidden
        Task {
            do {
                let result = try await service.listDirectory(
                    settings: settings,
                    path: path,
                    showHidden: includeHidden
                )
                guard generation == loadGeneration else {
                    return
                }
                commitHistory(intent: intent, loadedPath: path)
                listing = result
                hasLoadedOnce = true
                isLoading = false
                // Drop selected ids that no longer exist after a refresh.
                let validIDs = Set(result.entries.map(\.id))
                selection = selection.intersection(validIDs)
            } catch {
                guard generation == loadGeneration else {
                    return
                }
                isLoading = false
                // Keep showing the last good listing under its own path so
                // the breadcrumb never points at a directory we failed to
                // open. On a first-ever load this resets to "" so the hero
                // state and the currentPath-gated toolbar buttons (New
                // Folder / Upload / Refresh) stay consistent.
                currentPath = previousPath
                showError("Could not open \(path) — \(error.localizedDescription)")
            }
        }
    }

    // MARK: Mutations

    func mkdir(name: String) {
        guard !currentPath.isEmpty else {
            return
        }
        if let issue = Self.validateName(name) {
            showError(issue)
            return
        }
        guard let settings = settings() else {
            return
        }
        let path = Self.join(currentPath, name.trimmingCharacters(in: .whitespacesAndNewlines))
        performMutation(failurePrefix: "New folder failed") { [service] in
            try await service.createDirectory(settings: settings, path: path)
        }
    }

    func rename(entry: RemoteFileEntry, to newName: String) {
        if let issue = Self.validateName(newName) {
            showError(issue)
            return
        }
        guard let settings = settings() else {
            return
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = (entry.path as NSString).deletingLastPathComponent
        let destination = Self.join(parent, trimmed)
        guard destination != entry.path else {
            return
        }
        performMutation(failurePrefix: "Rename failed") { [service] in
            try await service.rename(settings: settings, from: entry.path, to: destination)
        }
    }

    /// Soft delete: the service moves paths into per-operation server-side
    /// `.aire-trash/<timestamp>-<id>/` folders (same-filesystem whenever
    /// possible, so nothing is copied into the home quota) and reports where
    /// they went. When a quota copy would be required, the service throws
    /// and the request parks in `pendingQuotaTrash` for user confirmation.
    func trash(entries: [RemoteFileEntry]) {
        performTrash(entries: entries, allowQuotaCopy: false)
    }

    /// User approved copying cross-filesystem items into the home-quota
    /// trash. Takes the pending request explicitly so dialog dismissal
    /// clearing `pendingQuotaTrash` can never race the button action.
    func confirmQuotaTrash(_ pending: PendingQuotaTrash) {
        pendingQuotaTrash = nil
        performTrash(entries: pending.entries, allowQuotaCopy: true)
    }

    func cancelQuotaTrash() {
        pendingQuotaTrash = nil
    }

    private func performTrash(entries: [RemoteFileEntry], allowQuotaCopy: Bool) {
        guard !entries.isEmpty, let settings = settings() else {
            return
        }
        let paths = entries.map(\.path)
        isMutating = true
        Task {
            do {
                let destinations = try await service.moveToTrash(
                    settings: settings,
                    paths: paths,
                    allowQuotaCopy: allowQuotaCopy
                )
                selection.removeAll()
                showInfo(Self.trashSuccessMessage(count: paths.count, destinations: destinations))
                isMutating = false
                refreshCurrent()
            } catch let needsConfirmation as RemoteFileService.QuotaCopyConfirmationRequired {
                // Nothing was moved — ask before copying into the home quota.
                isMutating = false
                pendingQuotaTrash = PendingQuotaTrash(
                    entries: entries,
                    affectedPaths: needsConfirmation.paths
                )
            } catch {
                showError("Move to trash failed — \(error.localizedDescription)")
                isMutating = false
                refreshCurrent()
            }
        }
    }

    private static func trashSuccessMessage(count: Int, destinations: [String]) -> String {
        let items = "\(count) item\(count == 1 ? "" : "s")"
        if destinations.count == 1, let only = destinations.first {
            return "Moved \(items) to \(only)"
        }
        return "Moved \(items) to trash: \(destinations.joined(separator: ", "))"
    }

    /// Hard delete, only reachable through the doubly-confirmed UI path.
    func deleteForever(entries: [RemoteFileEntry]) {
        guard !entries.isEmpty, let settings = settings() else {
            return
        }
        let paths = entries.map(\.path)
        isMutating = true
        Task {
            do {
                try await service.deletePermanently(settings: settings, paths: paths)
                selection.removeAll()
                showInfo("Permanently deleted \(paths.count) item\(paths.count == 1 ? "" : "s")")
            } catch {
                showError("Permanent delete failed — \(error.localizedDescription)")
            }
            isMutating = false
            refreshCurrent()
        }
    }

    private func performMutation(
        failurePrefix: String,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        isMutating = true
        Task {
            do {
                try await operation()
            } catch {
                showError("\(failurePrefix) — \(error.localizedDescription)")
            }
            isMutating = false
            refreshCurrent()
        }
    }

    // MARK: Transfers

    func download(entries: [RemoteFileEntry]) {
        guard let settings = settings() else {
            return
        }
        let files = entries.filter(\.isDownloadable)
        guard !files.isEmpty else {
            showError("Select files to download — folders are not downloadable yet.")
            return
        }
        let downloadsDirectory = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask)
            .first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        for entry in files {
            let transfer = TransferItem(filename: entry.name, direction: .download)
            transfers.append(transfer)
            let transferID = transfer.id
            Task {
                do {
                    let localURL = try await service.download(
                        settings: settings,
                        remotePath: entry.path,
                        toLocalDirectory: downloadsDirectory
                    )
                    finishTransfer(id: transferID, error: nil)
                    NSWorkspace.shared.activateFileViewerSelecting([localURL])
                } catch {
                    finishTransfer(id: transferID, error: error)
                }
            }
        }
    }

    func upload(urls: [URL]) {
        guard !currentPath.isEmpty else {
            showError("Open a remote folder before uploading.")
            return
        }
        guard let settings = settings() else {
            return
        }
        let destination = currentPath
        for url in urls where url.isFileURL {
            let transfer = TransferItem(filename: url.lastPathComponent, direction: .upload)
            transfers.append(transfer)
            let transferID = transfer.id
            Task {
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    try await service.upload(
                        settings: settings,
                        localFile: url,
                        toRemoteDirectory: destination
                    )
                    finishTransfer(id: transferID, error: nil)
                    refreshCurrent()
                } catch {
                    finishTransfer(id: transferID, error: error)
                }
            }
        }
    }

    func dismissTransfer(_ id: UUID) {
        transfers.removeAll { $0.id == id }
    }

    /// Successful transfers linger briefly with a checkmark; failures stay
    /// until dismissed so their message is never lost to the 6s banner timer.
    private func finishTransfer(id: UUID, error: Error?) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else {
            return
        }
        if let error {
            transfers[index].state = .failed(error.localizedDescription)
            return
        }
        transfers[index].state = .done
        Task {
            try? await Task.sleep(nanoseconds: Self.doneTransferLinger)
            transfers.removeAll { $0.id == id && $0.state == .done }
        }
    }

    // MARK: Preview

    func preview(entry: RemoteFileEntry) {
        guard let settings = settings() else {
            return
        }
        activePreview = PreviewState(entry: entry, content: .loading)
        Task {
            let outcome: PreviewContent
            do {
                switch try await service.preview(
                    settings: settings,
                    path: entry.path,
                    maxBytes: Self.previewMaxBytes
                ) {
                case .text(let text):
                    outcome = .text(text)
                case .binary(let mimeType):
                    outcome = .binary(mimeType: mimeType)
                case .tooLarge(let bytes):
                    outcome = .tooLarge(bytes: bytes)
                }
            } catch {
                outcome = .failure(error.localizedDescription)
            }
            // The sheet may have moved on to another file (or closed) while
            // the preview was in flight.
            guard activePreview?.entry.path == entry.path else {
                return
            }
            activePreview?.content = outcome
        }
    }

    // MARK: Folder size

    func requestDiskUsage(for entry: RemoteFileEntry) {
        guard let settings = settings() else {
            return
        }
        diskUsageResult = DiskUsageResult(path: entry.path, summary: "Calculating…", isPending: true)
        Task {
            do {
                let summary = try await service.diskUsage(settings: settings, path: entry.path)
                guard diskUsageResult?.path == entry.path else {
                    return
                }
                diskUsageResult = DiskUsageResult(path: entry.path, summary: summary, isPending: false)
            } catch {
                guard diskUsageResult?.path == entry.path else {
                    return
                }
                diskUsageResult = nil
                showError("Folder size failed — \(error.localizedDescription)")
            }
        }
    }

    func dismissDiskUsage() {
        diskUsageResult = nil
    }

    // MARK: Shell

    /// Opens a terminal session that lands in the current directory. The
    /// path travels through `openShell(settings:startDirectory:)`, which
    /// shell-quotes it before interpolation.
    func openShellHere(using manager: TerminalManager) {
        guard !currentPath.isEmpty, let settings = settings() else {
            return
        }
        manager.openShell(settings: settings, startDirectory: currentPath)
    }

    // MARK: Banners

    func showError(_ message: String) {
        infoBanner = nil
        errorBanner = message
        scheduleBannerDismiss()
    }

    func showInfo(_ message: String) {
        errorBanner = nil
        infoBanner = message
        scheduleBannerDismiss()
    }

    private func scheduleBannerDismiss() {
        bannerDismissTask?.cancel()
        bannerDismissTask = Task {
            try? await Task.sleep(nanoseconds: Self.bannerDismissDelay)
            guard !Task.isCancelled else {
                return
            }
            errorBanner = nil
            infoBanner = nil
        }
    }

    // MARK: Path helpers

    /// Trims whitespace and trailing slashes (except the root itself).
    /// Deliberately does NOT collapse `..` — the remote side resolves paths;
    /// this is display-level normalization only.
    static func normalize(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/\(name)" : "\(directory)/\(name)"
    }

    /// Validates a user-entered file or folder name (mkdir / rename). The
    /// service layer quotes everything anyway; this exists to give friendly
    /// feedback before a doomed remote round-trip.
    static func validateName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Name cannot be empty."
        }
        if trimmed.contains("/") {
            return "Names cannot contain “/”."
        }
        if trimmed == "." || trimmed == ".." {
            return "That name is reserved."
        }
        if trimmed.unicodeScalars.contains(where: { $0 == "\0" || CharacterSet.newlines.contains($0) }) {
            return "Names cannot contain newlines or control characters."
        }
        return nil
    }

    static func icon(forStorageLabel label: String) -> String {
        let lowered = label.lowercased()
        if lowered.contains("home") {
            return "house"
        }
        if lowered.contains("scratch") {
            return "externaldrive"
        }
        return "folder"
    }
}
