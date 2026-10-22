import HPCCore
import Foundation
import Testing
@testable import AIREMonitorApp

/// `MonitorService.collectorArguments` is the Swift half of the collector
/// CLI contract (DESIGN.md "Collector contract"). The same argv is written
/// to `.runtime/clusters/<id>/collector.json` for the desktop widget, so it
/// must be complete, self-describing and password-free.
@Suite("Collector arguments")
struct CollectorArgumentsTests {
    @Test("Identity, host and socket flags are present", arguments: catalogIDs, ConnectionRoute.allCases)
    func identityFlags(id: ClusterID, route: ConnectionRoute) {
        let profile = catalogProfile(id)
        let settings = makeSettings(profile, route: route)
        let arguments = MonitorService.collectorArguments(settings: settings)

        #expect(value(after: "--cluster-id", in: arguments) == profile.id.rawValue)
        #expect(value(after: "--cluster-name", in: arguments) == profile.displayName)
        #expect(value(after: "--username", in: arguments) == testUsername)
        #expect(value(after: "--hostname", in: arguments) == profile.defaultHostname)
        #expect(value(after: "--control-path", in: arguments) == settings.controlPath)
        // The deprecated single-cluster spelling must not be emitted.
        #expect(!arguments.contains("--aire-hostname"))
        // Alias mode is gone from the app; explicit mode only.
        #expect(!arguments.contains("--host"))
    }

    @Test("Each flag appears at most once", arguments: catalogIDs, ConnectionRoute.allCases)
    func flagsAreUnique(id: ClusterID, route: ConnectionRoute) {
        let arguments = MonitorService.collectorArguments(settings: makeSettings(catalogProfile(id), route: route))
        let flags = arguments.filter { $0.hasPrefix("--") }
        #expect(flags.count == Set(flags).count, "duplicate flag in \(flags)")
    }

    @Test("--storage-spec is JSON that decodes back to the profile's volumes", arguments: catalogIDs)
    func storageSpecRoundTrips(id: ClusterID) throws {
        let profile = catalogProfile(id)
        let arguments = MonitorService.collectorArguments(settings: makeSettings(profile))
        let json = try #require(value(after: "--storage-spec", in: arguments))

        let decoded = try decode([StorageVolumeSpec].self, from: json)
        #expect(decoded == profile.storage)
        // `$USER`/`$HOME` are expanded on the login node, never locally: the
        // tokens must reach the collector verbatim.
        #expect(json.contains("$USER"))
        #expect(json.contains("$HOME"))
        #expect(!json.contains(NSHomeDirectory()))
    }

    @Test("Calder storage spec carries its Lustre scratch and optional flash")
    func calderStorageSpecContents() throws {
        let arguments = MonitorService.collectorArguments(settings: makeSettings(.calder))
        let json = try #require(value(after: "--storage-spec", in: arguments))
        let volumes = try decode([StorageVolumeSpec].self, from: json)

        let scratch = try #require(volumes.first { $0.label == "Scratch" })
        #expect(scratch.quota == .lustre)
        #expect(scratch.paths.first == "/scratch-calder/users/$USER")
        #expect(scratch.optional == false)

        let flash = try #require(volumes.first { $0.label == "Flash" })
        #expect(flash.quota == .lustre)
        #expect(flash.optional)

        // The shared /users home is reported through NFS quota.
        let home = try #require(volumes.first { $0.label == "Home" })
        #expect(home.quota == .nfs)
        #expect(home.paths == ["$HOME"])
    }

    @Test("Direct route: --no-jump-host and no jump socket", arguments: catalogIDs)
    func directRouteFlags(id: ClusterID) {
        let arguments = MonitorService.collectorArguments(settings: makeSettings(catalogProfile(id), route: .directVPN))

        #expect(arguments.contains("--no-jump-host"))
        #expect(!arguments.contains("--use-jump-host"))
        #expect(!arguments.contains("--jump-control-path"))
    }

    @Test("rash route: --use-jump-host and the shared jump socket", arguments: catalogIDs)
    func rashRouteFlags(id: ClusterID) {
        let settings = makeSettings(catalogProfile(id), route: .rashJump)
        let arguments = MonitorService.collectorArguments(settings: settings)

        #expect(arguments.contains("--use-jump-host"))
        #expect(!arguments.contains("--no-jump-host"))
        #expect(value(after: "--jump-hostname", in: arguments) == "rash.leeds.ac.uk")
        #expect(value(after: "--jump-control-path", in: arguments) == settings.jumpControlPath)
        #expect(value(after: "--jump-control-path", in: arguments)?.hasSuffix("/jump-20506f6fe2c6.sock") == true)
    }

    @Test("argv is password-free", arguments: catalogIDs, ConnectionRoute.allCases)
    func argumentsArePasswordFree(id: ClusterID, route: ConnectionRoute) {
        // collector.json is written verbatim from this list; the password
        // only ever travels on a login helper's stdin.
        let arguments = MonitorService.collectorArguments(settings: makeSettings(catalogProfile(id), route: route))
        #expect(!arguments.contains { $0.lowercased().contains("password") })
    }
}

