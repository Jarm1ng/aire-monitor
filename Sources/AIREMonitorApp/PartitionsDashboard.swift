import SwiftUI

struct PartitionsDashboard: View {
    let partitions: [PartitionSummary]
    // Hoisted into DashboardView so the toggle survives tab switches.
    @Binding var showDetails: Bool

    private var groups: [PartitionGroup] {
        Dictionary(grouping: partitions, by: \.partition)
            .map { PartitionGroup(name: $0.key, rows: $0.value) }
            .sorted { partitionSortKey($0.name) < partitionSortKey($1.name) }
    }

    private var totalNodes: Int {
        groups.reduce(0) { $0 + $1.totalNodes }
    }

    private var availablePartitions: Int {
        groups.filter { $0.isAvailable }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(
                title: "Partitions",
                subtitle: "Capacity by queue, state, and resource class",
                systemImage: "square.grid.2x2",
                accent: .purple
            ) {
                DetailsToggleButton(showDetails: $showDetails)
            }

            HStack(spacing: 12) {
                MetricView(title: "Partitions", value: "\(groups.count)", subtitle: "\(availablePartitions) available", systemImage: "rectangle.3.group", accent: .blue)
                MetricView(title: "Nodes", value: "\(totalNodes)", subtitle: "state rows merged", systemImage: "server.rack", accent: .purple)
                MetricView(title: "GPU Capacity", value: "\(gpuCapacity)", subtitle: "configured GPUs", systemImage: "memorychip", accent: AIRETheme.gpu)
                MetricView(title: "Maint Rows", value: "\(maintenanceRows)", subtitle: "maintenance states", systemImage: "wrench.and.screwdriver", accent: .red)
            }

            if groups.isEmpty {
                EmptyVisual(
                    title: "No partition data yet",
                    subtitle: "Queue capacity appears after the next successful refresh.",
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
        .animation(AIRETheme.smoothEase, value: showDetails)
    }

    private var gpuCapacity: Int {
        partitions.reduce(0) { total, row in
            total + ((row.nodeCount ?? 0) * slurmGPUTotal(from: row.gres))
        }
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
        }
    }
}

struct PartitionGroup: Identifiable {
    let name: String
    let rows: [PartitionSummary]

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
}

struct PartitionPortfolioPanel: View {
    let groups: [PartitionGroup]

    private var gpuGroups: Int {
        groups.filter { $0.gres.lowercased().contains("gpu") }.count
    }

    private var specialistGroups: Int {
        groups.filter { $0.name == "himem" || $0.name == "teachingnodes" }.count
    }

    var body: some View {
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
                InfoChip(label: "GPU", value: "\(gpuGroups)", systemImage: "memorychip", color: AIRETheme.gpu)
                InfoChip(label: "Special", value: "\(specialistGroups)", systemImage: "sparkles", color: .indigo)
                InfoChip(label: "CPU", value: "\(max(groups.count - gpuGroups, 0))", systemImage: "cpu", color: AIRETheme.cpu)
            }
            .frame(width: 190, alignment: .leading)
        }
        .dashboardCard(accent: .purple)
    }
}

struct PartitionPortfolioRow: View {
    let group: PartitionGroup

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(accentColor.opacity(0.12))
                Image(systemName: iconName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accentColor)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(group.name)
                        .font(.callout.weight(.semibold))
                    Text("\(group.totalNodes) nodes")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
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
                .stroke(accentColor.opacity(0.16), lineWidth: 1)
        )
        .animation(AIRETheme.smoothEase, value: group.totalNodes)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Partition \(group.name)")
        .accessibilityValue("\(group.totalNodes) nodes, \(group.isAvailable ? "up" : "down")")
    }

    private var iconName: String {
        partitionIcon(name: group.name, gres: group.gres)
    }

    private var accentColor: Color {
        partitionAccent(name: group.name, gres: group.gres)
    }
}

struct PartitionCard: View {
    let group: PartitionGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(accentColor.opacity(0.12))
                    Image(systemName: iconName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accentColor)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.headline)
                    Text(partitionSubtitle)
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
                }
            }

            HStack(spacing: 14) {
                Label("\(group.totalNodes)", systemImage: "server.rack")
                if let cpus = group.cpusPerNode {
                    Label("\(cpus) CPU", systemImage: "cpu")
                }
                if let mem = group.memoryMBPerNode {
                    Label("\(mem / 1024)G", systemImage: "memorychip")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .dashboardCard(accent: accentColor)
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accentColor.opacity(0.70))
                .frame(height: 3)
                .padding(.horizontal, 12)
        }
        .animation(AIRETheme.smoothEase, value: group.totalNodes)
    }

    private var partitionSubtitle: String {
        if group.gres.lowercased().contains("gpu") {
            return "\(group.gres) • training queue"
        }
        if group.name == "himem" {
            return "high-memory CPU queue"
        }
        return group.gres == "none" ? "CPU queue" : group.gres
    }

    private var iconName: String {
        partitionIcon(name: group.name, gres: group.gres)
    }

    private var accentColor: Color {
        partitionAccent(name: group.name, gres: group.gres)
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
    }
}

func partitionIcon(name: String, gres: String) -> String {
    if gres.lowercased().contains("gpu") {
        return "memorychip"
    }
    if name == "himem" {
        return "memorychip.fill"
    }
    if name == "teachingnodes" {
        return "graduationcap"
    }
    return "cpu"
}

func partitionAccent(name: String, gres: String) -> Color {
    if gres.lowercased().contains("gpu") {
        return AIRETheme.gpu
    }
    if name == "himem" {
        return .indigo
    }
    if name == "teachingnodes" {
        return .orange
    }
    return AIRETheme.cpu
}

func partitionSortKey(_ name: String) -> String {
    switch name {
    case "gpu":
        return "0-\(name)"
    case "nodes":
        return "1-\(name)"
    case "himem":
        return "2-\(name)"
    case "teachingnodes":
        return "3-\(name)"
    default:
        return "9-\(name)"
    }
}
