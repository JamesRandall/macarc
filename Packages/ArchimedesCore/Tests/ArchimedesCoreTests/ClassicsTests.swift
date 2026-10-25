import Foundation
import XCTest
@testable import ArchimedesCore

/// The Archimedes Classics catalogue (Apps/MacArch/Resources/Classics):
/// its invariants, and the launcher's prompt reading.
final class ClassicsTests: XCTestCase {
    static let root = GameSmokeTests.root
    static let catalogueURL = root.appendingPathComponent("Apps/MacArch/Resources/Classics/classics.json")

    static func catalogue() throws -> ClassicsCatalogue {
        try ClassicsCatalogue(data: Data(contentsOf: catalogueURL))
    }

    func testTheCatalogueIsATop25() throws {
        let c = try Self.catalogue()
        XCTAssertEqual(c.games.map(\.rank), Array(1...25))
        XCTAssertEqual(Set(c.games.map(\.id)).count, 25, "IDs are distinct")
        XCTAssertEqual(c.games.first?.title, "Star Fighter 3000")
    }

    func testEveryDiscIsKnownOnceAndComesFromTheArchive() throws {
        let c = try Self.catalogue()
        let digests = c.games.flatMap { $0.discs.map(\.sha256) }
        XCTAssertEqual(Set(digests).count, digests.count, "no disc belongs to two games")
        for game in c.games {
            XCTAssertFalse(game.discs.isEmpty, game.id)
            XCTAssertTrue(game.archivePageURL.absoluteString.hasPrefix("https://arcarc.top/archive/Games/"), game.id)
            for disc in game.discs {
                XCTAssertEqual(disc.sha256.count, 64, "\(game.id): \(disc.fileName)")
                XCTAssertTrue(disc.url.absoluteString.hasPrefix(game.archivePageURL.absoluteString), "\(game.id): \(disc.fileName) is in the game's folder")
                XCTAssertEqual(disc.url.lastPathComponent, disc.fileName)
                XCTAssertEqual(c.disc(forDigest: disc.sha256.uppercased())?.game.id, game.id)
            }
            XCTAssertTrue(game.machine.model.ramChoices.contains(game.machine.ramKB), "\(game.id): \(game.machine.ramKB)K")
            if game.discs.contains(where: { $0.kind == .hardDiscArchive }) {
                XCTAssertTrue(game.machine.model.hasIDE, "\(game.id) needs a hard disc interface")
            }
        }
    }

    func testCovers() throws {
        let c = try Self.catalogue()
        let covers = Self.root.appendingPathComponent("Apps/MacArch/Resources/Covers")
        let missing = c.games.filter { !FileManager.default.fileExists(atPath: covers.appendingPathComponent("\($0.id).jpg").path) }
        // Two have no box art yet: they get a typographic cover.
        XCTAssertEqual(Set(missing.map(\.id)), ["starfighter3000", "bughunter"])
    }

    func testCommandLines() throws {
        let c = try Self.catalogue()
        XCTAssertEqual(c.game(id: "zarch")?.commandLine, "Filer_Run ADFS::0.$.!Zarch\n\n")
        XCTAssertEqual(c.game(id: "elite")?.commandLine, "Filer_OpenDir ADFS::0.$\nFiler_Run ADFS::0.$.!#lite\n\n")
        // Several discs: run by name, so <Obey$Dir> stays with disc 1.
        XCTAssertEqual(c.game(id: "nevryon")?.commandLine, "Filer_Run ADFS::WILDPARTY.$.!Nevryon\n\n")
        XCTAssertEqual(c.game(id: "lemmings")?.commandLine, "Filer_Run ADFS::4.$.!Lemmings\n\n")
    }

    func testPromptsForDiscs() throws {
        let c = try Self.catalogue()
        let stunt = try XCTUnwrap(c.game(id: "stuntracer2000")).floppies
        XCTAssertEqual(ClassicLauncher.requestedDisc(in: "Loading... Please insert Disk Two and click", discs: stunt), 1)
        XCTAssertEqual(ClassicLauncher.requestedDisc(in: "Please insert disc 2", discs: stunt), 1)
        XCTAssertNil(ClassicLauncher.requestedDisc(in: "Please insert disc 3", discs: stunt), "there's no disc 3")
        let apocalypse = try XCTUnwrap(c.game(id: "apocalypse")).floppies
        XCTAssertEqual(ClassicLauncher.requestedDisc(in: "Please insert disc 'Planets'", discs: apocalypse), 1)
        XCTAssertEqual(ClassicLauncher.requestedDisc(in: "Please insert disc :Apocalypse", discs: apocalypse), 0)
        XCTAssertNil(ClassicLauncher.requestedDisc(in: "Insert coin", discs: apocalypse))
    }
}

/// Boots each Classic from its discs, as the app plays it: a CMOS reset,
/// the game's machine, its launcher (the desktop, then its start command
/// typed, then disc swaps). Opt-in, with folders of the archive's discs:
///     MACARCH_CLASSICS_DISCS=top25:more swift test -c release -Xswiftc -enable-testing --filter ClassicsDiscTests
/// MACARCH_CLASSICS_ONLY=zarch,elite picks games. Screenshots and a
/// summary go to tests/reports/classics/.
final class ClassicsDiscTests: XCTestCase {
    static let reports = ClassicsTests.root.appendingPathComponent("tests/reports/classics")

    /// Every file in the folders, by SHA-256.
    static func discs(in folders: [String]) -> [String: URL] {
        var found: [String: URL] = [:]
        for folder in folders {
            let url = URL(fileURLWithPath: folder, relativeTo: ClassicsTests.root)
            let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for file in files {
                guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size < 8 << 20,
                      let data = try? Data(contentsOf: file) else { continue }
                found[SHA256.hex([UInt8](data))] = file
            }
        }
        return found
    }

