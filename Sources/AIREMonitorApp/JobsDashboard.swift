import HPCCore
import SwiftUI

/// One cluster's Jobs tab. Everything here is scoped to `profile`: Slurm job
/// ids are only unique within one cluster, so the cards, the table and the
/// cancel action must never mix or mislabel clusters.
struct JobsDashboard: View {
    let profile: ClusterProfile
    let jobs: [Job]
    // Hoisted into DashboardView so both survive tab switches.
    @Binding var showDetails: Bool
    /// The job whose sheet is open. A copy taken when the sheet opened; the
    /// sheet itself always shows the CURRENT snapshot's version of that job
    /// (looked up by id), and this copy is only the fallback once the job
    /// has left the queue.
    @Binding var selectedJob: Job?
    /// Wired by DashboardView: switches to the terminal tab and tails stdout.
    var onTailOutput: (@MainActor (Job) -> Void)? = nil
    /// Wired by DashboardView: runs `scancel` remotely, throwing on failure.
    var onCancelJob: (@MainActor (Job) async throws -> Void)? = nil
    /// Wired by DashboardView: closes the sheet, switches to the Files tab,
    /// and opens the job's working directory.
    var onBrowseWorkDir: (@MainActor (Job) -> Void)? = nil
    /// What running jobs use on their nodes (`ClusterSession.jobUsage`),
    /// with the recent trend, and the "Sample" switch.
    var usage: [String: JobUsageSummary] = [:]
    var usageHistory = JobUsageHistory()
    var isSamplingUsage: Binding<Bool> = .constant(false)

    /// When the selected job was last present in a snapshot, for the
    /// "no longer in the queue" banner.
    @State private var selectedLastSeen: (id: String, at: Date)?

    var body: some View {
        // Parsed once per render: state, GPU request and GPU classification
        // are read many times by the cards, the table and the metrics.
        let rows = JobRow.rows(for: jobs, profile: profile)
        let summary = JobQueueSummary(rows: rows)

        VStack(alignment: .leading, spacing: 14) {
            PageHeader(
                title: "Job Activity",
                subtitle: "Your Slurm jobs on \(profile.displayName)",
                systemImage: "waveform.path.ecg.rectangle",
                accent: .blue
            ) {
                DetailsToggleButton(showDetails: $showDetails)
            }

            HStack(alignment: .top, spacing: 12) {
                MetricView(title: "Running", value: "\(summary.running)", subtitle: summary.runningSubtitle, systemImage: "play.fill", accent: .green)
                MetricView(title: "Pending", value: "\(summary.pending)", subtitle: summary.pendingSubtitle, systemImage: "clock.fill", accent: .orange, help: summary.pendingHelp)
                MetricView(title: "GPU jobs", value: "\(summary.gpuJobs)", subtitle: summary.gpuSubtitle, systemImage: "memorychip", accent: AppTheme.gpu)
                MetricView(title: "Total", value: "\(summary.total)", subtitle: summary.totalSubtitle, systemImage: "sum", accent: .purple)
            }

            if rows.isEmpty {
                EmptyVisual(
                    title: "No jobs in the queue",
                    subtitle: "Jobs you submit on \(profile.displayName) will appear here after the next refresh.",
                    systemImage: "checkmark.circle"
                )
            } else {
                if summary.running > 0 {
                    JobUsagePanel(
                        rows: rows,
                        usage: usage,
                        history: usageHistory,
                        isSampling: isSamplingUsage,
                        onSelect: { selectedJob = $0 }
                    )
                    .transition(.opacity)
                }

                JobPulsePanel(profile: profile, rows: rows, summary: summary)
                    .transition(.opacity.combined(with: .move(edge: .top)))

                // Running first, then waiting, then held: the order every
                // surface shares (HPCCore `jobDisplayOrder`), with headers so
                // a long pending queue never buries the running jobs.
                ForEach(JobGroup.allCases) { group in
                    let members = rows.filter { $0.group == group }
                    if !members.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: group.title, subtitle: group.countText(members))
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 10, alignment: .top)], spacing: 10) {
                                ForEach(members) { row in
                                    // The card is plain data (Equatable), so
                                    // SwiftUI skips unchanged cards; the action
                                    // lives on this wrapper, not in the card.
                                    Button {
                                        selectedJob = row.job
                                    } label: {
                                        JobCard(row: row)
                                            .equatable()
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel("Job \(row.job.name), \(row.job.displayJobID)")
                                    .accessibilityValue(row.accessibilitySummary)
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityHint("Opens job details")
                                }
                            }
                        }
                    }
                }
            }

            if showDetails {
                SectionHeader(title: "Job details", subtitle: pluralized(rows.count, "row"))
                JobsTable(rows: rows)
                    .frame(height: 300)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(AppTheme.smoothEase, value: showDetails)
        .sheet(item: $selectedJob) { selected in
            // Always the current snapshot's version of the job, so a job that
            // started or finished while the sheet is open is shown as such.
            let live = jobs.first { $0.jobId == selected.jobId }
            let job = live ?? selected
            JobDetailView(
                profile: profile,
                job: job,
                isGone: live == nil,
                lastSeen: selectedLastSeen?.id == selected.jobId ? selectedLastSeen?.at : nil,
                runningSiblings: Self.runningSiblings(of: job, in: jobs),
                usage: usage[job.jobId],
                usageSeries: usageHistory.series(for: job.jobId),
                isSamplingUsage: isSamplingUsage.wrappedValue,
                onTailOutput: onTailOutput,
                onCancelJob: onCancelJob,
                onBrowseWorkDir: onBrowseWorkDir
            )
        }
        .onAppear {
            noteSelectionSeen(in: jobs)
        }
        .onChange(of: selectedJob?.jobId) { _ in
            noteSelectionSeen(in: jobs)
        }
        .onChange(of: jobs) { newJobs in
            syncSelection(with: newJobs)
        }
    }

    /// Keeps the stored copy in step with the queue while the job is still
    /// listed (same id, so the sheet updates in place rather than
    /// re-presenting); once it vanishes the copy is the last-seen state.
    private func syncSelection(with newJobs: [Job]) {
        guard let selected = selectedJob else {
            return
        }
        if let live = newJobs.first(where: { $0.jobId == selected.jobId }) {
            if live != selected {
                selectedJob = live
            }
            selectedLastSeen = (selected.jobId, Date())
        }
    }

    private func noteSelectionSeen(in jobs: [Job]) {
        guard let selected = selectedJob, jobs.contains(where: { $0.jobId == selected.jobId }) else {
            return
        }
        selectedLastSeen = (selected.jobId, Date())
    }

    /// Running tasks of the same job array, named in the cancel dialog of
    /// the pending remainder so it is clear they keep running.
    nonisolated static func runningSiblings(of job: Job, in jobs: [Job]) -> [Job] {
        guard job.isArrayRemainder else {
            return []
        }
        let arrayID = job.arrayJobID.map(String.init) ?? job.jobId
        return jobs
            .filter { candidate in
                guard candidate.jobId != job.jobId, candidate.jobState.occupiesNodes else {
                    return false
                }
                if let candidateArray = candidate.arrayJobID {
                    return String(candidateArray) == arrayID
                }
                return candidate.jobId.hasPrefix("\(arrayID)_")
            }
            .sorted(by: jobDisplayOrder)
    }
}

