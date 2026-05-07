// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iCloud-Bridge",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "icloud-bridge", targets: ["icloud-bridge"]),
        .library(name: "BridgeCore", targets: ["BridgeCore"]),
        .library(name: "ServiceMail", targets: ["ServiceMail"]),
        .library(name: "ServiceCalendar", targets: ["ServiceCalendar"]),
        .library(name: "ServiceDrive", targets: ["ServiceDrive"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.3.0"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "icloud-bridge",
            dependencies: [
                "BridgeCore",
                "BridgeConfig",
                "BridgeAuth",
                "BridgePolicy",
                "ServiceMail",
                "ServiceCalendar",
                "ServiceDrive",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/icloud-bridge"
        ),
        // BridgePolicy already a transitive dep through BridgeCore; explicit
        // here so Audit subcommand can call AuditSink directly.
        .target(
            name: "ServiceMail",
            dependencies: [
                "BridgeCore",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/ServiceMail"
        ),
        .target(
            name: "ServiceCalendar",
            dependencies: [
                "BridgeCore",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/ServiceCalendar"
        ),
        .target(
            name: "ServiceDrive",
            dependencies: [
                "BridgeCore",
                "BridgeConfig",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/ServiceDrive"
        ),
        .target(
            name: "BridgeCore",
            dependencies: [
                "BridgeConfig",
                "BridgeAuth",
                "BridgePolicy",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            path: "Sources/BridgeCore"
        ),
        .target(
            name: "BridgeConfig",
            dependencies: [
                "TOMLKit",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/BridgeConfig"
        ),
        .target(
            name: "BridgeAuth",
            dependencies: [
                "BridgeConfig",
                "TOMLKit",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/BridgeAuth"
        ),
        .target(
            name: "BridgePolicy",
            dependencies: [
                "BridgeConfig",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/BridgePolicy"
        ),
        .testTarget(
            name: "BridgeTests",
            dependencies: [
                "BridgeConfig",
                "BridgeAuth",
                "BridgePolicy",
                "BridgeCore",
                "ServiceMail",
                "ServiceCalendar",
                "ServiceDrive",
            ],
            path: "Tests/BridgeTests"
        ),
    ]
)
