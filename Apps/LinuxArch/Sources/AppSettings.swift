import ArchimedesCore
import Foundation
import MacArchAgent
import Observation

/// The machine's saved hardware choices and the app's file locations.
/// Shared by all windows; new windows start with the last choices. (The
/// Mac app's AppSettings, with `Preferences` for UserDefaults.)
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()
    @ObservationIgnored private let d = Preferences.standard

    /// Self-test runs (LINUXARCH_SELFTEST) keep their settings, CMOS
    /// profiles and hard discs apart from the user's.
    nonisolated static let isSelfTest = ProcessInfo.processInfo.environment["LINUXARCH_SELFTEST"] != nil

    /// The ROM in use (a file, or a folder of chip files).
    var romPath: String? { didSet { d.set(romPath, forKey: "romPath"); if let romPath { addROM(romPath) } } }
    /// The model new windows start as.
    var model: MachineModel { didSet { d.set(model.rawValue, forKey: "model") } }
    /// ROMs the user has chosen before, for the Machine menu's picker.
    private(set) var romLibrary: [ROMEntry] = []
    private(set) var recentDiscs: [String] { didSet { d.set(recentDiscs, forKey: "recentDiscs") } }

    struct ROMEntry: Hashable, Identifiable {
        var path: String
        var version: String
        var size: Int
        var id: String { path }
        func suits(_ m: MachineModel) -> Bool { ROMImporter.whyNot(version: version, size: size, on: m) == nil }
    }

    /// A ROM's name in a list: its version, with its size when another ROM
    /// on the list has the same version (ArcLibre's 2 MB and 4 MB ROMs).
    func label(_ e: ROMEntry) -> String {
        guard romLibrary.contains(where: { $0.path != e.path && $0.version == e.version }) else { return e.version }
        return "\(e.version) · \(Self.ramLabel(e.size / 1024))"
    }

    /// The ROM to use for a model: the newest that suits it, from the same
    /// family as `like` if one does (ArcLibre stays ArcLibre), the bigger
    /// of two the same version; nil if none suits.
    func preferredROM(for m: MachineModel, like path: String? = nil) -> String? {
        let suiting = romLibrary.filter { $0.suits(m) }
        let family = path.flatMap { p in romLibrary.first { $0.path == p } }.map { $0.version.prefix { $0 != " " } }
        let pool = suiting.filter { family == nil || $0.version.hasPrefix(family!) }
        return (pool.isEmpty ? suiting : pool).max {
            let order = $0.version.localizedStandardCompare($1.version)
            return order == .orderedSame ? $0.size < $1.size : order == .orderedAscending
        }?.path
    }

    static func ramLabel(_ kb: Int) -> String { kb < 1024 ? "\(kb) KB" : "\(kb / 1024) MB" }

    // Memory, processor, monitor and hard discs are remembered for each model, so
    // switching back to a model finds it as it was left.

    func ramKB(for m: MachineModel) -> Int {
        let v = d.object(forKey: "ramKB.\(m.rawValue)") as? Int
        return v.flatMap { m.ramChoices.contains($0) ? $0 : nil } ?? m.defaultRAMKB
    }

    func setRAMKB(_ kb: Int, for m: MachineModel) { d.set(kb, forKey: "ramKB.\(m.rawValue)") }

    func cpu(for m: MachineModel) -> CPUType {
        d.string(forKey: "cpu.\(m.rawValue)").flatMap(CPUType.init(rawValue:)).flatMap { m.cpuChoices.contains($0) ? $0 : nil } ?? m.defaultCPU
    }

    func setCPU(_ c: CPUType, for m: MachineModel) { d.set(c.rawValue, forKey: "cpu.\(m.rawValue)") }

    func monitor(for m: MachineModel) -> MonitorType {
        d.string(forKey: "monitor.\(m.rawValue)").flatMap(MonitorType.init(rawValue:)).flatMap { m.monitorChoices.contains($0) ? $0 : nil } ?? .standard
    }

    func setMonitor(_ t: MonitorType, for m: MachineModel) { d.set(t.rawValue, forKey: "monitor.\(m.rawValue)") }

    /// Hard disc image paths by drive ("" for none).
    func hardDiscs(for m: MachineModel) -> [String?] {
        let a = d.stringArray(forKey: "hardDiscs.\(m.rawValue)") ?? []
        return (0..<m.hardDiscSlots).map { $0 < a.count && !a[$0].isEmpty ? a[$0] : nil }
    }

    func setHardDiscs(_ paths: [String?], for m: MachineModel) {
        d.set(paths.map { $0 ?? "" }, forKey: "hardDiscs.\(m.rawValue)")
    }

    /// The Archimedes mouse has three buttons: Select, Menu (the middle
    /// one) and Adjust. What the right button does; the other of Menu and
    /// Adjust is on the middle button.
    enum SecondaryClick: String, CaseIterable, Identifiable {
        case adjust, menu
        var id: Self { self }
        var name: String { self == .adjust ? "Adjust (right button)" : "Menu (middle button)" }
    }
    var secondaryClick: SecondaryClick {
        didSet { d.set(secondaryClick.rawValue, forKey: "secondaryClick") }
    }

    /// How the PC's mouse drives the Archimedes': captured by a click and
    /// moving it by how far it moves, or left free with RISC OS's pointer
    /// following the desktop's.
    enum MouseMode: String, CaseIterable, Identifiable {
        case capture, follow
        var id: Self { self }
        var name: String { self == .capture ? "Capture the mouse" : "Follow the desktop pointer" }
    }
    var mouseMode: MouseMode {
        didSet { d.set(mouseMode.rawValue, forKey: "mouseMode") }
    }

    /// Editors (VS Code) debug the first window's machine over the Debug
    /// Adapter Protocol on this localhost port. Takes effect next launch.
    var debugAdapterEnabled: Bool { didSet { d.set(debugAdapterEnabled, forKey: "debugAdapterEnabled") } }
    /// The floppy drives' motor and head noises.
    var discDriveSounds: Bool { didSet { d.set(discDriveSounds, forKey: "discDriveSounds") } }
    var debugAdapterPort: Int { didSet { d.set(debugAdapterPort, forKey: "debugAdapterPort") } }

    private init() {
        romPath = d.string(forKey: "romPath")
        model = d.string(forKey: "model").flatMap(MachineModel.init(rawValue:)) ?? .a3000
        recentDiscs = d.stringArray(forKey: "recentDiscs") ?? []
        secondaryClick = d.string(forKey: "secondaryClick").flatMap(SecondaryClick.init(rawValue:)) ?? .adjust
        mouseMode = d.string(forKey: "mouseMode").flatMap(MouseMode.init(rawValue:)) ?? .capture
        debugAdapterEnabled = d.object(forKey: "debugAdapterEnabled") as? Bool ?? true
        discDriveSounds = d.object(forKey: "discDriveSounds") as? Bool ?? true
        debugAdapterPort = d.integer(forKey: "debugAdapterPort") == 0 ? Int(DAPServer.defaultPort) : d.integer(forKey: "debugAdapterPort")
        for p in d.stringArray(forKey: "romLibrary") ?? [] { addROM(p, save: false) }
        // Developer convenience: launched from the project with no ROM chosen.
        if romPath == nil {
            let dev = FileManager.default.currentDirectoryPath + "/roms"
            for name in ["riscos3_11", "riscos2_00"] where FileManager.default.fileExists(atPath: dev + "/" + name) {
                addROM(dev + "/" + name)
            }
            romPath = romLibrary.max { $0.version.localizedStandardCompare($1.version) == .orderedAscending }?.path
        }
        if let romPath { addROM(romPath, save: false) }
        addBundledArcLibre()
        // (Observers don't run in init: saved by hand.)
        if romPath.map({ !FileManager.default.fileExists(atPath: $0) }) ?? true {
            romPath = preferredROM(for: model) ?? romLibrary.max { $0.version.localizedStandardCompare($1.version) == .orderedAscending }?.path
            d.set(romPath, forKey: "romPath")
        }
    }

    /// ArcLibre, the free ROM rebuilt from RISC OS's public sources, comes
    /// with LinuxArch when the build has it (2 MB for any model, 4 MB for the
    /// A5000 family) so that it works without one of Acorn's. Each joins the
    /// ROM list unless it was taken off, replacing an older ArcLibre put
    /// there; Acorn's ROMs stay the default when there are any.
    private func addBundledArcLibre() {
        let bundled = Self.bundledArcLibre(withExtension: "rom").compactMap { try? ROMImage.load(paths: [$0.path]) }
        guard !bundled.isEmpty else { return }
        let declined = Set(d.stringArray(forKey: "declinedBundledROMs") ?? [])
        let installed = romLibrary.compactMap { e in (try? ROMImage.load(paths: [e.path])).map { (e, $0.sha256) } }
        let directory = (Self.supportDirectory as NSString).appendingPathComponent("ROMs")
        for rom in bundled where !declined.contains(rom.sha256) && !installed.contains(where: { $0.1 == rom.sha256 }) {
            if let path = try? ROMImporter.install(rom, into: directory) { addROM(path) }
        }
        let current = Set(bundled.map(\.sha256))
        // Earlier bundled releases go; an ArcLibre added by hand (a build of
        // your own, say) stays.
        let shipped = Set(ROMImporter.known.filter { $0.value.title.hasPrefix("ArcLibre") }.keys)
        for (e, sha) in installed where shipped.contains(sha) && e.path.hasPrefix(directory) && !current.contains(sha) {
            let replacement = preferredROM(for: model, like: e.path)
            removeROM(e.path)
            try? FileManager.default.removeItem(atPath: e.path)
            if romPath == e.path { romPath = replacement; d.set(romPath, forKey: "romPath") }
        }
    }

    /// The files of one kind in the build's ArcLibre folder.
    static func bundledArcLibre(withExtension ext: String) -> [URL] {
        guard let folder = AppPaths.resource("ArcLibre"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter { $0.hasSuffix("." + ext) }.sorted().map { folder.appendingPathComponent($0) }
    }

    /// ArcLibre's extras disc, for its 2 MB ROM (DOSFS, !Alarm and
    /// !Printers, which the 4 MB ROM has built in): a copy in LinuxArch's own
    /// folder, made from the installed one the first time, so it can be
    /// written to.
    var arcLibreExtrasDisc: URL? {
        guard let bundled = Self.bundledArcLibre(withExtension: "adf").first else { return nil }
        let folder = URL(fileURLWithPath: Self.supportDirectory).appendingPathComponent("ArcLibre")
        let copy = folder.appendingPathComponent(bundled.lastPathComponent)
        if !FileManager.default.fileExists(atPath: copy.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard (try? FileManager.default.copyItem(at: bundled, to: copy)) != nil else { return nil }
        }
        return copy
    }

    /// The bundled ArcLibre was taken off the ROM list: don't put it back.
    func declineBundledROM(sha256: String) {
        d.set((d.stringArray(forKey: "declinedBundledROMs") ?? []) + [sha256], forKey: "declinedBundledROMs")
    }

    /// Adds a ROM to the library if it loads; returns its version.
    @discardableResult
    func addROM(_ path: String, save: Bool = true) -> String? {
        if let e = romLibrary.first(where: { $0.path == path }) { return e.version }
        guard let rom = try? ROMImage.load(paths: [path]) else { return nil }
        romLibrary.append(ROMEntry(path: path, version: rom.versionString, size: rom.data.count))
        romLibrary.sort { $0.version < $1.version }
        if save { d.set(romLibrary.map(\.path), forKey: "romLibrary") }
        return rom.versionString
    }

    func removeROM(_ path: String) {
        romLibrary.removeAll { $0.path == path }
        d.set(romLibrary.map(\.path), forKey: "romLibrary")
    }

    /// `$XDG_DATA_HOME/linuxarch` (~/.local/share/linuxarch): the Mac app's
    /// Application Support/MacArch. Self-tests have a folder of their own.
    nonisolated static var supportDirectory: String {
        if isSelfTest { return (NSTemporaryDirectory() as NSString).appendingPathComponent("LinuxArch-selftest") }
        return AppPaths.dataHome.appendingPathComponent("linuxarch").path
    }

    /// CMOS is kept per model and ROM, so incompatible OS versions never
    /// share settings and each machine keeps its own configuration.
    nonisolated static func cmosPath(for rom: ROMImage, model: MachineModel) -> String {
        let name = model.rawValue.replacingOccurrences(of: "/", with: "-")
        return (supportDirectory as NSString).appendingPathComponent("Profiles/\(name)-\(rom.sha256.prefix(16))/cmos.bin")
    }

    /// Where new hard disc images go unless the user picks elsewhere.
    nonisolated static var hardDiscDirectory: String { (supportDirectory as NSString).appendingPathComponent("Hard Discs") }

    func addRecent(_ p: String) {
        var r = recentDiscs.filter { $0 != p }
        r.insert(p, at: 0)
        recentDiscs = Array(r.prefix(10))
    }

    func clearRecents() { recentDiscs = [] }
}