// MARK: - Row model

/// Sections of the Jobs grid, in display order.
enum JobGroup: Int, CaseIterable, Identifiable {
    case running
    case waiting
    case held
    case other

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .running: return "Running"
        case .waiting: return "Waiting"
        case .held: return "Held"
        case .other: return "Other"
        }
    }

    /// "3 jobs", or "2 rows · 61 jobs" when array remainders stand for many.
    func countText(_ rows: [JobRow]) -> String {
        let jobs = rows.reduce(0) { $0 + $1.multiplicity }
        if jobs == rows.count {
            return pluralized(jobs, "job")
        }
        return "\(pluralized(rows.count, "row")) · \(pluralized(jobs, "job"))"
    }
}

/// One job prepared for display. Built once per render of the Jobs tab, so
/// cards and the table never re-parse TRES strings or states, and Equatable
/// so SwiftUI can skip cards whose job did not change.
struct JobRow: Identifiable, Equatable, Sendable {
    let job: Job
    let state: JobState
    let gpu: JobGPURequest?
    let isGPU: Bool
    let reason: SlurmPendingReason?

    var id: String { job.id }

    init(job: Job, profile: ClusterProfile) {
        self.job = job
        state = job.jobState
        gpu = job.gpuRequest
        isGPU = job.isGPUJob(on: profile, gpuRequest: gpu)
        reason = state.isPending ? SlurmPendingReason(job.reasonOrNodeList) : nil
    }

    /// Rows in the one display order every surface shares.
    static func rows(for jobs: [Job], profile: ClusterProfile) -> [JobRow] {
        jobs.sorted(by: jobDisplayOrder).map { JobRow(job: $0, profile: profile) }
    }

    var isHeld: Bool { reason?.isHeld ?? false }

    /// Jobs this row stands for: the queued task count of an array
    /// remainder, otherwise 1.
    var multiplicity: Int { job.taskMultiplicity }

    /// GPUs this row holds or asks for (per task × tasks for a remainder).
    var gpuCount: Int { (gpu?.count ?? 0) * multiplicity }

    var group: JobGroup {
        if state.occupiesNodes {
            return .running
        }
        if state.isPending {
            return isHeld ? .held : .waiting
        }
        return .other
    }

