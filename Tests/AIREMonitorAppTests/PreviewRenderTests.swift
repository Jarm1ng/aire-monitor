import HPCCore
import AppKit
import SwiftUI
import Testing
@testable import AIREMonitorApp

// Two suites share the fixtures and hosting helpers below:
//
// - "Minimum window layout" (always on): hosts the real dashboards at the
//   narrowest the detail column can get and fails when anything needs more
//   width. This is the assertion the renders below never made — the AIRE
//   Nodes overflow shipped although a render showed it.
// - "Preview renders" (opt-in, scripts/render_previews.sh): PNG screenshots
//   for reviewing layout by eye when a screen capture is not possible.
//
// Nothing here touches the network, the Keychain or the real runtime
// directory: the models point at a throwaway project root and a username
// with no control sockets, and start no timers. The only process a hosted
// view starts is the Files tab's `ssh -O check` pre-flight, which asks a
// control socket that does not exist and never opens a connection.

// MARK: - Minimum window layout

/// Every cluster tab, sign-in screen and the overview must fit the detail
/// column at ContentView's minimum window size. A width check sees overflow
/// (content wider than the column, which AppKit then clips or centres off
/// both edges); it cannot see text that wraps or truncates to fit, which is
/// what `lineLimit(1)`/`fixedSize()` on labels turn into measurable overflow.
@MainActor
@Suite(
    "Minimum window layout",
    .enabled(if: LayoutHost.windowServerAvailable, "needs a logged-in macOS session (a window server)")
)
struct MinimumWindowLayoutTests {
    /// The narrowest the detail column gets: ContentView's minimum window
    /// width minus the sidebar column's minimum width.
    static let detailWidth: CGFloat = ContentView.minimumDetailSize.width
    /// ContentView's minimum height. Height only scrolls; it matters for the
    /// panes that fill the column (Files, Terminal).
    static let detailHeight: CGFloat = ContentView.minimumDetailSize.height

    @Test("Each cluster tab fits while live", arguments: catalogIDs, DashboardTab.allCases)
    func liveTab(id: ClusterID, tab: DashboardTab) throws {
        let model = PreviewModels.fixtureModel { session, snapshot in
            session.installPreviewState(
                snapshot: snapshot,
                history: PreviewModels.history(from: snapshot),
                isLoggedIn: true,
                statusMessage: "Last refresh 11:49:50"
            )
        }
        try expectClusterFits(model: model, id: id, tab: tab)
    }

    @Test("Each cluster tab fits while showing a cached snapshot", arguments: catalogIDs, DashboardTab.allCases)
    func cachedTab(id: ClusterID, tab: DashboardTab) throws {
        // Not signed in, with an error banner, instead of the live refresh
        // controls: the stale phase with Connect in the header once
        // installPreviewState marks the startup probe as done, the
        // "checking" phase while it does not.
        let model = PreviewModels.fixtureModel { session, snapshot in
            session.installPreviewState(
                snapshot: snapshot,
                history: PreviewModels.history(from: snapshot),
                isLoggedIn: false,
                statusMessage: "Showing the snapshot from 12:49",
                errorMessage: "\(session.displayName) SSH session expired — use Connect to sign in to \(session.displayName) again."
            )
        }
        try expectClusterFits(model: model, id: id, tab: tab)
    }

    @Test("The status strip fits for every refresh failure kind", arguments: catalogIDs, PreviewModels.FailureState.allCases)
    func failureStrip(id: ClusterID, state: PreviewModels.FailureState) throws {
        let model = PreviewModels.fixtureModel { session, snapshot in
            state.install(on: session, snapshot: snapshot)
        }
        try expectClusterFits(model: model, id: id, tab: .jobs)
    }

    @Test("The status strip fits with its details open")
    func expandedStrip() {
        for state in PreviewModels.FailureState.allCases {
            let input = state.input(clusterName: "Calder")
            let content = ClusterStatusContent.make(input)
            #expect(content?.details != nil, "\(state.rawValue) has no details to open")
            guard let content else {
                continue
            }
            let measurement = LayoutHost.measure(
                StatusStripView(content: content, clusterName: "Calder", initiallyExpanded: true),
                width: Self.detailWidth - 36,
                height: Self.detailHeight
            )
            #expect(measurement.fits, "\(state.rawValue) strip, details open: \(measurement.problem)")
        }
    }

    @Test("Nodes and Trends fit while GPU allocation is unknown", arguments: catalogIDs, [DashboardTab.nodes, .trends])
    func unknownGPUAllocation(id: ClusterID, tab: DashboardTab) throws {
        let model = PreviewModels.fixtureModel { session, snapshot in
            PreviewModels.installUnknownGPUAllocation(on: session, snapshot: snapshot)
        }
        try expectClusterFits(model: model, id: id, tab: tab)
    }

    @Test("Sign-in screens fit", arguments: catalogIDs, PreviewModels.SignInState.allCases)
    func signInScreen(id: ClusterID, state: PreviewModels.SignInState) throws {
        let model = PreviewModels.fixtureModel { session, _ in
            state.install(on: session)
        }
        try expectClusterFits(model: model, id: id, tab: .jobs)
    }

    @Test("The overview fits", arguments: PreviewModels.OverviewState.allCases)
    func overview(state: PreviewModels.OverviewState) {
        let model = PreviewModels.fixtureModel { session, snapshot in
            state.install(on: session, snapshot: snapshot)
        }
        model.selection = .overview
        let measurement = LayoutHost.measure(OverviewDashboard(model: model), width: Self.detailWidth, height: Self.detailHeight)
        #expect(measurement.fits, "Overview (\(state.rawValue)): \(measurement.problem)")
    }

