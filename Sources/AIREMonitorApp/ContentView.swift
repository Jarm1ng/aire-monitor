import AppKit
import SwiftUI

private enum AIRETheme {
    static let pageBackground = Color(nsColor: .windowBackgroundColor)
    static let sidebarBackground = Color(nsColor: .underPageBackgroundColor)
    static let panelBackground = Color(nsColor: .controlBackgroundColor)
    static let insetBackground = Color(nsColor: .textBackgroundColor)
    static let border = Color.primary.opacity(0.08)
    static let softBorder = Color.primary.opacity(0.05)
    static let mutedFill = Color.primary.opacity(0.035)
    static let gpu = Color.cyan
    static let cpu = Color.teal
    static let storage = Color.indigo
    static let warning = Color.orange
}

private extension View {
    func dashboardCard(padding: CGFloat = 12) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(AIRETheme.panelBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AIRETheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: Color.black.opacity(0.045), radius: 8, x: 0, y: 3)
    }
}

struct AIRELogoMark: View {
    var cornerRadius: CGFloat = 8

    var body: some View {
        Group {
            if let image = Self.logoImage() {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "server.rack")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AIRETheme.gpu)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AIRETheme.gpu.opacity(0.12))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
    }

    private static func logoImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "AIRELogo", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        let fallback = FileManager.default.currentDirectoryPath + "/assets/AIRELogo.png"
        return NSImage(contentsOfFile: fallback)
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 18) {
                SidebarHeader()
                connectionForm
                actions
                statusPanel
                Spacer()
            }
            .padding(16)
            .background(AIRETheme.sidebarBackground)
            .navigationTitle("AIRE")
            .frame(minWidth: 340)
        } detail: {
            DashboardView(model: model)
                .background(AIRETheme.pageBackground)
        }
        .frame(minWidth: 1240, minHeight: 780)
    }

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Connection", subtitle: "SSH and Duo authentication")

            Toggle("Use local SSH alias", isOn: $model.useSSHAlias)
                .toggleStyle(.switch)

            LabeledContent("SSH alias") {
                TextField("aire", text: $model.sshAlias)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!model.useSSHAlias)
            }

            LabeledContent("Username") {
                TextField("Username", text: $model.username)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.useSSHAlias)
            }

            LabeledContent("Password") {
                SecureField("Password", text: $model.password)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("Duo option") {
                TextField("1", text: $model.duoOption)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
            }

            LabeledContent("AIRE host") {
                TextField("aire.leeds.ac.uk", text: $model.aireHostname)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.useSSHAlias)
            }

            LabeledContent("Jump host") {
                TextField("rash.leeds.ac.uk", text: $model.jumpHostname)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.useSSHAlias)
            }

            LabeledContent("Project root") {
                TextField("Path to this project", text: $model.projectRoot)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .font(.callout)
        .dashboardCard()
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                model.login()
            } label: {
                Label(model.isLoggingIn ? "Logging in" : "Login", systemImage: "person.crop.circle.badge.checkmark")
            }
            .disabled(model.isLoggingIn || model.isRefreshing)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                model.refresh()
            } label: {
                Label(model.isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoggingIn || model.isRefreshing)
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button {
                model.openDesktopWidget()
            } label: {
                Label("Widget", systemImage: "rectangle.on.rectangle.angled")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Session", subtitle: model.isLoggedIn ? "Connected" : "Not connected")
            HStack {
                Circle()
                    .fill(model.isLoggedIn ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(model.statusMessage)
                    .lineLimit(3)
                    .font(.callout)
                    .foregroundStyle(model.isLoggedIn ? .primary : .secondary)
            }

            if let error = model.errorMessage, !error.isEmpty {
                ScrollView {
                    Text(error)
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 90, maxHeight: 180)
                .padding(8)
                .background(AIRETheme.insetBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .dashboardCard()
    }
}

struct SidebarHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            AIRELogoMark()
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 1) {
                Text("AIRE Monitor")
                    .font(.headline.weight(.semibold))
                Text("Slurm cluster dashboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SectionTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let accent: Color
    let trailing: Trailing

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        accent: Color,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.accent = accent
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(accent.opacity(0.14))
                Image(systemName: systemImage)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)
            trailing
        }
        .dashboardCard(padding: 12)
    }
}

struct InfoChip: View {
    let label: String
    let value: String
    let systemImage: String
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(color.opacity(0.10))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }
}

struct MeterSegment: Identifiable {
    let id: String
    let value: Int
    let color: Color
}

struct SegmentedMeter: View {
    let segments: [MeterSegment]
    var height: CGFloat = 12

    private var total: Int {
        segments.reduce(0) { $0 + max($1.value, 0) }
    }

