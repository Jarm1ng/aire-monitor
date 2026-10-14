import HPCCore
import Foundation
import Testing
@testable import AIREMonitorApp

// The remote file manager deletes and moves user data on shared HPC
// filesystems. These tests pin its safety rules (protected paths, trash
// planning that fails closed, no-clobber transfer names), its error wording
// and the browser model's race handling — with a fake runner standing in
// for ssh, so nothing here touches a cluster.

// MARK: - Fake runner

/// Answers remote commands by script marker (`# hpc-file-script: <name>`)
/// or by the shell command, records every call, and can delay an answer to
/// recreate in-flight races.
final class FakeRemoteRunner: RemoteCommandRunning, @unchecked Sendable {
    typealias Handler = @Sendable (_ script: String?, _ arguments: [String], _ command: String) async -> ProcessResult

    private let lock = NSLock()
    private var recordedCommands: [String] = []
    private var recordedTransfers: [[String]] = []
    private let handler: Handler
    private let transferHandler: @Sendable ([String]) async -> ProcessResult

    init(
        transfer: @escaping @Sendable ([String]) async -> ProcessResult = { _ in ProcessResult(stdout: "", stderr: "", exitCode: 0) },
        handler: @escaping Handler
    ) {
        self.handler = handler
        self.transferHandler = transfer
    }

    var commands: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCommands
    }

    var transfers: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedTransfers
    }

    func calls(to script: String) -> [[String]] {
        commands.compactMap { command in
            let parsed = FakeRemoteRunner.parse(command)
            return parsed.script == script ? parsed.arguments : nil
        }
    }

    func runRemoteCommand(settings: ConnectionSettings, command: String, timeout: TimeInterval) async throws -> ProcessResult {
        lock.withLock {
            recordedCommands.append(command)
        }
        let parsed = Self.parse(command)
        return await handler(parsed.script, parsed.arguments, command)
    }

    func runTransfer(settings: ConnectionSettings, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        lock.withLock {
            recordedTransfers.append(arguments)
        }
        return await transferHandler(arguments)
    }

    /// The embedded script's name and its argv, from a `pythonCommand`.
    static func parse(_ command: String) -> (script: String?, arguments: [String]) {
        let words = shellWords(command)
        guard let index = words.firstIndex(of: "-c"), index + 1 < words.count else {
            return (nil, [])
        }
        let script = words[index + 1]
        let marker = "# hpc-file-script: "
        let name = script
            .components(separatedBy: "\n")
            .first { $0.hasPrefix(marker) }
            .map { String($0.dropFirst(marker.count)) }
        return (name, Array(words[(index + 2)...]))
    }

    /// Minimal POSIX word splitting: single quotes, double quotes, backslash
    /// escapes, and `;` as a separator — enough for the app's commands.
    static func shellWords(_ command: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var iterator = Array(command).makeIterator()
        var pendingQuote: Character?
        while let character = pendingQuote ?? iterator.next() {
            pendingQuote = nil
            switch character {
            case "'":
                inWord = true
                while let next = iterator.next(), next != "'" {
                    current.append(next)
                }
            case "\"":
                inWord = true
                while let next = iterator.next(), next != "\"" {
                    current.append(next)
                }
            case "\\":
                inWord = true
                if let next = iterator.next() {
                    current.append(next)
                }
            case " ", "\n", "\t", ";":
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
            default:
                inWord = true
                current.append(character)
            }
        }
        if inWord {
            words.append(current)
        }
        return words
    }
}

func ok(_ object: [String: Any]) -> ProcessResult {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    return ProcessResult(stdout: String(decoding: data, as: UTF8.self) + "\n", stderr: "", exitCode: 0)
}

func lines(_ objects: [[String: Any]]) -> ProcessResult {
    let text = objects.map { object in
        String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }.joined(separator: "\n")
    return ProcessResult(stdout: text + "\n", stderr: "", exitCode: 0)
}

func listingPayload(_ path: String, names: [String], truncated: Bool = false, total: Int? = nil, filter: String = "") -> [String: Any] {
    [
        "requested": path,
        "resolved": path,
        "truncated": truncated,
        "total": total ?? names.count,
        "matched": names.count,
        "filter": filter,
        "entries": names.map { ["name": $0, "kind": "file", "size": 1, "mtime": 0, "owner": "u", "mode": "rw-r--r--", "lossy": false] }
    ]
}

private let calder = makeSettings(catalogProfile(.calder))
private let home = "/users/abcd1234"
private let roots = [home, "/scratch-calder/users/abcd1234", "/flash-calder/users/abcd1234"]

// MARK: - Protected paths

@Suite("Protected paths for trash and delete")
struct ProtectedPathTests {
    @Test(
        "Refuses the root, top-level folders, every protected root and its ancestors",
        arguments: [
            "/", "/users", "/users/", "/mnt", "/scratch-calder",
            home, home + "/",
            "/scratch-calder/users", "/scratch-calder/users/abcd1234",
            "/flash-calder/users/abcd1234", "/flash-calder/users",
            "/mnt/scratch", "/mnt/scratch/abcd1234",
            "/users/abcd1234/../abcd1234", "//users/abcd1234/x", "/users/abcd1234/./x",
            "~", "~/proj", "relative/path"
        ]
    )
    func refuses(_ path: String) {
        let protectedRoots = roots + ["/mnt/scratch/abcd1234"]
        #expect(throws: MonitorError.self) {
            _ = try RemoteFileService.validatedTargets([path], protectedRoots: protectedRoots, operation: "Delete")
        }
    }

    @Test(
        "Allows ordinary paths inside a root and elsewhere",
        arguments: ["/tmp/x", "/users/abcd1234/proj", "/scratch-calder/users/abcd1234/run/out.log", "/users/abcd1234/..foo", "/users/other/shared"]
    )
    func allows(_ path: String) throws {
        let validated = try RemoteFileService.validatedTargets([path], protectedRoots: roots, operation: "Delete")
        #expect(validated == [path])
    }

    @Test("Trailing slashes are dropped, nothing else changes")
    func trailingSlashes() throws {
        let validated = try RemoteFileService.validatedTargets(["/tmp/x/ ", "/tmp/y//"], protectedRoots: roots, operation: "Delete")
        #expect(validated == ["/tmp/x/ ", "/tmp/y"])
    }

    @Test("The refusal names the reason")
    func messages() {
        do {
            _ = try RemoteFileService.validatedTargets(["/users"], protectedRoots: roots, operation: "Delete")
            Issue.record("expected a refusal")
        } catch {
            #expect(error.localizedDescription.contains("top-level folder"))
        }
        do {
            _ = try RemoteFileService.validatedTargets(["/scratch-calder/users"], protectedRoots: roots, operation: "Move to trash")
            Issue.record("expected a refusal")
        } catch {
            #expect(error.localizedDescription == "Move to trash refused for /scratch-calder/users: it contains your home or a storage root.")
        }
    }

    @Test("Anything inside a trash folder is refused for Move to Trash")
    func trashOfTrash() {
        #expect(RemoteFileService.isInsideTrash("/users/u/.aire-trash"))
        #expect(RemoteFileService.isInsideTrash("/scratch/u/p/.aire-trash/20261013-1-abc/x"))
        #expect(!RemoteFileService.isInsideTrash("/users/u/.aire-trash-old/x"))
        #expect(throws: MonitorError.self) {
            try RemoteFileService.refuseTrashingTrash(["/users/u/a", "/users/u/.aire-trash/r/x"])
        }
    }
}