    private func expectClusterFits(model: AppModel, id: ClusterID, tab: DashboardTab) throws {
        let session = try #require(model.session(for: id))
        model.selection = .cluster(id)
        session.dashboard.selectedTab = tab
        let measurement = LayoutHost.measure(
            ClusterDashboardView(model: model, session: session),
            width: Self.detailWidth,
            height: Self.detailHeight
        )
        #expect(measurement.fits, "\(session.displayName) · \(tab.title): \(measurement.problem)")
    }
}

// MARK: - Offscreen renders

/// Offscreen screenshots of the real UI, for reviewing layout without a
/// display session (screen capture is often unavailable to tooling).
///
/// Disabled unless HPC_RENDER_PREVIEWS names an output directory; run it
/// through scripts/render_previews.sh. Snapshot data comes from
/// HPC_PREVIEW_DATA (a directory laid out like .runtime/clusters/<id>/ with
/// latest_snapshot.json and optionally snapshot_history.jsonl); a cluster
/// without one there falls back to the checked-in fixtures (CoreFixtures).
/// The minimum-size renders are also measured, so real data that overflows
/// the column fails the run (the PNG is still written).
@MainActor
@Suite(
    "Preview renders",
    .enabled(if: ProcessInfo.processInfo.environment["HPC_RENDER_PREVIEWS"] != nil),
    // One at a time: a render blocks the main actor for its whole run, and
    // the Files render waits on main-actor tasks of its own.
    .serialized
)
struct PreviewRenderTests {
    private let outputDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HPC_RENDER_PREVIEWS"] ?? "/tmp")
    private let dataDirectory = ProcessInfo.processInfo.environment["HPC_PREVIEW_DATA"]

    private static let comfortable = CGSize(width: 1440, height: 920)
    private static let minimum = ContentView.minimumWindowSize
    /// The detail column of the comfortable window, for renders of one
    /// cluster's dashboard on its own (no sidebar-column artefact).
    private static let comfortableDetail = CGSize(width: 1100, height: 760)

    @Test("Render every main surface")
    func renderAll() throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let suffix = appearance == .darkAqua ? "dark" : "light"
            // Everything live, comfortable window.
            let model = makeModel()
            model.selection = .overview
            try render(ContentView(model: model), size: Self.comfortable, appearance: appearance, name: "overview-live-\(suffix)")
            guard appearance == .darkAqua else {
                // Jobs, plus the two tabs drawn in node-state colours
                // (state pills, partition bars and legends), whose contrast
                // light mode tests hardest.
                for session in model.sessions {
                    model.selection = .cluster(session.id)
                    for tab in [DashboardTab.jobs, .partitions, .nodes] {
                        session.dashboard.selectedTab = tab
                        try render(ContentView(model: model), size: Self.comfortable, appearance: appearance, name: "\(session.id.rawValue)-\(tab.rawValue)-\(suffix)")
                    }
                }
                // Tinted text on tinted fills is where light mode loses
                // contrast: check the status strip there too.
                try renderStrips(appearance: appearance, suffix: suffix)
                continue
            }
            for session in model.sessions {
                model.selection = .cluster(session.id)
                for tab in DashboardTab.allCases {
                    session.dashboard.selectedTab = tab
                    try render(ContentView(model: model), size: Self.comfortable, appearance: appearance, name: "\(session.id.rawValue)-\(tab.rawValue)-\(suffix)")
                    // Minimum window size: catches truncation by eye and
                    // overflow by measurement.
                    let measurement = LayoutHost.measure(
                        ClusterDashboardView(model: model, session: session),
                        width: MinimumWindowLayoutTests.detailWidth,
                        height: MinimumWindowLayoutTests.detailHeight
                    )
                    #expect(measurement.fits, "\(session.displayName) · \(tab.title) with this data: \(measurement.problem)")
                    // …and by eye: the detail column alone at that size.
                    try renderDetail(model: model, session: session, size: ContentView.minimumDetailSize, appearance: appearance, name: "\(session.id.rawValue)-\(tab.rawValue)-detail-min-\(suffix)")
                }
                session.dashboard.selectedTab = .nodes
                try render(ContentView(model: model), size: Self.minimum, appearance: appearance, name: "\(session.id.rawValue)-nodes-min-\(suffix)")
                // A little above the minimum, to compare how the header
                // and filters reflow once there is room (AIRE's five node
                // groups once pushed the header past the column here).
                for width in [1100, 1220] {
                    try render(ContentView(model: model), size: CGSize(width: width, height: 760), appearance: appearance, name: "\(session.id.rawValue)-nodes-\(width)x760-\(suffix)")
                }
            }
            model.selection = .overview
            try render(ContentView(model: model), size: Self.minimum, appearance: appearance, name: "overview-min-\(suffix)")

            // Sidebar on its own (NavigationSplitView's sidebar column uses a
            // material background that layer rendering cannot draw).
            try render(
                ConnectionSidebar(model: model).environment(\.colorScheme, appearance == .darkAqua ? .dark : .light),
                size: CGSize(width: 360, height: 1500),
                appearance: appearance,
                name: "sidebar-\(suffix)"
            )

            // Menu bar dropdown.
            try render(MenuBarMonitorView(model: model, closeMenu: {}).fixedSize(horizontal: false, vertical: true), size: CGSize(width: 400, height: 900), appearance: appearance, name: "menubar-live-\(suffix)")

