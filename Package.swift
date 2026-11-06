// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BuildrHooksCLI",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "BuildrBridgeContracts", targets: ["BuildrBridgeContracts"]),
        .library(name: "BuildrHooksCore", targets: ["BuildrHooksCore"]),
        .executable(name: "BuildrHooksCLI", targets: ["BuildrHooksCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        .target(name: "BuildrBridgeContracts", resources: [.copy("Fixtures")]),
        .target(name: "BuildrHooksCore", dependencies: ["BuildrBridgeContracts"]),
        .executableTarget(
            name: "BuildrHooksCLI",
            dependencies: [
                "BuildrHooksCore",
                "BuildrBridgeContracts",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            resources: [.copy("Resources/ClaudeUsageMod")]
        ),
        .testTarget(name: "BuildrBridgeContractsTests", dependencies: ["BuildrBridgeContracts"]),
        .testTarget(
            name: "BuildrHooksCoreTests",
            dependencies: [
                "BuildrHooksCore",
                "BuildrBridgeContracts",
                "BuildrHooksCLI"
            ]
        )
    ]
)
