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
        // The one thing Swift cannot do for itself: run a block and survive
        // an Objective-C `NSException` raised inside it. AVFAudio reports
        // several failures that way, and a Swift `catch` cannot see them.
        // See `Sources/ReedObjC/include/ReedObjCException.h`.
        .target(
            name: "ReedObjC",
            path: "Sources/ReedObjC"
        ),
        .executableTarget(
            name: "Reed",
            dependencies: [
                "ReedObjC",
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
