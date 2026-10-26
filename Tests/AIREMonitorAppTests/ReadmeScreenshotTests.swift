import AppKit
import HPCCore
import SwiftUI
import Testing
@testable import AIREMonitorApp

/// The README's screenshots (docs/images/): the main surfaces drawn from the
/// checked-in fixtures plus demo job usage and session ages — never the
/// data cached on the machine running it, so no real account, job or
/// path can end up in the repository.
///
/// Disabled unless HPC_RENDER_README names an output directory; run it
/// through scripts/render_readme_images.sh, which also scales and
/// compresses the PNGs.
@MainActor
@Suite(
    "README screenshots",
    .enabled(if: ProcessInfo.processInfo.environment["HPC_RENDER_README"] != nil),
    .serialized
)
struct ReadmeScreenshotTests {
    private let outputDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HPC_RENDER_README"] ?? "/tmp")
    private static let window = CGSize(width: 1440, height: 900)
    private static let sidebarWidth: CGFloat = 340
    /// Transparent margin around a drawn window, room for its shadow.
    private static let margin: CGFloat = 36

    @Test("Render the README screenshots")
    func renderAll() throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let scheme: ColorScheme = appearance == .darkAqua ? .dark : .light
            let suffix = appearance == .darkAqua ? "dark" : "light"
            let model = makeDemoModel()

            model.selection = .overview
            try renderWindow(model: model, scheme: scheme, appearance: appearance, size: Self.window, name: "overview-\(suffix)") {
                OverviewDashboard(model: model)
            }

            let calder = try #require(model.session(for: .calder))
            model.selection = .cluster(.calder)
            calder.dashboard.selectedTab = .jobs
            try renderWindow(model: model, scheme: scheme, appearance: appearance, size: CGSize(width: 1440, height: 1010), name: "jobs-\(suffix)") {
                ClusterDashboardView(model: model, session: calder)
            }

            // The rest only in dark mode: the README shows them once.
            guard appearance == .darkAqua else {
                continue
            }

            calder.dashboard.selectedTab = .nodes
            try renderPanel(scheme: scheme, appearance: appearance, size: CGSize(width: 1100, height: 830), name: "nodes-\(suffix)") {
                ClusterDashboardView(model: model, session: calder).background(DashboardBackdrop())
            }

            let aire = try #require(model.session(for: .aire))
            model.selection = .cluster(.aire)
            aire.dashboard.selectedTab = .trends
            try renderPanel(scheme: scheme, appearance: appearance, size: CGSize(width: 1100, height: 760), name: "trends-\(suffix)") {
                ClusterDashboardView(model: model, session: aire).background(DashboardBackdrop())
            }

            let job = try #require(calder.snapshot?.jobs.first { $0.jobId == Self.bigJobID })
            // Cropped just below Resource use.
            try renderPanel(scheme: scheme, appearance: appearance, size: CGSize(width: 720, height: 724), name: "job-usage-\(suffix)") {
                JobDetailView(
                    profile: calder.profile,
                    job: job,
                    usage: calder.jobUsage[job.jobId],
                    usageSeries: calder.jobUsageHistory.series(for: job.jobId),
                    isSamplingUsage: true,
                    onTailOutput: { _ in },
                    onCancelJob: { _ in },
                    onBrowseWorkDir: { _ in }
                )
            }

