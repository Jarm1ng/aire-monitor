import HPCCore
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
/// different pools, so nothing here may ever mix two clusters' data. GPU
/// figures come from HPCCore's `GPUFleet`, the one definition of idle,
/// stranded, unavailable and unknown GPUs shared by every surface.
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
        let coverage = NodeMetricCoverage(nodes: nodes)

        VStack(alignment: .leading, spacing: 14) {
            PageHeader(
                title: "\(profile.displayName) nodes",
                subtitle: headerSubtitle(grouping),
                systemImage: "server.rack",
                accent: AppTheme.gpu
            ) {
                DetailsToggleButton(showDetails: $showDetails)
            }

            // One group needs no filter: "All" and it would be the same view.
            // The filter sits on its own row rather than in the header: AIRE
            // has five groups, and a fixed-size segmented control in the
            // header squeezed the title to nothing at narrow widths.
            if grouping.availableFilters.count > 2 {
                NodeFilterBar(filters: grouping.availableFilters, selection: $filter)
            }

            if nodes.isEmpty {
                EmptyVisual(
                    title: "No node data yet",
                    subtitle: "\(profile.displayName) node health and GPU occupancy appear after the next successful refresh.",
                    systemImage: "server.rack"
                )
            } else {
                nodeContent(grouping: grouping, filter: activeFilter, coverage: coverage)
            }

            if showDetails {
                SectionHeader(title: "Node details", subtitle: pluralized(visibleNodes.count, "row"))
                NodesTable(nodes: visibleNodes, coverage: coverage)
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
    private func nodeContent(grouping: NodeGrouping, filter: NodeFilter, coverage: NodeMetricCoverage) -> some View {
        let gpuNodes = grouping.nodes(in: .gpu)
        // Per-model GPU pools of this cluster (same rule as the session's
        // cached fleet, the sidebar and the menu bar).
        let fleet = GPUFleet(nodes: nodes)
        // Exact hostnames the user's jobs occupy on THIS cluster, computed
        // once per render from expanded Slurm node lists (never substrings).
        let busyNodes = busyNodeSet(for: jobs)

        if !gpuNodes.isEmpty && filter.includes(.gpu) {
            GPUFleetPanel(fleet: fleet, nodes: gpuNodes)
        }

        VStack(alignment: .leading, spacing: 18) {
            ForEach(grouping.roles, id: \.self) { role in
                if filter.includes(role) {
                    NodeSection(
                        title: NodeGrouping.sectionTitle(for: role),
                        subtitle: sectionSubtitle(for: role, grouping: grouping, fleet: fleet),
                        nodes: grouping.nodes(in: role),
                        busyNodes: busyNodes,
                        style: role,
                        coverage: coverage,
                        clusterName: profile.displayName,
                        onOpenShell: onOpenShell
                    )
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// "114 nodes · 8 GPU · 106 CPU · 13 unavailable", or the cluster
    /// tagline before the first snapshot arrives.
    private func headerSubtitle(_ grouping: NodeGrouping) -> String {
        guard !nodes.isEmpty else {
            return profile.tagline
        }
        let counts = grouping.roles.map { "\(grouping.nodes(in: $0).count) \(NodeGrouping.shortNoun(for: $0))" }
        var parts = [pluralized(nodes.count, "node")] + counts
        let unavailable = nodes.filter { !$0.stateInfo.isAvailable }.count
        if unavailable > 0 {
            parts.append("\(unavailable) unavailable")
        }
        return parts.joined(separator: " · ")
    }

    /// Where the group's nodes live and what each one offers, e.g.
    /// "calder-gpu-hopper, aire-gpu-lovelace · 8 × H200, 3 × L40 per node ·
    /// 17 idle H200 · 0 idle L40" or "calder-cpu-turin · 128 cores, 754 GiB
    /// per node · 1,689 of 12,288 cores allocated · +1,600 on unavailable
    /// nodes".
    private func sectionSubtitle(for role: PartitionRole, grouping: NodeGrouping, fleet: GPUFleet) -> String {
        let members = grouping.nodes(in: role)
        let partitions = grouping.partitionNames(in: role)
        var parts = [partitions.isEmpty ? "no partition" : partitions.joined(separator: ", ")]
        if role == .gpu {
            if let shape = gpuShapeText(members) {
                parts.append(shape)
            }
            parts.append(contentsOf: fleet.pools.map { pool in
                pool.idleIsUnknown ? "? idle \(pool.label)" : gpuUnitText(pool.idle, model: pool.model, adjective: "idle")
            })
        } else {
            if let shape = cpuShapeText(members) {
                parts.append(shape)
            }
            parts.append(contentsOf: coreUsageText(members))
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

/// The node-group filter: a segmented control when it fits, a pop-up menu
/// in narrow windows. The frame hands the picker the full row width, so the
/// segmented form is chosen whenever it can be shown.
private struct NodeFilterBar: View {
    let filters: [NodeFilter]
    @Binding var selection: NodeFilter

    var body: some View {
        ViewThatFits(in: .horizontal) {
            picker
                .pickerStyle(.segmented)
                .fixedSize()
            picker
                .pickerStyle(.menu)
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var picker: some View {
        Picker("Node group", selection: $selection) {
            ForEach(filters) { option in
                Text(option.title).tag(option)
            }
        }
        .labelsHidden()
        .accessibilityLabel("Node group filter")
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
        if node.gpuCount > 0 || hinted.contains(.gpu) {
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

/// "8 × H200 per node"; "4–8 × L40S per node" for uneven nodes of one model;
/// "8 × H200, 3 × L40 per node" when a group mixes models — each model with
/// its own shape, never one range spanning both. Nil without GPUs.
func gpuShapeText(_ nodes: [NodeSummary]) -> String? {
    var countsByModel: [String: [Int]] = [:]
    var order: [String] = []
    for node in nodes {
        let count = node.gpuCount
        guard count > 0 else {
            continue
        }
        let model = slurmGPUModelDisplayName(from: node.gres) ?? ""
        if countsByModel[model] == nil {
            order.append(model)
        }
        countsByModel[model, default: []].append(count)
    }
    let parts = order.compactMap { model -> String? in
        guard let range = rangeText(countsByModel[model] ?? [], format: { "\($0)" }) else {
            return nil
        }
        return model.isEmpty ? "\(range) GPUs" : "\(range) × \(model)"
    }
    return parts.isEmpty ? nil : parts.joined(separator: ", ") + " per node"
}

/// "5 idle L40S", "1 idle GPU": a count with its model named, never a bare
/// number that could be read as another model's.
func gpuUnitText(_ count: Int, model: String?, adjective: String) -> String {
    guard let model else {
        return "\(count) \(adjective) \(count == 1 ? "GPU" : "GPUs")"
    }
    return "\(count) \(adjective) \(model)"
}

/// "128 cores, 754 GiB per node", "128–192 cores, …" for a spread. Memory
/// is Slurm's MiB through the app's 1024-based `formatMemoryGB`, so Calder
/// GPU nodes read "1.5 TiB".
private func cpuShapeText(_ nodes: [NodeSummary]) -> String? {
    let cores = rangeText(nodes.compactMap(\.cpuTotal).filter { $0 > 0 }, format: { "\($0)" })
        .map { "\($0) cores" }
    let memory = rangeText(nodes.compactMap(\.memoryMB).filter { $0 > 0 }, format: { formatMemoryGB(Double($0) / 1024) })
    let pieces = [cores, memory].compactMap { $0 }
    return pieces.isEmpty ? nil : pieces.joined(separator: ", ") + " per node"
}

/// "1,689 of 12,288 cores allocated" over the nodes that accept work (the
/// same denominator as the overview), plus "+1,600 on unavailable nodes"
/// when drained or down nodes hold cores that cannot be used.
func coreUsageText(_ nodes: [NodeSummary]) -> [String] {
    let available = nodes.filter { $0.stateInfo.isAvailable }
    let total = available.reduce(0) { $0 + ($1.cpuTotal ?? 0) }
    let offline = nodes.filter { !$0.stateInfo.isAvailable }.reduce(0) { $0 + ($1.cpuTotal ?? 0) }
    var parts: [String] = []
    if total > 0 {
        let allocated = available.reduce(0) { $0 + ($1.cpuAllocated ?? 0) }
        parts.append("\(groupedNumber(allocated)) of \(groupedNumber(total)) cores allocated")
    }
    if offline > 0 {
        parts.append("+\(groupedNumber(offline)) on unavailable nodes")
    }
    return parts
}

/// "128" for uniform values, "64–168" for a spread. Compared after
/// formatting so near-identical memory sizes do not print "754 GiB–754 GiB".
private func rangeText(_ values: [Int], format: (Int) -> String) -> String? {
    guard let low = values.min(), let high = values.max() else {
        return nil
    }
    let lowText = format(low)
    let highText = format(high)
    return lowText == highText ? lowText : "\(lowText)–\(highText)"
}

// MARK: - Untracked metrics

/// Which per-node metrics this cluster actually tracks, decided per
/// snapshot so every card agrees. Calder reports AllocMem=0 and
/// CurrentWatts=0 on every node (memory is not a consumable resource there
/// and there is no energy accounting); showing those zeros as "0W" and an
/// empty memory bar on busy nodes would read as "no memory in use".
struct NodeMetricCoverage: Equatable {
    /// Slurm allocates memory here: some node reports allocated memory.
    let memoryTracked: Bool
    /// Some node reports a power draw.
    let powerTracked: Bool

    init(nodes: [NodeSummary]) {
        memoryTracked = nodes.contains { ($0.memoryAllocatedMB ?? 0) > 0 }
        powerTracked = nodes.contains { ($0.currentWatts ?? 0) > 0 || ($0.averageWatts ?? 0) > 0 }
    }

    /// Watts worth showing for a node: nil when power is not tracked, or the
    /// node draws nothing measurable (AIRE's down nodes report 0).
    func watts(for node: NodeSummary) -> Int? {
        guard powerTracked, let watts = node.currentWatts, watts > 0 else {
            return nil
        }
        return watts
    }

    /// Memory Slurm can still allocate, in MiB; nil when untracked.
    func unallocatedMemoryMB(for node: NodeSummary) -> Int? {
        guard memoryTracked, let total = node.memoryMB, let allocated = node.memoryAllocatedMB else {
            return nil
        }
        return max(total - allocated, 0)
    }
}

/// "245 G", from Slurm's MiB.
private func gibText(_ mib: Int) -> String {
    "\(groupedNumber(mib / 1024))G"
}

// MARK: - Table

struct NodesTable: View {
    let nodes: [NodeSummary]
    var coverage: NodeMetricCoverage? = nil

    var body: some View {
        let coverage = coverage ?? NodeMetricCoverage(nodes: nodes)
        // The raw Slurm codes stay here (tooltips explain them); cards and
        // legends use plain words.
        Table(nodes) {
            TableColumn("Node", value: \.node)
            TableColumn("Partitions") { item in
                Text(item.partitions.joined(separator: ", "))
            }
            TableColumn("State") { item in
                Text(item.state)
                    .help(item.stateInfo.helpText)
            }
            TableColumn("CPU") { item in
                Text(cpuText(item))
            }
            TableColumn("GPU") { item in
                Text(gpuText(item))
                    .help(item.knownGPUAllocated == nil && item.gpuCount > 0 ? "GPU allocation unknown: no node details in this snapshot" : "")
            }
            Group {
                TableColumn("Memory MB") { (item: NodeSummary) in
                    Text(number(item.memoryMB))
                }
                TableColumn("Allocated MB") { (item: NodeSummary) in
                    Text(coverage.memoryTracked ? number(item.memoryAllocatedMB) : missingValuePlaceholder)
                        .help(coverage.memoryTracked ? "" : "This cluster does not track allocated memory")
                }
                TableColumn("OS free MB") { (item: NodeSummary) in
                    Text(number(item.memoryFreeMB))
                        .help("Free memory as the operating system reports it (scontrol FreeMem)")
                }
            }
            TableColumn("Watts") { item in
                Text(coverage.powerTracked ? number(item.currentWatts) : missingValuePlaceholder)
                    .help(coverage.powerTracked ? "" : "This cluster does not report power draw")
            }
            TableColumn("GRES", value: \.gres)
            TableColumn("Reason", value: \.reason)
        }
    }
}

// MARK: - GPU fleet

/// The colours of the GPU heatmap, the fleet bar, its legend and the slots
/// on GPU node cards, defined once so they never drift apart. Allocated is
/// the GPU identity colour at every utilisation (pressure shows on the ring
/// only), and unavailable is grey with a slash or stripes — never the red
/// of an alert, and never the colour of allocated GPUs. `colorName`s feed
/// accessibility labels and must describe the colours above them.
enum GPUSlotPalette {
    static let idle = Color.green.opacity(0.78)
    static let partlyUsed = AppTheme.gpu.opacity(0.42)
    static let allocated = AppTheme.gpu.opacity(0.85)
    static let stranded = Color.gray.opacity(0.55)
    static let unavailable = Color.gray.opacity(0.32)
    static let unknown = Color.primary.opacity(0.06)

    static let idleName = "green"
    static let partlyUsedName = "light cyan"
    static let allocatedName = "cyan"
    static let strandedName = "grey"
    static let unavailableName = "grey with a slash"
    static let unknownName = "outlined"
}

/// What a GPU node offers a new job, for heatmap cells and the legend.
/// Decided by startability, the same rule as `GPUFleet`: a node whose CPUs
/// are all taken is "full" even with a GPU idle, because nothing can start
/// there.
enum GPUNodeCategory: CaseIterable {
    case allIdle
    case partlyUsed
    case full
    case unavailable
    case unknown

    init(node: NodeSummary) {
        guard node.stateInfo.isAvailable else {
            self = .unavailable
            return
        }
        let total = node.gpuCount
        guard total > 0, let allocated = node.knownGPUAllocated else {
            self = .unknown
            return
        }
        if allocated >= total || node.cpusFull {
            self = .full
        } else if allocated > 0 {
            self = .partlyUsed
        } else {
            self = .allIdle
        }
    }

    var title: String {
        switch self {
        case .allIdle: return "All idle"
        case .partlyUsed: return "Partly used"
        case .full: return "Full"
        case .unavailable: return "Unavailable"
        case .unknown: return "Unknown"
        }
    }

    var help: String {
        switch self {
        case .allIdle: return "Every GPU idle and the node accepts work"
        case .partlyUsed: return "Some GPUs allocated, some still free to start a job"
        case .full: return "No GPU can start a job: all allocated, or the node's CPUs are all taken"
        case .unavailable: return "Drained, down, reserved or not responding"
        case .unknown: return "No GPU allocation in this snapshot (node details missing)"
        }
    }

    var color: Color {
        switch self {
        case .allIdle: return GPUSlotPalette.idle
        case .partlyUsed: return GPUSlotPalette.partlyUsed
        case .full: return GPUSlotPalette.allocated
        case .unavailable: return GPUSlotPalette.unavailable
        case .unknown: return GPUSlotPalette.unknown
        }
    }

    var colorName: String {
        switch self {
        case .allIdle: return GPUSlotPalette.idleName
        case .partlyUsed: return GPUSlotPalette.partlyUsedName
        case .full: return GPUSlotPalette.allocatedName
        case .unavailable: return GPUSlotPalette.unavailableName
        case .unknown: return GPUSlotPalette.unknownName
        }
    }
}

/// One GPU slot on a node card.
enum GPUSlotKind: Equatable {
    case allocated
    case idle
    /// Idle, but the node's CPUs are all taken.
    case stranded
    /// Idle on a node that accepts no work.
    case unavailable
    /// Allocation not reported.
    case unknown

    /// Slots of a node in display order: allocated first, then what the
    /// rest are — matching how `GPUFleet` counts the node.
    static func slots(for node: NodeSummary) -> [GPUSlotKind] {
        let total = node.gpuCount
        guard total > 0 else {
            return []
        }
        let available = node.stateInfo.isAvailable
        guard let allocatedCount = node.knownGPUAllocated else {
            return Array(repeating: available ? .unknown : .unavailable, count: total)
        }
        let allocated = min(allocatedCount, total)
        let rest: GPUSlotKind = !available ? .unavailable : (node.cpusFull ? .stranded : .idle)
        return Array(repeating: .allocated, count: allocated) + Array(repeating: rest, count: total - allocated)
    }

    var color: Color {
        switch self {
        case .allocated: return GPUSlotPalette.allocated
        case .idle: return GPUSlotPalette.idle.opacity(0.95)
        case .stranded: return GPUSlotPalette.stranded
        case .unavailable: return GPUSlotPalette.unavailable
        case .unknown: return GPUSlotPalette.unknown
        }
    }
}

/// Per-model GPU pools of one cluster, with the node heatmap.
struct GPUFleetPanel: View {
    let fleet: GPUFleet
    /// The GPU group's nodes, for the heatmap.
    let nodes: [NodeSummary]

    var body: some View {
        let categories = nodes.map(GPUNodeCategory.init(node:))
        HStack(alignment: .center, spacing: 18) {
            if let primary = fleet.primary {
                RingMeter(
                    value: Self.utilization(primary),
                    color: ringColor(primary),
                    label: "\(primary.label) in use"
                )
                .frame(width: 118, height: 118)
                .help(ringHelp(primary))
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "GPU fleet", subtitle: summaryText)
                ForEach(fleet.pools) { pool in
                    GPUPoolRow(pool: pool, showsHeader: fleet.pools.count > 1)
                }
                if fleet.hasUnknownAllocation {
                    Label(
                        "Allocation unknown for \(pluralized(fleet.unknown, "GPU")) — node details are missing from this snapshot, so they are not counted as idle.",
                        systemImage: "questionmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Node heatmap", subtitle: pluralized(nodes.count, "GPU node"))
                GPUNodeHeatmap(nodes: nodes)
                HeatmapLegend(categories: categories)
            }
            .frame(minWidth: 200, idealWidth: 310, maxWidth: 310)
        }
        .dashboardCard(accent: AppTheme.gpu)
        .animation(AppTheme.smoothEase, value: fleet)
    }

    /// "73 of 84 L40S allocated"; for several models "31 of 59 GPUs
    /// allocated · H200 31 of 56 · L40 0 of 3", so the total never stands
    /// without its parts.
    private var summaryText: String {
        Self.summaryText(fleet)
    }

    /// GPUs of unknown allocation are named beside the pool they belong to
    /// ("H200 0 of 56 (40 unknown) · L40 0 of 3"), so "0 of 84 allocated"
    /// never stands alone when node details are missing, and a fleet-wide
    /// "· 40 unknown" after the last model never reads as that model's.
    nonisolated static func summaryText(_ fleet: GPUFleet) -> String {
        if fleet.pools.count == 1, let pool = fleet.primary {
            let unknown = pool.unknown > 0 ? " · \(pool.unknown) unknown" : ""
            return "\(pool.allocated) of \(pool.total) \(pool.model ?? "GPUs") allocated" + unknown
        }
        let parts = fleet.pools.map { pool in
            "\(pool.label) \(pool.allocated) of \(pool.total)" + (pool.unknown > 0 ? " (\(pool.unknown) unknown)" : "")
        }
        return (["\(fleet.allocated) of \(fleet.total) GPUs allocated"] + parts).joined(separator: " · ")
    }

    /// The ring's share of the pool in use, or nil while any GPU's
    /// allocation is unknown: those GPUs are neither allocated nor idle, so
    /// allocated ÷ total would understate the load — all the way to "0% in
    /// use" when node details failed outright. The bar beside the ring
    /// still shows the known part.
    nonisolated static func utilization(_ pool: GPUPool) -> Double? {
        guard pool.total > 0, pool.unknown == 0 else {
            return nil
        }
        return Double(pool.allocated) / Double(pool.total)
    }

    /// Allocation pressure, on the shared 75/90 thresholds; the GPU
    /// identity colour while there is headroom (or nothing is drawn).
    private func ringColor(_ pool: GPUPool) -> Color {
        let tone = Self.ringTone(pool)
        return tone == .normal ? AppTheme.gpu : tone.color
    }

    /// A busy pool is a warning at most, never red: red is kept for faults
    /// and critical storage, and a full GPU pool is the shared orange
    /// "full" (the capacity signal, the header chip) everywhere.
    nonisolated static func ringTone(_ pool: GPUPool) -> StatusTone {
        guard let utilization = utilization(pool) else {
            return .normal
        }
        return min(StatusTone(usedPercent: utilization * 100), .warning)
    }

    private func ringHelp(_ pool: GPUPool) -> String {
        var text = "\(pool.allocated) of \(pool.total) \(pool.label) allocated"
        if pool.unknown > 0 {
            text = "Allocation unknown for \(pool.unknown) of \(pool.total) \(pool.label): node details are missing from this snapshot, so no share in use is shown (\(pool.allocated) known to be allocated)"
        }
        if fleet.pools.count > 1 {
            text += " (largest pool; the other models are listed beside it)"
        }
        return text
    }
}

/// One GPU model's bar and legend: allocated | stranded | unavailable |
/// unknown | idle, each in GPUs.
struct GPUPoolRow: View {
    let pool: GPUPool
    var showsHeader = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsHeader {
                HStack(alignment: .firstTextBaseline) {
                    Text(pool.label)
                        .font(.callout.weight(.semibold))
                    Text(pool.partitions.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    // The partition names give way first.
                    Text(Self.allocationText(pool))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            GPUFleetBar(pool: pool)
        }
    }

    /// "31 of 56 allocated", naming GPUs of unknown allocation ("0 of 56
    /// allocated · 40 unknown") so the row never claims an empty pool the
    /// ring beside it deliberately leaves blank.
    nonisolated static func allocationText(_ pool: GPUPool) -> String {
        let base = "\(pool.allocated) of \(pool.total) allocated"
        return pool.unknown > 0 ? "\(base) · \(pool.unknown) unknown" : base
    }
}

/// Allocated | stranded | unavailable | unknown | idle for one GPU pool.
/// Only idle GPUs can start a job: stranded ones sit on nodes whose CPUs
/// are full, unavailable ones on nodes that accept no work, so neither is
/// ever counted as free.
struct GPUFleetBar: View {
    let pool: GPUPool

    private struct Segment: Identifiable {
        let id: String
        let count: Int
        let fill: AnyShapeStyle
        let striped: Bool
    }

    private var segments: [Segment] {
        [
            Segment(id: "allocated", count: pool.allocated, fill: AnyShapeStyle(GPUSlotPalette.allocated), striped: false),
            Segment(id: "stranded", count: pool.stranded, fill: AnyShapeStyle(GPUSlotPalette.stranded), striped: false),
            Segment(id: "unavailable", count: pool.unavailable, fill: AnyShapeStyle(GPUSlotPalette.unavailable), striped: true),
            Segment(id: "unknown", count: pool.unknown, fill: AnyShapeStyle(GPUSlotPalette.unknown), striped: false),
            Segment(id: "idle", count: pool.idle, fill: AnyShapeStyle(GPUSlotPalette.idle), striped: false)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let scale = pool.total == 0 ? 0 : width / CGFloat(pool.total)
                HStack(spacing: 0) {
                    ForEach(segments.filter { $0.count > 0 }) { segment in
                        Rectangle()
                            .fill(segment.fill)
                            .overlay {
                                if segment.striped {
                                    DiagonalStripes()
                                        .stroke(Color.primary.opacity(0.28), lineWidth: 1)
                                }
                            }
                            .frame(width: CGFloat(segment.count) * scale)
                    }
                }
                .frame(width: width, alignment: .leading)
                .background(AppTheme.mutedFill)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .frame(height: 10)
            .animation(AppTheme.softSpring, value: pool)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    legendItems
                }
                VStack(alignment: .leading, spacing: 4) {
                    legendItems
                }
            }
            .font(.caption.monospacedDigit())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(pool.label) allocation")
        .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder
    private var legendItems: some View {
        legendItem("\(pool.allocated) allocated", swatch: GPUSlotPalette.allocated, help: "Allocated to running jobs")
        if pool.stranded > 0 {
            legendItem("\(pool.stranded) stranded", swatch: GPUSlotPalette.stranded, help: "Idle, but the node's CPUs are all allocated, so no job can start on these GPUs")
        }
        if pool.unavailable > 0 {
            legendItem("\(pool.unavailable) unavailable", swatch: GPUSlotPalette.unavailable, striped: true, help: "Idle on nodes that accept no work (drained, down, reserved or not responding)")
        }
        if pool.unknown > 0 {
            legendItem("\(pool.unknown) unknown", swatch: GPUSlotPalette.unknown, help: "Allocation not reported for these GPUs this refresh")
        }
        // "? idle" while the allocation is unknown: a bare bold "0 idle"
        // would claim a full pool (the header chip already says "?").
        legendItem(
            "\(pool.idleFigure) idle",
            swatch: GPUSlotPalette.idle,
            help: pool.idleIsUnknown
                ? "Not known: allocation was not reported for these nodes, so no GPU is counted as idle"
                : "Idle on nodes that can start a job now"
        )
        .fontWeight(.semibold)
    }

    private func legendItem(_ text: String, swatch: Color, striped: Bool = false, help: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(swatch)
                .overlay {
                    if striped {
                        DiagonalStripes()
                            .stroke(Color.primary.opacity(0.35), lineWidth: 0.8)
                            .clipShape(RoundedRectangle(cornerRadius: 2.5))
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 2.5).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                .frame(width: 9, height: 9)
            Text(text)
                .fixedSize()
        }
        .foregroundStyle(.secondary)
        .help(help)
    }

    private var accessibilityValue: String {
        Self.accessibilityValue(pool)
    }

    nonisolated static func accessibilityValue(_ pool: GPUPool) -> String {
        var parts = ["\(pool.allocated) allocated", pool.idleIsUnknown ? "idle GPUs unknown" : "\(pool.idle) idle and startable"]
        if pool.stranded > 0 {
            parts.append("\(pool.stranded) stranded on nodes with no free CPU")
        }
        if pool.unavailable > 0 {
            parts.append("\(pool.unavailable) on unavailable nodes")
        }
        if pool.unknown > 0 {
            parts.append("\(pool.unknown) with unknown allocation")
        }
        return parts.joined(separator: ", ") + " of \(pool.total)"
    }
}

/// Diagonal hatching for "unavailable" GPUs: a cue that does not depend on
/// telling two greys apart.
struct DiagonalStripes: Shape {
    var spacing: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}

struct GPUNodeHeatmap: View {
    let nodes: [NodeSummary]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 20, maximum: 24), spacing: 5)], spacing: 5) {
            ForEach(nodes) { node in
                let category = GPUNodeCategory(node: node)
                RoundedRectangle(cornerRadius: 4)
                    .fill(category.color)
                    .frame(height: 18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(
                                Color.primary.opacity(category == .unknown ? 0.35 : 0.08),
                                style: StrokeStyle(lineWidth: 1, dash: category == .unknown ? [2, 2] : [])
                            )
                    )
                    .overlay {
                        // Non-colour cue so unavailable nodes stay distinguishable.
                        if category == .unavailable {
                            Image(systemName: "line.diagonal")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color.primary.opacity(0.55))
                        }
                    }
                    .help(cellHelp(node, category: category))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(node.node)
                    .accessibilityValue(cellHelp(node, category: category))
                    .animation(AppTheme.smoothEase, value: node.state)
            }
        }
    }

    private func cellHelp(_ node: NodeSummary, category: GPUNodeCategory) -> String {
        let model = slurmGPUModelDisplayName(from: node.gres) ?? "GPU"
        let allocation = node.knownGPUAllocated.map { "\(min($0, node.gpuCount)) of \(node.gpuCount) \(model) allocated" }
            ?? "\(node.gpuCount) \(model), allocation unknown"
        var parts = ["\(node.node): \(allocation)", category.title.lowercased()]
        let stranded = GPUSlotKind.slots(for: node).filter { $0 == .stranded }.count
        if stranded > 0 {
            parts.append("\(stranded) idle GPU\(stranded == 1 ? "" : "s") stranded — CPUs full")
        }
        parts.append(node.stateInfo.helpText)
        return parts.joined(separator: " · ")
    }
}

/// Labelled legend with node counts, so the heatmap encoding is
/// discoverable and the counts name their unit (nodes).
struct HeatmapLegend: View {
    let categories: [GPUNodeCategory]

    var body: some View {
        let counts = Dictionary(grouping: categories, by: { $0 }).mapValues(\.count)
        // Always explain the main four; "Unknown" only when it occurs.
        let shown = GPUNodeCategory.allCases.filter { $0 != .unknown || (counts[$0] ?? 0) > 0 }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                legendDots(shown, counts: counts)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 4) {
                legendDots(shown, counts: counts)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heatmap legend, in nodes")
        .accessibilityValue(
            shown.map { "\($0.colorName) \($0.title.lowercased()) \(counts[$0] ?? 0)" }.joined(separator: ", ")
        )
    }

    @ViewBuilder
    private func legendDots(_ shown: [GPUNodeCategory], counts: [GPUNodeCategory: Int]) -> some View {
        ForEach(shown, id: \.self) { category in
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(category.color)
                    .frame(width: 9, height: 9)
                    .overlay {
                        if category == .unavailable {
                            Image(systemName: "line.diagonal")
                                .font(.system(size: 6, weight: .bold))
                                .foregroundStyle(Color.primary.opacity(0.6))
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 2.5)
                            .stroke(Color.primary.opacity(category == .unknown ? 0.4 : 0.12), lineWidth: 0.5)
                    )
                Text("\(category.title) \(counts[category] ?? 0)")
                    .fixedSize()
            }
            .help("\(category.help) — \(pluralized(counts[category] ?? 0, "node"))")
        }
    }
}

// MARK: - Sections and cards

struct NodeSection: View {
    let title: String
    let subtitle: String
    let nodes: [NodeSummary]
    let busyNodes: Set<String>
    let style: PartitionRole
    let coverage: NodeMetricCoverage
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
            .accessibilityValue("\(pluralized(nodes.count, "node")), \(subtitle)")
            .accessibilityAddTraits(.isHeader)

            if nodes.isEmpty {
                EmptyVisual(title: "No nodes in this group", subtitle: "Nothing to show for the current filter.", systemImage: "tray")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cardWidth, maximum: 280), spacing: 10, alignment: .top)], spacing: 10) {
                    ForEach(nodes) { node in
                        Group {
                            if style == .gpu {
                                GPUNodeCard(node: node, hasUserJob: busyNodes.contains(node.node), coverage: coverage)
                            } else {
                                GeneralNodeCard(node: node, style: style, hasUserJob: busyNodes.contains(node.node), coverage: coverage)
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

/// Tooltip for a node's state pill: the plain meaning and flags, plus a
/// reminder that MIX/ALLOC describe the node's CPUs (GPU use is the slots).
private func nodeStateHelp(_ node: NodeSummary, gpuNode: Bool) -> String {
    let base = node.stateInfo.helpText
    return gpuNode ? "\(base). The node state describes its CPUs; the slots show its GPUs." : base
}

struct GPUNodeCard: View {
    let node: NodeSummary
    let hasUserJob: Bool
    var coverage = NodeMetricCoverage(nodes: [])

    private var total: Int { node.gpuCount }
    /// "H200", "L40S"; plain "GPU" when the gres names no model.
    private var model: String { slurmGPUModelDisplayName(from: node.gres) ?? "GPU" }
    private var cpuRatio: Double {
        guard let allocated = node.cpuAllocated, let total = node.cpuTotal, total > 0 else {
            return 0
        }
        return min(Double(allocated) / Double(total), 1)
    }

    var body: some View {
        let slots = GPUSlotKind.slots(for: node)
        let stranded = slots.filter { $0 == .stranded }.count
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
                    .help(nodeStateHelp(node, gpuNode: true))
            }

            HStack(spacing: total > 6 ? 4 : 6) {
                ForEach(Array((slots.isEmpty ? [GPUSlotKind.unknown] : slots).enumerated()), id: \.offset) { _, slot in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(slot.color)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(
                                    Color.primary.opacity(slot == .unknown ? 0.35 : 0.08),
                                    style: StrokeStyle(lineWidth: 1, dash: slot == .unknown ? [3, 2] : [])
                                )
                        )
                        .overlay {
                            if slot == .unavailable {
                                Image(systemName: "line.diagonal")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Color.primary.opacity(0.45))
                            }
                        }
                        .frame(height: 28)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(model) slots")
            .accessibilityValue(allocationText)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(model)
                    Spacer()
                    Text(allocationText)
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
                    .tint(AppTheme.cpu)
                    .accessibilityLabel("CPU usage")
                    .accessibilityValue("\(Int((cpuRatio * 100).rounded())) percent")

                memoryRow
                    .font(.caption)
            }

            HStack(spacing: 8) {
                if let watts = coverage.watts(for: node) {
                    Label("\(watts)W", systemImage: "bolt.fill")
                }
                if hasUserJob {
                    Label("your job", systemImage: "person.crop.circle")
                        .foregroundStyle(.purple)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            if stranded > 0 {
                Label("\(stranded) idle GPU\(stranded == 1 ? "" : "s") stranded — CPUs full", systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Every CPU on this node is allocated, so no job can start on its idle GPUs")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .nodeCardChrome(highlighted: hasUserJob, tint: cardTint(slots))
        .animation(AppTheme.smoothEase, value: node)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model) node \(node.node)")
    }

    /// "7 of 8 allocated"; "unavailable" for an out-of-service node with no
    /// allocation reported (its GPUs count as unavailable either way); "? of
    /// 8" when an available node's allocation is missing.
    private var allocationText: String {
        guard let allocated = node.knownGPUAllocated else {
            return node.stateInfo.isAvailable ? "? of \(total) · unknown" : "\(total) unavailable"
        }
        return "\(min(allocated, total)) of \(total) allocated"
    }

    /// Memory a job could still get. Where Slurm tracks allocation that is
    /// total minus allocated; where it does not (Calder), only the OS view
    /// exists and is labelled as such — it is not what a job can request.
    @ViewBuilder
    private var memoryRow: some View {
        if let unallocated = coverage.unallocatedMemoryMB(for: node) {
            HStack {
                Text("Memory")
                Spacer()
                Text("\(gibText(unallocated)) unallocated")
                    .monospacedDigit()
            }
            .help("Memory Slurm can still allocate on this node")
        } else if let free = node.memoryFreeMB {
            HStack {
                Text("Memory")
                Spacer()
                Text("\(gibText(free)) OS free")
                    .monospacedDigit()
            }
            .help("Free memory as the operating system reports it (scontrol FreeMem). This cluster does not track allocated memory, so this is not a guarantee of what a job can request.")
        }
    }

    private func cardTint(_ slots: [GPUSlotKind]) -> Color {
        if !node.stateInfo.isAvailable {
            return Color.gray.opacity(0.12)
        }
        if slots.contains(.idle) {
            return AppTheme.panelBackground
        }
        return AppTheme.gpu.opacity(0.08)
    }
}

struct GeneralNodeCard: View {
    let node: NodeSummary
    let style: PartitionRole
    let hasUserJob: Bool
    var coverage = NodeMetricCoverage(nodes: [])

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
                    .help(nodeStateHelp(node, gpuNode: false))
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

                memoryRows
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .nodeCardChrome(highlighted: hasUserJob, tint: cardTint)
        .animation(AppTheme.smoothEase, value: cpuRatio)
        .animation(AppTheme.smoothEase, value: node.state)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(NodeGrouping.shortNoun(for: style)) node \(node.node)")
    }

    /// Allocated memory where Slurm tracks it; otherwise the OS's in-use
    /// figure, labelled as such (it includes page cache, so it is not what
    /// jobs hold); otherwise "not tracked" — never an empty "0/754G" bar on
    /// a busy node.
    @ViewBuilder
    private var memoryRows: some View {
        if coverage.memoryTracked, let allocated = node.memoryAllocatedMB, let total = node.memoryMB, total > 0 {
            HStack {
                Text("Memory")
                Spacer()
                Text("\(allocated / 1024)/\(total / 1024)G")
                    .monospacedDigit()
            }
            ProgressView(value: min(Double(allocated) / Double(total), 1))
                .tint(.purple)
                .accessibilityLabel("Memory allocated")
        } else if let free = node.memoryFreeMB, let total = node.memoryMB, total > 0 {
            let used = max(total - free, 0)
            HStack {
                Text("Memory (OS)")
                Spacer()
                Text("\(used / 1024)/\(total / 1024)G in use")
                    .monospacedDigit()
            }
            .help("This cluster does not track allocated memory. This is the operating system's view (total minus FreeMem), which includes file cache.")
            ProgressView(value: min(Double(used) / Double(total), 1))
                .tint(.purple.opacity(0.55))
                .accessibilityLabel("Memory in use as reported by the operating system")
        } else {
            HStack {
                Text("Memory")
                Spacer()
                Text("not tracked")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Same role colours as the Partitions tab.
    private var accentColor: Color {
        partitionRoleAccent(style)
    }

    private var cardTint: Color {
        if !node.stateInfo.isAvailable {
            return Color.gray.opacity(0.12)
        }
        return accentColor.opacity(0.08)
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
