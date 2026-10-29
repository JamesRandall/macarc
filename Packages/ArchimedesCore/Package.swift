// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ArchimedesCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ArchimedesCore", targets: ["ArchimedesCore"]),
        .library(name: "ArchimedesEmbedding", targets: ["ArchimedesEmbedding"]),
        // The WebAssembly module (a WASI reactor): see docs/wasm.md.
        .executable(name: "ArchimedesWasm", targets: ["ArchimedesWasm"]),
    ],
    targets: [
        .target(
            name: "ArchimedesCore",
            swiftSettings: [
                .unsafeFlags(["-Ounchecked", "-enforce-exclusivity=unchecked", "-wmo"], .when(configuration: .release)),
            ],
            linkerSettings: [.linkedLibrary("z", .when(platforms: [.macOS, .linux]))]
        ),
        // Host-neutral machine facade: everything a host needs, in bytes
        // and integers (no paths, clocks or threads). Native and WASM share it.
        .target(
            name: "ArchimedesEmbedding",
            dependencies: ["ArchimedesCore"]
        ),
        // Flat C-ABI exports of ArchimedesEmbedding for WebAssembly hosts.
        .executableTarget(
            name: "ArchimedesWasm",
            dependencies: ["ArchimedesEmbedding"],
            swiftSettings: [
                .unsafeFlags(["-Ounchecked", "-enforce-exclusivity=unchecked", "-wmo"], .when(configuration: .release)),
            ]
        ),
        .testTarget(
            name: "ArchimedesEmbeddingTests",
            dependencies: ["ArchimedesEmbedding"]
        ),
        .testTarget(
            name: "ArchimedesCoreTests",
            dependencies: ["ArchimedesCore"],
            resources: [.copy("Resources")]
        ),
    ],
    swiftLanguageModes: [.v5]
)

#if os(Linux)
// Linux's Swift has no zlib module (macOS's SDK has one): the system's
// libz (zlib1g-dev), for the core's deflate and the tests that check it.
package.targets.append(.systemLibrary(name: "zlib", path: "Sources/zlib", pkgConfig: "zlib",
                                      providers: [.apt(["zlib1g-dev"])]))
for target in package.targets where target.name == "ArchimedesCore" || target.name == "ArchimedesCoreTests" {
    target.dependencies.append(.target(name: "zlib", condition: .when(platforms: [.linux])))
}
#endif