    /// Pill text and colour: Slurm's state, except that a held job reads
    /// "Held" in grey — it will not start however much capacity frees up,
    /// so it must not look like an ordinary queued job.
    var statusText: String {
        isHeld ? "Held" : state.label
    }

    var statusColor: Color {
        if isHeld {
            return .gray
        }
        return SlurmState(job: state).color
    }

    var statusHelp: String {
        if isHeld, let reason {
            return "\(job.state) — \(reason.explanation)"
        }
        return job.state
    }

    /// One state-derived accent shared by the icon, tint, border and rail.
    var accentColor: Color {
        if isHeld {
            return .gray
        }
        switch SlurmState(job: state) {
        case .running:
            return isGPU ? AppTheme.gpu : .green
        case .pending:
            return .orange
        case .failed:
            return StatusTone.critical.color
        case .suspended:
            return .yellow
        default:
            return .secondary
        }
    }

    /// Node list for jobs on nodes; nil for queued jobs, whose `%R` column
    /// is a reason, not a node list.
    var nodeListText: String? {
        if let list = job.nodeList, !list.isEmpty {
            return list
        }
        if state.occupiesNodes, !job.reasonOrNodeList.isEmpty {
            return job.reasonOrNodeList
        }
        return nil
    }

    /// "1 GPU", "2 × H200", or "1 × H200 per task" for an array remainder.
    var gpuText: String? {
        guard let gpu else {
            return isGPU ? "GPU" : nil
        }
        return job.isArrayRemainder ? "\(gpu.summary) per task" : gpu.summary
    }

    var accessibilitySummary: String {
        var parts = [statusText, "partition \(job.partition)"]
        if job.isArrayRemainder {
            parts.append(pluralized(multiplicity, "queued task"))
        }
        if state.occupiesNodes {
            parts.append("elapsed \(elapsedText(job.elapsed))")
        } else if let reason {
            parts.append(reason.explanation)
        }
        if let gpuText {
            parts.append(gpuText)
        }
        return parts.joined(separator: ", ")
    }
}

/// Queue totals for the metric row. Array remainders count as the tasks
/// they stand for, so 59 queued tasks never read as one pending job.
///
/// Pending never includes held jobs (HPCCore `JobQueueCounts`, which the
/// overview, sidebar and menu bar use): a held job will not start however
/// much capacity frees up, so it is counted and named on its own.
struct JobQueueSummary: Equatable {
    var running = 0
    /// Waiting for capacity, priority or a dependency; held jobs excluded.
    var pending = 0
    var held = 0
    var onDependency = 0
    var other = 0
    var total = 0
    var gpuJobs = 0
    var queuedArrayTasks = 0
    /// GPUs held or requested, per GPU model ("H200", or "" for untyped
    /// requests). Models are never added together.
    var gpusByModel: [String: Int] = [:]

    init(rows: [JobRow]) {
        for row in rows {
            let count = row.multiplicity
            total += count
            if row.job.isArrayRemainder {
                queuedArrayTasks += count
            }
            if row.state.occupiesNodes {
                running += count
            } else if row.state.isPending {
                if row.isHeld {
                    held += count
                } else {
                    pending += count
                    if row.reason?.isDependency == true {
                        onDependency += count
                    }
                }
            } else {
                other += count
            }
            if row.isGPU {
                gpuJobs += count
                if row.gpuCount > 0 {
                    gpusByModel[row.gpu?.modelDisplayName ?? "", default: 0] += row.gpuCount
                }
            }
        }
    }

    var runningSubtitle: String {
        other > 0 ? "\(other) suspended or ending" : "on nodes now"
    }

    /// "9 on dependency · +2 held": the dependency count is part of the
    /// pending figure; held jobs are not, hence the "+", so queued work that
    /// cannot start yet is told apart from jobs waiting for capacity
    /// without reading as a subset of pending.
    var pendingSubtitle: String {
        var parts: [String] = []
        if onDependency > 0 {
            parts.append("\(onDependency) on dependency")
        }
        if held > 0 {
            parts.append("+\(held) held")
        }
        return parts.isEmpty ? "waiting for a start" : parts.joined(separator: " · ")
    }

    /// The Pending tile's tooltip: what the figure counts and leaves out.
    var pendingHelp: String {
        var text = "\(pluralized(pending, "job")) waiting for resources, priority or a dependency"
        if held > 0 {
            text += "; \(pluralized(held, "held job")) on top, which will not start until released"
        }
        return text + "."
    }

    /// "8 GPUs requested", "6 × H200 + 2 × L40 requested".
    var gpuSubtitle: String {
        guard !gpusByModel.isEmpty else {
            return gpuJobs > 0 ? "GPU count not reported" : "none in the queue"
        }
        let parts = gpusByModel
            .sorted { lhs, rhs in lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key }
            .map { model, count in
                model.isEmpty ? pluralized(count, "GPU") : "\(count) × \(model)"
            }
        return parts.joined(separator: " + ") + " requested"
    }

