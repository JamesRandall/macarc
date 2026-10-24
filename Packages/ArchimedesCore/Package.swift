// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ArchimedesCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ArchimedesCore", targets: ["ArchimedesCore"]),
    ],
    targets: [
        .target(
            name: "ArchimedesCore",
            swiftSettings: [
                .unsafeFlags(["-Ounchecked", "-enforce-exclusivity=unchecked", "-wmo"], .when(configuration: .release)),
            ],
            linkerSettings: [.linkedLibrary("z")]
        ),
        .testTarget(
            name: "ArchimedesCoreTests",
            dependencies: ["ArchimedesCore"],
            resources: [.copy("Resources")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
