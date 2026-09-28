// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "eq",
    platforms: [.macOS("14.4")],
    targets: [
        .target(name: "EQAtomics", path: "Sources/EQAtomics"),
        .target(name: "EQCore", path: "Sources/EQCore"),
        .executableTarget(
            name: "eq",
            dependencies: ["EQAtomics", "EQCore"],
            path: "Sources/eq",
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]
        ),
        .testTarget(
            name: "eqTests",
            dependencies: ["eq", "EQCore"],
            path: "Tests/eqTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageVersions: [.v5],
    cLanguageStandard: .c11
)
