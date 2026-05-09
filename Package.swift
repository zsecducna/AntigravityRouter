// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AntigravityRouter",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AntigravityRouterCore",
            targets: ["AntigravityRouterCore"]
        ),
        .executable(
            name: "AntigravityRouter",
            targets: ["AntigravityRouterApp"]
        ),
        .executable(
            name: "AntigravityRouterMonitor",
            targets: ["AntigravityRouterMonitor"]
        )
    ],
    targets: [
        .target(
            name: "AntigravityRouterCore"
        ),
        .executableTarget(
            name: "AntigravityRouterApp",
            dependencies: ["AntigravityRouterCore"]
        ),
        .executableTarget(
            name: "AntigravityRouterMonitor",
            dependencies: ["AntigravityRouterCore"]
        ),
        .testTarget(
            name: "AntigravityRouterCoreTests",
            dependencies: ["AntigravityRouterCore"]
        ),
        .testTarget(
            name: "AntigravityRouterAppTests",
            dependencies: ["AntigravityRouterApp"]
        )
    ]
)