// MARK: - Trash planning

@Suite("Trash planning")
struct TrashPlanTests {
    private func probe(_ path: String, device: String?, writable: Bool = true, error: String? = nil) -> TrashProbe {
        TrashProbe(path: path, device: device, error: error, parent: (path as NSString).deletingLastPathComponent, parentWritable: writable)
    }

    @Test("Home-filesystem items go to the home trash")
    func sameDevice() throws {
        let plan = try RemoteFileService.planTrash(
            TrashInspection(home: home, homeDevice: "1", targets: [probe(home + "/a", device: "1"), probe(home + "/b", device: "1")], mountTrash: []),
            runName: "R"
        )
        #expect(plan.groups == [TrashPlan.Group(directory: home + "/.aire-trash/R", isHome: true, paths: [home + "/a", home + "/b"])])
        #expect(plan.quotaCopyTargets.isEmpty)
    }

    @Test("Other-filesystem items go to a trash folder beside them")
    func perMount() throws {
        let scratch = "/scratch-calder/users/abcd1234/run"
        let plan = try RemoteFileService.planTrash(
            TrashInspection(
                home: home,
                homeDevice: "1",
                targets: [probe(home + "/a", device: "1"), probe(scratch + "/x", device: "2"), probe(scratch + "/y", device: "2")],
                mountTrash: [MountTrashDirectory(parent: scratch, directory: scratch + "/.aire-trash/R", error: nil, createdBase: true)]
            ),
            runName: "R"
        )
        #expect(plan.groups.count == 2)
        #expect(plan.groups[1] == TrashPlan.Group(directory: scratch + "/.aire-trash/R", isHome: false, paths: [scratch + "/x", scratch + "/y"]))
        #expect(plan.unusedDirectories.isEmpty)
    }

    @Test("A trash folder that cannot be created means a quota copy")
    func mkdirFailure() throws {
        let scratch = "/mnt/scratch/abcd1234"
        let plan = try RemoteFileService.planTrash(
            TrashInspection(
                home: home,
                homeDevice: "1",
                targets: [probe(scratch + "/x", device: "2")],
                mountTrash: [MountTrashDirectory(parent: scratch, directory: scratch + "/.aire-trash/R", error: "Disk quota exceeded", createdBase: false)]
            ),
            runName: "R"
        )
        #expect(plan.groups.isEmpty)
        #expect(plan.quotaCopyTargets == [scratch + "/x"])
        #expect(plan.homeTrashDirectory == home + "/.aire-trash/R")
    }

    @Test("An unknown home device fails closed")
    func probeFailure() {
        #expect(throws: MonitorError.self) {
            _ = try RemoteFileService.planTrash(
                TrashInspection(home: home, homeDevice: nil, targets: [probe("/mnt/scratch/u/x", device: "2")], mountTrash: []),
                runName: "R"
            )
        }
    }

    @Test("A target that cannot be statted stops everything and is named")
    func missingTarget() {
        do {
            _ = try RemoteFileService.planTrash(
                TrashInspection(home: home, homeDevice: "1", targets: [probe(home + "/a", device: "1"), probe(home + "/gone", device: nil, error: "No such file or directory")], mountTrash: []),
                runName: "R"
            )
            Issue.record("expected a failure")
        } catch {
            #expect(error.localizedDescription.contains(home + "/gone"))
            #expect(error.localizedDescription.contains("nothing was moved"))
        }
    }

    @Test("A parent without write permission stops everything")
    func readOnlyParent() {
        do {
            _ = try RemoteFileService.planTrash(
                TrashInspection(home: home, homeDevice: "1", targets: [probe("/mnt/scratch/x", device: "2", writable: false)], mountTrash: []),
                runName: "R"
            )
            Issue.record("expected a failure")
        } catch {
            #expect(error.localizedDescription == "You don't have permission to move items out of /mnt/scratch — nothing was moved.")
        }
    }
}

// MARK: - Transfers

@Suite("Transfer naming and limits")
struct TransferRuleTests {
    @Test(
        "Download sources escape the characters scp globs",
        arguments: [
            ("/d/data[1].csv", "/d/data\\[1].csv"),
            ("/d/a*b", "/d/a\\*b"),
            ("/d/x\\y", "/d/x\\\\y"),
            ("/d/what?.txt", "/d/what\\?.txt"),
            ("/d/plain name.txt", "/d/plain name.txt")
        ]
    )
    func globEscaping(_ input: String, _ expected: String) {
        #expect(RemoteFileService.downloadGlobEscaped(input) == expected)
    }

