import HPCCore
import SwiftUI

/// The Partitions tab for one cluster. Icons, accents, order and card
/// subtitles come from the cluster profile's `PartitionHint`s, never from
/// hard-coded partition names, so AIRE's `gpu`/`nodes`/`himem`/
/// `teachingnodes` and Calder's `calder-gpu-hopper`/`calder-cpu-turin` share
/// one code path, and a partition the profile does not know yet still gets
/// sensible styling derived from its data.
struct PartitionsDashboard: View {
    let profile: ClusterProfile
    let partitions: [PartitionSummary]
    /// The same snapshot's nodes, for counts by unique node: AIRE's teaching
    /// nodes are also in `nodes`, so summing sinfo rows across partitions
    /// counts them twice. Empty (older call sites, or a snapshot without node
    /// rows) falls back to the summed rows and says so.
    var nodes: [NodeSummary] = []
    // Hoisted into the cluster's ClusterDashboardState so the toggle
    // survives tab switches.
    @Binding var showDetails: Bool

    /// One group per partition name. Grouping by name alone is safe because
    /// a dashboard only ever shows one cluster's partitions; two clusters'
    /// rows must never be fed through the same instance.
    private var groups: [PartitionGroup] {
        Dictionary(grouping: partitions, by: \.partition)
            .map { PartitionGroup(name: $0.key, rows: $0.value, profile: profile) }
            .sorted(by: PartitionGroup.displayOrder)
    }

    var body: some View {
        // Grouped once per render; the tiles, panel and cards all read it.
        let groups = self.groups
        let totals = PartitionTotals(partitions: partitions, nodes: nodes)

        VStack(alignment: .leading, spacing: 14) {
            PageHeader(
                title: "\(profile.displayName) partitions",
                subtitle: "Capacity by queue, state, walltime and resource class",
                systemImage: "square.grid.2x2",
                accent: .purple
            ) {
                DetailsToggleButton(showDetails: $showDetails)
            }

            HStack(alignment: .top, spacing: 12) {
                MetricView(
                    title: "Partitions",
                    value: "\(groups.count)",
                    subtitle: "\(groups.filter(\.health.acceptsWork).count) can start jobs",
                    systemImage: "rectangle.3.group",
                    accent: .blue
                )
                MetricView(
                    title: "Nodes",
                    value: groupedNumber(totals.nodeCount),
                    subtitle: totals.nodeSubtitle,
                    systemImage: "server.rack",
                    accent: .purple,
                    help: totals.nodeHelp
                )
                MetricView(
                    title: "GPU capacity",
                    value: groupedNumber(totals.gpuTotal),
                    subtitle: totals.gpuSubtitle,
                    systemImage: PartitionRole.gpu.systemImage,
                    accent: AppTheme.gpu
                )
                MetricView(
                    title: "Unavailable nodes",
                    value: groupedNumber(totals.unavailableNodes),
                    subtitle: totals.unavailableSubtitle,
                    systemImage: "wrench.and.screwdriver",
                    accent: totals.unavailableNodes > 0 ? StatusTone.unavailable.color : .green
                )
            }

            if groups.isEmpty {
                EmptyVisual(
                    title: "No partition data yet",
                    subtitle: "\(profile.displayName) queue capacity appears after the next successful refresh.",
                    systemImage: "square.grid.2x2"
                )
            } else {
                PartitionPortfolioPanel(groups: groups)

                // Top-aligned cells: cards of different heights in one row
                // start on the same line instead of being centred.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270, maximum: 380), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(groups) { group in
                        PartitionCard(group: group)
                    }
                }
                .padding(.vertical, 2)
            }

            if showDetails {
                SectionHeader(title: "Partition details", subtitle: pluralized(partitions.count, "row"))
                PartitionsTable(partitions: partitions)
                    .frame(height: 300)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(AppTheme.smoothEase, value: showDetails)
    }
}

