// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Steppe",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SteppeCore", targets: ["SteppeCore"]),
        .executable(name: "Steppe", targets: ["Steppe"]),
        .executable(name: "steppe-cli", targets: ["steppe-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4"),
    ],
    targets: [
        .target(
            name: "SteppeCore",
            path: "Sources/SteppeCore"
        ),
        .executableTarget(
            name: "Steppe",
            dependencies: [
                "SteppeCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Steppe"
        ),
        .executableTarget(
            name: "steppe-cli",
            dependencies: ["SteppeCore"],
            path: "Sources/steppe-cli"
        ),
        .testTarget(
            name: "SteppeCoreTests",
            dependencies: ["SteppeCore"],
            path: "Tests/SteppeCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
