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

        VStack(alignment: .leading, spacing: 14) {
            PageHeader(
                title: "\(profile.displayName) partitions",
                subtitle: "Capacity by queue, state, walltime and resource class",
                systemImage: "square.grid.2x2",
                accent: .purple
            ) {
                DetailsToggleButton(showDetails: $showDetails)
            }

            HStack(spacing: 12) {
                MetricView(
                    title: "Partitions",
                    value: "\(groups.count)",
                    subtitle: "\(groups.filter(\.isAvailable).count) available",
                    systemImage: "rectangle.3.group",
                    accent: .blue
                )
                MetricView(
                    title: "Nodes",
                    value: "\(groups.reduce(0) { $0 + $1.totalNodes })",
                    subtitle: "summed across partitions",
                    systemImage: "server.rack",
                    accent: .purple
                )
                MetricView(
                    title: "GPU Capacity",
                    value: "\(gpuCapacity)",
                    subtitle: gpuCapacitySubtitle(groups),
                    systemImage: PartitionRole.gpu.systemImage,
                    accent: AppTheme.gpu
                )
                MetricView(
                    title: "Maint Rows",
                    value: "\(maintenanceRows)",
                    subtitle: "maintenance states",
                    systemImage: "wrench.and.screwdriver",
                    accent: .red
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

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270, maximum: 380), spacing: 12)], spacing: 12) {
                    ForEach(groups) { group in
                        PartitionCard(group: group)
                    }
                }
                .padding(.vertical, 2)
            }

            if showDetails {
                SectionHeader(title: "Partition details", subtitle: "\(partitions.count) rows")
                PartitionsTable(partitions: partitions)
                    .frame(height: 300)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(AppTheme.smoothEase, value: showDetails)
    }

    /// Configured GPUs summed over partitions (every state row carries its
    /// own node count). A node listed in two GPU partitions would count
    /// twice; neither Leeds cluster shares GPU nodes between partitions.
    private var gpuCapacity: Int {
        partitions.reduce(0) { total, row in
            total + ((row.nodeCount ?? 0) * slurmGPUTotal(from: row.gres))
        }
    }

    /// Names the GPU model ("H200 GPUs configured") so a Calder figure can
    /// never be read as AIRE L40S capacity, or vice versa.
    private func gpuCapacitySubtitle(_ groups: [PartitionGroup]) -> String {
        var models: [String] = []
        for group in groups where group.gpusPerNode > 0 {
            if let model = group.gpuModel, !models.contains(model) {
                models.append(model)
            }
        }
        if gpuCapacity == 0 {
            return "no GPU partitions"
        }
        if models.isEmpty {
            return "configured GPUs"
        }
        return "\(models.joined(separator: " + ")) GPUs configured"
    }

    private var maintenanceRows: Int {
        partitions.filter { $0.state.lowercased().contains("maint") }.count
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
    }

    var id: String { name }

    var totalNodes: Int {
        rows.reduce(0) { $0 + ($1.nodeCount ?? 0) }
    }

    var isAvailable: Bool {
        rows.contains { $0.availability == "up" }
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
                    Text(group.name)
                        .font(.callout.weight(.semibold))
                    Text("\(group.totalNodes) nodes")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let walltime {
                        Label(walltime, systemImage: "timer")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Maximum walltime")
                    }
                    Spacer()
                    Text(group.isAvailable ? "up" : "down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(group.isAvailable ? .green : .red)
                }
                PartitionStateBar(rows: group.rows)
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

    private var accessibilityValue: String {
        var parts = ["\(group.totalNodes) nodes", group.isAvailable ? "up" : "down"]
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
                StatePill(state: group.isAvailable ? "up" : "down")
            }

            PartitionStateBar(rows: group.rows)

            VStack(spacing: 6) {
                ForEach(group.rows.sorted { $0.state < $1.state }) { row in
                    HStack {
                        Circle()
                            .fill(colorForState(row.state))
                            .frame(width: 7, height: 7)
                        Text(row.state)
                        Spacer()
                        Text("\(row.nodeCount ?? 0)")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
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
                    // Slurm reports MiB; formatGB is 1024-based throughout the app.
                    Label(formatGB(Double(mem) / 1024), systemImage: "memorychip")
                        .help("Memory per node")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
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
    let rows: [PartitionSummary]

    private var segments: [MeterSegment] {
        rows.sorted { $0.state < $1.state }
            .enumerated()
            .map { index, row in
                MeterSegment(
                    id: "\(index)-\(row.state)",
                    value: max(row.nodeCount ?? 0, 0),
                    color: colorForState(row.state)
                )
            }
    }

    var body: some View {
        SegmentedMeter(segments: segments, height: 12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Node states")
            .accessibilityValue(
                rows.sorted { $0.state < $1.state }
                    .map { "\($0.nodeCount ?? 0) \($0.state)" }
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
