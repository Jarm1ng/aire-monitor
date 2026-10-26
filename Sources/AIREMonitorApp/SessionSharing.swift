import Foundation
import Darwin

// MARK: - Sharing the app's SSH sessions with other programs
//
// The app's ControlMasters live at hashed paths (~/.ssh/ctl/aire-<hash>.sock)
// that nothing else knows about, so `ssh aire` in Terminal — or a Claude
// session running commands on the cluster — used to sign in all over again
// (password, Duo). Sharing makes every other program ride the app's sign-in:
//
// - a stable link per live master, ~/.ssh/ctl/<name>.sock (aire, calder,
//   rash), which `scripts/hpc-session` and `ssh -S` use;
// - a link at the ControlPath of every ~/.ssh/config alias that resolves
//   (`ssh -G`) to the same host and user — `aire`, `aire-rash`, `rash`, ... —
//   so a plain `ssh aire`, `scp` or `rsync` multiplexes over the app's
//   session with no prompt. An alias that jumps through rash (`ProxyJump
//   rash`) rides the shared rash session for its first hop as well.
//
// Every link is a symlink to the master's socket, so a replaced master (a
// Reconnect binds the same path) is picked up without relinking. Links are
// only ever made where nothing live is: a socket another live master holds —
// the user's own `ssh aire-rash`, say — is left alone and reported, and
// taken over only once it has died. Links the app made are recorded in a
// manifest and removed when their master goes away, so a dead link never
// stops `ssh <alias>` from becoming a master of its own; nothing the app did
// not create is ever deleted except a dead socket, which ssh itself would
// unlink the same way.

/// A live ControlMaster the app can offer to other programs.
struct SharedMaster: Equatable, Sendable {
    /// Stable short name, also the stable link's file name: the cluster id
    /// ("aire", "calder") or the jump host's first label ("rash").
    let name: String
    let displayName: String
    let hostname: String
    let username: String
    let socketPath: String
}

/// One `Host` alias from ~/.ssh/config as `ssh -G` resolves it.
struct SSHAlias: Equatable, Sendable {
    let name: String
    let hostname: String
    let user: String
    let port: Int
    /// nil when the alias has no ControlPath (or "none").
    let controlPath: String?
}

/// A master's state for the Sessions card, the menu bar and the CLI.
struct SharedSessionStatus: Equatable, Sendable, Identifiable {
    var id: String { name }
    let name: String
    let displayName: String
    let socketPath: String
    /// ~/.ssh/ctl/<name>.sock; present only while sharing is on and the
    /// master answers.
    let stableLinkPath: String?
    /// When the master started listening (its socket's birth time): the
    /// moment the sign-in completed, for masters adopted from an earlier
    /// run as well.
    let since: Date?
}

/// What sharing did for one alias that names a live master's host.
struct SharedAliasStatus: Equatable, Sendable, Identifiable {
    enum State: Equatable, Sendable {
        /// `ssh <alias>` rides the app's session.
        case linked
        /// Another live master (the user's own `ssh <alias>`, typically)
        /// holds the alias's socket. Left alone: it keeps working, and the
        /// app links the alias once it has gone.
        case heldByOtherSession(since: Date?)
        /// The alias has no ControlPath, so there is nothing to link.
        case noControlPath
        case failed(String)
    }

    var id: String { alias }
    let alias: String
    /// `SharedMaster.name` of the session it maps to.
    let sessionName: String
    let state: State
}

struct SessionSharingReport: Equatable, Sendable {
    var sessions: [SharedSessionStatus] = []
    var aliases: [SharedAliasStatus] = []
    var isSharing = false

    func session(named name: String) -> SharedSessionStatus? {
        sessions.first { $0.name == name }
    }

    func aliases(for sessionName: String) -> [SharedAliasStatus] {
        aliases.filter { $0.sessionName == sessionName }
    }
}

/// Pure pieces of sharing (parsing, socket checks, the link rules), kept
/// free of state so tests can drive them against a temporary directory.
enum SessionSharing {
    /// sun_path holds 104 bytes on macOS, terminator included.
    static let maximumSocketPathLength = 103

    // MARK: ssh_config discovery

