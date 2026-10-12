import Foundation
@testable import AIREMonitorApp

/// The university account used throughout the fixtures. The exact value
/// matters for the control-socket tests: the expected hashes below were
/// computed from it and match sockets that exist on the user's Mac today.
let testUsername = "abcd1234"

/// Catalogue ids, used as parameterised-test arguments so test cases are
/// reported as "aire"/"calder" rather than as a dump of the whole profile.
let catalogIDs: [ClusterID] = ClusterCatalog.all.map(\.id)

func catalogProfile(_ id: ClusterID) -> ClusterProfile {
    guard let profile = ClusterCatalog.profile(for: id) else {
        preconditionFailure("\(id) is not in ClusterCatalog.all")
    }
    return profile
}

/// Builds the settings a `ClusterSession` would build for `profile`, without
/// constructing a session (which owns terminals, a file browser and timers).
/// Mirrors `ClusterSession.settings`: the host defaults to the profile's and
/// the storage spec is the profile's own.
func makeSettings(
    _ profile: ClusterProfile,
    route: ConnectionRoute = .directVPN,
    username: String = testUsername,
    hostname: String? = nil,
    jumpHostname: String = "rash.leeds.ac.uk",
    projectRoot: String = "/tmp/hpc-tests-project"
) -> ConnectionSettings {
    ConnectionSettings(
        clusterID: profile.id,
        clusterName: profile.displayName,
        username: username,
        hostname: hostname ?? profile.defaultHostname,
        route: route,
        jumpHostname: jumpHostname,
        duoOption: "1",
        projectRoot: projectRoot,
        storage: profile.storage
    )
}

/// Value that follows `flag` in an argv list, or nil when the flag is absent
/// or is the last element.
func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.index(after: index) < arguments.endIndex else {
        return nil
    }
    return arguments[arguments.index(after: index)]
}

/// A private, empty project root under the system temp directory. Every test
/// that touches the filesystem gets its own, so swift-testing's parallel
/// execution never shares state and nothing is written to the real
/// `.runtime/` or `~/.ssh`.
struct TemporaryProjectRoot {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hpc-monitor-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var path: String { url.path }

    var runtimeURL: URL { url.appendingPathComponent(".runtime", isDirectory: true) }

    func clusterDirectory(_ id: ClusterID) -> URL {
        runtimeURL
            .appendingPathComponent("clusters", isDirectory: true)
            .appendingPathComponent(id.rawValue, isDirectory: true)
    }

    /// Writes `contents` to a path relative to the project root, creating
    /// intermediate directories.
    @discardableResult
    func write(_ contents: String, to relativePath: String) throws -> URL {
        let fileURL = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: fileURL)
        return fileURL
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(relativePath).path)
    }

    func contents(of relativePath: String) throws -> String {
        try String(contentsOf: url.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Decodes a JSON fixture the same way the app decodes collector output and
/// cache files (default `JSONDecoder`, explicit snake_case CodingKeys).
func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}