/// Cluster-wide tile figures. Counted by unique node whenever the node list
/// is available, so a node in two partitions counts once and maintenance
/// reservations ("down$", "drain$") are seen; otherwise summed from sinfo
/// rows, with subtitles that say so.
struct PartitionTotals: Equatable {
    let nodeCount: Int
    let nodeSubtitle: String
    let nodeHelp: String
    let gpuTotal: Int
    let gpuSubtitle: String
    let unavailableNodes: Int
    let unavailableSubtitle: String

    init(partitions: [PartitionSummary], nodes: [NodeSummary]) {
        if nodes.isEmpty {
            nodeCount = partitions.reduce(0) { $0 + ($1.nodeCount ?? 0) }
            nodeSubtitle = "summed across partitions"
            nodeHelp = "Node counts summed across partition rows: a node in two partitions counts twice."
            // Rows: a node listed in two partitions counts twice here.
            gpuTotal = partitions.reduce(0) { $0 + ($1.nodeCount ?? 0) * slurmGPUTotal(from: $1.gres) }
            var models: [String: Int] = [:]
            var order: [String] = []
            for row in partitions {
                let count = (row.nodeCount ?? 0) * slurmGPUTotal(from: row.gres)
                guard count > 0 else { continue }
                let model = slurmGPUModelDisplayName(from: row.gres) ?? ""
                if models[model] == nil { order.append(model) }
                models[model, default: 0] += count
            }
            gpuSubtitle = Self.gpuSubtitle(order.map { ($0, models[$0] ?? 0) })
            let unavailableRows = partitions.filter { !NodeStateInfo($0.state).isAvailable }
            unavailableNodes = unavailableRows.reduce(0) { $0 + ($1.nodeCount ?? 0) }
            let maintenance = unavailableRows
                .filter { Self.isMaintenance(NodeStateInfo($0.state)) }
                .reduce(0) { $0 + ($1.nodeCount ?? 0) }
            unavailableSubtitle = maintenance > 0 ? "\(maintenance) in maintenance · summed rows" : "summed across partitions"
            return
        }
        nodeCount = nodes.count
        let shared = nodes.filter { $0.partitions.count > 1 }.count
        // Short enough for a quarter of the narrowest detail column, where
        // "11 nodes in more than one partition" was cut to "11 nodes in
        // more than…"; the tile's tooltip carries the long form.
        nodeSubtitle = shared > 0 ? "\(groupedNumber(shared)) in 2+ partitions" : "unique nodes"
        nodeHelp = shared > 0
            ? "\(pluralized(nodes.count, "node")), each counted once; \(pluralized(shared, "node")) \(shared == 1 ? "is" : "are") in more than one partition."
            : "\(pluralized(nodes.count, "node")), each in one partition."
        let fleet = GPUFleet(nodes: nodes)
        gpuTotal = fleet.total
        gpuSubtitle = Self.gpuSubtitle(fleet.pools.map { ($0.model ?? "", $0.total) })
        let unavailable = nodes.filter { !$0.stateInfo.isAvailable }
        unavailableNodes = unavailable.count
        let maintenance = unavailable.filter { Self.isMaintenance($0.stateInfo) }.count
        if unavailable.isEmpty {
            unavailableSubtitle = "every node accepts work"
        } else if maintenance > 0 {
            unavailableSubtitle = "\(maintenance) in maintenance"
        } else {
            unavailableSubtitle = "down, drained or not responding"
        }
    }

    /// "42 L40S configured", "56 H200 + 3 L40" — each model named with its
    /// own count, never one anonymous sum.
    private static func gpuSubtitle(_ models: [(String, Int)]) -> String {
        guard !models.isEmpty else {
            return "no GPU nodes"
        }
        if models.count == 1, models[0].0.isEmpty {
            return "configured GPUs"
        }
        let named = models
            .map { model, count in model.isEmpty ? "\(count) other" : "\(count) \(model)" }
            .joined(separator: " + ")
        // "configured" only fits beside one model: "56 H200 + 3 L40
        // configured" truncates in a quarter of the narrowest column, and
        // the tile's title already says it is capacity.
        return models.count == 1 ? named + " configured" : named
    }

