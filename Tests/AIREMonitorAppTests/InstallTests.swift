import Foundation
import HPCCore
import Testing
@testable import AIREMonitorApp

// Installing the app outside the checkout: how the app and the widget find
// the checkout again (the HPCProjectRoot Info.plist key), the install record
// the widget and the scripts share, scripts/install_app.sh itself and
// build_bundle.sh's install-source mode. The scripts run inside a throwaway
// checkout against small fake bundles, with HPC_INSTALL_DIR (or
// HPC_INSTALL_DEFAULT_DIR and HOME) in a temp folder and stubs for
// lsregister, `open` and `swift`, so nothing here touches /Applications,
// ~/Applications, LaunchServices or a real app.

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A private temp folder spelled the way bash reports it (/private/var/…),
/// removed by the caller.
private func makeResolvedTemporaryDirectory(_ prefix: String) throws -> String {
    guard let resolved = realpath(NSTemporaryDirectory(), nil) else {
        throw CocoaError(.fileNoSuchFile)
    }
    defer { free(resolved) }
    let path = String(cString: resolved) + "/\(prefix)-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

private func makeCheckout(at path: String) throws {
    try FileManager.default.createDirectory(atPath: path + "/scripts", withIntermediateDirectories: true)
    try Data("print()\n".utf8).write(to: URL(fileURLWithPath: path + "/" + ProjectRootLocator.markerScript))
}

private struct ProcessResult {
    var status: Int32
    var stdout: String
    var stderr: String
}

/// A command started with output in files (no pipe to fill up) and a 60 s
/// watchdog; `wait()` collects the result. Started on its own when a test
/// has to act while it runs.
private final class BackgroundCommand {
    private let process = Process()
    private let outputDirectory: String
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private let watchdog: DispatchWorkItem

    init(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: String? = nil
    ) throws {
        outputDirectory = try makeResolvedTemporaryDirectory("hpc-install-output")
        FileManager.default.createFile(atPath: outputDirectory + "/stdout", contents: nil)
        FileManager.default.createFile(atPath: outputDirectory + "/stderr", contents: nil)
        stdoutHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: outputDirectory + "/stdout"))
        stderrHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: outputDirectory + "/stderr"))
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        try process.run()
        let pid = process.processIdentifier
        watchdog = DispatchWorkItem {
            kill(pid, SIGKILL)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: watchdog)
    }

    func wait() throws -> ProcessResult {
        process.waitUntilExit()
        watchdog.cancel()
        defer { try? FileManager.default.removeItem(atPath: outputDirectory) }
        try stdoutHandle.close()
        try stderrHandle.close()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: (try? String(contentsOfFile: outputDirectory + "/stdout", encoding: .utf8)) ?? "",
            stderr: (try? String(contentsOfFile: outputDirectory + "/stderr", encoding: .utf8)) ?? ""
        )
    }
}

/// Runs a command to completion (see BackgroundCommand).
private func runCommand(
    _ executable: String,
    _ arguments: [String],
    environment: [String: String]? = nil,
    currentDirectory: String? = nil
) throws -> ProcessResult {
    try BackgroundCommand(executable, arguments, environment: environment, currentDirectory: currentDirectory).wait()
}

private func writeExecutable(_ path: String, _ text: String) throws {
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
}

/// A file's inode, as `stat -f %i` prints it; nil when it does not exist.
private func inode(of path: String) -> String? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let number = attributes[.systemFileNumber] as? NSNumber else {
        return nil
    }
    return number.stringValue
}

/// Stand-ins for lsregister and `open` in `<base>/bin`. lsregister logs its
/// arguments (`calls`) and, for each call, the bundle's inode and identifier
/// and whether a copy of the app was running from it then (`records`), so a
/// test can replay what LaunchServices would list. Both also log to one
/// event log, in order.
private struct LaunchServicesStubs {
    let base: String
    var folder: String { base + "/bin" }
    var lsregister: String { folder + "/lsregister" }
    private var callLog: String { base + "/lsregister.log" }
    private var recordLog: String { base + "/lsregister.records" }
    private var openLog: String { base + "/open.log" }
    private var eventLog: String { base + "/events.log" }

    struct Record {
        var flag: String
        var node: String
        var identifier: String
        var running: Bool
        var path: String
    }

    init(base: String) throws {
        self.base = base
        try FileManager.default.createDirectory(atPath: base + "/bin", withIntermediateDirectories: true)
        try writeExecutable(lsregister, """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(callLog)'
        printf 'lsregister %s\\n' "$*" >> '\(eventLog)'
        node=$(stat -f %i "$2" 2>/dev/null || echo missing)
        identifier=$(plutil -extract CFBundleIdentifier raw -o - "$2/Contents/Info.plist" 2>/dev/null || echo none)
        running=no
        if pgrep -f -- "$2/Contents/MacOS/AIREMonitorApp" >/dev/null 2>&1; then running=yes; fi
        printf '%s\\t%s\\t%s\\t%s\\t%s\\n' "$1" "$node" "$identifier" "$running" "$2" >> '\(recordLog)'
        """)
        // First on PATH, so `open` never reaches LaunchServices.
        try writeExecutable(folder + "/open", """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(openLog)'
        printf 'open %s\\n' "$*" >> '\(eventLog)'
        """)
    }

    private func lines(_ path: String) -> [String] {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    var calls: [String] { lines(callLog) }
    var openCalls: [String] { lines(openLog) }
    var events: [String] { lines(eventLog) }

    var records: [Record] {
        lines(recordLog).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5 else {
                return nil
            }
            return Record(flag: fields[0], node: fields[1], identifier: fields[2], running: fields[3] == "yes", path: fields[4])
        }
    }

    /// Registers a bundle the way an earlier build or launch did.
    func register(_ bundle: String) throws {
        let result = try runCommand(lsregister, ["-f", bundle])
        if result.status != 0 {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: result.stderr])
        }
    }

    /// The app bundles (as inodes) LaunchServices would still list after
    /// every -f and -u so far. It keeps track of a bundle by its file: `-u`
    /// on a path reaches only the bundle there at that moment, and a bundle
    /// deleted while registered stays listed, under an inode no file has.
    var registeredAppNodes: Set<String> {
        var nodes = Set<String>()
        for record in records where record.node != "missing" && record.identifier == WidgetAppLauncher.appBundleIdentifier {
            switch record.flag {
            case "-f": nodes.insert(record.node)
            case "-u": nodes.remove(record.node)
            default: break
            }
        }
        return nodes
    }
}

/// Builds a small native program that sleeps for its argument's seconds
/// (60 by default): an executable that really runs from a fake bundle,
/// which a copy of /bin/sleep cannot (macOS stops a platform binary that
/// was copied elsewhere).
private func compileSleeper(at path: String) throws {
    let source = path + ".c"
    try Data("""
    #include <stdlib.h>
    #include <unistd.h>
    int main(int argc, char **argv) { sleep(argc > 1 ? (unsigned)atoi(argv[1]) : 60); return 0; }

    """.utf8).write(to: URL(fileURLWithPath: source))
    let result = try runCommand("/usr/bin/cc", ["-o", path, source])
    if result.status != 0 {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: result.stderr])
    }
}

/// The sleeper, built once into the per-user temp folder and reused by later
/// runs (the folder name carries a version: bump it when the source
/// changes); nil when it could not be built. Each build goes to a name of
/// its own and is renamed into place, so concurrent runs never see half of
/// one.
private let sharedSleeperPath: String? = {
    guard let resolved = realpath(NSTemporaryDirectory(), nil) else {
        return nil
    }
    let folder = String(cString: resolved) + "/hpc-install-sleeper-v1"
    free(resolved)
    let path = folder + "/sleeper"
    let manager = FileManager.default
    if manager.isExecutableFile(atPath: path) {
        return path
    }
    let building = folder + "/sleeper-\(UUID().uuidString)"
    defer {
        try? manager.removeItem(atPath: building)
        try? manager.removeItem(atPath: building + ".c")
    }
    do {
        try manager.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try compileSleeper(at: building)
    } catch {
        return nil
    }
    return rename(building, path) == 0 || manager.isExecutableFile(atPath: path) ? path : nil
}()

private func sleeperExecutable() throws -> String {
    guard let path = sharedSleeperPath else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "could not build the test sleeper with /usr/bin/cc"])
    }
    return path
}

// MARK: - Finding the checkout

@Suite("Project root discovery")
struct ProjectRootDiscoveryTests {
    /// Three checkouts (with the marker script) and one folder without it.
    private struct Folders {
        let base: String
        var first: String { base + "/first" }
        var second: String { base + "/second" }
        var third: String { base + "/third" }
        var empty: String { base + "/empty" }

        init() throws {
            base = try makeResolvedTemporaryDirectory("hpc-root-tests")
            for checkout in [base + "/first", base + "/second", base + "/third"] {
                try makeCheckout(at: checkout)
            }
            try FileManager.default.createDirectory(atPath: base + "/empty", withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(atPath: base)
        }
    }

    private func locate(
        environment: [String: String] = [:],
        plist: Any? = nil,
        currentDirectory: String = "/",
        bundlePath: String = "/Applications/Leeds HPC Monitor.app"
    ) -> String? {
        ProjectRootLocator.locate(
            environment: environment,
            infoPlistValue: plist,
            currentDirectory: currentDirectory,
            bundlePath: bundlePath
        )
    }

    @Test("Candidates come in the documented order")
    func candidateOrder() {
        let candidates = ProjectRootLocator.candidates(
            environment: ["AIRE_PROJECT_ROOT": "/old", "HPC_PROJECT_ROOT": "/env", "UNRELATED": "/x"],
            infoPlistValue: "/plist",
            currentDirectory: "/cwd",
            bundlePath: "/checkout/.runtime/AIREMonitorApp.app"
        )
        #expect(candidates == ["/env", "/old", "/plist", "/cwd", "/checkout"])
    }

    @Test("An explicit environment variable beats the Info.plist key")
    func environmentFirst() throws {
        let folders = try Folders()
        defer { folders.remove() }
        #expect(locate(environment: ["HPC_PROJECT_ROOT": folders.first], plist: folders.second) == folders.first)
        #expect(locate(environment: ["AIRE_PROJECT_ROOT": folders.first], plist: folders.second) == folders.first)
        // One without the collector is skipped, not trusted.
        #expect(locate(environment: ["HPC_PROJECT_ROOT": folders.empty], plist: folders.second) == folders.second)
    }