    /// Short enough for a quarter of the narrowest detail column; the
    /// Pending tile beside it already says these tasks are queued.
    var totalSubtitle: String {
        queuedArrayTasks > 0 ? "incl. \(pluralized(queuedArrayTasks, "array task"))" : "in the queue"
    }
}

// MARK: - Table

struct JobsTable: View {
    let rows: [JobRow]

    var body: some View {
        // Row identity is the bare job id, which is only unique because this
        // table always shows a single cluster's jobs. Rows arrive in the
        // shared display order (running first).
        Table(rows) {
            TableColumn("Job ID") { row in
                Text(row.job.displayJobID)
                    .monospacedDigit()
                    .help(row.job.isArrayRemainder ? "\(pluralized(row.multiplicity, "queued task")) of array \(row.job.jobId)" : row.job.jobId)
            }
            TableColumn("Partition") { row in
                Text(row.job.partition)
            }
            TableColumn("Name") { row in
                Text(row.job.name)
            }
            TableColumn("GPUs") { row in
                Text(row.gpuText ?? missingValuePlaceholder)
                    .monospacedDigit()
                    .foregroundStyle(row.isGPU ? AppTheme.gpu : Color.secondary)
            }
            TableColumn("State") { row in
                Text(row.statusText)
                    .foregroundStyle(row.statusColor)
                    .help(row.statusHelp)
            }
            TableColumn("Elapsed") { row in
                Text(row.state.occupiesNodes ? elapsedText(row.job.elapsed) : missingValuePlaceholder)
                    .monospacedDigit()
                    .help(row.job.elapsed)
            }
            TableColumn("Limit") { row in
                Text(formatSlurmTimeLimit(row.job.timeLimit))
                    .monospacedDigit()
                    .help(row.job.timeLimit)
            }
            TableColumn("Nodes") { row in
                Text(row.job.nodes)
                    .monospacedDigit()
            }
            TableColumn("Reason / Nodes") { row in
                Text(row.reason?.explanation ?? row.nodeListText ?? missingValuePlaceholder)
                    .help(row.job.reasonOrNodeList)
            }
        }
    }
}

// MARK: - Queue mix

/// Proportions of the queue and where it runs. Counts live in the metric
/// row above; this panel only shows the shape (no repeated numbers).
struct JobPulsePanel: View {
    let profile: ClusterProfile
    let rows: [JobRow]
    let summary: JobQueueSummary

    private var stateSegments: [MeterSegment] {
        [
            MeterSegment(id: "Running", value: summary.running, color: .green),
            MeterSegment(id: "Waiting", value: summary.pending, color: .orange),
            MeterSegment(id: "Held", value: summary.held, color: .gray),
            MeterSegment(id: "Other", value: summary.other, color: .secondary.opacity(0.65))
        ]
    }

