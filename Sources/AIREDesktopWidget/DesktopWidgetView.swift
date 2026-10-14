import AppKit
import HPCCore
import SwiftUI

/// The widget window's root: the panel plus the window plumbing (desktop
/// level, saved position, context menu, polling). The panel itself is a
/// separate view so it can be rendered offscreen without touching a window.
struct DesktopWidgetView: View {
    @StateObject private var model: WidgetModel

    init(model: @autoclosure @escaping () -> WidgetModel = WidgetModel()) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        WidgetPanel(model: model)
            .background(
                DesktopWindowConfigurator(contentSize: NSSize(width: WidgetLayout.width, height: model.panelHeight))
            )
            .ignoresSafeArea()
            .contextMenu {
                Button(model.feeds.count > 1 ? "Refresh All" : "Refresh") {
                    model.refresh()
                }
                .disabled(model.feeds.isEmpty)
                if model.feeds.count > 1 {
                    ForEach(model.feeds) { feed in
                        Button("Refresh \(feed.displayName)") {
                            model.refresh(clusterID: feed.id)
                        }
                    }
                }
                Button("Open Leeds HPC Monitor") {
                    model.openMainApp()
                }
                .disabled(!model.hasProjectRoot)
                Divider()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }
            .task {
                model.start()
            }
    }
}

extension WidgetModel {
    var visibleFeeds: [ClusterFeed] {
        Array(feeds.prefix(WidgetLayout.maxVisibleClusters))
    }

    var hiddenFeedCount: Int {
        max(feeds.count - WidgetLayout.maxVisibleClusters, 0)
    }

    var panelHeight: CGFloat {
        WidgetLayout.height(forClusterRows: visibleFeeds.count)
    }
}

/// Header, one row per cluster (or the empty/missing-project card) and the
/// footer, on the widget's glass background.
struct WidgetPanel: View {
    @ObservedObject var model: WidgetModel

