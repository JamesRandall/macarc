// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacArch",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "macarch-cli", targets: ["macarch-cli"]),
        .executable(name: "macarch-mcp", targets: ["macarch-mcp"]),
        .executable(name: "MacArch", targets: ["MacArch"]),
    ],
    dependencies: [
        .package(path: "Packages/ArchimedesCore"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
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
            dependencies: [.product(name: "ArchimedesCore", package: "ArchimedesCore"), "MacArchAgent",
                           .product(name: "Sparkle", package: "Sparkle")],
            path: "Apps/MacArch",
            exclude: ["Info.plist", "Resources"],
            // Sparkle.framework is embedded in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ],
    swiftLanguageModes: [.v5]
)