    var body: some View {
        GeometryReader { proxy in
            if total == 0 {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(AIRETheme.mutedFill)
            } else {
                HStack(spacing: 2) {
                    ForEach(segments.filter { $0.value > 0 }) { segment in
                        RoundedRectangle(cornerRadius: height / 2)
                            .fill(segment.color)
                            .frame(width: max(proxy.size.width * CGFloat(segment.value) / CGFloat(total), 7))
                    }
                }
            }
        }
        .frame(height: height)
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            summaryCards

            TabView {
                JobsDashboard(jobs: model.snapshot?.jobs ?? [])
                    .tabItem { Label("Jobs", systemImage: "list.bullet.rectangle") }
                PartitionsDashboard(partitions: model.snapshot?.partitions ?? [])
                    .tabItem { Label("Partitions", systemImage: "square.grid.2x2") }
                NodesDashboard(nodes: model.snapshot?.nodes ?? [], jobs: model.snapshot?.jobs ?? [])
                    .tabItem { Label("Nodes", systemImage: "server.rack") }
                TrendsDashboard(history: model.history, snapshot: model.snapshot)
                    .tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }
                StorageDashboard(storage: model.snapshot?.storage ?? [], history: model.history)
                    .tabItem { Label("Storage", systemImage: "internaldrive") }
            }
            .padding(.top, 2)
        }
        .padding(18)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AIRE Monitor")
                    .font(.title2.weight(.semibold))
                if let snapshot = model.snapshot {
                    Text("\(snapshot.remote.hostname) • \(snapshot.remote.user) • \(snapshot.remote.remoteTime)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("No snapshot loaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            StatusBadge(isConnected: model.isLoggedIn)
            Button {
                model.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isRefreshing || model.isLoggingIn)
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private var summaryCards: some View {
        HStack(spacing: 12) {
            MetricView(title: "Jobs", value: "\(model.snapshot?.jobs.count ?? 0)", systemImage: "list.bullet.rectangle", accent: .blue)
            MetricView(title: "Partitions", value: "\(model.snapshot?.partitions.count ?? 0)", systemImage: "square.grid.2x2", accent: .purple)
            MetricView(title: "Nodes", value: "\(model.snapshot?.nodes.count ?? 0)", systemImage: "server.rack", accent: .teal)
            MetricView(title: "GPU Nodes", value: "\(gpuNodeCount)", systemImage: "memorychip", accent: AIRETheme.gpu)
        }
    }

    private var gpuNodeCount: Int {
        model.snapshot?.nodes.filter { $0.gres.lowercased().contains("gpu") }.count ?? 0
    }
}

struct StatusBadge: View {
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isConnected ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(isConnected ? "Connected" : "Offline")
                .font(.caption.weight(.medium))
                .foregroundStyle(isConnected ? .green : .secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background((isConnected ? Color.green : Color.gray).opacity(0.10))
        .clipShape(Capsule())
    }
}

struct MetricView: View {
    let title: String
    let value: String
    var subtitle: String?
    var systemImage: String?
    var accent: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accent)
                }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(accent)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard(padding: 11)
    }
}

struct DetailsToggleButton: View {
    @Binding var showDetails: Bool

    var body: some View {
        Button {
            showDetails.toggle()
        } label: {
            Label(showDetails ? "Hide Details" : "Show Details", systemImage: showDetails ? "tablecells.badge.ellipsis" : "tablecells")
        }
        .buttonStyle(.bordered)
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
            Spacer()
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct EmptyVisual: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .dashboardCard(padding: 20)
    }
}

struct JobsTable: View {
    let jobs: [Job]

    var body: some View {
        Table(jobs) {
            TableColumn("Job ID", value: \.jobId)
            TableColumn("Partition", value: \.partition)
            TableColumn("Name", value: \.name)
            TableColumn("State", value: \.state)
            TableColumn("Elapsed", value: \.elapsed)
            TableColumn("Limit", value: \.timeLimit)
            TableColumn("Nodes", value: \.nodes)
            TableColumn("Reason / Node", value: \.reasonOrNodeList)
        }
    }
}

struct JobsDashboard: View {
    let jobs: [Job]
    @State private var showDetails = false
    @State private var selectedJob: Job?

    private var runningJobs: [Job] {
        jobs.filter { $0.state.uppercased().contains("RUN") }
    }

    private var pendingJobs: [Job] {
        jobs.filter { $0.state.uppercased().contains("PEND") }
    }