            // Job detail sheet for the first job anywhere.
            if let session = model.sessions.first(where: { ($0.snapshot?.jobs.isEmpty ?? true) == false }),
               let job = session.snapshot?.jobs.sorted(by: jobDisplayOrder).first {
                let sheet = JobDetailView(profile: session.profile, job: job, onTailOutput: { _ in }, onCancelJob: { _ in }, onBrowseWorkDir: { _ in })
                try render(sheet, size: CGSize(width: 720, height: 820), appearance: appearance, name: "\(session.id.rawValue)-job-sheet-\(suffix)")
            }

            // Job sheet for a pending array remainder ("123_[2-58]"), with
            // its running tasks passed in, as the Jobs tab does.
            if let session = model.sessions.first(where: { $0.snapshot?.jobs.contains(where: \.isArrayRemainder) == true }),
               let jobs = session.snapshot?.jobs,
               let remainder = jobs.first(where: \.isArrayRemainder) {
                let sheet = JobDetailView(
                    profile: session.profile,
                    job: remainder,
                    runningSiblings: JobsDashboard.runningSiblings(of: remainder, in: jobs),
                    onTailOutput: { _ in },
                    onCancelJob: { _ in },
                    onBrowseWorkDir: { _ in }
                )
                try render(sheet, size: CGSize(width: 720, height: 860), appearance: appearance, name: "\(session.id.rawValue)-job-sheet-array-remainder-\(suffix)")
            }

            // The status strip for each refresh failure kind, on the
            // detail column at the minimum window size.
            for state in PreviewModels.FailureState.allCases {
                let failing = makeModel()
                if let calder = failing.session(for: .calder), let snapshot = calder.snapshot {
                    state.install(on: calder, snapshot: snapshot)
                    calder.dashboard.selectedTab = .jobs
                    try renderDetail(model: failing, session: calder, size: ContentView.minimumDetailSize, appearance: appearance, name: "calder-strip-\(state.rawValue)-min-\(suffix)")
                }
            }
            try renderStrips(appearance: appearance, suffix: suffix)

            // A paused cluster's Trends ("Last point … · paused").
            let paused = makeModel()
            if let aire = paused.session(for: .aire), let snapshot = aire.snapshot {
                aire.installPreviewState(
                    snapshot: snapshot,
                    history: PreviewModels.history(from: snapshot),
                    isLoggedIn: true,
                    statusMessage: aire.pausedStatusText,
                    isPaused: true
                )
                aire.dashboard.selectedTab = .trends
                try renderDetail(model: paused, session: aire, size: Self.comfortableDetail, appearance: appearance, name: "aire-trends-paused-\(suffix)")
            }


            // GPU allocation unknown (node details failed): the fleet ring,
            // the capacity signal and the GPU trend cards must say so, not
            // show a free pool, "GPU full" or a dip to 0 %.
            let unknownGPUs = makeModel()
            for session in unknownGPUs.sessions {
                guard let snapshot = session.snapshot else {
                    continue
                }
                PreviewModels.installUnknownGPUAllocation(on: session, snapshot: snapshot)
                for tab in [DashboardTab.nodes, .trends] {
                    session.dashboard.selectedTab = tab
                    try renderDetail(model: unknownGPUs, session: session, size: Self.comfortableDetail, appearance: appearance, name: "\(session.id.rawValue)-\(tab.rawValue)-gpu-unknown-\(suffix)")
                }
            }

            // The confirmations' wording (the system dialog itself cannot be
            // rendered offscreen): route change, disconnect, reconnect.
            for (name, confirmation) in PreviewModels.sampleConfirmations {
                try render(
                    ConfirmationCopyPreview(confirmation: confirmation),
                    size: CGSize(width: 420, height: 400),
                    appearance: appearance,
                    name: "confirm-\(name)-\(suffix)"
                )
            }