    @Test("An installed bundle finds its checkout through HPCProjectRoot, before the working directory")
    func infoPlistKey() throws {
        let folders = try Folders()
        defer { folders.remove() }
        // What a LaunchServices-less start of /Applications/... looks like:
        // no environment, working directory /, bundle grandparent /.
        #expect(locate(plist: folders.second) == folders.second)
        #expect(locate(plist: folders.second, currentDirectory: folders.third) == folders.second)
    }

    @Test("A stale, relative or malformed HPCProjectRoot falls through to the other lookups")
    func invalidInfoPlistValues() throws {
        let folders = try Folders()
        defer { folders.remove() }
        #expect(locate(plist: folders.empty, currentDirectory: folders.third) == folders.third)
        #expect(locate(plist: folders.base + "/moved-away", currentDirectory: folders.third) == folders.third)
        #expect(locate(plist: "first", currentDirectory: folders.base) == nil)
        #expect(locate(plist: NSNumber(value: 5), currentDirectory: folders.third) == folders.third)
        #expect(locate(plist: "", currentDirectory: folders.third) == folders.third)
        #expect(ProjectRootLocator.infoPlistRoot(["/x"]) == nil)
        #expect(ProjectRootLocator.infoPlistRoot("/x") == "/x")
    }

    @Test("A bundle in <checkout>/.runtime still finds its checkout; nothing valid gives nil")
    func bundleGrandparent() throws {
        let folders = try Folders()
        defer { folders.remove() }
        #expect(locate(bundlePath: folders.third + "/.runtime/AIREMonitorApp.app") == folders.third)
        #expect(locate(plist: folders.empty, currentDirectory: folders.empty, bundlePath: folders.empty + "/x/y.app") == nil)
    }

    @Test("The app adds the saved root last, then the working directory")
    func appModelFallbacks() throws {
        let folders = try Folders()
        defer { folders.remove() }
        func root(plist: Any?, saved: String?, currentDirectory: String = "/") -> String {
            AppModel.defaultProjectRoot(
                environment: [:],
                infoPlistValue: plist,
                currentDirectory: currentDirectory,
                bundlePath: "/Applications/Leeds HPC Monitor.app",
                savedRoot: saved
            )
        }
        #expect(root(plist: folders.first, saved: folders.second) == folders.first)
        #expect(root(plist: nil, saved: folders.second) == folders.second)
        #expect(root(plist: folders.empty, saved: folders.empty, currentDirectory: folders.empty) == folders.empty)
        #expect(MonitorService.collectorScript == ProjectRootLocator.markerScript)
    }

    @Test("build_bundle.sh writes the key the app reads")
    func buildScriptWritesKey() throws {
        let text = try String(contentsOf: repositoryRoot.appendingPathComponent("scripts/build_bundle.sh"), encoding: .utf8)
        #expect(text.contains("plutil -insert \(ProjectRootLocator.infoPlistKey) -string \"$ROOT_DIR\""))
        #expect(text.contains("LSEnvironment.HPC_PROJECT_ROOT"))
    }
}

// MARK: - The install record

@Suite("Install record")
struct AppInstallRecordTests {
    @Test("Only an absolute .app path on the first line counts")
    func parsing() {
        #expect(AppInstallRecord.parse("/Applications/Leeds HPC Monitor.app\n") == "/Applications/Leeds HPC Monitor.app")
        #expect(AppInstallRecord.parse("/Applications/Leeds HPC Monitor.app") == "/Applications/Leeds HPC Monitor.app")
        #expect(AppInstallRecord.parse("/a/Leeds HPC Monitor.app\n/b/other.app\n") == "/a/Leeds HPC Monitor.app")
        #expect(AppInstallRecord.parse("Leeds HPC Monitor.app\n") == nil)
        #expect(AppInstallRecord.parse("/Applications/Leeds HPC Monitor\n") == nil)
        #expect(AppInstallRecord.parse("") == nil)
        #expect(AppInstallRecord.parse("\n/Applications/Leeds HPC Monitor.app") == nil)
    }

    @Test("The record counts only while it names a bundle with the app's identifier")
    func validation() throws {
        let base = try makeResolvedTemporaryDirectory("hpc-record-tests")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let checkout = base + "/checkout"
        try makeCheckout(at: checkout)
        try FileManager.default.createDirectory(atPath: checkout + "/.runtime", withIntermediateDirectories: true)
        let bundle = base + "/Apps/Leeds HPC Monitor.app"
        let recordURL = URL(fileURLWithPath: checkout + "/" + AppInstallRecord.recordRelativePath)

        #expect(AppInstallRecord.installedAppPath(projectRoot: checkout) == nil)
        try Data("\(bundle)\n".utf8).write(to: recordURL)
        #expect(AppInstallRecord.installedAppPath(projectRoot: checkout) == nil)

        try FakeAppBundle.write(at: bundle, identifier: "com.example.other", stamp: "s")
        #expect(AppInstallRecord.installedAppPath(projectRoot: checkout) == nil)
        try FakeAppBundle.write(at: bundle, identifier: WidgetAppLauncher.appBundleIdentifier, stamp: "s")
        #expect(AppInstallRecord.installedAppPath(projectRoot: checkout) == bundle)
        #expect(AppInstallRecord.bundleIdentifier(atBundlePath: bundle) == WidgetAppLauncher.appBundleIdentifier)
    }

    @Test("The scripts use the same record, identifier and bundle name")
    func scriptsAgree() throws {
        let install = try String(contentsOf: repositoryRoot.appendingPathComponent("scripts/install_app.sh"), encoding: .utf8)
        #expect(install.contains("BUNDLE_ID=\"\(WidgetAppLauncher.appBundleIdentifier)\""))
        #expect(install.contains("RECORD=\"$RUNTIME_DIR/installed_app_path\""))
        #expect(AppInstallRecord.recordRelativePath == ".runtime/installed_app_path")
        #expect(install.contains("APP_NAME=\"Leeds HPC Monitor\""))
    }
}

// MARK: - Fake bundles

/// A minimal app bundle with the app's layout, signed ad hoc like the real
/// one. Its executable is a copy of the sleeper, so a running copy of the
/// app is that executable really running from the bundle (see
/// FakeRunningCopy), as the kernel then reports it.
private enum FakeAppBundle {
    static func write(
        at path: String,
        identifier: String,
        stamp: String,
        sign: Bool = false
    ) throws {
        let manager = FileManager.default
        try? manager.removeItem(atPath: path)
        try manager.createDirectory(atPath: path + "/Contents/MacOS", withIntermediateDirectories: true)
        try manager.createDirectory(atPath: path + "/Contents/Resources", withIntermediateDirectories: true)
        try manager.copyItem(atPath: try sleeperExecutable(), toPath: path + "/Contents/MacOS/AIREMonitorApp")
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": "AIREMonitorApp",
            "CFBundleName": "Leeds HPC Monitor",
            "CFBundlePackageType": "APPL",
            "HPCBuildStamp": stamp,
            "HPCBuildConfiguration": "release",
            "HPCSourceRevision": "test",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        if sign {
            let result = try runCommand(
                "/usr/bin/codesign",
                ["--force", "--sign", "-", "--identifier", identifier, "--timestamp=none", path]
            )
            if result.status != 0 {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: result.stderr])
            }
        }
    }

    static func stamp(at path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path + "/Contents/Info.plist"),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return plist["HPCBuildStamp"] as? String
    }
}

/// A process the scripts may take for the app: `/bin/bash -c script
/// argument`, usually exec'ing into its final form.
private final class FakeRunningCopy {
    let process = Process()

    /// The bundle's executable (the sleeper), started by the bundle's path
    /// as given (through a link, say). It exits by itself after `seconds`,
    /// as a copy that quits when asked does.
    convenience init(bundle: String, seconds: Int = 60) throws {
        try self.init(script: "exec \"$0\" \(seconds)", argument: bundle + "/Contents/MacOS/AIREMonitorApp")
    }

    init(script: String, argument: String) throws {
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script, argument]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Wait (bounded) until bash has exec'd, so the scripts see the final
        // process rather than the shell.
        let pid = String(process.processIdentifier)
        for _ in 0..<40 {
            let name = try runCommand("/bin/ps", ["-o", "ucomm=", "-p", pid]).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && name != "bash" {
                return
            }
            usleep(50_000)
        }
    }

    var isRunning: Bool { process.isRunning }

    func stop() {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}

// MARK: - scripts/install_app.sh

@Suite("Install script", .serialized, .timeLimit(.minutes(3)))
struct InstallScriptTests {
    private struct Workspace {
        let base: String
        let stubs: LaunchServicesStubs
        var checkout: String { base + "/checkout" }
        var installDirectory: String { base + "/Apps" }
        var source: String { checkout + "/.runtime/AIREMonitorApp.app" }
        var target: String { installDirectory + "/Leeds HPC Monitor.app" }
        var record: String { checkout + "/.runtime/installed_app_path" }
        var buildMarker: String { base + "/build-called" }

        init() throws {
            base = try makeResolvedTemporaryDirectory("hpc-install-script")
            stubs = try LaunchServicesStubs(base: base)
            let manager = FileManager.default
            try makeCheckout(at: checkout)
            try manager.createDirectory(atPath: checkout + "/.runtime", withIntermediateDirectories: true)
            try manager.copyItem(
                atPath: repositoryRoot.appendingPathComponent("scripts/install_app.sh").path,
                toPath: checkout + "/scripts/install_app.sh"
            )
            // --skip-build must never build: this stand-in only leaves a mark.
            try writeExecutable(checkout + "/scripts/build_bundle.sh", """
            #!/usr/bin/env bash
            touch '\(buildMarker)'
            exit 1
            """)
        }

        func makeSource(stamp: String) throws {
            try FakeAppBundle.write(at: source, identifier: WidgetAppLauncher.appBundleIdentifier, stamp: stamp, sign: true)
        }

        /// A build_bundle.sh stand-in that fails with `status` (75: it gave
        /// up waiting for its own lock).
        func useFailingBuildStub(status: Int32) throws {
            try writeExecutable(checkout + "/scripts/build_bundle.sh", """
            #!/usr/bin/env bash
            touch '\(buildMarker)'
            exit \(status)
            """)
        }

        /// Replaces the build_bundle.sh stand-in with one that "builds" a
        /// bundle stamped `stamp` into .runtime/.
        func useBuildStub(producing stamp: String) throws {
            let next = base + "/next.app"
            try FakeAppBundle.write(at: next, identifier: WidgetAppLauncher.appBundleIdentifier, stamp: stamp, sign: true)
            try writeExecutable(checkout + "/scripts/build_bundle.sh", """
            #!/usr/bin/env bash
            touch '\(buildMarker)'
            rm -rf '\(source)'
            /usr/bin/ditto '\(next)' '\(source)'
            """)
        }

