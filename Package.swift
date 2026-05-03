// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AntigravityPorter",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AntigravityPorterCore",
            targets: ["AntigravityPorterCore"]
        ),
        .executable(
            name: "AntigravityPorter",
            targets: ["AntigravityPorterApp"]
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
        .testTarget(
            name: "AntigravityPorterCoreTests",
            dependencies: ["AntigravityPorterCore"]
        )
    ]
)