            // Calder not signed in (never connected), signing in, loading.
            let partial = makeModel()
            if let calder = partial.session(for: .calder) {
                PreviewModels.SignInState.notConnected.install(on: calder)
                partial.selection = .overview
                try render(ContentView(model: partial), size: Self.comfortable, appearance: appearance, name: "overview-calder-not-connected-\(suffix)")
                partial.selection = .cluster(.calder)
                try render(ContentView(model: partial), size: Self.comfortable, appearance: appearance, name: "calder-hero-not-connected-\(suffix)")
                PreviewModels.SignInState.signingIn.install(on: calder)
                try render(ContentView(model: partial), size: Self.comfortable, appearance: appearance, name: "calder-hero-signing-in-\(suffix)")
                PreviewModels.SignInState.loadingFirstSnapshot.install(on: calder)
                try render(ContentView(model: partial), size: Self.comfortable, appearance: appearance, name: "calder-hero-loading-\(suffix)")
                PreviewModels.SignInState.setupProblem.install(on: calder)
                try renderDetail(model: partial, session: calder, size: Self.comfortableDetail, appearance: appearance, name: "calder-hero-setup-problem-\(suffix)")
                // The sidebar with the full sign-in form (not everything
                // is live) and a pending setup error.
                PreviewModels.SignInState.notConnected.install(on: calder)
                partial.selection = .cluster(.calder)
                try render(
                    ConnectionSidebar(model: partial).environment(\.colorScheme, appearance == .darkAqua ? .dark : .light),
                    size: CGSize(width: 360, height: 1500),
                    appearance: appearance,
                    name: "sidebar-sign-in-\(suffix)"
                )
                // The menu bar while Calder is signed in but has no snapshot yet.
                try render(MenuBarMonitorView(model: partial, closeMenu: {}).fixedSize(horizontal: false, vertical: true), size: CGSize(width: 400, height: 900), appearance: appearance, name: "menubar-partial-\(suffix)")
            }
        }
    }

    @Test("Render the Sessions card, Resource use and a job's usage")
    func renderSessionsAndUsage() throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let now = Date()
        let report = SessionSharingReport(
            sessions: [
                SharedSessionStatus(name: "rash", displayName: "rash", socketPath: "/tmp/jump.sock", stableLinkPath: "/tmp/rash.sock", since: now.addingTimeInterval(-23 * 3600 - 300)),
                SharedSessionStatus(name: "aire", displayName: "AIRE", socketPath: "/tmp/aire.sock", stableLinkPath: "/tmp/aire.sock", since: now.addingTimeInterval(-10 * 3600 - 49 * 60))
            ],
            aliases: [
                SharedAliasStatus(alias: "aire", sessionName: "aire", state: .linked),
                SharedAliasStatus(alias: "rash", sessionName: "rash", state: .linked),
                SharedAliasStatus(alias: "aire-rash", sessionName: "aire", state: .heldByOtherSession(since: now.addingTimeInterval(-36_000)))
            ],
            isSharing: true
        )
        let jobs = [
            Job(jobId: "489997", partition: "calder-gpu-hopper", name: "train-llm", state: "RUNNING", elapsed: "3:12:09", nodes: "1", tresPerNode: "gres/gpu:nvidia_h200:4"),
            Job(jobId: "490008", partition: "calder-cpu-turin", name: "preprocess", state: "RUNNING", elapsed: "0:42:10", nodes: "1"),
            Job(jobId: "490032", partition: "calder-gpu-hopper", name: "eval", state: "PENDING", nodes: "1", tresPerNode: "gres/gpu:nvidia_h200:1")
        ]
        func gpu(_ index: Int, _ utilization: Double, _ memory: Double) -> GPUUsage {
            GPUUsage(index: index, name: "NVIDIA H200", utilizationPercent: utilization, memoryUsedMB: memory, memoryTotalMB: 143_771, powerWatts: 120 + utilization * 5.5, temperatureC: 38 + utilization / 3)
        }
        let rows = [
            JobNodeUsage(jobID: "489997", displayID: "489997", node: "calder-h200-03", cpusAllocated: 64, cpusBusy: 9.4,
                         memoryUsedMB: 98_000, memoryPeakMB: 120_000, memoryLimitMB: 512_000, gpuIndices: [0, 1, 2, 3],
                         gpus: [gpu(0, 97, 121_000), gpu(1, 1, 600), gpu(2, 0, 600), gpu(3, 95, 118_000)]),
            JobNodeUsage(jobID: "490008", displayID: "490008", node: "calder-cpu-12", cpusAllocated: 32, cpusBusy: 30.1,
                         memoryUsedMB: 40_000, memoryPeakMB: 52_000, memoryLimitMB: 128_000)
        ]
        let usage = JobUsageSummary.summaries(from: rows, sampledAt: now.addingTimeInterval(-25))
        var history = JobUsageHistory()
        for minute in stride(from: 90, through: 0, by: -1) {
            let wobble = Double((minute * 37) % 23) - 11
            let sample = JobUsageSummary.summaries(from: [
                JobNodeUsage(jobID: "489997", displayID: "489997", node: "calder-h200-03", cpusAllocated: 64, cpusBusy: 9 + wobble / 4,
                             memoryUsedMB: 98_000, memoryLimitMB: 512_000, gpuIndices: [0, 1, 2, 3],
                             gpus: [gpu(0, 90 + wobble / 2, 121_000), gpu(1, 1, 600), gpu(2, 0, 600), gpu(3, 88 + wobble / 2, 118_000)])
            ], sampledAt: now.addingTimeInterval(Double(-minute) * 60))
            history.record(sample, running: ["489997", "490008"])
        }
        let profile = ClusterProfile.calder
        let jobRows = JobRow.rows(for: jobs, profile: profile)

        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let suffix = appearance == .darkAqua ? "dark" : "light"
            let model = makeModel()
            model.installPreviewSharing(
                report,
                drops: [.calder: SessionDrop(at: now.addingTimeInterval(-600), lasted: 3 * 3600 + 610)],
                dropped: [.calder]
            )
            model.sessions.first { $0.id == .calder }?.installPreviewState(snapshot: nil, isLoggedIn: false)
            try render(
                SessionsCard(model: model, confirmation: .constant(nil))
                    .padding(16)
                    .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light),
                size: CGSize(width: 360, height: 420),
                appearance: appearance,
                name: "sessions-card-\(suffix)"
            )
            try render(
                ScrollView {
                    JobUsagePanel(rows: jobRows, usage: usage, history: history, isSampling: .constant(true), onSelect: { _ in })
                        .padding(18)
                },
                size: CGSize(width: 1000, height: 420),
                appearance: appearance,
                name: "calder-job-usage-\(suffix)"
            )
            let sheet = JobDetailView(
                profile: profile,
                job: jobs[0],
                usage: usage["489997"],
                usageSeries: history.series(for: "489997"),
                isSamplingUsage: true,
                onTailOutput: { _ in },
                onCancelJob: { _ in },
                onBrowseWorkDir: { _ in }
            )
            try render(sheet, size: CGSize(width: 720, height: 1100), appearance: appearance, name: "calder-job-sheet-usage-\(suffix)")
        }
    }

    @Test("Render the Files tab over a fake remote")
    func renderFiles() async throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            try await renderFilesTab(appearance: appearance, name: "aire-files-fake-\(appearance == .darkAqua ? "dark" : "light")")
        }
    }

    // MARK: Fixtures

    /// Real data from HPC_PREVIEW_DATA where present, fixtures otherwise.
    /// Fixtures are re-stamped to "just now", so headers read "updated just
    /// now" and the Trends window (relative to the clock) holds their
    /// history instead of "No data in this window".
    private func makeModel() -> AppModel {
        let now = Date().addingTimeInterval(-20)
        return PreviewModels.model(snapshot: { id in
            loadSnapshot(id) ?? CoreFixtures.snapshot(for: id).map { PreviewModels.restamped($0, at: now) }
        }) { session, snapshot in
            let history = loadHistory(session.id)
            session.installPreviewState(
                snapshot: snapshot,
                history: history.isEmpty ? snapshot.map { PreviewModels.history(from: $0) } ?? [] : history,
                isLoggedIn: snapshot != nil,
                statusMessage: snapshot == nil ? "Not signed in to \(session.displayName)" : "Last refresh 11:30:00"
            )
        }
    }

    private func loadSnapshot(_ id: ClusterID) -> ClusterSnapshot? {
        guard let dataDirectory,
              let data = try? Data(contentsOf: URL(fileURLWithPath: "\(dataDirectory)/\(id.rawValue)/latest_snapshot.json")) else {
            return nil
        }
        return try? JSONDecoder().decode(ClusterSnapshot.self, from: data)
    }

    /// The app's history log (one TrendPoint per line), or the legacy JSON
    /// array a cache from an older build may still hold.
    private func loadHistory(_ id: ClusterID) -> [TrendPoint] {
        guard let dataDirectory else {
            return []
        }
        let decoder = JSONDecoder()
        let directory = "\(dataDirectory)/\(id.rawValue)"
        if let log = try? String(contentsOfFile: "\(directory)/snapshot_history.jsonl", encoding: .utf8) {
            return log.split(separator: "\n").compactMap { line in
                try? decoder.decode(TrendPoint.self, from: Data(line.utf8))
            }
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "\(directory)/snapshot_history.json")) else {
            return []
        }
        return (try? decoder.decode([TrendPoint].self, from: data)) ?? []
    }

    // MARK: Rendering

    /// Each failure kind's strip on its own, Details open.
    private func renderStrips(appearance: NSAppearance.Name, suffix: String) throws {
        for state in PreviewModels.FailureState.allCases {
            guard let content = ClusterStatusContent.make(state.input(clusterName: "Calder")) else {
                continue
            }
            try render(
                StatusStripView(content: content, clusterName: "Calder", initiallyExpanded: true)
                    .padding(16)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(DashboardBackdrop()),
                size: CGSize(width: 760, height: 260),
                appearance: appearance,
                name: "strip-\(state.rawValue)-details-\(suffix)"
            )
        }
    }

    /// One cluster's dashboard on its own, as the detail column shows it.
    /// Avoids the full window's blank sidebar column and its occasional
    /// dropped header row (both layer-render artefacts).
    private func renderDetail(model: AppModel, session: ClusterSession, size: CGSize, appearance: NSAppearance.Name, name: String) throws {
        model.selection = .cluster(session.id)
        try render(
            ClusterDashboardView(model: model, session: session).background(DashboardBackdrop()),
            size: size,
            appearance: appearance,
            name: name
        )
    }

    /// The Files tab driven by a fake remote runner: a home folder with
    /// folders and files, and a capped listing so the footer shows. Nothing
    /// runs: the fake answers every script, and downloads go to a
    /// throwaway directory.
    private func renderFilesTab(appearance: NSAppearance.Name, name: String) async throws {
        let home = "/users/abcd1234"
        let runner = FakeRemoteRunner { script, arguments, _ in
            switch script {
            case "roots":
                return ok(["home": home, "roots": [home, "/mnt/scratch/abcd1234"]])
            case "listing":
                return ok(PreviewModels.filesListing(arguments.first ?? home))
            default:
                return ProcessResult(stdout: "", stderr: "not available in previews", exitCode: 1)
            }
        }
        let model = makeModel()
        let session = try #require(model.session(for: .aire))
        let files = FileBrowserModel(service: RemoteFileService(runner: runner))
        files.activity.downloadsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hpc-preview-downloads-\(UUID().uuidString)")
        files.attach(session: session)
        files.openHome()
        // Yield the main actor (spinning the run loop would not): the
        // model's tasks run on it.
        let deadline = Date().addingTimeInterval(5)
        while files.listing == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(files.listing != nil, "the fake listing never arrived: \(files.banner?.message ?? "no banner")")
        try render(
            FilesDashboard(session: session, files: files)
                .padding(18)
                .background(DashboardBackdrop()),
            size: Self.comfortableDetail,
            appearance: appearance,
            name: name
        )
    }

    /// Hosts `view` in a borderless window parked off-screen, lets SwiftUI
    /// and AppKit lay out for a moment, then renders the layer tree.
    private func render<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, name: String) throws {
        let hosted = LayoutHost.host(view, size: size, appearance: appearance, settle: 1.2)
        defer { hosted.window.orderOut(nil) }
        let host = hosted.view

        let scale: CGFloat = 2
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            context.cgContext.setFillColor(NSColor.windowBackgroundColor.cgColor)
        }
        context.cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.cgContext.scaleBy(x: scale, y: scale)
        context.cgContext.translateBy(x: 0, y: size.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        try #require(host.layer).render(in: context.cgContext)

        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }
}