    private static func isMaintenance(_ info: NodeStateInfo) -> Bool {
        info.maintenanceReservation || info.base == .maintenance
    }
}

struct PartitionsTable: View {
    let partitions: [PartitionSummary]

    var body: some View {
        Table(partitions) {
            TableColumn("Partition", value: \.partition)
            TableColumn("Availability", value: \.availability)
            TableColumn("State", value: \.state)
            TableColumn("Nodes") { item in
                Text(number(item.nodeCount))
            }
            TableColumn("GRES", value: \.gres)
            TableColumn("CPUs / Node") { item in
                Text(number(item.cpusPerNode))
            }
            TableColumn("Memory MB") { item in
                Text(number(item.memoryMBPerNode))
            }
            TableColumn("Max walltime") { item in
                Text(item.timeLimit.map(formatSlurmTimeLimit) ?? missingValuePlaceholder)
            }
        }
    }
}

/// All `sinfo` state rows of one partition, plus what the cluster profile
/// says the partition is for.
struct PartitionGroup: Identifiable {
    let name: String
    let rows: [PartitionSummary]
    /// The profile's hint, nil for a partition the profile does not know.
    let hint: PartitionHint?
    /// The hinted role, or — for an unknown partition — one derived from
    /// its data: GPU gres means a GPU partition, anything else is CPU.
    let role: PartitionRole

    init(name: String, rows: [PartitionSummary], profile: ClusterProfile) {
        self.name = name
        self.rows = rows
        hint = profile.hint(forPartition: name)
        if let hinted = hint?.role {
            role = hinted
        } else if rows.contains(where: { slurmGPUTotal(from: $0.gres) > 0 || $0.gres.lowercased().contains("gpu") }) {
            role = .gpu
        } else {
            role = .cpu
        }
        health = PartitionHealth(rows: rows)
        sortedRows = rows.sorted { lhs, rhs in
            let left = NodeStateInfo(lhs.state).displayRank
            let right = NodeStateInfo(rhs.state).displayRank
            return left != right ? left < right : lhs.state < rhs.state
        }
    }

    var id: String { name }

    /// Whether the partition can start work now, from both sinfo's
    /// administrative flag (%a) and the state of its nodes.
    let health: PartitionHealth

    /// State rows in display order: busy, idle, then unavailable flavours.
    let sortedRows: [PartitionSummary]

    /// Nodes in this partition. Rows of ONE partition never overlap, so the
    /// sum is exact here (unlike a sum across partitions).
    var totalNodes: Int {
        rows.reduce(0) { $0 + ($1.nodeCount ?? 0) }
    }

    var cpusPerNode: Int? {
        rows.compactMap(\.cpusPerNode).first
    }

    var memoryMBPerNode: Int? {
        rows.compactMap(\.memoryMBPerNode).first
    }

    var gres: String {
        rows.first(where: { $0.gres != "(null)" })?.gres ?? "none"
    }

    var gpusPerNode: Int {
        rows.map { slurmGPUTotal(from: $0.gres) }.max() ?? 0
    }

    /// "H200", "L40S"; nil for CPU partitions or a gres without a model.
    var gpuModel: String? {
        rows.lazy.compactMap { slurmGPUModelDisplayName(from: $0.gres) }.first
    }

