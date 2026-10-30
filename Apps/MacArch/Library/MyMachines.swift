import AppKit
import ArchimedesCore
import Observation
import SwiftUI

/// My Machines: Archimedes saved with a name, to start again as they were
/// left: model, processor, memory, monitor, ROM, hard discs and RISC OS's
/// CMOS settings. Each is a folder in Application Support/MacArch/Machines
/// with `info.json` (its name and dates), `machine.json` (a machine
/// configuration file, as Export writes, with ROM and hard disc paths
/// absolute), `machine.cmos` and `screen.png` (the screen when it was saved).
/// A machine started from here keeps its CMOS in `machine.cmos`, so RISC
/// OS's settings carry on from one run to the next; its hardware changes
/// only when it's saved again.
@MainActor
@Observable
final class MyMachines {
    static let shared = MyMachines()

    struct Info: Codable {
        var id: UUID
        var name: String
        var created: Date
        var modified: Date
    }

    struct Entry: Identifiable {
        var info: Info
        let folder: URL
        /// As written, paths unresolved (nil if it can't be read).
        var configuration: MachineConfiguration?
        /// Why it can't start (a ROM or hard disc that's gone), if it can't.
        var problem: String?
        var id: UUID { info.id }
        var name: String { info.name }
        var configurationURL: URL { folder.appendingPathComponent("machine.json") }
        var cmosURL: URL { folder.appendingPathComponent("machine.cmos") }
        var screenURL: URL { folder.appendingPathComponent("screen.png") }
    }

    private(set) var entries: [Entry] = []
    /// Bumped when a screen image is rewritten, so thumbnails reload.
    private(set) var revision = 0

    static var directory: URL {
        URL(fileURLWithPath: AppSettings.supportDirectory).appendingPathComponent("Machines")
    }

    private init() { reload() }

