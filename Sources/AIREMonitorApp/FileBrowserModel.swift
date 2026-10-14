import HPCCore
import AppKit
import Foundation

// MARK: - Entry conveniences

/// View-facing conveniences over `RemoteFileEntry` (owned by
/// `RemoteFileService`). The sort keys are non-optional so they can back
/// `KeyPathComparator` table columns directly. `sortName` is the plain name:
/// the String comparator is already Finder's case-insensitive, numeric-aware
/// `localizedStandard`, so lowercasing per comparison only cost time.
extension RemoteFileEntry {
    var sortName: String { name }
    var sortSize: Int64 { size ?? -1 }
    var sortModified: Date { modifiedAt ?? .distantPast }
    var sortOwner: String { owner ?? "" }
    var sortMode: String { permissions ?? "" }

    /// A folder, or a link that resolves to one (the common $HOME → scratch
    /// link on the Leeds clusters). Double-clicking these navigates; Folder
    /// Size and Open Shell Here apply to them.
    var isDirectoryLike: Bool {
        kind == .directory || (kind == .symlink && linkIsDir == true)
    }

    var isNavigable: Bool { isDirectoryLike }

    /// A regular file, or a link that is not known to resolve to a folder.
    /// FIFOs, sockets and devices are excluded: scp would block on a FIFO
    /// until killed. A broken link stays included and fails with a clear
    /// "could not find" error.
    var isDownloadable: Bool {
        kind == .file || (kind == .symlink && linkIsDir != true)
    }

    var isPreviewable: Bool { isDownloadable }

