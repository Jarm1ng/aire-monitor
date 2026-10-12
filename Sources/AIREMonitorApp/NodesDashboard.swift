import SwiftUI

/// The Nodes tab for one cluster. Nodes are grouped by what their partitions
/// are for — GPU, CPU, high-memory, teaching, other — using the cluster
/// profile's `PartitionHint`s rather than hard-coded partition names, so
/// AIRE (`gpu`, `nodes`, `himem`, `teachingnodes`) and Calder
/// (`calder-gpu-hopper`, `calder-cpu-turin`) share one code path and a
/// partition added later still lands in a sensible group.
///
/// The caller passes ONE cluster's nodes and jobs. Node names are only
/// unique within a cluster, and an L40S fleet and an H200 fleet are
/// different pools, so nothing here may ever mix two clusters' data.
struct NodesDashboard: View {
    let profile: ClusterProfile
    let nodes: [NodeSummary]
    let jobs: [Job]
    // Hoisted into the cluster's ClusterDashboardState so the selection
    // survives tab switches.
    @Binding var filter: NodeFilter
    @Binding var showDetails: Bool
    /// Wired by the cluster dashboard: switches to the terminal tab and opens
    /// (or focuses) a shell on this cluster's login node.
    var onOpenShell: (@MainActor () -> Void)? = nil

