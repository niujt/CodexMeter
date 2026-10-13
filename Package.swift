// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexMeter",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "CodexMeter", targets: ["CodexMeter"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "CodexMeter",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/CodexMeter"
        ),
        .testTarget(
            name: "CodexMeterTests",
            dependencies: ["CodexMeter"],
            path: "Tests/CodexMeterTests"
        )
    ]
)
