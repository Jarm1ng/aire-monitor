import AppKit
import SwiftUI

struct MenuBarMonitorView: View {
    @ObservedObject var model: AppModel
    let closeMenu: @MainActor () -> Void

    private var summary: MenuBarSummary {
        MenuBarSummary(
            snapshot: model.snapshot,
            isConnected: model.isLoggedIn,
            hasCache: model.hasCachedSnapshot,
            isRefreshing: model.isRefreshing,
            refreshIntervalText: model.refreshIntervalText
        )
    }

    var body: some View {
        ZStack {
            MenuVisualEffectBackground(material: .popover, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(MenuPalette.backgroundOverlay)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(MenuPalette.border, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 12) {
                header

                HStack(spacing: 8) {
                    MenuMetricTile(title: "Running", value: "\(summary.runningJobs)", color: .green)
                    MenuMetricTile(title: "Pending", value: "\(summary.pendingJobs)", color: .orange)
                    MenuMetricTile(title: "Storage Risk", value: summary.storageRiskLabel, color: summary.storageRiskColor)
                }

                if !summary.attentionJobs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Current Jobs")
                            .font(.caption.weight(.semibold))
                        ForEach(summary.attentionJobs) { job in
                            MenuJobRow(job: job)
                        }
                        if summary.attentionOverflowCount > 0 {
                            Text("+\(summary.attentionOverflowCount) more - open the dashboard for the full list")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .menuSectionSurface()
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    Text("No running or pending jobs in the latest snapshot.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .menuSectionSurface()
                }

                if !summary.storageRows.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Storage")
                            .font(.caption.weight(.semibold))
                        ForEach(summary.storageRows) { row in
                            MenuStorageRow(row: row)
                        }
                    }
                    .menuSectionSurface()
                    .transition(.opacity)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("GPU Allocation")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(summary.allocatedGPUs)/\(summary.totalGPUs)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    MenuUsageBar(value: summary.gpuUsageFraction, color: summary.gpuUsageColor)
                    Text(summary.gpuCaption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .menuSectionSurface()

                Divider()
                    .opacity(0.55)

                HStack(spacing: 8) {
                    Button {
                        model.refresh()
                    } label: {
                        Label(model.isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isRefreshing || model.isLoggingIn)

                    Button {
                        closeMenu()
                        DashboardWindowPresenter.shared.show()
                    } label: {
                        Label("Open", systemImage: "macwindow")
                    }

                    Button {
                        closeMenu()
                        model.openDesktopWidget()
                    } label: {
                        Label("Widget", systemImage: "rectangle.on.rectangle.angled")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(12)
        }
        .frame(width: 370)
        .animation(AIRETheme.smoothEase, value: summary.runningJobs)
        .animation(AIRETheme.smoothEase, value: summary.pendingJobs)
        .animation(AIRETheme.smoothEase, value: summary.storageRiskLabel)
    }

    private var header: some View {
        HStack(spacing: 8) {
            AIRELogoMark(cornerRadius: 7)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("AIRE Monitor")
                        .font(.headline.weight(.semibold))
                    Circle()
                        .fill(summary.statusColor)
                        .frame(width: 7, height: 7)
                        .shadow(color: summary.statusColor.opacity(0.28), radius: 3, x: 0, y: 0)
                }
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let collected = summary.collectedDate {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Updated \(menuRelativeAge(from: collected, to: context.date))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var statusLine: String {
        if model.isLoggingIn {
            return model.loginProgress ?? "Signing in - watch for a Duo push"
        }
        return summary.statusText
    }
}

private struct MenuMetricTile: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(color.opacity(0.09))
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(color.opacity(0.14), lineWidth: 1)
        )
    }
}

private struct MenuUsageBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(MenuPalette.fill)
                RoundedRectangle(cornerRadius: 4)
                    .fill(color)
                    .frame(width: max(proxy.size.width * CGFloat(value), value > 0 ? 7 : 0))
                    .animation(AIRETheme.smoothEase, value: value)
            }
        }
        .frame(height: 9)
    }
}

private struct MenuStorageRow: View {
    let row: MenuStorageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(row.percentLabel)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(row.color)
            }
            HStack(spacing: 6) {
                Text(row.spaceDetail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(row.fileDetail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            MenuUsageBar(value: row.riskFraction, color: row.color)
        }
    }
}

private struct MenuJobRow: View {
    let job: MenuJobSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(job.color.opacity(0.18))
                    .frame(width: 24, height: 24)
                    .overlay(
                        Image(systemName: job.iconName)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(job.color)
                    )
                Text(job.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(job.state)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(job.color)
                    .lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(job.jobId) - \(job.partition) - \(job.elapsed)/\(job.timeLimit)")
                    .lineLimit(1)
                Text(job.location)
                    .lineLimit(1)
                Text(job.resourceSummary)
                    .lineLimit(2)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(MenuPalette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(MenuPalette.border, lineWidth: 1)
        )
    }
}

private struct MenuBarSummary {
    let snapshot: ClusterSnapshot?
    let isConnected: Bool
    let hasCache: Bool
    let isRefreshing: Bool
    let refreshIntervalText: String