    @Test("scp argv rides the cluster's master and ends options before paths")
    func scpArguments() {
        let download = RemoteFileService.scpArguments(settings: calder, remotePath: "/d/-rf", localPath: "/tmp/x", direction: .download)
        #expect(download.contains("BatchMode=yes"))
        #expect(download.contains("ControlMaster=no"))
        #expect(download.contains("ControlPath=\(calder.controlPath)"))
        #expect(download.firstIndex(of: "--") == download.count - 3)
        #expect(download.suffix(2) == ["\(calder.hostname):/d/-rf", "/tmp/x"])
        let upload = RemoteFileService.scpArguments(settings: calder, remotePath: "/d/[x]", localPath: "/tmp/x", direction: .upload)
        #expect(upload.suffix(2) == ["/tmp/x", "\(calder.hostname):/d/[x]"])
        // The options are exactly the shared mux set, so scp can never
        // drift from the terminal and the collector.
        let options = SSHMuxOptions.scpOptions(settings: calder)
        #expect(download.first == "-q")
        #expect(Array(download[1...options.count]) == options)
        #expect(Array(upload[1...options.count]) == options)
    }

    @Test("The quit-time cleanup rides the master with the scrubbed child environment")
    func detachedCleanup() throws {
        let process = RemoteFileService.detachedCleanupProcess(settings: calder, command: "rm -f -- '/d/.x.part-1'")
        #expect(process.executableURL?.path == "/usr/bin/ssh")
        let arguments = try #require(process.arguments)
        #expect(Array(arguments.prefix(arguments.count - 2)) == SSHMuxOptions.sshArguments(settings: calder))
        #expect(arguments.suffix(2) == [calder.hostname, "timeout -k 5 20 rm -f -- '/d/.x.part-1'"])
        #expect(process.environment == MonitorService.childEnvironment())
    }

    @Test("Trash run names are stamped in cluster time and read back the same way")
    func trashRunStamp() throws {
        // 2026-10-13 10:41:38 UTC is 11:41:38 in Leeds (BST), whatever zone the Mac is in.
        let date = Date(timeIntervalSince1970: 1_791_888_098)
        let name = RemoteFileService.trashRunName(date)
        #expect(name.hasPrefix("20261013-114138-"))
        #expect(name.count == 15 + 1 + 8)
        let parsed = try #require(RemoteFileService.parseTrashDate(created: nil, directory: "/users/u/.aire-trash/" + name))
        #expect(parsed == date)
        // A manifest's ISO time wins over the folder name.
        let manifest = RemoteFileService.parseTrashDate(created: "2026-10-12T08:00:00Z", directory: "/users/u/.aire-trash/" + name)
        #expect(manifest == Date(timeIntervalSince1970: 1_791_792_000))
    }

    @Test("Compound archive extensions stay whole")
    func extensions() {
        #expect(RemoteFileService.splitExtension("data.tar.gz") == ("data", ".tar.gz"))
        #expect(RemoteFileService.splitExtension("a.b.csv") == ("a.b", ".csv"))
        #expect(RemoteFileService.splitExtension(".bashrc") == (".bashrc", ""))
        #expect(RemoteFileService.splitExtension("Makefile") == ("Makefile", ""))
        #expect(RemoteFileService.splitExtension(".tar.gz") == (".tar", ".gz"))
    }

    @Test("Local names are reserved on disk, so repeats never collide")
    func reservation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hpc-reserve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try RemoteFileService.reserveLocalURL(in: directory, preferredName: "data.tar.gz")
        let second = try RemoteFileService.reserveLocalURL(in: directory, preferredName: "data.tar.gz")
        let third = try RemoteFileService.reserveLocalURL(in: directory, preferredName: "data.tar.gz")
        #expect(first.lastPathComponent == "data.tar.gz")
        #expect(second.lastPathComponent == "data (2).tar.gz")
        #expect(third.lastPathComponent == "data (3).tar.gz")
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test("Concurrent reservations of one name all get distinct files")
    func concurrentReservation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hpc-reserve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let names = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    try? RemoteFileService.reserveLocalURL(in: directory, preferredName: "results.csv").lastPathComponent
                }
            }
            var collected: [String] = []
            for await name in group {
                if let name {
                    collected.append(name)
                }
            }
            return collected
        }
        #expect(names.count == 16)
        #expect(Set(names).count == 16)
    }

    @Test("Transfer ceilings scale with size and are never capped")
    func ceilings() {
        #expect(RemoteFileService.transferCeiling(forBytes: 0) == 600)
        #expect(RemoteFileService.transferCeiling(forBytes: 20_000_000_000) == 600 + 400_000)
        #expect(RemoteFileService.transferCeiling(forBytes: nil) == 86_400)
        #expect(RemoteFileService.partName(for: "x.csv").hasPrefix(".x.csv.part-"))
    }

    @Test("Logs preview from their end")
    func previewModes() {
        #expect(RemotePreviewMode.preferred(forFileName: "slurm-123.out") == .tail)
        #expect(RemotePreviewMode.preferred(forFileName: "train.LOG") == .tail)
        #expect(RemotePreviewMode.preferred(forFileName: "job.err") == .tail)
        #expect(RemotePreviewMode.preferred(forFileName: "config.json") == .head)
    }
}

// MARK: - Names and previews

@Suite("Names and preview classification")
struct NameAndPreviewTests {
    @Test(
        "Control characters are rejected",
        arguments: ["a\tb", "a\u{1B}b", "a\u{7F}b", "a\u{85}b", "a\nb", "a\0b"]
    )
    func controlCharacters(_ name: String) {
        #expect(FileBrowserModel.validateName(name) != nil)
    }

    @Test("Emoji sequences with a zero-width joiner are allowed", arguments: ["👩‍💻 notes", "résumé", "data (2)"])
    func allowedNames(_ name: String) {
        #expect(FileBrowserModel.validateName(name) == nil)
    }

    private func payload(mime: String?, charset: String?, hasFile: Bool = true, size: Int64 = 9, truncated: Bool = false, fromEnd: Bool = false) -> PreviewPayload {
        PreviewPayload(mime: mime, charset: charset, hasFile: hasFile, size: size, truncated: truncated, fromEnd: fromEnd, data: "")
    }