    private var gpuJobs: [Job] {
        jobs.filter { $0.partition.lowercased().contains("gpu") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(
                title: "Job Activity",
                subtitle: "Current Slurm workload for the logged-in user",
                systemImage: "waveform.path.ecg.rectangle",
                accent: .blue
            ) {
                DetailsToggleButton(showDetails: $showDetails)
            }

            HStack(spacing: 12) {
                MetricView(title: "Running", value: "\(runningJobs.count)", subtitle: "active jobs", systemImage: "play.fill", accent: .green)
                MetricView(title: "Pending", value: "\(pendingJobs.count)", subtitle: "waiting", systemImage: "clock.fill", accent: .orange)
                MetricView(title: "GPU Jobs", value: "\(gpuJobs.count)", subtitle: "training or inference", systemImage: "memorychip", accent: AIRETheme.gpu)
                MetricView(title: "Total", value: "\(jobs.count)", subtitle: "visible jobs", systemImage: "sum", accent: .purple)
            }

            if jobs.isEmpty {
                EmptyVisual(
                    title: "No jobs in the queue",
                    subtitle: "Submitted jobs will appear here after the next refresh.",
                    systemImage: "checkmark.circle"
                )
            } else {
                JobPulsePanel(jobs: jobs)

                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 10)], spacing: 10) {
                        ForEach(jobs) { job in
                            JobCard(job: job) {
                                selectedJob = job
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 210, maxHeight: 380)
            }

            if showDetails {
                SectionHeader(title: "Job details", subtitle: "\(jobs.count) rows")
                JobsTable(jobs: jobs)
                    .frame(minHeight: 220)
            }
        }
        .sheet(item: $selectedJob) { job in
            JobDetailView(job: job)
                .frame(width: 720, height: 620)
        }
    }
}

struct JobPulsePanel: View {
    let jobs: [Job]

    private var runningCount: Int {
        jobs.filter { $0.state.uppercased().contains("RUN") }.count
    }

    private var pendingCount: Int {
        jobs.filter { $0.state.uppercased().contains("PEND") }.count
    }

    private var otherCount: Int {
        max(jobs.count - runningCount - pendingCount, 0)
    }

    private var stateSegments: [MeterSegment] {
        [
            MeterSegment(id: "Running", value: runningCount, color: .green),
            MeterSegment(id: "Pending", value: pendingCount, color: .orange),
            MeterSegment(id: "Other", value: otherCount, color: .secondary.opacity(0.65))
        ]
    }

    private var topPartitions: [(name: String, count: Int)] {
        Dictionary(grouping: jobs, by: \.partition)
            .map { (name: $0.key, count: $0.value.count) }
            .sorted {
                if $0.count == $1.count {
                    return $0.name < $1.name
                }
                return $0.count > $1.count
            }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Queue pulse", subtitle: "\(jobs.count) active records")
                SegmentedMeter(segments: stateSegments, height: 14)
                HStack(spacing: 8) {
                    InfoChip(label: "Run", value: "\(runningCount)", systemImage: "play.fill", color: .green)
                    InfoChip(label: "Wait", value: "\(pendingCount)", systemImage: "clock.fill", color: .orange)
                    InfoChip(label: "Other", value: "\(otherCount)", systemImage: "ellipsis", color: .secondary)
                }
            }

            Divider()
                .frame(height: 106)

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Partition mix", subtitle: "\(topPartitions.count) queues")
                VStack(spacing: 7) {
                    ForEach(Array(topPartitions.prefix(5)), id: \.name) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.name.lowercased().contains("gpu") ? "memorychip" : "cpu")
                                .foregroundStyle(item.name.lowercased().contains("gpu") ? AIRETheme.gpu : AIRETheme.cpu)
                            Text(item.name)
                                .lineLimit(1)
                            Spacer()
                            Text("\(item.count)")
                                .monospacedDigit()
                                .fontWeight(.semibold)
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(AIRETheme.mutedFill)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(maxWidth: 330)
        }
        .dashboardCard(padding: 13)
    }
}

struct JobCard: View {
    let job: Job
    var onSelect: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: isGPU ? "memorychip" : "terminal")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(accentColor)
                        Text(job.name)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    Text(job.jobId)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatePill(state: job.state)
            }

            HStack(spacing: 12) {
                Label(job.partition, systemImage: isGPU ? "memorychip" : "cpu")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(accentColor.opacity(0.10))
                    .clipShape(Capsule())
                Label("\(job.nodes) node\(job.nodes == "1" ? "" : "s")", systemImage: "server.rack")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AIRETheme.mutedFill)
                    .clipShape(Capsule())
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Elapsed")
                    Spacer()
                    Text(job.elapsed)
                        .monospacedDigit()
                }
                HStack {
                    Text("Limit")
                    Spacer()
                    Text(job.timeLimit)
                        .monospacedDigit()
                }
            }
            .font(.caption)

            HStack {
                Text(job.reasonOrNodeList)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
        }
        .padding(13)
        .background(jobCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(accentColor.opacity(0.22), lineWidth: 1)
        )
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 8)
                .fill(accentColor.opacity(0.70))
                .frame(height: 3)
                .padding(.horizontal, 10)
                .padding(.top, 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: Color.black.opacity(0.035), radius: 6, x: 0, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            onSelect?()
        }
    }

    private var isGPU: Bool {
        job.partition.lowercased().contains("gpu")
    }

    private var accentColor: Color {
        let state = job.state.lowercased()
        if state.contains("run") {
            return isGPU ? AIRETheme.gpu : .green
        }
        if state.contains("pend") {
            return .orange
        }
        return .secondary
    }

    private var jobCardBackground: Color {
        let state = job.state.lowercased()
        if state.contains("run") {
            return isGPU ? AIRETheme.gpu.opacity(0.08) : Color.green.opacity(0.08)
        }
        if state.contains("pend") {
            return Color.orange.opacity(0.08)
        }
        return Color(nsColor: .controlBackgroundColor)
    }
}

