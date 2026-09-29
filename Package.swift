// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "eq",
    platforms: [.macOS("14.4")],
    targets: [
        .target(name: "EQAtomics", path: "Sources/EQAtomics"),
        .target(name: "EQCore", path: "Sources/EQCore"),
        .target(name: "EQTerm", path: "Sources/EQTerm", swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]),
        .executableTarget(
            name: "eq",
            dependencies: ["EQAtomics", "EQCore", "EQTerm"],
            path: "Sources/eq",
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]
        ),
        .testTarget(
            name: "eqTests",
            dependencies: ["eq", "EQCore", "EQTerm"],
            path: "Tests/eqTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "EQTermTests", dependencies: ["EQTerm"], path: "Tests/EQTermTests"),
    ],
    swiftLanguageVersions: [.v5],
    cLanguageStandard: .c11
)