@Suite("Collector arguments · storage")
struct CollectorStorageFlagTests {
    @Test("--skip-storage only on request, never in the widget's argv", arguments: catalogIDs, ConnectionRoute.allCases)
    func skipStorageFlag(id: ClusterID, route: ConnectionRoute) {
        let settings = makeSettings(catalogProfile(id), route: route)
        // collector.json is written from the default: the widget replays it
        // verbatim and must keep collecting storage.
        #expect(!MonitorService.collectorArguments(settings: settings).contains(MonitorService.skipStorageFlag))
        let skipping = MonitorService.collectorArguments(settings: settings, skipStorage: true)
        #expect(skipping.last == "--skip-storage")
        #expect(Array(skipping.dropLast()) == MonitorService.collectorArguments(settings: settings))
    }
}

/// Every child process gets the scrubbed environment, and the stop helper
/// gets exactly contract 2's variables.
@Suite("Helper processes")
struct HelperProcessTests {
    @Test("Child environments never carry a password variable")
    func childEnvironmentScrubsPasswords() {
        let inherited = [
            "PATH": "/usr/bin:/bin",
            "HPC_PASSWORD": "secret",
            "HPC_ASKPASS_PASSWORD": "secret",
            "AIRE_PASSWORD": "secret",
            "AIRE_ASKPASS_PASSWORD": "secret",
            "SDKROOT": "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
        ]
        let scrubbed = MonitorService.childEnvironment(from: inherited)
        #expect(scrubbed == ["PATH": "/usr/bin:/bin"])
        for name in MonitorService.passwordEnvironmentNames {
            #expect(MonitorService.childEnvironment()[name] == nil)
        }
    }

    @Test("Stop helper environment matches contract 2", arguments: ConnectionRoute.allCases)
    func stopMasterEnvironment(route: ConnectionRoute) {
        let settings = makeSettings(.calder, route: route)
        let environment = MonitorService.stopMasterEnvironment(settings: settings, stopJumpIfUnused: false)
        #expect(environment["HPC_PROJECT_ROOT"] == settings.projectRoot)
        #expect(environment["HPC_RUNTIME_DIR"] == settings.runtimeDirectory)
        #expect(environment["HPC_CONTROL_PATH"] == settings.controlPath)
        #expect(environment["HPC_HOSTNAME"] == settings.hostname)
        #expect(environment["HPC_USERNAME"] == testUsername)
        #expect(environment["HPC_TARGET_LABEL"] == "Calder")
        #expect(environment["HPC_JUMP_HOSTNAME"] == "rash.leeds.ac.uk")
        #expect(environment["HPC_STOP_JUMP_IF_UNUSED"] == "0")
        for name in MonitorService.passwordEnvironmentNames {
            #expect(environment[name] == nil)
        }
        switch route {
        case .rashJump:
            #expect(environment["HPC_USE_JUMP_HOST"] == "1")
            #expect(environment["HPC_JUMP_CONTROL_PATH"] == settings.jumpControlPath)
        case .directVPN:
            #expect(environment["HPC_USE_JUMP_HOST"] == "0")
            #expect(environment["HPC_JUMP_CONTROL_PATH"] == nil)
        }
    }

    @Test("The jump master is offered for closing only on request, and only on the rash route")
    func stopJumpIfUnused() {
        let rash = makeSettings(.aire, route: .rashJump)
        #expect(MonitorService.stopMasterEnvironment(settings: rash, stopJumpIfUnused: true)["HPC_STOP_JUMP_IF_UNUSED"] == "1")
        let direct = makeSettings(.aire, route: .directVPN)
        #expect(MonitorService.stopMasterEnvironment(settings: direct, stopJumpIfUnused: true)["HPC_STOP_JUMP_IF_UNUSED"] == "0")
    }

    @Test("Stop helper status lines are read, and a kept jump session is recognised")
    func stopReport() {
        let output = """
        some noise
        HPC-STATUS: stopped the AIRE session
        HPC-STATUS: kept the shared jump-host session (rash.leeds.ac.uk): another connection still uses it
        """
        let report = StopMasterReport(statusLines: MonitorService.statusLines(in: output))
        #expect(report.statusLines == [
            "stopped the AIRE session",
            "kept the shared jump-host session (rash.leeds.ac.uk): another connection still uses it"
        ])
        #expect(report.keptSharedJumpSession)
        #expect(!report.stoppedSharedJumpSession)
        let stopped = StopMasterReport(statusLines: ["stopped the Calder session", "stopped the shared jump-host session (rash.leeds.ac.uk)"])
        #expect(stopped.stoppedSharedJumpSession)
        #expect(!stopped.keptSharedJumpSession)
    }

    @Test("Remote commands ride the master with the shared never-prompt options")
    func remoteCommandArguments() {
        let settings = makeSettings(.aire, route: .rashJump)
        let arguments = MonitorService.remoteCommandArguments(settings: settings, command: "scancel '42'")
        #expect(Array(arguments.prefix(2)) == ["-S", settings.controlPath])
        #expect(Array(arguments.suffix(2)) == [settings.hostname, "scancel '42'"])
        for option in ["BatchMode=yes", "PasswordAuthentication=no", "KbdInteractiveAuthentication=no", "ControlMaster=no", "ConnectTimeout=5", "User=\(testUsername)"] {
            #expect(arguments.contains(option), "missing \(option)")
        }
        #expect(arguments == SSHMuxOptions.sshArguments(settings: settings) + [settings.hostname, "scancel '42'"])
    }
}