struct JobDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(accentColor.opacity(0.14))
                    Image(systemName: isGPU ? "memorychip" : "terminal")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(accentColor)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 4) {
                    Text(job.name)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    Text("\(job.jobId) • \(job.partition)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer()
                StatePill(state: job.state)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 12) {
                DetailMetric(title: "Elapsed", value: job.elapsed, systemImage: "timer", accent: .blue)
                DetailMetric(title: "Limit", value: job.timeLimit, systemImage: "hourglass", accent: .purple)
                DetailMetric(title: "Nodes", value: job.nodes, systemImage: "server.rack", accent: .teal)
                DetailMetric(title: "CPUs", value: number(job.numCpus), systemImage: "cpu", accent: .orange)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    DetailSection(title: "Timeline", systemImage: "calendar.badge.clock") {
                        DetailRow(label: "Submitted", value: job.submitTime)
                        DetailRow(label: "Started", value: job.startTime)
                        DetailRow(label: "Ends", value: job.endTime)
                        DetailRow(label: "Batch host", value: job.batchHost)
                    }

                    DetailSection(title: "Resources", systemImage: "square.stack.3d.up") {
                        DetailRow(label: "Node list", value: job.nodeList ?? job.reasonOrNodeList)
                        DetailRow(label: "Tasks", value: number(job.numTasks))
                        DetailRow(label: "Requested TRES", value: job.reqTres)
                        DetailRow(label: "Allocated TRES", value: job.allocTres)
                        DetailRow(label: "TRES per node", value: job.tresPerNode)
                    }

                    DetailSection(title: "Paths", systemImage: "folder") {
                        DetailRow(label: "Work directory", value: job.workDir)
                        DetailRow(label: "Command", value: job.command)
                        DetailRow(label: "Stdout", value: job.stdoutPath)
                        DetailRow(label: "Stderr", value: job.stderrPath)
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(18)
        .background(AIRETheme.pageBackground)
    }

    private var isGPU: Bool {
        job.partition.lowercased().contains("gpu")
    }

    private var accentColor: Color {
        if job.state.lowercased().contains("run") {
            return isGPU ? AIRETheme.gpu : .green
        }
        if job.state.lowercased().contains("pend") {
            return .orange
        }
        return .secondary
    }
}

struct DetailMetric: View {
    let title: String
    let value: String
    let systemImage: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(accent)
                Text(title)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            Text(value.isEmpty ? "n/a" : value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard(padding: 11)
    }
}

struct DetailSection<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(AIRETheme.gpu)
                Text(title)
                    .font(.headline.weight(.semibold))
            }
            content
        }
        .dashboardCard(padding: 13)
    }
}

struct DetailRow: View {
    let label: String
    let value: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .leading)
            Text(displayValue)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var displayValue: String {
        guard let value, !value.isEmpty else {
            return "n/a"
        }
        return value
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

struct PartitionsDashboard: View {
    let partitions: [PartitionSummary]
    @State private var showDetails = false

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

            PartitionPortfolioPanel(groups: groups)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270, maximum: 380), spacing: 12)], spacing: 12) {
                    ForEach(groups) { group in
                        PartitionCard(group: group)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 300, maxHeight: 470)

            if showDetails {
                SectionHeader(title: "Partition details", subtitle: "\(partitions.count) rows")
                PartitionsTable(partitions: partitions)
                    .frame(minHeight: 220)
            }
        }
    }

    private var gpuCapacity: Int {
        partitions.reduce(0) { total, row in
            total + ((row.nodeCount ?? 0) * parseGPUTotal(from: row.gres))
        }
    }

    private var maintenanceRows: Int {
        partitions.filter { $0.state.lowercased().contains("maint") }.count
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
        .dashboardCard(padding: 13)
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
        .background(AIRETheme.mutedFill)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var iconName: String {
        if group.gres.lowercased().contains("gpu") {
            return "memorychip"
        }
        if group.name == "himem" {
            return "memorychip.fill"
        }
        if group.name == "teachingnodes" {
            return "graduationcap"
        }
        return "cpu"
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
        .dashboardCard()
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 8)
                .fill(accentColor.opacity(0.70))
                .frame(height: 3)
                .padding(.horizontal, 12)
        }
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
        if group.gres.lowercased().contains("gpu") {
            return "memorychip"
        }
        if group.name == "himem" {
            return "memorychip.fill"
        }
        if group.name == "teachingnodes" {
            return "graduationcap"
        }
        return "cpu"
    }

    private var accentColor: Color {
        partitionAccent(name: group.name, gres: group.gres)
    }
}

struct PartitionStateBar: View {
    let rows: [PartitionSummary]