    /// SF Symbol by kind, then by extension for plain files.
    var systemIconName: String {
        switch kind {
        case .directory:
            return "folder.fill"
        case .symlink:
            // Outline folder: a link to a folder, told apart from a real
            // (filled) folder at a glance; the cell also shows its target.
            return linkIsDir == true ? "folder" : "link"
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
/// protocols — this model never interpolates remote file names into
/// command strings itself.
///
/// Each `ClusterSession` owns exactly one browser (attached at creation), so
/// a path, history entry, preview or transfer can never be replayed against
/// the other cluster's filesystem: every operation captures the session's
/// `ConnectionSettings` at the moment it starts. Living on the session also
/// means navigation history, listings and transfers survive tab and sidebar
/// switches. Transfers and detached remote jobs live in `activity`, the
/// Trash sheet's state in `trash`.
@MainActor
final class FileBrowserModel: ObservableObject {

    // MARK: Nested types

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

    enum PreviewContent: Equatable {
        case loading
        case text(RemoteTextPreview)
        case binary(mimeType: String)
        case failure(String)
    }

    struct PreviewState: Identifiable {
        let entry: RemoteFileEntry
        var mode: RemotePreviewMode
        var content: PreviewContent = .loading
        /// Switching Start/End keeps the current text on screen until the
        /// other end arrives, instead of flashing a spinner.
        var isReloading = false
        var id: String { entry.path }
    }

    /// A trash request that needs user confirmation first: some items sit on
    /// a filesystem where no `RemoteFileService.trashDirectoryName` folder
    /// could be created, so trashing them would COPY the data into the home
    /// quota (one quota shared by every cluster). The UI offers Copy to Home
    /// Trash (only when it fits) / Delete Permanently / Cancel.
    struct PendingQuotaTrash {
        let entries: [RemoteFileEntry]
        /// Subset of paths that would be copied into the home trash.
        let affectedPaths: [String]
        /// Their total size; nil when it could not be measured in time.
        let bytes: Int64?
    }

    /// One message above the table. Errors and trash results stay until
    /// dismissed — they say what happened to the user's data (and where
    /// trashed items went), which a six-second toast would lose.
    struct Banner: Identifiable, Equatable {
        enum Style: Equatable {
            case info
            case error
        }

        enum Action: Equatable {
            /// Open this folder with hidden files shown (a trash folder).
            case reveal(path: String)
            case openTrash
        }

        let id = UUID()
        let message: String
        let style: Style
        let action: Action?
        let persistent: Bool

        var isError: Bool { style == .error }
    }

    // MARK: Published state

    @Published private(set) var currentPath = ""
    @Published private(set) var listing: RemoteDirectoryListing? {
        didSet { resortEntries() }
    }
    /// The listing filtered by `filterText` and sorted by `sortOrder` —
    /// stored, and recomputed only when one of those changes. A computed
    /// version re-sorted 4,000 rows (~100 ms with localizedStandard) on every
    /// read, three times per body render, on every selection click.
    @Published private(set) var visibleEntries: [RemoteFileEntry] = []
    @Published private(set) var isLoading = false
    /// Distinguishes "never browsed yet" (hero) from "empty directory".
    @Published private(set) var hasLoadedOnce = false
    /// When the shown listing was fetched.
    @Published private(set) var listedAt: Date?
    @Published private(set) var banner: Banner?
    @Published private(set) var backStack: [String] = []
    @Published private(set) var forwardStack: [String] = []
    @Published var showHidden = false {
        didSet {
            if oldValue != showHidden, !suppressHiddenRefresh {
                refreshCurrent()
            }
        }
    }
    @Published var sortOrder: [KeyPathComparator<RemoteFileEntry>] = [
        KeyPathComparator(\RemoteFileEntry.sortName)
    ] {
        didSet { resortEntries() }
    }
    @Published var filterText = "" {
        didSet {
            guard oldValue != filterText else {
                return
            }
            refilterEntries()
            // The Table keeps rows selected after the filter hides them, so
            // Delete / a selection context menu could act on invisible rows.
            // Prune to what the user can actually see.
            selection.formIntersection(Set(visibleEntries.map(\.id)))
            scheduleServerFilter()
        }
    }
    @Published var selection = Set<RemoteFileEntry.ID>()
    @Published var activePreview: PreviewState?
    /// Non-nil while a trash operation waits for quota-copy confirmation.
    @Published var pendingQuotaTrash: PendingQuotaTrash?
    @Published var diskUsageResult: DiskUsageResult?
    /// Paths with a mutation in flight (trash, delete, rename, new folder).
    /// Their rows are dimmed and excluded from further destructive actions,
    /// so a second Delete cannot start another trash of rows already moving.
    @Published private(set) var pendingPaths = Set<String>()
    @Published var isTrashPresented = false

    /// Transfers and detached remote jobs of this cluster.
    let activity: FileActivity
    /// The Trash sheet's state.
    let trash: RemoteTrashModel

    // MARK: Private state

    private let service: RemoteFileService
    private weak var session: ClusterSession?
    /// The remote `$HOME` and storage roots (realpath on the login node;
    /// never derived from a hardcoded `/users/<name>` pattern), tagged with
    /// the connection identity they were resolved for. A different account
    /// or login host misses the cache and resolves again, so changing the
    /// username, or the cluster's host under Advanced, can never send Home
    /// to the previous account's directory.
    private var resolvedHome: (identity: ConnectionIdentity, path: String, roots: [String])?
    /// Identity of the most recent listing REQUEST — what the open folder,
    /// history and selection belong to. Recorded at request time (not on
    /// success) so a navigation started just before the tab appears, such
    /// as Browse workdir from a job sheet, is never mistaken for stale.
    private var browsedIdentity: ConnectionIdentity?
    private var loadGeneration = 0
    private var previewGeneration = 0
    /// A refresh requested while a load was in flight: run once that load
    /// has committed its history, instead of superseding it (which would
    /// drop the navigation's Back entry).
    private var refreshAfterLoad = false
    private var suppressHiddenRefresh = false
    private var sortedEntries: [RemoteFileEntry] = []
    private var serverFilterTask: Task<Void, Never>?
    private var bannerDismissTask: Task<Void, Never>?
    /// Work this model started and has not finished: listings, deferred
    /// refreshes, debounced server searches, mutations, previews. The UI
    /// fires these and forgets them; `waitUntilIdle()` is how a caller that
    /// needs their outcome waits for it.
    private var pendingWork: [UUID: Task<Void, Never>] = [:]

    static let previewMaxBytes = 262_144
    private static let bannerDismissDelay: UInt64 = 6_000_000_000
    private static let serverFilterDelay: UInt64 = 300_000_000

    init(service: RemoteFileService = RemoteFileService()) {
        self.service = service
        activity = FileActivity(service: service)
        trash = RemoteTrashModel(service: service)
        activity.onUploadFinished = { [weak self] directory in
            guard let self else {
                return
            }
            if directory == self.currentPath || directory == self.listing?.resolvedPath {
                self.refreshCurrent()
            }
        }
        trash.browser = self
    }

    // MARK: Wiring

    /// Binds the browser to its cluster. Each `ClusterSession` owns one
    /// browser and attaches it once at creation, so paths, history and
    /// transfers never mix between clusters.
    func attach(session: ClusterSession) {
        if self.session !== session {
            self.session = session
        }
    }

    /// The session's settings now, or nil (with an error banner) when the
    /// browser is not attached.
    func currentSettings() -> ConnectionSettings? {
        guard let session else {
            showError("The file browser is not attached to a cluster session yet.")
            return nil
        }
        return session.settings
    }

    /// Cluster name for banner and status text, so a message can never be
    /// mistaken for the other cluster's.
    var clusterName: String {
        session?.displayName ?? "the cluster"
    }

    /// The cached home, only while it belongs to the current connection
    /// identity.
    var homePath: String? {
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
    /// Transfers and remote jobs are left alone: each captured its own
    /// settings and names its cluster.
    func reconcileConnectionIdentity() {
        guard let session, let browsedIdentity,
              browsedIdentity != ConnectionIdentity(session.settings) else {
            return
        }
        loadGeneration += 1     // orphan listings still in flight for the old identity
        self.browsedIdentity = nil
        refreshAfterLoad = false
        serverFilterTask?.cancel()
        currentPath = ""
        listing = nil
        listedAt = nil
        isLoading = false
        hasLoadedOnce = false
        backStack.removeAll()
        forwardStack.removeAll()
        filterText = ""
        serverFilterTask?.cancel()
        selection.removeAll()
        activePreview = nil
        pendingQuotaTrash = nil
        diskUsageResult = nil
        isTrashPresented = false
        trash.reset()
    }

    // MARK: Work tracking

    /// Runs `operation` on the main actor as tracked work (see
    /// `pendingWork`). Every remote round trip the model starts goes
    /// through here; only the banner's fade timer does not, since it is a
    /// delay and not work.
    @discardableResult
    private func startWork(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        // The task cannot start before this method returns (both run on the
        // main actor), so the entry is always recorded before it is removed.
        let task = Task { [weak self] in
            await operation()
            self?.pendingWork[id] = nil
        }
        pendingWork[id] = task
        return task
    }

    /// Returns once everything this model started has finished, including
    /// follow-up work started on the way (the refresh deferred behind a
    /// navigation, the reload after a trash, a debounced server search).
    ///
    /// Tests await this instead of polling for a state with a wall-clock
    /// deadline. Such a deadline loses whenever another part of the app
    /// holds the main actor for a while (the offscreen layout suite does
    /// for ~10 s): the poll then wakes up after its deadline and gives up,
    /// before the listing it is waiting for gets the main actor to publish.
    func waitUntilIdle() async {
        while let next = pendingWork.values.first {
            await next.value
        }
    }

    // MARK: Derived state

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var isMutating: Bool { !pendingPaths.isEmpty }

    /// The listing is a capped or server-filtered subset that does not
    /// match the current filter text yet: a server-side search is pending.
    var isAwaitingServerFilter: Bool {
        guard let listing else {
            return false
        }
        return (listing.truncated || !listing.filter.isEmpty) && listing.filter != filterText
    }

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

    /// Paths no trash or delete may remove or contain: home and every
    /// storage space, as the snapshot spells them and as the login node
    /// resolved them. The service refuses targets that equal or contain any
    /// of them, and its scripts re-check against realpath on the server.
    func protectedRoots() -> [String] {
        var roots: [String] = []
        if let homePath {
            roots.append(homePath)
        }
        roots += shortcuts.map(\.path)
        if let resolvedHome, let session, resolvedHome.identity == ConnectionIdentity(session.settings) {
            roots += resolvedHome.roots
        }
        if let home = (session?.snapshot?.sortedStorage ?? []).first(where: { $0.kind == .home })?.path,
           home.hasPrefix("/") {
            roots.append(Self.normalize(home))
        }
        var seen = Set<String>()
        return roots.filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }

    /// Home's free space from the latest snapshot (quota-aware: the
    /// collector reports what the user may still write), in bytes.
    var homeAvailableBytes: Int64? {
        guard let gigabytes = (session?.snapshot?.sortedStorage ?? []).first(where: { $0.kind == .home })?.availableGB,
              gigabytes >= 0 else {
            return nil
        }
        return Int64(gigabytes * 1_000_000_000)
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
    nonisolated static func personalPath(for space: StorageSummary, isLegacySnapshot: Bool, user: String) -> String {
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

    var selectedEntries: [RemoteFileEntry] {
        entries(withIDs: selection)
    }

    func entries(withIDs ids: Set<RemoteFileEntry.ID>) -> [RemoteFileEntry] {
        listing?.entries.filter { ids.contains($0.id) } ?? []
    }

    func isPending(_ entry: RemoteFileEntry) -> Bool {
        pendingPaths.contains(entry.path)
    }

    // MARK: Visible entries

    private func resortEntries() {
        sortedEntries = (listing?.entries ?? []).sorted(using: sortOrder)
        refilterEntries()
    }

    /// Filtering keeps the sorted order, so a keystroke costs a filter pass,
    /// never a re-sort. A listing the server already filtered with exactly
    /// this text is shown as is (its case-folding may differ slightly from
    /// Foundation's, and the server's answer is the complete one).
    private func refilterEntries() {
        let needle = filterText
        if needle.isEmpty || listing?.filter == needle {
            visibleEntries = sortedEntries
        } else {
            visibleEntries = sortedEntries.filter { $0.name.localizedCaseInsensitiveContains(needle) }
        }
    }

    /// When the listing is capped (or was itself a server-side search), the
    /// filter must search the whole folder on the server — otherwise
    /// "No matches" could be shown for a file that exists beyond the cap.
    private func scheduleServerFilter() {
        serverFilterTask?.cancel()
        guard isAwaitingServerFilter else {
            return
        }
        serverFilterTask = startWork { [weak self] in
            try? await Task.sleep(nanoseconds: Self.serverFilterDelay)
            guard !Task.isCancelled, let self, self.isAwaitingServerFilter else {
                return
            }
            self.refreshCurrent()
        }
    }

    // MARK: Navigation

    func openHome() {
        if let homePath {
            navigate(to: homePath)
            return
        }
        guard let settings = currentSettings() else {
            return
        }
        // Tagged with the identity the request was made for: if the account
        // or host changes while this is in flight, the result can never be
        // served as the new identity's home.
        let identity = ConnectionIdentity(settings)
        let name = clusterName
        let roots = shortcuts.map(\.path)
        startWork { [self] in
            do {
                let resolved = try await service.resolveHome(settings: settings, roots: roots)
                guard isCurrent(identity) else {
                    // Superseded by an account/host change while in flight.
                    return
                }
                resolvedHome = (identity, resolved.home, resolved.roots)
                navigate(to: resolved.home)
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

    /// Opens a hidden folder (a trash run) with hidden files shown, in one
    /// listing rather than a refresh followed by a navigation.
    func reveal(path: String) {
        suppressHiddenRefresh = true
        showHidden = true
        suppressHiddenRefresh = false
        navigate(to: path)
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

    /// Reloads the open folder. While another load is in flight the reload
    /// is deferred until that load lands: superseding it would discard its
    /// result before it commits history, and Back would skip a folder.
    func refreshCurrent() {
        guard !currentPath.isEmpty else {
            return
        }
        if isLoading {
            refreshAfterLoad = true
            return
        }
        load(path: currentPath, resetFilter: false, intent: .refresh)
    }

    /// Refreshes on returning to the tab when the listing is older than
    /// `olderThan` seconds: changes made in the terminal or by a running
    /// job must not leave stale rows under destructive actions.
    func refreshIfStale(olderThan threshold: TimeInterval = 15) {
        guard !isLoading, let listedAt, Date().timeIntervalSince(listedAt) > threshold else {
            return
        }
        refreshCurrent()
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
        guard let settings = currentSettings() else {
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
        serverFilterTask?.cancel()
        // A refresh keeps searching the whole folder on the server while the
        // listing is capped; a navigation starts unfiltered.
        let needsServerFilter = listing.map { $0.truncated || !$0.filter.isEmpty } ?? false
        let filter = !resetFilter && needsServerFilter ? filterText : ""
        loadGeneration += 1
        let generation = loadGeneration
        let includeHidden = showHidden
        startWork { [self] in
            do {
                let result = try await service.listDirectory(
                    settings: settings,
                    path: path,
                    showHidden: includeHidden,
                    filter: filter
                )
                guard generation == loadGeneration else {
                    return
                }
                commitHistory(intent: intent, loadedPath: path)
                listing = result
                listedAt = Date()
                hasLoadedOnce = true
                isLoading = false
                // Drop selected ids that are gone or hidden after a refresh.
                selection.formIntersection(Set(visibleEntries.map(\.id)))
                runDeferredRefresh()
                scheduleServerFilter()
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
                runDeferredRefresh()
            }
        }
    }

    private func runDeferredRefresh() {
        guard refreshAfterLoad else {
            return
        }
        refreshAfterLoad = false
        refreshCurrent()
    }

    // MARK: Mutations

    /// Entries an action may touch: never a row with a mutation already in
    /// flight, and never one whose name the app cannot spell exactly.
    private func actionable(_ entries: [RemoteFileEntry], verb: String) -> [RemoteFileEntry] {
        if let lossy = entries.first(where: \.nameIsLossy) {
            showError(
                "Cannot \(verb) “\(lossy.name)” on \(clusterName): its name is not valid UTF-8, so the app "
                    + "cannot name it exactly. Rename it in the Terminal first (ls -b shows the raw name)."
            )
            return []
        }
        return entries.filter { !pendingPaths.contains($0.path) }
    }

    private func beginPending(_ paths: [String]) {
        pendingPaths.formUnion(paths)
    }

    private func endPending(_ paths: [String]) {
        pendingPaths.subtract(paths)
    }

    func mkdir(name: String) {
        guard !currentPath.isEmpty else {
            return
        }
        if let issue = Self.validateName(name) {
            showError("Cannot create that folder on \(clusterName) — \(issue)")
            return
        }
        guard let settings = currentSettings() else {
            return
        }
        let path = Self.join(currentPath, name.trimmingCharacters(in: .whitespacesAndNewlines))
        performMutation(paths: [path], failurePrefix: "New folder on \(clusterName) failed") { [service] in
            try await service.createDirectory(settings: settings, path: path)
        }
    }

    func rename(entry: RemoteFileEntry, to newName: String) {
        if let issue = Self.validateName(newName) {
            showError("Cannot rename “\(entry.name)” on \(clusterName) — \(issue)")
            return
        }
        guard !actionable([entry], verb: "rename").isEmpty, let settings = currentSettings() else {
            return
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = (entry.path as NSString).deletingLastPathComponent
        let destination = Self.join(parent, trimmed)
        guard destination != entry.path else {
            return
        }
        performMutation(paths: [entry.path], failurePrefix: "Rename on \(clusterName) failed") { [service] in
            try await service.rename(settings: settings, from: entry.path, to: destination)
        }
    }

    private func performMutation(
        paths: [String],
        failurePrefix: String,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        beginPending(paths)
        startWork { [self] in
            do {
                try await operation()
            } catch {
                showError("\(failurePrefix) — \(error.localizedDescription)")
            }
            endPending(paths)
            refreshCurrent()
        }
    }

    // MARK: Trash

    /// Soft delete: the service moves paths into per-operation server-side
    /// `<trashDirectoryName>/<timestamp>-<id>/` folders (same-filesystem
    /// whenever possible, so nothing is copied into the shared home quota)
    /// and reports where every item went. When a quota copy would be
    /// required, the service throws and the request parks in
    /// `pendingQuotaTrash` for user confirmation.
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
        let targets = actionable(entries, verb: "move to the trash")
        guard !targets.isEmpty, let settings = currentSettings() else {
            return
        }
        if let inTrash = targets.first(where: { RemoteFileService.isInsideTrash($0.path) }) {
            showError(
                "“\(inTrash.name)” is already in the trash on \(clusterName). "
                    + "Use Delete Permanently (or Empty in the Trash sheet) to remove it for good."
            )
            return
        }
        let paths = targets.map(\.path)
        let roots = protectedRoots()
        let name = clusterName
        beginPending(paths)
        startWork { [self] in
            do {
                let outcome = try await service.moveToTrash(
                    settings: settings,
                    paths: paths,
                    protectedRoots: roots,
                    allowQuotaCopy: allowQuotaCopy
                )
                handleTrashOutcome(outcome, requested: paths, settings: settings, clusterName: name)
            } catch let needsConfirmation as RemoteFileService.QuotaCopyConfirmationRequired {
                // Nothing was moved — ask before copying into the home quota.
                endPending(paths)
                // Confirming runs with the session's settings at that moment;
                // if the account or host changed meanwhile, those would no
                // longer be the settings these paths were listed under.
                guard isCurrent(ConnectionIdentity(settings)) else {
                    showError("Move to trash on \(name) was cancelled — the connection changed. Nothing was moved.")
                    return
                }
                pendingQuotaTrash = PendingQuotaTrash(
                    entries: targets,
                    affectedPaths: needsConfirmation.paths,
                    bytes: needsConfirmation.bytes
                )
            } catch {
                endPending(paths)
                showError("Move to trash on \(name) failed — \(error.localizedDescription)")
                refreshCurrent()
            }
        }
    }

    private func handleTrashOutcome(
        _ outcome: TrashOutcome,
        requested: [String],
        settings: ConnectionSettings,
        clusterName name: String
    ) {
        let copying = outcome.copyJob?.paths ?? []
        endPending(requested.filter { !copying.contains($0) })
        selection.subtract(outcome.moved.flatMap(\.paths))
        if let job = outcome.copyJob {
            activity.track(
                job,
                kind: .quotaCopy,
                title: "Copying \(Self.itemCount(job.paths.count)) into \(RemoteFileService.homeTrashDisplayPath)",
                settings: settings,
                clusterName: name
            ) { [weak self] result in
                self?.finishQuotaCopy(job, result: result, clusterName: name)
            }
        }
        let message = Self.trashMessage(outcome, clusterName: name, home: homePath)
        let action: Banner.Action? = outcome.moved.count == 1
            ? .reveal(path: outcome.moved[0].directory)
            : (outcome.moved.isEmpty ? nil : .openTrash)
        if outcome.failed.isEmpty {
            showInfo(message, persistent: true, action: action)
        } else {
            showError(message, action: action)
        }
        refreshCurrent()
        trash.reloadIfLoaded()
    }

    /// "Moved 3 items on Calder to ~/.aire-trash/…; 1 could not be moved:
    /// x (permission denied)". Says where every moved item went, even when
    /// some failed, and what is still being copied.
    nonisolated static func trashMessage(_ outcome: TrashOutcome, clusterName: String, home: String?) -> String {
        let displayPath = { (path: String) in Self.displayPath(path, home: home) }
        var parts: [String] = []
        if outcome.moved.count == 1, let only = outcome.moved.first {
            parts.append("Moved \(itemCount(only.paths.count)) on \(clusterName) to \(displayPath(only.directory))")
        } else if !outcome.moved.isEmpty {
            let places = outcome.moved
                .map { "\($0.paths.count) to \(displayPath($0.directory))" }
                .joined(separator: ", ")
            parts.append("Moved \(itemCount(outcome.movedCount)) on \(clusterName) to the trash: \(places)")
        }
        if let job = outcome.copyJob {
            parts.append(
                "copying \(itemCount(job.paths.count)) into \(RemoteFileService.homeTrashDisplayPath) in the background"
            )
        }
        if !outcome.failed.isEmpty {
            parts.append("\(outcome.failed.count) could not be moved: \(failureSummary(outcome.failed))")
        }
        if parts.isEmpty {
            return "Nothing was moved on \(clusterName)."
        }
        var message = parts.joined(separator: "; ")
        message = message.prefix(1).uppercased() + message.dropFirst()
        return message + "."
    }

    nonisolated static func failureSummary(_ failures: [TrashOutcome.Failure], limit: Int = 3) -> String {
        var text = failures.prefix(limit)
            .map { "\(($0.path as NSString).lastPathComponent) (\($0.reason))" }
            .joined(separator: "; ")
        if failures.count > limit {
            text += "; and \(failures.count - limit) more"
        }
        return text
    }

    nonisolated static func itemCount(_ count: Int) -> String {
        "\(count) item\(count == 1 ? "" : "s")"
    }

    /// A path with the resolved home shown as "~".
    func displayPath(_ path: String) -> String {
        Self.displayPath(path, home: homePath)
    }

    nonisolated static func displayPath(_ path: String, home: String?) -> String {
        guard let home, home != "/" else {
            return path
        }
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func finishQuotaCopy(_ job: RemoteJob, result: FileActivity.OperationResult, clusterName name: String) {
        endPending(job.paths)
        let destination = job.destination.map { displayPath($0) } ?? RemoteFileService.homeTrashDisplayPath
        switch result {
        case .finished(let status):
            let report = Self.quotaCopyReport(status, clusterName: name, destination: destination)
            let action: Banner.Action? = status.moved.isEmpty ? nil : job.destination.map { .reveal(path: $0) }
            if report.isError {
                showError(report.message, action: action)
            } else {
                showInfo(report.message, persistent: true, action: action)
            }
        case .crashed(let detail):
            showError("Copy into the home trash on \(name) stopped unexpectedly (\(detail)). Check \(destination) and the original folder.")
        case .lost(let detail):
            showError("Lost track of the copy into the home trash on \(name) (\(detail)). It may still be running there — refresh later to check.")
        }
        refreshCurrent()
        trash.reloadIfLoaded()
    }

    /// Banner for a copy into the home trash that ran to its end. After a
    /// Cancel, the item the copy was working on is reported "cancelled" and
    /// left where it was, which "the rest were not moved" already says; any
    /// other failure is still listed and makes the banner an error — above
    /// all an original that was copied but could not be fully removed, so
    /// it looks intact while the only complete copy is in the trash.
    nonisolated static func quotaCopyReport(
        _ status: RemoteJobStatus,
        clusterName name: String,
        destination: String
    ) -> (message: String, isError: Bool) {
        let copied = status.moved.count
        if status.cancelled {
            let problems = status.failed.filter { $0.reason != "cancelled" }
            var message = "Copy into the home trash on \(name) was cancelled after \(itemCount(copied)); "
                + "those are in \(destination), the rest were not moved"
            if !problems.isEmpty {
                message += "; \(problems.count) did not finish cleanly: \(failureSummary(problems))"
            }
            return (message + ".", !problems.isEmpty)
        }
        var message = "Copied \(itemCount(copied)) on \(name) into \(destination)"
        if !status.failed.isEmpty {
            message += "; \(status.failed.count) could not be moved: \(failureSummary(status.failed))"
        }
        return (message + ".", !status.failed.isEmpty)
    }

    // MARK: Permanent delete

    /// Hard delete, only reachable through the doubly-confirmed UI path.
    /// Runs as a detached job on the login node: a large tree takes as long
    /// as it takes, the job keeps going if the app quits, and the strip shows
    /// progress with Cancel instead of a misleading timeout.
    func deleteForever(entries: [RemoteFileEntry]) {
        let targets = actionable(entries, verb: "delete")
        guard !targets.isEmpty else {
            return
        }
        startDelete(paths: targets.map(\.path), title: "Deleting \(Self.itemCount(targets.count))", onFinish: nil)
    }

    /// Shared by Delete Permanently and the Trash sheet's Empty.
    func startDelete(paths: [String], title: String, onFinish: (@MainActor () -> Void)?) {
        guard !paths.isEmpty, let settings = currentSettings() else {
            return
        }
        let roots = protectedRoots()
        let name = clusterName
        beginPending(paths)
        startWork { [self] in
            do {
                let job = try await service.startPermanentDelete(settings: settings, paths: paths, protectedRoots: roots)
                activity.track(job, kind: .delete, title: title, settings: settings, clusterName: name) { [weak self] result in
                    self?.finishDelete(job, result: result, clusterName: name)
                    onFinish?()
                }
            } catch {
                endPending(paths)
                showError("Permanent delete on \(name) failed — \(error.localizedDescription)")
                refreshCurrent()
                onFinish?()
            }
        }
    }

    private func finishDelete(_ job: RemoteJob, result: FileActivity.OperationResult, clusterName name: String) {
        endPending(job.paths)
        switch result {
        case .finished(let status):
            let deleted = max(0, status.done - status.failed.count)
            if status.cancelled {
                showInfo(
                    "Permanent delete on \(name) was cancelled. Items already removed are gone; the rest are untouched "
                        + "(the item being deleted at that moment may be partly removed).",
                    persistent: true
                )
            } else if status.failed.isEmpty {
                selection.subtract(job.paths)
                showInfo("Permanently deleted \(Self.itemCount(deleted)) on \(name).", persistent: true)
            } else {
                selection.subtract(job.paths.filter { path in !status.failed.contains { $0.path == path } })
                showError(
                    "Permanently deleted \(Self.itemCount(deleted)) on \(name); \(status.failed.count) could not be "
                        + "deleted: \(Self.failureSummary(status.failed))."
                )
            }
        case .crashed(let detail):
            showError("Permanent delete on \(name) stopped unexpectedly (\(detail)). Refresh to see what is left.")
        case .lost(let detail):
            showError("Lost track of the permanent delete on \(name) (\(detail)). It may still be running there — refresh later to check.")
        }
        refreshCurrent()
    }

    // MARK: Transfers

    func download(entries: [RemoteFileEntry]) {
        let candidates = actionable(entries, verb: "download")
        guard let settings = currentSettings() else {
            return
        }
        let files = candidates.filter(\.isDownloadable)
        guard !files.isEmpty else {
            if !entries.contains(where: \.nameIsLossy) {
                showError("Select files to download from \(clusterName) — folders, pipes and sockets cannot be downloaded.")
            }
            return
        }
        let skipped = activity.enqueueDownloads(files, settings: settings, clusterName: clusterName)
        if !skipped.isEmpty {
            showInfo("Already downloading \(ListFormatter.localizedString(byJoining: skipped)) from \(clusterName).")
        }
    }

    func upload(urls: [URL]) {
        guard !currentPath.isEmpty else {
            showError("Open a folder on \(clusterName) before uploading.")
            return
        }
        guard let settings = currentSettings() else {
            return
        }
        let skipped = activity.enqueueUploads(urls, remoteDirectory: currentPath, settings: settings, clusterName: clusterName)
        if !skipped.isEmpty {
            showInfo(
                "Already uploading \(ListFormatter.localizedString(byJoining: skipped)) to \(currentPath) on \(clusterName)."
            )
        }
    }

    // MARK: Preview

    func preview(entry: RemoteFileEntry, mode: RemotePreviewMode? = nil) {
        guard !actionable([entry], verb: "preview").isEmpty, let settings = currentSettings() else {
            return
        }
        let chosenMode = mode ?? RemotePreviewMode.preferred(forFileName: entry.name)
        if var current = activePreview, current.entry.path == entry.path, case .text = current.content {
            current.mode = chosenMode
            current.isReloading = true
            activePreview = current
        } else {
            activePreview = PreviewState(entry: entry, mode: chosenMode, content: .loading)
        }
        previewGeneration += 1
        let generation = previewGeneration
        startWork { [self] in
            let outcome: PreviewContent
            do {
                switch try await service.preview(
                    settings: settings,
                    path: entry.path,
                    maxBytes: Self.previewMaxBytes,
                    mode: chosenMode
                ) {
                case .text(let text):
                    outcome = .text(text)
                case .binary(let mimeType):
                    outcome = .binary(mimeType: mimeType)
                }
            } catch {
                outcome = .failure(error.localizedDescription)
            }
            // The sheet may have moved on to another file or mode (or
            // closed) while the preview was in flight.
            guard generation == previewGeneration, activePreview?.entry.path == entry.path else {
                return
            }
            activePreview?.content = outcome
            activePreview?.isReloading = false
        }
    }

    // MARK: Folder size

    func requestDiskUsage(for entry: RemoteFileEntry) {
        guard !actionable([entry], verb: "measure").isEmpty, let settings = currentSettings() else {
            return
        }
        diskUsageResult = DiskUsageResult(path: entry.path, summary: "Calculating…", isPending: true)
        let name = clusterName
        startWork { [self] in
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

    // MARK: Banners

    /// Errors stay until dismissed by default.
    func showError(_ message: String, persistent: Bool = true, action: Banner.Action? = nil) {
        present(Banner(message: message, style: .error, action: action, persistent: persistent))
    }

    /// Plain confirmations ("Copied the path") fade after a few seconds;
    /// results that describe what happened to data pass `persistent: true`.
    func showInfo(_ message: String, persistent: Bool = false, action: Banner.Action? = nil) {
        present(Banner(message: message, style: .info, action: action, persistent: persistent))
    }

    func dismissBanner() {
        bannerDismissTask?.cancel()
        banner = nil
    }

    func perform(_ action: Banner.Action) {
        switch action {
        case .reveal(let path):
            reveal(path: path)
        case .openTrash:
            isTrashPresented = true
        }
    }

    private func present(_ newBanner: Banner) {
        bannerDismissTask?.cancel()
        banner = newBanner
        guard !newBanner.persistent else {
            return
        }
        let id = newBanner.id
        bannerDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.bannerDismissDelay)
            guard !Task.isCancelled, let self, self.banner?.id == id else {
                return
            }
            self.banner = nil
        }
    }

    // MARK: Path helpers

    /// Drops trailing slashes (except the root itself). Whitespace is kept:
    /// remote names may legitimately end in spaces, and trimming would open
    /// the parent instead of a directory called "data ". A whitespace-only
    /// input becomes "" so callers reject it. Deliberately does NOT collapse
    /// `..` — the remote side resolves paths.
    nonisolated static func normalize(_ path: String) -> String {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        var normalized = path
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    nonisolated static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/\(name)" : "\(directory)/\(name)"
    }

    /// Validates a user-entered file or folder name (mkdir / rename). The
    /// service layer quotes everything anyway; this exists to give friendly
    /// feedback before a doomed remote round-trip. Rejects the C0 and C1
    /// control characters (tab, ESC, DEL…) but not Unicode format characters
    /// such as the zero-width joiner, which emoji sequences need.
    nonisolated static func validateName(_ name: String) -> String? {
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
        if trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }) {
            return "Names cannot contain newlines or control characters."
        }
        return nil
    }
}
