// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "eq",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(
            name: "eq",
            path: "Sources/eq",
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]
        ),
        .testTarget(
            name: "eqTests",
            dependencies: ["eq"],
            path: "Tests/eqTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
