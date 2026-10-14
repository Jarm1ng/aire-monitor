import Foundation
import Testing

// scripts/render_previews.sh hands its folders to run_tests.sh, which
// changes into the checkout before `swift test`. These tests run the real
// script inside a throwaway checkout whose run_tests.sh only records what it
// was given, so nothing is built or rendered.

private let previewScript = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("scripts/render_previews.sh")

@Suite("Preview render script", .timeLimit(.minutes(2)))
struct PreviewScriptTests {
    private struct Workspace {
        let base: String
        var checkout: String { base + "/checkout" }
        var caller: String { base + "/caller" }
        var record: String { base + "/record.txt" }

        init() throws {
            // realpath: bash reports the physical working directory
            // (/private/var/…), so compare against the same spelling.
            guard let resolved = realpath(NSTemporaryDirectory(), nil) else {
                throw CocoaError(.fileNoSuchFile)
            }
            defer { free(resolved) }
            base = String(cString: resolved) + "/hpc-preview-script-\(UUID().uuidString)"
            let manager = FileManager.default
            try manager.createDirectory(atPath: checkout + "/scripts", withIntermediateDirectories: true)
            try manager.createDirectory(atPath: checkout + "/Tests/AIREMonitorAppTests", withIntermediateDirectories: true)
            try manager.createDirectory(atPath: caller + "/data", withIntermediateDirectories: true)
            try manager.copyItem(atPath: previewScript.path, toPath: checkout + "/scripts/render_previews.sh")
            // Changes directory exactly like the real wrapper, then records.
            let standIn = """
            #!/usr/bin/env bash
            cd "$(dirname "${BASH_SOURCE[0]}")/../.."
            printf '%s\\n%s\\n' "$HPC_RENDER_PREVIEWS" "$HPC_PREVIEW_DATA" > '\(record)'
            """
            let runner = checkout + "/Tests/AIREMonitorAppTests/run_tests.sh"
            try Data(standIn.utf8).write(to: URL(fileURLWithPath: runner))
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner)
        }

        /// Runs the copied script from `caller`; returns its exit status and stderr.
        func render(_ arguments: [String]) throws -> (status: Int32, stderr: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [checkout + "/scripts/render_previews.sh"] + arguments
            process.currentDirectoryURL = URL(fileURLWithPath: caller)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            let pid = process.processIdentifier
            let watchdog = DispatchWorkItem {
                kill(pid, SIGKILL)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
            let stderr = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            return (process.terminationStatus, String(decoding: stderr, as: UTF8.self))
        }

        func remove() {
            try? FileManager.default.removeItem(atPath: base)
        }
    }

    @Test("Relative folders are resolved where the script was run, not in the checkout")
    func relativeFolders() throws {
        guard FileManager.default.fileExists(atPath: previewScript.path) else {
            Issue.record("scripts/render_previews.sh is missing")
            return
        }
        let workspace = try Workspace()
        defer { workspace.remove() }
        let result = try workspace.render(["out", "data"])
        #expect(result.status == 0, "\(result.stderr)")
        let recorded = try String(contentsOfFile: workspace.record, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(recorded == [workspace.caller + "/out", workspace.caller + "/data"])
        #expect(FileManager.default.fileExists(atPath: workspace.caller + "/out"))
        #expect(!FileManager.default.fileExists(atPath: workspace.checkout + "/out"))
    }

    @Test("A data folder that does not exist is an error, not a silent switch to fixtures")
    func missingDataFolder() throws {
        guard FileManager.default.fileExists(atPath: previewScript.path) else {
            Issue.record("scripts/render_previews.sh is missing")
            return
        }
        let workspace = try Workspace()
        defer { workspace.remove() }
        let result = try workspace.render(["out", "no-such-data"])
        #expect(result.status != 0)
        #expect(result.stderr.contains("data folder not found"))
        #expect(!FileManager.default.fileExists(atPath: workspace.record))
    }
}