    /// Literal host names declared by `Host` lines in `configPath` and the
    /// files it `Include`s (relative includes resolve against
    /// `sshDirectory`, as ssh does for the user config). Patterns (`*`,
    /// `?`), negations and names that would read as an ssh option are
    /// skipped; order of first appearance is kept.
    static func hostAliases(inConfigAt configPath: String, sshDirectory: String) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        var visited = Set<String>()
        collectAliases(configPath, sshDirectory: sshDirectory, depth: 0, names: &names, seen: &seen, visited: &visited)
        return names
    }

    private static func collectAliases(
        _ path: String,
        sshDirectory: String,
        depth: Int,
        names: inout [String],
        seen: inout Set<String>,
        visited: inout Set<String>
    ) {
        let resolved = (path as NSString).resolvingSymlinksInPath
        guard depth < 8, visited.insert(resolved).inserted,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return
        }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            guard let (keyword, arguments) = configLine(String(rawLine)) else {
                continue
            }
            switch keyword {
            case "host":
                for name in arguments where isLiteralAlias(name) && seen.insert(name).inserted {
                    names.append(name)
                }
            case "include":
                for pattern in arguments {
                    for file in expandInclude(pattern, sshDirectory: sshDirectory) {
                        collectAliases(file, sshDirectory: sshDirectory, depth: depth + 1, names: &names, seen: &seen, visited: &visited)
                    }
                }
            default:
                continue
            }
        }
    }

    /// `Keyword arg arg` or `Keyword=arg`, comments and blank lines skipped,
    /// double-quoted arguments unquoted. The keyword comes back lowercased.
    static func configLine(_ line: String) -> (String, [String])? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
            return nil
        }
        let keywordEnd = trimmed.firstIndex { $0 == " " || $0 == "\t" || $0 == "=" } ?? trimmed.endIndex
        let keyword = trimmed[..<keywordEnd].lowercased()
        var rest = Substring(trimmed[keywordEnd...]).drop { $0 == " " || $0 == "\t" }
        if rest.first == "=" {
            rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" }
        }
        var arguments: [String] = []
        var current = ""
        var inQuotes = false
        for character in rest {
            if character == "\"" {
                inQuotes.toggle()
            } else if (character == " " || character == "\t") && !inQuotes {
                if !current.isEmpty {
                    arguments.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty {
            arguments.append(current)
        }
        return (keyword, arguments)
    }

    static func isLiteralAlias(_ name: String) -> Bool {
        !name.isEmpty
            && !name.hasPrefix("-")
            && !name.contains(where: { "*?!%".contains($0) || $0.isWhitespace })
    }

    private static func expandInclude(_ pattern: String, sshDirectory: String) -> [String] {
        var path = (pattern as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            path = (sshDirectory as NSString).appendingPathComponent(path)
        }
        var matches = glob_t()
        defer { globfree(&matches) }
        guard glob(path, 0, nil, &matches) == 0 else {
            return []
        }
        return (0..<Int(matches.gl_pathc)).compactMap { index in
            matches.gl_pathv[index].map { String(cString: $0) }
        }.sorted()
    }

    /// The fields sharing needs from `ssh -G <alias>` output.
    static func parseResolvedConfig(_ output: String, alias: String) -> SSHAlias? {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else {
                continue
            }
            let key = parts[0].lowercased()
            if values[key] == nil {
                values[key] = String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let hostname = values["hostname"], !hostname.isEmpty, let user = values["user"] else {
            return nil
        }
        let controlPath = values["controlpath"].flatMap { $0.isEmpty || $0.lowercased() == "none" ? nil : $0 }
        return SSHAlias(
            name: alias,
            hostname: hostname,
            user: user,
            port: values["port"].flatMap(Int.init) ?? 22,
            controlPath: controlPath
        )
    }

    // MARK: Sockets

    /// True when something accepts connections on the unix socket at
    /// `path` (symlinks followed): a live master. Connecting and hanging up
    /// without a word is harmless to an OpenSSH mux master.
    static func socketAnswers(_ path: String) -> Bool {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumSocketPathLength else {
            return false
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return false
        }
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    /// When the socket at `path` (symlinks followed) was created.
    static func birthDate(ofSocketAt path: String) -> Date? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK else {
            return nil
        }
        let time = info.st_birthtimespec
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9)
    }

    // MARK: Links

    enum PathKind: Equatable {
        case missing
        case symlink(String)
        case socket
        case other
    }

    static func pathKind(_ path: String) -> PathKind {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return .missing
        }
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            return .symlink((try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? "")
        case S_IFSOCK:
            return .socket
        default:
            return .other
        }
    }

    enum LinkResult: Equatable {
        case linked
        case heldByOtherSession(since: Date?)
        case failed(String)
    }

    /// Makes `link` a symlink to `target` unless something live that the
    /// app did not link holds it. `owned` is the manifest's record of links
    /// the app made (link -> target). Never renames over a path: a master
    /// ssh binds there between our look and our symlink() makes the
    /// symlink fail with EEXIST instead of being clobbered.
    static func ensureLink(_ link: String, to target: String, owned: [String: String]) -> LinkResult {
        switch pathKind(link) {
        case .missing:
            break
        case .symlink(let current):
            if current == target {
                return .linked
            }
            let ours = owned[link] == current
            // A link someone else made (`calder` -> `calder-rash`'s socket)
            // is kept while its master answers.
            if !ours, socketAnswers(link) {
                return .heldByOtherSession(since: birthDate(ofSocketAt: link))
            }
            unlink(link)
        case .socket:
            // The user's own master for this alias. Checked twice so a
            // momentary refusal never deletes a live one.
            if socketAnswers(link) || (usleep(200_000) == 0 && socketAnswers(link)) {
                return .heldByOtherSession(since: birthDate(ofSocketAt: link))
            }
            // A dead master's leftover: ssh unlinks these itself.
            unlink(link)
        case .other:
            return .failed("\(link) is not a socket")
        }
        let directory = (link as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: directory) {
            try? FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        if symlink(target, link) == 0 {
            return .linked
        }
        let reason = String(cString: strerror(errno))
        if errno == EEXIST {
            return .heldByOtherSession(since: birthDate(ofSocketAt: link))
        }
        return .failed("could not link \(link): \(reason)")
    }

    struct Outcome: Equatable {
        var sessions: [SharedSessionStatus] = []
        var aliases: [SharedAliasStatus] = []
        /// The manifest after this pass: every link the app now owns.
        var owned: [String: String] = [:]
    }

    /// One pass: links for every live master (when `share`), the alias
    /// report, and removal of every owned link that is no longer wanted.
    static func reconcile(
        masters: [SharedMaster],
        aliases: [SSHAlias],
        linkDirectory: String,
        owned previouslyOwned: [String: String],
        share: Bool
    ) -> Outcome {
        var outcome = Outcome()
        var handled = Set<String>()
        let live = masters.filter { socketAnswers($0.socketPath) }

        for master in live {
            var stableLink: String?
            if share {
                let link = (linkDirectory as NSString).appendingPathComponent("\(master.name).sock")
                if link != master.socketPath, ensureLink(link, to: master.socketPath, owned: previouslyOwned) == .linked {
                    outcome.owned[link] = master.socketPath
                    stableLink = link
                }
                handled.insert(link)
            }
            outcome.sessions.append(SharedSessionStatus(
                name: master.name,
                displayName: master.displayName,
                socketPath: master.socketPath,
                stableLinkPath: stableLink,
                since: birthDate(ofSocketAt: master.socketPath)
            ))
        }

        if share {
            for alias in aliases {
                guard let master = live.first(where: { matches(alias, $0) }) else {
                    continue
                }
                guard let controlPath = alias.controlPath else {
                    outcome.aliases.append(SharedAliasStatus(alias: alias.name, sessionName: master.name, state: .noControlPath))
                    continue
                }
                if controlPath == master.socketPath {
                    outcome.aliases.append(SharedAliasStatus(alias: alias.name, sessionName: master.name, state: .linked))
                    continue
                }
                let state: SharedAliasStatus.State
                if handled.contains(controlPath), let target = outcome.owned[controlPath] {
                    // Two aliases resolving to one ControlPath.
                    state = target == master.socketPath ? .linked : .heldByOtherSession(since: nil)
                } else {
                    switch ensureLink(controlPath, to: master.socketPath, owned: previouslyOwned) {
                    case .linked:
                        outcome.owned[controlPath] = master.socketPath
                        state = .linked
                    case .heldByOtherSession(let since):
                        state = .heldByOtherSession(since: since)
                    case .failed(let reason):
                        state = .failed(reason)
                    }
                    handled.insert(controlPath)
                }
                outcome.aliases.append(SharedAliasStatus(alias: alias.name, sessionName: master.name, state: state))
            }
        }

        // Links the app made that are no longer wanted (master gone, alias
        // edited, sharing off): removed only while they still point where
        // the app pointed them.
        for (link, target) in previouslyOwned where outcome.owned[link] == nil {
            if case .symlink(let current) = pathKind(link), current == target {
                unlink(link)
            }
        }
        return outcome
    }

    static func matches(_ alias: SSHAlias, _ master: SharedMaster) -> Bool {
        alias.port == 22
            && alias.hostname.caseInsensitiveCompare(master.hostname) == .orderedSame
            && alias.user == master.username
    }
}

// MARK: - Service

/// Runs sharing passes off the main actor (they spawn `ssh -G` and touch
/// the file system) and persists the manifest the CLI also reads.
actor SessionSharingService {
    let linkDirectory: String
    let configPath: String
    let sshDirectory: String
    var manifestPath: String { (linkDirectory as NSString).appendingPathComponent("shared-sessions.json") }

    /// Alias resolution is cached until the config files change, and at
    /// most `aliasRefreshInterval` anyway (a `Match` may depend on more
    /// than the files).
    static let aliasRefreshInterval: TimeInterval = 600
    private var cachedAliases: [SSHAlias] = []
    private var cachedSignature: [String: Date] = [:]
    private var cachedAt: Date?

    init(
        linkDirectory: String = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/ctl"),
        sshDirectory: String = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")
    ) {
        self.linkDirectory = linkDirectory
        self.sshDirectory = sshDirectory
        configPath = (sshDirectory as NSString).appendingPathComponent("config")
    }

    func reconcile(masters: [SharedMaster], share: Bool, now: Date = Date()) -> SessionSharingReport {
        let manifest = loadManifest()
        let aliases = share ? resolvedAliases(now: now) : []
        let outcome = SessionSharing.reconcile(
            masters: masters,
            aliases: aliases,
            linkDirectory: linkDirectory,
            owned: manifest,
            share: share
        )
        let report = SessionSharingReport(sessions: outcome.sessions, aliases: outcome.aliases, isSharing: share)
        saveManifest(owned: outcome.owned, masters: masters, report: report, now: now)
        return report
    }

    /// Forces the next pass to resolve the aliases again.
    func invalidateAliases() {
        cachedAt = nil
    }

    private func resolvedAliases(now: Date) -> [SSHAlias] {
        let names = SessionSharing.hostAliases(inConfigAt: configPath, sshDirectory: sshDirectory)
        let signature = configSignature()
        if let cachedAt, signature == cachedSignature, now.timeIntervalSince(cachedAt) < Self.aliasRefreshInterval {
            return cachedAliases
        }
        cachedAliases = names.compactMap { name in
            Self.runSSHConfigQuery(alias: name).flatMap { SessionSharing.parseResolvedConfig($0, alias: name) }
        }
        cachedSignature = signature
        cachedAt = now
        return cachedAliases
    }

    /// Modification dates of the user config and everything in ~/.ssh it
    /// may include: a change to any of them re-resolves the aliases.
    private func configSignature() -> [String: Date] {
        var signature: [String: Date] = [:]
        let manager = FileManager.default
        var candidates = [configPath]
        if let entries = try? manager.subpathsOfDirectory(atPath: sshDirectory) {
            candidates += entries
                .filter { !$0.hasPrefix("ctl/") && !$0.hasPrefix("control/") && !$0.hasSuffix(".sock") && !$0.hasPrefix("known_hosts") }
                .prefix(200)
                .map { (sshDirectory as NSString).appendingPathComponent($0) }
        }
        for path in candidates {
            if let date = (try? manager.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
                signature[path] = date
            }
        }
        return signature
    }

    /// `ssh -G <alias>`: ssh's own resolution of the alias (ControlPath
    /// tokens such as %C expanded), bounded to a few seconds. Local only:
    /// it never connects.
    static func runSSHConfigQuery(alias: String, timeout: TimeInterval = 5) -> String? {
        guard SessionSharing.isLiteralAlias(alias) else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", alias]
        process.environment = MonitorService.childEnvironment()
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Manifest

    private struct Manifest: Codable {
        struct Session: Codable {
            let name: String
            let displayName: String
            let host: String
            let socket: String
            let link: String?
            let since: Date?
        }
        struct Alias: Codable {
            let alias: String
            let session: String
            let state: String
        }
        var updatedAt: Date
        var sharing: Bool
        /// link path -> socket it points at, for every link the app made.
        var links: [String: String]
        var sessions: [Session]
        var aliases: [Alias]
    }

    private func loadManifest() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: manifestPath) else {
            return [:]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Manifest.self, from: data))?.links ?? [:]
    }

    private func saveManifest(owned: [String: String], masters: [SharedMaster], report: SessionSharingReport, now: Date) {
        let sessions = report.sessions.map { status in
            Manifest.Session(
                name: status.name,
                displayName: status.displayName,
                host: masters.first { $0.name == status.name }?.hostname ?? "",
                socket: status.socketPath,
                link: status.stableLinkPath,
                since: status.since
            )
        }
        let aliases = report.aliases.map { status -> Manifest.Alias in
            let state: String
            switch status.state {
            case .linked: state = "linked"
            case .heldByOtherSession: state = "held-by-other-session"
            case .noControlPath: state = "no-controlpath"
            case .failed: state = "failed"
            }
            return Manifest.Alias(alias: status.alias, session: status.sessionName, state: state)
        }
        let manifest = Manifest(updatedAt: now, sharing: report.isSharing, links: owned, sessions: sessions, aliases: aliases)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(manifest) else {
            return
        }
        let manager = FileManager.default
        if !manager.fileExists(atPath: linkDirectory) {
            try? manager.createDirectory(atPath: linkDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let url = URL(fileURLWithPath: manifestPath)
        do {
            try data.write(to: url, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestPath)
        } catch {
            Log.sharing.error("Could not write the shared-session manifest: \(error.localizedDescription, privacy: .public)")
        }
    }
}
