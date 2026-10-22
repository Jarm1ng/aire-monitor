import HPCCore
import Foundation
import Testing
@testable import AIREMonitorApp

// Runs the embedded remote scripts (`RemoteFileScripts`) against this
// Mac's /usr/bin/python3 in isolated mode, exactly as the login node runs
// them, on throwaway directories. Catches syntax and Python-version slips
// and pins the behaviours that make deletes and listings safe. HOME is
// pointed at the temp directory, so nothing outside it is touched.

private let python = "/usr/bin/python3"

private var pythonAvailable: Bool {
    guard FileManager.default.isExecutableFile(atPath: python),
          FileManager.default.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/python3")
            || FileManager.default.fileExists(atPath: "/Applications/Xcode.app") else {
        return false
    }
    return true
}

/// One script run that outlived `scriptTimeLimit` (and was killed).
private struct ScriptTimedOut: Error, CustomStringConvertible {
    let seconds: TimeInterval
    var description: String { "the script was still running after \(Int(seconds)) s and was killed" }
}

/// Collects one pipe to EOF on a background thread.
private final class PipeDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var collected = Data()

    var data: Data {
        lock.withLock { collected }
    }

    func start(_ handle: FileHandle, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global().async {
            let data = handle.readDataToEndOfFile()
            self.lock.withLock { self.collected = data }
            group.leave()
        }
    }
}

private let scriptTimeLimit: TimeInterval = 60

/// Runs `python3 -I -c <script> <arguments…>` with HOME set, bounded: both
/// pipes are drained concurrently (a script writing a lot to stderr can
/// never block on a full pipe with stdout still open), and a script still
/// running after `scriptTimeLimit` is killed and fails the test instead of
/// hanging the whole serialized suite.
private func runScript(
    _ script: String,
    _ arguments: [String],
    home: URL,
    environment extra: [String: String] = [:],
    timeLimit: TimeInterval = scriptTimeLimit
) throws -> [[String: Any]] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: python)
    process.arguments = ["-I", "-c", script] + arguments
    var environment = ProcessInfo.processInfo.environment
    // swift test runs under xcrun, which exports SDKROOT; with it set,
    // /usr/bin/python3 on a Mac with full Xcode (CI) resolves itself through
    // xcodebuild on every call, which can stall for a minute.
    environment.removeValue(forKey: "SDKROOT")
    environment["HOME"] = home.path
    for (key, value) in extra {
        environment[key] = value
    }
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let pipes = DispatchGroup()
    let stdout = PipeDrain()
    stdout.start(output.fileHandleForReading, group: pipes)
    PipeDrain().start(errors.fileHandleForReading, group: pipes)
    if pipes.wait(timeout: .now() + timeLimit) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        throw ScriptTimedOut(seconds: timeLimit)
    }
    process.waitUntilExit()
    return String(decoding: stdout.data, as: UTF8.self)
        .split(separator: "\n")
        .compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
}

private struct Sandbox {
    let root: URL

