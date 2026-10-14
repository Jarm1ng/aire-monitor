import HPCCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Files tab: a Finder-like browser over ONE cluster's live SSH session.
/// Rendered outside the shared dashboard ScrollView (like the terminal)
/// because the table manages its own scrolling. All state that must survive
/// tab and sidebar switches lives in the session's `FileBrowserModel`; the
/// @State here is transient dialog plumbing only.
///
/// Every place a path is acted on (dialogs, drop target, preview, banners)
/// names the cluster: home is the same /users directory on every cluster,
/// but scratch and flash are not, and an upload or delete aimed at the wrong
/// cluster is exactly the mistake a multi-cluster browser must prevent.
struct FilesDashboard: View {
    @ObservedObject var session: ClusterSession
    @ObservedObject var files: FileBrowserModel
    /// Wired by ClusterDashboardView: switches this cluster's dashboard to
    /// the terminal tab and opens a shell landing in the given directory.
    var onOpenShellAt: (@MainActor (String) -> Void)? = nil
    /// Wired by ClusterDashboardView: switches to the terminal tab and opens
    /// vim on the given file over this cluster's session.
    var onOpenVim: (@MainActor (String) -> Void)? = nil

    @State private var showNewFolderSheet = false
    @State private var renameTarget: RemoteFileEntry?
    @State private var showUploadImporter = false
    @State private var trashCandidates: [RemoteFileEntry] = []
    @State private var showTrashConfirmation = false
    @State private var deleteCandidates: [RemoteFileEntry] = []
    @State private var showDeleteStepOne = false
    @State private var showDeleteStepTwo = false
    @State private var isDropTargeted = false
    @Environment(\.colorScheme) private var colorScheme

    /// Margin kept free in home when deciding whether a quota copy fits:
    /// a full home quota breaks logins, shells and jobs on every cluster.
    private static let homeSafetyMargin: Int64 = 1_000_000_000

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(
                title: "Files",
                subtitle: "Browse and manage your \(clusterName) files over its live SSH session",
                systemImage: "folder",
                accent: .orange
            ) {
                headerActions
            }

            toolbarRow
            shortcutRow
            bannerRow

            content