    var body: some View {
        // Classified once per render; header, filter, fleet panel, sections
        // and table all read the same grouping.
        let grouping = NodeGrouping(profile: profile, nodes: nodes)
        // A stored filter naming a group this cluster does not have (or no
        // longer has) behaves as All until the clamp below rewrites it.
        let activeFilter = grouping.effectiveFilter(filter)
        let visibleNodes = grouping.nodes(for: activeFilter)

        VStack(alignment: .leading, spacing: 14) {
            PageHeader(
                title: "\(profile.displayName) nodes",
                subtitle: headerSubtitle(grouping),
                systemImage: "server.rack",
                accent: AppTheme.gpu
            ) {
                HStack(spacing: 10) {
                    // One group needs no filter: "All" and it would be the same view.
                    if grouping.availableFilters.count > 2 {
                        Picker("Node group", selection: $filter) {
                            ForEach(grouping.availableFilters) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel("Node group filter")
                    }
                    DetailsToggleButton(showDetails: $showDetails)
                }
            }

            if nodes.isEmpty {
                EmptyVisual(
                    title: "No node data yet",
                    subtitle: "\(profile.displayName) node health and GPU occupancy appear after the next successful refresh.",
                    systemImage: "server.rack"
                )
            } else {
                nodeContent(grouping: grouping, filter: activeFilter)
            }

            if showDetails {
                SectionHeader(title: "Node details", subtitle: "\(visibleNodes.count) rows")
                NodesTable(nodes: visibleNodes)
                    .frame(height: 320)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(AppTheme.smoothEase, value: showDetails)
        .onChange(of: grouping.availableFilters) { newFilters in
            // A refresh can empty the group the user selected (e.g. the last
            // unclassified node disappears while "Other" is active); clamp
            // back to All so the Picker never holds a value with no segment.
            clampFilter(to: newFilters)
        }
        .onAppear {
            // The filter is hoisted state, so it can also go stale while this
            // tab is unmounted; re-clamp on every appearance.
            clampFilter(to: grouping.availableFilters)
        }
    }

    @ViewBuilder
    private func nodeContent(grouping: NodeGrouping, filter: NodeFilter) -> some View {
        let gpuNodes = grouping.nodes(in: .gpu)
        let stats = GPUFleetStats(nodes: gpuNodes)
        // Exact hostnames the user's jobs occupy on THIS cluster, computed
        // once per render from expanded Slurm node lists (never substrings).
        let busyNodes = busyNodeSet(for: jobs)

        if !gpuNodes.isEmpty && filter.includes(.gpu) {
            GPUFleetPanel(stats: stats, nodes: gpuNodes)
        }

        VStack(alignment: .leading, spacing: 18) {
            ForEach(grouping.roles, id: \.self) { role in
                if filter.includes(role) {
                    NodeSection(
                        title: NodeGrouping.sectionTitle(for: role),
                        subtitle: sectionSubtitle(for: role, grouping: grouping, stats: stats),
                        nodes: grouping.nodes(in: role),
                        busyNodes: busyNodes,
                        style: role,
                        clusterName: profile.displayName,
                        onOpenShell: onOpenShell
                    )
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// "105 nodes · 7 GPU · 98 CPU", or the cluster tagline before the
    /// first snapshot arrives.
    private func headerSubtitle(_ grouping: NodeGrouping) -> String {
        guard !nodes.isEmpty else {
            return profile.tagline
        }
        let counts = grouping.roles.map { "\(grouping.nodes(in: $0).count) \(NodeGrouping.shortNoun(for: $0))" }
        return (["\(nodes.count) nodes"] + counts).joined(separator: " · ")
    }

    /// Where the group's nodes live and what each one offers, e.g.
    /// "calder-gpu-hopper · 8 × H200 per node · 27 free GPUs" or
    /// "calder-cpu-turin · 128 cores, 754 GB per node · 4210 of 12544 cores allocated".
    private func sectionSubtitle(for role: PartitionRole, grouping: NodeGrouping, stats: GPUFleetStats) -> String {
        let members = grouping.nodes(in: role)
        let partitions = grouping.partitionNames(in: role)
        var parts = [partitions.isEmpty ? "no partition" : partitions.joined(separator: ", ")]
        if role == .gpu {
            if let shape = gpuShapeText(members) {
                parts.append(shape)
            }
            parts.append(stats.free == 1 ? "1 free GPU" : "\(stats.free) free GPUs")
        } else {
            if let shape = cpuShapeText(members) {
                parts.append(shape)
            }
            if let usage = coreUsageText(members) {
                parts.append(usage)
            }
        }
        return parts.joined(separator: " · ")
    }

    private func clampFilter(to available: [NodeFilter]) {
        // Without data every group is empty; keep the user's choice until
        // the first snapshot can say whether the group exists.
        guard !nodes.isEmpty, !available.contains(filter) else {
            return
        }
        filter = .all
    }
}

// MARK: - Grouping

/// Node-group filter for the Nodes tab. The cases mirror `PartitionRole`, so
/// the type is the same for every cluster, but the dashboard only offers the
/// groups that actually have nodes on the cluster being shown (Calder has no
/// high-memory or teaching segment).
enum NodeFilter: String, CaseIterable, Identifiable {
    case all
    case gpu
    case cpu
    case highMemory
    case teaching
    case other

    init(role: PartitionRole) {
        switch role {
        case .gpu:
            self = .gpu
        case .cpu:
            self = .cpu
        case .highMemory:
            self = .highMemory
        case .teaching:
            self = .teaching
        case .other:
            self = .other
        }
    }

    var id: String { rawValue }

    /// The group this filter selects; nil for All.
    var role: PartitionRole? {
        switch self {
        case .all:
            return nil
        case .gpu:
            return .gpu
        case .cpu:
            return .cpu
        case .highMemory:
            return .highMemory
        case .teaching:
            return .teaching
        case .other:
            return .other
        }
    }

    var title: String {
        role?.title ?? "All"
    }

    func includes(_ role: PartitionRole) -> Bool {
        self == .all || self.role == role
    }
}

/// One pass over a cluster's nodes, putting every node in exactly one group
/// so the section counts add up to the node total.
private struct NodeGrouping {
    /// GPU first: it is the scarce pool people come to this tab for.
    static let displayOrder: [PartitionRole] = [.gpu, .cpu, .highMemory, .teaching, .other]

    let profile: ClusterProfile
    let sortedNodes: [NodeSummary]
    private let byRole: [PartitionRole: [NodeSummary]]

    init(profile: ClusterProfile, nodes: [NodeSummary]) {
        self.profile = profile
        // Natural order, so a future `node9` sorts before `node10`.
        let sorted = nodes.sorted { $0.node.localizedStandardCompare($1.node) == .orderedAscending }
        sortedNodes = sorted
        byRole = Dictionary(grouping: sorted) { NodeGrouping.role(of: $0, on: profile) }
    }

    /// The group a node is shown in:
    /// 1. GPU when it has GPUs or sits in a partition the profile calls GPU
    ///    (a drained GPU node can report no GPUs but still belongs there);
    /// 2. otherwise the most specialised role the profile gives any of its
    ///    partitions — high-memory, then teaching, then CPU — because a node
    ///    in both a general and a specialist partition is distinct for the
    ///    specialist reason, and this keeps the result independent of the
    ///    order Slurm lists partitions in;
    /// 3. otherwise (partitions the profile does not know) CPU when it has
    ///    CPUs, else Other, so a new partition is never invisible.
    static func role(of node: NodeSummary, on profile: ClusterProfile) -> PartitionRole {
        let hinted = Set(node.partitions.compactMap { profile.role(forPartition: $0) })
        if gpuTotal(node) > 0 || hinted.contains(.gpu) {
            return .gpu
        }
        for role in [PartitionRole.highMemory, .teaching, .cpu, .other] where hinted.contains(role) {
            return role
        }
        return (node.cpuTotal ?? 0) > 0 ? .cpu : .other
    }

    static func sectionTitle(for role: PartitionRole) -> String {
        switch role {
        case .gpu:
            return "GPU nodes"
        case .cpu:
            return "CPU nodes"
        case .highMemory:
            return "High-memory nodes"
        case .teaching:
            return "Teaching nodes"
        case .other:
            return "Other nodes"
        }
    }

    /// Noun for counts in running text: "7 GPU", "4 high-memory".
    static func shortNoun(for role: PartitionRole) -> String {
        switch role {
        case .gpu:
            return "GPU"
        case .cpu:
            return "CPU"
        case .highMemory:
            return "high-memory"
        case .teaching:
            return "teaching"
        case .other:
            return "other"
        }
    }

    /// Non-empty groups in display order.
    var roles: [PartitionRole] {
        NodeGrouping.displayOrder.filter { !(byRole[$0] ?? []).isEmpty }
    }

    var availableFilters: [NodeFilter] {
        [.all] + roles.map(NodeFilter.init(role:))
    }

    func effectiveFilter(_ filter: NodeFilter) -> NodeFilter {
        availableFilters.contains(filter) ? filter : .all
    }

    func nodes(in role: PartitionRole) -> [NodeSummary] {
        byRole[role] ?? []
    }

    func nodes(for filter: NodeFilter) -> [NodeSummary] {
        filter.role.map(nodes(in:)) ?? sortedNodes
    }

    /// Every partition the group's nodes belong to, in profile order, then
    /// by name for partitions the profile does not know.
    func partitionNames(in role: PartitionRole) -> [String] {
        let names = Set(nodes(in: role).flatMap(\.partitions))
        return names.sorted { lhs, rhs in
            let lhsRank = profile.hint(forPartition: lhs)?.sortRank ?? Int.max
            let rhsRank = profile.hint(forPartition: rhs)?.sortRank ?? Int.max
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }
}

// MARK: - Shape text

/// "8 × H200 per node"; "4–8 × L40S per node" for uneven nodes;
/// "H200 / A100" when one group mixes models. Nil without GPUs.
private func gpuShapeText(_ nodes: [NodeSummary]) -> String? {
    let counts = nodes.map(gpuTotal).filter { $0 > 0 }
    guard let count = rangeText(counts, format: { "\($0)" }) else {
        return nil
    }
    let models = orderedUnique(nodes.compactMap { slurmGPUModelDisplayName(from: $0.gres) })
    if models.isEmpty {
        return "\(count) GPUs per node"
    }
    return "\(count) × \(models.joined(separator: " / ")) per node"
}

/// "128 cores, 754 GB per node", "128–192 cores, …" for a spread. Memory is
/// Slurm's MiB through the app's 1024-based formatGB, so Calder GPU nodes
/// read "1.5 TB".
private func cpuShapeText(_ nodes: [NodeSummary]) -> String? {
    let cores = rangeText(nodes.compactMap(\.cpuTotal).filter { $0 > 0 }, format: { "\($0)" })
        .map { "\($0) cores" }
    let memory = rangeText(nodes.compactMap(\.memoryMB).filter { $0 > 0 }, format: { formatGB(Double($0) / 1024) })
    let pieces = [cores, memory].compactMap { $0 }
    return pieces.isEmpty ? nil : pieces.joined(separator: ", ") + " per node"
}

/// "4210 of 12544 cores allocated" across the group.
private func coreUsageText(_ nodes: [NodeSummary]) -> String? {
    let total = nodes.reduce(0) { $0 + ($1.cpuTotal ?? 0) }
    guard total > 0 else {
        return nil
    }
    let allocated = nodes.reduce(0) { $0 + ($1.cpuAllocated ?? 0) }
    return "\(allocated) of \(total) cores allocated"
}

/// "128" for uniform values, "64–168" for a spread. Compared after
/// formatting so near-identical memory sizes do not print "754 GB–754 GB".
private func rangeText(_ values: [Int], format: (Int) -> String) -> String? {
    guard let low = values.min(), let high = values.max() else {
        return nil
    }
    let lowText = format(low)
    let highText = format(high)
    return lowText == highText ? lowText : "\(lowText)–\(highText)"
}

private func orderedUnique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
}

// MARK: - Table

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

// MARK: - GPU fleet

/// GPU totals for ONE cluster's GPU nodes. Never build this from two
/// clusters' nodes: an L40S and an H200 are not interchangeable, so a mixed
/// percentage would mean nothing.
struct GPUFleetStats {
    let nodes: [NodeSummary]
    let total: Int
    let allocated: Int
    /// Idle GPUs on nodes that can take work. Same definition as
    /// `ClusterSession.gpuAvailability`, so this panel, the sidebar, the
    /// overview and the menu bar agree.
    let free: Int
    /// Display names of the GPU models present, in node order.
    let models: [String]

    init(nodes: [NodeSummary]) {
        self.nodes = nodes
        total = nodes.reduce(0) { $0 + gpuTotal($1) }
        allocated = nodes.reduce(0) { $0 + gpuAllocated($1) }
        free = nodes.filter(isAvailable).reduce(0) { $0 + gpuIdle($1) }
        models = orderedUnique(nodes.compactMap { slurmGPUModelDisplayName(from: $0.gres) })
    }

    /// Idle GPUs stranded on drained or down nodes (e.g. Calder's
    /// `calder-h200-05` while IDLE+DRAIN): not allocated, not usable either.
    var offline: Int {
        max(total - allocated - free, 0)
    }

    /// "H200", "H200 / A100" for a mixed fleet, nil when gres names no model.
    var modelName: String? {
        models.isEmpty ? nil : models.joined(separator: " / ")
    }

    /// Unit for counts: "H200" or "GPUs".
    var unit: String {
        modelName ?? "GPUs"
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
        return AppTheme.gpu
    }
}

/// The colours of the GPU heatmap, its legend and the slots on GPU node
/// cards, defined once so the three never drift apart. `colorName`s feed the
/// legend's accessibility label and must describe the colours above them.
enum GPUSlotPalette {
    static let free = Color.green.opacity(0.78)
    static let mixed = Color.orange.opacity(0.85)
    static let full = AppTheme.gpu.opacity(0.85)
    static let down = Color.red.opacity(0.65)

    static let freeName = "green"
    static let mixedName = "orange"
    static let fullName = "cyan"
    static let downName = "red with a slash"
}

struct GPUFleetPanel: View {
    let stats: GPUFleetStats
    let nodes: [NodeSummary]

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            RingMeter(
                value: Double(stats.utilizationPercent) / 100,
                color: stats.utilizationColor,
                label: stats.modelName.map { "\($0) in use" } ?? "GPU use"
            )
            .frame(width: 118, height: 118)

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "GPU fleet", subtitle: "\(stats.allocated)/\(stats.total) \(stats.unit) allocated")
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
        .dashboardCard(accent: AppTheme.gpu)
        .animation(AppTheme.smoothEase, value: stats.utilizationPercent)
    }

    @ViewBuilder
    private var fleetChips: some View {
        InfoChip(label: "Free", value: "\(stats.free)", systemImage: "checkmark.circle.fill", color: .green)
            .help("Idle \(stats.unit) on nodes that accept work")
        InfoChip(label: "Mixed", value: "\(stats.mixedNodes)", systemImage: "circle.lefthalf.filled", color: .orange)
            .help("Nodes with some GPUs allocated")
        InfoChip(label: "Unavailable", value: "\(stats.unavailableNodes)", systemImage: "exclamationmark.triangle.fill", color: .red)
            .help("Drained, down or failing GPU nodes")
    }
}

struct GPUNodeHeatmap: View {
    let nodes: [NodeSummary]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 20, maximum: 24), spacing: 5)], spacing: 5) {
            ForEach(nodes) { node in
                let available = isAvailable(node)
                let model = slurmGPUModelDisplayName(from: node.gres) ?? "GPU"
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
                    .help("\(node.node): \(gpuAllocated(node))/\(gpuTotal(node)) \(model), \(node.state)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(node.node)
                    .accessibilityValue(
                        available
                            ? "\(gpuAllocated(node)) of \(gpuTotal(node)) \(model) allocated"
                            : "unavailable, \(node.state)"
                    )
                    .animation(AppTheme.smoothEase, value: node.state)
            }
        }
    }

    private func color(for node: NodeSummary, available: Bool) -> Color {
        if !available {
            return GPUSlotPalette.down
        }
        let total = max(gpuTotal(node), 1)
        let ratio = Double(gpuAllocated(node)) / Double(total)
        if ratio >= 1 {
            return GPUSlotPalette.full
        }
        if ratio > 0 {
            return GPUSlotPalette.mixed
        }
        return GPUSlotPalette.free
    }
}

/// Compact labeled legend so the heatmap encoding is discoverable.
struct HeatmapLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            legendDot(color: GPUSlotPalette.free, label: "Free")
            legendDot(color: GPUSlotPalette.mixed, label: "Mixed")
            legendDot(color: GPUSlotPalette.full, label: "Full")
            legendDot(color: GPUSlotPalette.down, label: "Down", slashed: true)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heatmap legend")
        .accessibilityValue(
            "\(GPUSlotPalette.freeName) free, \(GPUSlotPalette.mixedName) mixed, "
                + "\(GPUSlotPalette.fullName) full, \(GPUSlotPalette.downName) down or drained"
        )
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

/// Allocated | offline | free. Offline GPUs (idle on a drained node) get
/// their own segment so they are neither counted as free nor hidden.
struct GPUFleetBar: View {
    let stats: GPUFleetStats

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let scale = stats.total == 0 ? 0 : width / CGFloat(stats.total)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.green.opacity(0.22))
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(stats.utilizationColor.opacity(0.82))
                            .frame(width: CGFloat(stats.allocated) * scale)
                        Rectangle()
                            .fill(GPUSlotPalette.down.opacity(0.7))
                            .frame(width: CGFloat(stats.offline) * scale)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .frame(height: 10)
            .animation(AppTheme.softSpring, value: stats.allocated)
            .animation(AppTheme.softSpring, value: stats.offline)

