// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Reed",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Reed",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/Reed"
        ),
        .testTarget(
            name: "ReedTests",
            dependencies: ["Reed"],
            path: "Tests/ReedTests"
        ),
    ]
)
