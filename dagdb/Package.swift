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
        // DSL parser + command handler, extracted from the daemon executable
        // so they're testable against a real engine without a socket or shm.
        .target(
            name: "DagDBDaemonKit",
            dependencies: ["DagDB"],
            path: "Sources/DagDBDaemonKit"
        ),
        .executableTarget(
            name: "DagDBCLI",
            dependencies: ["DagDB"],
            path: "Sources/DagDBCLI"
        ),
        .executableTarget(
            name: "DagDBDaemon",
            dependencies: ["DagDB", "DagDBDaemonKit"],
            path: "Sources/DagDBDaemon"
        ),
        .testTarget(
            name: "DagDBTests",
            dependencies: ["DagDB"],
            path: "Tests/DagDBTests"
        ),
        .testTarget(
            name: "DagDBDaemonKitTests",
            dependencies: ["DagDB", "DagDBDaemonKit"],
            path: "Tests/DagDBDaemonKitTests"
        ),
    ]
)
