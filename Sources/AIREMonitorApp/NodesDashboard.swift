import SwiftUI

struct NodesDashboard: View {
    let nodes: [NodeSummary]
    let jobs: [Job]
    // Hoisted into DashboardView so the selection survives tab switches.
    @Binding var filter: NodeFilter
    @Binding var showDetails: Bool
    /// Wired by DashboardView: switches to the terminal tab and opens (or
    /// focuses) a shell on the login node.
    var onOpenShell: (@MainActor () -> Void)? = nil

    /// Exact hostnames the user's jobs occupy, computed once per snapshot
    /// from expanded Slurm node lists (never substring matching).
    private var userBusyNodes: Set<String> {
        busyNodeSet(for: jobs)
    }

    private var gpuNodes: [NodeSummary] {
        nodes.filter { gpuTotal($0) > 0 }.sorted { $0.node < $1.node }
    }

    private var himemNodes: [NodeSummary] {
        nodes.filter { $0.partitions.contains("himem") }.sorted { $0.node < $1.node }
    }

    private var teachingNodes: [NodeSummary] {
        nodes.filter { $0.partitions.contains("teachingnodes") }.sorted { $0.node < $1.node }
    }

    private var cpuNodes: [NodeSummary] {
        nodes.filter {
            gpuTotal($0) == 0
                && $0.partitions.contains("nodes")
                && !$0.partitions.contains("teachingnodes")
        }
        .sorted { $0.node < $1.node }
    }

    /// Nodes outside the four named groups; ensures newly added partitions
    /// are never silently invisible.
    private var otherNodes: [NodeSummary] {
        var classified = Set(gpuNodes.map(\.node))
        classified.formUnion(cpuNodes.map(\.node))
        classified.formUnion(himemNodes.map(\.node))
        classified.formUnion(teachingNodes.map(\.node))
        return nodes.filter { !classified.contains($0.node) }.sorted { $0.node < $1.node }
    }

    private var visibleNodes: [NodeSummary] {
        switch filter {
        case .all:
            return nodes.sorted { $0.node < $1.node }
        case .gpu:
            return gpuNodes
        case .cpu:
            return cpuNodes
        case .himem:
            return himemNodes
        case .teaching:
            return teachingNodes
        case .other:
            return otherNodes
        }
    }

    private var stats: GPUFleetStats {
        GPUFleetStats(nodes: gpuNodes)
    }

