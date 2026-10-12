import SwiftUI

/// One cluster's Jobs tab. Everything here is scoped to `profile`: Slurm job
/// ids are only unique within one cluster, so the cards, the table and the
/// cancel action must never mix or mislabel clusters.
struct JobsDashboard: View {
    let profile: ClusterProfile
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
        jobs.filter { $0.isGPUJob(on: profile) }
    }

    /// GPUs held or requested by this user's jobs. Safe to sum: a dashboard
    /// covers one cluster, and each cluster has a single GPU pool.
    private var requestedGPUCount: Int {
        gpuJobs.reduce(0) { $0 + ($1.gpuRequest?.count ?? 0) }
    }

    private var gpuJobsSubtitle: String {
        let count = requestedGPUCount
        guard count > 0 else {
            return "training or inference"
        }
        return count == 1 ? "1 GPU requested" : "\(count) GPUs requested"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(
                title: "Job Activity",
                subtitle: "Your current Slurm workload on \(profile.displayName)",
                systemImage: "waveform.path.ecg.rectangle",
                accent: .blue
            ) {
                DetailsToggleButton(showDetails: $showDetails)
            }

            HStack(spacing: 12) {
                MetricView(title: "Running", value: "\(runningJobs.count)", subtitle: "active jobs", systemImage: "play.fill", accent: .green)
                MetricView(title: "Pending", value: "\(pendingJobs.count)", subtitle: "waiting", systemImage: "clock.fill", accent: .orange)
                MetricView(title: "GPU Jobs", value: "\(gpuJobs.count)", subtitle: gpuJobsSubtitle, systemImage: "memorychip", accent: AppTheme.gpu)
                MetricView(title: "Total", value: "\(jobs.count)", subtitle: "visible jobs", systemImage: "sum", accent: .purple)
            }

            if jobs.isEmpty {
                EmptyVisual(
                    title: "No jobs in the queue",
                    subtitle: "Jobs you submit on \(profile.displayName) will appear here after the next refresh.",
                    systemImage: "checkmark.circle"
                )
            } else {
                JobPulsePanel(profile: profile, jobs: jobs)
                    .transition(.opacity.combined(with: .move(edge: .top)))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 10)], spacing: 10) {
                    ForEach(jobs) { job in
                        JobCard(profile: profile, job: job) {
                            selectedJob = job
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            if showDetails {
                SectionHeader(title: "Job details", subtitle: "\(jobs.count) rows")
                JobsTable(profile: profile, jobs: jobs)
                    .frame(height: 300)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(AppTheme.smoothEase, value: showDetails)
        .sheet(item: $selectedJob) { job in
            JobDetailView(
                profile: profile,
                job: job,
                onTailOutput: onTailOutput,
                onCancelJob: onCancelJob,
                onBrowseWorkDir: onBrowseWorkDir
            )
        }
    }
}

struct JobsTable: View {
    let profile: ClusterProfile
    let jobs: [Job]

    var body: some View {
        // Row identity is the bare job id, which is only unique because this
        // table always shows a single cluster's jobs.
        Table(jobs) {
            TableColumn("Job ID", value: \.jobId)
            TableColumn("Partition", value: \.partition)
            TableColumn("Name", value: \.name)
            TableColumn("GPUs") { job in
                Text(gpuText(for: job))
                    .monospacedDigit()
                    .foregroundStyle(job.isGPUJob(on: profile) ? AppTheme.gpu : Color.secondary)
            }
            TableColumn("State", value: \.state)
            TableColumn("Elapsed", value: \.elapsed)
            TableColumn("Limit", value: \.timeLimit)
            TableColumn("Nodes", value: \.nodes)
            TableColumn("Reason / Node", value: \.reasonOrNodeList)
        }
    }

    /// GPU count and model when the TRES strings say; "GPU" for a job that is
    /// only known to be a GPU job from its partition.
    private func gpuText(for job: Job) -> String {
        if let request = job.gpuRequest {
            return request.summary
        }
        return job.isGPUJob(on: profile) ? "GPU" : missingValuePlaceholder
    }
}

struct JobPulsePanel: View {
    let profile: ClusterProfile
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

    /// Partitions ranked by job count. A partition reads as GPU when any of
    /// its jobs is a GPU job, so the mix agrees with the cards and the GPU
    /// tile; other partitions take their role icon from the profile.
    private var topPartitions: [(name: String, count: Int, isGPU: Bool)] {
        Dictionary(grouping: jobs, by: \.partition)
            .map { entry in
                (
                    name: entry.key,
                    count: entry.value.count,
                    isGPU: entry.value.contains { $0.isGPUJob(on: profile) }
                )
            }
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
                            Image(systemName: partitionIcon(name: item.name, isGPU: item.isGPU))
                                .foregroundStyle(item.isGPU ? AppTheme.gpu : AppTheme.cpu)
                                .accessibilityHidden(true)
                            Text(item.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
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
                                .stroke(AppTheme.border, lineWidth: 1)
                        )
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Partition \(item.name)\(item.isGPU ? ", GPU" : "")")
                        .accessibilityValue("\(item.count) job\(item.count == 1 ? "" : "s")")
                    }
                }
            }
            .frame(maxWidth: 330)
        }
        .dashboardCard(accent: .blue)
    }

    private func partitionIcon(name: String, isGPU: Bool) -> String {
        if isGPU {
            return PartitionRole.gpu.systemImage
        }
        // A pending job may list several candidate partitions ("a,b"); the
        // profile only knows single names, so unknown combos read as CPU.
        return profile.role(forPartition: name)?.systemImage ?? PartitionRole.cpu.systemImage
    }
}

