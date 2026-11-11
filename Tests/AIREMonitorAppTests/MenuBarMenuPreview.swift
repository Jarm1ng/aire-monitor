import AppKit
import HPCCore
import SwiftUI
@testable import AIREMonitorApp

/// An offscreen stand-in for the status item's NSMenu, for renders only
/// (an NSMenu cannot be drawn offscreen): the same `MenuEntry` values, the
/// same hosted rows, and native items drawn at menu metrics. Close to the
/// real menu, not pixel-identical — check the real one on a Mac.
struct MenuBarMenuPreview: View {
    let entries: [MenuEntry]
    /// One native item drawn highlighted, as under the pointer.
    var highlighted: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                row(entry)
            }
        }
        .padding(.vertical, 5)
        .frame(width: MenuMetrics.minimumWidth)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.14), lineWidth: 1))
    }

    @ViewBuilder
    private func row(_ entry: MenuEntry) -> some View {
        switch entry {
        case .separator:
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        case .clusterHeader(let header):
            MenuClusterHeaderRow(header: header).frame(height: MenuMetrics.headerHeight)
        case .note(_, let note):
            MenuNoteRow(note: note).padding(.vertical, 2)
        case .gpuPool(_, let row):
            MenuGPUPoolRow(row: row).frame(height: row.caption == nil ? MenuMetrics.rowHeight : MenuMetrics.captionedRowHeight)
        case .storage(_, let row):
            MenuStorageWarningRow(row: row).frame(height: MenuMetrics.rowHeight)
        case .item(let item):
            nativeRow(item)
        }
    }

    private func nativeRow(_ item: MenuItemModel) -> some View {
        let isHighlighted = item.id == highlighted
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                if let suffix = item.protectedSuffix, item.title.hasSuffix(suffix) {
                    Text(String(item.title.dropLast(suffix.count)))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(suffix)
                        .lineLimit(1)
                        .fixedSize()
                } else {
                    Text(item.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                if let trailing = item.trailing {
                    Text(trailing)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .frame(width: MenuMetrics.trailingTab - CGFloat(item.indent) * MenuMetrics.indentPerLevel, alignment: .leading)
            .padding(.leading, CGFloat(item.indent) * MenuMetrics.indentPerLevel)
            Spacer(minLength: 0)
            if item.submenu != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isHighlighted ? Color.white : Color.secondary)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(isHighlighted ? Color.white : (item.isEnabled ? Color.primary : Color.secondary))
        // The outer 5 pt (the highlight's inset) counts toward the inset.
        .padding(.leading, MenuMetrics.textInset - 5)
        .padding(.trailing, 7)
        .frame(height: MenuMetrics.rowHeight)
        .background(isHighlighted ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, 5)
    }
}

/// The status item on a stand-in menu bar strip, in several states.
struct StatusItemPreviewStrip: View {
    let summaries: [(label: String, summary: StatusBarSummary)]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(summaries.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 14) {
                    Text(item.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 170, alignment: .leading)
                    HStack(spacing: StatusItemLayout.gap) {
                        Image(nsImage: StatusItemGlyph.image(attention: item.summary.hasAttention))
                            .renderingMode(.template)
                        if !item.summary.title.isEmpty {
                            Text(item.summary.title)
                                .font(Font(StatusItemLayout.font))
                        }
                    }
                    .foregroundStyle(Color.primary.opacity(item.summary.isDimmed ? 0.35 : 0.88))
                    .padding(.horizontal, StatusItemLayout.padding / 2)
                    .frame(height: 24)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                }
            }
        }
        .padding(14)
        .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.93))
    }
}