    private var gpuSectionSubtitle: String {
        let model = slurmGPUModel(from: gpuNodes.first?.gres ?? "")
        let kind = model.map { "\($0.uppercased()) " } ?? ""
        return "\(gpuNodes.count) \(kind)GPU nodes • \(stats.idle) free GPUs"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(
                title: "Nodes",
                subtitle: "GPU-first visual monitoring with CPU and specialist queues included",
                systemImage: "server.rack",
                accent: AIRETheme.gpu
            ) {
                HStack(spacing: 10) {
                    Picker("Node group", selection: $filter) {
                        ForEach(availableFilters) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(minWidth: 260, idealWidth: 420, maxWidth: 420)
                    .accessibilityLabel("Node group filter")
                    DetailsToggleButton(showDetails: $showDetails)
                }
            }

            if nodes.isEmpty {
                EmptyVisual(
                    title: "No node data yet",
                    subtitle: "Node health and GPU occupancy appear after the next successful refresh.",
                    systemImage: "server.rack"
                )
            } else {
                nodeContent
            }

            if showDetails {
                SectionHeader(title: "Node details", subtitle: "\(visibleNodes.count) rows")
                NodesTable(nodes: visibleNodes)
                    .frame(height: 320)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(AIRETheme.smoothEase, value: showDetails)
        .onChange(of: availableFilters) { newFilters in
            // A refresh can remove the segment the user selected (e.g. the
            // last unclassified node disappears while "Other" is active),
            // stranding the filter on a value with no Picker tag and hiding
            // every section. Clamp back to All when that happens.
            if !newFilters.contains(filter) {
                filter = .all
            }
        }
        .onAppear {
            // The filter is hoisted state, so it can also go stale while this
            // tab is unmounted; re-clamp on every appearance.
            if !availableFilters.contains(filter) {
                filter = .all
            }
        }
    }

    @ViewBuilder
    private var nodeContent: some View {
        GPUFleetPanel(stats: stats, nodes: gpuNodes)

        VStack(alignment: .leading, spacing: 18) {
            if shouldShow(.gpu) {
                NodeSection(
                    title: "GPU training nodes",
                    subtitle: gpuSectionSubtitle,
                    nodes: gpuNodes,
                    busyNodes: userBusyNodes,
                    style: .gpu,
                    onOpenShell: onOpenShell
                )
            }
            if shouldShow(.cpu) {
                NodeSection(
                    title: "CPU nodes",
                    subtitle: "\(cpuNodes.count) general-purpose compute nodes",
                    nodes: cpuNodes,
                    busyNodes: userBusyNodes,
                    style: .cpu,
                    onOpenShell: onOpenShell
                )
            }
            if shouldShow(.himem) {
                NodeSection(
                    title: "High-memory nodes",
                    subtitle: "\(himemNodes.count) large-memory CPU nodes",
                    nodes: himemNodes,
                    busyNodes: userBusyNodes,
                    style: .himem,
                    onOpenShell: onOpenShell
                )
            }
            if shouldShow(.teaching) {
                NodeSection(
                    title: "Teaching nodes",
                    subtitle: "\(teachingNodes.count) teaching partition nodes",
                    nodes: teachingNodes,
                    busyNodes: userBusyNodes,
                    style: .teaching,
                    onOpenShell: onOpenShell
                )
            }
            if shouldShow(.other) && !otherNodes.isEmpty {
                NodeSection(
                    title: "Other nodes",
                    subtitle: otherSectionSubtitle,
                    nodes: otherNodes,
                    busyNodes: userBusyNodes,
                    style: .other,
                    onOpenShell: onOpenShell
                )
            }
        }
        .padding(.vertical, 2)
    }

    private var availableFilters: [NodeFilter] {
        otherNodes.isEmpty ? NodeFilter.allCases.filter { $0 != .other } : NodeFilter.allCases
    }

    /// Section names derived from the data itself.
    private var otherSectionSubtitle: String {
        let partitions = Set(otherNodes.flatMap(\.partitions)).sorted()
        if partitions.isEmpty {
            return "\(otherNodes.count) unclassified nodes"
        }
        return "\(otherNodes.count) nodes in \(partitions.joined(separator: ", "))"
    }

    private func shouldShow(_ option: NodeFilter) -> Bool {
        filter == .all || filter == option
    }
}

enum NodeFilter: String, CaseIterable, Identifiable {
    case all
    case gpu
    case cpu
    case himem
    case teaching
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .gpu:
            return "GPU"
        case .cpu:
            return "CPU"
        case .himem:
            return "HiMem"
        case .teaching:
            return "Teaching"
        case .other:
            return "Other"
        }
    }
}

struct NodesTable: View {
    let nodes: [NodeSummary]

    var body: some View {
        Table(nodes) {
            TableColumn("Node", value: \.node)
            TableColumn("Partitions") { item in
                Text(item.partitions.joined(separator: ", "))
            }
            TableColumn("State", value: \.state)
            TableColumn("CPU") { item in
                Text(cpuText(item))
            }
            TableColumn("GPU") { item in
                Text(gpuText(item))
            }
            TableColumn("Memory MB") { item in
                Text(number(item.memoryMB))
            }
            TableColumn("Free MB") { item in
                Text(number(item.memoryFreeMB))
            }
            TableColumn("Watts") { item in
                Text(number(item.currentWatts))
            }
            TableColumn("GRES", value: \.gres)
            TableColumn("Reason", value: \.reason)
        }
    }
}

struct GPUFleetStats {
    let nodes: [NodeSummary]

    var total: Int {
        nodes.reduce(0) { $0 + gpuTotal($1) }
    }

    var allocated: Int {
        nodes.reduce(0) { $0 + gpuAllocated($1) }
    }

    var idle: Int {
        max(total - allocated, 0)
    }