struct JobCard: View {
    let profile: ClusterProfile
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
        .animation(AppTheme.softSpring, value: isHovered)
        .animation(AppTheme.smoothEase, value: job.state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Job \(job.name), \(job.jobId)")
        .accessibilityValue(accessibilitySummary)
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
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(accentColor.opacity(0.10), in: Capsule())
                    .overlay(Capsule().stroke(accentColor.opacity(0.18), lineWidth: 1))
                    .clipShape(Capsule())
                Label("\(job.nodes) node\(job.nodes == "1" ? "" : "s")", systemImage: "server.rack")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(AppTheme.border, lineWidth: 1))
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
                if let gpuRequest = job.gpuRequest {
                    HStack {
                        Text("GPUs")
                        Spacer()
                        Text(gpuRequest.summary)
                            .monospacedDigit()
                            .foregroundStyle(AppTheme.gpu)
                    }
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
        // GPU jobs carry an extra "GPUs" row; filling the grid row keeps
        // CPU-job cards beside them the same height instead of centred.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        job.isGPUJob(on: profile)
    }

    private var accessibilitySummary: String {
        var parts = [
            SlurmState(parsing: job.state).label,
            "partition \(job.partition)",
            "elapsed \(job.elapsed)"
        ]
        if let gpuRequest = job.gpuRequest {
            parts.append(gpuRequest.summary)
        }
        return parts.joined(separator: ", ")
    }

