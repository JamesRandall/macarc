import ArchimedesCore
import Foundation

// A network as saved: the same shape as MacBeeb's (nodes with kinds,
// station numbers and places on a canvas), so that one day a network can
// hold both apps' machines. (After MacBeeb's NetworkProject.)

/// A network of Archimedes as saved: its machines and what they're for,
/// their hardware, discs and places on the canvas. Configuration only; the
/// machines' running state isn't saved.
struct NetworkProject: Codable, Equatable {
    /// The manifest's format. Older manifests are migrated on load (see
    /// `NetworkPackage`); newer ones are refused rather than half-read.
    static let currentSchemaVersion = 1

    var schemaVersion = Self.currentSchemaVersion
    var id = UUID()
    var name: String
    /// The Econet's network number: 0, the local network.
    var networkNumber = 0
    var nodes: [NetworkNode] = []
    var canvas = CanvasLayout()
    var workspace = Workspace()

    init(name: String, nodes: [NetworkNode] = []) {
        self.name = name
        self.nodes = nodes
    }

    subscript(id: UUID) -> NetworkNode? {
        get { nodes.first { $0.id == id } }
        set {
            guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
            if let newValue { nodes[index] = newValue } else { nodes.remove(at: index) }
        }
    }

    /// The machines (everything but the clock), in station number order.
    var stations: [NetworkNode] {
        nodes.filter(\.isMachine).sorted { ($0.stationNumber ?? 0, $0.name) < ($1.stationNumber ?? 0, $1.name) }
    }

    var hasClock: Bool { nodes.contains { $0.kind == .clock } }

    /// The clock's rate (nil: no clock).
    var clockRate: Int? { nodes.first { $0.kind == .clock }.map { $0.clockRate ?? EconetTime.defaultClockRate } }

    /// The lowest station number that's free, from `start`.
    func freeStationNumber(from start: Int = 1) -> Int? {
        let used = Set(nodes.compactMap(\.stationNumber))
        return (max(1, start)...254).first { !used.contains($0) } ?? (1...254).first { !used.contains($0) }
    }

    /// A name like "A3000 3" that isn't taken.
    func freeName(_ base: String) -> String {
        let names = Set(nodes.map(\.name))
        if !names.contains(base) { return base }
        return (2...).lazy.map { "\(base) \($0)" }.first { !names.contains($0) }!
    }

    // MARK: Placing

    /// A machine card's size on the canvas, and the space between them.
    static let cardSize = CanvasPoint(x: 236, y: 230)
    static let columnSpacing = 260.0
    static let rowSpacing = 330.0

    /// Where a new node of `kind` goes: at the end of its row, so the trunk
    /// grows to reach it. Stations go along the top row, servers and the
    /// clock along the row below.
    func nextPosition(for kind: NetworkNode.Kind) -> CanvasPoint {
        let stationRow = commonY(nodes.filter { $0.kind == .station })
        let serverRow = commonY(nodes.filter { $0.kind != .station })
        let y: Double
        switch kind {
        case .station:
            y = stationRow ?? serverRow.map { $0 - Self.rowSpacing } ?? 0
        case .fileServer, .clock:
            y = serverRow ?? stationRow.map { $0 + Self.rowSpacing } ?? Self.rowSpacing
        }
        let row = nodes.filter { abs($0.position.y - y) < Self.cardSize.y / 2 }
        let x = row.map(\.position.x).max().map { $0 + Self.columnSpacing } ?? nodes.map(\.position.x).min() ?? 0
        return freePosition(near: CanvasPoint(x: x, y: y))
    }

    /// `point`, or the nearest place to the right of it along its row that
    /// no card covers.
    func freePosition(near point: CanvasPoint, excluding id: UUID? = nil) -> CanvasPoint {
        var candidate = point
        for _ in 0..<500 {
            let covered = nodes.contains { node in
                node.id != id && abs(node.position.x - candidate.x) < Self.cardSize.x
                    && abs(node.position.y - candidate.y) < Self.cardSize.y
            }
            if !covered { return candidate }
            candidate.x += Self.columnSpacing
        }
        return candidate
    }

    /// The y most of these nodes share (their row), if there are any.
    private func commonY(_ nodes: [NetworkNode]) -> Double? {
        let counts = Dictionary(grouping: nodes, by: { ($0.position.y / 10).rounded() * 10 }).mapValues(\.count)
        return counts.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key
    }

    // MARK: Problems

    /// What's wrong with the network as set up, for the canvas to show.
    var problems: [NetworkProblem] {
        var problems: [NetworkProblem] = []
        let machines = nodes.filter(\.isMachine)
        for (number, group) in Dictionary(grouping: machines.filter { $0.stationNumber != nil }, by: { $0.stationNumber! })
        where group.count > 1 {
            problems.append(.duplicateStation(number, group.map(\.id)))
        }
        for node in machines {
            if let number = node.stationNumber, !NetworkNode.validStationNumbers.contains(number) {
                problems.append(.reservedStation(number, node.id))
            }
            if let model = node.setup?.model, !model.takesEconet {
                problems.append(.noEconet(model, node.id))
            }
        }
        if machines.count > 1 && !hasClock { problems.append(.noClock) }
        if nodes.filter({ $0.kind == .clock }).count > 1 { problems.append(.twoClocks) }
        return problems
    }