            FileActivityStrip(activity: files.activity)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(AppTheme.smoothEase, value: files.banner)
        // ContentView keys each cluster's dashboard by cluster id, so this
        // also runs on every sidebar switch to this cluster.
        .onAppear {
            files.reconcileConnectionIdentity()
            openHomeIfFirstVisit()
            // Coming back to the tab: files may have changed in the
            // terminal or under a running job since this was listed.
            files.refreshIfStale()
        }
        .onChange(of: session.isLoggedIn) { _ in
            // A sign-in may be under a new account or host: drop the old
            // identity's folder first. Connecting while the tab is open then
            // lands in Home without an extra click, exactly as opening the
            // tab on a live session does.
            files.reconcileConnectionIdentity()
            openHomeIfFirstVisit()
        }
        .sheet(isPresented: $showNewFolderSheet) {
            NameEntrySheet(
                title: "New Folder",
                prompt: "Create a folder in \(files.currentPath) on \(clusterName)",
                confirmLabel: "Create",
                initialName: ""
            ) { name in
                files.mkdir(name: name)
            }
        }
        .sheet(item: $renameTarget) { entry in
            NameEntrySheet(
                title: "Rename",
                prompt: "Rename “\(entry.name)”",
                confirmLabel: "Rename",
                initialName: entry.name
            ) { name in
                files.rename(entry: entry, to: name)
            }
        }
        .sheet(item: $files.activePreview) { preview in
            FilePreviewSheet(
                files: files,
                activity: files.activity,
                profile: session.profile,
                entry: preview.entry,
                onOpenVim: onOpenVim,
                onOpenPager: { path in
                    openPager(for: path)
                }
            )
        }
        .sheet(isPresented: $files.isTrashPresented) {
            TrashSheet(files: files, trash: files.trash, profile: session.profile)
        }
        .fileImporter(
            isPresented: $showUploadImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                files.upload(urls: urls)
            }
        }
        .confirmationDialog(
            trashDialogTitle,
            isPresented: $showTrashConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                files.trash(entries: trashCandidates)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(trashDialogMessage)
        }
        .confirmationDialog(
            "Copy \(clusterName) items into your shared home quota?",
            isPresented: quotaTrashDialogBinding,
            titleVisibility: .visible,
            presenting: files.pendingQuotaTrash
        ) { pending in
            if quotaCopyBlocker(pending) == nil {
                Button(quotaCopyButtonTitle(pending), role: .destructive) {
                    files.confirmQuotaTrash(pending)
                }
            }
            Button("Delete Permanently…", role: .destructive) {
                files.cancelQuotaTrash()
                beginDelete(pending.entries)
            }
            Button("Cancel", role: .cancel) {
                files.cancelQuotaTrash()
            }
        } message: { pending in
            Text(quotaTrashMessage(pending))
        }
        .confirmationDialog(
            "Permanently delete \(FileBrowserModel.itemCount(deleteCandidates.count)) on \(clusterName)?",
            isPresented: $showDeleteStepOne,
            titleVisibility: .visible
        ) {
            Button("Continue…", role: .destructive) {
                showDeleteStepTwo = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This skips the server-side trash (\(RemoteFileService.trashDirectoryName)). "
                    + "You will be asked to confirm once more."
            )
        }
        .confirmationDialog(
            "This cannot be undone",
            isPresented: $showDeleteStepTwo,
            titleVisibility: .visible
        ) {
            Button(
                "Delete \(FileBrowserModel.itemCount(deleteCandidates.count)) permanently",
                role: .destructive
            ) {
                files.deleteForever(entries: deleteCandidates)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteStepTwoMessage)
        }
    }

    private var clusterName: String {
        session.displayName
    }

    private func openHomeIfFirstVisit() {
        if !files.hasLoadedOnce, !files.isLoading, session.isLoggedIn {
            files.openHome()
        }
    }

    /// Files preview → terminal: pages the file from its end with less
    /// over this cluster's session. The path is untrusted listing data and
    /// is single-quoted before interpolation.
    private func openPager(for path: String) {
        withAnimation(AppTheme.softSpring) {
            session.dashboard.selectedTab = .terminal
        }
        session.terminals.open(
            command: "less +G -- \(SSHTerminalCommand.shellQuote(path))",
            title: "less \((path as NSString).lastPathComponent)",
            settings: session.settings
        )
    }

    // MARK: Header actions

    private var headerActions: some View {
        HStack(spacing: 10) {
            if files.isMutating {
                ProgressView()
                    .controlSize(.small)
                    .help("Changes in progress on \(clusterName)")
                    .accessibilityLabel("Changes in progress")
            }

            Button {
                files.isTrashPresented = true
            } label: {
                Label("Trash", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(!session.isLoggedIn)
            .help("Review, restore and empty what you moved to the trash on \(clusterName)")

            Button {
                showNewFolderSheet = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)
            .disabled(files.currentPath.isEmpty)
            .help("Create a folder in the current \(clusterName) directory")

            Button {
                showUploadImporter = true
            } label: {
                Label("Upload", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .disabled(files.currentPath.isEmpty)
            .help("Upload local files to the current \(clusterName) directory")
        }
    }

    // MARK: Toolbar

    private var toolbarRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Button {
                    files.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!files.canGoBack)
                .help("Back")
                .accessibilityLabel("Back")

                Button {
                    files.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!files.canGoForward)
                .help("Forward")
                .accessibilityLabel("Forward")
            }
            .buttonStyle(.bordered)

            BreadcrumbView(path: files.currentPath) { path in
                files.navigate(to: path)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            searchField

            Toggle(isOn: $files.showHidden) {
                Image(systemName: files.showHidden ? "eye" : "eye.slash")
            }
            .toggleStyle(.button)
            .help(files.showHidden ? "Hide hidden files" : "Show hidden files")
            .accessibilityLabel("Show hidden files")

            Button {
                files.refreshCurrent()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(files.currentPath.isEmpty || files.isLoading)
            .help("Refresh listing")
            .accessibilityLabel("Refresh listing")
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Filter", text: $files.filterText)
                .textFieldStyle(.plain)
                .font(.callout)
                .frame(width: 140)
            if files.isAwaitingServerFilter {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Searching the whole folder")
            }
            if !files.filterText.isEmpty {
                Button {
                    files.filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().stroke(AppTheme.border, lineWidth: 1))
        .help(
            files.listing?.truncated == true
                ? "Filter searches the whole folder on \(clusterName), not just the entries shown"
                : "Filter the entries shown by name"
        )
        .accessibilityLabel("Filter listing")
    }

    @ViewBuilder
    private var shortcutRow: some View {
        let shortcuts = files.shortcuts
        if !shortcuts.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(shortcuts) { shortcut in
                        ShortcutChip(
                            label: shortcut.label,
                            systemImage: shortcut.icon,
                            isCurrent: shortcut.path == files.currentPath
                        ) {
                            files.navigate(to: shortcut.path)
                        }
                        .help(shortcut.detail)
                        .accessibilityHint(shortcut.detail)
                    }
                }
                .padding(.vertical, 1)
            }
            .accessibilityLabel("\(clusterName) location shortcuts")
        }
    }

    @ViewBuilder
    private var bannerRow: some View {
        if let banner = files.banner {
            FilesBanner(
                message: banner.message,
                isError: banner.isError,
                actionTitle: banner.action.map(Self.actionTitle),
                onAction: {
                    if let action = banner.action {
                        files.perform(action)
                    }
                },
                onDismiss: {
                    files.dismissBanner()
                }
            )
        }
    }

    private static func actionTitle(_ action: FileBrowserModel.Banner.Action) -> String {
        switch action {
        case .reveal:
            return "Show"
        case .openTrash:
            return "Open Trash"
        }
    }

    // MARK: Main content

    @ViewBuilder
    private var content: some View {
        if !files.hasLoadedOnce && !files.isLoading {
            FilesHero(
                profile: session.profile,
                state: session.connectionState,
                isLoggedIn: session.isLoggedIn,
                spacesSummary: spacesSummary
            ) {
                files.openHome()
            }
        } else {
            tableArea
        }
    }

    private var tableArea: some View {
        fileTable
            .overlay {
                if files.isLoading && !files.isAwaitingServerFilter {
                    loadingOverlay
                } else if files.visibleEntries.isEmpty {
                    emptyListingOverlay
                }
            }
            .overlay {
                if isDropTargeted {
                    dropOverlay
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
            .onDeleteCommand {
                beginTrash(files.selectedEntries)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .dashboardCard(padding: 8, accent: .orange)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileTable: some View {
        Table(files.visibleEntries, selection: $files.selection, sortOrder: $files.sortOrder) {
            TableColumn("Name", value: \.sortName) { entry in
                FileNameCell(entry: entry, isPending: files.pendingPaths.contains(entry.path))
            }
            .width(min: 200, ideal: 340)

            TableColumn("Size", value: \.sortSize) { entry in
                Text(FileDisplay.sizeText(entry))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 84)

            TableColumn("Modified", value: \.sortModified) { entry in
                Text(FileDisplay.modifiedText(entry.modifiedAt))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help(FileDisplay.modifiedTooltip(entry.modifiedAt))
            }
            .width(min: 90, ideal: 130)

            TableColumn("Owner", value: \.sortOwner) { entry in
                Text(entry.owner ?? missingValuePlaceholder)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 90)

            TableColumn("Mode", value: \.sortMode) { entry in
                Text(entry.permissions ?? missingValuePlaceholder)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 96)
        }
        .contextMenu(forSelectionType: RemoteFileEntry.ID.self) { ids in
            contextMenuItems(for: ids)
        } primaryAction: { ids in
            handleDoubleClick(ids)
        }
    }

    private var loadingOverlay: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Listing \(files.currentPath) on \(clusterName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(AppTheme.border, lineWidth: 1))
        .transition(.opacity)
        .accessibilityLabel("Loading \(clusterName) directory listing")
    }

    private var emptyListingOverlay: some View {
        VStack(spacing: 8) {
            Image(systemName: files.filterText.isEmpty ? "folder" : "magnifyingglass")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
            Text(emptyTitle)
                .font(.headline)
            Text(emptySubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    /// A capped listing only holds the first entries, so "No matches" is
    /// only ever stated once the server has searched the whole folder.
    private var emptyTitle: String {
        if files.filterText.isEmpty {
            return "This folder is empty"
        }
        if files.isAwaitingServerFilter, let listing = files.listing {
            return "Searching all \(listing.totalCount.formatted()) entries…"
        }
        return "No matches for “\(files.filterText)”"
    }

    private var emptySubtitle: String {
        if files.filterText.isEmpty {
            return "Drop files here to upload them, or create a folder."
        }
        if files.isAwaitingServerFilter {
            return "This folder has more entries than are shown, so the filter searches it on \(clusterName)."
        }
        if let listing = files.listing, !listing.filter.isEmpty {
            return "Searched every entry in this folder on \(clusterName). Try a different filter, or clear it."
        }
        return "Try a different filter, or clear it to see everything."
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.orange.opacity(0.10))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            }
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 30, weight: .medium))
                    Text("Drop to upload to \(files.currentPath) on \(clusterName)")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(Color.orange.legibleText(in: colorScheme))
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    // MARK: Footer

    /// The footer's item count. A capped listing says so in orange, and that
    /// line is the only sign the folder holds more than is shown, so it uses
    /// the legible text shade: a plain system orange caption measures about
    /// 2:1 on the light window background (and plain `.secondary` about 4:1).
    static func itemsSummaryColor(truncated: Bool, in scheme: ColorScheme) -> Color {
        (truncated ? Color.orange : Color.secondary).legibleText(in: scheme)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if files.listing != nil {
                Text(itemsSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Self.itemsSummaryColor(truncated: files.listing?.truncated == true, in: colorScheme))
                    .help(itemsHelp)
            }

            if let listedAt = files.listedAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("listed \(FileDisplay.relativeText(listedAt, now: context.date))")
                        .font(.caption)
                        .foregroundStyle(Color.secondary.legibleText(in: colorScheme))
                }
                .help("When this listing was fetched from \(clusterName). Refresh to update it.")
            }

            if let listing = files.listing,
               !listing.resolvedPath.isEmpty,
               listing.resolvedPath != listing.requestedPath {
                Text("resolves to \(listing.resolvedPath)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if let usage = files.diskUsageResult {
                diskUsageChip(usage)
            }
        }
        .frame(minHeight: 20)
    }

    /// Counts that never pretend a capped listing is complete.
    private var itemsSummary: String {
        guard let listing = files.listing else {
            return FileBrowserModel.itemCount(0)
        }
        let shown = files.visibleEntries.count
        let selected = files.selection.count
        var text: String
        if files.isAwaitingServerFilter {
            let total = listing.filter.isEmpty ? listing.totalCount : max(listing.totalCount, listing.matchedCount)
            text = "Searching all \(total.formatted()) entries on \(clusterName)…"
        } else if listing.truncated {
            if listing.filter.isEmpty {
                text = "Showing \(shown.formatted()) of \(listing.totalCount.formatted()) — type in Filter to search all"
            } else {
                text = "Showing \(shown.formatted()) of \(listing.matchedCount.formatted()) matches"
            }
        } else if !files.filterText.isEmpty {
            let total = listing.filter.isEmpty ? listing.entries.count : listing.totalCount
            text = "\(shown.formatted()) of \(FileBrowserModel.itemCount(total))"
        } else {
            text = FileBrowserModel.itemCount(shown)
        }
        if selected > 0 {
            text += " (\(selected) selected)"
        }
        return text
    }

    private var itemsHelp: String {
        guard let listing = files.listing, listing.truncated else {
            return "Entries in this folder"
        }
        return "Only the first \(RemoteFileService.entryCap.formatted()) entries (folders first, then by name) are "
            + "listed. Typing in Filter searches all \(listing.totalCount.formatted()) on \(clusterName)."
    }

    private func diskUsageChip(_ usage: FileBrowserModel.DiskUsageResult) -> some View {
        HStack(spacing: 6) {
            if usage.isPending {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: "internaldrive")
                    .font(.caption2)
            }
            Text("\((usage.path as NSString).lastPathComponent): \(usage.summary)")
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                files.dismissDiskUsage()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss folder size")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().stroke(AppTheme.border, lineWidth: 1))
        .help(usage.path)
        .transition(.opacity)
    }

    // MARK: Context menu / actions

    /// Right-clicking inside the current selection acts on all of it;
    /// right-clicking elsewhere acts on the clicked row only.
    private func contextTargets(for ids: Set<RemoteFileEntry.ID>) -> [RemoteFileEntry] {
        files.entries(withIDs: ids)
    }

    @ViewBuilder
    private func contextMenuItems(for ids: Set<RemoteFileEntry.ID>) -> some View {
        let targets = contextTargets(for: ids)
        if targets.isEmpty {
            Button("Refresh") {
                files.refreshCurrent()
            }
            Button("New Folder…") {
                showNewFolderSheet = true
            }
            if !files.currentPath.isEmpty {
                Button("Open Shell Here") {
                    onOpenShellAt?(files.currentPath)
                }
                .disabled(onOpenShellAt == nil)
            }
        } else if targets.contains(where: \.nameIsLossy) {
            Button("Copy Path") {
                if let entry = targets.first {
                    copyPath(entry)
                }
            }
            Text("Name is not valid UTF-8 — rename it in the Terminal")
        } else {
            let actionable = targets.filter { !files.isPending($0) }
            Button("Open") {
                openEntries(targets)
            }
            if targets.count == 1, let entry = targets.first {
                if entry.isPreviewable {
                    Button("Preview") {
                        files.preview(entry: entry)
                    }
                }
                // Trash runs are managed in the Trash sheet: a renamed run
                // (or .aire-trash folder) would only show there as missing
                // until it is renamed back.
                if !RemoteFileService.isInsideTrash(entry.path) {
                    Button("Rename…") {
                        renameTarget = entry
                    }
                    .disabled(actionable.isEmpty)
                }
                Button("Copy Path") {
                    copyPath(entry)
                }
                if entry.isDirectoryLike {
                    Button("Folder Size") {
                        files.requestDiskUsage(for: entry)
                    }
                    Button("Open Shell Here") {
                        onOpenShellAt?(entry.path)
                    }
                    .disabled(onOpenShellAt == nil)
                }
            }
            if targets.contains(where: \.isDownloadable) {
                Button("Download") {
                    files.download(entries: targets)
                }
            }
            Divider()
            if !targets.contains(where: { RemoteFileService.isInsideTrash($0.path) }) {
                Button("Move to Trash", role: .destructive) {
                    beginTrash(targets)
                }
                .disabled(actionable.isEmpty)
            }
            Button("Delete Permanently…", role: .destructive) {
                beginDelete(targets)
            }
            .disabled(actionable.isEmpty)
        }
    }

    private func handleDoubleClick(_ ids: Set<RemoteFileEntry.ID>) {
        let targets = contextTargets(for: ids)
        guard targets.count == 1, let entry = targets.first else {
            return
        }
        openEntries([entry])
    }

    private func openEntries(_ entries: [RemoteFileEntry]) {
        guard let entry = entries.first else {
            return
        }
        if entry.isNavigable {
            files.navigate(to: entry.path)
        } else if entry.isPreviewable {
            files.preview(entry: entry)
        } else {
            files.showInfo("“\(entry.name)” is a pipe, socket or device — there is nothing to open.")
        }
    }

    private func copyPath(_ entry: RemoteFileEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.path, forType: .string)
        files.showInfo("Copied the \(clusterName) path \(entry.path) to the clipboard")
    }

    /// Rows with a mutation already in flight are left out, so a second
    /// Delete cannot start another trash of items that are still moving.
    private func beginTrash(_ entries: [RemoteFileEntry]) {
        let targets = entries.filter { !files.isPending($0) }
        guard !targets.isEmpty else {
            return
        }
        if targets.contains(where: { RemoteFileService.isInsideTrash($0.path) }) {
            // Same refusal (and wording) as the model, before any dialog.
            files.trash(entries: targets)
            return
        }
        trashCandidates = targets
        showTrashConfirmation = true
    }

    private func beginDelete(_ entries: [RemoteFileEntry]) {
        let targets = entries.filter { !files.isPending($0) }
        guard !targets.isEmpty else {
            return
        }
        deleteCandidates = targets
        showDeleteStepOne = true
    }

    private var trashDialogTitle: String {
        if trashCandidates.count == 1, let first = trashCandidates.first {
            return "Move “\(first.name)” to trash?"
        }
        return "Move \(trashCandidates.count) items to trash?"
    }

    /// Multi-item confirmations name what they act on — the selection may
    /// include rows scrolled away or (before pruning) filtered out, so the
    /// count alone is not enough to know what is being trashed.
    private var trashDialogMessage: String {
        let note = trashLocationNote
        guard trashCandidates.count > 1 else {
            return note
        }
        var names = trashCandidates.prefix(5).map(\.name).joined(separator: ", ")
        if trashCandidates.count > 5 {
            names += ", …"
        }
        return "\(names)\n\(note)"
    }

    /// Where trashed items go, and what they keep costing. Home is one NFS
    /// export shared by every cluster, so the home trash is the same folder
    /// everywhere; everything else is trashed beside itself on its own
    /// filesystem (a rename, never a copy), which keeps counting toward that
    /// filesystem's quota. Clusters whose snapshot reports Lustre PROJECT
    /// quotas (Calder scratch and flash) get that called out by name: the
    /// project quota follows the data, not the folder it sits in.
    private var trashLocationNote: String {
        let trash = RemoteFileService.trashDirectoryName
        var note = "Items move to a \(trash) folder; restore or empty them from Trash in the Files toolbar. "
            + "Home items go to \(RemoteFileService.homeTrashDisplayPath) — one folder seen from "
            + "\(FileBrowserModel.sharedHomeClusterList), because home is shared. "
            + "Items elsewhere are moved, never copied, into a \(trash) folder beside them "
            + "and keep using that filesystem's quota until you empty the trash."
        let projectQuotaSpaces = (session.snapshot?.sortedStorage ?? [])
            .filter { $0.quotaType == "lustre-project" }
            .map(\.label)
        if !projectQuotaSpaces.isEmpty {
            let spaces = ListFormatter.localizedString(byJoining: projectQuotaSpaces)
            let quota = projectQuotaSpaces.count == 1
                ? "has a Lustre project quota, which counts"
                : "have Lustre project quotas, which count"
            note += " On \(clusterName), \(spaces) \(quota) trashed data too."
        }
        return note
    }

    private var deleteStepTwoMessage: String {
        var names = deleteCandidates.prefix(5).map(\.name).joined(separator: ", ")
        if deleteCandidates.count > 5 {
            names += ", …"
        }
        return "On \(clusterName): \(names)"
    }

    /// Presents the quota-copy confirmation whenever the model parks a trash
    /// request; dismissal (Escape / click outside) cancels it. Button
    /// actions use the dialog's `presenting` value, so this setter clearing
    /// the model state can never race them.
    private var quotaTrashDialogBinding: Binding<Bool> {
        Binding(
            get: { files.pendingQuotaTrash != nil },
            set: { isPresented in
                if !isPresented {
                    files.cancelQuotaTrash()
                }
            }
        )
    }

    /// Why the copy cannot be offered, or nil when it fits in home with a
    /// safety margin to spare.
    private func quotaCopyBlocker(_ pending: FileBrowserModel.PendingQuotaTrash) -> String? {
        guard let bytes = pending.bytes else {
            return "Their size could not be measured in time, so copying them into home is not offered."
        }
        guard let available = files.homeAvailableBytes else {
            return "Home's free space is unknown until the next refresh, so copying \(FileDisplay.byteText(bytes)) is not offered."
        }
        if bytes > available - Self.homeSafetyMargin {
            return "\(FileDisplay.byteText(bytes)) would not fit in the \(FileDisplay.byteText(max(0, available))) "
                + "free in home (with \(FileDisplay.byteText(Self.homeSafetyMargin)) kept spare)."
        }
        return nil
    }

    private func quotaCopyButtonTitle(_ pending: FileBrowserModel.PendingQuotaTrash) -> String {
        guard let bytes = pending.bytes else {
            return "Copy to Home Trash"
        }
        return "Copy \(FileDisplay.byteText(bytes)) to Home Trash"
    }

    private func quotaTrashMessage(_ pending: FileBrowserModel.PendingQuotaTrash) -> String {
        let count = pending.affectedPaths.count
        let items = FileBrowserModel.itemCount(count)
        var paths = pending.affectedPaths.prefix(3).joined(separator: "\n")
        if count > 3 {
            paths += "\n…"
        }
        let size = pending.bytes.map { " (\(FileDisplay.byteText($0)))" } ?? ""
        var message = "No \(RemoteFileService.trashDirectoryName) folder could be created beside "
            + "\(items)\(size) on \(clusterName). Moving to trash would copy that data into "
            + "\(RemoteFileService.homeTrashDisplayPath), which counts against your home quota — "
            + "one quota shared by \(FileBrowserModel.sharedHomeClusterList)."
        if let blocker = quotaCopyBlocker(pending) {
            message += " \(blocker) You can skip the trash and delete permanently instead."
        } else {
            message += " You can copy anyway (it runs in the background and can be cancelled), "
                + "or skip the trash and delete permanently."
        }
        return message + "\n\(paths)"
    }

    /// "home, scratch, and flash" for the first-visit hero: the spaces this
    /// cluster actually reported (its location shortcuts), falling back to
    /// the volumes its profile always collects. An optional space, such as
    /// a flash area with no personal directory yet, is named only once the
    /// snapshot shows it exists.
    private var spacesSummary: String {
        var labels = files.shortcuts.map { $0.label.lowercased() }
        if labels.isEmpty {
            labels = session.profile.storage.filter { !$0.optional }.map { $0.label.lowercased() }
        }
        return labels.isEmpty ? "home" : ListFormatter.localizedString(byJoining: labels)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !files.currentPath.isEmpty else {
            return false
        }
        var handled = false
        // Local capture: the provider completion runs off the main actor, so
        // it must not touch the view's main-actor-isolated property.
        let browser = files
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else {
                    return
                }
                Task { @MainActor in
                    browser.upload(urls: [url])
                }
            }
        }
        return handled
    }
}