    @Test("JSON and notebooks are text by charset, not by MIME prefix")
    func json() {
        let result = RemoteFileService.classifyPreview(payload: payload(mime: "application/json", charset: "us-ascii"), data: Data("{\"a\": 1}\n".utf8))
        guard case .text(let preview) = result else {
            Issue.record("expected text, got \(result)")
            return
        }
        #expect(preview.text == "{\"a\": 1}\n")
        #expect(!preview.truncated)
    }

    @Test("A binary charset, and NUL bytes in a non-text type, are binary")
    func binary() {
        #expect(RemoteFileService.classifyPreview(payload: payload(mime: "application/octet-stream", charset: "binary"), data: Data([0, 1, 2])) == .binary(mimeType: "application/octet-stream"))
        #expect(RemoteFileService.classifyPreview(payload: payload(mime: "application/x-foo", charset: "utf-8"), data: Data([0x41, 0, 0x42])) == .binary(mimeType: "application/x-foo"))
    }

    @Test("Empty files are text even though file(1) says charset=binary")
    func empty() {
        let result = RemoteFileService.classifyPreview(payload: payload(mime: "inode/x-empty", charset: "binary", size: 0), data: Data())
        #expect(result == .text(RemoteTextPreview(text: "", totalBytes: 0, shownBytes: 0, truncated: false, fromEnd: false)))
    }

    @Test("Without file(1) the content is sniffed")
    func sniff() {
        #expect(RemoteFileService.classifyPreview(payload: payload(mime: nil, charset: nil, hasFile: false), data: Data("plain\n".utf8)) != .binary(mimeType: "application/octet-stream"))
        #expect(RemoteFileService.classifyPreview(payload: payload(mime: nil, charset: nil, hasFile: false), data: Data([0x41, 0x00])) == .binary(mimeType: "application/octet-stream"))
    }

    @Test("A head cut mid-codepoint drops the artifact and reports the truncation")
    func truncatedHead() {
        let data = Data("abc".utf8) + Data([0xE2, 0x82])
        let result = RemoteFileService.classifyPreview(payload: payload(mime: "text/plain", charset: "utf-8", size: 1000, truncated: true), data: data)
        #expect(result == .text(RemoteTextPreview(text: "abc", totalBytes: 1000, shownBytes: 5, truncated: true, fromEnd: false)))
    }
}

// MARK: - Outcome wording

@Suite("Trash outcome reporting")
struct TrashOutcomeTests {
    @Test("Per-item lines become groups and failures; a missing done line marks the rest")
    func parsing() throws {
        let result = lines([
            ["moved": "/u/a", "to": "/u/.aire-trash/R/a", "directory": "/u/.aire-trash/R"],
            ["failed": "/u/b", "error": "permission denied"]
        ])
        let outcome = try RemoteFileService.trashOutcome(from: result, targets: ["/u/a", "/u/b", "/u/c"], settings: calder)
        #expect(outcome.moved == [TrashOutcome.Move(directory: "/u/.aire-trash/R", paths: ["/u/a"])])
        #expect(outcome.failed.count == 2)
        #expect(outcome.failed[1].path == "/u/c")
        #expect(outcome.failed[1].reason.contains("not attempted"))
    }

    @Test("The message says where moved items went even when some failed")
    @MainActor
    func message() {
        var outcome = TrashOutcome()
        outcome.moved = [TrashOutcome.Move(directory: home + "/.aire-trash/R", paths: ["/a", "/b", "/c"])]
        outcome.failed = [TrashOutcome.Failure(path: home + "/x", reason: "permission denied")]
        let text = FileBrowserModel.trashMessage(outcome, clusterName: "Calder", home: home)
        #expect(text == "Moved 3 items on Calder to ~/.aire-trash/R; 1 could not be moved: x (permission denied).")
    }

    @Test("Several destinations are each named")
    @MainActor
    func severalDestinations() {
        var outcome = TrashOutcome()
        outcome.moved = [
            TrashOutcome.Move(directory: home + "/.aire-trash/R", paths: ["/a"]),
            TrashOutcome.Move(directory: "/scratch-calder/p/.aire-trash/R", paths: ["/b", "/c"])
        ]
        let text = FileBrowserModel.trashMessage(outcome, clusterName: "Calder", home: home)
        #expect(text == "Moved 3 items on Calder to the trash: 1 to ~/.aire-trash/R, 2 to /scratch-calder/p/.aire-trash/R.")
    }

    private func copyStatus(cancelled: Bool, moved: [String], failed: [TrashOutcome.Failure]) -> RemoteJobStatus {
        RemoteJobStatus(
            state: .finished, total: 2, done: 2, failed: failed, moved: moved,
            cancelled: cancelled, current: nil, detail: ""
        )
    }

    @Test("A cancelled copy is an info banner when only the interrupted item stayed behind")
    func cancelledCopy() {
        let status = copyStatus(
            cancelled: true,
            moved: ["/s/a"],
            failed: [TrashOutcome.Failure(path: "/s/b", reason: "cancelled")]
        )
        let report = FileBrowserModel.quotaCopyReport(status, clusterName: "Calder", destination: "~/.aire-trash/R")
        #expect(!report.isError)
        #expect(report.message == "Copy into the home trash on Calder was cancelled after 1 item; those are in ~/.aire-trash/R, the rest were not moved.")
    }

    @Test("A cancelled copy still names an original it could not fully remove, as an error")
    func cancelledCopyWithIncompleteOriginal() {
        let status = copyStatus(
            cancelled: true,
            moved: ["/s/big"],
            failed: [TrashOutcome.Failure(path: "/s/big", reason: "copied to the trash, but the original could not be fully removed: rm: Permission denied")]
        )
        let report = FileBrowserModel.quotaCopyReport(status, clusterName: "Calder", destination: "~/.aire-trash/R")
        #expect(report.isError)
        #expect(report.message.contains("1 did not finish cleanly: big (copied to the trash, but the original could not be fully removed"))
    }
}

// MARK: - Service flows with a fake runner

@Suite("Remote file service flows")
struct ServiceFlowTests {
    private func inspection(homeDevice: String?, targets: [[String: Any]], mounts: [[String: Any]] = []) -> ProcessResult {
        ok(["home": home, "home_device": homeDevice.map { $0 as Any } ?? NSNull(), "home_error": NSNull(), "refused": [], "targets": targets, "mount_trash": mounts])
    }