        /// A folder with a `perl` that steps in when rename_path moves a
        /// staged bundle onto the install, and runs /usr/bin/perl for
        /// everything else. "fail": the move fails. "recreate": it fails
        /// after a folder appeared at the install, as if something else had
        /// made it. "occupy": that folder appears and the real rename(2) is
        /// tried. "kill": the run is killed (SIGKILL) between its two moves.
        func makeRenameShim(mode: String) throws -> String {
            let folder = base + "/shim-\(mode)"
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let occupy = "mkdir -p '\(target)/Contents' && echo other > '\(target)/Contents/other'"
            let action: String
            switch mode {
            case "recreate": action = occupy + "; exit 1"
            case "occupy": action = occupy
            case "kill": action = "kill -KILL $PPID; sleep 1; exit 1"
            default: action = "exit 1"
            }
            try writeExecutable(folder + "/perl", """
            #!/bin/bash
            if [[ "$1" == -e && "${@: -1}" == '\(target)' && "${@: -2:1}" == *'/.Leeds HPC Monitor.install.'*'/Leeds HPC Monitor.app' ]]; then
                \(action)
            fi
            exec /usr/bin/perl "$@"
            """)
            return folder
        }

        /// A folder with a `perl` that, when rename_path first moves the
        /// install into a staging folder (--uninstall), starts a copy from
        /// it just before: one started between the quit and the move. That
        /// copy's process id goes to `pidFile`.
        func makeLateStartShim(pidFile: String) throws -> String {
            let folder = base + "/shim-late"
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try writeExecutable(folder + "/perl", """
            #!/bin/bash
            if [[ "$1" == -e && "${@: -2:1}" == '\(target)' && "${@: -1}" == *'/.Leeds HPC Monitor.install.'*'/previous.app' && ! -e '\(pidFile)' ]]; then
                '\(target)/Contents/MacOS/AIREMonitorApp' 60 </dev/null >/dev/null 2>&1 &
                echo $! > '\(pidFile)'
                for _ in $(seq 1 100); do
                    [[ "$(ps -o ucomm= -p $! 2>/dev/null)" != *AIREMonitorApp* ]] || break
                    sleep 0.05
                done
            fi
            exec /usr/bin/perl "$@"
            """)
            return folder
        }

        /// A folder with a `ditto` that waits (at most 20 s) until `gate`
        /// exists, so a test can act while the install is staging.
        func makeGatedDittoShim(gate: String) throws -> String {
            let folder = base + "/shim-ditto"
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try writeExecutable(folder + "/ditto", """
            #!/bin/bash
            for _ in $(seq 1 400); do
                [[ ! -e '\(gate)' ]] || break
                sleep 0.05
            done
            exec /usr/bin/ditto "$@"
            """)
            return folder
        }

        /// `environment` entries are set, or removed when nil, after the
        /// defaults. `pathPrefix` goes before the stubs on PATH.
        func startInstall(
            _ arguments: [String],
            quitTimeout: Int = 1,
            into directory: String? = nil,
            environment overrides: [String: String?] = [:],
            pathPrefix: String? = nil
        ) throws -> BackgroundCommand {
            var environment = ProcessInfo.processInfo.environment
            environment["HPC_INSTALL_DIR"] = directory ?? installDirectory
            environment["HPC_LSREGISTER"] = stubs.lsregister
            environment["HPC_INSTALL_QUIT_TIMEOUT"] = String(quitTimeout)
            environment["PATH"] = ([pathPrefix, stubs.folder].compactMap { $0 } + [environment["PATH"] ?? "/usr/bin:/bin"])
                .joined(separator: ":")
            for key in ["HPC_INSTALL_NO_OPEN", "HPC_INSTALL_DEFAULT_DIR", "HPC_INSTALL_LOCK_TIMEOUT", "HPC_INSTALL_APP_LOCKED"] {
                environment.removeValue(forKey: key)
            }
            for (key, value) in overrides {
                environment[key] = value
            }
            return try BackgroundCommand(
                "/bin/bash",
                [checkout + "/scripts/install_app.sh"] + arguments,
                environment: environment,
                currentDirectory: base
            )
        }

        func install(
            _ arguments: [String],
            quitTimeout: Int = 1,
            into directory: String? = nil,
            environment overrides: [String: String?] = [:],
            pathPrefix: String? = nil
        ) throws -> ProcessResult {
            try startInstall(
                arguments,
                quitTimeout: quitTimeout,
                into: directory,
                environment: overrides,
                pathPrefix: pathPrefix
            ).wait()
        }

        var lsregisterCalls: [String] { stubs.calls }
        var openCalls: [String] { stubs.openCalls }