    /// Raw `sinfo %l` value ("2-00:00:00", "infinite"); nil when the
    /// snapshot predates the column.
    var timeLimit: String? {
        rows.lazy
            .compactMap(\.timeLimit)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// "8 × H200" — the per-node GPU shape of a GPU partition.
    var gpuShapeText: String? {
        guard gpusPerNode > 0 else {
            return nil
        }
        return "\(gpusPerNode) × \(gpuModel ?? "GPU")"
    }

    /// The profile's one-line summary, or a description built from data for
    /// partitions the profile does not know ("H200 GPU partition").
    var summary: String {
        if let summary = hint?.summary, !summary.isEmpty {
            return summary
        }
        switch role {
        case .gpu:
            return gpuModel.map { "\($0) GPU partition" } ?? "GPU partition"
        case .cpu:
            return "CPU partition"
        case .highMemory:
            return "high-memory partition"
        case .teaching:
            return "teaching partition"
        case .other:
            return "partition"
        }
    }

    /// High-memory and teaching queues: the specialist pools beside the
    /// general CPU and GPU partitions.
    var isSpecialist: Bool {
        role == .highMemory || role == .teaching
    }

    var systemImage: String {
        role.systemImage
    }

    var accent: Color {
        partitionRoleAccent(role)
    }

    /// Profile order first (lower `sortRank` wins); partitions the profile
    /// does not know follow, GPU before CPU, then by name.
    static func displayOrder(_ lhs: PartitionGroup, _ rhs: PartitionGroup) -> Bool {
        if lhs.sortKey != rhs.sortKey {
            return lhs.sortKey < rhs.sortKey
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private var sortKey: Int {
        if let rank = hint?.sortRank {
            return rank
        }
        let roleOrder: [PartitionRole] = [.gpu, .cpu, .highMemory, .teaching, .other]
        return 10_000 + (roleOrder.firstIndex(of: role) ?? roleOrder.count)
    }
}

/// Whether a partition can start a job now. sinfo's availability column
/// (%a) is only the administrative switch: a partition whose every node is
/// drained still reports "up", so node states decide the rest.
enum PartitionHealth: Equatable {
    /// Up, and every node accepts work.
    case up
    /// Up, but only some nodes accept work.
    case degraded(usable: Int, total: Int)
    /// Up, but no node can start anything (all drained, down, reserved…).
    case noUsableNodes(total: Int)
    /// Administratively not "up": the %a text ("down", "drain", "inact").
    case down(String)

    init(rows: [PartitionSummary]) {
        let upRows = rows.filter { $0.availability.trimmingCharacters(in: .whitespaces).lowercased() == "up" }
        guard !upRows.isEmpty else {
            let state = rows.lazy
                .map { $0.availability.trimmingCharacters(in: .whitespaces).lowercased() }
                .first { !$0.isEmpty } ?? "down"
            self = .down(state == "inact" ? "inactive" : state)
            return
        }
        // A row without a node count (older caches) still stands for at
        // least one node; counting it as zero would read "no usable nodes".
        let total = rows.reduce(0) { $0 + max($1.nodeCount ?? 1, 0) }
        let usable = upRows
            .filter { NodeStateInfo($0.state).isAvailable }
            .reduce(0) { $0 + max($1.nodeCount ?? 1, 0) }
        if usable == 0 {
            self = .noUsableNodes(total: total)
        } else if usable < total {
            self = .degraded(usable: usable, total: total)
        } else {
            self = .up
        }
    }

    /// Up or degraded: a job submitted here can start without waiting for
    /// an administrator.
    var acceptsWork: Bool {
        switch self {
        case .up, .degraded:
            return true
        case .noUsableNodes, .down:
            return false
        }
    }

    /// Every node out of service (drained, down, reserved) is the
    /// "accepts no work" class the palette draws grey everywhere (the
    /// Unavailable nodes tile, a wholly unavailable GPU pool's header chip,
    /// the capacity signal), not an alarm; red is kept for a partition
    /// Slurm itself reports down or inactive.
    var tone: StatusTone {
        switch self {
        case .up: return .normal
        case .degraded: return .warning
        case .noUsableNodes: return .unavailable
        case .down: return .critical
        }
    }

    /// Portfolio-row text: "up", "up · 5 of 7 usable", "no usable nodes",
    /// "down".
    var label: String {
        switch self {
        case .up:
            return "up"
        case let .degraded(usable, total):
            return "up · \(usable) of \(total) usable"
        case .noUsableNodes:
            return "no usable nodes"
        case .down(let state):
            return state
        }
    }

    /// Short pill text for cards.
    var pillText: String {
        switch self {
        case .up: return "Up"
        case let .degraded(usable, total): return "\(usable) of \(total) usable"
        case .noUsableNodes: return "No usable nodes"
        case .down(let state): return state
        }
    }

    var help: String {
        switch self {
        case .up:
            return "The partition is up and every node accepts work."
        case let .degraded(usable, total):
            return "Up, but only \(usable) of \(total) nodes accept work; the rest are drained, down or reserved."
        case .noUsableNodes(let total):
            return "The partition is up, but none of its \(pluralized(total, "node")) accepts work (drained, down or reserved), so jobs submitted here wait."
        case .down(let state):
            return "Slurm reports the partition as \(state): jobs can be submitted but will not start."
        }
    }
}

struct PartitionPortfolioPanel: View {
    let groups: [PartitionGroup]

    private func names(_ matching: (PartitionGroup) -> Bool) -> [String] {
        groups.filter(matching).map(\.name)
    }

    var body: some View {
        let gpu = names { $0.role == .gpu }
        let specialist = names(\.isSpecialist)
        let cpu = names { $0.role == .cpu }
        let other = names { $0.role == .other }

        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Queue portfolio", subtitle: "\(groups.count) partitions")
                VStack(spacing: 8) {
                    ForEach(groups) { group in
                        PartitionPortfolioRow(group: group)
                    }
                }
            }

            Divider()
                .frame(height: 150)

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Resource classes", subtitle: "at a glance")
                classChip("GPU", names: gpu, role: .gpu)
                classChip("Special", names: specialist, systemImage: "sparkles", color: partitionRoleAccent(.highMemory))
                classChip("CPU", names: cpu, role: .cpu)
                if !other.isEmpty {
                    classChip("Other", names: other, role: .other)
                }
            }
            .frame(width: 190, alignment: .leading)
        }
        .dashboardCard(accent: .purple)
    }

