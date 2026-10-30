import XCTest
@testable import ArchimedesCore

/// ArcLibre, the free ROM MacArch ships so that it works without one of
/// Acorn's, in its 2 MB and 4 MB forms: each is recognised for what it is,
/// offered for the machines it suits, and starts the desktop on them.
final class ArcLibreTests: XCTestCase {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../Apps/MacArch/Resources/ArcLibre").standardized
    static let path = folder.appendingPathComponent("arclibre-0.9.1-2mb.rom").path
    static let fourMegabytePath = folder.appendingPathComponent("arclibre-0.9.1-4mb.rom").path

    func testTheyAreRecognised() throws {
        for (path, size) in [(Self.path, 2 << 20), (Self.fourMegabytePath, 4 << 20)] {
            let rom = try ROMImage.load(paths: [path])
            XCTAssertTrue(rom.versionString.hasPrefix("ArcLibre 0.91"), rom.versionString)
            XCTAssertEqual(rom.data.count, size)
            XCTAssertEqual(ROMImporter.known[rom.sha256]?.title, "ArcLibre 0.9.1", "the bundled ArcLibre is a known ROM")
            XCTAssertTrue(ROMImporter.hasVersion(rom))
            XCTAssertNotNil(ROMImporter.recognise([rom.data], sources: [path]), "it can be added as a ROM file")
        }
    }

    /// The 2 MB ROM drives every model; the 4 MB one only the A5000 family,
    /// whose sockets take it; 0.8 had no drivers for that family.
    func testTheModelsTheySuit() throws {
        XCTAssertEqual(ROMImporter.models(for: try ROMImage.load(paths: [Self.path])), MachineModel.allCases)
        XCTAssertEqual(ROMImporter.models(for: try ROMImage.load(paths: [Self.fourMegabytePath])), MachineModel.allCases.filter(\.hasNewIO))
        let old = ROMImporter.models(version: "ArcLibre 0.80 (28 Oct 2026)", size: 2 << 20)
        XCTAssertEqual(old, MachineModel.allCases.filter { !$0.hasNewIO })
        XCTAssertNotNil(ROMImporter.whyNot(version: "ArcLibre 0.90 (29 Oct 2026)", size: 4 << 20, on: .a3000))
    }

    func testTheyStartTheDesktop() throws {
        let runs: [(String, MachineModel, CPUType)] = [
            (Self.path, .a3000, .arm2), (Self.path, .a440, .arm2), (Self.path, .a310, .arm3), (Self.path, .a5000, .arm3),
            (Self.fourMegabytePath, .a5000, .arm3), (Self.fourMegabytePath, .a3010, .arm250),
        ]
        for (path, model, cpu) in runs {
            var c = MachineConfiguration(model: model)
            c.romPaths = [path]
            c.cpu = cpu
            c.powerOnKeys = [0x34] // Delete: CMOS defaults, as the app does on a first boot
            let m = try Machine(configuration: c)
            m.powerOn()
            var seconds = 0.0
            while seconds < 120 && !(Self.desktopIsUp(m) && m.vidc.pointerShown) { m.run(seconds: 1); seconds += 1 }
            XCTAssertTrue(Self.desktopIsUp(m) && m.vidc.pointerShown,
                          "\((path as NSString).lastPathComponent) on the \(model.rawValue) \(cpu): no desktop after \(seconds) s")
        }
    }

    /// Whether the desktop is up: the icon bar is there, and the left half
    /// of the display's middle rows (clear of the pointer, which starts in
    /// the middle) is all background, with the start-up splash gone.
    static func desktopIsUp(_ m: Machine) -> Bool {
        let f = m.currentFrame
        guard m.vidc.bitsPerPixel == 4, let d = f.displayArea else { return false }
        let first = f.pixels[d.y * f.width + d.x]
        // The icon bar along the bottom...
        let bar = (d.y + d.height - 8) * f.width + d.x
        guard f.pixels[bar..<(bar + d.width)].filter({ $0 != first }).count > d.width * 3 / 4 else { return false }
        // ...and no splash in the middle.
        return stride(from: d.y + d.height / 3, to: d.y + d.height * 2 / 3, by: 4).allSatisfy { y in
            f.pixels[(y * f.width + d.x)..<(y * f.width + d.x + d.width / 2 - 16)].allSatisfy { $0 == first }
        }
    }
}

/// 4 MB ROMs: MEMC's high ROM space is 8 MB and the sockets are wired for
/// 4 MB, so a ROM that size is all there at &3800000, and mirrored once.
final class FourMegabyteROMTests: XCTestCase {
    func testTheWholeROMIsMapped() throws {
        var image = (0..<(4 << 20)).map { UInt8(truncatingIfNeeded: $0 >> 12) }
        image.replaceSubrange(0..<4, with: [0x10, 0x00, 0x00, 0xEA])
        let memc = MEMC(ramSize: 1 << 20, rom: image)
        XCTAssertEqual(memc.romSize, 4 << 20)
        for offset in [0, 0x1F_F000, 0x20_0000, 0x3F_F000] {
            let expected = memc.romWord(UInt32(offset))
            XCTAssertEqual(UInt8(truncatingIfNeeded: expected >> 8), UInt8(truncatingIfNeeded: offset >> 12), "&\(String(offset, radix: 16)) is its own")
            XCTAssertEqual(memc.romWord(UInt32(0x0380_0000 + offset)), expected)
            XCTAssertEqual(memc.romWord(UInt32(0x03C0_0000 + offset)), expected, "mirrored above &3C00000")
        }
    }

    /// RISC OS 3.11 and ArcLibre each start the desktop from a 4 MB ROM
    /// with something after them, from a CMOS reset. (3.11's self-test takes
    /// half a minute longer then, so Delete is held through it.)
    func testOperatingSystemsStartFromFourMegabytes() throws {
        var roms = [ArcLibreTests.path]
        if let dir = GameSmokeTests.romDir("riscos3_11") { roms.append(dir) }
        for path in roms {
            let base = try ROMImage.load(paths: [path])
            // Something after it, as an extension ROM would be.
            let padded = base.data + (0..<(4 << 20) - base.data.count).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 13) }
            let file = NSTemporaryDirectory() + "macarch-4mb-\(UUID().uuidString).rom"
            defer { try? FileManager.default.removeItem(atPath: file) }
            try Data(padded).write(to: URL(fileURLWithPath: file))
            XCTAssertNotNil(ROMImporter.recognise([padded], sources: [file]), "\(base.versionString) at 4 MB is a ROM")
            var c = MachineConfiguration(model: .a3000)
            c.romPaths = [file]
            c.powerOnKeys = [0x34]
            let m = try Machine(configuration: c)
            XCTAssertEqual(m.memc.romSize, 4 << 20)
            m.powerOn()
            var seconds = 0.0
            while seconds < 120 && !(ArcLibreTests.desktopIsUp(m) && m.vidc.pointerShown) { m.run(seconds: 1); seconds += 1 }
            XCTAssertTrue(ArcLibreTests.desktopIsUp(m), "\(base.versionString) from 4 MB: no desktop after \(seconds) s; \(m.screenText.filter { !$0.isEmpty }.prefix(6))")
        }
    }
}