    init() throws {
        // Resolve /var -> /private/var up front, as realpath does remotely
        // (URL.resolvingSymlinksInPath would strip /private again).
        guard let resolved = realpath(NSTemporaryDirectory(), nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        defer { free(resolved) }
        let base = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        root = base.appendingPathComponent("hpc-scripts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func path(_ relative: String) -> String {
        root.appendingPathComponent(relative).path
    }

    @discardableResult
    func make(_ relative: String, contents: String = "x") throws -> String {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url.path
    }

    func directory(_ relative: String) throws -> String {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Embedded remote scripts", .enabled(if: pythonAvailable), .serialized, .timeLimit(.minutes(3)))
struct FileScriptTests {
    @Test("Every script compiles under python3 -I")
    func compiles() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let checker = "import sys\ncompile(sys.argv[1], 'script', 'exec')\nprint('{\"ok\": true}')"
        for script in [
            RemoteFileScripts.listing, RemoteFileScripts.preview, RemoteFileScripts.roots,
            RemoteFileScripts.trashInspect, RemoteFileScripts.trashExecute, RemoteFileScripts.jobStart,
            RemoteFileScripts.jobPoll, RemoteFileScripts.trashList, RemoteFileScripts.trashRestore,
            RemoteFileScripts.jobWorker
        ] {
            let result = try runScript(checker, [script], home: sandbox.root)
            #expect(result.first?["ok"] as? Bool == true)
        }
    }

    @Test("Listing sorts before capping, so the cap keeps the first names, and counts everything")
    func listingCap() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let folder = try sandbox.directory("logs")
        for index in 1...4005 {
            FileManager.default.createFile(atPath: "\(folder)/slurm-\(index).out", contents: nil)
        }
        try sandbox.make("logs/.hidden")
        try sandbox.make("logs/-rf")
        try sandbox.make("logs/new\nline")
        _ = try sandbox.directory("logs/zdir")

        let result = try runScript(RemoteFileScripts.listing, [folder, "0", "4000"], home: sandbox.root)
        let payload = try #require(result.first)
        let names = (payload["entries"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        #expect(payload["truncated"] as? Bool == true)
        #expect(payload["total"] as? Int == 4008)
        #expect(names.count == 4000)
        #expect(names.first == "zdir")                  // folders first
        #expect(names.contains("-rf"))
        #expect(names.contains("new\nline"))
        #expect(names.contains("slurm-2500.out"))       // natural order: 1…3997 kept
        #expect(!names.contains("slurm-4005.out"))
        #expect(!names.contains(".hidden"))

        let filtered = try #require(try runScript(RemoteFileScripts.listing, [folder, "0", "4000", "SLURM-4005"], home: sandbox.root).first)
        let filteredNames = (filtered["entries"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        #expect(filteredNames == ["slurm-4005.out"])
        #expect(filtered["matched"] as? Int == 1)
        #expect(filtered["truncated"] as? Bool == false)
    }

    @Test("Listing a missing folder reports an error object")
    func listingErrors() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let result = try runScript(RemoteFileScripts.listing, [sandbox.path("nope"), "0", "10"], home: sandbox.root)
        #expect((result.first?["error"] as? String)?.hasPrefix("No such directory") == true)
    }

    @Test("Preview reads the tail without its partial first line and refuses FIFOs")
    func preview() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let log = try sandbox.make("job.out", contents: (0..<5000).map { "line \($0)\n" }.joined())
        let tail = try #require(try runScript(RemoteFileScripts.preview, [log, "100", "tail"], home: sandbox.root).first)
        let data = Data(base64Encoded: tail["data"] as? String ?? "") ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        #expect(tail["from_end"] as? Bool == true)
        #expect(tail["truncated"] as? Bool == true)
        #expect(text.hasPrefix("line "))
        #expect(text.hasSuffix("line 4999\n"))

        let json = try sandbox.make("metrics.json", contents: "{\"loss\": 0.1}\n")
        let jsonPreview = try #require(try runScript(RemoteFileScripts.preview, [json, "1000", "head"], home: sandbox.root).first)
        #expect(jsonPreview["truncated"] as? Bool == false)
        if jsonPreview["has_file"] as? Bool == true {
            #expect(jsonPreview["charset"] as? String != "binary")
        }

        let fifo = sandbox.path("pipe")
        #expect(mkfifo(fifo, 0o600) == 0)
        let refused = try runScript(RemoteFileScripts.preview, [fifo, "10", "head"], home: sandbox.root)
        #expect((refused.first?["error"] as? String)?.contains("not a regular file") == true)
    }

    @Test("Trash pre-flight refuses home and its ancestors, including through a symlinked parent")
    func trashRefusals() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let scratch = try sandbox.directory("scratch")
        try FileManager.default.createSymbolicLink(atPath: sandbox.path("alias"), withDestinationPath: sandbox.root.path)
        let result = try runScript(
            RemoteFileScripts.trashInspect,
            ["--run", "R", "--trash-name", ".aire-trash", "--roots", scratch, "--targets", sandbox.path("alias/scratch"), sandbox.root.path],
            home: sandbox.root
        )
        let refused = result.first?["refused"] as? [[String: Any]] ?? []
        #expect(refused.count == 2)
    }

    @Test("Trash moves by rename, records a manifest, lists and restores")
    func trashRoundTrip() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let file = try sandbox.make("proj/result.csv")
        let folder = try sandbox.directory("proj/run1")
        let inspect = try #require(try runScript(
            RemoteFileScripts.trashInspect,
            ["--run", "R1", "--trash-name", ".aire-trash", "--roots", "--targets", file, folder],
            home: sandbox.root
        ).first)
        #expect((inspect["refused"] as? [Any])?.isEmpty == true)
        #expect(inspect["home_device"] as? String != nil)

        let trashRun = sandbox.path(".aire-trash/R1")
        let execute = try runScript(
            RemoteFileScripts.trashExecute,
            ["--run", "R1", "--cluster", "calder", "--created", "2026-10-13T10:00:00Z", "--trash-name", ".aire-trash",
             "--group", trashRun, "home", file, folder, sandbox.path("proj/missing")],
            home: sandbox.root
        )
        #expect(execute.filter { $0["moved"] != nil }.count == 2)
        #expect(execute.contains { ($0["failed"] as? String)?.hasSuffix("missing") == true })
        #expect(execute.last?["done"] as? Bool == true)
        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(FileManager.default.fileExists(atPath: trashRun + "/result.csv"))

        let listed = try #require(try runScript(RemoteFileScripts.trashList, ["--cluster", "calder", "--trash-name", ".aire-trash"], home: sandbox.root).first)
        let runs = listed["runs"] as? [[String: Any]] ?? []
        #expect(runs.count == 1)
        let entries = runs.first?["entries"] as? [[String: Any]] ?? []
        #expect(entries.compactMap { $0["original"] as? String }.sorted() == [file, folder].sorted())

        let restore = try runScript(
            RemoteFileScripts.trashRestore,
            ["--run", trashRun, "--trash-name", ".aire-trash", "--pairs", trashRun + "/result.csv", file, trashRun + "/run1", folder],
            home: sandbox.root
        )
        #expect(restore.filter { $0["restored"] != nil }.count == 2)
        #expect(restore.last?["removed_run"] as? Bool == true)
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(!FileManager.default.fileExists(atPath: trashRun))
    }