    private var total: Int {
        max(rows.reduce(0) { $0 + ($1.nodeCount ?? 0) }, 1)
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(rows.sorted { $0.state < $1.state }) { row in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(colorForState(row.state))
                        .frame(width: max(proxy.size.width * CGFloat(row.nodeCount ?? 0) / CGFloat(total), 4))
                }
            }
        }
        .frame(height: 12)
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

struct TrendsDashboard: View {
    let history: [TrendPoint]
    let snapshot: ClusterSnapshot?

    private var recentHistory: [TrendPoint] {
        Array(history.suffix(240))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(
                title: "Trends",
                subtitle: "Historical workload, GPU pressure, node health, and storage drift",
                systemImage: "chart.xyaxis.line",
                accent: .indigo
            ) {
                InfoChip(label: "Points", value: "\(history.count)", systemImage: "clock.arrow.circlepath", color: .indigo)
            }

            if recentHistory.count < 2 {
                EmptyVisual(
                    title: "Building trend history",
                    subtitle: "The app records one local point after each refresh. Charts become richer as the cache grows.",
                    systemImage: "chart.line.uptrend.xyaxis"
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        trendHero
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 310, maximum: 460), spacing: 12)], spacing: 12) {
                            TrendChartCard(
                                title: "Free GPUs",
                                subtitle: "Capacity available for new training jobs",
                                value: "\(recentHistory.last?.gpuIdle ?? 0)",
                                systemImage: "memorychip",
                                color: .green,
                                values: recentHistory.map { Double($0.gpuIdle) }
                            )
                            TrendChartCard(
                                title: "GPU Allocation",
                                subtitle: "Allocated GPUs across training nodes",
                                value: "\(recentHistory.last?.gpuAllocated ?? 0)/\(recentHistory.last?.gpuTotal ?? 0)",
                                systemImage: "gauge.with.dots.needle.67percent",
                                color: AIRETheme.gpu,
                                values: recentHistory.map { gpuPercent($0) }
                            )
                            TrendChartCard(
                                title: "Queue Pressure",
                                subtitle: "Running and pending jobs for the current user",
                                value: "\(recentHistory.last?.runningJobs ?? 0) run / \(recentHistory.last?.pendingJobs ?? 0) wait",
                                systemImage: "list.bullet.rectangle",
                                color: .orange,
                                values: recentHistory.map { Double($0.runningJobs + $0.pendingJobs) }
                            )
                            TrendChartCard(
                                title: "Unavailable GPU Nodes",
                                subtitle: "Nodes in down, drain, fail, or maintenance states",
                                value: "\(recentHistory.last?.unavailableGpuNodes ?? 0)",
                                systemImage: "exclamationmark.triangle",
                                color: .red,
                                values: recentHistory.map { Double($0.unavailableGpuNodes) }
                            )
                            TrendChartCard(
                                title: "Home Usage",
                                subtitle: "Quota pressure under /users",
                                value: percentText(recentHistory.last?.homeUsedPercent),
                                systemImage: "house",
                                color: .purple,
                                values: recentHistory.compactMap(\.homeUsedPercent)
                            )
                            TrendChartCard(
                                title: "Scratch Usage",
                                subtitle: "Quota pressure under /mnt/scratch",
                                value: percentText(recentHistory.last?.scratchUsedPercent),
                                systemImage: "externaldrive",
                                color: .teal,
                                values: recentHistory.compactMap(\.scratchUsedPercent)
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var trendHero: some View {
        HStack(spacing: 12) {
            InsightCard(
                title: "Best signal",
                value: trendSignal,
                subtitle: "Based on recent GPU availability",
                color: trendSignalColor,
                systemImage: "sparkline"
            )
            InsightCard(
                title: "Last point",
                value: recentHistory.last?.collectedAt ?? "n/a",
                subtitle: "Local cache timestamp",
                color: .secondary,
                systemImage: "clock"
            )
            InsightCard(
                title: "Window",
                value: "\(recentHistory.count)",
                subtitle: "recent refresh points",
                color: .indigo,
                systemImage: "point.3.connected.trianglepath.dotted"
            )
        }
    }

    private var trendSignal: String {
        guard let last = recentHistory.last else {
            return "Collecting"
        }
        if last.gpuIdle == 0 {
            return "GPU full"
        }
        if last.pendingJobs > last.runningJobs {
            return "Queue building"
        }
        if last.gpuIdle >= 8 {
            return "Room available"
        }
        return "Tight capacity"
    }

    private var trendSignalColor: Color {
        guard let last = recentHistory.last else {
            return .secondary
        }
        if last.gpuIdle == 0 {
            return .red
        }
        if last.gpuIdle >= 8 {
            return .green
        }
        return .orange
    }
}

struct StorageDashboard: View {
    let storage: [StorageSummary]
    let history: [TrendPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(
                title: "Storage",
                subtitle: "Quota and filesystem headroom for home and scratch spaces",
                systemImage: "internaldrive",
                accent: .teal
            ) {
                InfoChip(label: "Spaces", value: "\(storage.count)", systemImage: "folder", color: .teal)
            }

            if storage.isEmpty {
                EmptyVisual(
                    title: "No storage snapshot yet",
                    subtitle: "Storage quota information will appear after the next successful refresh.",
                    systemImage: "externaldrive.badge.questionmark"
                )
            } else {
                HStack(spacing: 12) {
                    ForEach(storage) { item in
                        StorageCard(item: item, history: history)
                    }
                }

                StorageComparison(storage: storage)
            }
        }
    }
}

