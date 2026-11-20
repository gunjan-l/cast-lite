// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CastLite",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "CastCore", targets: ["CastCore"]),
        .executable(name: "CastLiteServer", targets: ["CastLiteServer"]),
        .executable(name: "CastLiteHarness", targets: ["CastLiteHarness"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CastCore",
            dependencies: [],
            path: "Sources/CastCore"
        ),
        .executableTarget(
            name: "CastLiteServer",
            dependencies: ["CastCore"],
            path: "Sources/CastLiteServer"
        ),
        .executableTarget(
            name: "CastLiteHarness",
            dependencies: ["CastCore"],
            path: "Sources/CastLiteHarness"
        ),
        .testTarget(
            name: "CastCoreTests",
            dependencies: ["CastCore"],
            path: "Tests/CastCoreTests"
        )
    ]
)
