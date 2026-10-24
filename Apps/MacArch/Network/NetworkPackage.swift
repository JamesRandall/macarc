import Foundation

/// A network on disc: a `.macarchnet` package (a folder Finder shows as one
/// file) with `manifest.json`, the project, and `Media`, the copies of its
/// discs and each machine's CMOS. (As MacBeeb's `.macbeebnet`.)
enum NetworkPackage {
    static let fileExtension = "macarchnet"
    static let manifestName = "manifest.json"
    static let mediaFolder = "Media"

    enum LoadError: Error, CustomStringConvertible {
        case notANetwork
        case newerVersion(Int)

        var description: String {
            switch self {
            case .notANetwork: "This isn't a MacArch network: it has no manifest."
            case .newerVersion(let version): "This network was saved by a newer MacArch (format \(version)). Update MacArch to open it."
            }
        }
    }

    static func load(from url: URL) throws -> NetworkProject {
        let manifest = url.appendingPathComponent(manifestName)
        guard FileManager.default.fileExists(atPath: manifest.path) else { throw LoadError.notANetwork }
        let data = try Data(contentsOf: manifest)
        let version = try JSONDecoder().decode(Versioned.self, from: data).schemaVersion
        guard version <= NetworkProject.currentSchemaVersion else { throw LoadError.newerVersion(version) }
        // Migrations from older versions go here, by version.
        return try JSONDecoder().decode(NetworkProject.self, from: data)
    }

    /// Writes the manifest (atomically) and makes the package if it's new.
    static func save(_ project: NetworkProject, to url: URL) throws {
        try FileManager.default.createDirectory(at: mediaURL(in: url), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(project).write(to: url.appendingPathComponent(manifestName), options: .atomic)
    }

    /// A new network from a template, saved at `url`.
    @discardableResult
    static func create(_ template: NetworkTemplate, named name: String? = nil, at url: URL) throws -> NetworkProject {
        var project = template.makeProject()
        if let name, !name.isEmpty { project.name = name }
        try save(project, to: url)
        return project
    }

    static func mediaURL(in package: URL) -> URL {
        package.appendingPathComponent(mediaFolder, isDirectory: true)
    }

    /// Copies a disc image into the package, under a new name, so the
    /// network's machines write to the copy. (On APFS the copy is a clone:
    /// a hard disc costs no space until it's written.)
    static func importMedia(_ source: URL, into package: URL) throws -> MediaReference {
        let folder = mediaURL(in: package)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = UUID().uuidString.prefix(8) + "-" + source.lastPathComponent
        try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(String(name)))
        return MediaReference(storedName: String(name), displayName: source.lastPathComponent, originalPath: source.path)
    }

    static func url(of media: MediaReference, in package: URL) -> URL {
        mediaURL(in: package).appendingPathComponent(media.storedName)
    }

    /// A machine's CMOS RAM, kept with the network.
    static func cmosURL(of node: UUID, in package: URL) -> URL {
        mediaURL(in: package).appendingPathComponent("cmos-\(node.uuidString).bin")
    }

    /// Media the manifest no longer mentions (and CMOS of machines gone).
    static func unusedMedia(of project: NetworkProject, in package: URL) -> [URL] {
        var used = Set(project.nodes.flatMap { $0.discs.values.map(\.storedName) + $0.hardDiscs.values.map(\.storedName) })
        used.formUnion(project.nodes.map { cmosURL(of: $0.id, in: package).lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(at: mediaURL(in: package), includingPropertiesForKeys: nil)) ?? []
        return files.filter { !used.contains($0.lastPathComponent) }
    }

    private struct Versioned: Decodable {
        var schemaVersion: Int
    }
}

/// Ready-made networks to start from.
enum NetworkTemplate: String, CaseIterable, Identifiable {
    case twoArchimedes, schoolClassroom, family, empty

    var id: String { rawValue }

    var title: String {
        switch self {
        case .twoArchimedes: "Two Archimedes"
        case .schoolClassroom: "School Classroom"
        case .family: "The Archimedes Family"
        case .empty: "Empty Network"
        }
    }

    var summary: String {
        switch self {
        case .twoArchimedes: "The smallest network: two A3000s, stations 1 and 2, and a clock."
        case .schoolClassroom: "Four A3000s and a file server on station 254, as a 1990s school had. The server runs Acorn's Level 4 File Server, from discs you supply."
        case .family: "An A310, an A440/1, an A3000 and an A5000 side by side, from 1987 to 1991, on one network."
        case .empty: "Just the clock. Add machines from the palette."
        }
    }

    var symbolName: String {
        switch self {
        case .twoArchimedes: "rectangle.on.rectangle"
        case .schoolClassroom: "building.columns"
        case .family: "square.stack.3d.up"
        case .empty: "square.dashed"
        }
    }

    /// Canvas spacing between machines.
    static let spacing = 260.0

    func makeProject() -> NetworkProject {
        func station(_ name: String, _ number: Int, _ x: Double, _ setup: StationSetup = StationSetup(model: .a3000)) -> NetworkNode {
            NetworkNode(kind: .station, name: name, stationNumber: number, setup: setup, position: CanvasPoint(x: x, y: 0))
        }
        let s = Self.spacing
        var project = NetworkProject(name: title)
        switch self {
        case .twoArchimedes:
            project.nodes = [station("A3000 1", 1, -s / 2), station("A3000 2", 2, s / 2), .clock(at: CanvasPoint(x: 0, y: 200))]
        case .schoolClassroom:
            project.nodes = (0..<4).map { station("A3000 \($0 + 1)", $0 + 1, (Double($0) - 1.5) * s) }
                + [NetworkNode.fileServer(at: CanvasPoint(x: -s / 2, y: 330)), .clock(at: CanvasPoint(x: s / 2 + 40, y: 330))]
        case .family:
            project.nodes = [station("A310", 1, -1.5 * s, StationSetup(model: .a310, rom: "RISC OS 2")),
                             station("A440/1", 2, -0.5 * s, StationSetup(model: .a440)),
                             station("A3000", 3, 0.5 * s),
                             station("A5000", 4, 1.5 * s, StationSetup(model: .a5000)),
                             .clock(at: CanvasPoint(x: 0, y: 330))]
        case .empty:
            project.nodes = [.clock(at: CanvasPoint())]
        }
        project.workspace.tiles = project.stations.filter { $0.kind == .station }.map(\.id)
        return project
    }
}

extension NetworkNode {
    /// A file server: an A440/1 with 4 MB and a hard disc, as Acorn's Level
    /// 4 File Server wants, on station 254.
    static func fileServer(at position: CanvasPoint, number: Int = 254) -> NetworkNode {
        NetworkNode(kind: .fileServer, name: "File Server", stationNumber: number,
                    setup: StationSetup(model: .a440, ramKB: 4096), position: position)
    }
}
