import SwiftUI

struct JobsDashboard: View {
    let jobs: [Job]
    // Hoisted into DashboardView so both survive tab switches.
    @Binding var showDetails: Bool
    @Binding var selectedJob: Job?
    /// Wired by DashboardView: switches to the terminal tab and tails stdout.
    var onTailOutput: (@MainActor (Job) -> Void)? = nil
    /// Wired by DashboardView: runs `scancel` remotely, throwing on failure.
    var onCancelJob: (@MainActor (Job) async throws -> Void)? = nil
    /// Wired by DashboardView: closes the sheet, switches to the Files tab,
    /// and opens the job's working directory.
    var onBrowseWorkDir: (@MainActor (Job) -> Void)? = nil

    private var runningJobs: [Job] {
        jobs.filter { SlurmState(parsing: $0.state) == .running }
    }

    private var pendingJobs: [Job] {
        jobs.filter { SlurmState(parsing: $0.state) == .pending }
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
                    .transition(.opacity.combined(with: .move(edge: .top)))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 10)], spacing: 10) {
                    ForEach(jobs) { job in
                        JobCard(job: job) {
                            selectedJob = job
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            if showDetails {
                SectionHeader(title: "Job details", subtitle: "\(jobs.count) rows")
                JobsTable(jobs: jobs)
                    .frame(height: 300)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(AIRETheme.smoothEase, value: showDetails)
        .sheet(item: $selectedJob) { job in
            JobDetailView(
                job: job,
                onTailOutput: onTailOutput,
                onCancelJob: onCancelJob,
                onBrowseWorkDir: onBrowseWorkDir
            )
        }
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

struct JobPulsePanel: View {
    let jobs: [Job]

    private var runningCount: Int {
        jobs.filter { SlurmState(parsing: $0.state) == .running }.count
    }

    private var pendingCount: Int {
        jobs.filter { SlurmState(parsing: $0.state) == .pending }.count
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
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(AIRETheme.border, lineWidth: 1)
                        )
                    }
                }
            }
            .frame(maxWidth: 330)
        }
        .dashboardCard(accent: .blue)
    }
}

struct JobCard: View {
    let job: Job
    var onSelect: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        Button {
            onSelect?()
        } label: {
            cardContent
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            // Visual hover state only: pushing NSCursor here leaks a stuck
            // pointing hand when the hovered card is removed by a refresh,
            // because SwiftUI never delivers the terminal onHover(false).
            isHovered = hovering
        }
        .animation(AIRETheme.softSpring, value: isHovered)
        .animation(AIRETheme.smoothEase, value: job.state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Job \(job.name), \(job.jobId)")
        .accessibilityValue("\(SlurmState(parsing: job.state).label), partition \(job.partition), elapsed \(job.elapsed)")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens job details")
    }

    private var cardContent: some View {
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
                    .background(accentColor.opacity(0.10), in: Capsule())
                    .overlay(Capsule().stroke(accentColor.opacity(0.18), lineWidth: 1))
                    .clipShape(Capsule())
                Label("\(job.nodes) node\(job.nodes == "1" ? "" : "s")", systemImage: "server.rack")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(AIRETheme.border, lineWidth: 1))
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
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(accentColor.opacity(cardTintOpacity))
                }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(accentColor.opacity(isHovered ? 0.34 : 0.22), lineWidth: 1)
        )
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accentColor.opacity(0.70))
                .frame(height: isHovered ? 4 : 3)
                .padding(.horizontal, 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: Color.black.opacity(isHovered ? 0.10 : 0.04), radius: isHovered ? 12 : 6, x: 0, y: isHovered ? 6 : 2)
        .scaleEffect(isHovered ? 1.01 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var isGPU: Bool {
        job.partition.lowercased().contains("gpu")
    }

    /// One state-derived accent shared by the icon, tint, border, and top rail.
    private var accentColor: Color {
        switch SlurmState(parsing: job.state) {
        case .running:
            return isGPU ? AIRETheme.gpu : .green
        case .pending:
            return .orange
        case .unavailable:
            return .red
        default:
            return .secondary
        }
    }

    private var cardTintOpacity: Double {
        isHovered ? 0.11 : 0.08
    }
}