    var body: some View {
        ZStack {
            WidgetVisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(WidgetPalette.backgroundOverlay)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(WidgetPalette.border, lineWidth: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(WidgetPalette.highlight, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.18), radius: 22, x: 0, y: 10)

            VStack(alignment: .leading, spacing: WidgetLayout.sectionSpacing) {
                header
                    .frame(height: WidgetLayout.headerHeight)

                if !model.hasProjectRoot {
                    MissingProjectCard()
                        .frame(height: WidgetLayout.clusterRowHeight)
                } else if model.visibleFeeds.isEmpty {
                    EmptyClustersCard {
                        model.openMainApp()
                    }
                    .frame(height: WidgetLayout.clusterRowHeight)
                } else {
                    VStack(spacing: WidgetLayout.clusterRowSpacing) {
                        ForEach(model.visibleFeeds) { feed in
                            ClusterRow(feed: feed)
                                .frame(height: WidgetLayout.clusterRowHeight)
                                .transition(.opacity)
                        }
                    }
                }

                TimelineView(.periodic(from: .now, by: WidgetLayout.ageRefreshInterval)) { context in
                    footer(now: context.date)
                }
                .frame(height: WidgetLayout.footerHeight)
            }
            .padding(.horizontal, WidgetLayout.horizontalPadding)
            .padding(.vertical, WidgetLayout.verticalPadding)
        }
        .frame(width: WidgetLayout.width, height: model.panelHeight, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.28), value: model.visibleFeeds.map(\.id))
    }

    private var header: some View {
        HStack(spacing: 9) {
            WidgetLogoMark()
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)

            Text("Leeds HPC")
                .font(.title3.weight(.semibold))
                .singleLine()

            StatusChip(
                title: overallStatus.title,
                value: overallStatus.value,
                color: overallStatus.color
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Overall status")
            .accessibilityValue("\(overallStatus.title), \(overallStatus.value)")

            Spacer()

            Button {
                model.openMainApp()
            } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(WidgetIconButtonStyle())
            .disabled(!model.hasProjectRoot)
            .help("Open Leeds HPC Monitor")
            .accessibilityLabel("Open Leeds HPC Monitor")

            Button {
                model.refresh()
            } label: {
                if model.isAnyRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(WidgetIconButtonStyle())
            .disabled(model.feeds.isEmpty)
            .help(model.feeds.count > 1 ? "Refresh all clusters" : "Refresh")
            .accessibilityLabel(model.feeds.count > 1 ? "Refresh all clusters" : "Refresh")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(WidgetIconButtonStyle())
            .help("Close widget")
            .accessibilityLabel("Close widget")
        }
    }

    /// How the feeds are doing as a whole. Deliberately a count of clusters,
    /// never a sum of their numbers. Clusters paused or switched off in the
    /// app are the user's choice, so they are named but never make the
    /// widget look broken.
    private var overallStatus: (title: String, value: String, color: Color) {
        guard model.hasProjectRoot else {
            return ("setup", "project not found", WidgetPalette.red)
        }
        let feeds = model.feeds
        guard !feeds.isEmpty else {
            return ("waiting", "no clusters yet", WidgetPalette.neutral)
        }
        let active = feeds.filter { !$0.status.isUserChoice }
        guard !active.isEmpty else {
            let allOff = feeds.allSatisfy { $0.status == .off }
            let title = allOff ? "off" : "paused"
            return (title, feeds.count == 1 ? feeds[0].displayName : "all \(feeds.count) clusters", WidgetPalette.neutral)
        }
        let pausedCount = feeds.filter { $0.status == .paused }.count
        let offCount = feeds.filter { $0.status == .off }.count
        let parkedSuffix = (pausedCount > 0 ? ", \(pausedCount) paused" : "") + (offCount > 0 ? ", \(offCount) off" : "")
        // One active cluster is named; several are counted.
        let subject = active.count == 1 ? active[0].displayName : nil
        let live = active.filter { $0.status == .live }.count
        let cached = active.filter { $0.status == .cached }.count
        let offline = active.filter { $0.status == .offline }.count
        if live == active.count {
            return ("live", (subject ?? "all \(active.count) clusters") + parkedSuffix, WidgetPalette.green)
        }
        if live > 0 {
            return ("partial", "\(live) of \(active.count) live\(parkedSuffix)", WidgetPalette.orange)
        }
        if cached > 0 {
            return ("cached", (subject ?? "\(cached) of \(active.count) cached") + parkedSuffix, WidgetPalette.orange)
        }
        if offline == active.count {
            return ("offline", (subject ?? "no data") + parkedSuffix, WidgetPalette.red)
        }
        return ("connecting", "waiting", WidgetPalette.neutral)
    }

    private func footer(now: Date) -> some View {
        let presentation = footerPresentation(now: now)
        let color = presentation.isWarning ? WidgetPalette.orange : WidgetPalette.green
        let cadence = Int(model.refreshCadence.rounded())

        return HStack(alignment: .center, spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.28), radius: 3, x: 0, y: 0)
            Text(presentation.message)
                .font(.caption2)
                .foregroundColor(presentation.isWarning ? .primary : .secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .minimumScaleFactor(0.9)
            Spacer()
            if model.hasProjectRoot && !model.feeds.isEmpty {
                Text("\(cadence)s")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .singleLine()
                    .help("Refresh cadence: every \(cadence) seconds (the slowest cluster, including any retry backoff)")
                    .accessibilityLabel("Refresh cadence")
                    .accessibilityValue("\(cadence) seconds")
            }
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(
            presentation.isWarning ? WidgetPalette.orange.opacity(0.12) : WidgetPalette.fill,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(presentation.isWarning ? WidgetPalette.orange.opacity(0.18) : WidgetPalette.border, lineWidth: 1)
        )
        .help(presentation.message)
        .accessibilityElement(children: .combine)
    }

    /// Most important message first: launching, widget errors, the reply to
    /// a Refresh the user just pressed, per-cluster errors (always prefixed
    /// with the cluster name), notices, cached data with its age, then the
    /// time the data is from — the collection time, like the rows, never the
    /// time the widget last read a file.
    private func footerPresentation(now: Date) -> (message: String, isWarning: Bool) {
        var message: String
        var isWarning = true
        let feeds = model.feeds
        let replies = feeds.compactMap(\.refreshReply)
        let problems = feeds.compactMap { feed -> String? in
            guard let error = feed.errorMessage else {
                return nil
            }
            if let next = feed.nextAutomaticAttempt {
                return "\(feed.displayName): \(error) (next try \(next.formatted(date: .omitted, time: .shortened)))"
            }
            return "\(feed.displayName): \(error)"
        }
        let warnings = feeds.filter { !$0.status.isUserChoice }.compactMap(\.notice)
        let choices = feeds.filter { $0.status.isUserChoice }.compactMap(\.notice)
        let cached = feeds.filter { $0.status == .cached }

        if !model.hasProjectRoot {
            message = "The widget looks for scripts/hpc_snapshot.py under HPC_PROJECT_ROOT, the checkout its bundle was built from, its working directory and the folder holding its .runtime bundle."
        } else if let launchMessage = model.launchMessage {
            message = launchMessage
            isWarning = false
        } else if let error = model.errorMessage, !error.isEmpty {
            message = error
        } else if !replies.isEmpty {
            message = RefreshReply.summary(replies)
            isWarning = false
        } else if !problems.isEmpty {
            message = problems.joined(separator: " · ")
        } else if !warnings.isEmpty {
            message = warnings.joined(separator: " ")
        } else if !cached.isEmpty {
            let names = cached.map(\.displayName).joined(separator: " and ")
            if let oldest = cached.compactMap(\.snapshotDate).min() {
                message = "\(names): showing cached data from \(SlurmTimestamp.ageText(from: oldest, now: now)); waiting for a fresh snapshot."
            } else {
                message = "\(names): showing cached data; waiting for a fresh snapshot."
            }
        } else if !choices.isEmpty {
            message = choices.joined(separator: " ")
            isWarning = false
        } else if feeds.isEmpty {
            message = "Waiting for Leeds HPC Monitor to write a cluster snapshot."
            isWarning = false
        } else if let oldest = feeds.filter({ $0.status == .live }).compactMap(\.snapshotDate).min() {
            // The oldest live row: every row's data is at least this recent.
            message = "Data from \(oldest.formatted(date: .omitted, time: .standard)) · refreshes every \(Int(model.refreshCadence.rounded())) seconds"
            isWarning = false
        } else {
            message = "Refreshes every \(Int(model.refreshCadence.rounded())) seconds"
            isWarning = false
        }
        if model.hiddenFeedCount > 0 {
            message += " (+\(model.hiddenFeedCount) more \(model.hiddenFeedCount == 1 ? "cluster" : "clusters") not shown)"
        }
        return (message, isWarning)
    }
}