struct InsightCard: View {
    let title: String
    let value: String
    let subtitle: String
    let color: Color
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.headline.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard(padding: 11)
    }
}

struct TrendChartCard: View {
    let title: String
    let subtitle: String
    let value: String
    let systemImage: String
    let color: Color
    let values: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: systemImage)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(color)
                Spacer()
                Text(value)
                    .font(.headline.monospacedDigit().weight(.semibold))
            }

            TrendLineChart(values: values, color: color)
                .frame(height: 118)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .dashboardCard(padding: 13)
    }
}

struct TrendLineChart: View {
    let values: [Double]
    let color: Color

    private var validValues: [Double] {
        values.filter { $0.isFinite }
    }

    var body: some View {
        GeometryReader { proxy in
            let data = validValues
            let minValue = data.min() ?? 0
            let maxValue = data.max() ?? 1
            let span = max(maxValue - minValue, 1)
            ZStack {
                VStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { _ in
                        Divider()
                        Spacer()
                    }
                    Divider()
                }
                .opacity(0.55)

                if data.count > 1 {
                    Path { path in
                        for index in data.indices {
                            let x = proxy.size.width * CGFloat(index) / CGFloat(max(data.count - 1, 1))
                            let yRatio = (data[index] - minValue) / span
                            let y = proxy.size.height - proxy.size.height * CGFloat(yRatio)
                            if index == data.startIndex {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                    Path { path in
                        for index in data.indices {
                            let x = proxy.size.width * CGFloat(index) / CGFloat(max(data.count - 1, 1))
                            let yRatio = (data[index] - minValue) / span
                            let y = proxy.size.height - proxy.size.height * CGFloat(yRatio)
                            if index == data.startIndex {
                                path.move(to: CGPoint(x: x, y: proxy.size.height))
                                path.addLine(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                        path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.20), color.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
            .background(AIRETheme.mutedFill)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct StorageCard: View {
    let item: StorageSummary
    let history: [TrendPoint]

    private var percent: Double {
        min(max(item.usedPercent ?? 0, 0), 100)
    }

    private var color: Color {
        if percent >= 90 {
            return .red
        }
        if percent >= 75 {
            return .orange
        }
        return item.label.lowercased() == "scratch" ? .teal : .purple
    }

    private var trendValues: [Double] {
        if item.label.lowercased() == "scratch" {
            return history.compactMap(\.scratchUsedPercent)
        }
        return history.compactMap(\.homeUsedPercent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(item.label, systemImage: item.label.lowercased() == "scratch" ? "externaldrive" : "house")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(color)
                    Text(item.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
                Spacer()
                RingMeter(value: percent / 100, color: color, label: "\(Int(percent.rounded()))%")
                    .frame(width: 74, height: 74)
            }

            HStack(spacing: 10) {
                StorageStat(title: "Used", value: formatGB(item.usedGB), color: color)
                StorageStat(title: "Free", value: formatGB(item.availableGB), color: .green)
                StorageStat(title: "Limit", value: formatGB(item.limitGB), color: .secondary)
            }

            TrendLineChart(values: trendValues, color: color)
                .frame(height: 72)

            if let fileLimit = item.fileLimit, fileLimit > 0 {
                StorageFileBar(count: item.fileCount, limit: fileLimit, color: color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard(padding: 14)
    }
}

struct StorageStat: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(AIRETheme.mutedFill)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct StorageFileBar: View {
    let count: Int?
    let limit: Int
    let color: Color

    private var ratio: Double {
        min(Double(count ?? 0) / Double(max(limit, 1)), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Files")
                Spacer()
                Text("\(count ?? 0) / \(limit)")
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            ProgressView(value: ratio)
                .tint(ratio > 0.9 ? .red : color)
        }
    }
}

struct StorageComparison: View {
    let storage: [StorageSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Space balance", subtitle: "Quota-backed remaining capacity")
            ForEach(storage) { item in
                HStack(spacing: 10) {
                    Text(item.label)
                        .font(.caption.weight(.semibold))
                        .frame(width: 70, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.green.opacity(0.16))
                            RoundedRectangle(cornerRadius: 5)
                                .fill(storageColor(item).opacity(0.85))
                                .frame(width: proxy.size.width * CGFloat(min(max((item.usedPercent ?? 0) / 100, 0), 1)))
                        }
                    }
                    .frame(height: 12)
                    Text("\(Int((item.usedPercent ?? 0).rounded()))%")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .frame(width: 42, alignment: .trailing)
                }
            }
        }
        .dashboardCard(padding: 13)
    }

    private func storageColor(_ item: StorageSummary) -> Color {
        let percent = item.usedPercent ?? 0
        if percent >= 90 {
            return .red
        }
        if percent >= 75 {
            return .orange
        }
        return item.label.lowercased() == "scratch" ? .teal : .purple
    }
}

struct NodesDashboard: View {
    let nodes: [NodeSummary]
    let jobs: [Job]
    @State private var filter: NodeFilter = .all
    @State private var showDetails = false

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
        }
    }

    private var stats: GPUFleetStats {
        GPUFleetStats(nodes: gpuNodes)
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
                    Picker("", selection: $filter) {
                        ForEach(NodeFilter.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 390)
                    DetailsToggleButton(showDetails: $showDetails)
                }
            }

            gpuOverview

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if shouldShow(.gpu) {
                        NodeSection(
                            title: "GPU training nodes",
                            subtitle: "\(gpuNodes.count) L40S nodes • \(stats.idle) free GPUs",
                            nodes: gpuNodes,
                            jobs: jobs,
                            style: .gpu
                        )
                    }
                    if shouldShow(.cpu) {
                        NodeSection(
                            title: "CPU nodes",
                            subtitle: "\(cpuNodes.count) general-purpose compute nodes",
                            nodes: cpuNodes,
                            jobs: jobs,
                            style: .cpu
                        )
                    }
                    if shouldShow(.himem) {
                        NodeSection(
                            title: "High-memory nodes",
                            subtitle: "\(himemNodes.count) large-memory CPU nodes",
                            nodes: himemNodes,
                            jobs: jobs,
                            style: .himem
                        )
                    }
                    if shouldShow(.teaching) {
                        NodeSection(
                            title: "Teaching nodes",
                            subtitle: "\(teachingNodes.count) teaching partition nodes",
                            nodes: teachingNodes,
                            jobs: jobs,
                            style: .teaching
                        )
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 360, maxHeight: 560)

            if showDetails {
                SectionHeader(title: "Node details", subtitle: "\(visibleNodes.count) rows")
                NodesTable(nodes: visibleNodes)
                    .frame(minHeight: 240)
            }
        }
    }

    private var gpuOverview: some View {
        GPUFleetPanel(stats: stats, nodes: gpuNodes)
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
                HStack(spacing: 8) {
                    InfoChip(label: "Free", value: "\(stats.idle)", systemImage: "checkmark.circle.fill", color: .green)
                    InfoChip(label: "Mixed", value: "\(stats.mixedNodes)", systemImage: "circle.lefthalf.filled", color: .orange)
                    InfoChip(label: "Unavailable", value: "\(stats.unavailableNodes)", systemImage: "exclamationmark.triangle.fill", color: .red)
                }
            }

            Divider()
                .frame(height: 120)

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Node heatmap", subtitle: "\(nodes.count) GPU nodes")
                GPUNodeHeatmap(nodes: nodes)
            }
            .frame(width: 310)
        }
        .dashboardCard(padding: 14)
    }
}

struct GPUNodeHeatmap: View {
    let nodes: [NodeSummary]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 20, maximum: 24), spacing: 5)], spacing: 5) {
            ForEach(nodes) { node in
                RoundedRectangle(cornerRadius: 4)
                    .fill(color(for: node))
                    .frame(height: 18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .help("\(node.node): \(gpuAllocated(node))/\(gpuTotal(node)) GPU, \(node.state)")
            }
        }
    }

    private func color(for node: NodeSummary) -> Color {
        if !isAvailable(node) {
            return .red.opacity(0.65)
        }
        let total = max(gpuTotal(node), 1)
        let ratio = Double(gpuAllocated(node)) / Double(total)
        if ratio >= 1 {
            return statsHighColor
        }
        if ratio > 0 {
            return .orange.opacity(0.85)
        }
        return .green.opacity(0.78)
    }

    private var statsHighColor: Color {
        AIRETheme.gpu.opacity(0.85)
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
            }
            .frame(height: 10)

            HStack {
                Label("\(stats.allocated) allocated", systemImage: "circle.fill")
                    .foregroundStyle(stats.utilizationColor)
                Spacer()
                Label("\(stats.idle) free", systemImage: "circle.fill")
                    .foregroundStyle(.green)
            }
            .font(.caption)
        }
    }
}

