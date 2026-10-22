// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacArch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "macarch-cli", targets: ["macarch-cli"]),
        .executable(name: "macarch-mcp", targets: ["macarch-mcp"]),
        .executable(name: "MacArch", targets: ["MacArch"]),
    ],
    dependencies: [
        .package(path: "Packages/ArchimedesCore"),
    ],
    targets: [
        .executableTarget(
            name: "macarch-cli",
            dependencies: [.product(name: "ArchimedesCore", package: "ArchimedesCore")],
            path: "Tools/macarch-cli"
        ),
        .target(
            name: "MacArchAgent",
            dependencies: [.product(name: "ArchimedesCore", package: "ArchimedesCore")],
            path: "Tools/MacArchAgent"
        ),
        .executableTarget(
            name: "macarch-mcp",
            dependencies: ["MacArchAgent"],
            path: "Tools/macarch-mcp"
        ),
        .testTarget(
            name: "MacArchAgentTests",
            dependencies: ["MacArchAgent", .product(name: "ArchimedesCore", package: "ArchimedesCore")],
            path: "tests/MacArchAgentTests"
        ),
        .executableTarget(
            name: "MacArch",
            dependencies: [.product(name: "ArchimedesCore", package: "ArchimedesCore"), "MacArchAgent"],
            path: "Apps/MacArch",
            exclude: ["Info.plist", "Resources"]
        ),
    ]
)
