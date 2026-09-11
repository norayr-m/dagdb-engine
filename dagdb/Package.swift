// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DagDB",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DagDB", targets: ["DagDB"]),
        .executable(name: "dagdb-cli", targets: ["DagDBCLI"]),
        .executable(name: "dagdb-daemon", targets: ["DagDBDaemon"]),
        .executable(name: "dagdb-twin-demo", targets: ["TwinDemo"]),
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
            name: "E3Ladder",
            dependencies: ["DagDB"],
            path: "Sources/E3Ladder"
        ),
        .executableTarget(
            name: "E2Runner",
            dependencies: ["DagDB"],
            path: "Sources/E2Runner"
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
        // Runnable narrative over the seven twin primitives merged for the
        // twin spec — see examples/twin_primitives/README.md.
        .executableTarget(
            name: "TwinDemo",
            dependencies: ["DagDB"],
            path: "Sources/TwinDemo"
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
