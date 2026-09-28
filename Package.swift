// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "eq",
    platforms: [.macOS("14.4")],
    targets: [
        .target(name: "EQAtomics", path: "Sources/EQAtomics"),
        .executableTarget(
            name: "eq",
            dependencies: ["EQAtomics"],
            path: "Sources/eq",
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]
        ),
        .testTarget(
            name: "eqTests",
            dependencies: ["eq"],
            path: "Tests/eqTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