    private func target(_ path: String, device: String?) -> [String: Any] {
        [
            "path": path,
            "device": device.map { $0 as Any } ?? NSNull(),
            "error": device == nil ? "No such file or directory" as Any : NSNull(),
            "parent": (path as NSString).deletingLastPathComponent,
            "parent_writable": true
        ]
    }

    @Test("Same-device trash renames into the home trash and reports it")
    func sameDevice() async throws {
        let runner = FakeRemoteRunner { script, arguments, _ in
            switch script {
            case "trash-inspect":
                return self.inspection(homeDevice: "7", targets: [self.target(home + "/a", device: "7")])
            case "trash-execute":
                let group = arguments.firstIndex(of: "--group").map { arguments[$0 + 1] } ?? ""
                return lines([["moved": home + "/a", "to": group + "/a", "directory": group], ["done": true]])
            default:
                return ProcessResult(stdout: "", stderr: "unexpected", exitCode: 1)
            }
        }
        let service = RemoteFileService(runner: runner)
        let outcome = try await service.moveToTrash(settings: calder, paths: [home + "/a"], protectedRoots: roots)
        #expect(outcome.movedCount == 1)
        #expect(outcome.failed.isEmpty)
        let execute = try #require(runner.calls(to: "trash-execute").first)
        #expect(execute.contains("home"))
        #expect(execute.contains(home + "/a"))
    }

    @Test("When no trash folder can be created beside scratch items, nothing moves and the size is reported")
    func quotaCopyConfirmation() async {
        let scratch = "/mnt/scratch/abcd1234"
        let runner = FakeRemoteRunner { script, _, command in
            switch script {
            case "trash-inspect":
                return self.inspection(
                    homeDevice: "1",
                    targets: [self.target(scratch + "/big", device: "2")],
                    mounts: [["parent": scratch, "directory": scratch + "/.aire-trash/R", "created_base": false, "error": "Disk quota exceeded"]]
                )
            case nil where command.contains("du -sk"):
                return ProcessResult(stdout: "3774873600\t\(scratch)/big\n", stderr: "", exitCode: 0)
            default:
                return ProcessResult(stdout: "", stderr: "", exitCode: 0)
            }
        }
        let service = RemoteFileService(runner: runner)
        do {
            _ = try await service.moveToTrash(settings: calder, paths: [scratch + "/big"], protectedRoots: roots)
            Issue.record("expected a confirmation request")
        } catch let request as RemoteFileService.QuotaCopyConfirmationRequired {
            #expect(request.paths == [scratch + "/big"])
            #expect(request.bytes == Int64(3_774_873_600) * 1024)
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(runner.calls(to: "trash-execute").allSatisfy { !$0.contains("--group") })
        #expect(runner.commands.contains { $0.contains("timeout -k 5") && $0.contains("du -sk") })
    }

    @Test("A failed device probe moves nothing")
    func probeFailure() async {
        let runner = FakeRemoteRunner { script, _, _ in
            script == "trash-inspect"
                ? self.inspection(homeDevice: nil, targets: [self.target("/mnt/scratch/u/x", device: "2")])
                : ProcessResult(stdout: "", stderr: "", exitCode: 0)
        }
        let service = RemoteFileService(runner: runner)
        await #expect(throws: MonitorError.self) {
            _ = try await service.moveToTrash(settings: calder, paths: ["/mnt/scratch/u/x"], protectedRoots: roots)
        }
        #expect(runner.calls(to: "trash-execute").allSatisfy { !$0.contains("--group") })
    }

    @Test("A server-side refusal (an alias of a protected root) moves nothing")
    func serverRefusal() async {
        let runner = FakeRemoteRunner { _, _, _ in
            ok(["home": home, "refused": [["path": "/home/abcd1234", "reason": "it contains your home or a storage root"]]])
        }
        let service = RemoteFileService(runner: runner)
        do {
            _ = try await service.moveToTrash(settings: calder, paths: ["/home/abcd1234"], protectedRoots: roots)
            Issue.record("expected a refusal")
        } catch {
            #expect(error.localizedDescription.contains("refused for /home/abcd1234"))
        }
        #expect(runner.calls(to: "trash-execute").isEmpty)
    }

    @Test("New Folder with an existing name says so")
    func mkdirExists() async {
        let runner = FakeRemoteRunner { _, _, command in
            #expect(command.contains("mkdir -- "))
            #expect(!command.contains("mkdir -p"))
            return ProcessResult(stdout: "", stderr: "mkdir: cannot create directory '/u/x': File exists", exitCode: 1)
        }
        let service = RemoteFileService(runner: runner)
        do {
            try await service.createDirectory(settings: calder, path: "/u/x")
            Issue.record("expected a failure")
        } catch {
            #expect(error.localizedDescription == "A file or folder named “x” already exists.")
        }
    }

    @Test("Folder Size is bounded on the server and explains a timeout")
    func diskUsageTimeout() async {
        let runner = FakeRemoteRunner { _, _, command in
            #expect(command.hasPrefix("timeout -k 5 "))
            return ProcessResult(stdout: "", stderr: "", exitCode: 124)
        }
        do {
            _ = try await RemoteFileService(runner: runner).diskUsage(settings: calder, path: "/u/big")
            Issue.record("expected a failure")
        } catch {
            #expect(error.localizedDescription.contains("too large to measure quickly"))
        }
    }

    @Test("Folder Size measures a symlinked folder's target, not the link")
    func diskUsageFollowsTheLinkItself() async throws {
        let runner = FakeRemoteRunner { _, _, command in
            ProcessResult(stdout: "1.2T\t/users/abcd1234/scratch\n", stderr: "", exitCode: 0)
        }
        let size = try await RemoteFileService(runner: runner).diskUsage(settings: calder, path: home + "/scratch")
        #expect(size == "1.2T")
        let command = try #require(runner.commands.first)
        #expect(command.contains("du -shH -- "))
        #expect(!command.contains("du -shL"))
    }