enum NodeVisualStyle {
    case gpu
    case cpu
    case himem
    case teaching
}

struct NodeSection: View {
    let title: String
    let subtitle: String
    let nodes: [NodeSummary]
    let jobs: [Job]
    let style: NodeVisualStyle

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
                        if style == .gpu {
                            GPUNodeCard(node: node, hasUserJob: hasUserJob(on: node))
                        } else {
                            GeneralNodeCard(node: node, style: style, hasUserJob: hasUserJob(on: node))
                        }
                    }
                }
            }
        }
    }

    private var cardWidth: CGFloat {
        style == .gpu ? 205 : 190
    }

    private func hasUserJob(on node: NodeSummary) -> Bool {
        jobs.contains { $0.reasonOrNodeList.contains(node.node) }
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
                    .tint(cpuRatio > 0.85 ? .orange : .blue)
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
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(hasUserJob ? Color.purple.opacity(0.55) : AIRETheme.border, lineWidth: hasUserJob ? 1.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: Color.black.opacity(0.035), radius: 6, x: 0, y: 2)
    }

    private var cardBackground: Color {
        if !isAvailable(node) {
            return Color.gray.opacity(0.12)
        }
        if gpuIdle(node) > 0 {
            return Color(nsColor: .controlBackgroundColor)
        }
        return Color.blue.opacity(0.08)
    }

    private func gpuSlotColor(index: Int) -> Color {
        if !isAvailable(node) {
            return .gray.opacity(0.35)
        }
        if index < allocated {
            return .blue
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
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(hasUserJob ? Color.purple.opacity(0.55) : AIRETheme.border, lineWidth: hasUserJob ? 1.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: Color.black.opacity(0.035), radius: 6, x: 0, y: 2)
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
        }
    }

    private var cardBackground: Color {
        if !isAvailable(node) {
            return Color.gray.opacity(0.12)
        }
        return accentColor.opacity(0.08)
    }

    private var memoryText: String {
        guard let allocated = node.memoryAllocatedMB, let total = node.memoryMB else {
            return ""
        }
        return "\(allocated / 1024)/\(total / 1024)G"
    }
}

