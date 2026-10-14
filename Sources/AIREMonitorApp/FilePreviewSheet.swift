import HPCCore
import AppKit
import SwiftUI

// MARK: - Preview sheet

/// Quick look at a remote file over the cluster's session: the head or the
/// tail of a text file (logs open at the end), always saying how much of
/// the file is shown, with hand-offs to vim, less and Download.
struct FilePreviewSheet: View {
    @ObservedObject var files: FileBrowserModel
    @ObservedObject var activity: FileActivity
    /// The cluster the file was listed from: a path like /users/<u>/x is
    /// valid on every cluster, so the sheet says whose copy it is showing.
    let profile: ClusterProfile
    let entry: RemoteFileEntry
    var onOpenVim: (@MainActor (String) -> Void)?
    var onOpenPager: (@MainActor (String) -> Void)?

    @Environment(\.dismiss) private var dismiss

    /// Renders from the live model (not the sheet item snapshot) so the
    /// loading state flips to content in place.
    private var state: FileBrowserModel.PreviewState? {
        guard let preview = files.activePreview, preview.entry.path == entry.path else {
            return nil
        }
        return preview
    }

    private var content: FileBrowserModel.PreviewContent {
        state?.content ?? .loading
    }

    private var mode: RemotePreviewMode {
        state?.mode ?? RemotePreviewMode.preferred(forFileName: entry.name)
    }

    private var isDownloading: Bool {
        activity.isDownloading(remotePath: entry.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if case .text(let preview) = content {
                coverageBar(preview)
            }
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
                HStack(spacing: 6) {
                    ClusterBadge(profile: profile, size: 15)
                    Text(entry.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(entry.path) on \(profile.displayName)")
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

    /// "Showing the last 256 KB of 912 KB" with a Start/End switch — a
    /// cut-off preview must never look like the whole file.
    private func coverageBar(_ preview: RemoteTextPreview) -> some View {
        HStack(spacing: 10) {
            Image(systemName: preview.truncated ? "scissors" : "doc.plaintext")
                .font(.caption)
                .foregroundStyle(preview.truncated ? Color.orange : Color.secondary)
                .accessibilityHidden(true)
            Text(Self.coverageText(preview))
                .font(.caption.monospacedDigit())
                .foregroundStyle(preview.truncated ? Color.primary : Color.secondary)
            Spacer()
            if state?.isReloading == true {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Loading the other end of the file")
            }
            if preview.truncated || mode == .tail {
                Picker("Show", selection: Binding(
                    get: { mode },
                    set: { files.preview(entry: entry, mode: $0) }
                )) {
                    Text("Start").tag(RemotePreviewMode.head)
                    Text("End").tag(RemotePreviewMode.tail)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
                .help("Show the beginning or the end of the file")
            }
        }
        .accessibilityElement(children: .contain)
    }

    @MainActor
    static func coverageText(_ preview: RemoteTextPreview) -> String {
        let total = FileDisplay.byteText(preview.totalBytes)
        guard preview.truncated else {
            return "Whole file · \(total)"
        }
        let shown = FileDisplay.byteText(Int64(preview.shownBytes))
        return preview.fromEnd
            ? "Showing the last \(shown) of \(total)"
            : "Showing the first \(shown) of \(total)"
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

        case .text(let preview):
            Group {
                if preview.text.isEmpty {
                    Text("(empty file)")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PlainTextPreview(text: preview.text, scrollToEnd: preview.fromEnd)
                }
            }
            .background(AppTheme.mutedFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )

        case .binary(let mimeType):
            previewCard(
                systemImage: "doc.badge.gearshape",
                title: "Binary file",
                subtitle: "\(mimeType) — no inline preview. Download it to open locally."
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
                .help("Edit this file with vim over \(profile.displayName)'s live SSH session")

                Button {
                    dismiss()
                    onOpenPager?(entry.path)
                } label: {
                    Label("Open in Terminal (less)", systemImage: "text.alignleft")
                }
                .buttonStyle(.bordered)
                .disabled(onOpenPager == nil)
                .help("Page through the whole file from its end (less +G) — follow a growing log with Shift-F")
            }

            Button {
                files.download(entries: [entry])
            } label: {
                if isDownloading {
                    Label("Downloading…", systemImage: "arrow.down.circle")
                } else {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isDownloading)
            .help(
                isDownloading
                    ? "Already downloading this file — see the transfers below the file list"
                    : "Download from \(profile.displayName) to your local Downloads folder"
            )

            Spacer()
        }
    }
}

// MARK: - Plain text view

/// Read-only monospaced text in an AppKit text view. SwiftUI lays out and
/// draws a selectable `Text` in full on the main thread — 256 KB of log
/// took about five seconds and froze every window — while NSTextView with
/// non-contiguous layout only lays out what is on screen.
struct PlainTextPreview: NSViewRepresentable {
    let text: String
    /// Logs previewed from their end open scrolled to the bottom.
    var scrollToEnd = false

    final class Coordinator {
        var shownText: String?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PreviewScrollView {
        let scrollView = PreviewScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize))
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.setAccessibilityLabel("File contents")
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: PreviewScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              context.coordinator.shownText != text else {
            return
        }
        context.coordinator.shownText = text
        textView.string = text
        scrollView.requestScroll(toEnd: scrollToEnd)
    }
}

/// Applies a requested scroll once the view has a real size: SwiftUI
/// updates the representable before the sheet has laid it out, when a
/// scroll to the end would be computed against an empty clip view.
final class PreviewScrollView: NSScrollView {
    private var pendingScrollToEnd: Bool?

    func requestScroll(toEnd: Bool) {
        pendingScrollToEnd = toEnd
        applyPendingScroll()
    }

    override func tile() {
        super.tile()
        applyPendingScroll()
    }

    private func applyPendingScroll() {
        guard let toEnd = pendingScrollToEnd,
              contentView.bounds.height > 1,
              let textView = documentView as? NSTextView else {
            return
        }
        pendingScrollToEnd = nil
        let length = (textView.string as NSString).length
        // With non-contiguous layout this lays out only the glyphs needed
        // to reach the requested end.
        textView.scrollRangeToVisible(NSRange(location: toEnd ? length : 0, length: 0))
    }
}