struct JobDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let job: Job
    var onTailOutput: (@MainActor (Job) -> Void)? = nil
    var onCancelJob: (@MainActor (Job) async throws -> Void)? = nil
    var onBrowseWorkDir: (@MainActor (Job) -> Void)? = nil

    @State private var showCancelConfirmation = false
    @State private var isCancelling = false
    @State private var cancelStatus: String?
    @State private var cancelFailed = false

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
                .keyboardShortcut(.cancelAction)
                .disabled(isCancelling)
                .accessibilityLabel("Close job details")
            }

            HStack(spacing: 12) {
                DetailMetric(title: "Elapsed", value: job.elapsed, systemImage: "timer", accent: .blue)
                DetailMetric(title: "Limit", value: job.timeLimit, systemImage: "hourglass", accent: .purple)
                DetailMetric(title: "Nodes", value: job.nodes, systemImage: "server.rack", accent: .teal)
                DetailMetric(title: "CPUs", value: number(job.numCpus), systemImage: "cpu", accent: .orange)
            }

            actionsRow

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
        .background(DashboardBackdrop())
        .frame(
            minWidth: 620,
            idealWidth: 720,
            maxWidth: .infinity,
            minHeight: 480,
            idealHeight: 620,
            maxHeight: .infinity
        )
        // Keep the sheet up while scancel is in flight (at most the 30s
        // command timeout) so its outcome is never silently swallowed.
        .interactiveDismissDisabled(isCancelling)
    }

    /// Terminal-backed actions: tail the job's stdout, or scancel it after a
    /// confirmation. Status of the last cancel attempt shows inline.
    private var actionsRow: some View {
        HStack(spacing: 10) {
            Button {
                onTailOutput?(job)
            } label: {
                Label("Tail output", systemImage: "text.alignleft")
            }
            .buttonStyle(.bordered)
            .disabled(onTailOutput == nil || (job.stdoutPath ?? "").isEmpty || isPending)
            .help(tailHelp)

            Button {
                // The callback closes this sheet (clearing selectedJob),
                // switches to the Files tab, and navigates to the workdir.
                onBrowseWorkDir?(job)
            } label: {
                Label("Browse workdir", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .disabled(onBrowseWorkDir == nil || (job.workDir ?? "").isEmpty)
            .help(
                (job.workDir ?? "").isEmpty
                    ? "This job has no working directory"
                    : "Open \(job.workDir ?? "") in the Files tab"
            )

            Button(role: .destructive) {
                showCancelConfirmation = true
            } label: {
                Label(isCancelling ? "Cancelling…" : "Cancel job", systemImage: "xmark.octagon")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(onCancelJob == nil || isCancelling)
            .help("Run scancel \(job.jobId) on AIRE")

            if isCancelling {
                ProgressView()
                    .controlSize(.small)
            }

            if let cancelStatus {
                Text(cancelStatus)
                    .font(.caption)
                    .foregroundStyle(cancelFailed ? Color.red : Color.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .transition(.opacity)
            }

            Spacer(minLength: 0)
        }
        .animation(AIRETheme.smoothEase, value: cancelStatus)
        .alert("Cancel job \(job.jobId)?", isPresented: $showCancelConfirmation) {
            Button("Keep job", role: .cancel) {}
            Button("Cancel job", role: .destructive) {
                performCancel()
            }
        } message: {
            Text("Cancel job \(job.jobId) \(job.name)? This runs scancel on AIRE.")
        }
    }

    private func performCancel() {
        guard let onCancelJob, !isCancelling else {
            return
        }
        isCancelling = true
        cancelStatus = nil
        cancelFailed = false
        Task { @MainActor in
            do {
                try await onCancelJob(job)
                cancelStatus = "scancel sent — the job list refreshes shortly"
                cancelFailed = false
            } catch {
                cancelStatus = error.localizedDescription
                cancelFailed = true
            }
            isCancelling = false
        }
    }

    private var isGPU: Bool {
        job.partition.lowercased().contains("gpu")
    }

    /// Slurm resolves the stdout path at submit time, but slurmstepd only
    /// creates the file once the job starts — tailing a pending job would
    /// just watch a path that does not exist yet.
    private var isPending: Bool {
        SlurmState(parsing: job.state) == .pending
    }

    private var tailHelp: String {
        if (job.stdoutPath ?? "").isEmpty {
            return "This job has no stdout path"
        }
        if isPending {
            return "Output file is created when the job starts"
        }
        return "Follow the job's stdout in the Terminal tab"
    }

    private var accentColor: Color {
        switch SlurmState(parsing: job.state) {
        case .running:
            return isGPU ? AIRETheme.gpu : .green
        case .pending:
            return .orange
        case .unavailable:
            return .red
        default:
            return .secondary
        }
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
            Text(value.isEmpty ? missingValuePlaceholder : value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard(accent: accent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value.isEmpty ? "not available" : value)
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
        .dashboardCard(accent: AIRETheme.gpu)
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
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var displayValue: String {
        guard let value, !value.isEmpty else {
            return missingValuePlaceholder
        }
        return value
    }
}
