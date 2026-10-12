// swift-tools-version: 6.0

import PackageDescription

// The unit tests use swift-testing (`import Testing`): XCTest does not exist
// on a Command Line Tools-only Mac. Two settings work around how the CLT
// package swift-testing; both are harmless when Xcode is the toolchain.
// - The CLT omit the module of Testing's _Testing_Foundation cross-import
//   overlay, so a test file importing both Testing and Foundation fails with
//   "no such module '_Testing_Foundation'". The tests use nothing from that
//   overlay, so overlays are disabled for the test target only.
// - Testing.framework requires macOS 14 while the app targets macOS 13; the
//   test bundle is linked for 14 so ld does not warn on every build. The app
//   and widget products are untouched.
// The CLT also need `-F` for Testing.framework on every module (including
// SwiftPM's generated test runner, which target settings cannot reach), so
// on such a machine run the tests through Tests/AIREMonitorAppTests/run_tests.sh.
#if arch(arm64)
let testBundleTriple = "arm64-apple-macosx14.0"
#else
let testBundleTriple = "x86_64-apple-macosx14.0"
#endif

let package = Package(
    name: "AIREServerApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AIREMonitorApp", targets: ["AIREMonitorApp"]),
        .executable(name: "AIREDesktopWidget", targets: ["AIREDesktopWidget"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "AIREMonitorApp",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        ),
        .executableTarget(name: "AIREDesktopWidget"),
        // Deterministic unit tests for the multi-cluster foundation:
        // connection settings and control-socket names, collector argv,
        // SSH failure wording, snapshot/cache decoding, preference migration.
        // No network, Keychain or ~/.ssh access; files go to temp dirs.
        .testTarget(
            name: "AIREMonitorAppTests",
            dependencies: ["AIREMonitorApp"],
            exclude: ["run_tests.sh"],
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-disable-cross-import-overlays"])
            ],
            linkerSettings: [
                .unsafeFlags(["-target", testBundleTriple])
            ]
        )
    ]
)
