import Foundation
import Testing
@testable import AIREMonitorApp

/// Control-socket naming is a compatibility contract, not an implementation
/// detail: the login scripts, the collector, the terminal and the file
/// browser all find a cluster's ControlMaster by this path, and a master
/// started by the previous single-cluster release must still be found after
/// the upgrade (otherwise every user is forced through Duo again).
@Suite("ConnectionSettings")
struct ConnectionSettingsTests {
    @Test("AIRE direct socket keeps the pre-multi-cluster name")
    func aireDirectControlPathIsBackwardCompatible() {
        let settings = makeSettings(.aire, route: .directVPN)

        // sha256("abcd1234@aire.leeds.ac.uk:direct")[:12] == ad0d6854d832 —
        // the socket a live master from the previous release is listening on.
        #expect(settings.controlPath.hasSuffix("/.ssh/ctl/aire-ad0d6854d832.sock"))
        #expect(settings.controlPath.hasPrefix(NSHomeDirectory()))
        #expect(settings.controlDirectory == (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/ctl"))
    }

    @Test("Calder direct socket is namespaced by cluster id")
    func calderDirectControlPath() {
        let settings = makeSettings(.calder, route: .directVPN)

        // sha256("abcd1234@calder.leeds.ac.uk:direct")[:12]
        #expect(settings.controlPath.hasSuffix("/.ssh/ctl/calder-8f5b62dbf96a.sock"))
    }

    @Test("Direct route has no jump socket")
    func directRouteHasNoJumpControlPath() {
        for profile in ClusterCatalog.all {
            let settings = makeSettings(profile, route: .directVPN)
            #expect(settings.useJumpHost == false)
            #expect(settings.jumpControlPath.isEmpty, "\(profile.displayName) direct route must not name a jump socket")
        }
    }

    @Test("rash jump socket is shared by every cluster")
    func rashJumpControlPathIsSharedAcrossClusters() {
        let aire = makeSettings(.aire, route: .rashJump)
        let calder = makeSettings(.calder, route: .rashJump)

        #expect(aire.useJumpHost)
        #expect(calder.useJumpHost)
        // sha256("abcd1234@rash.leeds.ac.uk")[:12]. One jump master serves
        // both clusters, so rash costs one Duo approval in total.
        #expect(aire.jumpControlPath.hasSuffix("/.ssh/ctl/jump-20506f6fe2c6.sock"))
        #expect(aire.jumpControlPath == calder.jumpControlPath)
    }

    @Test("Target sockets differ per route and per cluster")
    func targetControlPathsAreDistinct() {
        let aireDirect = makeSettings(.aire, route: .directVPN).controlPath
        let aireJump = makeSettings(.aire, route: .rashJump).controlPath
        let calderDirect = makeSettings(.calder, route: .directVPN).controlPath
        let calderJump = makeSettings(.calder, route: .rashJump).controlPath

        // A master opened over one route must never be mistaken for the
        // other route's (the via-rash master dies with the jump session).
        #expect(aireDirect != aireJump)
        #expect(calderDirect != calderJump)
        // Two clusters must never share a target master.
        #expect(Set([aireDirect, aireJump, calderDirect, calderJump]).count == 4)
        // The target master is never the jump master.
        #expect(aireJump != makeSettings(.aire, route: .rashJump).jumpControlPath)

        // sha256("abcd1234@aire.leeds.ac.uk:via-rash.leeds.ac.uk")[:12]
        #expect(aireJump.hasSuffix("/.ssh/ctl/aire-134706c82ad1.sock"))
    }

    @Test("Socket path depends on user, host and jump host")
    func controlPathTracksIdentity() {
        let base = makeSettings(.calder, route: .rashJump)
        let otherUser = makeSettings(.calder, route: .rashJump, username: "wxyz9876")
        let otherHost = makeSettings(.calder, route: .rashJump, hostname: "calder-login-1.leeds.ac.uk")
        let otherJump = makeSettings(.calder, route: .rashJump, jumpHostname: "rash2.leeds.ac.uk")

        #expect(base.controlPath != otherUser.controlPath)
        #expect(base.controlPath != otherHost.controlPath)
        #expect(base.controlPath != otherJump.controlPath)
        #expect(base.jumpControlPath != otherUser.jumpControlPath)
        #expect(base.jumpControlPath != otherJump.jumpControlPath)
        // The jump master does not depend on which cluster host is behind it.
        #expect(base.jumpControlPath == otherHost.jumpControlPath)
    }

    @Test("Socket paths leave room for ssh's temporary suffix")
    func controlPathsFitInSunPath() {
        // macOS limits sun_path to 104 bytes and ssh appends a ~20-byte
        // random suffix while it binds a new master. This only holds for a
        // normal-length home directory, which is what the short hashed
        // ~/.ssh/ctl layout exists to guarantee.
        for profile in ClusterCatalog.all {
            for route in ConnectionRoute.allCases {
                let settings = makeSettings(profile, route: route)
                #expect(settings.controlPath.utf8.count + 20 < 104, "\(settings.controlPath)")
                #expect(settings.jumpControlPath.utf8.count + 20 < 104, "\(settings.jumpControlPath)")
            }
        }
    }

    @Test("Runtime directory is per cluster under .runtime/clusters")
    func runtimeDirectoryIsPerCluster() {
        let root = "/Users/someone/projects/aire_server_app"
        let aire = makeSettings(.aire, projectRoot: root)
        let calder = makeSettings(.calder, projectRoot: root)

        #expect(aire.runtimeDirectory == "\(root)/.runtime/clusters/aire")
        #expect(calder.runtimeDirectory == "\(root)/.runtime/clusters/calder")
    }
}