    @Test("Restore never overwrites an existing name")
    func restoreNoClobber() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let trashRun = try sandbox.directory(".aire-trash/R2")
        try sandbox.make(".aire-trash/R2/a.txt", contents: "old")
        let original = try sandbox.make("a.txt", contents: "new")
        let restore = try runScript(
            RemoteFileScripts.trashRestore,
            ["--run", trashRun, "--trash-name", ".aire-trash", "--pairs", trashRun + "/a.txt", original],
            home: sandbox.root
        )
        #expect((restore.first?["error"] as? String)?.contains("already exists") == true)
        #expect(try String(contentsOfFile: original, encoding: .utf8) == "new")
    }

    @Test("A background delete runs detached, reports progress and can be refused")
    func backgroundDelete() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.make("w/big/sub/f1")
        let small = try sandbox.make("w/y")
        let refused = try runScript(
            RemoteFileScripts.jobStart,
            ["--worker", RemoteFileScripts.jobWorker, "--mode", "delete", "--roots", sandbox.path("w"), "--targets", sandbox.path("w")],
            home: sandbox.root
        )
        #expect((refused.first?["refused"] as? [Any])?.count == 1)

        let started = try #require(try runScript(
            RemoteFileScripts.jobStart,
            ["--worker", RemoteFileScripts.jobWorker, "--mode", "delete", "--roots", "--targets", sandbox.path("w/big"), small],
            home: sandbox.root
        ).first)
        let job = try #require(started["job"] as? String)
        let pid = try #require(started["pid"] as? Int)
        var state = ""
        var status: [String: Any] = [:]
        for _ in 0..<100 where state != "finished" {
            Thread.sleep(forTimeInterval: 0.1)
            let poll = try #require(try runScript(RemoteFileScripts.jobPoll, [job, String(pid), "poll"], home: sandbox.root).first)
            state = poll["state"] as? String ?? ""
            status = poll["status"] as? [String: Any] ?? status
        }
        #expect(state == "finished")
        #expect(status["done"] as? Int == 2)
        #expect((status["failed"] as? [Any])?.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: small))
        #expect(!FileManager.default.fileExists(atPath: job))   // collected after the final poll
    }

    @Test("Large argument lists can be staged in a private file")
    func stagedArguments() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let staged = sandbox.path("args")
        let folder = try sandbox.directory("d")
        try Data((folder + "\u{0}0\u{0}10\u{0}").utf8).write(to: URL(fileURLWithPath: staged))
        let result = try #require(try runScript(RemoteFileScripts.listing, ["@" + staged], home: sandbox.root).first)
        #expect(result["resolved"] as? String == folder)
        #expect(!FileManager.default.fileExists(atPath: staged))
    }

    @Test("The harness is bounded: a hung script is killed, and a flood of stderr cannot block it")
    func harnessIsBounded() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let started = Date()
        #expect(throws: ScriptTimedOut.self) {
            _ = try runScript("import time\ntime.sleep(60)", [], home: sandbox.root, timeLimit: 1)
        }
        #expect(Date().timeIntervalSince(started) < 30)
        let flood = "import sys\nsys.stderr.write('x' * 1000000)\nsys.stderr.flush()\nprint('{\"ok\": true}')"
        let result = try runScript(flood, [], home: sandbox.root, timeLimit: 30)
        #expect(result.first?["ok"] as? Bool == true)
    }

    @Test("A trashed file named .manifest.json is stored apart from the run's manifest and survives restores")
    func trashedManifestNameIsReserved() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let userManifest = try sandbox.make("proj/.manifest.json", contents: "{\"name\": \"my-webapp\"}")
        let notes = try sandbox.make("proj/notes.txt", contents: "notes")
        let trashRun = sandbox.path(".aire-trash/R1")
        let execute = try runScript(
            RemoteFileScripts.trashExecute,
            ["--run", "R1", "--cluster", "calder", "--created", "2026-10-13T10:00:00Z", "--trash-name", ".aire-trash",
             "--group", trashRun, "home", userManifest, notes],
            home: sandbox.root
        )
        let stored = trashRun + "/.manifest (2).json"
        #expect(execute.contains { $0["moved"] as? String == userManifest && $0["to"] as? String == stored })
        #expect(try String(contentsOfFile: stored, encoding: .utf8) == "{\"name\": \"my-webapp\"}")

        let listed = try #require(try runScript(RemoteFileScripts.trashList, ["--cluster", "calder", "--trash-name", ".aire-trash"], home: sandbox.root).first)
        let run = try #require((listed["runs"] as? [[String: Any]])?.first)
        #expect(run["count"] as? Int == 2)
        let entries = run["entries"] as? [[String: Any]] ?? []
        #expect(entries.contains { $0["name"] as? String == ".manifest (2).json" && $0["original"] as? String == userManifest })

        // Restoring the sibling alone must leave the user's file in place.
        let first = try runScript(
            RemoteFileScripts.trashRestore,
            ["--run", trashRun, "--trash-name", ".aire-trash", "--pairs", trashRun + "/notes.txt", notes],
            home: sandbox.root
        )
        #expect(first.last?["removed_run"] as? Bool == false)
        #expect(try String(contentsOfFile: stored, encoding: .utf8) == "{\"name\": \"my-webapp\"}")

        let second = try runScript(
            RemoteFileScripts.trashRestore,
            ["--run", trashRun, "--trash-name", ".aire-trash", "--pairs", stored, userManifest],
            home: sandbox.root
        )
        #expect(second.last?["removed_run"] as? Bool == true)
        #expect(try String(contentsOfFile: userManifest, encoding: .utf8) == "{\"name\": \"my-webapp\"}")
    }

    @Test("A scratch run whose folder was renamed stays listed, comes back, and is dropped only when forgotten")
    func trashIndexSurvivesRenames() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let list = { (extra: [String]) throws -> [[String: Any]] in
            let payload = try #require(try runScript(
                RemoteFileScripts.trashList,
                ["--cluster", "calder", "--trash-name", ".aire-trash"] + extra,
                home: sandbox.root
            ).first)
            return payload["runs"] as? [[String: Any]] ?? []
        }
        let trash = { (folder: String, run: String, file: String) throws in
            let execute = try runScript(
                RemoteFileScripts.trashExecute,
                ["--run", run, "--cluster", "calder", "--created", "2026-10-13T10:00:00Z", "--trash-name", ".aire-trash",
                 "--group", sandbox.path("\(folder)/.aire-trash/\(run)"), "mount", file],
                home: sandbox.root
            )
            #expect(execute.contains { $0["moved"] != nil })
        }
        let index = sandbox.path(".aire-trash/.index")
        try trash("proj", "R1", try sandbox.make("proj/a.dat"))
        let pointer = try #require(try FileManager.default.contentsOfDirectory(atPath: index).first)
        #expect(try list([]).first?["count"] as? Int == 1)

        // Renamed: still listed, as missing, with the index entry to forget.
        try FileManager.default.moveItem(atPath: sandbox.path("proj"), toPath: sandbox.path("proj2"))
        let missing = try #require(try list([]).first)
        #expect(missing["state"] as? String == "missing")
        #expect(missing["pointer"] as? String == pointer)
        #expect((missing["error"] as? String)?.contains("no longer there") == true)

        // Renamed back: listed normally again.
        try FileManager.default.moveItem(atPath: sandbox.path("proj2"), toPath: sandbox.path("proj"))
        let back = try #require(try list([]).first)
        #expect(back["state"] == nil)
        #expect(back["count"] as? Int == 1)

        // Forget is refused while the run is there…
        #expect(try list(["--forget", pointer]).count == 1)
        // …and unreachable runs are listed, not pruned.
        let holder = sandbox.path("proj")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: holder)
        let unavailable = try list([])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: holder)
        #expect(unavailable.first?["state"] as? String == "unavailable")
        #expect(unavailable.first?["pointer"] == nil || unavailable.first?["pointer"] is NSNull)

        // Forgotten on request while missing; the data itself is untouched.
        try FileManager.default.moveItem(atPath: sandbox.path("proj"), toPath: sandbox.path("proj2"))
        #expect(try list(["--forget", pointer]).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: index).isEmpty)
        #expect(FileManager.default.fileExists(atPath: sandbox.path("proj2/.aire-trash/R1/a.dat")))

        // Gone from beside a folder that is still there: deleted outside the
        // app or renamed away, which the login node cannot tell apart, so it
        // stays listed as missing until the user forgets it.
        try trash("other", "R2", try sandbox.make("other/b.dat"))
        let otherPointer = try #require(try FileManager.default.contentsOfDirectory(atPath: index).first)
        try FileManager.default.removeItem(atPath: sandbox.path("other/.aire-trash/R2"))
        let deleted = try #require(try list([]).first)
        #expect(deleted["state"] as? String == "missing")
        #expect(deleted["pointer"] as? String == otherPointer)
        #expect((deleted["error"] as? String)?.contains("deleted outside this sheet") == true)
        #expect(try list(["--forget", otherPointer]).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: index).isEmpty)

        // Under a storage root that is absent (its filesystem not mounted on
        // this login node): unavailable, and Forget cannot drop it.
        try trash("mnt/u/proj", "R5", try sandbox.make("mnt/u/proj/c.dat"))
        let unmountedPointer = try #require(try FileManager.default.contentsOfDirectory(atPath: index).first)
        try FileManager.default.moveItem(atPath: sandbox.path("mnt"), toPath: sandbox.path("mnt-away"))
        let roots = ["--roots", sandbox.path("mnt/u")]
        let unmounted = try #require(try list(roots).first)
        #expect(unmounted["state"] as? String == "unavailable")
        #expect((unmounted["error"] as? String)?.contains("not available on this login node") == true)
        #expect(try list(roots + ["--forget", unmountedPointer]).count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: index) == [unmountedPointer])
    }

    /// The runs `trash-list` reports for Calder.
    private func listTrash(_ sandbox: Sandbox, _ extra: [String] = []) throws -> [[String: Any]] {
        let payload = try #require(try runScript(
            RemoteFileScripts.trashList,
            ["--cluster", "calder", "--trash-name", ".aire-trash"] + extra,
            home: sandbox.root
        ).first)
        return payload["runs"] as? [[String: Any]] ?? []
    }

    /// Trashes `file` into the run folder `<folder>/.aire-trash/<run>` as a
    /// scratch/flash group, which also writes the run's index pointer.
    private func trashBeside(_ sandbox: Sandbox, folder: String, run: String, file: String) throws {
        let execute = try runScript(
            RemoteFileScripts.trashExecute,
            ["--run", run, "--cluster", "calder", "--created", "2026-10-13T10:00:00Z", "--trash-name", ".aire-trash",
             "--group", sandbox.path("\(folder)/.aire-trash/\(run)"), "mount", file],
            home: sandbox.root
        )
        #expect(execute.contains { $0["moved"] as? String == file })
    }

    @Test("A scratch run stays listed when a new folder takes its renamed folder's name, or its own folders are renamed")
    func trashIndexIgnoresRecreatedHolder() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let index = sandbox.path(".aire-trash/.index")
        let results = sandbox.path("scratch/u/results")
        try trashBeside(sandbox, folder: "scratch/u/results", run: "R1", file: try sandbox.make("scratch/u/results/old.dat"))
        let pointer = try #require(try FileManager.default.contentsOfDirectory(atPath: index).first)
        let move = { (from: String, to: String) throws in
            try FileManager.default.moveItem(atPath: from, toPath: to)
        }
        let expectMissing = { (note: Comment) throws in
            let runs = try self.listTrash(sandbox)
            #expect(runs.count == 1, note)
            #expect(runs.first?["state"] as? String == "missing", note)
            #expect(runs.first?["pointer"] as? String == pointer, note)
            #expect(try FileManager.default.contentsOfDirectory(atPath: index) == [pointer], note)
        }
        let expectBack = { (note: Comment) throws in
            let run = try #require(try self.listTrash(sandbox).first, note)
            #expect(run["state"] == nil, note)
            #expect(run["count"] as? Int == 1, note)
        }

        // Keep the old results, start fresh: a new folder at the old path
        // says nothing about the run, which went with results-v1.
        try move(results, results + "-v1")
        try expectMissing("holder renamed")
        _ = try sandbox.directory("scratch/u/results")
        try expectMissing("a new folder took the holder's name")
        let recreated = try #require(try listTrash(sandbox).first)
        #expect((recreated["error"] as? String)?.contains("no longer in \(results)") == true)
        try FileManager.default.removeItem(atPath: results)
        try move(results + "-v1", results)
        try expectBack("holder renamed back")

        // Renaming the run folder itself (Show, then Rename… in the browser)
        // or its .aire-trash leaves the holder in place.
        let run = results + "/.aire-trash/R1"
        try move(run, run + "-renamed")
        try expectMissing("run folder renamed")
        try move(run + "-renamed", run)
        try expectBack("run folder renamed back")
        try move(results + "/.aire-trash", results + "/.aire-trash-old")
        try expectMissing(".aire-trash renamed")
        try move(results + "/.aire-trash-old", results + "/.aire-trash")
        try expectBack(".aire-trash renamed back")
        #expect(FileManager.default.fileExists(atPath: run + "/old.dat"))
    }

    @Test("Emptying a scratch run drops its index entry; a run that moved away before the delete keeps it")
    func emptyDropsOnlyRemovedRunsPointers() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let index = sandbox.path(".aire-trash/.index")
        try trashBeside(sandbox, folder: "scratch/u/a", run: "R1", file: try sandbox.make("scratch/u/a/x.dat"))
        try trashBeside(sandbox, folder: "scratch/u/b", run: "R2", file: try sandbox.make("scratch/u/b/y.dat"))
        let pointers = try FileManager.default.contentsOfDirectory(atPath: index)
        #expect(pointers.count == 2)
        let removedRun = sandbox.path("scratch/u/a/.aire-trash/R1")
        let movedRun = sandbox.path("scratch/u/b/.aire-trash/R2")
        // b is renamed after the sheet listed it, before Empty: the delete's
        // rm -rf of the old path removes nothing, which proves nothing.
        try FileManager.default.moveItem(atPath: sandbox.path("scratch/u/b"), toPath: sandbox.path("scratch/u/b2"))
        // An unrelated folder of the same shape is not a run with a pointer.
        let unrelated = try sandbox.directory("scratch/u/c/.aire-trash/R3")

        let started = try #require(try runScript(
            RemoteFileScripts.jobStart,
            ["--worker", RemoteFileScripts.jobWorker, "--mode", "delete", "--roots", sandbox.path("scratch/u"),
             "--targets", removedRun, movedRun, unrelated, "--trash-name", ".aire-trash"],
            home: sandbox.root
        ).first)
        let (state, status) = try waitForJob(started, home: sandbox.root)
        #expect(state == "finished")
        #expect((status["failed"] as? [Any])?.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: removedRun))

        let remaining = try FileManager.default.contentsOfDirectory(atPath: index)
        #expect(remaining.count == 1)
        let runs = try listTrash(sandbox)
        #expect(runs.count == 1)
        #expect(runs.first?["directory"] as? String == movedRun)
        #expect(runs.first?["state"] as? String == "missing")
        #expect(runs.first?["pointer"] as? String == remaining.first)
        #expect(FileManager.default.fileExists(atPath: sandbox.path("scratch/u/b2/.aire-trash/R2/y.dat")))
    }

    @Test("Names that merely start like the manifest's temporary file are trashed, listed and restored without looping")
    func manifestLookalikeNamesTerminate() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let plain = try sandbox.make("proj/a.txt", contents: "a")
        let backup = try sandbox.make("proj/.manifest.json.tmp.bak", contents: "bak")
        let older = try sandbox.make("proj/.manifest.json.tmp-old.txt", contents: "old")
        let temporary = try sandbox.make("proj/.manifest.json.tmp-123", contents: "tmp")
        let scratchBackup = try sandbox.make("scratch/u/.manifest.json.tmp.bak", contents: "scratch")
        let homeRun = sandbox.path(".aire-trash/R1")
        let mountRun = sandbox.path("scratch/u/.aire-trash/R1")
        let execute = try runScript(
            RemoteFileScripts.trashExecute,
            ["--run", "R1", "--cluster", "calder", "--created", "2026-10-13T10:00:00Z", "--trash-name", ".aire-trash",
             "--group", homeRun, "home", plain, backup, older, temporary,
             "--group", mountRun, "mount", scratchBackup],
            home: sandbox.root,
            timeLimit: 20
        )
        #expect(execute.last?["done"] as? Bool == true)
        #expect(execute.filter { $0["moved"] != nil }.count == 5)
        // Only write_json's exact temporary name is reserved; look-alikes
        // keep their names, and the reserved one is numbered.
        #expect(try String(contentsOfFile: homeRun + "/.manifest.json.tmp.bak", encoding: .utf8) == "bak")
        #expect(try String(contentsOfFile: homeRun + "/.manifest.json.tmp-old.txt", encoding: .utf8) == "old")
        #expect(try String(contentsOfFile: homeRun + "/.manifest.json (2).tmp-123", encoding: .utf8) == "tmp")
        #expect(try String(contentsOfFile: mountRun + "/.manifest.json.tmp.bak", encoding: .utf8) == "scratch")
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.path(".aire-trash/.index")).count == 1)

        let runs = try listTrash(sandbox)
        let byDirectory = Dictionary(uniqueKeysWithValues: runs.compactMap { run in
            (run["directory"] as? String).map { ($0, run) }
        })
        let home = try #require(byDirectory[homeRun])
        #expect(home["has_manifest"] as? Bool == true)
        #expect(home["count"] as? Int == 4)
        let entries = home["entries"] as? [[String: Any]] ?? []
        let originals = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            (entry["name"] as? String).map { ($0, entry["original"] as? String ?? "") }
        })
        #expect(originals == [
            "a.txt": plain,
            ".manifest.json.tmp.bak": backup,
            ".manifest.json.tmp-old.txt": older,
            ".manifest.json (2).tmp-123": temporary
        ])
        #expect(byDirectory[mountRun]?["count"] as? Int == 1)
        #expect(byDirectory[mountRun]?["has_manifest"] as? Bool == true)

        let pairs = originals.sorted { $0.key < $1.key }.flatMap { [homeRun + "/" + $0.key, $0.value] }
        let restore = try runScript(
            RemoteFileScripts.trashRestore,
            ["--run", homeRun, "--trash-name", ".aire-trash", "--pairs"] + pairs,
            home: sandbox.root
        )
        #expect(restore.filter { $0["restored"] != nil }.count == 4)
        #expect(restore.last?["removed_run"] as? Bool == true)
        #expect(try String(contentsOfFile: temporary, encoding: .utf8) == "tmp")
        #expect(try String(contentsOfFile: backup, encoding: .utf8) == "bak")
    }

    @Test("A quota copy of names that merely start like the manifest's temporary file finishes")
    func quotaCopyManifestLookalikeTerminates() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let backup = try sandbox.make("scratch/.manifest.json.tmp.bak", contents: "bak")
        let temporary = try sandbox.make("scratch/.manifest.json.tmp-7", contents: "seven")
        let started = try #require(try runScript(
            RemoteFileScripts.jobStart,
            copyArguments(sandbox, run: "R6", targets: [backup, temporary]),
            home: sandbox.root
        ).first)
        let pid = try #require(started["pid"] as? Int)
        var finished = false
        defer {
            // A worker stuck in its naming loop ignores Cancel's SIGTERM;
            // never leave it spinning after a failed run.
            if !finished {
                kill(-pid_t(pid), SIGKILL)
                kill(pid_t(pid), SIGKILL)
                if let job = started["job"] as? String {
                    try? FileManager.default.removeItem(atPath: job)
                }
            }
        }
        let (state, status) = try waitForJob(started, home: sandbox.root)
        finished = state == "finished"
        #expect(state == "finished")
        #expect((status["failed"] as? [Any])?.isEmpty == true)
        let run = sandbox.path(".aire-trash/R6")
        #expect(try String(contentsOfFile: run + "/.manifest.json.tmp.bak", encoding: .utf8) == "bak")
        #expect(try String(contentsOfFile: run + "/.manifest.json (2).tmp-7", encoding: .utf8) == "seven")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: run + "/.manifest.json"))) as? [String: Any]
        let names = (manifest?["items"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        #expect(names.sorted() == [".manifest.json (2).tmp-7", ".manifest.json.tmp.bak"])
        #expect(!FileManager.default.fileExists(atPath: backup))
        #expect(!FileManager.default.fileExists(atPath: temporary))
    }

    /// Polls a background job until it reports finished (or 20 s pass).
    private func waitForJob(_ started: [String: Any], home: URL) throws -> (state: String, status: [String: Any]) {
        let job = try #require(started["job"] as? String)
        let pid = try #require(started["pid"] as? Int)
        var state = ""
        var status: [String: Any] = [:]
        for _ in 0..<200 where state != "finished" && state != "crashed" {
            Thread.sleep(forTimeInterval: 0.1)
            let poll = try #require(try runScript(RemoteFileScripts.jobPoll, [job, String(pid), "poll"], home: home).first)
            state = poll["state"] as? String ?? ""
            status = poll["status"] as? [String: Any] ?? status
        }
        return (state, status)
    }

    private func copyArguments(_ sandbox: Sandbox, run: String, targets: [String]) -> [String] {
        ["--worker", RemoteFileScripts.jobWorker, "--mode", "copy", "--roots", "--targets"] + targets
            + ["--destination", sandbox.path(".aire-trash/\(run)"), "--run", run, "--cluster", "calder",
               "--created", "2026-10-13T10:00:00Z", "--trash-name", ".aire-trash"]
    }

    @Test("A quota copy stores a file named .manifest.json apart from the run's manifest")
    func quotaCopyReservesManifestName() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let userManifest = try sandbox.make("scratch/.manifest.json", contents: "[1, 2, 3]")
        let data = try sandbox.make("scratch/data.bin", contents: "data")
        let started = try #require(try runScript(
            RemoteFileScripts.jobStart,
            copyArguments(sandbox, run: "R3", targets: [userManifest, data]),
            home: sandbox.root
        ).first)
        let (state, status) = try waitForJob(started, home: sandbox.root)
        #expect(state == "finished")
        #expect((status["failed"] as? [Any])?.isEmpty == true)
        let run = sandbox.path(".aire-trash/R3")
        #expect(try String(contentsOfFile: run + "/.manifest (2).json", encoding: .utf8) == "[1, 2, 3]")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: run + "/.manifest.json"))) as? [String: Any]
        let names = (manifest?["items"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        #expect(names.sorted() == [".manifest (2).json", "data.bin"])
        #expect(!FileManager.default.fileExists(atPath: userManifest))
    }

    @Test("Cancelling a quota copy while it removes the original lets the removal finish")
    func quotaCopyCancelDuringRemoval() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let source = try sandbox.directory("scratch/big")
        for index in 1...50 {
            try sandbox.make("scratch/big/f\(index)", contents: "\(index)")
        }
        // An rm that announces itself and dawdles when removing an original
        // (not a .partial), so the Cancel lands mid-removal every time.
        let marker = sandbox.path("rm-started")
        let tools = try sandbox.directory("bin")
        let fakeRm = """
        #!/bin/sh
        for last; do :; done
        case "$last" in
          *.partial) ;;
          *) : > '\(marker)'; sleep 2 ;;
        esac
        exec /bin/rm "$@"
        """
        try Data(fakeRm.utf8).write(to: URL(fileURLWithPath: tools + "/rm"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tools + "/rm")
        let path = tools + ":/usr/bin:/bin:/usr/sbin:/sbin"

        let started = try #require(try runScript(
            RemoteFileScripts.jobStart,
            copyArguments(sandbox, run: "R4", targets: [source]),
            home: sandbox.root,
            environment: ["PATH": path]
        ).first)
        let job = try #require(started["job"] as? String)
        let pid = try #require(started["pid"] as? Int)
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: marker) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        try #require(FileManager.default.fileExists(atPath: marker), "the copy never reached the removal")
        let cancel = try #require(try runScript(RemoteFileScripts.jobPoll, [job, String(pid), "cancel"], home: sandbox.root).first)
        #expect(cancel["state"] as? String == "signalled")

        let (state, status) = try waitForJob(started, home: sandbox.root)
        #expect(state == "finished")
        #expect(status["cancelled"] as? Bool == true)
        #expect((status["moved"] as? [String]) == [source])
        #expect((status["failed"] as? [Any])?.isEmpty == true)
        // Never a gutted original beside the copy: it is gone entirely, and
        // the trash holds every file.
        #expect(!FileManager.default.fileExists(atPath: source))
        let copied = try FileManager.default.contentsOfDirectory(atPath: sandbox.path(".aire-trash/R4/big"))
        #expect(copied.count == 50)
    }
}