// MARK: - Preview models

/// Coordinators wired to preview sessions: no preferences or Keychain
/// access, no notification prompt, no refresh timers, no SSH.
@MainActor
enum PreviewModels {
    /// A model whose clusters start from the given snapshots; `configure`
    /// installs each session's state.
    static func model(
        snapshot: (ClusterID) -> ClusterSnapshot?,
        configure: (ClusterSession, ClusterSnapshot?) -> Void
    ) -> AppModel {
        let sessions = ClusterCatalog.all.map { profile in
            ClusterSession(profile: profile, isEnabled: true, hostname: nil)
        }
        let model = AppModel(
            previewSessions: sessions,
            projectRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("hpc-preview-root-\(UUID().uuidString)").path
        )
        for session in sessions {
            configure(session, snapshot(session.id))
        }
        return model
    }

    /// A model built from the checked-in fixtures (AIRE plus multi-model
    /// Calder), so layout assertions never depend on whatever is cached on
    /// the machine running the tests.
    static func fixtureModel(configure: (ClusterSession, ClusterSnapshot) -> Void) -> AppModel {
        model(snapshot: { CoreFixtures.snapshot(for: $0) }) { session, snapshot in
            guard let snapshot else {
                preconditionFailure("no fixture snapshot for \(session.id)")
            }
            configure(session, snapshot)
        }
    }