        var installDirectoryEntries: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: installDirectory)) ?? []).sorted()
        }

        /// Staging folders left in the install folder, as full paths.
        var stagingFolders: [String] {
            installDirectoryEntries.filter { $0.hasPrefix(".Leeds HPC Monitor.install.") }.map { installDirectory + "/" + $0 }
        }

        func remove() {
            try? FileManager.default.removeItem(atPath: base)
        }
    }

    @Test("Installs a verified copy, records it and registers only that copy")
    func installs() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")

        let result = try workspace.install(["--skip-build", "--no-open"])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(AppInstallRecord.bundleIdentifier(atBundlePath: workspace.target) == WidgetAppLauncher.appBundleIdentifier)
        #expect(FakeAppBundle.stamp(at: workspace.target) == "one")
        let verify = try runCommand("/usr/bin/codesign", ["--verify", "--strict", workspace.target])
        #expect(verify.status == 0, "\(verify.stderr)")
        #expect(try String(contentsOfFile: workspace.record, encoding: .utf8) == workspace.target + "\n")
        // The widget reads the same record by the same rule.
        #expect(AppInstallRecord.installedAppPath(projectRoot: workspace.checkout) == workspace.target)
        #expect(workspace.lsregisterCalls == ["-f \(workspace.target)", "-u \(workspace.source)"])
        // No staging folder left behind, and no build.
        #expect(workspace.installDirectoryEntries == ["Leeds HPC Monitor.app"])
        #expect(!FileManager.default.fileExists(atPath: workspace.buildMarker))

        let printed = try workspace.install(["--installed-path"])
        #expect(printed.status == 0)
        #expect(printed.stdout == workspace.target + "\n")
    }

    @Test("An unchanged install is left alone; a changed bundle replaces it")
    func updates() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        #expect(try workspace.install(["--skip-build", "--no-open"]).status == 0)

        let again = try workspace.install(["--skip-build", "--no-open"])
        #expect(again.status == 0, "\(again.stderr)")
        #expect(again.stdout.contains("is up to date"))

        try workspace.makeSource(stamp: "two")
        let update = try workspace.install(["--skip-build", "--no-open"])
        #expect(update.status == 0, "\(update.stderr)")
        #expect(update.stdout.contains("Installed "))
        #expect(FakeAppBundle.stamp(at: workspace.target) == "two")
        #expect(workspace.installDirectoryEntries == ["Leeds HPC Monitor.app"])
    }

    @Test("Installing somewhere else moves the install, so only one copy stays")
    func moves() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        #expect(try workspace.install(["--skip-build", "--no-open"]).status == 0)

        let elsewhere = workspace.base + "/Elsewhere"
        let moved = try workspace.install(["--skip-build", "--no-open"], into: elsewhere)
        #expect(moved.status == 0, "\(moved.stderr)")
        let newTarget = elsewhere + "/Leeds HPC Monitor.app"
        #expect(AppInstallRecord.bundleIdentifier(atBundlePath: newTarget) == WidgetAppLauncher.appBundleIdentifier)
        #expect(!FileManager.default.fileExists(atPath: workspace.target))
        #expect(try String(contentsOfFile: workspace.record, encoding: .utf8) == newTarget + "\n")
        #expect(workspace.lsregisterCalls.contains("-u \(workspace.target)"))
        #expect(workspace.lsregisterCalls.contains("-f \(newTarget)"))
    }

    @Test("A running copy that does not quit stops the update; --force replaces it")
    func runningCopy() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        #expect(try workspace.install(["--skip-build", "--no-open"]).status == 0)
        try workspace.makeSource(stamp: "two")

        let running = try FakeRunningCopy(bundle: workspace.target)
        defer { running.stop() }
        let refused = try workspace.install(["--skip-build", "--no-open"])
        #expect(refused.status == WidgetAppLauncher.appStillRunningExitStatus, "\(refused.stderr)")
        #expect(refused.stderr.contains("is still running, so nothing was changed"))
        #expect(FakeAppBundle.stamp(at: workspace.target) == "one")
        #expect(workspace.installDirectoryEntries == ["Leeds HPC Monitor.app"])
        #expect(running.isRunning)

        let forced = try workspace.install(["--skip-build", "--no-open", "--force"])
        #expect(forced.status == 0, "\(forced.stderr)")
        #expect(FakeAppBundle.stamp(at: workspace.target) == "two")
        #expect(forced.stdout.contains("not reopened"))
        running.process.waitUntilExit()
        #expect(running.process.terminationReason == .uncaughtSignal)
        #expect(running.process.terminationStatus == SIGTERM)
    }

    @Test("A copy still running from .runtime must quit even when the install is current")
    func runtimeCopy() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        #expect(try workspace.install(["--skip-build", "--no-open"]).status == 0)

        let running = try FakeRunningCopy(bundle: workspace.source)
        defer { running.stop() }
        let refused = try workspace.install(["--skip-build", "--no-open"])
        #expect(refused.status == WidgetAppLauncher.appStillRunningExitStatus, "\(refused.stderr)")
        #expect(running.isRunning)
    }

    @Test("Something else under the app's name is never overwritten")
    func foreignBundle() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        try FakeAppBundle.write(at: workspace.target, identifier: "com.example.other", stamp: "theirs")

        let result = try workspace.install(["--skip-build", "--no-open"])
        #expect(result.status == 1)
        #expect(result.stderr.contains("is not Leeds HPC Monitor"))
        #expect(AppInstallRecord.bundleIdentifier(atBundlePath: workspace.target) == "com.example.other")
        #expect(!FileManager.default.fileExists(atPath: workspace.record))
        #expect(workspace.lsregisterCalls.isEmpty)
    }

    @Test("--skip-build without a built bundle explains what to do")
    func missingBundle() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let result = try workspace.install(["--skip-build", "--no-open"])
        #expect(result.status == 1)
        #expect(result.stderr.contains("without --skip-build"))
        #expect(!FileManager.default.fileExists(atPath: workspace.buildMarker))
        #expect(!FileManager.default.fileExists(atPath: workspace.target))
    }

    @Test("--uninstall removes the app, unregisters it and forgets the record")
    func uninstall() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        #expect(try workspace.install(["--skip-build", "--no-open"]).status == 0)
        let installedNode = try #require(inode(of: workspace.target))

        let result = try workspace.install(["--uninstall"])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("Removed \(workspace.target)."))
        #expect(!FileManager.default.fileExists(atPath: workspace.target))
        #expect(!FileManager.default.fileExists(atPath: workspace.record))
        // No staging folder left behind.
        #expect(workspace.installDirectoryEntries.isEmpty)
        // The install is unregistered once it has been moved out of the way,
        // while it still exists, then the checkout's own bundle registered.
        let last = Array(workspace.stubs.records.suffix(2))
        #expect(last.map(\.flag) == ["-u", "-f"])
        #expect(last.first?.node == installedNode)
        #expect(last.first?.identifier == WidgetAppLauncher.appBundleIdentifier)
        #expect(last.last?.path == workspace.source)
        #expect(try workspace.install(["--installed-path"]).status == 1)
        #expect(AppInstallRecord.installedAppPath(projectRoot: workspace.checkout) == nil)

        let again = try workspace.install(["--uninstall"])
        #expect(again.status == 0)
        #expect(again.stdout.contains("is not installed"))
    }

    @Test("Bad arguments are usage errors")
    func usage() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        #expect(try workspace.install(["--bogus"]).status == 2)
        #expect(try workspace.install(["--help"]).stdout.contains("--installed-path"))
    }

    @Test("The same folder under another spelling (letter case, a link, an old record) is never treated as a move")
    func sameFolderOtherSpelling() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        #expect(try workspace.install(["--skip-build", "--no-open"]).status == 0)

        func expectInstallKept(_ result: ProcessResult, stamp: String, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(result.status == 0, "\(result.stderr)", sourceLocation: sourceLocation)
            #expect(!result.stdout.contains("Moving the install"), sourceLocation: sourceLocation)
            #expect(!result.stdout.contains("Removed the old install"), sourceLocation: sourceLocation)
            #expect(FakeAppBundle.stamp(at: workspace.target) == stamp, sourceLocation: sourceLocation)
            #expect(workspace.installDirectoryEntries == ["Leeds HPC Monitor.app"], sourceLocation: sourceLocation)
            // Recorded under its real spelling, and never unregistered.
            #expect(
                (try? String(contentsOfFile: workspace.record, encoding: .utf8)) == workspace.target + "\n",
                sourceLocation: sourceLocation
            )
            #expect(AppInstallRecord.installedAppPath(projectRoot: workspace.checkout) == workspace.target, sourceLocation: sourceLocation)
            #expect(
                !workspace.lsregisterCalls.contains { $0.hasPrefix("-u ") && $0.hasSuffix("/Leeds HPC Monitor.app") },
                sourceLocation: sourceLocation
            )
        }

        // Another letter case names the same folder on a case-insensitive
        // volume (the macOS default); skipped on a case-sensitive one.
        let upper = workspace.base + "/APPS"
        if FileManager.default.fileExists(atPath: upper) {
            let result = try workspace.install(["--skip-build", "--no-open"], into: upper)
            #expect(result.stdout.contains("is up to date"))
            expectInstallKept(result, stamp: "one")
        }

        // A symbolic link to the folder, with a changed bundle to install.
        let link = workspace.base + "/AppsLink"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: workspace.installDirectory)
        try workspace.makeSource(stamp: "two")
        let linked = try workspace.install(["--skip-build", "--no-open"], into: link)
        #expect(linked.stdout.contains("Installed \(workspace.target) "))
        expectInstallKept(linked, stamp: "two")

        // A record naming the folder through the link (an older install):
        // the same bundle by device and inode.
        try Data((link + "/Leeds HPC Monitor.app\n").utf8).write(to: URL(fileURLWithPath: workspace.record))
        let viaRecord = try workspace.install(["--skip-build", "--no-open"])
        #expect(viaRecord.stdout.contains("is up to date"))
        expectInstallKept(viaRecord, stamp: "two")
        #expect(try workspace.install(["--installed-path"]).stdout == workspace.target + "\n")
    }

    @Test("A running install is found when its folder is given through a link")
    func runningCopyThroughLink() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        #expect(try workspace.install(["--skip-build", "--no-open"]).status == 0)
        let link = workspace.base + "/AppsLink"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: workspace.installDirectory)
        try workspace.makeSource(stamp: "two")

        // LaunchServices starts the app by its real path.
        let running = try FakeRunningCopy(bundle: workspace.target)
        defer { running.stop() }
        let refused = try workspace.install(["--skip-build", "--no-open"], into: link)
        #expect(refused.status == WidgetAppLauncher.appStillRunningExitStatus, "\(refused.stderr)")
        #expect(FakeAppBundle.stamp(at: workspace.target) == "one")
        #expect(running.isRunning)
    }

    @Test("A first install whose .runtime copy does not quit builds nothing and leaves that copy registered and running")
    func failedFirstInstall() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        try workspace.useBuildStub(producing: "two")
        let running = try FakeRunningCopy(bundle: workspace.source)
        defer { running.stop() }

        let refused = try workspace.install(["--no-open"])
        #expect(refused.status == WidgetAppLauncher.appStillRunningExitStatus, "\(refused.stderr)")
        #expect(refused.stderr.contains("quit it, then run this again"))
        // Asked before the build, so its bundle is still the one it runs,
        // and it was never unregistered.
        #expect(!FileManager.default.fileExists(atPath: workspace.buildMarker))
        #expect(FakeAppBundle.stamp(at: workspace.source) == "one")
        #expect(workspace.lsregisterCalls.isEmpty)
        #expect(running.isRunning)
        #expect(!FileManager.default.fileExists(atPath: workspace.record))
        #expect(!FileManager.default.fileExists(atPath: workspace.target))

        running.stop()
        let installed = try workspace.install(["--no-open"])
        #expect(installed.status == 0, "\(installed.stderr)")
        #expect(FileManager.default.fileExists(atPath: workspace.buildMarker))
        #expect(FakeAppBundle.stamp(at: workspace.target) == "two")
        // .runtime is unregistered only once the installed copy is in place.
        #expect(workspace.lsregisterCalls == ["-f \(workspace.target)", "-u \(workspace.source)"])
    }

    @Test("--installed-path answers before install options are checked")
    func installedPathFirst() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        #expect(try workspace.install(["--skip-build", "--no-open"]).status == 0)

        let printed = try workspace.install(["--installed-path"], environment: ["HPC_INSTALL_QUIT_TIMEOUT": "soon"])
        #expect(printed.status == 0, "\(printed.stderr)")
        #expect(printed.stdout == workspace.target + "\n")
        let refused = try workspace.install(["--skip-build", "--no-open"], environment: ["HPC_INSTALL_QUIT_TIMEOUT": "soon"])
        #expect(refused.status == 2)
        #expect(refused.stderr.contains("HPC_INSTALL_QUIT_TIMEOUT"))
    }

    @Test("A failed swap never deletes the previous install: it is kept where the error says, then put back")
    func failedSwapKeepsPreviousInstall() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        #expect(try workspace.install(["--skip-build", "--no-open"]).status == 0)
        try workspace.makeSource(stamp: "two")

        // The new bundle cannot be moved in, and a folder appears in its
        // place: putting the old one back would mean moving it into that.
        let shim = try workspace.makeRenameShim(mode: "recreate")
        let failed = try workspace.install(["--skip-build", "--no-open"], pathPrefix: shim)
        #expect(failed.status == 1)
        #expect(failed.stderr.contains("could not put the previous install back"))
        let staging = workspace.stagingFolders
        #expect(staging.count == 1)
        let kept = (staging.first ?? workspace.installDirectory) + "/previous.app"
        #expect(FakeAppBundle.stamp(at: kept) == "one")
        #expect(failed.stderr.contains(kept))
        #expect(!FileManager.default.fileExists(atPath: workspace.target + "/previous.app"))

        // While something else is in its place, the next run keeps it too.
        let blocked = try workspace.install(["--skip-build", "--no-open"])
        #expect(blocked.status == 1)
        #expect(FakeAppBundle.stamp(at: kept) == "one")

        // Once the place is free, the next run puts it back, removes the
        // staging folder and updates as usual.
        try FileManager.default.removeItem(atPath: workspace.target)
        let next = try workspace.install(["--skip-build", "--no-open"])
        #expect(next.status == 0, "\(next.stderr)")
        #expect(next.stdout.contains("Put back the install"))
        #expect(FakeAppBundle.stamp(at: workspace.target) == "two")
        #expect(workspace.installDirectoryEntries == ["Leeds HPC Monitor.app"])
    }

    @Test("Write access is checked before anything is asked to quit")
    func writeAccessFirst() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        #expect(try workspace.install(["--skip-build", "--no-open"]).status == 0)
        try workspace.makeSource(stamp: "two")
        // As for an install made with sudo: this account cannot move it.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: workspace.target)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: workspace.target) }
        let running = try FakeRunningCopy(bundle: workspace.target)
        defer { running.stop() }

        let result = try workspace.install(["--skip-build", "--no-open", "--force"])
        #expect(result.status == 1)
        #expect(result.stderr.contains("is not writable"))
        #expect(!result.stdout.contains("Asking"))
        #expect(running.isRunning)
        #expect(FakeAppBundle.stamp(at: workspace.target) == "one")
        #expect(workspace.installDirectoryEntries == ["Leeds HPC Monitor.app"])
    }

    @Test("When the swap fails after the app quit, the previous install is put back and opened again")
    func reopensAfterFailedSwap() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        #expect(try workspace.install(["--skip-build", "--no-open"]).status == 0)
        try workspace.makeSource(stamp: "two")
        let shim = try workspace.makeRenameShim(mode: "fail")

        let running = try FakeRunningCopy(bundle: workspace.target)
        defer { running.stop() }
        let failed = try workspace.install(["--skip-build", "--force"], pathPrefix: shim)
        #expect(failed.status == 1)
        #expect(failed.stderr.contains("the previous install was put back"))
        running.process.waitUntilExit()
        #expect(FakeAppBundle.stamp(at: workspace.target) == "one")
        #expect(workspace.installDirectoryEntries == ["Leeds HPC Monitor.app"])
        #expect(workspace.openCalls == [workspace.target])

        // With --no-open it only says so.
        let again = try FakeRunningCopy(bundle: workspace.target)
        defer { again.stop() }
        let quiet = try workspace.install(["--skip-build", "--force", "--no-open"], pathPrefix: shim)
        #expect(quiet.status == 1)
        #expect(quiet.stderr.contains("is not reopened (--no-open)"))
        #expect(workspace.openCalls == [workspace.target])
    }

    @Test("Staging folders a killed run left behind are unregistered and removed")
    func leftoverStaging() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        #expect(try workspace.install(["--skip-build", "--no-open"]).status == 0)
        let leftover = workspace.installDirectory + "/.Leeds HPC Monitor.install.AbC123"
        try FakeAppBundle.write(at: leftover + "/Leeds HPC Monitor.app", identifier: WidgetAppLauncher.appBundleIdentifier, stamp: "staged")
        try FakeAppBundle.write(at: leftover + "/previous.app", identifier: WidgetAppLauncher.appBundleIdentifier, stamp: "old")

        let result = try workspace.install(["--skip-build", "--no-open"])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("Removed the staging folder"))
        #expect(workspace.installDirectoryEntries == ["Leeds HPC Monitor.app"])
        #expect(FakeAppBundle.stamp(at: workspace.target) == "one")
        #expect(workspace.lsregisterCalls.contains("-u \(leftover)/Leeds HPC Monitor.app"))
        #expect(workspace.lsregisterCalls.contains("-u \(leftover)/previous.app"))
    }

    @Test("Without HPC_INSTALL_DIR it uses the default folder, or ~/Applications when that is not writable")
    func defaultFolder() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        let manager = FileManager.default
        let system = workspace.base + "/System"
        let writable = workspace.base + "/Writable"
        let home = workspace.base + "/home"
        for folder in [system, writable, home] {
            try manager.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: system)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: system) }
        // HOME and the default folder are always replaced, so this never
        // reaches /Applications or ~/Applications.
        func environment(default folder: String) -> [String: String?] {
            ["HPC_INSTALL_DIR": nil, "HPC_INSTALL_DEFAULT_DIR": folder, "HOME": home]
        }

        let fallback = try workspace.install(["--skip-build", "--no-open"], environment: environment(default: system))
        #expect(fallback.status == 0, "\(fallback.stderr)")
        #expect(fallback.stdout.contains("is not writable for this account"))
        let homeTarget = home + "/Applications/Leeds HPC Monitor.app"
        #expect(FakeAppBundle.stamp(at: homeTarget) == "one")
        #expect(try String(contentsOfFile: workspace.record, encoding: .utf8) == homeTarget + "\n")
        #expect(try manager.contentsOfDirectory(atPath: system).isEmpty)

        #expect(try workspace.install(["--uninstall"], environment: environment(default: system)).status == 0)
        #expect(!manager.fileExists(atPath: homeTarget))
        let direct = try workspace.install(["--skip-build", "--no-open"], environment: environment(default: writable))
        #expect(direct.status == 0, "\(direct.stderr)")
        #expect(!direct.stdout.contains("not writable"))
        #expect(FakeAppBundle.stamp(at: writable + "/Leeds HPC Monitor.app") == "one")
    }

    // MARK: Running copies, by executable

    @Test("A copy started through a link, in another letter case or by the recorded spelling is found by its executable")
    func runningCopyUnderOtherSpellings() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        #expect(try workspace.install(["--skip-build", "--no-open"]).status == 0)
        try workspace.makeSource(stamp: "two")
        let link = workspace.base + "/AppsLink"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: workspace.installDirectory)
        var spellings = [link + "/Leeds HPC Monitor.app"]
        // Another letter case names the same bundle on a case-insensitive
        // volume (the macOS default); skipped on a case-sensitive one.
        let upper = workspace.base + "/APPS/Leeds HPC Monitor.app"
        if FileManager.default.fileExists(atPath: upper) {
            spellings.append(upper)
        }

        for spelling in spellings {
            let running = try FakeRunningCopy(bundle: spelling)
            defer { running.stop() }
            let refused = try workspace.install(["--skip-build", "--no-open"])
            #expect(refused.status == WidgetAppLauncher.appStillRunningExitStatus, "\(spelling): \(refused.stderr)")
            #expect(refused.stdout.contains("(pid \(running.process.processIdentifier))"))
            #expect(FakeAppBundle.stamp(at: workspace.target) == "one")
            #expect(running.isRunning)
        }

        // The record names the install through the link (an older run):
        // the same install, and a copy started by that spelling counts.
        try Data((link + "/Leeds HPC Monitor.app\n").utf8).write(to: URL(fileURLWithPath: workspace.record))
        let running = try FakeRunningCopy(bundle: link + "/Leeds HPC Monitor.app")
        defer { running.stop() }
        let refused = try workspace.install(["--skip-build", "--no-open"])
        #expect(refused.status == WidgetAppLauncher.appStillRunningExitStatus, "\(refused.stderr)")
        #expect(!refused.stdout.contains("Moving the install"))
        let forced = try workspace.install(["--skip-build", "--no-open", "--force"])
        #expect(forced.status == 0, "\(forced.stderr)")
        #expect(FakeAppBundle.stamp(at: workspace.target) == "two")
        running.process.waitUntilExit()
        #expect(running.process.terminationReason == .uncaughtSignal)
        #expect(running.process.terminationStatus == SIGTERM)
    }

    @Test("A copy is found by the executable it runs, whatever its command line says")
    func runningCopyByExecutable() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        #expect(try workspace.install(["--skip-build", "--no-open"]).status == 0)
        try workspace.makeSource(stamp: "two")

        // Started from its own folder under a bare name: only the file the
        // kernel runs points at the install.
        let running = try FakeRunningCopy(
            script: "cd \"${0%/*}\" && exec -a AIREMonitorApp ./AIREMonitorApp 60",
            argument: workspace.target + "/Contents/MacOS/AIREMonitorApp"
        )
        defer { running.stop() }
        // macOS may deny a process without the App Management permission
        // (as this test runner) write access to the bundle of a running app;
        // such a refusal is let through while the copy runs, so it is asked
        // to quit, not refused as an install made with sudo.
        let refused = try workspace.install(["--skip-build", "--no-open"])
        #expect(refused.status == WidgetAppLauncher.appStillRunningExitStatus, "\(refused.stderr)")
        #expect(refused.stdout.contains("(pid \(running.process.processIdentifier))"))
        #expect(FakeAppBundle.stamp(at: workspace.target) == "one")
        #expect(running.isRunning)

        let forced = try workspace.install(["--skip-build", "--no-open", "--force"])
        #expect(forced.status == 0, "\(forced.stderr)")
        #expect(FakeAppBundle.stamp(at: workspace.target) == "two")
        running.process.waitUntilExit()
        #expect(running.process.terminationReason == .uncaughtSignal)
        #expect(running.process.terminationStatus == SIGTERM)
    }

    @Test("A process that only mentions the app's path (tail -f) is not a running copy")
    func mentionIsNotACopy() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        #expect(try workspace.install(["--skip-build", "--no-open"]).status == 0)
        try workspace.makeSource(stamp: "two")

        let tail = try FakeRunningCopy(script: "exec /usr/bin/tail -f \"$0\"", argument: workspace.target + "/Contents/MacOS/AIREMonitorApp")
        defer { tail.stop() }
        let result = try workspace.install(["--skip-build", "--no-open"])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(!result.stdout.contains("Asking"))
        #expect(FakeAppBundle.stamp(at: workspace.target) == "two")
        #expect(tail.isRunning)
    }

    @Test("A copy started through a symbolic link to the executable itself is found")
    func runningCopyThroughExecutableLink() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        #expect(try workspace.install(["--skip-build", "--no-open"]).status == 0)
        try workspace.makeSource(stamp: "two")

        // Neither its command line nor its process name mentions the app.
        let link = workspace.base + "/hpcmon"
        try FileManager.default.createSymbolicLink(
            atPath: link,
            withDestinationPath: workspace.target + "/Contents/MacOS/AIREMonitorApp"
        )
        let running = try FakeRunningCopy(script: "exec \"$0\" 60", argument: link)
        defer { running.stop() }
        let refused = try workspace.install(["--skip-build", "--no-open"])
        #expect(refused.status == WidgetAppLauncher.appStillRunningExitStatus, "\(refused.stderr)")
        #expect(refused.stdout.contains("(pid \(running.process.processIdentifier))"))
        #expect(FakeAppBundle.stamp(at: workspace.target) == "one")
        #expect(running.isRunning)

        let forced = try workspace.install(["--skip-build", "--no-open", "--force"])
        #expect(forced.status == 0, "\(forced.stderr)")
        #expect(FakeAppBundle.stamp(at: workspace.target) == "two")
        running.process.waitUntilExit()
        #expect(running.process.terminationReason == .uncaughtSignal)
        #expect(running.process.terminationStatus == SIGTERM)
    }

    @Test("A copy in a folder with a non-ASCII name is found without a UTF-8 locale")
    func runningCopyInNonASCIIFolder() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let folder = workspace.base + "/Apps ø 应用"
        let target = folder + "/Leeds HPC Monitor.app"
        // The C locale, in which ps and lsof print such bytes escaped.
        let locale: [String: String?] = ["LC_ALL": "C", "LC_CTYPE": nil, "LANG": nil]
        try workspace.makeSource(stamp: "one")
        let first = try workspace.install(["--skip-build", "--no-open"], into: folder, environment: locale)
        #expect(first.status == 0, "\(first.stderr)")
        try workspace.makeSource(stamp: "two")

        let running = try FakeRunningCopy(bundle: target)
        defer { running.stop() }
        let refused = try workspace.install(["--skip-build", "--no-open"], into: folder, environment: locale)
        #expect(refused.status == WidgetAppLauncher.appStillRunningExitStatus, "\(refused.stderr)")
        #expect(refused.stdout.contains("(pid \(running.process.processIdentifier))"))
        #expect(FakeAppBundle.stamp(at: target) == "one")
        #expect(running.isRunning)
    }

    @Test("A process that only maps the app's executable (a viewer, an indexer) is not a running copy")
    func mappedExecutableIsNotACopy() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        #expect(try workspace.install(["--skip-build", "--no-open"]).status == 0)
        try workspace.makeSource(stamp: "two")

        // lsof lists a mapped file as "txt", as it lists an executable.
        let mapped = workspace.base + "/mapped"
        let viewer = try FakeRunningCopy(
            script: """
            exec /usr/bin/python3 -I -c 'import mmap, sys, time
            f = open(sys.argv[1], "rb")
            m = mmap.mmap(f.fileno(), 0, prot=mmap.PROT_READ)
            open(sys.argv[2], "w").close()
            time.sleep(60)' "$0" '\(mapped)'
            """,
            argument: workspace.target + "/Contents/MacOS/AIREMonitorApp"
        )
        defer { viewer.stop() }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: mapped) {
                break
            }
            usleep(50_000)
        }
        try #require(FileManager.default.fileExists(atPath: mapped))

        let result = try workspace.install(["--skip-build", "--no-open"])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(!result.stdout.contains("Asking"))
        #expect(FakeAppBundle.stamp(at: workspace.target) == "two")
        #expect(viewer.isRunning)
    }

    // MARK: Removing

    @Test("--uninstall of a bundle this account cannot delete (locked, an ACL, a read-only folder inside) changes nothing")
    func uninstallLeavesUndeletableBundleWhole() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        #expect(try workspace.install(["--skip-build", "--no-open"]).status == 0)
        let contents = workspace.target + "/Contents"
        let cases: [(name: String, lock: [String], unlock: [String])] = [
            ("locked", ["/usr/bin/chflags", "uchg", workspace.target], ["/usr/bin/chflags", "nouchg", workspace.target]),
            ("ACL", ["/bin/chmod", "+a", "everyone deny delete", workspace.target], ["/bin/chmod", "-N", workspace.target]),
            ("read-only folder", ["/bin/chmod", "555", contents], ["/bin/chmod", "755", contents]),
        ]

        func expectUnchanged(_ result: ProcessResult, _ name: String, calls: [String], sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(result.status == 1, "\(name): \(result.stderr)", sourceLocation: sourceLocation)
            #expect(result.stderr.contains("nothing was changed"), "\(name): \(result.stderr)", sourceLocation: sourceLocation)
            #expect(!result.stdout.contains("Asking"), "\(name)", sourceLocation: sourceLocation)
            // Whole: still the signed bundle it was, recorded and registered.
            #expect(FakeAppBundle.stamp(at: workspace.target) == "one", "\(name)", sourceLocation: sourceLocation)
            #expect(
                FileManager.default.isExecutableFile(atPath: workspace.target + "/Contents/MacOS/AIREMonitorApp"),
                "\(name)",
                sourceLocation: sourceLocation
            )
            let verify = try? runCommand("/usr/bin/codesign", ["--verify", "--strict", workspace.target])
            #expect(verify?.status == 0, "\(name): \(verify?.stderr ?? "")", sourceLocation: sourceLocation)
            #expect(AppInstallRecord.installedAppPath(projectRoot: workspace.checkout) == workspace.target, "\(name)", sourceLocation: sourceLocation)
            #expect(workspace.lsregisterCalls == calls, "\(name)", sourceLocation: sourceLocation)
            #expect(workspace.installDirectoryEntries == ["Leeds HPC Monitor.app"], "\(name)", sourceLocation: sourceLocation)
        }

        for (name, lock, unlock) in cases {
            #expect(try runCommand(lock[0], Array(lock.dropFirst())).status == 0, "\(name)")
            defer { _ = try? runCommand(unlock[0], Array(unlock.dropFirst())) }
            let calls = workspace.lsregisterCalls
            expectUnchanged(try workspace.install(["--uninstall"]), name, calls: calls)
        }

        // Nothing running is asked to quit for it either, even with --force.
        let (_, lock, unlock) = cases[0]
        #expect(try runCommand(lock[0], Array(lock.dropFirst())).status == 0)
        defer { _ = try? runCommand(unlock[0], Array(unlock.dropFirst())) }
        let running = try FakeRunningCopy(bundle: workspace.target)
        defer { running.stop() }
        let calls = workspace.lsregisterCalls
        expectUnchanged(try workspace.install(["--uninstall", "--force"]), "locked, running", calls: calls)
        #expect(running.isRunning)
    }

    @Test("--uninstall asks a running copy to quit first; with --force it stops one that does not")
    func uninstallRunningCopy() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        #expect(try workspace.install(["--skip-build", "--no-open"]).status == 0)
        let running = try FakeRunningCopy(bundle: workspace.target)
        defer { running.stop() }
        let calls = workspace.lsregisterCalls

        let refused = try workspace.install(["--uninstall"])
        #expect(refused.status == WidgetAppLauncher.appStillRunningExitStatus, "\(refused.stderr)")
        #expect(refused.stdout.contains("(pid \(running.process.processIdentifier))"))
        #expect(FakeAppBundle.stamp(at: workspace.target) == "one")
        #expect(workspace.installDirectoryEntries == ["Leeds HPC Monitor.app"])
        #expect(AppInstallRecord.installedAppPath(projectRoot: workspace.checkout) == workspace.target)
        #expect(workspace.lsregisterCalls == calls)
        #expect(running.isRunning)

        let removed = try workspace.install(["--uninstall", "--force"])
        #expect(removed.status == 0, "\(removed.stderr)")
        #expect(removed.stdout.contains("Removed \(workspace.target)."))
        #expect(workspace.installDirectoryEntries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: workspace.record))
        running.process.waitUntilExit()
        #expect(running.process.terminationReason == .uncaughtSignal)
        #expect(running.process.terminationStatus == SIGTERM)
    }

    @Test("--uninstall puts the install back when a copy starts while it is being moved out of the way")
    func uninstallCopyStartedMeanwhile() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        #expect(try workspace.install(["--skip-build", "--no-open"]).status == 0)
        let pidFile = workspace.base + "/late.pid"
        let shim = try workspace.makeLateStartShim(pidFile: pidFile)
        defer {
            let text = (try? String(contentsOfFile: pidFile, encoding: .utf8)) ?? ""
            if let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 {
                kill(pid, SIGKILL)
            }
        }
        let calls = workspace.lsregisterCalls

        let result = try workspace.install(["--uninstall"], pathPrefix: shim)
        #expect(FileManager.default.fileExists(atPath: pidFile))
        #expect(result.status == WidgetAppLauncher.appStillRunningExitStatus, "\(result.stderr)")
        #expect(result.stderr.contains("was started again while it was being removed"))
        #expect(FakeAppBundle.stamp(at: workspace.target) == "one")
        #expect(workspace.installDirectoryEntries == ["Leeds HPC Monitor.app"])
        #expect(AppInstallRecord.installedAppPath(projectRoot: workspace.checkout) == workspace.target)
        #expect(workspace.lsregisterCalls == calls)
    }

    @Test("An update stops, with the install unchanged, when a copy starts between the quit and the swap")
    func updateCopyStartedMeanwhile() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        #expect(try workspace.install(["--skip-build", "--no-open"]).status == 0)
        try workspace.makeSource(stamp: "two")
        let pidFile = workspace.base + "/late.pid"
        let shim = try workspace.makeLateStartShim(pidFile: pidFile)
        var latePID: Int32 = 0
        defer {
            if latePID > 0 {
                kill(latePID, SIGKILL)
            }
        }

        let result = try workspace.install(["--skip-build", "--no-open"], pathPrefix: shim)
        let text = (try? String(contentsOfFile: pidFile, encoding: .utf8)) ?? ""
        latePID = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        #expect(latePID > 0, "the shim never started the late copy")
        #expect(result.status == WidgetAppLauncher.appStillRunningExitStatus, "\(result.stderr)")
        #expect(result.stderr.contains("was started again during the update"))
        // The late copy keeps running from the old install, which is back in
        // place and whole; the new build was not installed.
        #expect(latePID > 0 && kill(latePID, 0) == 0)
        #expect(FakeAppBundle.stamp(at: workspace.target) == "one")
        #expect(workspace.installDirectoryEntries == ["Leeds HPC Monitor.app"])
    }

    @Test("After a move, an old install this account cannot delete is left whole, never half deleted")
    func oldInstallLeftWhole() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        #expect(try workspace.install(["--skip-build", "--no-open"]).status == 0)
        let contents = workspace.target + "/Contents"
        #expect(try runCommand("/bin/chmod", ["555", contents]).status == 0)
        defer { _ = try? runCommand("/bin/chmod", ["755", contents]) }

        let elsewhere = workspace.base + "/Elsewhere"
        let newTarget = elsewhere + "/Leeds HPC Monitor.app"
        let moved = try workspace.install(["--skip-build", "--no-open"], into: elsewhere)
        #expect(moved.status == 0, "\(moved.stderr)")
        #expect(moved.stderr.contains("left the old install at '\(workspace.target)' alone"))
        #expect(FakeAppBundle.stamp(at: newTarget) == "one")
        #expect(FakeAppBundle.stamp(at: workspace.target) == "one")
        #expect(FileManager.default.isExecutableFile(atPath: workspace.target + "/Contents/MacOS/AIREMonitorApp"))
        #expect(workspace.installDirectoryEntries == ["Leeds HPC Monitor.app"])
        // LaunchServices is left with the new install only.
        #expect(workspace.stubs.registeredAppNodes == Set([inode(of: newTarget)].compactMap { $0 }))
    }

    // MARK: Staging folders

    @Test("--uninstall after a run killed between its two moves puts the install back from the staging folder, then removes it")
    func uninstallAfterKilledRun() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        #expect(try workspace.install(["--skip-build", "--no-open"]).status == 0)
        try workspace.makeSource(stamp: "two")
        let shim = try workspace.makeRenameShim(mode: "kill")
        let killed = try workspace.install(["--skip-build", "--no-open"], pathPrefix: shim)
        #expect(killed.status != 0)
        #expect(!FileManager.default.fileExists(atPath: workspace.target))
        #expect(workspace.stagingFolders.count == 1)
        #expect(try workspace.install(["--installed-path"]).status == 1)

        let result = try workspace.install(["--uninstall"])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("Put back the install"))
        #expect(result.stdout.contains("Removed \(workspace.target)."))
        #expect(!result.stdout.contains("is not installed"))
        #expect(workspace.installDirectoryEntries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: workspace.record))
        // LaunchServices is left with the checkout's own bundle only.
        #expect(workspace.stubs.registeredAppNodes == Set([inode(of: workspace.source)].compactMap { $0 }))
    }

    @Test("--uninstall with nothing installed still removes a staging folder a killed run left")
    func uninstallCleansStagingWhenNotInstalled() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let leftover = workspace.installDirectory + "/.Leeds HPC Monitor.install.AbC123"
        try FakeAppBundle.write(at: leftover + "/Leeds HPC Monitor.app", identifier: WidgetAppLauncher.appBundleIdentifier, stamp: "staged")

        let result = try workspace.install(["--uninstall"])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("Removed the staging folder"))
        #expect(result.stdout.contains("is not installed"))
        #expect(workspace.installDirectoryEntries.isEmpty)
        #expect(workspace.lsregisterCalls == ["-u \(leftover)/Leeds HPC Monitor.app"])
    }

    @Test("A staging folder whose install is still running, from another checkout, is left alone")
    func liveStagingLeftAlone() throws {
        let first = try Workspace()
        defer { first.remove() }
        let second = try Workspace()
        defer { second.remove() }
        try first.makeSource(stamp: "first-one")
        #expect(try first.install(["--skip-build", "--no-open"]).status == 0)
        try first.makeSource(stamp: "first-two")

        // The first checkout's update waits in the middle of staging.
        let gate = first.base + "/gate"
        let shim = try first.makeGatedDittoShim(gate: gate)
        let update = try first.startInstall(["--skip-build", "--no-open"], pathPrefix: shim)
        var finished = false
        defer {
            if !finished {
                FileManager.default.createFile(atPath: gate, contents: nil)
                _ = try? update.wait()
            }
        }
        var folders: [String] = []
        for _ in 0..<200 {
            folders = first.stagingFolders.filter { FileManager.default.fileExists(atPath: $0 + "/owner") }
            if !folders.isEmpty {
                break
            }
            usleep(50_000)
        }
        try #require(folders.count == 1)

        // Meanwhile the second checkout installs into the same folder.
        try second.makeSource(stamp: "second")
        let other = try second.install(["--skip-build", "--no-open"], into: first.installDirectory)
        #expect(other.status == 0, "\(other.stderr)")
        #expect(other.stdout.contains("Left the staging folder '\(folders[0])' alone"))
        #expect(FileManager.default.fileExists(atPath: folders[0] + "/owner"))
        #expect(!second.lsregisterCalls.contains { $0.hasPrefix("-u \(folders[0])") })

        FileManager.default.createFile(atPath: gate, contents: nil)
        let result = try update.wait()
        finished = true
        #expect(result.status == 0, "\(result.stderr)")
        #expect(FakeAppBundle.stamp(at: first.target) == "first-two")
        #expect(first.stagingFolders.isEmpty)
    }

    @Test("A staging folder is in use only while the process its owner file names runs, since the time it gives")
    func stagingOwners() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        #expect(try workspace.install(["--skip-build", "--no-open"]).status == 0)
        let prefix = workspace.installDirectory + "/.Leeds HPC Monitor.install."
        let identifier = WidgetAppLauncher.appBundleIdentifier
        let me = ProcessInfo.processInfo.processIdentifier

        // Its run has ended: nothing runs under that process id now.
        let ended = Process()
        ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try ended.run()
        ended.waitUntilExit()
        let dead = prefix + "\(ended.processIdentifier).AbCdEf"
        try FakeAppBundle.write(at: dead + "/Leeds HPC Monitor.app", identifier: identifier, stamp: "staged")
        try Data("\(ended.processIdentifier)\nThu Jan  1 00:00:00 1970\n".utf8).write(to: URL(fileURLWithPath: dead + "/owner"))
        // The id runs (this test) but started later than the owner file
        // says: it was reused.
        let reused = prefix + "\(me).GhIjKl"
        try FakeAppBundle.write(at: reused + "/Leeds HPC Monitor.app", identifier: identifier, stamp: "staged")
        try Data("\(me)\nThu Jan  1 00:00:00 1970\n".utf8).write(to: URL(fileURLWithPath: reused + "/owner"))
        // No owner file yet, and the id in the name runs: that run is just
        // starting.
        let starting = prefix + "\(me).MnOpQr"
        try FileManager.default.createDirectory(atPath: starting, withIntermediateDirectories: true)

        let result = try workspace.install(["--skip-build", "--no-open"])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(!FileManager.default.fileExists(atPath: dead))
        #expect(!FileManager.default.fileExists(atPath: reused))
        #expect(workspace.lsregisterCalls.contains("-u \(dead)/Leeds HPC Monitor.app"))
        #expect(workspace.lsregisterCalls.contains("-u \(reused)/Leeds HPC Monitor.app"))
        #expect(FileManager.default.fileExists(atPath: starting))
        #expect(result.stdout.contains("Left the staging folder '\(starting)' alone"))
    }

    @Test("A folder that appears at the install during the swap is never filled (rename(2), not mv)")
    func swapNeverMovesIntoAFolder() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        #expect(try workspace.install(["--skip-build", "--no-open"]).status == 0)
        try workspace.makeSource(stamp: "two")

        let shim = try workspace.makeRenameShim(mode: "occupy")
        let failed = try workspace.install(["--skip-build", "--no-open"], pathPrefix: shim)
        #expect(failed.status == 1)
        #expect(failed.stderr.contains("could not put the previous install back"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.target) == ["Contents"])
        let kept = try #require(workspace.stagingFolders.first)
        #expect(FakeAppBundle.stamp(at: kept + "/previous.app") == "one")
        #expect(FakeAppBundle.stamp(at: kept + "/Leeds HPC Monitor.app") == "two")
    }

    // MARK: Locks

    @Test("Exit 75 from the build's own lock is not reported as another install")
    func buildLockTimeout() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.useFailingBuildStub(status: 75)

        let result = try workspace.install(["--no-open"])
        #expect(result.status == WidgetAppLauncher.buildBusyExitStatus)
        #expect(FileManager.default.fileExists(atPath: workspace.buildMarker))
        #expect(!result.stderr.contains("another install of this checkout"))
        let runtime = try FileManager.default.contentsOfDirectory(atPath: workspace.checkout + "/.runtime")
        #expect(!runtime.contains { $0.hasPrefix(".install_app.waiting.") })
    }

    @Test("An install that cannot get the checkout's lock says so and exits 75")
    func installLockTimeout() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        let lock = workspace.checkout + "/.runtime/.install_app.lock"
        let holder = try BackgroundCommand("/usr/bin/lockf", ["-k", "-s", lock, "/bin/sleep", "3"])
        defer { _ = try? holder.wait() }
        var held = false
        for _ in 0..<40 {
            held = try runCommand("/usr/bin/lockf", ["-k", "-s", "-t", "0", lock, "/usr/bin/true"]).status == 75
            if held {
                break
            }
            usleep(50_000)
        }
        try #require(held)

        let result = try workspace.install(["--skip-build", "--no-open"], environment: ["HPC_INSTALL_LOCK_TIMEOUT": "0"])
        #expect(result.status == WidgetAppLauncher.buildBusyExitStatus)
        #expect(result.stderr.contains("another install of this checkout has been running"))
        #expect(!FileManager.default.fileExists(atPath: workspace.target))
        let runtime = try FileManager.default.contentsOfDirectory(atPath: workspace.checkout + "/.runtime")
        #expect(!runtime.contains { $0.hasPrefix(".install_app.waiting.") })
        let bad = try workspace.install(["--skip-build", "--no-open"], environment: ["HPC_INSTALL_LOCK_TIMEOUT": "soon"])
        #expect(bad.status == 2)
        #expect(bad.stderr.contains("HPC_INSTALL_LOCK_TIMEOUT"))
    }

    // MARK: LaunchServices

    @Test("Only the installed copy stays registered: every bundle is unregistered before it is deleted")
    func onlyInstalledCopyStaysRegistered() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        func registered(_ path: String) -> Set<String> {
            Set([inode(of: path)].compactMap { $0 })
        }

        // As the build would have left it: the .runtime bundle registered.
        try workspace.makeSource(stamp: "one")
        try workspace.stubs.register(workspace.source)
        #expect(try workspace.install(["--skip-build", "--no-open"]).status == 0)
        #expect(workspace.stubs.registeredAppNodes == registered(workspace.target))

        // An update: the install it replaces goes too.
        try workspace.makeSource(stamp: "two")
        try workspace.stubs.register(workspace.source)
        let update = try workspace.install(["--skip-build", "--no-open"])
        #expect(update.status == 0, "\(update.stderr)")
        #expect(workspace.stubs.registeredAppNodes == registered(workspace.target))

        // A move: so does the old install.
        let elsewhere = workspace.base + "/Elsewhere"
        let moved = try workspace.install(["--skip-build", "--no-open"], into: elsewhere)
        #expect(moved.status == 0, "\(moved.stderr)")
        let newTarget = elsewhere + "/Leeds HPC Monitor.app"
        #expect(workspace.stubs.registeredAppNodes == registered(newTarget))

        // Uninstalling hands the app back to the checkout's own bundle.
        let removed = try workspace.install(["--uninstall"], into: elsewhere)
        #expect(removed.status == 0, "\(removed.stderr)")
        #expect(workspace.stubs.registeredAppNodes == registered(workspace.source))
    }

    @Test("The .runtime copy is unregistered last, after the app is opened, once the copy that ran from it is gone")
    func buildOutputUnregisteredLast() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeSource(stamp: "one")
        try workspace.stubs.register(workspace.source)
        // Exits by itself within the quit timeout, as a copy that quits when
        // asked does.
        let running = try FakeRunningCopy(bundle: workspace.source, seconds: 1)
        defer { running.stop() }

        let result = try workspace.install(["--skip-build"], quitTimeout: 10)
        #expect(result.status == 0, "\(result.stderr)")
        #expect(workspace.stubs.events.suffix(3) == [
            "lsregister -f \(workspace.target)",
            "open \(workspace.target)",
            "lsregister -u \(workspace.source)",
        ])
        let last = workspace.stubs.records.last
        #expect(last?.path == workspace.source)
        #expect(last?.running == false)
        #expect(workspace.stubs.registeredAppNodes == Set([inode(of: workspace.target)].compactMap { $0 }))
    }
}