    /// Partitions ranked by job count (array tasks counted individually). A
    /// partition reads as GPU when any of its jobs is a GPU job, so the mix
    /// agrees with the cards and the GPU tile; other partitions take their
    /// role icon from the profile.
    private var topPartitions: [(name: String, count: Int, isGPU: Bool)] {
        Dictionary(grouping: rows, by: \.job.partition)
            .map { entry in
                (
                    name: entry.key,
                    count: entry.value.reduce(0) { $0 + $1.multiplicity },
                    isGPU: entry.value.contains { $0.isGPU }
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
        let partitions = topPartitions
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Queue mix", subtitle: "share of your \(pluralized(summary.total, "job"))")
                SegmentedMeter(segments: stateSegments, height: 14)
                    .accessibilityLabel("Queue mix")
                HStack(spacing: 12) {
                    ForEach(stateSegments.filter { $0.value > 0 }) { segment in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(segment.color)
                                .frame(width: 7, height: 7)
                            Text(segment.id)
                        }
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }

            Divider()
                .frame(height: 76)

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Partition mix", subtitle: pluralized(partitions.count, "queue"))
                VStack(spacing: 7) {
                    ForEach(Array(partitions.prefix(5)), id: \.name) { item in
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
                        .accessibilityValue(pluralized(item.count, "job"))
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

// MARK: - Card

/// A job card. Pure data — no closures — so it is Equatable and SwiftUI
/// skips it when its row is unchanged; the Jobs grid wraps it in the Button
/// that opens the sheet.
struct JobCard: View, Equatable {
    let row: JobRow
    @State private var isHovered = false

    nonisolated static func == (lhs: JobCard, rhs: JobCard) -> Bool {
        lhs.row == rhs.row
    }

    var body: some View {
        let accent = row.accentColor
        let job = row.job
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: row.isGPU ? "memorychip" : "terminal")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(accent)
                        // Middle truncation keeps the end of the name, which
                        // is what tells pipeline stages apart
                        // ("sweep-baseli…-fwd" / "…-score").
                        Text(job.name)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(job.name)
                    }
                    HStack(spacing: 4) {
                        Text(job.displayJobID)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if job.isArrayRemainder {
                            Text("· \(pluralized(row.multiplicity, "task"))")
                                .fixedSize()
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                Spacer()
                StatusCapsule(text: row.statusText, color: row.statusColor, help: row.statusHelp)
            }

            HStack(spacing: 12) {
                Label(job.partition, systemImage: row.isGPU ? "memorychip" : "cpu")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(accent.opacity(0.10), in: Capsule())
                    .overlay(Capsule().stroke(accent.opacity(0.18), lineWidth: 1))
                    .clipShape(Capsule())
                Label(nodesText, systemImage: "server.rack")
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(AppTheme.border, lineWidth: 1))
                    .clipShape(Capsule())
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                if row.state.occupiesNodes {
                    valueRow("Elapsed", elapsedText(job.elapsed), help: job.elapsed)
                } else if row.state.isPending {
                    // A queued job has no elapsed time; how long it has
                    // waited, or when backfill expects it to start, says more.
                    JobWaitRows(job: job)
                }
                valueRow("Limit", formatSlurmTimeLimit(job.timeLimit), help: job.timeLimit)
                if let gpuText = row.gpuText {
                    HStack {
                        Text("GPUs")
                        Spacer()
                        Text(gpuText)
                            .monospacedDigit()
                            .foregroundStyle(AppTheme.gpu)
                    }
                }
            }
            .font(.caption)

            footer
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
                        .fill(accent.opacity(isHovered ? 0.11 : 0.08))
                }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(accent.opacity(isHovered ? 0.34 : 0.22), lineWidth: 1)
        )
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accent.opacity(0.70))
                .frame(height: isHovered ? 4 : 3)
                .padding(.horizontal, 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: Color.black.opacity(isHovered ? 0.10 : 0.04), radius: isHovered ? 12 : 6, x: 0, y: isHovered ? 6 : 2)
        .scaleEffect(isHovered ? 1.01 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering in
            // Visual hover state only: pushing NSCursor here leaks a stuck
            // pointing hand when the hovered card is removed by a refresh,
            // because SwiftUI never delivers the terminal onHover(false).
            isHovered = hovering
        }
        .animation(AppTheme.softSpring, value: isHovered)
        .animation(AppTheme.smoothEase, value: job.state)
    }

    /// "1 node", or "1 node per task" for an array remainder.
    private var nodesText: String {
        let count = Int(row.job.nodes.trimmingCharacters(in: .whitespaces))
        let base = count.map { pluralized($0, "node") } ?? "\(row.job.nodes) nodes"
        return row.job.isArrayRemainder ? "\(base) per task" : base
    }

    /// Where it runs, or why it waits — labelled, never a bare "(Priority)".
    @ViewBuilder
    private var footer: some View {
        if let nodes = row.nodeListText {
            Label(nodes, systemImage: "server.rack")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("Running on \(nodes)")
        } else if let reason = row.reason {
            Text("Reason: \(reason.explanation)")
                .font(.caption)
                .foregroundStyle(row.isHeld ? Color.primary : Color.secondary)
                .lineLimit(2)
                .help("Slurm reason: \(reason.raw)")
        }
    }

    private func valueRow(_ title: String, _ value: String, help: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .help(help)
        }
    }
}

/// "Waiting 2 h 5 min" (since submission) and, when backfill has an
/// estimate, "Expected start in 40 min". Ticks once a minute on its own so
/// the age never freezes while monitoring is paused.
private struct JobWaitRows: View {
    let job: Job

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 5) {
                if let submitted = job.submitTime.flatMap(SlurmTimestamp.parse) {
                    HStack {
                        Text("Waiting")
                        Spacer()
                        Text(slurmDurationText(seconds: max(Int(context.date.timeIntervalSince(submitted)), 0)))
                            .monospacedDigit()
                            .help("Submitted \(submitted.formatted(date: .abbreviated, time: .standard))")
                    }
                }
                if let expected = job.startTime.flatMap(SlurmTimestamp.parse), expected > context.date {
                    HStack {
                        Text("Expected start")
                        Spacer()
                        Text(SlurmTimestamp.distanceText(to: expected, now: context.date))
                            .monospacedDigit()
                            .help("Slurm's backfill estimate: \(expected.formatted(date: .abbreviated, time: .standard)). Estimates move as other jobs finish early or new ones arrive.")
                    }
                }
            }
        }
    }
}

// MARK: - Detail sheet

