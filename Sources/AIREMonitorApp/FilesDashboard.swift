import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Files tab: a Finder-like browser over the app's live SSH session.
/// Rendered outside the shared dashboard ScrollView (like the terminal)
/// because the table manages its own scrolling. All state that must survive
/// tab switches lives in `FileBrowserModel` up in `ContentView`; the @State
/// here is transient dialog plumbing only.
struct FilesDashboard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var files: FileBrowserModel
    /// Wired by DashboardView: switches to the terminal tab and opens a
    /// shell landing in the given remote directory.
    var onOpenShellAt: (@MainActor (String) -> Void)? = nil
    /// Wired by DashboardView: switches to the terminal tab and opens vim
    /// on the given remote file.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(
                title: "Files",
                subtitle: "Browse and manage files on the AIRE login node over the live SSH session",
                systemImage: "folder",
                accent: .orange
            ) {
                headerActions
            }

            toolbarRow
            shortcutRow
            bannerRow

            content

            transfersStrip
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(AIRETheme.smoothEase, value: files.errorBanner)
        .animation(AIRETheme.smoothEase, value: files.infoBanner)
        .animation(AIRETheme.smoothEase, value: files.transfers.isEmpty)
        .onAppear {
            files.attach(appModel: model)
            if !files.hasLoadedOnce, !files.isLoading, model.isLoggedIn {
                files.openHome()
            }
        }
        .sheet(isPresented: $showNewFolderSheet) {
            NameEntrySheet(
                title: "New Folder",
                prompt: "Create a folder in \(files.currentPath)",
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
            FilePreviewSheet(files: files, entry: preview.entry, onOpenVim: onOpenVim)
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
            "Copy items into your home quota?",
            isPresented: quotaTrashDialogBinding,
            titleVisibility: .visible,
            presenting: files.pendingQuotaTrash
        ) { pending in
            Button("Copy to Home Trash", role: .destructive) {
                files.confirmQuotaTrash(pending)
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
            "Permanently delete \(deleteCandidates.count) item\(deleteCandidates.count == 1 ? "" : "s")?",
            isPresented: $showDeleteStepOne,
            titleVisibility: .visible
        ) {
            Button("Continue…", role: .destructive) {
                showDeleteStepTwo = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This skips the server-side trash. You will be asked to confirm once more.")
        }
        .confirmationDialog(
            "This cannot be undone",
            isPresented: $showDeleteStepTwo,
            titleVisibility: .visible
        ) {
            Button(
                "Delete \(deleteCandidates.count) item\(deleteCandidates.count == 1 ? "" : "s") permanently",
                role: .destructive
            ) {
                files.deleteForever(entries: deleteCandidates)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteCandidates.map(\.name).prefix(5).joined(separator: ", "))
        }
    }

    // MARK: Header actions

    private var headerActions: some View {
        HStack(spacing: 10) {
            if files.isMutating {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                showNewFolderSheet = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)
            .disabled(files.currentPath.isEmpty)
            .help("Create a folder in the current directory")

            Button {
                showUploadImporter = true
            } label: {
                Label("Upload", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .disabled(files.currentPath.isEmpty)
            .help("Upload local files to the current directory")
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
        .overlay(Capsule().stroke(AIRETheme.border, lineWidth: 1))
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
                        .help(shortcut.path)
                    }
                }
                .padding(.vertical, 1)
            }
            .accessibilityLabel("Location shortcuts")
        }
    }

    @ViewBuilder
    private var bannerRow: some View {
        if let message = files.errorBanner {
            FilesBanner(message: message, isError: true) {
                files.errorBanner = nil
            }
        } else if let message = files.infoBanner {
            FilesBanner(message: message, isError: false) {
                files.infoBanner = nil
            }
        }
    }

    // MARK: Main content

    @ViewBuilder
    private var content: some View {
        if !files.hasLoadedOnce && !files.isLoading {
            FilesHero(isLoggedIn: model.isLoggedIn) {
                files.openHome()
            }
        } else {
            tableArea
        }
    }

    private var tableArea: some View {
        fileTable
            .overlay {
                if files.isLoading {
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
                FileNameCell(entry: entry)
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
            Text("Listing \(files.currentPath)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(AIRETheme.border, lineWidth: 1))
        .transition(.opacity)
        .accessibilityLabel("Loading directory listing")
    }

    private var emptyListingOverlay: some View {
        VStack(spacing: 8) {
            Image(systemName: files.filterText.isEmpty ? "folder" : "magnifyingglass")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
            Text(files.filterText.isEmpty ? "This folder is empty" : "No matches for “\(files.filterText)”")
                .font(.headline)
            Text(
                files.filterText.isEmpty
                    ? "Drop files here to upload them, or create a folder."
                    : "Try a different filter, or clear it to see everything."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
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
                    Text("Drop to upload to \(files.currentPath)")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(Color.orange)
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    // MARK: Transfers strip

    @ViewBuilder
    private var transfersStrip: some View {
        if !files.transfers.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(files.transfers) { transfer in
                        TransferChip(item: transfer) {
                            files.dismissTransfer(transfer.id)
                        }
                    }
                }
                .padding(.vertical, 1)
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .accessibilityLabel("File transfers")
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text(itemsSummary)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if files.listing?.truncated == true {
                Label("Listing truncated — not all entries are shown", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
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

    private var itemsSummary: String {
        let total = files.visibleEntries.count
        let selected = files.selection.count
        if selected > 0 {
            return "\(total) item\(total == 1 ? "" : "s") (\(selected) selected)"
        }
        return "\(total) item\(total == 1 ? "" : "s")"
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
        .overlay(Capsule().stroke(AIRETheme.border, lineWidth: 1))
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
        } else {
            Button("Open") {
                openEntries(targets)
            }
            if targets.count == 1, let entry = targets.first {
                if !entry.isNavigable {
                    Button("Preview") {
                        files.preview(entry: entry)
                    }
                }
                Button("Rename…") {
                    renameTarget = entry
                }
                Button("Copy Path") {
                    copyPath(entry)
                }
                if entry.kind == .directory {
                    Button("Folder Size") {
                        files.requestDiskUsage(for: entry)
                    }
                    Button("Open Shell Here") {
                        onOpenShellAt?(entry.path)
                    }
                }
            }
            if targets.contains(where: \.isDownloadable) {
                Button("Download") {
                    files.download(entries: targets)
                }
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                beginTrash(targets)
            }
            Button("Delete Permanently…", role: .destructive) {
                beginDelete(targets)
            }
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
        } else {
            files.preview(entry: entry)
        }
    }

    private func copyPath(_ entry: RemoteFileEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.path, forType: .string)
        files.showInfo("Copied path to clipboard")
    }

    private func beginTrash(_ entries: [RemoteFileEntry]) {
        guard !entries.isEmpty else {
            return
        }
        trashCandidates = entries
        showTrashConfirmation = true
    }

    private func beginDelete(_ entries: [RemoteFileEntry]) {
        guard !entries.isEmpty else {
            return
        }
        deleteCandidates = entries
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
        let note = "Items are moved to a .aire-trash folder on AIRE and can be restored from a shell."
        guard trashCandidates.count > 1 else {
            return note
        }
        var names = trashCandidates.prefix(5).map(\.name).joined(separator: ", ")
        if trashCandidates.count > 5 {
            names += ", …"
        }
        return "\(names)\n\(note)"
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

    private func quotaTrashMessage(_ pending: FileBrowserModel.PendingQuotaTrash) -> String {
        let count = pending.affectedPaths.count
        let items = "\(count) item\(count == 1 ? "" : "s")"
        return "No trash folder could be created on the filesystem of \(items). "
            + "Moving to trash will copy that data into ~/.aire-trash, which counts "
            + "against your home quota. You can copy anyway, or skip the trash and "
            + "delete permanently."
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
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    static func modifiedTooltip(_ date: Date?) -> String {
        guard let date else {
            return "Modification time unavailable"
        }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    static func byteText(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }
}

// MARK: - Name cell

private struct FileNameCell: View {
    let entry: RemoteFileEntry

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
            if entry.kind == .symlink, let target = entry.linkTarget, !target.isEmpty {
                Text("→ \(target)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var iconColor: Color {
        switch entry.kind {
        case .directory:
            return .orange
        case .symlink:
            return AIRETheme.gpu
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
        .overlay(Capsule().stroke(AIRETheme.border, lineWidth: 1))
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
                                : AIRETheme.chipStroke(for: colorScheme),
                            lineWidth: 1
                        )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(AIRETheme.smoothEase, value: isHovered)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Banner

private struct FilesBanner: View {
    let message: String
    let isError: Bool
    let onDismiss: () -> Void

    private var color: Color {
        isError ? .red : .green
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(color)
            Text(message)
                .font(.caption)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 6)
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
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Transfer chip

private struct TransferChip: View {
    let item: FileBrowserModel.TransferItem
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                .foregroundStyle(item.direction == .upload ? Color.orange : AIRETheme.gpu)
            Text(item.filename)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180)
            statusView
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().stroke(AIRETheme.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private var statusView: some View {
        switch item.state {
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .help(message)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss failed transfer")
        }
    }

    private var accessibilitySummary: String {
        let direction = item.direction == .upload ? "Upload" : "Download"
        switch item.state {
        case .running:
            return "\(direction) of \(item.filename) in progress"
        case .done:
            return "\(direction) of \(item.filename) finished"
        case .failed(let message):
            return "\(direction) of \(item.filename) failed: \(message)"
        }
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
                    .foregroundStyle(.orange)
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

// MARK: - Preview sheet

private struct FilePreviewSheet: View {
    @ObservedObject var files: FileBrowserModel
    let entry: RemoteFileEntry
    var onOpenVim: (@MainActor (String) -> Void)?

    @Environment(\.dismiss) private var dismiss

    /// Renders from the live model (not the sheet item snapshot) so the
    /// loading state flips to content in place.
    private var content: FileBrowserModel.PreviewContent {
        guard let preview = files.activePreview, preview.entry.path == entry.path else {
            return .loading
        }
        return preview.content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            main
            actions
        }
        .padding(18)
        .background(DashboardBackdrop())
        .frame(minWidth: 640, idealWidth: 780, minHeight: 440, idealHeight: 600)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.14))
                Image(systemName: entry.systemIconName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            .frame(width: 46, height: 46)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close preview")
        }
    }

    @ViewBuilder
    private var main: some View {
        switch content {
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading preview…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .text(let text):
            ScrollView {
                Text(text.isEmpty ? "(empty file)" : text)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(AIRETheme.mutedFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AIRETheme.border, lineWidth: 1)
            )

        case .binary(let mimeType):
            previewCard(
                systemImage: "doc.badge.gearshape",
                title: "Binary file",
                subtitle: "\(mimeType) — no inline preview. Download it to open locally."
            )

        case .tooLarge(let bytes):
            previewCard(
                systemImage: "scalemass",
                title: "Too large to preview",
                subtitle: "\(FileDisplay.byteText(bytes)) — download the file or open it in the terminal instead."
            )

        case .failure(let message):
            previewCard(
                systemImage: "exclamationmark.triangle",
                title: "Preview failed",
                subtitle: message
            )
        }
    }

    private func previewCard(systemImage: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dashboardCard(padding: 20, accent: .secondary)
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if case .text = content {
                Button {
                    dismiss()
                    onOpenVim?(entry.path)
                } label: {
                    Label("Open in Terminal (vim)", systemImage: "terminal")
                }
                .buttonStyle(.bordered)
                .disabled(onOpenVim == nil)
                .help("Edit this file with vim over the live SSH session")
            }

            Button {
                files.download(entries: [entry])
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .help("Download to your local Downloads folder")

            Spacer()
        }
    }
}

// MARK: - Hero empty state

/// First-visit hero for the Files tab, in the same voice as TerminalHero.
private struct FilesHero: View {
    let isLoggedIn: Bool
    let onOpenHome: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)

            VStack(spacing: 14) {
                Image(systemName: "folder")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.orange)

                Text(
                    isLoggedIn
                        ? "Browse your files on AIRE"
                        : "The file browser reuses the app's SSH session — log in first."
                )
                .font(.headline)
                .multilineTextAlignment(.center)

                Text(
                    isLoggedIn
                        ? "List, preview, upload, and organize files in your home and scratch spaces over the existing SSH session — no extra password or Duo push."
                        : "Once connected, your home and scratch spaces appear here with upload, download, and a server-side trash."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

                Button(action: onOpenHome) {
                    Label("Open Home", systemImage: "house")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            .padding(28)
            .frame(maxWidth: 520)
            .dashboardCard(padding: 24, accent: .orange)

            Spacer(minLength: 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
