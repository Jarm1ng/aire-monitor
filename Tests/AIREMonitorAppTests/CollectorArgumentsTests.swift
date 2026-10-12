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
