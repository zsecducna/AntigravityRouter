// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AntigravityRouter",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AntigravityPorterCore",
            targets: ["AntigravityPorterCore"]
        ),
        .executable(
            name: "AntigravityRouter",
            targets: ["AntigravityPorterApp"]
        ),
        .executable(
            name: "AntigravityPorterMonitor",
            targets: ["AntigravityPorterMonitor"]
        )
    ],
    targets: [
        .target(
            name: "AntigravityPorterCore"
        ),
        .executableTarget(
            name: "AntigravityPorterApp",
            dependencies: ["AntigravityPorterCore"]
        ),
        .executableTarget(
            name: "AntigravityPorterMonitor",
            dependencies: ["AntigravityPorterCore"]
        ),
        .testTarget(
            name: "AntigravityPorterCoreTests",
            dependencies: ["AntigravityPorterCore"]
        ),
        .testTarget(
            name: "AntigravityPorterAppTests",
            dependencies: ["AntigravityPorterApp"]
        )
    ]
)
