import AppKit
import ArchimedesCore
import Foundation
import Observation

/// Adding ROMs: files, folders or ZIP archives are scanned for RISC OS
/// ROMs (`ROMImporter`), and each one found is copied, as a single image,
/// into Application Support/MacArch/ROMs and added to the ROM list. The
/// welcome screen and the ROMs window share it.
@MainActor
@Observable
final class ROMLibrary {
    static let shared = ROMLibrary()

    /// One ROM from the last thing added.
    struct Outcome: Identifiable {
        var found: ROMImporter.Found
        var path: String
        /// Already in the library before this drop.
        var alreadyHad: Bool
        var id: String { found.id }
    }

    /// What a ROM in the list is.
    struct Detail {
        var version: String
        var known: ROMImporter.Known?
        var sizeKB: Int
        var models: [MachineModel]
        /// A copy MacArch keeps (rather than a file elsewhere it points at).
        var isCopy: Bool
    }

    private(set) var outcomes: [Outcome] = []
    private(set) var rejected: [ROMImporter.Rejected] = []
    private(set) var scanning = false
    /// Bumped on every finished scan (for animations).
    private(set) var scans = 0
    // Caches, filled while views draw: not observed.
    @ObservationIgnored private var details: [String: Detail] = [:]

    nonisolated static var directory: String { (AppSettings.supportDirectory as NSString).appendingPathComponent("ROMs") }

    private init() {
        // Self-tests start from nothing, like their settings.
        if AppSettings.isSelfTest { try? FileManager.default.removeItem(atPath: Self.directory) }
    }

    /// Scans `urls`, installs what it finds and adds it to the list. The
    /// first RISC OS 3 found becomes the default if there was none.
    @discardableResult
    func add(_ urls: [URL]) async -> [Outcome] {
        guard !urls.isEmpty else { return [] }
        scanning = true
        defer { scanning = false; scans += 1 }
        let result = await Task.detached(priority: .userInitiated) { ROMImporter.scan(urls: urls) }.value
        let settings = AppSettings.shared
        var outcomes: [Outcome] = []
        var problems = result.rejected
        for f in result.found {
            let had = settings.romLibrary.contains { sha(of: $0.path) == f.rom.sha256 }
            do {
                let path = try ROMImporter.install(f.rom, into: Self.directory)
                // The same ROM listed from a file elsewhere gives way to the copy.
                for other in settings.romLibrary where other.path != path && sha(of: other.path) == f.rom.sha256 {
                    if settings.romPath == other.path { settings.romPath = path }
                    settings.removeROM(other.path)
                }
                settings.addROM(path)
                outcomes.append(Outcome(found: f, path: path, alreadyHad: had))
            } catch {
                problems.append(.init(name: f.origin, reason: "couldn't be copied into MacArch's ROM folder: \(error.localizedDescription)"))
            }
        }
        if settings.romPath == nil || !FileManager.default.fileExists(atPath: settings.romPath!) {
            settings.romPath = Self.preferred(outcomes.map { ($0.path, $0.found.rom.versionString) })
        }
        self.outcomes = outcomes
        self.rejected = problems
        return outcomes
    }

    /// RISC OS 3 before 2 before Arthur; the newest of each.
    static func preferred(_ roms: [(path: String, version: String)]) -> String? {
        roms.max { $0.version.localizedStandardCompare($1.version) == .orderedAscending }?.path
    }

    /// Asks for files, folders or archives, then adds them.
    func chooseAndAdd() async {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowsMultipleSelection = true
        p.prompt = "Add"
        p.message = "Choose RISC OS ROM images, chip files (such as IC24–IC27), folders of them, or ZIP archives"
        guard p.runModal() == .OK else { return }
        await add(p.urls)
    }

    func clearResults() { outcomes = []; rejected = [] }

    func detail(for path: String) -> Detail? {
        if let d = details[path] { return d }
        guard let rom = try? ROMImage.load(paths: [path]) else { return nil }
        let d = Detail(version: rom.versionString, known: ROMImporter.known[rom.sha256], sizeKB: rom.data.count / 1024,
                       models: ROMImporter.models(for: rom), isCopy: path.hasPrefix(Self.directory))
        details[path] = d
        shas[path] = rom.sha256
        return d
    }

    @ObservationIgnored private var shas: [String: String] = [:]
    private func sha(of path: String) -> String? {
        if shas[path] == nil { _ = detail(for: path) }
        return shas[path]
    }

    /// Takes a ROM off the list; MacArch's own copy is moved to the Trash.
    func remove(_ path: String) {
        let settings = AppSettings.shared
        if let sha = sha(of: path), ROMImporter.known[sha]?.title.hasPrefix("ArcLibre") == true { settings.declineBundledROM(sha256: sha) }
        settings.removeROM(path)
        if path.hasPrefix(Self.directory) { try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) }
        details[path] = nil
        if settings.romPath == path { settings.romPath = Self.preferred(settings.romLibrary.map { ($0.path, $0.version) }) }
        outcomes.removeAll { $0.path == path }
    }
}
