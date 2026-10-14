import HPCCore
import AppKit
import SwiftUI

/// The strip under the file table: queued, running and finished transfers
/// plus detached remote jobs (permanent deletes, copies into the home
/// trash), each with progress and Cancel. Observes `FileActivity` on its
/// own so progress ticks never re-render the file table.
struct FileActivityStrip: View {
    @ObservedObject var activity: FileActivity

    private var isEmpty: Bool {
        activity.transfers.isEmpty && activity.operations.isEmpty
    }

    var body: some View {
        Group {
            if !isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(activity.operations) { operation in
                            OperationChip(operation: operation) {
                                activity.cancelOperation(operation.id)
                            }
                        }
                        ForEach(activity.transfers) { transfer in
                            TransferChip(
                                item: transfer,
                                onCancel: { activity.cancelTransfer(transfer.id) },
                                onDismiss: { activity.dismissTransfer(transfer.id) },
                                onReveal: { activity.revealInFinder(transfer.id) }
                            )
                        }
                    }
                    .padding(.vertical, 1)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .accessibilityLabel("File transfers and background operations")
            }
        }
        .animation(AppTheme.smoothEase, value: isEmpty)
    }
}

// MARK: - Transfer chip

private struct TransferChip: View {
    let item: FileActivity.TransferItem
    let onCancel: () -> Void
    let onDismiss: () -> Void
    let onReveal: () -> Void

    @State private var showsFailure = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                .foregroundStyle(item.direction == .upload ? Color.orange : AppTheme.gpu)
                .accessibilityHidden(true)
            Text(item.filename)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 170)
            statusView
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().stroke(AppTheme.border, lineWidth: 1))
        .help(accessibilitySummary)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private var statusView: some View {
        switch item.phase {
        case .waiting:
            Text("Waiting…")
                .foregroundStyle(.secondary)
            cancelButton

        case .running:
            if item.cancelRequested {
                ProgressView()
                    .controlSize(.mini)
                Text("Cancelling…")
                    .foregroundStyle(.secondary)
            } else {
                if let fraction = item.fractionCompleted {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 54)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(progressText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                cancelButton
            }

        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            if item.localURL != nil {
                Button(action: onReveal) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Show in Finder")
                .accessibilityLabel("Show \(item.filename) in Finder")
            }

        case .cancelled:
            Text("Cancelled")
                .foregroundStyle(.secondary)

        case .failed(let message):
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Button {
                showsFailure = true
            } label: {
                Text(message)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 220, alignment: .leading)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Show the full error")
            .popover(isPresented: $showsFailure, arrowEdge: .top) {
                Text(message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(14)
                    .frame(maxWidth: 420, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss failed transfer")
        }
    }

    private var cancelButton: some View {
        Button(action: onCancel) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(item.phase == .waiting ? "Remove from the queue" : "Cancel this transfer")
        .accessibilityLabel("Cancel \(item.direction == .upload ? "upload" : "download") of \(item.filename)")
    }

    /// "42% · 12.3 MB/s", or bytes so far when the size is unknown.
    @MainActor
    private var progressText: String {
        var parts: [String] = []
        if let fraction = item.fractionCompleted {
            parts.append("\(Int((fraction * 100).rounded(.down)))%")
        } else if item.transferredBytes > 0 {
            parts.append(FileDisplay.byteText(item.transferredBytes))
        } else {
            parts.append("Starting…")
        }
        if let rate = item.bytesPerSecond, rate > 0 {
            parts.append(FileDisplay.rateText(rate))
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilitySummary: String {
        let direction = item.direction == .upload
            ? "Upload of \(item.filename) to \(item.clusterName)"
            : "Download of \(item.filename) from \(item.clusterName)"
        switch item.phase {
        case .waiting:
            return "\(direction) waiting for a free transfer slot"
        case .running:
            return "\(direction) in progress"
        case .done:
            return "\(direction) finished"
        case .cancelled:
            return "\(direction) cancelled"
        case .failed(let message):
            return "\(direction) failed: \(message)"
        }
    }
}

// MARK: - Operation chip

private struct OperationChip: View {
    let operation: FileActivity.BackgroundOperation
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: operation.kind == .delete ? "trash" : "arrow.right.doc.on.clipboard")
                .foregroundStyle(operation.kind == .delete ? Color.red : Color.orange)
                .accessibilityHidden(true)
            Text(operation.title)
                .lineLimit(1)
                .frame(maxWidth: 220, alignment: .leading)
            if operation.total > 1 {
                ProgressView(value: Double(operation.done), total: Double(max(operation.total, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 54)
                Text("\(operation.done) of \(operation.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.mini)
            }
            if operation.unansweredPolls > 0 {
                Text("waiting for \(operation.clusterName)…")
                    .foregroundStyle(.orange)
            }
            if operation.cancelRequested {
                Text("Cancelling…")
                    .foregroundStyle(.secondary)
            } else {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(cancelHelp)
                .accessibilityLabel("Cancel: \(operation.title)")
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().stroke(AppTheme.border, lineWidth: 1))
        .help(helpText)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(operation.title) on \(operation.clusterName), \(operation.done) of \(operation.total) done")
    }

    private var cancelHelp: String {
        operation.kind == .delete
            ? "Stop deleting. Items already removed are gone; the rest stay."
            : "Stop copying. Items already copied stay in the home trash; the rest stay where they are."
    }

    private var helpText: String {
        var text = "\(operation.title) on \(operation.clusterName). Runs on the login node, so it continues even if "
            + "the app quits or the connection drops."
        if let current = operation.current {
            text += "\nNow: \(current)"
        }
        return text
    }
}
