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
        // NOTE: SwiftLint is intentionally NOT integrated as a SwiftPM plugin.
        // Both realm/SwiftLint and SimplyDanny/SwiftLintPlugins ship build-tool
        // plugins with prebuild capability, and SwiftPM 6.x rejects them with:
        //   "a prebuild command cannot use executables built from source,
        //    including executable target 'swiftlint'"
        // Until SwiftLint ships a buildCommand-based plugin, lint via the
        // standalone script: `scripts/lint.sh` (downloads the SwiftLint binary
        // artifact bundle on first run, then invokes it).
        // See docs/static-analysis.md for details.
    ],
    targets: [
        // One string, shared by the app and the bridge — which can't
        // import each other, since OnyxMCP is standalone and builds on
        // Linux. Keep this target free of dependencies and platform code.
        .target(
            name: "OnyxVersion",
            path: "Sources/OnyxVersion"
        ),
        .target(
            name: "OnyxLib",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                "OnyxVersion",
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
        // OnyxMCP: cross-platform (macOS + Linux). Depends only on the
        // version constant, which is deliberately dependency-free.
        // Build on Linux: swift build --product OnyxMCP
        .executableTarget(
            name: "OnyxMCP",
            dependencies: ["OnyxVersion"],
            path: "Sources/OnyxMCP"
        ),
        .testTarget(
            name: "OnyxTests",
            dependencies: ["OnyxLib"],
            path: "Tests/OnyxTests"
        ),
        .testTarget(
            name: "OnyxIntegrationTests",
            dependencies: ["OnyxLib"],
            path: "Tests/OnyxIntegrationTests"
        ),
    ]
)