    var utilizationPercent: Int {
        guard total > 0 else { return 0 }
        return Int((Double(allocated) / Double(total) * 100).rounded())
    }

    var mixedNodes: Int {
        nodes.filter {
            let used = gpuAllocated($0)
            let all = gpuTotal($0)
            return used > 0 && used < all && isAvailable($0)
        }.count
    }

    var nodesWithIdle: Int {
        nodes.filter { gpuIdle($0) > 0 && isAvailable($0) }.count
    }

    var unavailableNodes: Int {
        nodes.filter { !isAvailable($0) }.count
    }

    var utilizationColor: Color {
        if utilizationPercent >= 90 {
            return .red
        }
        if utilizationPercent >= 70 {
            return .orange
        }
        return AIRETheme.gpu
    }
}

struct GPUFleetPanel: View {
    let stats: GPUFleetStats
    let nodes: [NodeSummary]

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            RingMeter(
                value: Double(stats.utilizationPercent) / 100,
                color: stats.utilizationColor,
                label: "GPU use"
            )
            .frame(width: 118, height: 118)

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "GPU fleet", subtitle: "\(stats.allocated)/\(stats.total) GPUs allocated")
                GPUFleetBar(stats: stats)
                // At the 1000pt minimum window width the middle column can get
                // too narrow for three chips in a row; stack them instead of
                // letting the card's clip shape cut them off.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        fleetChips
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        fleetChips
                    }
                }
            }

            Divider()
                .frame(height: 120)

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Node heatmap", subtitle: "\(nodes.count) GPU nodes")
                GPUNodeHeatmap(nodes: nodes)
                HeatmapLegend()
            }
            .frame(minWidth: 200, idealWidth: 310, maxWidth: 310)
        }
        .dashboardCard(accent: AIRETheme.gpu)
        .animation(AIRETheme.smoothEase, value: stats.utilizationPercent)
    }

    @ViewBuilder
    private var fleetChips: some View {
        InfoChip(label: "Free", value: "\(stats.idle)", systemImage: "checkmark.circle.fill", color: .green)
        InfoChip(label: "Mixed", value: "\(stats.mixedNodes)", systemImage: "circle.lefthalf.filled", color: .orange)
        InfoChip(label: "Unavailable", value: "\(stats.unavailableNodes)", systemImage: "exclamationmark.triangle.fill", color: .red)
    }
}

struct GPUNodeHeatmap: View {
    let nodes: [NodeSummary]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 20, maximum: 24), spacing: 5)], spacing: 5) {
            ForEach(nodes) { node in
                let available = isAvailable(node)
                RoundedRectangle(cornerRadius: 4)
                    .fill(color(for: node, available: available))
                    .frame(height: 18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .overlay {
                        // Non-color cue so unavailable nodes remain distinguishable.
                        if !available {
                            Image(systemName: "line.diagonal")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    }
                    .help("\(node.node): \(gpuAllocated(node))/\(gpuTotal(node)) GPU, \(node.state)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(node.node)
                    .accessibilityValue(
                        available
                            ? "\(gpuAllocated(node)) of \(gpuTotal(node)) GPUs allocated"
                            : "unavailable, \(node.state)"
                    )
                    .animation(AIRETheme.smoothEase, value: node.state)
            }
        }
    }

    private func color(for node: NodeSummary, available: Bool) -> Color {
        if !available {
            return .red.opacity(0.65)
        }
        let total = max(gpuTotal(node), 1)
        let ratio = Double(gpuAllocated(node)) / Double(total)
        if ratio >= 1 {
            return AIRETheme.gpu.opacity(0.85)
        }
        if ratio > 0 {
            return .orange.opacity(0.85)
        }
        return .green.opacity(0.78)
    }
}

/// Compact labeled legend so the heatmap encoding is discoverable.
struct HeatmapLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            legendDot(color: .green.opacity(0.78), label: "Free")
            legendDot(color: .orange.opacity(0.85), label: "Mixed")
            legendDot(color: AIRETheme.gpu.opacity(0.85), label: "Full")
            legendDot(color: .red.opacity(0.65), label: "Down", slashed: true)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Legend: green free, orange mixed, cyan full, red slashed unavailable")
    }

    private func legendDot(color: Color, label: String, slashed: Bool = false) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(color)
                .frame(width: 9, height: 9)
                .overlay {
                    if slashed {
                        Image(systemName: "line.diagonal")
                            .font(.system(size: 6, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
            Text(label)
        }
    }
}

struct GPUFleetBar: View {
    let stats: GPUFleetStats

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let allocatedWidth = width * CGFloat(stats.total == 0 ? 0 : Double(stats.allocated) / Double(stats.total))
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.green.opacity(0.22))
                    RoundedRectangle(cornerRadius: 5)
                        .fill(stats.utilizationColor.opacity(0.82))
                        .frame(width: allocatedWidth)
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .frame(height: 10)
            .animation(AIRETheme.softSpring, value: stats.allocated)

            HStack {
                Label("\(stats.allocated) allocated", systemImage: "circle.fill")
                    .foregroundStyle(stats.utilizationColor)
                Spacer()
                Label("\(stats.idle) free", systemImage: "circle.fill")
                    .foregroundStyle(.green)
            }
            .font(.caption.monospacedDigit())
        }
        .animation(AIRETheme.smoothEase, value: stats.idle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("GPU allocation")
        .accessibilityValue("\(stats.allocated) allocated, \(stats.idle) free of \(stats.total)")
    }
}