    /// One state-derived accent shared by the icon, tint, border, and top rail.
    private var accentColor: Color {
        switch SlurmState(parsing: job.state) {
        case .running:
            return isGPU ? AppTheme.gpu : .green
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
    /// The cluster the job lives on. Named on every remote action because the
    /// same job id can exist on another cluster as a different job.
    let profile: ClusterProfile
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
                    HStack(spacing: 6) {
                        ClusterBadge(profile: profile, size: 16)
                        Text("\(profile.displayName) • \(job.jobId) • \(job.partition)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
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
                if let gpuRequest = job.gpuRequest {
                    DetailMetric(title: "GPUs", value: gpuRequest.summary, systemImage: "memorychip", accent: AppTheme.gpu)
                }
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
            .help("Run scancel \(job.jobId) on \(profile.displayName)")
            .accessibilityHint("Cancels this job on \(profile.displayName) after confirmation")

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
        .animation(AppTheme.smoothEase, value: cancelStatus)
        .alert("Cancel \(profile.displayName) job \(job.jobId)?", isPresented: $showCancelConfirmation) {
            Button("Keep job", role: .cancel) {}
            Button("Cancel job", role: .destructive) {
                performCancel()
            }
        } message: {
            Text("Cancel job \(job.jobId) \(job.name)? This runs scancel on \(profile.displayName) only.")
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
                cancelStatus = "scancel sent to \(profile.displayName) — the job list refreshes shortly"
                cancelFailed = false
            } catch {
                cancelStatus = error.localizedDescription
                cancelFailed = true
            }
            isCancelling = false
        }
    }

    private var isGPU: Bool {
        job.isGPUJob(on: profile)
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
            return isGPU ? AppTheme.gpu : .green
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
                    .foregroundStyle(AppTheme.gpu)
                Text(title)
                    .font(.headline.weight(.semibold))
            }
            content
        }
        .dashboardCard(accent: AppTheme.gpu)
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

// MARK: - GPU job detection

/// GPUs a job holds or asked for, read from its Slurm TRES strings.
struct JobGPURequest: Equatable {
    /// GPUs for the whole job; nil when Slurm names GPUs without a count.
    let count: Int?
    /// Raw gres type, e.g. "nvidia_h200" or "l40s"; nil for an untyped
    /// request such as `--gres=gpu:2`.
    let model: String?

    var modelDisplayName: String? {
        model.map(gpuModelDisplayName)
    }

    /// "2 × H200", "1 GPU", "H200 GPU", or just "GPU".
    var summary: String {
        switch (count, modelDisplayName) {
        case let (count?, model?):
            return "\(count) × \(model)"
        case let (count?, nil):
            return count == 1 ? "1 GPU" : "\(count) GPUs"
        case let (nil, model?):
            return "\(model) GPU"
        case (nil, nil):
            return "GPU"
        }
    }
}

extension Job {
    /// The job's GPUs, or nil when none of its TRES strings mention gres/gpu.
    ///
    /// Whole-job totals win: AllocTRES is what Slurm actually granted (a
    /// running job), ReqTRES what a pending job asked for. TresPerNode is per
    /// node, so it is only a fallback and is scaled by the node count.
    var gpuRequest: JobGPURequest? {
        let allocated = TRESGPUTally(allocTres)
        let requested = TRESGPUTally(reqTres)
        let perNode = TRESGPUTally(tresPerNode)
        guard allocated.mentionsGPU || requested.mentionsGPU || perNode.mentionsGPU else {
            return nil
        }
        let nodeCount = max(Int(nodes.trimmingCharacters(in: .whitespaces)) ?? 1, 1)
        let count = allocated.count ?? requested.count ?? perNode.count.map { $0 * nodeCount }
        // An explicit zero ("gres/gpu=0") is a CPU job that merely names the gres.
        if count == 0 {
            return nil
        }
        return JobGPURequest(count: count, model: allocated.model ?? requested.model ?? perNode.model)
    }

    /// Single source of truth for "is this a GPU job" on the Jobs tab.
    ///
    /// The TRES strings are authoritative and cluster-neutral. Without them
    /// (older caches, or a job squeue reported without details) the cluster
    /// profile's partition roles decide, and only partitions the profile does
    /// not know fall back to the historical "name contains gpu" heuristic —
    /// which still catches AIRE's `gpu` and Calder's `calder-gpu-hopper`.
    func isGPUJob(on profile: ClusterProfile) -> Bool {
        if gpuRequest != nil {
            return true
        }
        // A pending job may list several candidate partitions ("gpu,nodes").
        let candidates = partition
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return candidates.contains { name in
            if let role = profile.role(forPartition: name) {
                return role == .gpu
            }
            return name.lowercased().contains("gpu")
        }
    }
}

/// GPU entries found in one Slurm TRES string. Understands both shapes Slurm
/// prints:
/// - TRES lists (`ReqTRES`/`AllocTRES`): `cpu=8,gres/gpu=2,gres/gpu:nvidia_h200=2`
/// - per-node GRES (`TresPerNode`): `gres/gpu:nvidia_h200:2` (23.02+),
///   `gres:gpu:2` (21.08–22.05), or a bare `gpu:l40s:1` (older releases).
private struct TRESGPUTally {
    private(set) var mentionsGPU = false
    private(set) var model: String?
    private var untypedCount: Int?
    private var typedCount: Int?

    /// Slurm lists both the untyped total and the per-type split
    /// (`gres/gpu=2,gres/gpu:nvidia_h200=2`); the untyped total wins so the
    /// GPUs are not counted twice.
    var count: Int? {
        untypedCount ?? typedCount
    }

    init(_ raw: String?) {
        guard let raw else {
            return
        }
        for rawEntry in Self.entries(of: raw) {
            var entry = rawEntry.trimmingCharacters(in: .whitespaces).lowercased()
            // Drop index suffixes such as "(IDX:0-1)".
            if let paren = entry.firstIndex(of: "(") {
                entry = String(entry[..<paren])
            }
            var key = entry
            var valueText: Substring?
            if let equals = entry.firstIndex(of: "=") {
                key = String(entry[..<equals])
                valueText = entry[entry.index(after: equals)...]
            }
            for prefix in ["gres/", "gres:"] where key.hasPrefix(prefix) {
                key = String(key.dropFirst(prefix.count))
                break
            }
            var pieces = key.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            // "gpumem"/"gpuutil" style TRES are not GPU counts.
            guard pieces.first == "gpu" else {
                continue
            }
            pieces.removeFirst()

            var entryCount: Int?
            if let valueText {
                entryCount = Int(valueText.prefix { $0.isNumber })
            } else if let last = pieces.last, let parsed = Int(last) {
                entryCount = parsed
                pieces.removeLast()
            }
            let entryModel = pieces.first { !$0.isEmpty }

            mentionsGPU = true
            if let entryModel {
                model = model ?? entryModel
                if let entryCount {
                    typedCount = (typedCount ?? 0) + entryCount
                }
            } else if let entryCount {
                untypedCount = (untypedCount ?? 0) + entryCount
            }
        }
    }

    /// Splits on commas that are not inside parentheses, so an index list
    /// like "(IDX:0,2)" stays attached to its entry.
    private static func entries(of raw: String) -> [Substring] {
        var result: [Substring] = []
        var depth = 0
        var start = raw.startIndex
        for index in raw.indices {
            switch raw[index] {
            case "(":
                depth += 1
            case ")":
                depth = max(depth - 1, 0)
            case "," where depth == 0:
                result.append(raw[start..<index])
                start = raw.index(after: index)
            default:
                break
            }
        }
        result.append(raw[start...])
        return result
    }
}
