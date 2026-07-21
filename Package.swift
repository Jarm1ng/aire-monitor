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
        .executableTarget(name: "AIREDesktopWidget")
    ]
)