enum NodeVisualStyle {
    case gpu
    case cpu
    case himem
    case teaching
    case other
}

struct NodeSection: View {
    let title: String
    let subtitle: String
    let nodes: [NodeSummary]
    let busyNodes: Set<String>
    let style: NodeVisualStyle
    var onOpenShell: (@MainActor () -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(nodes.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if nodes.isEmpty {
                EmptyVisual(title: "No nodes in this group", subtitle: "Nothing to show for the current filter.", systemImage: "tray")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cardWidth, maximum: 280), spacing: 10)], spacing: 10) {
                    ForEach(nodes) { node in
                        Group {
                            if style == .gpu {
                                GPUNodeCard(node: node, hasUserJob: busyNodes.contains(node.node))
                            } else {
                                GeneralNodeCard(node: node, style: style, hasUserJob: busyNodes.contains(node.node))
                            }
                        }
                        .contextMenu {
                            if let onOpenShell {
                                Button {
                                    onOpenShell()
                                } label: {
                                    Label("Open shell on login node", systemImage: "terminal")
                                }
                            }
                        }
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .top)))
            }
        }
    }

    private var cardWidth: CGFloat {
        style == .gpu ? 205 : 190
    }
}

struct GPUNodeCard: View {
    let node: NodeSummary
    let hasUserJob: Bool

    private var total: Int { gpuTotal(node) }
    private var allocated: Int { gpuAllocated(node) }
    private var cpuRatio: Double {
        guard let allocated = node.cpuAllocated, let total = node.cpuTotal, total > 0 else {
            return 0
        }
        return min(Double(allocated) / Double(total), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.node)
                        .font(.headline.monospacedDigit())
                    Text(node.partitions.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatePill(state: node.state)
            }

            HStack(spacing: 6) {
                ForEach(0..<max(total, 1), id: \.self) { index in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(gpuSlotColor(index: index))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                        .frame(height: 28)
                }
            }
            .accessibilityLabel("GPU \(allocated) of \(total)")

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("GPU")
                    Spacer()
                    Text("\(allocated)/\(total)")
                        .monospacedDigit()
                }
                .font(.caption)

                HStack {
                    Text("CPU")
                    Spacer()
                    Text(cpuText(node))
                        .monospacedDigit()
                }
                .font(.caption)

