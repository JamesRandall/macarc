import XCTest
@testable import ArchimedesCore

/// ArcLibre, the free ROM MacArch ships so that it works without one of
/// Acorn's: it's recognised for what it is, and it starts the desktop.
final class ArcLibreTests: XCTestCase {
    static let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../Apps/MacArch/Resources/ArcLibre/ArcLibre.rom").standardized.path

    func testItIsRecognised() throws {
        let rom = try ROMImage.load(paths: [Self.path])
        XCTAssertTrue(rom.versionString.hasPrefix("ArcLibre 0."), rom.versionString)
        XCTAssertNotNil(ROMImporter.known[rom.sha256], "the bundled ArcLibre is a known ROM")
        XCTAssertTrue(ROMImporter.hasVersion(rom))
        XCTAssertNotNil(ROMImporter.recognise([rom.data], sources: [Self.path]), "it can be added as a ROM file")
        let models = ROMImporter.models(for: rom)
        XCTAssertTrue(models.contains(.a3000) && models.contains(.a440))
        XCTAssertFalse(models.contains(.a5000), "it has no drivers for the A5000 family")
    }

    func testItStartsTheDesktop() throws {
        for (model, cpu) in [(MachineModel.a3000, CPUType.arm2), (.a440, .arm2), (.a310, .arm3)] {
            var c = MachineConfiguration(model: model)
            c.romPaths = [Self.path]
            c.cpu = cpu
            c.powerOnKeys = [0x34] // Delete: CMOS defaults, as the app does on a first boot
            let m = try Machine(configuration: c)
            m.powerOn()
            var seconds = 0.0
            while seconds < 120 && !(Self.desktopIsUp(m) && m.vidc.pointerShown) { m.run(seconds: 1); seconds += 1 }
            XCTAssertTrue(Self.desktopIsUp(m) && m.vidc.pointerShown, "\(model.rawValue) \(cpu): no desktop after \(seconds) s")
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
