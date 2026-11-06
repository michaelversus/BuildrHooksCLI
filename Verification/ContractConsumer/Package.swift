// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ContractConsumer",
    platforms: [.macOS(.v26)],
    dependencies: [.package(name: "BuildrHooksCLI", path: "../..")],
    targets: [
        .testTarget(name: "ContractConsumerTests", dependencies: [
            .product(name: "BuildrBridgeContracts", package: "BuildrHooksCLI")
        ])
    ]
)