// MARK: - scripts/build_bundle.sh as the install source

@Suite("Bundle builder as the install source", .serialized, .timeLimit(.minutes(2)))
struct BuildBundleInstallSourceTests {
    /// A checkout with the real build_bundle.sh and install_app.sh, a fake
    /// `swift` whose "build" is a copy of the sleeper (the app) and of
    /// /usr/bin/true (the widget), ad-hoc signing, and stubs for lsregister
    /// and `open`.
    private struct Workspace {
        let base: String
        let stubs: LaunchServicesStubs
        var checkout: String { base + "/checkout" }
        var source: String { checkout + "/.runtime/AIREMonitorApp.app" }
        var installDirectory: String { base + "/Apps" }
        var installed: String { installDirectory + "/Leeds HPC Monitor.app" }

        init() throws {
            base = try makeResolvedTemporaryDirectory("hpc-build-bundle")
            stubs = try LaunchServicesStubs(base: base)
            let manager = FileManager.default
            try makeCheckout(at: checkout)
            for name in ["build_bundle.sh", "install_app.sh"] {
                try manager.copyItem(
                    atPath: repositoryRoot.appendingPathComponent("scripts/\(name)").path,
                    toPath: checkout + "/scripts/\(name)"
                )
            }
            try manager.createDirectory(atPath: checkout + "/.runtime", withIntermediateDirectories: true)
            try manager.createDirectory(atPath: checkout + "/assets", withIntermediateDirectories: true)
            for name in ["LeedsHPCMark.png", "LeedsHPCMonitor.icns"] {
                try Data("artwork".utf8).write(to: URL(fileURLWithPath: checkout + "/assets/" + name))
            }
            try manager.createDirectory(atPath: base + "/build/release", withIntermediateDirectories: true)
            // The app's executable really runs from the bundle (see
            // FakeRunningCopy); the widget's is never started.
            try manager.copyItem(atPath: try sleeperExecutable(), toPath: base + "/build/release/AIREMonitorApp")
            try manager.copyItem(atPath: "/usr/bin/true", toPath: base + "/build/release/AIREDesktopWidget")
            try writeExecutable(stubs.folder + "/swift", """
            #!/bin/sh
            echo "Build complete!"
            """)
        }

