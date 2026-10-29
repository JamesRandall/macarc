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

#if os(Linux)
// On Linux, LinuxArch (a GTK4 and libadwaita app) takes the Mac app's place:
// SwiftUI, Metal and Sparkle are macOS's. The core, macarch-cli and
// macarch-mcp are the same on both. See Apps/LinuxArch/README.md.
// (Sparkle stays a dependency, which nothing here uses, so that
// Package.resolved is the same on both. Builds without the network, the
// Flatpak's, set LINUXARCH_OFFLINE to leave it out.)
if Context.environment["LINUXARCH_OFFLINE"] != nil {
    package.dependencies.removeAll { dependency in
        if case .sourceControl(_, let location, _) = dependency.kind { return location.hasSuffix("/Sparkle") }
        return false
    }
}
package.products.removeAll { $0.name == "MacArch" }
package.targets.removeAll { $0.name == "MacArch" }
package.products.append(.executable(name: "linuxarch", targets: ["LinuxArch"]))
package.targets += [
    // GTK4 and libadwaita.
    .systemLibrary(name: "CGtk", path: "Apps/LinuxArch/System/CGtk", pkgConfig: "libadwaita-1",
                   providers: [.apt(["libadwaita-1-dev", "libgtk-4-dev"])]),
    // SDL3, for sound.
    .systemLibrary(name: "CSDL3", path: "Apps/LinuxArch/System/CSDL3", pkgConfig: "sdl3",
                   providers: [.apt(["libsdl3-dev"])]),
    // GStreamer, for video recording (the Mac app uses AVFoundation).
    .systemLibrary(name: "CGStreamer", path: "Apps/LinuxArch/System/CGStreamer", pkgConfig: "gstreamer-app-1.0",
                   providers: [.apt(["libgstreamer1.0-dev", "libgstreamer-plugins-base1.0-dev"])]),
    // The picture, drawn with OpenGL (the Mac app's Metal renderer).
    .target(name: "CArchGL", path: "Apps/LinuxArch/CArchGL",
            cSettings: [.unsafeFlags(["-O2"])], linkerSettings: [.linkedLibrary("epoxy")]),
    // Holding the pointer still while the mouse is captured, on Wayland.
    .target(name: "CWaylandPointer", path: "Apps/LinuxArch/CWaylandPointer", exclude: ["README.md"],
            cSettings: [.unsafeFlags(["-w"])], linkerSettings: [.linkedLibrary("wayland-client")]),
    .executableTarget(
        name: "LinuxArch",
        dependencies: [.product(name: "ArchimedesCore", package: "ArchimedesCore"), "MacArchAgent",
                       "CGtk", "CSDL3", "CGStreamer", "CArchGL", "CWaylandPointer"],
        path: "Apps/LinuxArch/Sources"
    ),
]
#endif