            HStack {
                Label("\(stats.allocated) allocated", systemImage: "circle.fill")
                    .foregroundStyle(stats.utilizationColor)
                if stats.offline > 0 {
                    Spacer()
                    Label("\(stats.offline) offline", systemImage: "circle.fill")
                        .foregroundStyle(.red)
                }
                Spacer()
                Label("\(stats.free) free", systemImage: "circle.fill")
                    .foregroundStyle(.green)
            }
            .font(.caption.monospacedDigit())
        }
        .animation(AppTheme.smoothEase, value: stats.free)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stats.modelName ?? "GPU") allocation")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        var parts = ["\(stats.allocated) allocated", "\(stats.free) free"]
        if stats.offline > 0 {
            parts.append("\(stats.offline) on unavailable nodes")
        }
        return parts.joined(separator: ", ") + " of \(stats.total)"
    }
}

// MARK: - Sections and cards

struct NodeSection: View {
    let title: String
    let subtitle: String
    let nodes: [NodeSummary]
    let busyNodes: Set<String>
    let style: PartitionRole
    /// Names the login node in the context menu, so it is clear which
    /// cluster the shell will open on.
    let clusterName: String
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue("\(nodes.count) nodes, \(subtitle)")
            .accessibilityAddTraits(.isHeader)

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
                                    Label("Open shell on \(clusterName) login node", systemImage: "terminal")
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
    /// "H200", "L40S"; plain "GPU" when the gres names no model.
    private var model: String { slurmGPUModelDisplayName(from: node.gres) ?? "GPU" }
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
                        .lineLimit(1)
                }
                Spacer()
                StatePill(state: node.state)
            }

            HStack(spacing: total > 6 ? 4 : 6) {
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(model) slots")
            .accessibilityValue("\(allocated) of \(total) allocated")

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(model)
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
                    .tint(cpuRatio > 0.85 ? .orange : AppTheme.cpu)
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
        .animation(AppTheme.smoothEase, value: allocated)
        .animation(AppTheme.smoothEase, value: node.state)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model) node \(node.node)")
    }

    private var cardTint: Color {
        if !isAvailable(node) {
            return Color.gray.opacity(0.12)
        }
        if gpuIdle(node) > 0 {
            return AppTheme.panelBackground
        }
        return AppTheme.gpu.opacity(0.08)
    }

    /// Slot colors mirror the fleet heatmap legend (GPUSlotPalette).
    private func gpuSlotColor(index: Int) -> Color {
        if !isAvailable(node) {
            return .gray.opacity(0.35)
        }
        if index < allocated {
            return GPUSlotPalette.full
        }
        return GPUSlotPalette.free.opacity(0.95)
    }
}

struct GeneralNodeCard: View {
    let node: NodeSummary
    let style: PartitionRole
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
        .animation(AppTheme.smoothEase, value: cpuRatio)
        .animation(AppTheme.smoothEase, value: node.state)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(NodeGrouping.shortNoun(for: style)) node \(node.node)")
    }

    /// Same role colours as the Partitions tab.
    private var accentColor: Color {
        partitionRoleAccent(style)
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
                    .stroke(highlighted ? Color.purple.opacity(0.55) : AppTheme.border, lineWidth: highlighted ? 1.5 : 1)
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