struct RingMeter: View {
    let value: Double
    let color: Color
    let label: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.10), lineWidth: 9)
            Circle()
                .trim(from: 0, to: min(max(value, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text("\(Int((value * 100).rounded()))%")
                    .font(.headline.monospacedDigit())
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct StatePill: View {
    let state: String

    var body: some View {
        Text(state.uppercased())
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(stateColor.opacity(0.14))
            .foregroundStyle(stateColor)
            .clipShape(Capsule())
    }

    private var stateColor: Color {
        let value = state.lowercased()
        if value.contains("maint") || value.contains("down") || value.contains("drain") {
            return .red
        }
        if value.contains("mix") {
            return .orange
        }
        if value.contains("alloc") {
            return .blue
        }
        if value.contains("idle") {
            return .green
        }
        return .secondary
    }
}

private func number(_ value: Int?) -> String {
    value.map(String.init) ?? ""
}

private func gpuPercent(_ point: TrendPoint) -> Double {
    guard point.gpuTotal > 0 else {
        return 0
    }
    return Double(point.gpuAllocated) / Double(point.gpuTotal) * 100
}

private func percentText(_ value: Double?) -> String {
    guard let value else {
        return "n/a"
    }
    return "\(Int(value.rounded()))%"
}

private func formatGB(_ value: Double?) -> String {
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

private func cpuText(_ node: NodeSummary) -> String {
    let allocated = number(node.cpuAllocated)
    let total = number(node.cpuTotal)
    if allocated.isEmpty || total.isEmpty {
        return ""
    }
    return "\(allocated)/\(total)"
}

private func gpuText(_ node: NodeSummary) -> String {
    let total = gpuTotal(node)
    guard total > 0 else {
        return ""
    }
    return "\(gpuAllocated(node))/\(total)"
}

private func gpuTotal(_ node: NodeSummary) -> Int {
    if let total = node.gpuTotal {
        return total
    }
    return parseGPUTotal(from: node.gres)
}

private func gpuAllocated(_ node: NodeSummary) -> Int {
    node.gpuAllocated ?? 0
}

private func gpuIdle(_ node: NodeSummary) -> Int {
    if let idle = node.gpuIdle {
        return idle
    }
    return max(gpuTotal(node) - gpuAllocated(node), 0)
}

private func parseGPUTotal(from gres: String) -> Int {
    guard gres.lowercased().contains("gpu") else {
        return 0
    }
    let pieces = gres.split(separator: ":")
    guard let last = pieces.last else {
        return 0
    }
    return Int(last) ?? 0
}

private func isAvailable(_ node: NodeSummary) -> Bool {
    let state = node.state.lowercased()
    return !state.contains("maint")
        && !state.contains("down")
        && !state.contains("drain")
        && !state.contains("fail")
}

private func colorForState(_ state: String) -> Color {
    let value = state.lowercased()
    if value.contains("maint") || value.contains("down") || value.contains("drain") || value.contains("fail") {
        return .red
    }
    if value.contains("mix") {
        return .orange
    }
    if value.contains("alloc") {
        return .blue
    }
    if value.contains("idle") {
        return .green
    }
    if value.contains("up") {
        return .green
    }
    return .secondary
}

private func partitionAccent(name: String, gres: String) -> Color {
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

private func partitionSortKey(_ name: String) -> String {
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