    /// An hour of one-minute trend points ending at the snapshot, with a
    /// queue that builds up to the snapshot's so the charts have shape.
    static func history(from snapshot: ClusterSnapshot, points: Int = 60) -> [TrendPoint] {
        let end = SlurmTimestamp.parse(snapshot.collectedAt) ?? Date(timeIntervalSince1970: 1_791_892_185)
        let formatter = ISO8601DateFormatter()
        return (0..<points).map { index in
            let minutesBefore = points - 1 - index
            let jobs = Array(snapshot.jobs.prefix(snapshot.jobs.count - minutesBefore * snapshot.jobs.count / points))
            let point = ClusterSnapshot(
                collectedAt: formatter.string(from: end.addingTimeInterval(TimeInterval(-60 * minutesBefore))),
                cluster: snapshot.cluster,
                remote: snapshot.remote,
                jobs: jobs,
                partitions: snapshot.partitions,
                nodes: snapshot.nodes,
                storage: snapshot.storage
            )
            return TrendPoint(snapshot: point)
        }
    }

    /// `snapshot` as it arrives when the collector's `scontrol show node`
    /// section failed: every node without GPU allocation figures (and the
    /// other node-detail fields), so all GPU allocation is unknown.
    static func withoutNodeDetails(_ snapshot: ClusterSnapshot) -> ClusterSnapshot {
        let nodes = snapshot.nodes.map { node in
            NodeSummary(
                node: node.node,
                partitions: node.partitions,
                state: node.state,
                cpuAllocated: node.cpuAllocated,
                cpuIdle: node.cpuIdle,
                cpuOther: node.cpuOther,
                cpuTotal: node.cpuTotal,
                memoryMB: node.memoryMB,
                gres: node.gres,
                features: node.features,
                reason: node.reason
            )
        }
        return ClusterSnapshot(
            schemaVersion: snapshot.schemaVersion,
            collectedAt: snapshot.collectedAt,
            startedAt: snapshot.startedAt,
            durationMs: snapshot.durationMs,
            timings: snapshot.timings,
            storageSkipped: snapshot.storageSkipped,
            cluster: snapshot.cluster,
            remote: snapshot.remote,
            jobs: snapshot.jobs,
            partitions: snapshot.partitions,
            nodes: nodes,
            storage: snapshot.storage,
            errors: snapshot.errors,
            warnings: snapshot.warnings + ["Section 'node_details' failed: scontrol: error: Socket timed out on send/recv operation"]
        )
    }

    /// Live, with node details missing from the current snapshot and from
    /// the last quarter of the history, so the GPU charts end in a gap.
    static func installUnknownGPUAllocation(on session: ClusterSession, snapshot: ClusterSnapshot) {
        let stripped = withoutNodeDetails(snapshot)
        let known = history(from: snapshot)
        let unknown = history(from: stripped)
        let split = known.count * 3 / 4
        session.installPreviewState(
            snapshot: stripped,
            history: Array(known.prefix(split)) + Array(unknown.suffix(unknown.count - split)),
            isLoggedIn: true,
            statusMessage: "Last refresh 11:49:50"
        )
    }

    /// The confirmations the route picker, Disconnect and Reconnect show,
    /// with terminals and transfers running.
    static var sampleConfirmations: [(String, SessionActionConfirmation)] {
        let aire = SessionWork(clusterID: .aire, clusterName: "AIRE", isLive: true, runningTerminals: 2, activeTransfers: 1)
        let calder = SessionWork(clusterID: .calder, clusterName: "Calder", isLive: true)
        return [
            ("route", SessionActionConfirmation(kind: .changeRoute(.rashJump), work: [aire, calder], usesJumpHost: true)),
            ("disconnect-transfer", SessionActionConfirmation(
                kind: .disconnect,
                work: [SessionWork(clusterID: .aire, clusterName: "AIRE", isLive: true, activeTransfers: 1)],
                usesJumpHost: false
            )),
            ("reconnect", SessionActionConfirmation(kind: .reconnect, work: [aire, calder], usesJumpHost: false))
        ]
    }