    @Test("A copy that cannot start after the renames still says where the moved items went")
    func copyStartFailureKeepsOutcome() async throws {
        let scratch = "/scratch-calder/users/abcd1234/proj"
        let runner = FakeRemoteRunner { script, arguments, _ in
            switch script {
            case "trash-inspect":
                return self.inspection(
                    homeDevice: "1",
                    targets: [self.target(home + "/a", device: "1"), self.target(scratch + "/big", device: "2")],
                    mounts: [["parent": scratch, "directory": scratch + "/.aire-trash/R", "created_base": false, "error": "Disk quota exceeded"]]
                )
            case "trash-execute":
                let group = arguments.firstIndex(of: "--group").map { arguments[$0 + 1] } ?? ""
                return lines([["moved": home + "/a", "to": group + "/a", "directory": group], ["done": true]])
            case "job-start":
                return ProcessResult(stdout: "", stderr: "Connection to calder closed by remote host.", exitCode: 255)
            default:
                return ProcessResult(stdout: "", stderr: "unexpected", exitCode: 1)
            }
        }
        let outcome = try await RemoteFileService(runner: runner).moveToTrash(
            settings: calder,
            paths: [home + "/a", scratch + "/big"],
            protectedRoots: roots,
            allowQuotaCopy: true
        )
        #expect(outcome.movedCount == 1)
        #expect(outcome.copyJob == nil)
        #expect(outcome.failed.map(\.path) == [scratch + "/big"])
        #expect(outcome.failed.first?.reason.contains("could not be started") == true)
        let message = FileBrowserModel.trashMessage(outcome, clusterName: "Calder", home: home)
        #expect(message.hasPrefix("Moved 1 item on Calder to ~/.aire-trash/"))
        #expect(message.contains("1 could not be moved: big (the copy into the home trash could not be started"))
    }

    @Test("With nothing renamed, a copy that cannot start is a plain failure")
    func copyStartFailureAlone() async {
        let scratch = "/scratch-calder/users/abcd1234/proj"
        let runner = FakeRemoteRunner { script, _, _ in
            switch script {
            case "trash-inspect":
                return self.inspection(
                    homeDevice: "1",
                    targets: [self.target(scratch + "/big", device: "2")],
                    mounts: [["parent": scratch, "directory": scratch + "/.aire-trash/R", "created_base": false, "error": "Disk quota exceeded"]]
                )
            case "job-start":
                return ProcessResult(stdout: "", stderr: "Connection to calder closed by remote host.", exitCode: 255)
            default:
                return ProcessResult(stdout: "", stderr: "", exitCode: 0)
            }
        }
        await #expect(throws: (any Error).self) {
            _ = try await RemoteFileService(runner: runner).moveToTrash(
                settings: calder,
                paths: [scratch + "/big"],
                protectedRoots: roots,
                allowQuotaCopy: true
            )
        }
    }

    @Test("The trash list keeps unreachable runs, and Forget names only the chosen index entry")
    func unreachableTrashRuns() async throws {
        let runner = FakeRemoteRunner { script, _, _ in
            guard script == "trash-list" else {
                return ProcessResult(stdout: "", stderr: "unexpected", exitCode: 1)
            }
            let run = { (directory: String, extra: [String: Any]) -> [String: Any] in
                ["directory": directory, "location": "mount", "count": 0, "entries": [], "error": NSNull()]
                    .merging(extra) { _, new in new }
            }
            return ok(["home_trash": home + "/.aire-trash", "runs": [
                run("/s/p/.aire-trash/R0", ["count": 1, "entries": [["name": "a", "is_dir": false, "original": "/s/p/a"]]]),
                run("/s/gone/.aire-trash/R1", ["state": "missing", "pointer": "R1-abc.json", "error": "Its folder /s/gone is no longer there"]),
                run("/s/eio/.aire-trash/R2", ["state": "unavailable", "pointer": NSNull(), "error": "Could not reach this trash folder"])
            ]])
        }
        let runs = try await RemoteFileService(runner: runner).listTrash(settings: calder, forgetting: ["R1-abc.json"])
        let byDirectory = Dictionary(uniqueKeysWithValues: runs.map { ($0.directory, $0) })
        #expect(byDirectory["/s/p/.aire-trash/R0"]?.isReachable == true)
        #expect(byDirectory["/s/gone/.aire-trash/R1"]?.reachability == .missing(pointer: "R1-abc.json"))
        #expect(byDirectory["/s/eio/.aire-trash/R2"]?.reachability == .unavailable)
        let arguments = try #require(runner.calls(to: "trash-list").first)
        #expect(Array(arguments.suffix(2)) == ["--forget", "R1-abc.json"])
    }

    @Test("Every script command is bounded on the login node")
    func scriptsAreBounded() async throws {
        let runner = FakeRemoteRunner { _, _, _ in ok(listingPayload("/u", names: ["a"])) }
        _ = try await RemoteFileService(runner: runner).listDirectory(settings: calder, path: "/u", showHidden: false)
        let command = try #require(runner.commands.first)
        #expect(command.contains("timeout -k 5 40 \"$hpc_python\" -I -c "))
    }

    @Test("A huge selection is staged as a file instead of an oversized command line")
    func stagedArguments() async throws {
        let many = (0..<3000).map { "/users/abcd1234/logs/slurm-\($0)-with-a-fairly-long-name.out" }
        let runner = FakeRemoteRunner { script, arguments, _ in
            #expect(script == "job-start")
            #expect(arguments.count == 1)
            #expect(arguments.first?.hasPrefix("@/tmp/hpc-monitor-args-") == true)
            return ok(["job": "/tmp/hpc-monitor-op-x", "pid": 42])
        }
        let job = try await RemoteFileService(runner: runner).startPermanentDelete(settings: calder, paths: many, protectedRoots: roots)
        #expect(job.paths.count == 3000)
        let upload = try #require(runner.transfers.first)
        #expect(upload.last?.hasPrefix("\(calder.hostname):/tmp/hpc-monitor-args-") == true)
        #expect(runner.commands.allSatisfy { $0.utf8.count <= RemoteFileService.commandBudget })
    }

    @Test("A permanent delete names the trash folder, so emptying a scratch run drops only that run's index entry")
    func permanentDeleteNamesTrashFolder() async throws {
        let run = "/scratch-calder/users/abcd1234/results/.aire-trash/20261013-100000-ab12"
        let runner = FakeRemoteRunner { script, _, _ in
            #expect(script == "job-start")
            return ok(["job": "/tmp/hpc-monitor-op-x", "pid": 42])
        }
        _ = try await RemoteFileService(runner: runner).startPermanentDelete(settings: calder, paths: [run], protectedRoots: roots)
        let arguments = try #require(runner.calls(to: "job-start").first)
        let name = try #require(arguments.firstIndex(of: "--trash-name"))
        #expect(arguments[name + 1] == RemoteFileService.trashDirectoryName)
        #expect(arguments.contains(run))
        #expect(!arguments.contains("--destination"))
    }
}

