// swift-tools-version: 5.9
import PackageDescription

// OnyxMCP must build on both macOS and Linux (no platform-specific dependencies).
// OnyxLib and the main Onyx app require macOS 14+. OnyxCore also builds for
// iOS 17 (see docs/ios-plan.md); nothing else here does yet.
let package = Package(
    name: "Onyx",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        // Declared so the iOS build of the core has a scheme of its own
        // (`xcodebuild -scheme OnyxCore`), and for the iOS app to link.
        .library(name: "OnyxCore", targets: ["OnyxCore"]),
        .library(name: "OnyxSSH", targets: ["OnyxSSH"]),
        .library(name: "OnyxUI", targets: ["OnyxUI"]),
        .library(name: "OnyxToday", targets: ["OnyxToday"]),
        .library(name: "OnyxPad", targets: ["OnyxPad"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        // The in-process SSH client (OnyxSSH): iOS can't run `ssh`, and the
        // Mac can opt in. See docs/ios-plan.md.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.12.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "6.0.0"),
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
        // The one piece of AppKit Swift can't express: an NSColor subclass
        // (see OnyxTerminalBackgroundColor.h). macOS only, and only OnyxLib
        // uses it, so the Linux bridge build never touches it.
        .target(
            name: "OnyxAppKitShims",
            path: "Sources/OnyxAppKitShims"
        ),
        // Everything that isn't drawing or Mac-only: Models, Stores and the
        // Services that don't launch processes. No AppKit, no UIKit — it
        // builds for macOS and iOS, and the iOS build is what keeps it so.
        .target(
            name: "OnyxCore",
            dependencies: ["OnyxVersion"],
            path: "Sources/OnyxCore"
        ),
        // In-process SSH on SwiftNIO SSH: connections, exec and shell
        // channels, PTYs, SFTP, forwarding, keys and known hosts. Builds for
        // macOS and iOS, and implements OnyxCore's RemoteTransport.
        .target(
            name: "OnyxSSH",
            dependencies: [
                "OnyxCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/OnyxSSH"
        ),
        // SwiftUI views shared by the Mac and the iOS apps — the Today
        // sections first (docs/ios-plan.md). No AppKit, no UIKit.
        .target(
            name: "OnyxUI",
            dependencies: ["OnyxCore"],
            path: "Sources/OnyxUI"
        ),
        // Onyx Today: the iPhone app's model and page, from the shared
        // sections and the built-in SSH client. The app target that wraps
        // it is Apps/OnyxToday.
        .target(
            name: "OnyxToday",
            dependencies: ["OnyxCore", "OnyxUI", "OnyxSSH"],
            path: "Sources/OnyxToday"
        ),
        // Onyx on an iPad: the shared hosts' tmux sessions in SwiftTerm's
        // UIKit view over the built-in client, beside the phone's Today. The
        // terminal view is iOS-only; the rest builds on the Mac for tests.
        .target(
            name: "OnyxPad",
            dependencies: [
                "OnyxCore", "OnyxUI", "OnyxSSH", "OnyxToday",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/OnyxPad"
        ),
        .target(
            name: "OnyxLib",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                "OnyxCore",
                "OnyxUI",
                "OnyxSSH",
                "OnyxVersion",
                "OnyxAppKitShims",
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
        // A real sshd for tests (LocalSSHD). Test-only: no product uses it.
        .target(
            name: "OnyxTestSupport",
            path: "Tests/OnyxTestSupport"
        ),
        .testTarget(
            name: "OnyxTests",
            dependencies: ["OnyxCore", "OnyxUI", "OnyxLib", "OnyxSSH", "OnyxToday", "OnyxPad", "OnyxVersion"],
            path: "Tests/OnyxTests"
        ),
        .testTarget(
            name: "OnyxIntegrationTests",
            dependencies: ["OnyxCore", "OnyxLib", "OnyxSSH", "OnyxTestSupport"],
            path: "Tests/OnyxIntegrationTests"
        ),
    ]
)