    /// `snapshot` with `collectedAt` moved to `date`; everything else kept.
    static func restamped(_ snapshot: ClusterSnapshot, at date: Date) -> ClusterSnapshot {
        ClusterSnapshot(
            schemaVersion: snapshot.schemaVersion,
            collectedAt: ISO8601DateFormatter().string(from: date),
            startedAt: snapshot.startedAt,
            durationMs: snapshot.durationMs,
            timings: snapshot.timings,
            storageSkipped: snapshot.storageSkipped,
            cluster: snapshot.cluster,
            remote: snapshot.remote,
            jobs: snapshot.jobs,
            partitions: snapshot.partitions,
            nodes: snapshot.nodes,
            storage: snapshot.storage,
            errors: snapshot.errors,
            warnings: snapshot.warnings
        )
    }

    /// A listing payload for the Files render: folders first in the data,
    /// files with sizes and ages, capped so the "showing N of M" footer
    /// appears.
    nonisolated static func filesListing(_ path: String) -> [String: Any] {
        let now = Date().timeIntervalSince1970
        let folders = ["checkpoints", "datasets", "envs", "logs", "notebooks", "src"]
        let files: [(String, Int)] = [
            ("README.md", 4_812), ("environment.yml", 1_204), ("finetune.sbatch", 2_390),
            ("slurm-8248307_0.out", 18_734_112), ("slurm-8248307_1.out", 17_002_441),
            ("results.csv", 7_340_032), ("model.ckpt", 3_221_225_472)
        ]
        var entries: [[String: Any]] = folders.enumerated().map { index, name in
            ["name": name, "kind": "directory", "size": 4096, "mtime": now - Double(index) * 7_200 - 120, "owner": "abcd1234", "mode": "rwxr-xr-x", "lossy": false]
        }
        entries += files.enumerated().map { index, file in
            ["name": file.0, "kind": "file", "size": file.1, "mtime": now - Double(index) * 5_400 - 600, "owner": "abcd1234", "mode": "rw-r--r--", "lossy": false]
        }
        return [
            "requested": path,
            "resolved": path,
            "truncated": true,
            "total": 2_413,
            "matched": entries.count,
            "filter": "",
            "entries": entries
        ]
    }

    /// The three refresh failure kinds, as the status strip shows them.
    enum FailureState: String, CaseIterable, Sendable {
        /// Local setup: the collector script is missing. Session live.
        case configuration
        /// Slurm failing over a live session.
        case clusterSide
        /// The connection is gone; showing the cached snapshot.
        case transport

        func failure(clusterName: String) -> RefreshFailure {
            let date = Date(timeIntervalSince1970: 1_791_892_185)
            switch self {
            case .configuration:
                return RefreshFailure(
                    kind: .configuration,
                    message: "Collector script missing at ~/hpc-monitor/scripts/hpc_snapshot.py",
                    detail: "python3: can't open file '/Users/me/hpc-monitor/scripts/hpc_snapshot.py': [Errno 2] No such file or directory",
                    consecutiveCount: 3,
                    date: date
                )
            case .clusterSide:
                return RefreshFailure(
                    kind: .clusterSide,
                    message: "Slurm error on \(clusterName): Section 'jobs' failed with exit 1",
                    detail: "squeue: error: slurm_load_jobs error: Socket timed out on send/recv operation\nSection 'jobs' failed with exit 1",
                    consecutiveCount: 2,
                    date: date
                )
            case .transport:
                return RefreshFailure(
                    kind: .transport,
                    message: "\(clusterName) did not answer: the connection timed out",
                    detail: "ssh: connect to host \(clusterName.lowercased())-login.leeds.ac.uk port 22: Operation timed out\nmux_client_request_session: read from master failed: Broken pipe",
                    consecutiveCount: 4,
                    date: date
                )
            }
        }

        /// Still signed in for setup and Slurm problems; logged out (stale,
        /// Connect offered) after repeated transport failures.
        var isLoggedIn: Bool {
            self != .transport
        }

        @MainActor
        func install(on session: ClusterSession, snapshot: ClusterSnapshot) {
            session.installPreviewState(
                snapshot: snapshot,
                history: PreviewModels.history(from: snapshot),
                isLoggedIn: isLoggedIn,
                statusMessage: isLoggedIn ? "Retrying every 40s" : "Cached snapshot offline • retrying every 80s",
                lastRefreshFailure: failure(clusterName: session.displayName)
            )
        }

        /// The strip's input for this state without a session.
        func input(clusterName: String) -> ClusterStatusInput {
            ClusterStatusInput(
                displayName: clusterName,
                phase: isLoggedIn ? .live : .stale,
                presentationDetail: "",
                primaryAction: isLoggedIn ? nil : .connect,
                statusMessage: "Retrying",
                failure: failure(clusterName: clusterName),
                refreshIntervalText: "40s"
            )
        }
    }

    /// Cluster screens shown before the first snapshot.
    enum SignInState: String, CaseIterable, Sendable {
        case notConnected
        case signingIn
        case loadingFirstSnapshot
        case failed
        /// Not connected, and the startup probe failed for a reason no
        /// sign-in can fix (the hero shows it).
        case setupProblem