        /// An older .runtime bundle, so the build replaces it.
        func makeOldSource() throws {
            try FakeAppBundle.write(at: source, identifier: WidgetAppLauncher.appBundleIdentifier, stamp: "old", sign: true)
        }

        func markInstalled() throws {
            try FakeAppBundle.write(at: installed, identifier: WidgetAppLauncher.appBundleIdentifier, stamp: "installed")
            try Data((installed + "\n").utf8).write(to: URL(fileURLWithPath: checkout + "/.runtime/installed_app_path"))
        }

        private var environment: [String: String] {
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = stubs.folder + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
            environment["HPC_LSREGISTER"] = stubs.lsregister
            environment["HPC_SWIFTPM_BUILD_DIR"] = base + "/build"
            environment["HPC_CODESIGN_IDENTITY"] = "-"
            // Only written to the build log; saves an xcrun call.
            environment["SDKROOT"] = base + "/sdk"
            environment["HPC_INSTALL_DIR"] = installDirectory
            for key in [
                "HPC_BUILD_LOG", "HPC_BUILD_JOBS", "HPC_BUILD_BUNDLE_LOCKED", "HPC_INSTALL_NO_OPEN",
                "HPC_INSTALL_DEFAULT_DIR", "HPC_INSTALL_LOCK_TIMEOUT", "HPC_INSTALL_APP_LOCKED",
            ] {
                environment.removeValue(forKey: key)
            }
            return environment
        }

