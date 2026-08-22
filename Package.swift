// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClipBar", targets: ["ClipBar"])
    ],
    targets: [
        .executableTarget(
            name: "ClipBar",
            path: "Sources/ClipBar",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        .testTarget(
            name: "ClipBarBaselineTests",
            dependencies: ["ClipBar"],
            path: "Tests/ClipBarBaselineTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
