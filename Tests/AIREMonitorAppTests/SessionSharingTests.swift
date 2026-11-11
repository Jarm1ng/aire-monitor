import HPCCore
import Darwin
import Foundation
import Testing
@testable import AIREMonitorApp

/// A scratch directory with short paths (unix socket paths are capped at
/// 104 bytes) holding real listening sockets. Never ~/.ssh.
final class SocketSandbox {
    let path: String
    private var listeners: [String: Int32] = [:]

    init() throws {
        path = (NSTemporaryDirectory() as NSString).appendingPathComponent("hs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    deinit {
        for descriptor in listeners.values {
            close(descriptor)
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    func file(_ name: String) -> String {
        (path as NSString).appendingPathComponent(name)
    }

    /// A socket something listens on: a live master.
    @discardableResult
    func listen(_ name: String) throws -> String {
        let socketPath = file(name)
        try FileManager.default.createDirectory(atPath: (socketPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bound == 0)
        #expect(Darwin.listen(descriptor, 8) == 0)
        listeners[socketPath] = descriptor
        return socketPath
    }

    /// Stops listening but leaves the socket file: a master that died
    /// without cleaning up.
    func kill(_ name: String) {
        if let descriptor = listeners.removeValue(forKey: file(name)) {
            close(descriptor)
        }
    }

    /// A master that exited cleanly (OpenSSH unlinks its socket).
    func stop(_ name: String) {
        kill(name)
        unlink(file(name))
    }

    func readLink(_ name: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: file(name))
    }
}

@Suite("Session sharing")
struct SessionSharingTests {
    private func master(_ name: String, host: String, socket: String) -> SharedMaster {
        SharedMaster(name: name, displayName: name.uppercased(), hostname: host, username: "user1", socketPath: socket)
    }

    private func alias(_ name: String, host: String, controlPath: String?, user: String = "user1", port: Int = 22) -> SSHAlias {
        SSHAlias(name: name, hostname: host, user: user, port: port, controlPath: controlPath)
    }

    @Test("Host aliases come from Host lines and Includes; patterns are skipped")
    func aliasDiscovery() throws {
        let sandbox = try SocketSandbox()
        try """
        # comment
        Include extra/*.conf
        Host aire aire-rash
            HostName aire.leeds.ac.uk
        Host=calder
        Host *.leeds.ac.uk !bad -opt
        Host "quoted"
        Match host foo
        host rash
        """.write(toFile: sandbox.file("config"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: sandbox.file("extra"), withIntermediateDirectories: true)
        try "Host vortex\nHost aire\n".write(toFile: sandbox.file("extra/one.conf"), atomically: true, encoding: .utf8)

        let names = SessionSharing.hostAliases(inConfigAt: sandbox.file("config"), sshDirectory: sandbox.path)
        #expect(names == ["vortex", "aire", "aire-rash", "calder", "quoted", "rash"])
    }

    @Test("ssh -G output yields host, user, port and ControlPath (none is nil)")
    func resolvedConfig() {
        let output = """
        user user1
        hostname aire.leeds.ac.uk
        port 22
        controlpath /home/u/.ssh/control/abc.sock
        controlmaster auto
        """
        #expect(SessionSharing.parseResolvedConfig(output, alias: "aire")
            == SSHAlias(name: "aire", hostname: "aire.leeds.ac.uk", user: "user1", port: 22, controlPath: "/home/u/.ssh/control/abc.sock"))
        let none = SessionSharing.parseResolvedConfig("user u\nhostname h\nport 2222\ncontrolpath none\n", alias: "h")
        #expect(none?.controlPath == nil)
        #expect(none?.port == 2222)
        #expect(SessionSharing.parseResolvedConfig("port 22\n", alias: "x") == nil)
    }

    @Test("A live master gets a stable link and links for matching free aliases")
    func linksFreeAliases() throws {
        let sandbox = try SocketSandbox()
        let socket = try sandbox.listen("ctl/aire-abc.sock")
        let outcome = SessionSharing.reconcile(
            masters: [master("aire", host: "aire.leeds.ac.uk", socket: socket)],
            aliases: [
                alias("aire", host: "AIRE.leeds.ac.uk", controlPath: sandbox.file("control/a.sock")),
                alias("other-user", host: "aire.leeds.ac.uk", controlPath: sandbox.file("control/b.sock"), user: "someone"),
                alias("calder", host: "calder.leeds.ac.uk", controlPath: sandbox.file("control/c.sock")),
                alias("no-cp", host: "aire.leeds.ac.uk", controlPath: nil)
            ],
            linkDirectory: sandbox.file("ctl"),
            owned: [:],
            share: true
        )
        #expect(sandbox.readLink("ctl/aire.sock") == socket)
        #expect(sandbox.readLink("control/a.sock") == socket)
        #expect(SessionSharing.pathKind(sandbox.file("control/b.sock")) == .missing)
        #expect(SessionSharing.pathKind(sandbox.file("control/c.sock")) == .missing)
        #expect(outcome.aliases.map(\.alias) == ["aire", "no-cp"])
        #expect(outcome.aliases.first?.state == .linked)
        #expect(outcome.aliases.last?.state == .noControlPath)
        #expect(outcome.owned == [sandbox.file("ctl/aire.sock"): socket, sandbox.file("control/a.sock"): socket])
        #expect(outcome.sessions.first?.since != nil)
        // Riding the link reaches the master.
        #expect(SessionSharing.socketAnswers(sandbox.file("control/a.sock")))
    }

    @Test("The user's own live master on an alias is never touched")
    func leavesOtherLiveMasters() throws {
        let sandbox = try SocketSandbox()
        let socket = try sandbox.listen("ctl/calder-abc.sock")
        let theirs = try sandbox.listen("control/own.sock")
        // A link the user made to their own live master.
        try FileManager.default.createDirectory(atPath: sandbox.file("control"), withIntermediateDirectories: true)
        #expect(symlink(theirs, sandbox.file("control/theirs-link.sock")) == 0)

        let outcome = SessionSharing.reconcile(
            masters: [master("calder", host: "calder.leeds.ac.uk", socket: socket)],
            aliases: [
                alias("calder-rash", host: "calder.leeds.ac.uk", controlPath: theirs),
                alias("calder", host: "calder.leeds.ac.uk", controlPath: sandbox.file("control/theirs-link.sock"))
            ],
            linkDirectory: sandbox.file("ctl"),
            owned: [:],
            share: true
        )
        #expect(SessionSharing.pathKind(theirs) == .socket)
        #expect(SessionSharing.socketAnswers(theirs))
        #expect(sandbox.readLink("control/theirs-link.sock") == theirs)
        for status in outcome.aliases {
            guard case .heldByOtherSession(let since) = status.state else {
                Issue.record("\(status.alias) should be held by the other session")
                continue
            }
            #expect(since != nil)
        }
        #expect(outcome.owned.keys.sorted() == [sandbox.file("ctl/calder.sock")])
    }

    @Test("Dead leftovers on an alias are replaced; when the master goes, only our links go")
    func replacesDeadAndCleansUp() throws {
        let sandbox = try SocketSandbox()
        let socket = try sandbox.listen("ctl/aire-abc.sock")
        try sandbox.listen("control/dead.sock")
        sandbox.kill("control/dead.sock")
        try FileManager.default.createDirectory(atPath: sandbox.file("control"), withIntermediateDirectories: true)
        #expect(symlink(sandbox.file("control/gone.sock"), sandbox.file("control/dangling.sock")) == 0)

        let masters = [master("aire", host: "aire.leeds.ac.uk", socket: socket)]
        let aliases = [
            alias("aire", host: "aire.leeds.ac.uk", controlPath: sandbox.file("control/dead.sock")),
            alias("aire-rash", host: "aire.leeds.ac.uk", controlPath: sandbox.file("control/dangling.sock"))
        ]
        let first = SessionSharing.reconcile(masters: masters, aliases: aliases, linkDirectory: sandbox.file("ctl"), owned: [:], share: true)
        #expect(sandbox.readLink("control/dead.sock") == socket)
        #expect(sandbox.readLink("control/dangling.sock") == socket)
        #expect(first.aliases.allSatisfy { $0.state == .linked })

        // Something else the user links meanwhile stays.
        #expect(symlink(socket, sandbox.file("control/mine.sock")) == 0)

        // The master exits: every link the app made is removed, so `ssh
        // aire` can become a master of its own again.
        sandbox.stop("ctl/aire-abc.sock")
        let second = SessionSharing.reconcile(masters: masters, aliases: aliases, linkDirectory: sandbox.file("ctl"), owned: first.owned, share: true)
        #expect(second.sessions.isEmpty)
        #expect(second.owned.isEmpty)
        #expect(SessionSharing.pathKind(sandbox.file("control/dead.sock")) == .missing)
        #expect(SessionSharing.pathKind(sandbox.file("control/dangling.sock")) == .missing)
        #expect(SessionSharing.pathKind(sandbox.file("ctl/aire.sock")) == .missing)
        #expect(sandbox.readLink("control/mine.sock") == socket)
    }

    @Test("A replaced master is picked up through the same link; a new route repoints ours")
    func followsReplacementAndRouteChange() throws {
        let sandbox = try SocketSandbox()
        let direct = try sandbox.listen("ctl/aire-direct.sock")
        let aliases = [alias("aire", host: "aire.leeds.ac.uk", controlPath: sandbox.file("control/a.sock"))]
        let first = SessionSharing.reconcile(
            masters: [master("aire", host: "aire.leeds.ac.uk", socket: direct)],
            aliases: aliases, linkDirectory: sandbox.file("ctl"), owned: [:], share: true
        )
        // Reconnect: same path, new master.
        sandbox.stop("ctl/aire-direct.sock")
        try sandbox.listen("ctl/aire-direct.sock")
        #expect(SessionSharing.socketAnswers(sandbox.file("control/a.sock")))

        // Route change: a different socket; our link moves with it.
        let viaRash = try sandbox.listen("ctl/aire-rash.sock")
        let second = SessionSharing.reconcile(
            masters: [master("aire", host: "aire.leeds.ac.uk", socket: viaRash)],
            aliases: aliases, linkDirectory: sandbox.file("ctl"), owned: first.owned, share: true
        )
        #expect(sandbox.readLink("control/a.sock") == viaRash)
        #expect(sandbox.readLink("ctl/aire.sock") == viaRash)
        #expect(second.aliases.first?.state == .linked)
    }

    @Test("Sharing off removes every link but still reports session ages")
    func sharingOff() throws {
        let sandbox = try SocketSandbox()
        let socket = try sandbox.listen("ctl/aire-abc.sock")
        let masters = [master("aire", host: "aire.leeds.ac.uk", socket: socket)]
        let aliases = [alias("aire", host: "aire.leeds.ac.uk", controlPath: sandbox.file("control/a.sock"))]
        let on = SessionSharing.reconcile(masters: masters, aliases: aliases, linkDirectory: sandbox.file("ctl"), owned: [:], share: true)
        let off = SessionSharing.reconcile(masters: masters, aliases: aliases, linkDirectory: sandbox.file("ctl"), owned: on.owned, share: false)
        #expect(off.owned.isEmpty)
        #expect(off.aliases.isEmpty)
        #expect(off.sessions.count == 1)
        #expect(off.sessions.first?.stableLinkPath == nil)
        #expect(off.sessions.first?.since != nil)
        #expect(SessionSharing.pathKind(sandbox.file("control/a.sock")) == .missing)
        #expect(SessionSharing.pathKind(sandbox.file("ctl/aire.sock")) == .missing)
    }

    @Test("The service persists its manifest beside the links and reads it back")
    func serviceManifest() async throws {
        let sandbox = try SocketSandbox()
        let socket = try sandbox.listen("ctl/aire-abc.sock")
        // An ssh directory with no config: no aliases, no `ssh -G` runs.
        let service = SessionSharingService(linkDirectory: sandbox.file("ctl"), sshDirectory: sandbox.file("ssh"))
        let report = await service.reconcile(masters: [master("aire", host: "aire.leeds.ac.uk", socket: socket)], share: true)
        #expect(report.session(named: "aire")?.stableLinkPath == sandbox.file("ctl/aire.sock"))
        let manifest = sandbox.file("ctl/shared-sessions.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: manifest)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        sandbox.stop("ctl/aire-abc.sock")
        let after = await service.reconcile(masters: [master("aire", host: "aire.leeds.ac.uk", socket: socket)], share: true)
        #expect(after.sessions.isEmpty)
        #expect(SessionSharing.pathKind(sandbox.file("ctl/aire.sock")) == .missing)
    }
}

@Suite("Session continuity")
struct SessionContinuityTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A drop is due at once; an automatic attempt is not repeated while it runs")
    func dropThenAttempt() {
        var policy = AutoReconnectPolicy()
        policy.sessionDropped(.aire, at: t0)
        #expect(policy.due(at: t0) == [.aire])
        policy.attemptStarted(.aire, at: t0)
        #expect(policy.due(at: t0.addingTimeInterval(1000)).isEmpty)
        policy.record(.succeeded(passwordVerified: true), for: .aire, automatic: true, at: t0)
        #expect(policy.isEmpty)
    }

    @Test("A declined or unanswered push is never followed by another automatic one")
    func pushProblemsSuspend() {
        for outcome in [LoginOutcome.duoNotApproved, .timedOut, .passwordRejected, .passwordExpired, .jumpHostFailed, .cancelled] {
            var policy = AutoReconnectPolicy()
            policy.sessionDropped(.calder, at: t0)
            policy.attemptStarted(.calder, at: t0)
            policy.record(outcome, for: .calder, automatic: true, at: t0)
            #expect(policy.state(of: .calder) == .suspended, "\(outcome)")
            #expect(policy.due(at: t0.addingTimeInterval(86_400)).isEmpty)
            // A later drop does not wake it up; a successful manual sign-in does.
            policy.sessionDropped(.calder, at: t0.addingTimeInterval(10))
            #expect(policy.state(of: .calder) == .suspended)
            policy.record(.succeeded(passwordVerified: true), for: .calder, automatic: false, at: t0)
            #expect(policy.state(of: .calder) == nil)
        }
    }

    @Test("Push-free failures retry later, a bounded number of times")
    func boundedRetries() {
        var policy = AutoReconnectPolicy()
        policy.sessionDropped(.aire, at: t0)
        var now = t0
        for attempt in 1...AutoReconnectPolicy.maximumAttempts {
            #expect(policy.due(at: now) == [.aire], "attempt \(attempt)")
            policy.attemptStarted(.aire, at: now)
            policy.record(.failed, for: .aire, automatic: true, at: now)
            #expect(policy.due(at: now).isEmpty)
            now = now.addingTimeInterval(AutoReconnectPolicy.retryDelay)
        }
        #expect(policy.state(of: .aire) == .suspended)
    }

    @Test("A manual failure leaves the automatic plan alone; a lost attempt is retried")
    func manualFailureAndLostAttempt() {
        var policy = AutoReconnectPolicy()
        policy.sessionDropped(.aire, at: t0)
        policy.record(.failed, for: .aire, automatic: false, at: t0)
        #expect(policy.due(at: t0) == [.aire])

        policy.attemptStarted(.aire, at: t0)
        policy.sweepLostAttempts(at: t0.addingTimeInterval(60))
        #expect(policy.due(at: t0.addingTimeInterval(60)).isEmpty)
        let later = t0.addingTimeInterval(AutoReconnectPolicy.lostAttemptAfter)
        policy.sweepLostAttempts(at: later)
        #expect(policy.due(at: later) == [.aire])
    }

    @Test("Session ages read naturally")
    func ageText() {
        #expect(SessionAge.text(20) == "under a minute")
        #expect(SessionAge.text(45 * 60) == "45 min")
        #expect(SessionAge.text(3 * 3600) == "3 h")
        #expect(SessionAge.text(10 * 3600 + 12 * 60) == "10 h 12 min")
        #expect(SessionAge.text(50 * 3600) == "2 d 2 h")
        #expect(SessionAge.clock(4 * 3600 + 7 * 60) == "4:07")
    }

    @Test("The drop notification says how long the session lasted and what happens next")
    func dropNotification() {
        let automatic = JobNotificationService.sessionDroppedNotification(cluster: .calder, lasted: 3 * 3600 + 600, signingInAgain: true, timestamp: "t")
        #expect(automatic.title == "Calder session dropped")
        #expect(automatic.subtitle == "The SSH session ended after 3 h 10 min")
        #expect(automatic.body.contains("Duo"))
        let manual = JobNotificationService.sessionDroppedNotification(cluster: .aire, lasted: nil, signingInAgain: false, timestamp: "t")
        #expect(manual.subtitle == "The SSH session ended")
        #expect(manual.body.contains("Connect"))
    }

    @Test("Renew counts a push for rash and one per cluster, and says what closes")
    func renewConfirmationText() {
        let confirmation = SessionActionConfirmation(
            kind: .renew,
            work: [
                SessionWork(clusterID: .aire, clusterName: "AIRE", isLive: true, runningTerminals: 1),
                SessionWork(clusterID: .calder, clusterName: "Calder", isLive: true)
            ],
            usesJumpHost: true
        )
        #expect(confirmation.title == "Renew every session?")
        #expect(confirmation.message.contains("the rash jump host, AIRE and Calder"))
        #expect(confirmation.message.contains("3 Duo pushes"))
        #expect(confirmation.message.contains("Claude sessions"))
        #expect(confirmation.message.contains("1 running session"))
        let direct = SessionActionConfirmation(kind: .renew, work: [SessionWork(clusterID: .aire, clusterName: "AIRE")], usesJumpHost: false)
        #expect(direct.message.contains("1 Duo push,"))
    }

    @Test("Preferences written before sharing existed turn both features on")
    func preferenceDefaults() throws {
        let old = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"username":"u","route":"rashJump"}"#.utf8))
        #expect(old.shareSessions)
        #expect(old.reconnectAutomatically)
        var changed = old
        changed.shareSessions = false
        changed.reconnectAutomatically = false
        let roundTrip = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(changed))
        #expect(!roundTrip.shareSessions)
        #expect(!roundTrip.reconnectAutomatically)
    }
}