                ProgressView(value: cpuRatio)
                    .tint(cpuRatio > 0.85 ? .orange : AIRETheme.cpu)
                    .accessibilityLabel("CPU usage")
                    .accessibilityValue("\(Int((cpuRatio * 100).rounded())) percent")
            }

            HStack(spacing: 8) {
                if let watts = node.currentWatts {
                    Label("\(watts)W", systemImage: "bolt.fill")
                }
                if let free = node.memoryFreeMB {
                    Label("\(free / 1024)G free", systemImage: "memorychip")
                }
                if hasUserJob {
                    Label("your job", systemImage: "person.crop.circle")
                        .foregroundStyle(.purple)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(12)
        .nodeCardChrome(highlighted: hasUserJob, tint: cardTint)
        .animation(AIRETheme.smoothEase, value: allocated)
        .animation(AIRETheme.smoothEase, value: node.state)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("GPU node \(node.node)")
    }

    private var cardTint: Color {
        if !isAvailable(node) {
            return Color.gray.opacity(0.12)
        }
        if gpuIdle(node) > 0 {
            return AIRETheme.panelBackground
        }
        return AIRETheme.gpu.opacity(0.08)
    }

    /// Slot colors mirror the fleet heatmap legend: cyan allocated, green free.
    private func gpuSlotColor(index: Int) -> Color {
        if !isAvailable(node) {
            return .gray.opacity(0.35)
        }
        if index < allocated {
            return AIRETheme.gpu.opacity(0.85)
        }
        return .green.opacity(0.75)
    }
}

struct GeneralNodeCard: View {
    let node: NodeSummary
    let style: NodeVisualStyle
    let hasUserJob: Bool

    private var cpuRatio: Double {
        guard let allocated = node.cpuAllocated, let total = node.cpuTotal, total > 0 else {
            return 0
        }
        return min(Double(allocated) / Double(total), 1)
    }

    private var memoryRatio: Double {
        guard let allocated = node.memoryAllocatedMB, let total = node.memoryMB, total > 0 else {
            return 0
        }
        return min(Double(allocated) / Double(total), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.node)
                        .font(.headline.monospacedDigit())
                    Text(node.partitions.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                StatePill(state: node.state)
            }

            RingMeter(value: cpuRatio, color: accentColor, label: "CPU")
                .frame(height: 78)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("CPU")
                    Spacer()
                    Text(cpuText(node))
                        .monospacedDigit()
                }
                ProgressView(value: cpuRatio)
                    .tint(accentColor)

                HStack {
                    Text("Memory")
                    Spacer()
                    Text(memoryText)
                        .monospacedDigit()
                }
                ProgressView(value: memoryRatio)
                    .tint(memoryRatio > 0.85 ? .orange : .purple)
            }
            .font(.caption)

            HStack(spacing: 8) {
                if let load = node.cpuLoad {
                    Label(String(format: "%.1f load", load), systemImage: "waveform.path.ecg")
                }
                if hasUserJob {
                    Label("your job", systemImage: "person.crop.circle")
                        .foregroundStyle(.purple)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(12)
        .nodeCardChrome(highlighted: hasUserJob, tint: cardTint)
        .animation(AIRETheme.smoothEase, value: cpuRatio)
        .animation(AIRETheme.smoothEase, value: node.state)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Node \(node.node)")
    }

    private var accentColor: Color {
        switch style {
        case .gpu:
            return .blue
        case .cpu:
            return .teal
        case .himem:
            return .purple
        case .teaching:
            return .indigo
        case .other:
            return .gray
        }
    }

    private var cardTint: Color {
        if !isAvailable(node) {
            return Color.gray.opacity(0.12)
        }
        return accentColor.opacity(0.08)
    }

    private var memoryText: String {
        guard let allocated = node.memoryAllocatedMB, let total = node.memoryMB else {
            return missingValuePlaceholder
        }
        return "\(allocated / 1024)/\(total / 1024)G"
    }
}

/// Shared chrome for node cards: material fill, tint, and the purple
/// "your job" highlight ring. Node cards are informational, so they do
/// not lift or scale on hover.
private struct NodeCardChrome: ViewModifier {
    let highlighted: Bool
    let tint: Color

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(tint)
                    }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(highlighted ? Color.purple.opacity(0.55) : AIRETheme.border, lineWidth: highlighted ? 1.5 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
    }
}

private extension View {
    func nodeCardChrome(highlighted: Bool, tint: Color) -> some View {
        modifier(NodeCardChrome(highlighted: highlighted, tint: tint))
    }
}