struct JobDetailView: View {
    @Environment(\.dismiss) private var dismiss
    /// The cluster the job lives on. Named on every remote action because the
    /// same job id can exist on another cluster as a different job.
    let profile: ClusterProfile
    /// The current snapshot's version of the job, or its last-seen copy when
    /// `isGone`.
    let job: Job
    /// The job is no longer in the queue (finished, cancelled, or removed):
    /// show the last-seen state and disable remote actions.
    var isGone: Bool = false
    /// When the job was last present in a snapshot.
    var lastSeen: Date? = nil
    /// Running tasks of the same array, for a pending remainder's cancel
    /// dialog; nil when the caller does not know the rest of the queue.
    var runningSiblings: [Job]? = nil
    /// The job's latest usage sample and recent trend (running jobs only).
    var usage: JobUsageSummary? = nil
    var usageSeries: [JobUsagePoint] = []
    var isSamplingUsage = false
    var onTailOutput: (@MainActor (Job) -> Void)? = nil
    var onCancelJob: (@MainActor (Job) async throws -> Void)? = nil
    var onBrowseWorkDir: (@MainActor (Job) -> Void)? = nil

    @State private var showCancelConfirmation = false
    @State private var isCancelling = false
    @State private var cancelStatus: String?
    @State private var cancelFailed = false

    /// The job parsed once, with the same state, reason and colour rules as
    /// its card.
    private var row: JobRow { JobRow(job: job, profile: profile) }

