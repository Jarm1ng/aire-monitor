import HPCCore
import SwiftUI

/// Everything the user moved to the trash on one cluster: the shared home
/// trash and every run folder beside scratch/flash items, each with its
/// size (on demand), Restore and Empty. Trashed scratch data keeps using the
/// scratch quota until emptied, so this is where quota is actually freed.
struct TrashSheet: View {
    @ObservedObject var files: FileBrowserModel
    @ObservedObject var trash: RemoteTrashModel
    let profile: ClusterProfile

    @Environment(\.dismiss) private var dismiss
    @State private var runsToEmpty: [TrashRun] = []
    @State private var confirmEmpty = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let message = trash.message {
                messageRow(message)
            }
            content
            footer
        }
        .padding(18)
        .frame(minWidth: 680, idealWidth: 760, minHeight: 480, idealHeight: 620)
        .background(DashboardBackdrop())
        .onAppear {
            trash.load()
        }
        .confirmationDialog(
            emptyDialogTitle,
            isPresented: $confirmEmpty,
            titleVisibility: .visible
        ) {
            Button("Empty Permanently", role: .destructive) {
                trash.empty(runsToEmpty)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "These items are deleted for good on \(profile.displayName) and cannot be restored. "
                    + "The delete runs on the login node and shows its progress under the file list."
            )
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.red.opacity(0.12))
                Image(systemName: "trash")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.red)
            }
            .frame(width: 46, height: 46)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Trash on \(profile.displayName)")
                        .font(.title3.weight(.semibold))
                    ClusterBadge(profile: profile, size: 16)
                }
                Text(
                    "Home items are in \(RemoteFileService.homeTrashDisplayPath), shared by "
                        + "\(FileBrowserModel.sharedHomeClusterList). Scratch and flash items wait beside where "
                        + "they were and keep counting against that quota until emptied."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close trash")
        }
    }

    private func messageRow(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: trash.messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(trash.messageIsError ? Color.red : Color.green)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption)
                .lineLimit(4)
                .textSelection(.enabled)
            Spacer()
            Button {
                trash.dismissMessage()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss message")
        }
        .padding(10)
        .background(
            (trash.messageIsError ? Color.red : Color.green).opacity(0.10),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if trash.isLoading && !trash.hasLoaded {
            VStack(spacing: 10) {
                ProgressView()
                Text("Looking for trashed items on \(profile.displayName)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if trash.runs.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "trash.slash")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("The trash is empty")
                    .font(.headline)
                Text(
                    "Trash folders that older versions created beside scratch items are not tracked; "
                        + "show hidden files in the browser to find any \(RemoteFileService.trashDirectoryName) folders."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(trash.runs) { run in
                        TrashRunCard(
                            run: run,
                            size: trash.sizes[run.directory],
                            isBusy: trash.busyDirectories.contains(run.directory),
                            location: locationText(run),
                            currentClusterID: profile.id.rawValue,
                            onRestore: { items in trash.restore(run, items: items) },
                            onShow: {
                                dismiss()
                                files.reveal(path: run.directory)
                            },
                            onEmpty: {
                                runsToEmpty = [run]
                                confirmEmpty = true
                            },
                            onForget: { trash.forget(run) }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func locationText(_ run: TrashRun) -> String {
        switch run.location {
        case .home:
            return "Home trash (\(RemoteFileService.homeTrashDisplayPath)), shared by every cluster"
        case .beside(let parent):
            return "Beside \(files.displayPath(parent))"
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(summary)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if trash.isLoading && trash.hasLoaded {
                ProgressView()
                    .controlSize(.mini)
            }
            Spacer()
            Button {
                trash.load()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(trash.isLoading)

            Button {
                trash.measureSizes()
            } label: {
                if trash.isMeasuring {
                    Label("Measuring…", systemImage: "scalemass")
                } else {
                    Label("Calculate Sizes", systemImage: "scalemass")
                }
            }
            .buttonStyle(.bordered)
            .disabled(trash.reachableRuns.isEmpty || trash.isMeasuring)
            .help("Measure each trash folder with du (bounded; large trees may take up to a minute)")

            // Unreachable runs are left out: their contents are unknown, and
            // deleting a path that is not there would report a success.
            Button(role: .destructive) {
                runsToEmpty = trash.reachableRuns.filter { !trash.busyDirectories.contains($0.directory) }
                confirmEmpty = !runsToEmpty.isEmpty
            } label: {
                Label("Empty Trash…", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(trash.reachableRuns.isEmpty)
        }
    }

    private var summary: String {
        guard !trash.runs.isEmpty else {
            return ""
        }
        var text = "\(FileBrowserModel.itemCount(trash.totalItemCount)) in \(trash.runs.count) "
            + "trash folder\(trash.runs.count == 1 ? "" : "s")"
        if let bytes = trash.totalMeasuredBytes {
            text += " · \(FileDisplay.byteText(bytes))"
        }
        // Their items are in neither figure: say so rather than imply the
        // count and size cover everything.
        let unreachable = trash.runs.count - trash.reachableRuns.count
        if unreachable > 0 {
            text += " · \(unreachable) unreachable"
        }
        return text
    }

    private var emptyDialogTitle: String {
        let count = runsToEmpty.reduce(0) { $0 + $1.itemCount }
        return "Permanently delete \(FileBrowserModel.itemCount(count)) from the trash on \(profile.displayName)?"
    }
}

// MARK: - Run card

private struct TrashRunCard: View {
    let run: TrashRun
    let size: Int64?
    let isBusy: Bool
    let location: String
    let currentClusterID: String
    let onRestore: ([TrashRun.Item]) -> Void
    let onShow: () -> Void
    let onEmpty: () -> Void
    let onForget: () -> Void

    @State private var isExpanded = false

    private static let collapsedCount = 4

    private var shownItems: [TrashRun.Item] {
        isExpanded ? run.items : Array(run.items.prefix(Self.collapsedCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: run.location == .home ? "house" : "externaldrive")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Text(location)
                        .font(run.location == .home ? .caption : .caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(run.directory)
                }
                Spacer()
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
                if run.isReachable {
                    Button("Show", action: onShow)
                        .controlSize(.small)
                        .help("Open this trash folder in the file browser")
                    if !run.restorableItems.isEmpty {
                        Button("Restore All") {
                            onRestore(run.restorableItems)
                        }
                        .controlSize(.small)
                        .disabled(isBusy)
                        .help("Move every item back to where it was (never over an existing name)")
                    }
                    Button("Empty…", role: .destructive, action: onEmpty)
                        .controlSize(.small)
                        .disabled(isBusy)
                } else if case .missing = run.reachability {
                    Button("Forget", action: onForget)
                        .controlSize(.small)
                        .help(
                            "Stop listing this trash folder. Nothing is deleted: if the folder turns up again, "
                                + "its items stay there, but only showing hidden files in the browser will find them."
                        )
                        .accessibilityLabel("Forget this trash folder")
                }
            }

            if let error = run.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(run.isReachable ? Color.red : StatusTone.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(shownItems) { item in
                    itemRow(item)
                }
                if run.items.count > Self.collapsedCount {
                    Button(isExpanded ? "Show fewer" : "Show \(run.items.count - Self.collapsedCount) more") {
                        withAnimation(AppTheme.smoothEase) {
                            isExpanded.toggle()
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                if run.itemCount > run.items.count {
                    Text("and \(run.itemCount - run.items.count) more — use Show to see them all")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !run.hasManifest, run.itemCount > 0 {
                    Text("Trashed by an older version: the original locations were not recorded, so restore with mv in a shell.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 24)
        }
        .dashboardCard(padding: 12, accent: run.location == .home ? .orange : .red)
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        var parts: [String] = []
        if let created = run.createdAt {
            parts.append(created.formatted(date: .abbreviated, time: .shortened))
        } else {
            parts.append((run.directory as NSString).lastPathComponent)
        }
        // An unreachable run's contents are unknown, not empty.
        parts.append(run.isReachable ? FileBrowserModel.itemCount(run.itemCount) : "contents unavailable")
        if let size {
            parts.append(FileDisplay.byteText(size))
        }
        if let cluster = run.clusterID, cluster != currentClusterID {
            parts.append("trashed on \(ClusterIdentity.resolve(ClusterID(cluster)).displayName)")
        }
        return parts.joined(separator: " · ")
    }

    private func itemRow(_ item: TrashRun.Item) -> some View {
        HStack(spacing: 6) {
            Image(systemName: item.isDirectory ? "folder" : "doc")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(item.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            if let original = item.originalPath {
                Text("from \((original as NSString).deletingLastPathComponent)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(original)
            }
            Spacer()
            if item.originalPath != nil, !item.nameIsLossy {
                Button("Restore") {
                    onRestore([item])
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(isBusy)
                .accessibilityLabel("Restore \(item.name)")
            }
        }
    }
}
