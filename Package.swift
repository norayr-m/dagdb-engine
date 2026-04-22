// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DagDBEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DagDBEngine", targets: ["DagDBEngine"]),
        .executable(name: "dagdb-engine-cli", targets: ["DagDBCLI"]),
    ],
    targets: [
        .target(
            name: "DagDBEngine",
            path: "Sources/DagDBEngine",
            resources: [.copy("Shaders/engine.metal")]
        ),
        .executableTarget(
            name: "DagDBCLI",
            dependencies: ["DagDBEngine"],
            path: "Sources/DagDBCLI"
        ),
        .testTarget(
            name: "DagDBEngineTests",
            dependencies: ["DagDBEngine"],
            path: "Tests/DagDBEngineTests"
        ),
    ]
)