    private static let maxAttentionJobs = 3

    var gpuNodes: [NodeSummary] {
        snapshot?.nodes.filter { gpuTotal($0) > 0 } ?? []
    }

    var totalGPUs: Int {
        gpuNodes.reduce(0) { $0 + gpuTotal($1) }
    }

    var allocatedGPUs: Int {
        gpuNodes.reduce(0) { $0 + gpuAllocated($1) }
    }

    var idleGPUs: Int {
        gpuNodes.reduce(0) { $0 + gpuIdle($1) }
    }

    var runningJobs: Int {
        snapshot?.jobs.filter { isRunningJobState($0.state) }.count ?? 0
    }

    var pendingJobs: Int {
        snapshot?.jobs.filter { isPendingJobState($0.state) }.count ?? 0
    }

    var gpuUsageFraction: Double {
        guard totalGPUs > 0 else {
            return 0
        }
        return min(Double(allocatedGPUs) / Double(totalGPUs), 1)
    }

    var gpuUsageColor: Color {
        if totalGPUs == 0 {
            return .secondary
        }
        if idleGPUs == 0 {
            return .red
        }
        if gpuUsageFraction >= 0.75 {
            return .orange
        }
        return .green
    }

    var statusColor: Color {
        if isConnected {
            return .green
        }
        if hasCache {
            return .orange
        }
        return .gray
    }

    var statusText: String {
        if isRefreshing {
            return isConnected ? "Syncing live data" : "Checking AIRE session"
        }
        if isConnected {
            return "Live - refreshes every \(refreshIntervalText)"
        }
        if hasCache {
            return "Cached/offline - retrying every \(refreshIntervalText)"
        }
        return "Offline - waiting for first snapshot"
    }

    var collectedDate: Date? {
        snapshot.flatMap { menuParseISODate($0.collectedAt) }
    }

    var gpuCaption: String {
        if totalGPUs == 0 {
            return "GPU information will appear after the next snapshot."
        }
        return "\(idleGPUs) free of \(totalGPUs) GPUs across \(gpuNodes.count) GPU nodes."
    }

    var storageRows: [MenuStorageSummary] {
        (snapshot?.storage ?? [])
            .filter { ["home", "scratch"].contains($0.label.lowercased()) }
            .map(MenuStorageSummary.init(storage:))
            .sorted { lhs, rhs in
                storageSortRank(lhs.label) < storageSortRank(rhs.label)
            }
    }

    var storageRiskLabel: String {
        guard let row = storageRows.max(by: { $0.riskPercent < $1.riskPercent }) else {
            return "n/a"
        }
        return "\(row.label) \(Int(row.riskPercent.rounded()))%"
    }

    var storageRiskColor: Color {
        guard let row = storageRows.max(by: { $0.riskPercent < $1.riskPercent }) else {
            return .secondary
        }
        return row.color
    }

    private var sortedAttentionJobs: [Job] {
        (snapshot?.jobs ?? [])
            .filter { jobRank($0.state) < 2 }
            .sorted { lhs, rhs in
                let lhsRank = jobRank(lhs.state)
                let rhsRank = jobRank(rhs.state)
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
                return lhs.jobId < rhs.jobId
            }
    }

    var attentionJobs: [MenuJobSummary] {
        sortedAttentionJobs
            .prefix(Self.maxAttentionJobs)
            .map(MenuJobSummary.init(job:))
    }

    var attentionOverflowCount: Int {
        max(sortedAttentionJobs.count - Self.maxAttentionJobs, 0)
    }
}

private struct MenuStorageSummary: Identifiable {
    let id: String
    let label: String
    let usedFraction: Double
    let fileFraction: Double?
    let riskFraction: Double
    let riskPercent: Double
    let percentLabel: String
    let spaceDetail: String
    let fileDetail: String
    let color: Color

    init(storage: StorageSummary) {
        id = storage.label
        label = storage.label.capitalized
        let percent = storage.usedPercent
        usedFraction = menuFraction(percent)

        let fileLimit = storage.fileLimit ?? storage.fileQuota
        if let fileCount = storage.fileCount, let fileLimit, fileLimit > 0 {
            fileFraction = min(Double(fileCount) / Double(fileLimit), 1)
        } else {
            fileFraction = nil
        }

        riskFraction = max(usedFraction, fileFraction ?? 0)
        riskPercent = riskFraction * 100

        // Show whichever pressure dominates, qualified so the tile and the
        // row never appear to disagree (e.g. "95% files" vs a 40% space bar).
        if let fileFraction, fileFraction > usedFraction {
            percentLabel = "\(Int((fileFraction * 100).rounded()))% files"
        } else {
            percentLabel = percent.map { "\(Int($0.rounded()))%" } ?? "n/a"
        }
        spaceDetail = "\(menuFormatGB(storage.availableGB)) free / \(menuFormatGB(storage.quotaGB)) quota / \(menuFormatGB(storage.limitGB)) limit"

        if let fileFraction {
            fileDetail = "files \(Int((fileFraction * 100).rounded()))%"
        } else {
            fileDetail = "files n/a"
        }

        if riskPercent >= 90 {
            color = .red
        } else if riskPercent >= 80 {
            color = .orange
        } else {
            // Matches the dashboard's storage accent instead of a stray blue.
            color = .teal
        }
    }
}

private struct MenuJobSummary: Identifiable {
    let id: String
    let name: String
    let jobId: String
    let partition: String
    let state: String
    let elapsed: String
    let timeLimit: String
    let location: String
    let resourceSummary: String
    let color: Color
    let iconName: String

