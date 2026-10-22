import ArchimedesCore
import MacArchAgent
import Foundation
import Observation

/// The machine's saved hardware choices and the app's file locations.
/// Shared by all windows; new windows start with the last choices.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()
    private let d = AppSettings.store

    /// Self-test runs (MACARCH_SELFTEST) keep their settings, CMOS profiles
    /// and hard discs apart from the user's, starting from nothing each time.
    nonisolated static let isSelfTest = ProcessInfo.processInfo.environment["MACARCH_SELFTEST"] != nil
    nonisolated(unsafe) static let store: UserDefaults = {
        guard isSelfTest else { return .standard }
        let suite = "com.accidentalfish.macarch.selftest"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite) ?? .standard
    }()

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
        var id: String { path }
    }

    static func ramLabel(_ kb: Int) -> String { kb < 1024 ? "\(kb) KB" : "\(kb / 1024) MB" }

    // Memory, processor, monitor and hard discs are remembered for each model, so
    // switching back to a model finds it as it was left.

    func ramKB(for m: MachineModel) -> Int {
        // Before models existed the A3000's memory was stored as "ramKB".
        let v = d.object(forKey: "ramKB.\(m.rawValue)") as? Int ?? (m == .a3000 ? d.object(forKey: "ramKB") as? Int : nil)
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
    /// one) and Adjust. What the Mac's secondary (right or two-finger)
    /// click does; the other of Menu and Adjust is on a modified click.
    enum SecondaryClick: String, CaseIterable, Identifiable {
        case adjust, menu
        var id: Self { self }
        var name: String { self == .adjust ? "Adjust (right button)" : "Menu (middle button)" }
    }
    var secondaryClick: SecondaryClick {
        didSet { d.set(secondaryClick.rawValue, forKey: "secondaryClick") }
    }

    /// Editors (VS Code) debug the first window's machine over the Debug
    /// Adapter Protocol on this localhost port. Takes effect next launch.
    var debugAdapterEnabled: Bool { didSet { d.set(debugAdapterEnabled, forKey: "debugAdapterEnabled") } }
    var debugAdapterPort: Int { didSet { d.set(debugAdapterPort, forKey: "debugAdapterPort") } }

    private init() {
        debugAdapterEnabled = d.object(forKey: "debugAdapterEnabled") as? Bool ?? true
        debugAdapterPort = d.integer(forKey: "debugAdapterPort") == 0 ? Int(DAPServer.defaultPort) : d.integer(forKey: "debugAdapterPort")
        romPath = d.string(forKey: "romPath")
        model = d.string(forKey: "model").flatMap(MachineModel.init(rawValue:)) ?? .a3000
        recentDiscs = d.stringArray(forKey: "recentDiscs") ?? []
        secondaryClick = d.string(forKey: "secondaryClick").flatMap(SecondaryClick.init(rawValue:)) ?? .adjust
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
    }

    /// Adds a ROM to the library if it loads; returns its version.
    @discardableResult
    func addROM(_ path: String, save: Bool = true) -> String? {
        if let e = romLibrary.first(where: { $0.path == path }) { return e.version }
        guard let rom = try? ROMImage.load(paths: [path]) else { return nil }
        romLibrary.append(ROMEntry(path: path, version: rom.versionString))
        romLibrary.sort { $0.version < $1.version }
        if save { d.set(romLibrary.map(\.path), forKey: "romLibrary") }
        return rom.versionString
    }

    func removeROM(_ path: String) {
        romLibrary.removeAll { $0.path == path }
        d.set(romLibrary.map(\.path), forKey: "romLibrary")
    }

    nonisolated static var supportDirectory: String {
        if isSelfTest { return (NSTemporaryDirectory() as NSString).appendingPathComponent("MacArch-selftest") }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path
        return (base as NSString).appendingPathComponent("MacArch")
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
