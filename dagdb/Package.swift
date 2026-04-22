// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DagDB",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DagDB", targets: ["DagDB"]),
        .executable(name: "dagdb-cli", targets: ["DagDBCLI"]),
        .executable(name: "dagdb-daemon", targets: ["DagDBDaemon"]),
    ],
    targets: [
        .target(
            name: "DagDB",
            path: "Sources/DagDB",
            resources: [.process("Shaders")]
        ),
        .executableTarget(
            name: "DagDBCLI",
            dependencies: ["DagDB"],
            path: "Sources/DagDBCLI"
        ),
        .executableTarget(
            name: "DagDBDaemon",
            dependencies: ["DagDB"],
            path: "Sources/DagDBDaemon"
        ),
        .testTarget(
            name: "DagDBTests",
            dependencies: ["DagDB"],
            path: "Tests/DagDBTests"
        ),
    ]
)