        @MainActor
        func install(on session: ClusterSession) {
            let name = session.displayName
            switch self {
            case .notConnected:
                session.installPreviewState(snapshot: nil, isLoggedIn: false, statusMessage: "Not signed in to \(name)")
            case .signingIn:
                session.installPreviewState(
                    snapshot: nil, isLoggedIn: false, isLoggingIn: true,
                    loginProgress: "waiting for Duo approval on your phone (\(name))"
                )
            case .loadingFirstSnapshot:
                session.installPreviewState(snapshot: nil, isLoggedIn: true, statusMessage: "Connected to \(name.lowercased())-login-2")
            case .failed:
                session.installPreviewState(
                    snapshot: nil, isLoggedIn: false,
                    statusMessage: "Not signed in to \(name)",
                    errorMessage: "\(name) rejected the password or the Duo approval timed out. Check the password saved in Settings, then use Connect to try again."
                )
            case .setupProblem:
                session.installPreviewState(
                    snapshot: nil, isLoggedIn: false,
                    statusMessage: "Not signed in to \(name)",
                    lastRefreshFailure: FailureState.configuration.failure(clusterName: name)
                )
            }
        }
    }

    /// Overview situations: both clusters live, or one live and one signing in.
    enum OverviewState: String, CaseIterable, Sendable {
        case allLive
        case calderSigningIn
        case calderNotConnected

        @MainActor
        func install(on session: ClusterSession, snapshot: ClusterSnapshot) {
            switch (self, session.id) {
            case (.calderSigningIn, .calder):
                SignInState.signingIn.install(on: session)
            case (.calderNotConnected, .calder):
                SignInState.notConnected.install(on: session)
            default:
                session.installPreviewState(
                    snapshot: snapshot,
                    history: PreviewModels.history(from: snapshot),
                    isLoggedIn: true,
                    statusMessage: "Last refresh 11:49:50"
                )
            }
        }
    }
}

// MARK: - Hosting and measuring

/// What a view needs at a given width.
struct LayoutMeasurement {
    let width: CGFloat
    /// The width SwiftUI asks for when offered `width`; more is overflow.
    let requiredWidth: CGFloat
    /// AppKit-backed pieces (scroll views, controls) laid out outside the
    /// column, with their horizontal extent.
    let escapedViews: [String]

    var fits: Bool {
        requiredWidth <= width + 0.5 && escapedViews.isEmpty
    }

    var problem: String {
        var parts: [String] = []
        if requiredWidth > width + 0.5 {
            parts.append("needs \(Int(requiredWidth.rounded(.up))) pt but the detail column at the minimum window size is \(Int(width)) pt")
        }
        if !escapedViews.isEmpty {
            parts.append("laid out past the column edge: " + escapedViews.joined(separator: ", "))
        }
        return parts.isEmpty ? "fits" : parts.joined(separator: "; ")
    }
}

enum LayoutHost {
    /// Hosting AppKit views needs a window server connection: present in a
    /// logged-in session (and on CI's macOS runners), absent over plain ssh.
    static var windowServerAvailable: Bool {
        CGSessionCopyCurrentDictionary() != nil
    }

    /// Hosts `view` in a borderless window parked off-screen and lets
    /// SwiftUI and AppKit settle for `settle` seconds.
    @MainActor
    static func host<V: View>(
        _ view: V,
        size: CGSize,
        appearance: NSAppearance.Name = .darkAqua,
        settle: TimeInterval
    ) -> (window: NSWindow, view: NSHostingView<some View>) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderFrontRegardless()
        host.wantsLayer = true
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    /// Measures `view` two ways: the width SwiftUI requests when offered
    /// `width` (an overflowing header or segmented control raises it, even
    /// inside the dashboards' vertical ScrollView), and, hosted at exactly
    /// `width`, whether any AppKit-backed scroll view or control ends up
    /// outside the column.
    @MainActor
    static func measure<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> LayoutMeasurement {
        _ = NSApplication.shared
        let controller = NSHostingController(rootView: view)
        let required = controller.sizeThatFits(in: CGSize(width: width, height: 10_000)).width

        let hosted = host(view, size: CGSize(width: width, height: height), settle: 0.15)
        defer { hosted.window.orderOut(nil) }
        var escaped: [String] = []
        collectEscapedViews(in: hosted.view, root: hosted.view, width: width, into: &escaped)
        return LayoutMeasurement(width: width, requiredWidth: required, escapedViews: escaped)
    }

    /// Scroll views and controls outside [0, width]. Content inside a scroll
    /// view's document is skipped: being scrolled out of view is its job.
    @MainActor
    private static func collectEscapedViews(in view: NSView, root: NSView, width: CGFloat, into escaped: inout [String]) {
        for subview in view.subviews where !subview.isHidden && subview.frame.width > 0 {
            if subview is NSScrollView || subview is NSControl {
                let frame = subview.convert(subview.bounds, to: root)
                if frame.minX < -0.5 || frame.maxX > width + 0.5 {
                    escaped.append("\(type(of: subview)) \(Int(frame.minX.rounded()))…\(Int(frame.maxX.rounded())) pt")
                }
            }
            if subview is NSScrollView {
                continue
            }
            collectEscapedViews(in: subview, root: root, width: width, into: &escaped)
        }
    }
}

/// Draws a `SessionActionConfirmation` the way the system confirmation
/// dialog lays it out (title, message, destructive and cancel buttons), for
/// reviewing its wording in a render: the real dialog is a separate window
/// that offscreen rendering cannot capture.
private struct ConfirmationCopyPreview: View {
    let confirmation: SessionActionConfirmation

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text(confirmation.title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(confirmation.message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                Button(confirmation.confirmTitle, role: .destructive) {}
                    .frame(maxWidth: .infinity)
                Button("Cancel", role: .cancel) {}
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DashboardBackdrop())
    }
}