    /// Why `number` can't be station `node`'s, if it can't.
    func stationNumberProblem(_ number: Int, for node: UUID) -> String? {
        guard NetworkNode.validStationNumbers.contains(number) else {
            return "Station numbers go from 1 to 254: 0 and 255 are for broadcasts"
        }
        if let other = nodes.first(where: { $0.id != node && $0.stationNumber == number }) {
            return "\(other.name) is station \(number)"
        }
        return nil
    }
}

/// Something about the network a real one wouldn't work with.
enum NetworkProblem: Equatable, Hashable {
    case duplicateStation(Int, [UUID])
    case reservedStation(Int, UUID)
    case noEconet(MachineModel, UUID)
    case noClock
    case twoClocks

    var message: String {
        switch self {
        case .duplicateStation(let number, let ids): "\(ids.count) machines are station \(number): each needs its own number"
        case .reservedStation(let number, _): "Station \(number) is reserved: use 1 to 254"
        case .noEconet(let model, _): "The \(model.rawValue) has no Econet header: it can't join the network"
        case .noClock: "No clock: an Econet needs one to carry anything"
        case .twoClocks: "Two clocks: a network has one"
        }
    }

    /// The nodes it's about.
    var nodes: [UUID] {
        switch self {
        case .duplicateStation(_, let ids): ids
        case .reservedStation(_, let id), .noEconet(_, let id): [id]
        case .noClock, .twoClocks: []
        }
    }
}

/// An Archimedes as a network has it: what a standalone machine's Configure
/// window sets, with the ROM by its version (paths differ between Macs).
struct StationSetup: Codable, Equatable {
    var model: MachineModel
    var cpu: CPUType
    var ramKB: Int
    var monitor: MonitorType
    /// The RISC OS version, e.g. "RISC OS 3.11 (29 Sep 1992)"; nil for the
    /// ROM chosen in Settings.
    var rom: String?

    init(model: MachineModel, cpu: CPUType? = nil, ramKB: Int? = nil, monitor: MonitorType = .standard, rom: String? = nil) {
        self.model = model
        self.cpu = cpu ?? model.defaultCPU
        self.ramKB = ramKB ?? model.defaultRAMKB
        self.monitor = monitor
        self.rom = rom
    }

    /// "A3000 · 2 MB · RISC OS 3.11"
    var summary: String {
        let memory = ramKB >= 1024 ? "\(ramKB / 1024) MB" : "\(ramKB) KB"
        var text = "\(model.rawValue) · \(memory)"
        if cpu != model.defaultCPU { text += " · \(cpu.rawValue)" }
        if let rom, let version = rom.split(separator: "(").first { text += " · " + version.trimmingCharacters(in: .whitespaces) }
        return text
    }
}

/// One thing on the network: an Archimedes (an ordinary station, or one
/// that serves files), or the network's clock.
struct NetworkNode: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case station, fileServer, clock

        var displayName: String {
            switch self {
            case .station: "Archimedes"
            case .fileServer: "File Server"
            case .clock: "Network Clock"
            }
        }

        /// The usual station number for a server.
        var conventionalStation: Int? { self == .fileServer ? 254 : nil }
    }

    static let validStationNumbers = 1...254

    /// Stable whatever the station number becomes.
    var id = UUID()
    var kind: Kind
    var name: String
    /// Nil for the clock.
    var stationNumber: Int?
    /// Nil for the clock.
    var setup: StationSetup?
    /// The floppies in its drives, by drive.
    var discs: [Int: MediaReference] = [:]
    /// Its hard discs, by drive (:4 is 0).
    var hardDiscs: [Int: MediaReference] = [:]
    /// Its place on the canvas, in canvas points.
    var position = CanvasPoint()
    /// Whether it's switched on when the network opens.
    var poweredOn = true
    /// The clock's rate, in bits per second (the clock only).
    var clockRate: Int?

    var isMachine: Bool { kind != .clock }

    init(kind: Kind, name: String, stationNumber: Int?, setup: StationSetup?, position: CanvasPoint = CanvasPoint()) {
        self.kind = kind
        self.name = name
        self.stationNumber = stationNumber
        self.setup = setup
        self.position = position
        if kind == .clock { clockRate = EconetTime.defaultClockRate }
    }

    static func clock(at position: CanvasPoint) -> NetworkNode {
        NetworkNode(kind: .clock, name: "Clock", stationNumber: nil, setup: nil, position: position)
    }
}

/// A disc a station's drive holds: a copy kept in the network's package (so
/// the machines never write to the user's own file), and where it came from.
struct MediaReference: Codable, Equatable {
    /// The copy's name in the package's Media folder.
    var storedName: String
    /// What it was called when it was added.
    var displayName: String
    /// The original's path, for reference only.
    var originalPath: String?
}

struct CanvasPoint: Codable, Equatable, Hashable {
    var x: Double
    var y: Double

    init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }
}

/// How the canvas was last shown.
struct CanvasLayout: Codable, Equatable {
    /// 0 until the network's first shown: then it's fitted to the window.
    var zoom = 0.0
    /// The canvas point at the centre of the view.
    var centre = CanvasPoint()
    var snapToGrid = true
}

/// The tiled workspace: which stations, how many columns, and the Focus
/// view's machine.
struct Workspace: Codable, Equatable {
    var tiles: [UUID] = []
    /// 0 for as many as fit.
    var columns = 0
    var focus: UUID?
}
