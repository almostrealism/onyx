// swift-tools-version: 5.9
import PackageDescription

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