    private func classChip(_ label: String, names: [String], role: PartitionRole) -> some View {
        classChip(label, names: names, systemImage: role.systemImage, color: partitionRoleAccent(role))
    }

    /// The tooltip names the partitions behind each count, so "Special 2"
    /// is explained on AIRE and "Special 0" is unsurprising on Calder.
    private func classChip(_ label: String, names: [String], systemImage: String, color: Color) -> some View {
        InfoChip(label: label, value: "\(names.count)", systemImage: systemImage, color: color)
            .help(names.isEmpty ? "No \(label.lowercased()) partitions on this cluster" : names.joined(separator: ", "))
    }
}

struct PartitionPortfolioRow: View {
    let group: PartitionGroup

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(group.accent.opacity(0.12))
                Image(systemName: group.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(group.accent)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    // One line, never "calder-\ngpu-hopper": the name has
                    // first claim on the row, and the node count and walltime
                    // (both repeated on the partition's card) give way
                    // before it would wrap.
                    Text(group.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            nodeCountText
                            walltimeLabel
                        }
                        nodeCountText
                        Color.clear.frame(width: 0, height: 0)
                    }
                    Spacer(minLength: 6)
                    Text(group.health.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(group.health.tone.color)
                        .lineLimit(1)
                        .fixedSize()
                        .help(group.health.help)
                }
                PartitionStateBar(rows: group.sortedRows)
            }
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(group.accent.opacity(0.16), lineWidth: 1)
        )
        .animation(AppTheme.smoothEase, value: group.totalNodes)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Partition \(group.name), \(group.role.title)")
        .accessibilityValue(accessibilityValue)
    }

    private var walltime: String? {
        group.timeLimit.map(formatSlurmTimeLimit)
    }

    private var nodeCountText: some View {
        Text(pluralized(group.totalNodes, "node"))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    @ViewBuilder
    private var walltimeLabel: some View {
        if let walltime {
            Label(walltime, systemImage: "timer")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .help("Maximum walltime")
        }
    }

    private var accessibilityValue: String {
        var parts = [pluralized(group.totalNodes, "node"), group.health.label]
        if let walltime {
            parts.append("maximum walltime \(walltime)")
        }
        return parts.joined(separator: ", ")
    }
}

