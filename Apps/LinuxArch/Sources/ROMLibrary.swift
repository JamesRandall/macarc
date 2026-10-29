import ArchimedesCore
import CGtk
import Foundation
import Observation

/// Adding ROMs: files, folders or ZIP archives are scanned for RISC OS
/// ROMs (`ROMImporter`), and each one found is copied, as a single image,
/// into the app's ROMs folder and added to the ROM list. (The Mac app's.)
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
        /// A copy LinuxArch keeps (rather than a file elsewhere it points at).
        var isCopy: Bool
    }

    private(set) var outcomes: [Outcome] = []
    private(set) var rejected: [ROMImporter.Rejected] = []
    private(set) var scanning = false
    // Caches, filled while views draw: not observed.
    @ObservationIgnored private var details: [String: Detail] = [:]

    nonisolated static var directory: String { (AppSettings.supportDirectory as NSString).appendingPathComponent("ROMs") }

    private init() {}

    /// Scans `urls`, installs what it finds and adds it to the list. The
    /// first RISC OS 3 found becomes the default if there was none.
    @discardableResult
    func add(_ urls: [URL]) async -> [Outcome] {
        guard !urls.isEmpty else { return [] }
        scanning = true
        defer { scanning = false }
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
                problems.append(.init(name: f.origin, reason: "couldn't be copied into LinuxArch's ROM folder: \(error.localizedDescription)"))
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

    /// Asks for ROM files or ZIP archives (folders can be dropped), then adds
    /// them, and says what was found.
    func chooseAndAdd(parent: Widget?) {
        FileDialogs.openMultiple(parent: parent, title: "Add RISC OS ROMs",
                                 filters: [.init(name: "ROM images and ZIP archives", suffixes: ["rom", "bin", "zip"])]) { urls in
            Task { @MainActor in
                await self.add(urls)
                self.report(parent: parent)
            }
        }
    }

    /// Says what the last scan found, and what it couldn't use.
    func report(parent: Widget?) {
        var lines = outcomes.map { o in
            "• " + o.found.rom.versionString + (o.alreadyHad ? " (already added)" : "")
        }
        lines += rejected.map { "• \($0.name) \($0.reason)" }
        if outcomes.isEmpty {
            Alerts.show("No RISC OS ROMs found", lines.isEmpty ? nil : lines.joined(separator: "\n"), parent: parent)
        } else {
            Alerts.show(outcomes.count == 1 ? "ROM added" : "ROMs added", lines.joined(separator: "\n"), parent: parent)
        }
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

    /// Takes a ROM off the list; LinuxArch's own copy is moved to the Trash.
    func remove(_ path: String) {
        let settings = AppSettings.shared
        // (ArcLibre, which LinuxArch adds by itself, stays off once taken off.)
        if let digest = sha(of: path),
           ROMImporter.known[digest]?.title.hasPrefix("ArcLibre") == true || detail(for: path)?.version.hasPrefix("ArcLibre") == true {
            settings.declineBundledROM(sha256: digest)
        }
        settings.removeROM(path)
        if path.hasPrefix(Self.directory) { moveToTrash(path) }
        details[path] = nil
        if settings.romPath == path { settings.romPath = Self.preferred(settings.romLibrary.map { ($0.path, $0.version) }) }
        outcomes.removeAll { $0.path == path }
    }
}

/// Moves a file to the desktop's Trash (or deletes it where there's none).
func moveToTrash(_ path: String) {
    let file = g_file_new_for_path(path)!
    defer { g_object_unref(file.raw) }
    if g_file_trash(file, nil, nil) == 0 {
        try? FileManager.default.removeItem(atPath: path)
    }
}
