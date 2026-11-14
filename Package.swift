// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CastLite",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "CastCore", targets: ["CastCore"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CastCore",
            dependencies: [],
            path: "Sources/CastCore"
        ),
        .testTarget(
            name: "CastCoreTests",
            dependencies: ["CastCore"],
            path: "Tests/CastCoreTests"
        )
    ]
)
