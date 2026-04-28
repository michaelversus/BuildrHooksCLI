// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BuildrHooksCLI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BuildrHooksCore", targets: ["BuildrHooksCore"]),
        .executable(name: "BuildrHooksCLI", targets: ["BuildrHooksCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        .target(name: "BuildrHooksCore"),
        .executableTarget(
            name: "BuildrHooksCLI",
            dependencies: [
                "BuildrHooksCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "BuildrHooksCoreTests",
            dependencies: ["BuildrHooksCore"]
        )
    ]
)