    init(job: Job) {
        id = job.id
        name = job.name.isEmpty ? "(unnamed)" : job.name
        jobId = job.jobId
        partition = job.partition.isEmpty ? "n/a" : job.partition
        state = job.state.isEmpty ? "n/a" : job.state
        elapsed = job.elapsed.isEmpty ? "0:00" : job.elapsed
        timeLimit = job.timeLimit.isEmpty ? "n/a" : job.timeLimit
        location = menuJobLocation(job)
        resourceSummary = menuJobResources(job)
        color = SlurmState(parsing: job.state).color
        iconName = isRunningJobState(job.state) ? "play.fill" : "clock.fill"
    }
}

private enum MenuPalette {
    static let backgroundOverlay = Color(nsColor: .windowBackgroundColor).opacity(0.50)
    static let fill = Color.primary.opacity(0.055)
    static let sectionFill = Color.primary.opacity(0.040)
    static let border = Color.primary.opacity(0.085)
}

private struct MenuVisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}

private extension View {
    func menuSectionSurface() -> some View {
        self
            .padding(12)
            .background(MenuPalette.sectionFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(MenuPalette.border, lineWidth: 1)
            )
    }
}

private func isRunningJobState(_ state: String) -> Bool {
    state.uppercased().contains("RUN")
}

private func isPendingJobState(_ state: String) -> Bool {
    state.uppercased().contains("PEND")
}

private func jobRank(_ state: String) -> Int {
    if isRunningJobState(state) {
        return 0
    }
    if isPendingJobState(state) {
        return 1
    }
    return 2
}

private func storageSortRank(_ label: String) -> Int {
    switch label.lowercased() {
    case "home":
        return 0
    case "scratch":
        return 1
    default:
        return 2
    }
}

private func menuFraction(_ percent: Double?) -> Double {
    guard let percent else {
        return 0
    }
    return min(max(percent / 100, 0), 1)
}

private func menuJobLocation(_ job: Job) -> String {
    let value = firstNonEmpty(job.nodeList, job.batchHost, job.reasonOrNodeList, job.nodes)
    if isPendingJobState(job.state) {
        return "reason/node \(value)"
    }
    return "node \(value)"
}

private func menuJobResources(_ job: Job) -> String {
    let parts = [
        menuKeyValue("req", job.reqTres),
        menuKeyValue("alloc", job.allocTres),
        menuKeyValue("node", job.tresPerNode)
    ].compactMap { $0 }

    if !parts.isEmpty {
        return parts.joined(separator: " | ")
    }

    let cpu = job.numCpus.map { "cpu=\($0)" }
    let tasks = job.numTasks.map { "tasks=\($0)" }
    return [cpu, tasks].compactMap { $0 }.joined(separator: " ").nilIfEmpty ?? "resources n/a"
}

private func menuKeyValue(_ key: String, _ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }
    return "\(key) \(menuCompactTres(value))"
}

private func menuCompactTres(_ value: String) -> String {
    value.replacingOccurrences(of: "billing=", with: "bill=")
        .replacingOccurrences(of: "gres/gpu=", with: "gpu=")
}

private func firstNonEmpty(_ values: String?...) -> String {
    for value in values {
        if let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            return trimmed
        }
    }
    return "n/a"
}

private func menuFormatGB(_ value: Double?) -> String {
    guard let value else {
        return "n/a"
    }
    if value >= 1024 {
        return String(format: "%.1f TB", value / 1024)
    }
    if value >= 100 {
        return String(format: "%.0f GB", value)
    }
    return String(format: "%.1f GB", value)
}

private func menuParseISODate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) {
        return date
    }

    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let date = plain.date(from: value) {
        return date
    }

    // Python's datetime.isoformat() emits microsecond fractions that the
    // strict three-digit fractional parser rejects; strip and retry.
    let stripped = value.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    return plain.date(from: stripped)
}

private func menuRelativeAge(from date: Date, to now: Date) -> String {
    let seconds = max(Int(now.timeIntervalSince(date).rounded()), 0)
    if seconds < 5 {
        return "just now"
    }
    if seconds < 60 {
        return "\(seconds)s ago"
    }
    if seconds < 3_600 {
        return "\(seconds / 60)m ago"
    }
    if seconds < 86_400 {
        return "\(seconds / 3_600)h ago"
    }
    return "\(seconds / 86_400)d ago"
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