    func reload() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        entries = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("info.json")),
                  let info = try? Self.decoder.decode(Info.self, from: data) else { return nil }
            var e = Entry(info: info, folder: folder)
            e.configuration = (try? Data(contentsOf: e.configurationURL)).flatMap { try? JSONDecoder().decode(MachineConfiguration.self, from: $0) }
            do { _ = try MachineConfigurationFile.load(from: e.configurationURL) } catch { e.problem = "\(error)" }
            return e
        }
        .sorted { $0.info.modified > $1.info.modified }
    }

    func entry(_ id: UUID) -> Entry? { entries.first { $0.id == id } }

    // MARK: Saving

    /// Saves a running machine as a new entry, or over `id`'s. Returns its id.
    @discardableResult
    func save(_ machine: MachineController, name: String, over id: UUID? = nil) async throws -> UUID {
        let (configuration, cmos, screen) = try await machine.currentSetup()
        let info: Info
        let folder: URL
        if let id, let existing = entry(id) {
            info = Info(id: id, name: name, created: existing.info.created, modified: Date())
            folder = existing.folder
        } else {
            let id = UUID()
            info = Info(id: id, name: name, created: Date(), modified: Date())
            folder = Self.directory.appendingPathComponent(id.uuidString)
        }
        try write(info, configuration, cmos: cmos, screen: screen, to: folder)
        machine.savedMachineID = info.id
        reload()
        revision += 1
        return info.id
    }

    /// A new entry, set up by hand and never started: its first start holds
    /// Delete, so RISC OS sets its CMOS to the defaults, which it keeps.
    @discardableResult
    func create(name: String, model: MachineModel, cpu: CPUType, ramKB: Int, monitor: MonitorType,
                romPath: String, hardDiscs: [String?]) throws -> UUID {
        var c = MachineConfiguration(model: model)
        c.cpu = cpu
        c.ramKB = ramKB
        c.monitorType = monitor
        c.romPaths = [romPath]
        c.hardDiscs = model.hardDiscSlots == 0 ? [] : hardDiscs
        c.powerOnKeys = Self.firstBootKeys
        // Builds it once, so a ROM or hard disc that won't do is said now.
        _ = try Machine(configuration: c)
        let info = Info(id: UUID(), name: unique(name), created: Date(), modified: Date())
        try write(info, c, cmos: nil, screen: nil, to: Self.directory.appendingPathComponent(info.id.uuidString))
        reload()
        return info.id
    }

    /// Delete: a created machine's first start resets CMOS to RISC OS's defaults.
    static let firstBootKeys: [UInt8] = [0x34]

    /// After a created machine's first start: from now on it has CMOS of its
    /// own, so it starts without Delete held.
    private func settle(_ e: Entry) {
        guard var c = e.configuration, c.cmosPath == nil, c.powerOnKeys == Self.firstBootKeys,
              FileManager.default.fileExists(atPath: e.cmosURL.path) else { return }
        c.powerOnKeys = []
        c.cmosPath = "machine.cmos"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(c).write(to: e.configurationURL, options: .atomic)
        reload()
    }

    /// Writes an entry's folder. The configuration is checked as Export
    /// checks it; the CMOS is saved, so the machine needs no Delete held at
    /// power-on to set it up.
    private func write(_ info: Info, _ configuration: MachineConfiguration, cmos: [UInt8]?, screen: Data?, to folder: URL) throws {
        var c = configuration
        c.version = MachineConfiguration.currentVersion
        c.powerOnKeys = cmos == nil ? c.powerOnKeys : []
        c.cmosPath = cmos == nil ? nil : "machine.cmos"
        c.romPaths = c.romPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        c.hardDiscs = c.hardDiscs.map { $0.map { URL(fileURLWithPath: $0).standardizedFileURL.path } }
        var check = c
        check.cmosPath = nil
        try MachineConfigurationFile.validate(check)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let cmos {
            guard cmos.count == 256 else { throw MachineError.badConfiguration("CMOS must contain exactly 256 bytes") }
            try Data(cmos).write(to: folder.appendingPathComponent("machine.cmos"), options: .atomic)
        }
        if let screen { try screen.write(to: folder.appendingPathComponent("screen.png"), options: .atomic) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(c).write(to: folder.appendingPathComponent("machine.json"), options: .atomic)
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(info).write(to: folder.appendingPathComponent("info.json"), options: .atomic)
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    /// A name for a machine: its model and ROM, made unique.
    func suggestedName(for machine: MachineController) -> String {
        let rom = machine.romVersion.components(separatedBy: " (").first ?? ""
        let base = rom.isEmpty ? machine.model.rawValue : "\(machine.model.rawValue) with \(rom)"
        return unique(base)
    }

    private func unique(_ base: String) -> String {
        let names = Set(entries.map(\.name))
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: Changing

    func rename(_ id: UUID, to name: String) {
        guard var e = entry(id), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        e.info.name = name.trimmingCharacters(in: .whitespaces)
        e.info.modified = Date()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(e.info).write(to: e.folder.appendingPathComponent("info.json"), options: .atomic)
        reload()
    }

    func duplicate(_ id: UUID) throws {
        guard let e = entry(id) else { return }
        let info = Info(id: UUID(), name: unique(e.name + " copy"), created: Date(), modified: Date())
        let folder = Self.directory.appendingPathComponent(info.id.uuidString)
        try FileManager.default.copyItem(at: e.folder, to: folder)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(info).write(to: folder.appendingPathComponent("info.json"), options: .atomic)
        reload()
    }

    /// Moves an entry's folder to the Trash (its ROM and hard discs stay).
    func remove(_ id: UUID) {
        guard let e = entry(id) else { return }
        try? FileManager.default.trashItem(at: e.folder, resultingItemURL: nil)
        for c in MachineController.live.allObjects where c.savedMachineID == id { c.savedMachineID = nil }
        reload()
    }

    // MARK: Import and export

    /// Adds a machine configuration file (and its CMOS) as a new entry.
    @discardableResult
    func importConfiguration(from url: URL) throws -> UUID {
        let c = try MachineConfigurationFile.load(from: url)
        _ = try ROMImage.load(paths: c.romPaths)
        let cmos = try c.cmosPath.map { [UInt8](try Data(contentsOf: URL(fileURLWithPath: $0))) }
        var name = url.lastPathComponent
        for suffix in [".json", ".machine"] where name.lowercased().hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
        let info = Info(id: UUID(), name: unique(name), created: Date(), modified: Date())
        try write(info, c, cmos: cmos, screen: nil, to: Self.directory.appendingPathComponent(info.id.uuidString))
        reload()
        return info.id
    }

    func chooseAndImport() -> UUID? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a machine configuration to add to My Machines. Keep its ROM and CMOS files beside it when their paths are relative."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do { return try importConfiguration(from: url) } catch {
            Self.alert("Could not import the machine", "\(error)")
            return nil
        }
    }

    /// Writes an entry as a machine configuration file elsewhere.
    func export(_ id: UUID) {
        guard let e = entry(id) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = e.name + ".machine.json"
        panel.message = "Save this machine's settings and a companion CMOS file. ROMs and hard discs are referenced, not copied."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var c = try MachineConfigurationFile.load(from: e.configurationURL)
            let cmos = try c.cmosPath.map { [UInt8](try Data(contentsOf: URL(fileURLWithPath: $0))) }
            c.cmosPath = nil
            if let cmos { try MachineConfigurationFile.save(c, cmos: cmos, to: url) } else {
                let m = try Machine(configuration: c)
                try MachineConfigurationFile.save(c, cmos: m.cmos, to: url)
            }
        } catch {
            Self.alert("Could not export the machine", "\(error)")
        }
    }

    // MARK: Starting

    /// The window already running this entry, if one is.
    func running(_ id: UUID) -> MachineController? {
        MachineController.live.allObjects.first { $0.savedMachineID == id && $0.host != nil && !$0.isStation }
    }

    /// Starts an entry in a window of its own, or brings forward the window
    /// already running it.
    func start(_ id: UUID, openWindow: OpenWindowAction) {
        guard let e = entry(id) else { return }
        if let running = running(id), running.startedFromMyMachines {
            openWindow(id: MachineConfigurationCommands.windowID, value: running.id)
            return
        }
        do {
            let machine = try prepare(id)
            openWindow(id: MachineConfigurationCommands.windowID, value: machine.id)
        } catch {
            Self.alert("Could not start \(e.name)", "\(error)")
        }
    }

    /// A machine running an entry, for a window to show.
    func prepare(_ id: UUID) throws -> MachineController {
        guard let e = entry(id) else { throw MachineError.badConfiguration("That machine has gone from My Machines") }
        let machine = try MachineConfigurationCommands.prepare(from: e.configurationURL, savedMachine: e.id)
        settle(e)
        return machine
    }

    static func alert(_ message: String, _ info: String) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = info
        a.runModal()
    }
}