        func build(_ arguments: [String]) throws -> ProcessResult {
            try runCommand(
                "/bin/bash",
                [checkout + "/scripts/build_bundle.sh"] + arguments,
                environment: environment,
                currentDirectory: base
            )
        }

        /// install_app.sh, building through the real build_bundle.sh.
        func install(_ arguments: [String], quitTimeout: Int) throws -> ProcessResult {
            var environment = environment
            environment["HPC_INSTALL_QUIT_TIMEOUT"] = String(quitTimeout)
            return try runCommand(
                "/bin/bash",
                [checkout + "/scripts/install_app.sh"] + arguments,
                environment: environment,
                currentDirectory: base
            )
        }

        var lsregisterCalls: [String] { stubs.calls }
        var openCalls: [String] { stubs.openCalls }

        func remove() {
            try? FileManager.default.removeItem(atPath: base)
        }
    }

    @Test("--for-install before the first install: a running copy is not stopped, nothing is opened, the bundle stays registered")
    func firstInstallSource() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeOldSource()
        let running = try FakeRunningCopy(bundle: workspace.source)
        defer { running.stop() }

        let result = try workspace.build(["--for-install", "--open", "AIREMonitorApp"])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("Built AIREMonitorApp.app"))
        #expect(FakeAppBundle.stamp(at: workspace.source) != "old")
        #expect(running.isRunning)
        // The old bundle is unregistered before it is deleted; install_app.sh
        // unregisters the new one once the installed copy is in place.
        #expect(workspace.lsregisterCalls == ["-u \(workspace.source)", "-f \(workspace.source)"])
        #expect(workspace.stubs.records.first?.identifier == WidgetAppLauncher.appBundleIdentifier)
        #expect(workspace.openCalls.isEmpty)
        #expect(result.stderr.contains("not opening .runtime/AIREMonitorApp.app"))
    }

    @Test("Once installed: replaced under a running copy without stopping it, unregistered, never opened")
    func installedSource() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try workspace.makeOldSource()
        try workspace.markInstalled()
        let running = try FakeRunningCopy(bundle: workspace.source)
        defer { running.stop() }

        let result = try workspace.build(["--open", "AIREMonitorApp"])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(FakeAppBundle.stamp(at: workspace.source) != "old")
        #expect(running.isRunning)
        // The old bundle (before it is deleted), then the new one.
        #expect(workspace.lsregisterCalls == ["-u \(workspace.source)", "-u \(workspace.source)"])
        #expect(Set(workspace.stubs.records.map(\.node)).count == 2)
        #expect(workspace.openCalls.isEmpty)
        #expect(result.stderr.contains("the app is installed at \(workspace.installed)"))
    }

    @Test("Without an install or --for-install the bundle is registered and opened as before")
    func notInstalled() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let result = try workspace.build(["--open", "AIREMonitorApp"])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(workspace.lsregisterCalls == ["-f \(workspace.source)"])
        #expect(workspace.openCalls == [workspace.source])
    }

    @Test("A first install through the real build leaves LaunchServices with the installed copy only")
    func firstInstallLeavesOnlyInstalledCopyRegistered() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        // What the real install met: the app running from a .runtime bundle
        // that LaunchServices knows, and that the build replaces once the
        // app has quit (this copy exits within the quit timeout by itself).
        try workspace.makeOldSource()
        try workspace.stubs.register(workspace.source)
        let oldSourceNode = try #require(inode(of: workspace.source))
        let running = try FakeRunningCopy(bundle: workspace.source, seconds: 1)
        defer { running.stop() }

        let result = try workspace.install(["--no-open"], quitTimeout: 10)
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("Built AIREMonitorApp.app"))
        #expect(FakeAppBundle.stamp(at: workspace.installed) == FakeAppBundle.stamp(at: workspace.source))
        // The bundle the app ran from was unregistered before the build
        // deleted it; neither it nor the new .runtime bundle stays listed.
        let installedNode = try #require(inode(of: workspace.installed))
        #expect(workspace.stubs.registeredAppNodes == [installedNode])
        #expect(workspace.stubs.records.contains { $0.flag == "-u" && $0.node == oldSourceNode })
        let sourceRecords = workspace.stubs.records.filter { $0.path == workspace.source }
        #expect(sourceRecords.last?.flag == "-u")
        #expect(!sourceRecords.contains { $0.flag == "-u" && $0.running })
    }
}

