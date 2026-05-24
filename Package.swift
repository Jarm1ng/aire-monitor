// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AIREServerApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AIREMonitorApp", targets: ["AIREMonitorApp"]),
        .executable(name: "AIREDesktopWidget", targets: ["AIREDesktopWidget"])
    ],
    targets: [
        .executableTarget(name: "AIREMonitorApp"),
        .executableTarget(name: "AIREDesktopWidget")
    ]
)