    func testBootEveryClassic() throws {
        guard let folders = ProcessInfo.processInfo.environment["MACARCH_CLASSICS_DISCS"] else {
            throw XCTSkip("set MACARCH_CLASSICS_DISCS to folders of the Classics' discs")
        }
        let only = ProcessInfo.processInfo.environment["MACARCH_CLASSICS_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let seconds = Double(ProcessInfo.processInfo.environment["MACARCH_CLASSICS_SECONDS"] ?? "") ?? 100
        let catalogue = try ClassicsTests.catalogue()
        let files = Self.discs(in: folders.split(separator: ":").map(String.init))
        try FileManager.default.createDirectory(at: Self.reports, withIntermediateDirectories: true)
        var summary: [String] = []
        for game in catalogue.games where only?.contains(game.id) ?? true {
            let line = try boot(game, files: files, seconds: seconds)
            summary.append(line)
            print(line)
        }
        try (summary.joined(separator: "\n") + "\n").write(to: Self.reports.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
    }

    /// The ROM a game gets: the first of its RISC OS versions there's a ROM for.
    func rom(for game: ClassicGame) -> String? {
        if let forced = ProcessInfo.processInfo.environment["MACARCH_CLASSICS_ROM"] { return GameSmokeTests.romDir(forced) }
        for family in game.machine.roms {
            let profile = family == "RISC OS 2" ? "riscos2_00" : "riscos3_11"
            if let dir = GameSmokeTests.romDir(profile) { return dir }
        }
        return nil
    }

    func boot(_ game: ClassicGame, files: [String: URL], seconds: Double) throws -> String {
        let missing = game.discs.filter { files[$0.sha256] == nil }
        guard missing.isEmpty else { return "\(game.rank). \(game.id): SKIPPED, no " + missing.map(\.fileName).joined(separator: ", ") }
        guard let rom = rom(for: game) else { return "\(game.rank). \(game.id): SKIPPED, no ROM" }
        var c = MachineConfiguration(model: game.machine.model)
        c.ramKB = Int(ProcessInfo.processInfo.environment["MACARCH_CLASSICS_RAM"] ?? "") ?? game.machine.ramKB
        c.romPaths = [rom]
        c.powerOnKeys = [0x34]
        var temp: URL?
        if let archive = game.discs.first(where: { $0.kind == .hardDiscArchive }) {
            let hdf = FileManager.default.temporaryDirectory.appendingPathComponent("classic-\(game.id)-\(UUID().uuidString).hdf")
            let items = try ADFSHardDiscBuilder.items(fromZip: [UInt8](Data(contentsOf: files[archive.sha256]!)))
            try ADFSHardDiscBuilder.create(path: hdf.path, geometry: HardDiscGeometry(cylinders: 200, heads: 4, sectorsPerTrack: 17, sectorSize: 512),
                                           name: "HardDisc4", items: items)
            c.hardDiscs = [hdf.path]
            temp = hdf
        }
        defer { if let temp { try? FileManager.default.removeItem(at: temp) } }
        let m = try Machine(configuration: c)
        let floppies = try game.floppies.map { try FloppyImage.open(path: files[$0.sha256]!.path) }
        if let first = floppies.first { m.insertFloppy(first) }
        m.powerOn()
        let s = GameSmokeTests.Script(m, name: game.id)
        s.note("\(game.title): \(m.rom.versionString), \(game.machine.model.displayName) \(game.machine.ramKB)K; types \(game.commandLine.debugDescription)")
        let launcher = ClassicLauncher(game: game, floppies: floppies, machine: m)
        var desktop: VideoFrame?
        var events: [String] = []
        let deadline = m.seconds + seconds
        while m.seconds < deadline {
            m.run(seconds: 0.25)
            switch launcher.step(m) {
            case .started?:
                desktop = m.currentFrame
                events.append(String(format: "started at %.0f s", m.seconds))
                s.note("started")
            case .inserted(let i)?:
                events.append(String(format: "disc %d in at %.0f s", i + 1, m.seconds))
                s.note("inserted disc \(i + 1)")
            case .clickedIconBar?:
                events.append(String(format: "icon clicked at %.0f s", m.seconds))
                s.note("clicked the icon bar")
            case nil: break
            }
        }
        let dir = Self.reports
        let f = m.currentFrame
        try? PNGEncoder.encode(f, scaleX: f.scaleX, scaleY: f.scaleY).write(to: dir.appendingPathComponent("\(game.rank)-\(game.id).png"))
        let text = m.recentText
        s.note("text: " + String(text.suffix(600)).debugDescription)
        try? (s.log.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("\(game.rank)-\(game.id).log"), atomically: true, encoding: .utf8)
        let crashed = ["Internal error", "Abort on", "Undefined instruction", "not found", "Not enough memory"].first { text.contains($0) }
        let colours = Set(f.pixels).count
        var changed = 0
        if let d = desktop, d.width == f.width, d.height == f.height {
            changed = zip(d.pixels, f.pixels).reduce(0) { $0 + ($1.0 != $1.1 ? 1 : 0) } * 100 / max(1, f.pixels.count)
        } else if desktop != nil {
            changed = 100
        }
        let verdict = crashed.map { "PROBLEM (\($0))" } ?? (launcher.started && changed > 40 && colours > 6 ? "OK" : "CHECK")
        return "\(game.rank). \(game.id): \(verdict); \(changed)% changed from the desktop, \(colours) colours; " + events.joined(separator: ", ")
    }
}
