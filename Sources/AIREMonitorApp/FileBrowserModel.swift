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
    /// case on the Leeds clusters; a file symlink surfaces a listing error
    /// banner instead.
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

/// UI state for one cluster's Files tab. All remote I/O routes through
/// `RemoteFileService`, which owns shell quoting and the remote-python JSON
/// listing protocol — this model never interpolates remote file names into
/// command strings itself.
///
/// Each `ClusterSession` owns exactly one browser (attached at creation), so
/// a path, history entry, preview or transfer can never be replayed against
/// the other cluster's filesystem: every operation captures the session's
/// `ConnectionSettings` at the moment it starts. Living on the session also
/// means navigation history, listings and transfers survive tab and sidebar
/// switches.
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
        /// Cluster the transfer runs against, for status text.
        let clusterName: String
        var state: Phase = .running
    }

    /// A location chip: Home first, then the cluster's storage spaces.
    struct Shortcut: Identifiable {
        let label: String
        let path: String
        let kind: StorageKind
        /// Tooltip: the path plus what kind of space it is (shared home,
        /// cluster-only scratch with a project quota, …).
        let detail: String
        var icon: String { kind.systemImage }
        var id: String { "\(label)|\(path)" }
    }

    /// Who and where the browser talks to: the account and the login host.
    /// The route is deliberately not part of it — direct or through rash,
    /// the same account on the same host sees the same filesystem, so a
    /// route switch keeps the cached home and the open folder.
    struct ConnectionIdentity: Equatable {
        let username: String
        let hostname: String

        init(_ settings: ConnectionSettings) {
            username = settings.username
            hostname = settings.hostname.lowercased()
        }
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
    /// a filesystem where no `RemoteFileService.trashDirectoryName` folder
    /// could be created, so trashing them would COPY the data into the home
    /// quota (one quota shared by every cluster). The UI offers Copy to Home
    /// Trash / Delete Permanently / Cancel.
    struct PendingQuotaTrash {
        let entries: [RemoteFileEntry]
        /// Subset of paths that would be copied into the home trash.
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
    private weak var session: ClusterSession?
    /// The remote `$HOME` (resolved with realpath on the login node; never
    /// derived from a hardcoded `/users/<name>` pattern), tagged with the
    /// connection identity it was resolved for. A different account or login
    /// host misses the cache and resolves again, so changing the username, or
    /// the cluster's host under Advanced, can never send Home to the previous
    /// account's directory.
    private var resolvedHome: (identity: ConnectionIdentity, path: String)?
    /// Identity of the most recent listing REQUEST — what the open folder,
    /// history and selection belong to. Recorded at request time (not on
    /// success) so a navigation started just before the tab appears, such
    /// as Browse workdir from a job sheet, is never mistaken for stale.
    private var browsedIdentity: ConnectionIdentity?
    private var loadGeneration = 0
    private var bannerDismissTask: Task<Void, Never>?

    private static let previewMaxBytes = 262_144
    private static let bannerDismissDelay: UInt64 = 6_000_000_000
    private static let doneTransferLinger: UInt64 = 4_000_000_000

    // MARK: Wiring

    /// Binds the browser to its cluster. Each `ClusterSession` owns one
    /// browser and attaches it once at creation, so paths, history and
    /// transfers never mix between clusters.
    func attach(session: ClusterSession) {
        if self.session !== session {
            self.session = session
        }
    }

    private func settings() -> ConnectionSettings? {
        guard let session else {
            showError("The file browser is not attached to a cluster session yet.")
            return nil
        }
        return session.settings
    }

    /// Cluster name for banner and status text, so a message can never be
    /// mistaken for the other cluster's.
    private var clusterName: String {
        session?.displayName ?? "the cluster"
    }

    /// The cached home, only while it belongs to the current connection
    /// identity.
    private var homePath: String? {
        guard let resolvedHome, let session,
              resolvedHome.identity == ConnectionIdentity(session.settings) else {
            return nil
        }
        return resolvedHome.path
    }

    /// True while the session still connects as `identity`.
    private func isCurrent(_ identity: ConnectionIdentity) -> Bool {
        session.map { ConnectionIdentity($0.settings) } == identity
    }

    /// "AIRE and Calder": every cluster that mounts the shared /users home,
    /// taken from the catalog so a new cluster is named automatically. Used
    /// by the Home shortcut and by the trash wording in the view.
    nonisolated static var sharedHomeClusterList: String {
        ListFormatter.localizedString(byJoining: ClusterCatalog.all.map(\.displayName))
    }

    /// Drops the open folder, history, selection and pending dialogs when
    /// they were produced under a different account or login host than the
    /// session now uses: another account's paths are not this account's to
    /// act on, and Back must never replay them. The view calls this when it
    /// appears and when the session signs in or out — deliberately NOT on
    /// every identity change, because the host field in the sidebar edits
    /// the identity per keystroke while the Files tab may be on screen.
    /// Transfers are left alone: each captured its own settings and names
    /// its cluster.
    func reconcileConnectionIdentity() {
        guard let session, let browsedIdentity,
              browsedIdentity != ConnectionIdentity(session.settings) else {
            return
        }
        loadGeneration += 1     // orphan listings still in flight for the old identity
        self.browsedIdentity = nil
        currentPath = ""
        listing = nil
        isLoading = false
        hasLoadedOnce = false
        backStack.removeAll()
        forwardStack.removeAll()
        filterText = ""
        selection.removeAll()
        activePreview = nil
        pendingQuotaTrash = nil
        diskUsageResult = nil
    }

    // MARK: Derived state

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// Toolbar chips: Home first, then this cluster's storage spaces from its
    /// latest snapshot (home, scratch, flash order), deduplicated by path.
    ///
    /// Home is the remotely resolved `$HOME` once known; before the first
    /// resolution the snapshot's own home row stands in, so the chip is
    /// there from the start. Rows that do not name a usable directory are
    /// skipped (see `isBrowsable`).
    var shortcuts: [Shortcut] {
        let snapshot = session?.snapshot
        let storage = (snapshot?.sortedStorage ?? []).filter(Self.isBrowsable)
        let user = (snapshot?.remote.user ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isLegacySnapshot = snapshot?.cluster == nil

        var items: [Shortcut] = []
        var seenPaths = Set<String>()
        func add(label: String, path: String, kind: StorageKind, quotaType: String?) {
            let normalized = Self.normalize(path)
            guard normalized.hasPrefix("/"), seenPaths.insert(normalized).inserted else {
                return
            }
            items.append(Shortcut(
                label: label,
                path: normalized,
                kind: kind,
                detail: shortcutDetail(path: normalized, kind: kind, quotaType: quotaType)
            ))
        }

        let homeRow = storage.first { $0.kind == .home }
        let homeFromSnapshot = homeRow.map {
            Self.personalPath(for: $0, isLegacySnapshot: isLegacySnapshot, user: user)
        }
        let homeChipPath = homePath ?? homeFromSnapshot
        if let homeChipPath {
            add(label: "Home", path: homeChipPath, kind: .home, quotaType: homeRow?.quotaType)
        }
        for space in storage {
            // The Home chip already stands for the snapshot's home row, even
            // when the row spells the path differently from realpath(~)
            // (e.g. through a symlinked /users).
            if homeChipPath != nil, let homeRow, space.label == homeRow.label {
                continue
            }
            add(
                label: space.label,
                path: Self.personalPath(for: space, isLegacySnapshot: isLegacySnapshot, user: user),
                kind: space.kind,
                quotaType: space.quotaType
            )
        }
        return items
    }

    private func shortcutDetail(path: String, kind: StorageKind, quotaType: String?) -> String {
        if kind.isSharedAcrossClusters {
            return "\(path) — shared home: the same files on \(Self.sharedHomeClusterList)"
        }
        var detail = "\(path) — \(clusterName) only"
        switch quotaType {
        case "lustre-project":
            detail += ", Lustre project quota"
        case "lustre-user":
            detail += ", Lustre user quota"
        default:
            break
        }
        return detail
    }

    /// A storage row worth a shortcut. Rows the collector marks
    /// "unavailable" are skipped: their path is the raw candidate template
    /// (still holding `$USER`/`$HOME`, which only the login node expands),
    /// a candidate that does not exist — e.g. a scratch directory not yet
    /// provisioned on a newly opened cluster — or, rarely, a real directory
    /// whose df/quota probe timed out. The row cannot tell that last case
    /// apart, and a chip that opens "No such directory" is worse than one
    /// that is missing until the next refresh. The token check is a second
    /// line of defence for any row that still carries a template.
    private static func isBrowsable(_ space: StorageSummary) -> Bool {
        space.source != "unavailable"
            && !space.path.contains("$USER")
            && !space.path.contains("$HOME")
    }

    /// The directory a storage shortcut opens.
    ///
    /// The current collector reports the RESOLVED per-user directory — the
    /// first candidate that exists on the login node, e.g.
    /// `/scratch-calder/users/<user>` on Calder or `/mnt/scratch/<user>` on
    /// AIRE — and marks its rows with `quota_type` (and the snapshot with a
    /// `cluster` block). Those paths are used verbatim: appending the user
    /// again would yield `/scratch-calder/users/<user>/<user>`, which does
    /// not exist, and a layout whose directory is not named after the user
    /// must not be second-guessed either.
    ///
    /// Snapshot caches written by the pre-multi-cluster collector carry
    /// neither marker, and their rows may name the shared filesystem ROOT
    /// (`/mnt/scratch`) rather than the user's directory. Only for those
    /// legacy rows is the username appended — unless the path already ends
    /// in it, or the row is home (always reported resolved). The next
    /// successful refresh replaces such a cache.
    static func personalPath(for space: StorageSummary, isLegacySnapshot: Bool, user: String) -> String {
        let path = normalize(space.path)
        let reportsResolvedDirectory = !isLegacySnapshot || space.quotaType != nil
        guard !reportsResolvedDirectory, space.kind != .home,
              !user.isEmpty, path.hasPrefix("/") else {
            return path
        }
        if path == "/\(user)" || path.hasSuffix("/\(user)") {
            return path
        }
        return join(path, user)
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
        // Tagged with the identity the request was made for: if the account
        // or host changes while this is in flight, the result can never be
        // served as the new identity's home.
        let identity = ConnectionIdentity(settings)
        let name = clusterName
        Task {
            do {
                let home = try await service.homeDirectory(settings: settings)
                guard isCurrent(identity) else {
                    // Superseded by an account/host change while in flight.
                    return
                }
                resolvedHome = (identity, home)
                navigate(to: home)
            } catch {
                showError("Could not find your home directory on \(name) — \(error.localizedDescription)")
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
            showError(
                "Only absolute paths can be opened on \(clusterName) "
                    + "(got \(path.isEmpty ? "an empty path" : "'\(path)'"))."
            )
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
        let name = clusterName
        browsedIdentity = ConnectionIdentity(settings)
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
                showError("Could not open \(path) on \(name) — \(error.localizedDescription)")
            }
        }
    }

    // MARK: Mutations

    func mkdir(name: String) {
        guard !currentPath.isEmpty else {
            return
        }
        if let issue = Self.validateName(name) {
            showError("Cannot create that folder on \(clusterName) — \(issue)")
            return
        }
        guard let settings = settings() else {
            return
        }
        let path = Self.join(currentPath, name.trimmingCharacters(in: .whitespacesAndNewlines))
        performMutation(failurePrefix: "New folder on \(clusterName) failed") { [service] in
            try await service.createDirectory(settings: settings, path: path)
        }
    }

    func rename(entry: RemoteFileEntry, to newName: String) {
        if let issue = Self.validateName(newName) {
            showError("Cannot rename “\(entry.name)” on \(clusterName) — \(issue)")
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
        performMutation(failurePrefix: "Rename on \(clusterName) failed") { [service] in
            try await service.rename(settings: settings, from: entry.path, to: destination)
        }
    }

    /// Soft delete: the service moves paths into per-operation server-side
    /// `<trashDirectoryName>/<timestamp>-<id>/` folders (same-filesystem
    /// whenever possible, so nothing is copied into the shared home quota)
    /// and reports where they went. When a quota copy would be required,
    /// the service throws and the request parks in `pendingQuotaTrash` for
    /// user confirmation.
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
        let name = clusterName
        isMutating = true
        Task {
            do {
                let destinations = try await service.moveToTrash(
                    settings: settings,
                    paths: paths,
                    allowQuotaCopy: allowQuotaCopy
                )
                selection.removeAll()
                showInfo(Self.trashSuccessMessage(
                    count: paths.count,
                    destinations: destinations,
                    clusterName: name
                ))
                isMutating = false
                refreshCurrent()
            } catch let needsConfirmation as RemoteFileService.QuotaCopyConfirmationRequired {
                // Nothing was moved — ask before copying into the home quota.
                isMutating = false
                // Confirming runs with the session's settings at that moment;
                // if the account or host changed meanwhile, those would no
                // longer be the settings these paths were listed under.
                guard isCurrent(ConnectionIdentity(settings)) else {
                    showError("Move to trash on \(name) was cancelled — the connection changed. Nothing was moved.")
                    return
                }
                pendingQuotaTrash = PendingQuotaTrash(
                    entries: entries,
                    affectedPaths: needsConfirmation.paths
                )
            } catch {
                showError("Move to trash on \(name) failed — \(error.localizedDescription)")
                isMutating = false
                refreshCurrent()
            }
        }
    }

    private static func trashSuccessMessage(count: Int, destinations: [String], clusterName: String) -> String {
        let items = "\(count) item\(count == 1 ? "" : "s")"
        if destinations.count == 1, let only = destinations.first {
            return "Moved \(items) on \(clusterName) to \(only)"
        }
        return "Moved \(items) on \(clusterName) to trash: \(destinations.joined(separator: ", "))"
    }

    /// Hard delete, only reachable through the doubly-confirmed UI path.
    func deleteForever(entries: [RemoteFileEntry]) {
        guard !entries.isEmpty, let settings = settings() else {
            return
        }
        let paths = entries.map(\.path)
        let name = clusterName
        isMutating = true
        Task {
            do {
                try await service.deletePermanently(settings: settings, paths: paths)
                selection.removeAll()
                showInfo("Permanently deleted \(paths.count) item\(paths.count == 1 ? "" : "s") on \(name)")
            } catch {
                showError("Permanent delete on \(name) failed — \(error.localizedDescription)")
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
            showError("Select files to download from \(clusterName) — folders are not downloadable yet.")
            return
        }
        let downloadsDirectory = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask)
            .first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        for entry in files {
            let transfer = TransferItem(filename: entry.name, direction: .download, clusterName: clusterName)
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
            showError("Open a folder on \(clusterName) before uploading.")
            return
        }
        guard let settings = settings() else {
            return
        }
        let destination = currentPath
        for url in urls where url.isFileURL {
            let transfer = TransferItem(filename: url.lastPathComponent, direction: .upload, clusterName: clusterName)
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
        let name = clusterName
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
                showError("Folder size on \(name) failed — \(error.localizedDescription)")
            }
        }
    }

    func dismissDiskUsage() {
        diskUsageResult = nil
    }

    // MARK: Shell

    /// Opens a terminal session on this browser's cluster that lands in the
    /// current directory. The manager is the session's own, never one passed
    /// in, so a folder listed on Calder can only ever open a Calder shell.
    /// The path travels through `openShell(settings:startDirectory:)`, which
    /// shell-quotes it before interpolation. (The dashboard wires its "Open
    /// Shell Here" items through `onOpenShellAt`, which also switches tabs;
    /// this is the model-level equivalent.)
    func openShellHere() {
        guard !currentPath.isEmpty, let session, let settings = settings() else {
            return
        }
        session.terminals.openShell(settings: settings, startDirectory: currentPath)
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

    /// Drops trailing slashes (except the root itself). Whitespace is kept:
    /// remote names may legitimately end in spaces, and trimming would open
    /// the parent instead of a directory called "data ". A whitespace-only
    /// input becomes "" so callers reject it. Deliberately does NOT collapse
    /// `..` — the remote side resolves paths.
    static func normalize(_ path: String) -> String {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        var normalized = path
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
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
}