            // The sidebar's Sessions card and the menu bar dropdown, each at
            // its natural height.
            let sessions = SessionsCard(model: model, confirmation: .constant(nil))
                .frame(width: 360)
                .padding(14)
                .background(Self.sidebarFill(scheme))
            try renderPanel(scheme: scheme, appearance: appearance, size: Self.naturalSize(sessions, width: 388), name: "sessions-\(suffix)") {
                sessions
            }
            let menu = MenuBarMonitorView(model: model, closeMenu: {}).fixedSize(horizontal: false, vertical: true)
            try renderPanel(scheme: scheme, appearance: appearance, size: Self.naturalSize(menu, width: MenuBarMonitorView.panelWidth), name: "menubar-\(suffix)", rounded: 14) {
                menu
            }
        }
    }

    // MARK: Demo data

    private static let bigJobID = "52110"

    /// The fixtures re-stamped to "just now", Calder with one more running
    /// job (four H200s, two of them idle), demo usage for every running
    /// Calder job, a live rash route, and session ages.
    private func makeDemoModel() -> AppModel {
        let now = Date().addingTimeInterval(-20)
        let model = PreviewModels.model(snapshot: { id in
            guard let fixture = CoreFixtures.snapshot(for: id) else {
                return nil
            }
            let snapshot = PreviewModels.restamped(fixture, at: now)
            return id == .calder ? Self.withBigJob(snapshot, now: now) : snapshot
        }) { session, snapshot in
            session.installPreviewState(
                snapshot: snapshot,
                history: snapshot.map { PreviewModels.history(from: $0) } ?? [],
                isLoggedIn: snapshot != nil,
                statusMessage: "Last refresh just now"
            )
        }
        model.connectionRoute = .rashJump
        // The fixtures' placeholder account, so the sidebar and the cluster
        // headers show one identity.
        model.username = "abcd1234"
        if let calder = model.session(for: .calder) {
            let (usage, history) = Self.demoUsage(now: now)
            calder.installPreviewJobUsage(usage, history: history)
        }
        let started = now.addingTimeInterval(-(3 * 3600 + 14 * 60))
        model.installPreviewSharing(
            SessionSharingReport(
                sessions: [
                    SharedSessionStatus(name: "rash", displayName: "rash", socketPath: "/tmp/jump.sock", stableLinkPath: "/tmp/rash.sock", since: started),
                    SharedSessionStatus(name: "aire", displayName: "AIRE", socketPath: "/tmp/aire.sock", stableLinkPath: "/tmp/aire.sock", since: started.addingTimeInterval(40)),
                    SharedSessionStatus(name: "calder", displayName: "Calder", socketPath: "/tmp/calder.sock", stableLinkPath: "/tmp/calder.sock", since: started.addingTimeInterval(95))
                ],
                aliases: [
                    SharedAliasStatus(alias: "aire", sessionName: "aire", state: .linked),
                    SharedAliasStatus(alias: "calder", sessionName: "calder", state: .linked),
                    SharedAliasStatus(alias: "rash", sessionName: "rash", state: .linked)
                ],
                isSharing: true
            ),
            hasSavedPassword: true
        )
        return model
    }

    private static func withBigJob(_ snapshot: ClusterSnapshot, now: Date) -> ClusterSnapshot {
        let slurmTime = DateFormatter()
        slurmTime.locale = Locale(identifier: "en_US_POSIX")
        slurmTime.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let elapsed: TimeInterval = 6 * 3600 + 42 * 60 + 10
        let started = now.addingTimeInterval(-elapsed)
        let submitTime: String = slurmTime.string(from: started.addingTimeInterval(-4_590))
        let startTime: String = slurmTime.string(from: started)
        let endTime: String = slurmTime.string(from: started.addingTimeInterval(2 * 86_400))
        let job = Job(
            jobId: bigJobID,
            partition: "calder-gpu-hopper",
            name: "train-llm-70b",
            user: "abcd1234",
            state: "RUNNING",
            elapsed: "6:42:10",
            timeLimit: "2-00:00:00",
            nodes: "1",
            reasonOrNodeList: "calder-h200-01",
            submitTime: submitTime,
            startTime: startTime,
            endTime: endTime,
            workDir: "/scratch-calder/users/abcd1234/train-llm-70b",
            command: "/scratch-calder/users/abcd1234/train-llm-70b/train.sh",
            stdoutPath: "/scratch-calder/users/abcd1234/train-llm-70b/slurm-52110.out",
            stderrPath: "/scratch-calder/users/abcd1234/train-llm-70b/slurm-52110.out",
            batchHost: "calder-h200-01",
            nodeList: "calder-h200-01",
            numCpus: 64,
            numTasks: 1,
            reqTres: "cpu=64,mem=500G,node=1,billing=64,gres/gpu=4",
            allocTres: "cpu=64,mem=500G,node=1,billing=64,gres/gpu=4",
            tresPerNode: "gres/gpu:nvidia_h200:4"
        )
        return ClusterSnapshot(
            schemaVersion: snapshot.schemaVersion,
            collectedAt: snapshot.collectedAt,
            startedAt: snapshot.startedAt,
            durationMs: snapshot.durationMs,
            timings: snapshot.timings,
            storageSkipped: snapshot.storageSkipped,
            cluster: snapshot.cluster,
            remote: snapshot.remote,
            jobs: [job] + snapshot.jobs,
            partitions: snapshot.partitions,
            nodes: snapshot.nodes,
            storage: snapshot.storage,
            errors: snapshot.errors,
            warnings: snapshot.warnings
        )
    }

    private struct DemoJob {
        let id: String
        let node: String
        let cpus: Int
        let busy: Double
        let memoryGB: Double
        let limitGB: Double
        /// (GRES index, utilisation %, memory GB) per GPU.
        let gpus: [(Int, Double, Double)]
    }

    private static let demoJobs = [
        DemoJob(id: bigJobID, node: "calder-h200-01", cpus: 64, busy: 21.5, memoryGB: 302, limitGB: 500,
                gpus: [(0, 97, 121), (1, 96, 118), (2, 0, 0.6), (3, 1, 0.6)]),
        DemoJob(id: "35796_1", node: "calder-h200-06", cpus: 8, busy: 7.1, memoryGB: 51, limitGB: 80, gpus: [(4, 94, 98)]),
        DemoJob(id: "38961_2", node: "calder-h200-03", cpus: 8, busy: 7.8, memoryGB: 30, limitGB: 80, gpus: [(6, 21, 34)]),
        DemoJob(id: "48081", node: "calder-cpu008", cpus: 64, busy: 61.2, memoryGB: 176, limitGB: 250, gpus: []),
        DemoJob(id: "9926", node: "calder-cpu001", cpus: 1, busy: 0.1, memoryGB: 0.2, limitGB: 4, gpus: [])
    ]

    private static func rows(at date: Date, wobble: Double) -> [JobNodeUsage] {
        demoJobs.map { job in
            JobNodeUsage(
                jobID: job.id,
                displayID: job.id,
                node: job.node,
                cpusAllocated: job.cpus,
                cpusBusy: max(job.busy + wobble * Double(job.cpus) / 64, 0),
                memoryUsedMB: job.memoryGB * 1024,
                memoryPeakMB: job.memoryGB * 1024 * 1.12,
                memoryLimitMB: job.limitGB * 1024,
                gpuIndices: job.gpus.map(\.0),
                gpus: job.gpus.map { index, utilization, memory in
                    let busy = utilization > 5
                    return GPUUsage(
                        index: index,
                        name: "NVIDIA H200",
                        utilizationPercent: busy ? min(max(utilization + wobble * 3, 0), 100) : utilization,
                        memoryUsedMB: memory * 1024,
                        memoryTotalMB: 143_771,
                        powerWatts: busy ? 120 + utilization * 5.6 : 118,
                        powerLimitWatts: 700,
                        temperatureC: busy ? 38 + utilization / 3 : 34
                    )
                }
            )
        }
    }

    /// The latest sample plus two hours of one-a-minute history.
    private static func demoUsage(now: Date) -> ([String: JobUsageSummary], JobUsageHistory) {
        let running = Set(demoJobs.map(\.id))
        var history = JobUsageHistory()
        for minute in stride(from: 119, through: 1, by: -1) {
            let wobble = sin(Double(minute) / 4) * 1.8 + Double((minute * 37) % 7) / 7 - 0.5
            let date = now.addingTimeInterval(Double(-minute) * 60)
            history.record(JobUsageSummary.summaries(from: rows(at: date, wobble: wobble), sampledAt: date), running: running)
        }
        let latest = JobUsageSummary.summaries(from: rows(at: now, wobble: 0), sampledAt: now)
        history.record(latest, running: running)
        return (latest, history)
    }

    // MARK: Rendering

    private static func sidebarFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.155) : Color(white: 0.935)
    }

    /// A macOS-style window: title bar with traffic lights over the sidebar
    /// column and the detail column, on a transparent margin with a shadow.
    private func renderWindow<Detail: View>(
        model: AppModel,
        scheme: ColorScheme,
        appearance: NSAppearance.Name,
        size: CGSize,
        name: String,
        @ViewBuilder detail: () -> Detail
    ) throws {
        let chrome = VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { color in
                    Circle().fill(color).frame(width: 12, height: 12)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 30)
            .background(Self.sidebarFill(scheme))
            HStack(spacing: 0) {
                ConnectionSidebar(model: model)
                    .frame(width: Self.sidebarWidth)
                    .background(Self.sidebarFill(scheme))
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1)
                detail()
                    .background(DashboardBackdrop())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
        .padding(Self.margin)
        .environment(\.colorScheme, scheme)

        try render(
            chrome,
            size: CGSize(width: size.width + Self.margin * 2, height: size.height + Self.margin * 2),
            appearance: appearance,
            name: name,
            transparent: true
        )
    }

    /// One panel with rounded corners on a transparent margin.
    private func renderPanel<Content: View>(
        scheme: ColorScheme,
        appearance: NSAppearance.Name,
        size: CGSize,
        name: String,
        rounded radius: CGFloat = 12,
        @ViewBuilder content: () -> Content
    ) throws {
        let body = content()
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color.primary.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
            .padding(Self.margin)
            .environment(\.colorScheme, scheme)
        let canvas = CGSize(width: size.width + Self.margin * 2, height: size.height + Self.margin * 2)
        try render(body, size: canvas, appearance: appearance, name: name, transparent: true)
    }

    /// The height `view` asks for at `width`.
    private static func naturalSize<V: View>(_ view: V, width: CGFloat) -> CGSize {
        let controller = NSHostingController(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true))
        let fitted = controller.sizeThatFits(in: CGSize(width: width, height: 10_000))
        return CGSize(width: width, height: ceil(fitted.height))
    }

    private func render<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, name: String, transparent: Bool) throws {
        let hosted = LayoutHost.host(view, size: size, appearance: appearance, settle: 1.5)
        defer { hosted.window.orderOut(nil) }
        let scale: CGFloat = 2
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        if !transparent {
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                context.cgContext.setFillColor(NSColor.windowBackgroundColor.cgColor)
            }
            context.cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.cgContext.scaleBy(x: scale, y: scale)
        context.cgContext.translateBy(x: 0, y: size.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        try #require(hosted.view.layer).render(in: context.cgContext)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }
}