// MARK: - Browser model

/// Every wait below awaits the model's own work (`waitUntilIdle`), never a
/// wall-clock deadline: the suite runs in parallel with tests that hold the
/// main actor for seconds (the offscreen layout suite), and a deadline-based
/// poll used to give up before the listing could publish, so a force unwrap
/// of the missing listing took the whole test process down.
@Suite("File browser model", .timeLimit(.minutes(2)))
@MainActor
struct FileBrowserModelTests {
    /// The model holds its session weakly (in the app the session owns the
    /// model), so every test keeps the returned session alive to its end.
    private func makeModel(_ runner: FakeRemoteRunner) -> (FileBrowserModel, ClusterSession) {
        let session = ClusterSession(profile: catalogProfile(.calder), isEnabled: true, hostname: nil)
        let model = FileBrowserModel(service: RemoteFileService(runner: runner))
        model.attach(session: session)
        return (model, session)
    }

    @Test("A refresh during a navigation waits for it, so Back keeps the parent")
    func refreshDoesNotSupersedeNavigation() async throws {
        let runner = FakeRemoteRunner { script, arguments, _ in
            guard script == "listing", let path = arguments.first else {
                return ProcessResult(stdout: "", stderr: "", exitCode: 1)
            }
            if path == "/data/sub" {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            return ok(listingPayload(path, names: ["x"]))
        }
        let (model, session) = makeModel(runner)
        defer { withExtendedLifetime(session) {} }
        model.navigate(to: "/data")
        await model.waitUntilIdle()
        #expect(model.listing?.requestedPath == "/data")
        model.navigate(to: "/data/sub")
        model.refreshCurrent()          // e.g. an upload finishing right now
        #expect(model.isLoading)
        await model.waitUntilIdle()
        let listing = try #require(model.listing)
        #expect(listing.requestedPath == "/data/sub")
        #expect(!model.isLoading)
        #expect(model.backStack == ["/data"])
        #expect(model.canGoBack)
        #expect(runner.calls(to: "listing").map(\.first) == ["/data", "/data/sub", "/data/sub"])
    }

    @Test("A navigation superseded in flight never lands or enters history")
    func supersededNavigation() async throws {
        let runner = FakeRemoteRunner { script, arguments, _ in
            guard script == "listing", let path = arguments.first else {
                return ProcessResult(stdout: "", stderr: "", exitCode: 1)
            }
            if path == "/slow" {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            return ok(listingPayload(path, names: [String(path.dropFirst())]))
        }
        let (model, session) = makeModel(runner)
        defer { withExtendedLifetime(session) {} }
        model.navigate(to: "/a")
        await model.waitUntilIdle()
        model.navigate(to: "/slow")
        model.navigate(to: "/b")
        await model.waitUntilIdle()
        let listing = try #require(model.listing)
        #expect(listing.requestedPath == "/b")
        #expect(model.currentPath == "/b")
        #expect(model.visibleEntries.map(\.name) == ["b"])
        #expect(model.backStack == ["/a"])
        #expect(runner.calls(to: "listing").count == 3)
    }

    @Test("Visible entries are cached, sorted and filtered without a re-sort per read")
    func visibleEntries() async throws {
        let runner = FakeRemoteRunner { _, arguments, _ in
            ok(listingPayload(arguments.first ?? "/", names: ["file10", "file2", "File1", "notes"]))
        }
        let (model, session) = makeModel(runner)
        defer { withExtendedLifetime(session) {} }
        model.navigate(to: "/d")
        await model.waitUntilIdle()
        try #require(model.listing != nil, "the listing never published")
        #expect(model.visibleEntries.map(\.name) == ["File1", "file2", "file10", "notes"])
        model.filterText = "file"
        #expect(model.visibleEntries.map(\.name) == ["File1", "file2", "file10"])
        #expect(!model.isAwaitingServerFilter)      // a complete listing filters locally
        model.sortOrder = [KeyPathComparator(\RemoteFileEntry.sortName, order: .reverse)]
        #expect(model.visibleEntries.map(\.name) == ["file10", "file2", "File1"])
        await model.waitUntilIdle()
        #expect(runner.calls(to: "listing").count == 1)
    }

    @Test("Filtering a capped listing searches the whole folder on the server")
    func serverFilter() async throws {
        let runner = FakeRemoteRunner { _, arguments, _ in
            let path = arguments.first ?? "/"
            if arguments.count > 3 {
                return ok(listingPayload(path, names: ["slurm-2500.out"], total: 5000, filter: arguments[3]))
            }
            return ok(listingPayload(path, names: ["slurm-0001.out"], truncated: true, total: 5000))
        }
        let (model, session) = makeModel(runner)
        defer { withExtendedLifetime(session) {} }
        model.navigate(to: "/logs")
        await model.waitUntilIdle()
        let capped = try #require(model.listing, "the listing never published")
        #expect(capped.truncated)
        model.filterText = "2500"
        #expect(model.isAwaitingServerFilter)
        await model.waitUntilIdle()
        #expect(model.listing?.filter == "2500")
        #expect(model.visibleEntries.map(\.name) == ["slurm-2500.out"])
        #expect(!model.isAwaitingServerFilter)
        #expect(runner.calls(to: "listing").last?.last == "2500")
        model.filterText = ""
        await model.waitUntilIdle()
        #expect(model.listing?.filter == "")
        #expect(model.listing?.truncated == true)
        #expect(model.visibleEntries.map(\.name) == ["slurm-0001.out"])
        #expect(runner.calls(to: "listing").count == 3)
    }

    @Test("Rows already being trashed cannot be trashed again")
    func pendingPathsBlockDuplicates() async throws {
        let runner = FakeRemoteRunner { script, arguments, _ in
            switch script {
            case "listing":
                return ok(listingPayload(arguments.first ?? "/", names: ["a"]))
            case "trash-inspect":
                try? await Task.sleep(nanoseconds: 300_000_000)
                return ok(["home": "/users/x", "home_device": "1", "refused": [], "targets": [["path": "/w/a", "device": "1", "parent": "/w", "parent_writable": true]], "mount_trash": []])
            case "trash-execute":
                return lines([["moved": "/w/a", "to": "/users/x/.aire-trash/R/a", "directory": "/users/x/.aire-trash/R"], ["done": true]])
            default:
                return ProcessResult(stdout: "", stderr: "", exitCode: 1)
            }
        }
        let (model, session) = makeModel(runner)
        defer { withExtendedLifetime(session) {} }
        model.navigate(to: "/w")
        await model.waitUntilIdle()
        let entry = try #require(model.listing?.entries.first, "the listing never published")
        model.trash(entries: [entry])
        #expect(model.isPending(entry))
        #expect(model.isMutating)
        model.trash(entries: [entry])
        await model.waitUntilIdle()
        #expect(!model.isMutating)
        #expect(runner.calls(to: "trash-inspect").count == 1)
        #expect(model.banner?.persistent == true)
        #expect(model.banner?.message.contains("Moved 1 item") == true)
        // The trash reloads the folder once it has finished.
        #expect(runner.calls(to: "listing").count == 2)
    }

    /// Waits (bounded generously) for state the model publishes from its own
    /// tasks, for the trash model, which has no `waitUntilIdle`.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    @Test("A reload during Calculate Sizes still ends the measurement")
    func measurementSurvivesReload() async throws {
        let directory = "/users/abcd1234/.aire-trash/R"
        let runner = FakeRemoteRunner { script, _, command in
            if script == "trash-list" {
                return ok(["home_trash": "/users/abcd1234/.aire-trash", "runs": [
                    ["directory": directory, "location": "home", "count": 1, "entries": [], "error": NSNull()]
                ]])
            }
            if command.contains("du -sk") {
                try? await Task.sleep(nanoseconds: 300_000_000)
                return ProcessResult(stdout: "4\t\(directory)\n", stderr: "", exitCode: 0)
            }
            return ProcessResult(stdout: "", stderr: "", exitCode: 1)
        }
        let (model, session) = makeModel(runner)
        defer { withExtendedLifetime(session) {} }
        let trash = model.trash
        trash.load()
        try #require(await eventually { trash.hasLoaded && !trash.isLoading }, "the trash never listed")
        trash.measureSizes()
        #expect(trash.isMeasuring)
        trash.load()            // e.g. Refresh, or the browser trashing something
        #expect(await eventually { !trash.isMeasuring })
        #expect(trash.sizes.isEmpty)            // measured for a list that was replaced
        trash.measureSizes()
        #expect(await eventually { !trash.isMeasuring })
        #expect(trash.sizes[directory] == 4096)
    }

    @Test("Forget drops a missing run's index entry and says nothing was deleted")
    func forgetMissingRun() async throws {
        let runner = FakeRemoteRunner { script, arguments, _ in
            guard script == "trash-list" else {
                return ProcessResult(stdout: "", stderr: "", exitCode: 1)
            }
            let runs: [[String: Any]] = arguments.contains("--forget") ? [] : [[
                "directory": "/s/gone/.aire-trash/R1", "location": "mount", "state": "missing", "pointer": "R1-abc.json",
                "count": 0, "entries": [], "error": "Its folder /s/gone is no longer there"
            ]]
            return ok(["home_trash": "/users/abcd1234/.aire-trash", "runs": runs])
        }
        let (model, session) = makeModel(runner)
        defer { withExtendedLifetime(session) {} }
        let trash = model.trash
        trash.load()
        try #require(await eventually { trash.hasLoaded && !trash.isLoading }, "the trash never listed")
        let run = try #require(trash.runs.first)
        #expect(trash.reachableRuns.isEmpty)
        // Its contents are unknown, so it is never emptied.
        trash.empty([run])
        #expect(trash.busyDirectories.isEmpty)
        #expect(runner.calls(to: "job-start").isEmpty)
        trash.forget(run)
        #expect(await eventually { trash.runs.isEmpty && !trash.isLoading })
        #expect(trash.message?.contains("Nothing was deleted") == true)
        #expect(runner.calls(to: "trash-list").last?.suffix(2) == ["--forget", "R1-abc.json"])
    }

    @Test("Names that are not valid UTF-8 are never acted on")
    func lossyNames() async {
        let runner = FakeRemoteRunner { _, _, _ in ProcessResult(stdout: "", stderr: "", exitCode: 1) }
        let (model, session) = makeModel(runner)
        defer { withExtendedLifetime(session) {} }
        let entry = RemoteFileEntry(name: "caf\u{FFFD}", path: "/w/caf\u{FFFD}", kind: .file, nameIsLossy: true)
        model.trash(entries: [entry])
        model.deleteForever(entries: [entry])
        #expect(runner.commands.isEmpty)
        #expect(model.banner?.isError == true)
    }

    @Test("Symlinks to files are previewable and downloadable; FIFOs are neither")
    func entryGates() {
        let fileLink = RemoteFileEntry(name: "l", path: "/l", kind: .symlink, linkIsDir: false)
        let dirLink = RemoteFileEntry(name: "s", path: "/s", kind: .symlink, linkIsDir: true)
        let fifo = RemoteFileEntry(name: "p", path: "/p", kind: .other)
        #expect(!fileLink.isNavigable && fileLink.isPreviewable && fileLink.isDownloadable)
        #expect(dirLink.isNavigable && dirLink.isDirectoryLike && !dirLink.isDownloadable)
        #expect(!fifo.isNavigable && !fifo.isPreviewable && !fifo.isDownloadable)
    }
}