// MARK: - Display helpers

/// Formatting is main-actor-only so the shared formatters need no locking.
@MainActor
enum FileDisplay {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func sizeText(_ entry: RemoteFileEntry) -> String {
        guard entry.kind != .directory, let size = entry.size, size >= 0 else {
            return missingValuePlaceholder
        }
        return byteFormatter.string(fromByteCount: size)
    }

    static func modifiedText(_ date: Date?) -> String {
        guard let date else {
            return missingValuePlaceholder
        }
        let now = Date()
        // A file written moments ago on a login node whose clock runs a
        // little ahead would read "in 0 sec"; small skews are "just now".
        // A large future offset is real information and stays visible.
        let age = now.timeIntervalSince(date)
        if age < 5 && age > -300 {
            return "just now"
        }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    static func modifiedTooltip(_ date: Date?) -> String {
        guard let date else {
            return "Modification time unavailable"
        }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    /// "just now" for the first minute, then "2 min. ago".
    static func relativeText(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 {
            return "just now"
        }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    static func byteText(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    /// "12.3 MB/s".
    static func rateText(_ bytesPerSecond: Double) -> String {
        byteFormatter.string(fromByteCount: Int64(bytesPerSecond.rounded())) + "/s"
    }
}

// MARK: - Name cell

private struct FileNameCell: View {
    let entry: RemoteFileEntry
    /// A trash, delete, rename or new-folder operation is in flight here.
    let isPending: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: entry.systemIconName)
                .font(.callout)
                .foregroundStyle(iconColor)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(entry.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            if entry.nameIsLossy {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("This name is not valid UTF-8, so the app cannot act on it. Rename it in the Terminal.")
            }
            if entry.kind == .symlink, let target = entry.linkTarget, !target.isEmpty {
                Text("→ \(target)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if isPending {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Change in progress")
            }
        }
        .opacity(isPending ? 0.5 : 1)
        .accessibilityElement(children: .combine)
    }

    private var iconColor: Color {
        switch entry.kind {
        case .directory:
            return .orange
        case .symlink:
            return AppTheme.gpu
        default:
            return .secondary
        }
    }
}

// MARK: - Breadcrumb

private struct BreadcrumbView: View {
    let path: String
    let onNavigate: (String) -> Void

    private struct Crumb: Identifiable, Equatable {
        let label: String
        let path: String
        var id: String { path.isEmpty ? "ellipsis" : path }
    }

    private var crumbs: [Crumb] {
        guard path.hasPrefix("/") else {
            return []
        }
        var result = [Crumb(label: "/", path: "/")]
        var running = ""
        for component in path.split(separator: "/") {
            running += "/\(component)"
            result.append(Crumb(label: String(component), path: running))
        }
        return result
    }

    /// Deep paths keep the root and the last three segments, with a
    /// non-clickable ellipsis standing in for the middle.
    private var displayCrumbs: [Crumb] {
        let all = crumbs
        guard all.count > 6 else {
            return all
        }
        return Array(all.prefix(2)) + [Crumb(label: "…", path: "")] + Array(all.suffix(3))
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                if displayCrumbs.isEmpty {
                    Text("No folder open")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(displayCrumbs) { crumb in
                        crumbView(crumb)
                        if crumb != displayCrumbs.last {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().stroke(AppTheme.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Current path")
        .accessibilityValue(path.isEmpty ? "No folder open" : path)
    }

    @ViewBuilder
    private func crumbView(_ crumb: Crumb) -> some View {
        if crumb.path.isEmpty {
            Text(crumb.label)
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Button {
                onNavigate(crumb.path)
            } label: {
                Text(crumb.label)
                    .font(.callout.monospaced())
                    .foregroundStyle(crumb.path == path ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help(crumb.path)
            .accessibilityLabel("Go to \(crumb.path)")
        }
    }
}

// MARK: - Shortcut chip

private struct ShortcutChip: View {
    let label: String
    let systemImage: String
    let isCurrent: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.caption.weight(isCurrent ? .semibold : .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Color.orange.opacity(isCurrent ? 0.18 : (isHovered ? 0.14 : 0.08)),
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .stroke(
                            isCurrent || isHovered
                                ? Color.orange.opacity(0.35)
                                : AppTheme.chipStroke(for: colorScheme),
                            lineWidth: 1
                        )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(AppTheme.smoothEase, value: isHovered)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Banner

private struct FilesBanner: View {
    let message: String
    let isError: Bool
    let actionTitle: String?
    let onAction: () -> Void
    let onDismiss: () -> Void

    private var color: Color {
        isError ? .red : .green
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption)
                .lineLimit(4)
                .textSelection(.enabled)
                .help(message)
            Spacer(minLength: 6)
            if let actionTitle {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss message")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color.opacity(0.25), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Name entry sheet (rename / new folder)

private struct NameEntrySheet: View {
    let title: String
    let prompt: String
    let confirmLabel: String
    let initialName: String
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var name: String

    init(
        title: String,
        prompt: String,
        confirmLabel: String,
        initialName: String,
        onSubmit: @escaping (String) -> Void
    ) {
        self.title = title
        self.prompt = prompt
        self.confirmLabel = confirmLabel
        self.initialName = initialName
        self.onSubmit = onSubmit
        _name = State(initialValue: initialName)
    }

    private var validationMessage: String? {
        FileBrowserModel.validateName(name)
    }

    private var isUnchangedRename: Bool {
        !initialName.isEmpty && name.trimmingCharacters(in: .whitespacesAndNewlines) == initialName
    }

    private var canSubmit: Bool {
        validationMessage == nil && !isUnchangedRename
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .onSubmit {
                    submit()
                }

            if let validationMessage, !name.isEmpty {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.orange.legibleText(in: colorScheme))
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(confirmLabel) {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
        }
        .padding(18)
        .frame(width: 380)
        .background(DashboardBackdrop())
    }

    private func submit() {
        guard canSubmit else {
            return
        }
        onSubmit(name.trimmingCharacters(in: .whitespacesAndNewlines))
        dismiss()
    }
}

// MARK: - Hero empty state

/// First-visit hero for the Files tab, in the same voice as TerminalHero.
private struct FilesHero: View {
    let profile: ClusterProfile
    let state: ClusterConnectionState
    let isLoggedIn: Bool
    /// e.g. "home, scratch, and flash".
    let spacesSummary: String
    let onOpenHome: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)

            VStack(spacing: 14) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "folder")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.orange)
                    ClusterBadge(profile: profile, size: 20)
                        .offset(x: 8, y: 6)
                }
                .accessibilityHidden(true)

                Text(
                    isLoggedIn
                        ? "Browse your files on \(profile.displayName)"
                        : "Connect to \(profile.displayName) to browse its files"
                )
                .font(.headline)
                .multilineTextAlignment(.center)

                Text(
                    isLoggedIn
                        ? "List, preview, upload, and organize files in your \(spacesSummary) spaces "
                            + "over \(profile.displayName)'s existing SSH session — no extra password or Duo push."
                        : "Use Connect for \(profile.displayName) in the sidebar. The file browser reuses "
                            + "\(profile.displayName)'s SSH session, so your \(spacesSummary) spaces then appear "
                            + "here with upload, download, and a server-side trash."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

                Text(sharingNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)

                if !isLoggedIn {
                    ConnectionStatePill(state: state)
                }

                Button(action: onOpenHome) {
                    Label("Open Home", systemImage: "house")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .help("Open your home directory on \(profile.displayName)")
            }
            .padding(28)
            .frame(maxWidth: 520)
            .dashboardCard(padding: 24, accent: .orange)

            Spacer(minLength: 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Which of the spaces are shared, derived from the profile's storage
    /// kinds rather than hard-coded paths.
    private var sharingNote: String {
        let hasClusterOnlySpaces = profile.storage.contains {
            !StorageKind(label: $0.label).isSharedAcrossClusters
        }
        let shared = "Home is shared: the same files on \(FileBrowserModel.sharedHomeClusterList)"
        return hasClusterOnlySpaces
            ? "\(shared); the other spaces belong to \(profile.displayName) alone."
            : "\(shared)."
    }
}
