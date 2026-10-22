// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ArchimedesCore",
    platforms: [.macOS(.v14)],
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
            dependencies: ["ArchimedesCore"]
        ),
    ]
)