// MARK: - scripts/run_macos_app.sh

@Suite("Development launcher", .timeLimit(.minutes(1)))
struct RunMacOSAppScriptTests {
    /// A checkout whose install_app.sh and build_bundle.sh only record how
    /// they were called.
    private struct Workspace {
        let base: String
        var checkout: String { base + "/checkout" }
        var installed: String { base + "/installed" }

        init() throws {
            base = try makeResolvedTemporaryDirectory("hpc-run-app-script")
            try makeCheckout(at: checkout)
            try FileManager.default.copyItem(
                atPath: repositoryRoot.appendingPathComponent("scripts/run_macos_app.sh").path,
                toPath: checkout + "/scripts/run_macos_app.sh"
            )
            try Data("""
            #!/usr/bin/env bash
            if [[ "${1:-}" == --installed-path ]]; then
                [[ -f '\(installed)' ]] || exit 1
                echo '/Apps/Leeds HPC Monitor.app'
                exit 0
            fi
            printf '%s\\n' "$*" > '\(base)/install.args'
            """.utf8).write(to: URL(fileURLWithPath: checkout + "/scripts/install_app.sh"))
            try Data("""
            #!/usr/bin/env bash
            printf '%s\\n' "$*" > '\(base)/build.args'
            """.utf8).write(to: URL(fileURLWithPath: checkout + "/scripts/build_bundle.sh"))
        }

        func run(_ arguments: [String]) throws -> ProcessResult {
            try runCommand("/bin/bash", [checkout + "/scripts/run_macos_app.sh"] + arguments)
        }

        func recorded(_ name: String) -> String? {
            try? String(contentsOfFile: base + "/" + name, encoding: .utf8)
        }

        func remove() {
            try? FileManager.default.removeItem(atPath: base)
        }
    }

    @Test("Without an install it builds into .runtime and opens that bundle, as before")
    func notInstalled() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        #expect(try workspace.run(["--debug"]).status == 0)
        #expect(workspace.recorded("build.args") == "--open --debug AIREMonitorApp AIREDesktopWidget\n")
        #expect(workspace.recorded("install.args") == nil)
    }

    @Test("Once installed it updates and opens the installed copy instead")
    func installed() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        FileManager.default.createFile(atPath: workspace.installed, contents: Data())
        #expect(try workspace.run(["--debug"]).status == 0)
        #expect(workspace.recorded("install.args") == "--debug\n")
        #expect(workspace.recorded("build.args") == nil)
    }
}

// MARK: - Syntax

@Suite("Shell script syntax")
struct ShellSyntaxTests {
    @Test("Every bash and zsh script parses")
    func scriptsParse() throws {
        let scripts = repositoryRoot.appendingPathComponent("scripts")
        let names = try FileManager.default.contentsOfDirectory(atPath: scripts.path).sorted()
        #expect(names.contains("install_app.sh"))
        for name in names {
            let path = scripts.appendingPathComponent(name).path
            let shell: String
            if name.hasSuffix(".sh") {
                shell = "/bin/bash"
            } else if name.hasSuffix(".zsh") {
                shell = "/bin/zsh"
            } else {
                continue
            }
            let result = try runCommand(shell, ["-n", path])
            #expect(result.status == 0, "\(name): \(result.stderr)")
        }
    }
}