    var body: some View {
        let row = self.row
        let state = row.state
        VStack(alignment: .leading, spacing: 14) {
            header(row)

            if isGone {
                goneBanner
            }

            HStack(spacing: 12) {
                if state.occupiesNodes {
                    DetailMetric(title: "Elapsed", value: elapsedText(job.elapsed), systemImage: "timer", accent: .blue)
                } else if job.isArrayRemainder {
                    DetailMetric(title: "Queued tasks", value: "\(job.taskMultiplicity)", systemImage: "square.stack.3d.down.right", accent: .orange)
                }
                DetailMetric(title: "Limit", value: formatSlurmTimeLimit(job.timeLimit), systemImage: "hourglass", accent: .purple)
                DetailMetric(title: job.isArrayRemainder ? "Nodes per task" : "Nodes", value: job.nodes, systemImage: "server.rack", accent: .teal)
                DetailMetric(title: job.isArrayRemainder ? "CPUs per task" : "CPUs", value: number(job.numCpus), systemImage: "cpu", accent: AppTheme.cpu)
                if let gpuRequest = row.gpu {
                    DetailMetric(title: job.isArrayRemainder ? "GPUs per task" : "GPUs", value: gpuRequest.summary, systemImage: "memorychip", accent: AppTheme.gpu)
                }
            }

            actionsRow(state: state)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    DetailSection(title: "Timeline", systemImage: "calendar.badge.clock") {
                        TimestampRow(label: "Submitted", raw: job.submitTime)
                        if state.isPending {
                            // For a queued job Slurm's StartTime/EndTime are
                            // backfill estimates, not facts; hide them when
                            // Slurm has none.
                            if job.startTime != nil {
                                TimestampRow(label: "Expected start", raw: job.startTime, isEstimate: true)
                            }
                            if job.endTime != nil {
                                TimestampRow(label: "Expected end", raw: job.endTime, isEstimate: true)
                            }
                        } else {
                            TimestampRow(label: "Started", raw: job.startTime)
                            TimestampRow(label: state.occupiesNodes ? "Ends by" : "Ended", raw: job.endTime)
                        }
                        DetailRow(label: "Batch host", value: job.batchHost)
                    }

                    if job.arrayJobID != nil || job.isArrayRemainder {
                        DetailSection(title: "Job array", systemImage: "square.stack.3d.down.right") {
                            DetailRow(label: "Array", value: job.arrayJobID.map(String.init) ?? job.jobId)
                            if job.isArrayRemainder {
                                DetailRow(label: "Queued tasks", value: queuedTasksText, monospaced: false)
                                if let runningSiblings {
                                    DetailRow(
                                        label: "Running tasks",
                                        value: runningSiblings.isEmpty ? "none right now" : siblingList(runningSiblings, limit: 8),
                                        monospaced: false
                                    )
                                }
                            }
                        }
                    }

                    if state.occupiesNodes && !isGone && !job.isArrayRemainder {
                        JobUsageDetailSection(summary: usage, series: usageSeries, isSampling: isSamplingUsage)
                    }

                    DetailSection(title: "Resources", systemImage: "square.stack.3d.up") {
                        if let reason = row.reason {
                            DetailRow(label: "Reason", value: reason.explanation, help: "Slurm reason: \(reason.raw)", monospaced: false)
                        }
                        // %R is a node list only for jobs on nodes; for a
                        // queued job it is the reason shown above.
                        DetailRow(label: "Node list", value: row.nodeListText)
                        DetailRow(label: Self.slurmTasksLabel(for: job), value: number(job.numTasks), help: Self.slurmTasksHelp(for: job))
                        DetailRow(label: "Requested TRES", value: job.reqTres)
                        DetailRow(label: "Allocated TRES", value: job.allocTres)
                        DetailRow(label: "TRES per node", value: job.tresPerNode)
                    }

                    DetailSection(title: "Paths", systemImage: "folder") {
                        DetailRow(label: "Work directory", value: job.workDir)
                        DetailRow(label: "Command", value: job.command)
                        DetailRow(label: outputLabel("Stdout"), value: outputPath(job.stdoutPath), help: outputHelp)
                        DetailRow(label: outputLabel("Stderr"), value: outputPath(job.stderrPath), help: outputHelp)
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

    private func header(_ row: JobRow) -> some View {
        let accent = isGone ? Color.gray : row.accentColor
        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(accent.opacity(0.14))
                Image(systemName: row.isGPU ? "memorychip" : "terminal")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text(job.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(job.name)
                HStack(spacing: 6) {
                    ClusterBadge(profile: profile, size: 16)
                    Text("\(profile.displayName) • \(job.displayJobID) • \(job.partition)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Spacer()
            StatusCapsule(
                text: isGone ? "Gone" : row.statusText,
                color: isGone ? .gray : row.statusColor,
                help: isGone ? "No longer in the queue; last state \(job.state)" : row.statusHelp
            )
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
    }

    private var goneBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "tray")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("No longer in the queue")
                    .font(.callout.weight(.semibold))
                Text(goneDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private var goneDetail: String {
        let seen = lastSeen.map { "Last seen \($0.formatted(date: .omitted, time: .shortened)), " } ?? ""
        return "\(seen)shown as it was then. It finished, was cancelled, or was removed; use sacct for its final state."
    }

    /// Terminal-backed actions: tail the job's stdout, or scancel it after a
    /// confirmation. Status of the last cancel attempt shows inline.
    private func actionsRow(state: JobState) -> some View {
        HStack(spacing: 10) {
            // The pending remainder of an array has no output file of its
            // own (each task writes its own once it starts), so there is
            // nothing to tail.
            if !job.isArrayRemainder {
                Button {
                    onTailOutput?(job)
                } label: {
                    Label("Tail output", systemImage: "text.alignleft")
                }
                .buttonStyle(.bordered)
                .disabled(onTailOutput == nil || (job.stdoutPath ?? "").isEmpty || state.isPending || isGone)
                .help(tailHelp(state: state))
            }

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
                Label(cancelButtonTitle, systemImage: "xmark.octagon")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(onCancelJob == nil || isCancelling || isGone)
            .help(cancelHelp)
            .accessibilityHint(cancelAccessibilityHint)

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
        .alert(cancelAlertTitle, isPresented: $showCancelConfirmation) {
            Button(job.isArrayRemainder ? "Keep tasks" : "Keep job", role: .cancel) {}
            Button(cancelButtonTitle, role: .destructive) {
                performCancel()
            }
        } message: {
            Text(cancelAlertMessage)
        }
    }

    // MARK: Cancel wording

    /// The array id `scancel --state=PENDING` targets for a remainder.
    private var arrayID: String {
        job.arrayJobID.map(String.init) ?? job.jobId
    }

    private var cancelButtonTitle: String {
        if isCancelling {
            return "Cancelling…"
        }
        return job.isArrayRemainder ? "Cancel queued tasks" : "Cancel job"
    }

    private var cancelAlertTitle: String {
        if job.isArrayRemainder {
            return "Cancel the queued tasks of \(profile.displayName) array \(arrayID)?"
        }
        return "Cancel \(profile.displayName) job \(job.jobId)?"
    }

    /// A remainder's cancel says exactly what happens to the running tasks:
    /// `scancel <array id>` would kill them too, so the session runs
    /// `scancel --state=PENDING <array id>`, which leaves them alone.
    private var cancelAlertMessage: String {
        if job.isArrayRemainder {
            let tasks = pluralized(job.taskMultiplicity, "pending task")
            let running: String
            if let runningSiblings, !runningSiblings.isEmpty {
                running = "Running tasks (\(siblingList(runningSiblings, limit: 4))) keep running."
            } else {
                running = "Tasks that are already running keep running."
            }
            return "Cancels the \(tasks) of array \(arrayID) (\(job.displayJobID)). \(running) This runs scancel --state=PENDING \(arrayID) on \(profile.displayName) only."
        }
        return "Cancel job \(job.jobId) \(job.name)? This runs scancel on \(profile.displayName) only."
    }

    private var cancelHelp: String {
        if isGone {
            return "This job is no longer in the queue"
        }
        if job.isArrayRemainder {
            return "Run scancel --state=PENDING \(arrayID) on \(profile.displayName): cancels only the tasks still queued"
        }
        return "Run scancel \(job.jobId) on \(profile.displayName)"
    }

    private var cancelAccessibilityHint: String {
        job.isArrayRemainder
            ? "Cancels the queued tasks of this array on \(profile.displayName) after confirmation; running tasks keep running"
            : "Cancels this job on \(profile.displayName) after confirmation"
    }

    private func siblingList(_ siblings: [Job], limit: Int) -> String {
        let names = siblings.prefix(limit).map(\.jobId)
        let extra = siblings.count - names.count
        return names.joined(separator: ", ") + (extra > 0 ? " and \(extra) more" : "")
    }

    private func performCancel() {
        guard let onCancelJob, !isCancelling, !isGone else {
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

    // MARK: Presentation

    private var queuedTasksText: String {
        var text = "\(job.arrayPendingTasks ?? missingValuePlaceholder) (\(pluralized(job.taskMultiplicity, "task")))"
        if let throttle = job.arrayThrottle {
            text += " · at most \(throttle) at once"
        }
        return text
    }

    /// Slurm expands `%a` in a pending remainder's output path to NO_VAL
    /// (4294967294); show the per-task template instead of a path that will
    /// never exist.
    private func outputPath(_ path: String?) -> String? {
        guard job.isArrayRemainder, let path else {
            return path
        }
        return path.replacingOccurrences(of: "4294967294", with: "%a")
    }

    /// Slurm's ntasks. For an array remainder it is per array task, so the
    /// bare word "Tasks" beside "Queued tasks 6" would contradict it.
    nonisolated static func slurmTasksLabel(for job: Job) -> String {
        job.isArrayRemainder ? "ntasks (per task)" : "Tasks"
    }

    nonisolated static func slurmTasksHelp(for job: Job) -> String? {
        guard job.isArrayRemainder else {
            return nil
        }
        return "Slurm's --ntasks for each array task; the array itself has \(pluralized(job.taskMultiplicity, "queued task"))."
    }

    private func outputLabel(_ base: String) -> String {
        job.isArrayRemainder ? "\(base) (per task)" : base
    }

    private var outputHelp: String? {
        job.isArrayRemainder ? "Each task writes its own file; %a is the task id." : nil
    }

    /// Slurm resolves the stdout path at submit time, but slurmstepd only
    /// creates the file once the job starts — tailing a pending job would
    /// just watch a path that does not exist yet.
    private func tailHelp(state: JobState) -> String {
        if isGone {
            return "This job is no longer in the queue"
        }
        if (job.stdoutPath ?? "").isEmpty {
            return "This job has no stdout path"
        }
        if state.isPending {
            return "Output file is created when the job starts"
        }
        return "Follow the job's stdout in the Terminal tab"
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
                    .lineLimit(1)
            }
            .font(.caption)
            Text(value.isEmpty ? missingValuePlaceholder : value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
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
    var help: String? = nil
    var monospaced = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .leading)
            Text(displayValue)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(help ?? "")
        }
    }

    private var displayValue: String {
        guard let value, !value.isEmpty else {
            return missingValuePlaceholder
        }
        return value
    }
}

/// A timestamp as a relative time ("41 min ago", "in 2 h") beside the
/// absolute local time, instead of Slurm's raw ISO string. Ticks on its own
/// so the relative part never freezes.
struct TimestampRow: View {
    let label: String
    let raw: String?
    /// A backfill estimate rather than a recorded time.
    var isEstimate = false

    var body: some View {
        if let raw, let date = SlurmTimestamp.parse(raw) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 108, alignment: .leading)
                    Text(SlurmTimestamp.distanceText(to: date, now: context.date))
                        .font(.callout)
                    Text(date.formatted(date: .abbreviated, time: .standard))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .help(isEstimate ? "Slurm's estimate; it moves as other jobs finish or arrive. Raw: \(raw)" : "Raw: \(raw)")
                .accessibilityElement(children: .combine)
            }
        } else {
            DetailRow(label: label, value: raw)
        }
    }
}

// MARK: - GPU job detection

extension Job {
    /// Single source of truth for "is this a GPU job" on the Jobs tab.
    ///
    /// The TRES strings are authoritative and cluster-neutral. Without them
    /// (older caches, or a job squeue reported without details) the cluster
    /// profile's partition roles decide, and only partitions the profile does
    /// not know fall back to the historical "name contains gpu" heuristic —
    /// which still catches AIRE's `gpu` and Calder's `calder-gpu-hopper`.
    func isGPUJob(on profile: ClusterProfile) -> Bool {
        isGPUJob(on: profile, gpuRequest: gpuRequest)
    }

    /// Same rule with an already-parsed GPU request (TRES parsing is the
    /// expensive part).
    func isGPUJob(on profile: ClusterProfile, gpuRequest: JobGPURequest?) -> Bool {
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
