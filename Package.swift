// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "AnokhaLauncher",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AnokhaCore", targets: ["AnokhaCore"]),
        .executable(name: "AnokhaLauncher", targets: ["AnokhaLauncher"]),
        .executable(name: "AnokhaJobRunner", targets: ["AnokhaJobRunner"])
    ],
    targets: [
        .target(name: "AnokhaCore"),
        .executableTarget(
            name: "AnokhaLauncher",
            dependencies: ["AnokhaCore"]
        ),
        .executableTarget(
            name: "AnokhaJobRunner",
            dependencies: ["AnokhaCore"]
        ),
        .testTarget(
            name: "AnokhaCoreTests",
            dependencies: ["AnokhaCore"]
        ),
        .testTarget(
            name: "AnokhaIntegrationTests",
            dependencies: ["AnokhaCore"]
        )
    ]
)
