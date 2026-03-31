// swift-tools-version: 5.9
import PackageDescription

// OnyxMCP must build on both macOS and Linux (no platform-specific dependencies).
// OnyxLib and the main Onyx app require macOS 14+.
let package = Package(
    name: "Onyx",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "OnyxLib",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/OnyxLib"
        ),
        .executableTarget(
            name: "Onyx",
            dependencies: ["OnyxLib"],
            path: "Sources/OnyxApp",
            exclude: ["Info.plist"],
            resources: [.copy("AppIcon.icns")]
        ),
        // OnyxMCP: cross-platform (macOS + Linux). No dependencies.
        // Build on Linux: swift build --product OnyxMCP
        .executableTarget(
            name: "OnyxMCP",
            dependencies: [],
            path: "Sources/OnyxMCP"
        ),
        .testTarget(
            name: "OnyxTests",
            dependencies: ["OnyxLib"],
            path: "Tests/OnyxTests"
        ),
    ]
)