struct PartitionCard: View {
    let group: PartitionGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(group.accent.opacity(0.12))
                    Image(systemName: group.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(group.accent)
                }
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.headline)
                    Text(group.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusCapsule(text: group.health.pillText, color: group.health.tone.color, help: group.health.help)
            }

            PartitionStateBar(rows: group.sortedRows)

            VStack(spacing: 6) {
                ForEach(group.sortedRows) { row in
                    let info = NodeStateInfo(row.state)
                    HStack {
                        Circle()
                            .fill(SlurmState(node: info).color)
                            .frame(width: 7, height: 7)
                        // Plain words ("Drained · not responding"); the raw
                        // sinfo code ("drain*") stays in the tooltip.
                        Text(info.legendText)
                            .lineLimit(1)
                        Spacer()
                        Text("\(row.nodeCount ?? 0)")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(info.helpText)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(info.legendText)
                    .accessibilityValue(pluralized(row.nodeCount ?? 0, "node"))
                }
            }

            if group.timeLimit != nil || group.gpuShapeText != nil {
                // Two chips overflow the narrowest grid column; stack them
                // rather than let the card clip them.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        limitChips
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        limitChips
                    }
                }
            }

            HStack(spacing: 14) {
                Label("\(group.totalNodes)", systemImage: "server.rack")
                    .help("Nodes")
                if let cpus = group.cpusPerNode {
                    Label("\(cpus) CPU", systemImage: "cpu")
                        .help("CPU cores per node")
                }
                if let mem = group.memoryMBPerNode {
                    // Slurm reports MiB; sizes are 1024-based throughout the app.
                    Label(formatMemoryGB(Double(mem) / 1024), systemImage: "memorychip")
                        .help("Memory per node")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        // Fill the grid row so cards beside a taller one keep a common top
        // and bottom edge.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dashboardCard(accent: group.accent)
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(group.accent.opacity(0.70))
                .frame(height: 3)
                .padding(.horizontal, 12)
        }
        .animation(AppTheme.smoothEase, value: group.totalNodes)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Partition \(group.name)")
    }

    @ViewBuilder
    private var limitChips: some View {
        if let limit = group.timeLimit {
            InfoChip(label: "Max walltime", value: formatSlurmTimeLimit(limit), systemImage: "timer", color: group.accent)
        }
        if let shape = group.gpuShapeText {
            InfoChip(label: "Per node", value: shape, systemImage: PartitionRole.gpu.systemImage, color: AppTheme.gpu)
        }
    }
}

struct PartitionStateBar: View {
    /// Rows in display order (`PartitionGroup.sortedRows`).
    let rows: [PartitionSummary]

    private var segments: [MeterSegment] {
        rows.enumerated().map { index, row in
            let info = NodeStateInfo(row.state)
            return MeterSegment(
                id: "\(index)-\(info.legendText)",
                value: max(row.nodeCount ?? 0, 0),
                color: SlurmState(node: info).color
            )
        }
    }

    var body: some View {
        SegmentedMeter(segments: segments, height: 12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Node states")
            .accessibilityValue(
                rows.map { "\($0.nodeCount ?? 0) \(NodeStateInfo($0.state).legendText)" }
                    .joined(separator: ", ")
            )
    }
}

/// Accent for a partition role, shared by the Partitions and Nodes tabs so a
/// role looks the same everywhere: GPU cyan, CPU teal, high-memory purple
/// (matching the memory bars on node cards), teaching indigo.
func partitionRoleAccent(_ role: PartitionRole) -> Color {
    switch role {
    case .gpu:
        return AppTheme.gpu
    case .cpu:
        return AppTheme.cpu
    case .highMemory:
        return .purple
    case .teaching:
        return .indigo
    case .other:
        return .gray
    }
}
