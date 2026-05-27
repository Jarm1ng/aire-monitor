import AppKit
import SwiftUI

struct MenuBarMonitorView: View {
    @ObservedObject var model: AppModel

    private var summary: MenuBarSummary {
        MenuBarSummary(
            snapshot: model.snapshot,
            isConnected: model.isLoggedIn,
            hasCache: model.hasCachedSnapshot,
            isRefreshing: model.isRefreshing
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
                .shadow(color: .black.opacity(0.16), radius: 22, x: 0, y: 12)

            VStack(alignment: .leading, spacing: 14) {
                header

                HStack(spacing: 8) {
                    MenuMetricTile(title: "Running", value: "\(summary.runningJobs)", color: .blue)
                    MenuMetricTile(title: "Pending", value: "\(summary.pendingJobs)", color: .orange)
                    MenuMetricTile(title: "Storage Risk", value: summary.storageRiskLabel, color: summary.storageRiskColor)
                }

                if !summary.attentionJobs.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Current Jobs")
                            .font(.caption.weight(.semibold))
                        ForEach(summary.attentionJobs) { job in
                            MenuJobRow(job: job)
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
                    VStack(alignment: .leading, spacing: 7) {
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
                        Text("\(summary.gpuAllocated)/\(summary.gpuTotal)")
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
                        DashboardWindowPresenter.shared.show()
                    } label: {
                        Label("Open", systemImage: "macwindow")
                    }

                    Button {
                        model.openDesktopWidget()
                    } label: {
                        Label("Widget", systemImage: "rectangle.on.rectangle.angled")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(14)
        }
        .frame(width: 370)
        .animation(.easeInOut(duration: 0.24), value: summary.runningJobs)
        .animation(.easeInOut(duration: 0.24), value: summary.pendingJobs)
        .animation(.easeInOut(duration: 0.24), value: summary.storageRiskLabel)
    }

    private var header: some View {
        HStack(spacing: 10) {
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
                Text(summary.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
    }
}

private struct MenuMetricTile: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
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
        .padding(.horizontal, 10)
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
                    .animation(.easeInOut(duration: 0.28), value: value)
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
        VStack(alignment: .leading, spacing: 5) {
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

    var gpuNodes: [NodeSummary] {
        snapshot?.nodes.filter { menuGPUTotal($0) > 0 } ?? []
    }

    var gpuTotal: Int {
        gpuNodes.reduce(0) { $0 + menuGPUTotal($1) }
    }

    var gpuAllocated: Int {
        gpuNodes.reduce(0) { $0 + ($1.gpuAllocated ?? 0) }
    }

    var gpuIdle: Int {
        max(gpuTotal - gpuAllocated, 0)
    }

    var runningJobs: Int {
        snapshot?.jobs.filter { $0.state.uppercased().contains("RUN") }.count ?? 0
    }

    var pendingJobs: Int {
        snapshot?.jobs.filter { $0.state.uppercased().contains("PEND") }.count ?? 0
    }

    var gpuUsageFraction: Double {
        guard gpuTotal > 0 else {
            return 0
        }
        return min(Double(gpuAllocated) / Double(gpuTotal), 1)
    }

    var gpuUsageColor: Color {
        if gpuTotal == 0 {
            return .secondary
        }
        if gpuIdle == 0 {
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
            return "Live - refreshes every 10s"
        }
        if hasCache {
            return "Cached/offline - retrying every 10s"
        }
        return "Offline - waiting for first snapshot"
    }

    var gpuCaption: String {
        if gpuTotal == 0 {
            return "GPU information will appear after the next snapshot."
        }
        return "\(gpuIdle) free of \(gpuTotal) GPUs across \(gpuNodes.count) GPU nodes."
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

    var attentionJobs: [MenuJobSummary] {
        (snapshot?.jobs ?? []).sorted { lhs, rhs in
            jobRank(lhs.state) < jobRank(rhs.state)
        }
        .filter { jobRank($0.state) < 2 }
        .prefix(3)
        .map(MenuJobSummary.init(job:))
    }
}

private struct MenuStorageSummary: Identifiable {
    let id: String
    let label: String
    let shortLabel: String
    let usedFraction: Double
    let fileFraction: Double?
    let riskFraction: Double
    let riskPercent: Double
    let percentLabel: String
    let spaceDetail: String
    let fileDetail: String
    let fileHelpText: String
    let color: Color

    init(storage: StorageSummary) {
        id = storage.label
        label = storage.label.capitalized
        shortLabel = storage.label.lowercased() == "scratch" ? "S" : "H"
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
        percentLabel = percent.map { "\(Int($0.rounded()))%" } ?? "n/a"
        spaceDetail = "\(menuFormatGB(storage.availableGB)) free / \(menuFormatGB(storage.quotaGB)) quota / \(menuFormatGB(storage.limitGB)) limit"

        if let fileFraction {
            fileDetail = "files \(Int((fileFraction * 100).rounded()))%"
            fileHelpText = fileDetail
        } else {
            fileDetail = "files n/a"
            fileHelpText = "files n/a"
        }

        if riskPercent >= 90 {
            color = .red
        } else if riskPercent >= 80 {
            color = .orange
        } else {
            color = .blue
        }
    }
}

private struct MenuJobSummary: Identifiable {
    let id: String
    let name: String
    let menuBarName: String
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
        menuBarName = menuCompactJobName(job.name)
        jobId = job.jobId
        partition = job.partition.isEmpty ? "n/a" : job.partition
        state = job.state.isEmpty ? "n/a" : job.state
        elapsed = job.elapsed.isEmpty ? "0:00" : job.elapsed
        timeLimit = job.timeLimit.isEmpty ? "n/a" : job.timeLimit
        location = menuJobLocation(job)
        resourceSummary = menuJobResources(job)
        color = jobStateColor(job.state)
        iconName = job.state.uppercased().contains("RUN") ? "play.fill" : "clock.fill"
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
            .padding(10)
            .background(MenuPalette.sectionFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(MenuPalette.border, lineWidth: 1)
            )
    }
}

private func menuGPUTotal(_ node: NodeSummary) -> Int {
    if let total = node.gpuTotal {
        return total
    }
    guard node.gres.lowercased().contains("gpu") else {
        return 0
    }
    return Int(node.gres.split(separator: ":").last ?? "") ?? 0
}

private func jobRank(_ state: String) -> Int {
    let value = state.uppercased()
    if value.contains("RUN") {
        return 0
    }
    if value.contains("PEND") {
        return 1
    }
    return 2
}

private func jobStateColor(_ state: String) -> Color {
    let value = state.uppercased()
    if value.contains("RUN") {
        return .green
    }
    if value.contains("PEND") {
        return .orange
    }
    return .secondary
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
    if job.state.uppercased().contains("PEND") {
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

private func menuCompactJobName(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return "Running job"
    }
    if trimmed.count <= 18 {
        return trimmed
    }
    return String(trimmed.prefix(16)) + ".."
}

private func menuKeyValue(_ key: String, _ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }
    return "\(key) \(menuCompactTres(value))"
}

private func menuCompactTres(_ value: String) -> String {
    value.replacingOccurrences(of: "billing=", with: "bill=")
        .replacingOccurrences(of: "mem=", with: "mem=")
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

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
