import Foundation
import XCTest
@testable import ArchimedesCore

final class ROMImporterTests: XCTestCase {
    /// A stand-in OS image: the reset branch, a version string, filler.
    static func fakeROM(_ version: String = "RISC OS 9.99 (01 Jan 2000)", size: Int = 512 << 10) -> [UInt8] {
        var d = (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 13) }
        d.replaceSubrange(0..<4, with: [0x10, 0x00, 0x00, 0xEA])  // B &48
        let v = Array(version.utf8) + [0]
        d.replaceSubrange(0x400..<(0x400 + v.count), with: v)
        return d
    }

    /// Splits an image into byte-wide (4) or halfword-wide (2) chips.
    static func chips(_ d: [UInt8], count: Int) -> [[UInt8]] {
        let width = 4 / count
        return (0..<count).map { c in
            stride(from: 0, to: d.count, by: 4).flatMap { i in d[(i + c * width)..<(i + c * width + width)] }
        }
    }

    func testSingleImageAndChipSetsInAnyOrder() throws {
        let rom = Self.fakeROM()
        let four = Self.chips(rom, count: 4), two = Self.chips(Self.fakeROM("Arthur 1.20 (25 Sep 1987)"), count: 2)
        // Names that sort into the wrong order: the version string sorts it out.
        let entries = [
            ROMImporter.Entry(name: "whole.rom", folder: "a", data: rom),
            ROMImporter.Entry(name: "x0", folder: "b", data: four[2]),
            ROMImporter.Entry(name: "x1", folder: "b", data: four[0]),
            ROMImporter.Entry(name: "x2", folder: "b", data: four[3]),
            ROMImporter.Entry(name: "x3", folder: "b", data: four[1]),
            ROMImporter.Entry(name: "hi", folder: "c", data: two[1]),
            ROMImporter.Entry(name: "lo", folder: "c", data: two[0]),
            ROMImporter.Entry(name: "readme.txt", folder: "c", data: Array("hello".utf8)),
        ]
        let r = ROMImporter.scan(entries)
        XCTAssertEqual(r.found.count, 2, "the whole image and the 4-chip set are the same ROM")
        XCTAssertEqual(Set(r.found.map(\.rom.versionString)), ["RISC OS 9.99 (01 Jan 2000)", "Arthur 1.20 (25 Sep 1987)"])
        XCTAssertEqual(r.found.first { $0.rom.versionString.hasPrefix("RISC") }?.rom.data, rom)
        XCTAssertEqual(r.found.first { $0.rom.versionString.hasPrefix("Arthur") }?.rom.data, Self.fakeROM("Arthur 1.20 (25 Sep 1987)"))
        XCTAssertTrue(r.rejected.isEmpty, "\(r.rejected)")
        XCTAssertNil(r.found[0].known)
    }

    /// Dumps split into consecutive slices (both of the user's are): name
    /// order works; a set whose order can't be told is turned away.
    func testConsecutiveSlices() {
        let rom = Self.fakeROM()
        let slices = (0..<4).map { Array(rom[($0 * 128 << 10)..<(($0 + 1) * 128 << 10)]) }
        let inOrder = ROMImporter.scan((0..<4).map { .init(name: "IC2\($0 + 4)", folder: "f", data: slices[$0]) })
        XCTAssertEqual(inOrder.found.first?.rom.data, rom)
        let reversed = ROMImporter.scan((0..<4).map { .init(name: "IC2\(7 - $0)", folder: "f", data: slices[$0]) })
        XCTAssertTrue(reversed.found.isEmpty)
        XCTAssertTrue(reversed.rejected.first?.reason.contains("order can't be told") == true, "\(reversed.rejected)")
    }

    func testRejectionsSayWhy() {
        let four = Self.chips(Self.fakeROM(), count: 4)
        let noise = [UInt8](repeating: 0x5A, count: 512 << 10)
        let r = ROMImporter.scan([
            .init(name: "IC24", folder: "f", data: four[0]),
            .init(name: "garbage.bin", folder: "g", data: noise),
            .init(name: "odd.bin", folder: "g", data: [UInt8](repeating: 1, count: 300 << 10)),
        ])
        XCTAssertTrue(r.found.isEmpty)
        let why = Dictionary(uniqueKeysWithValues: r.rejected.map { ($0.name, $0.reason) })
        XCTAssertTrue(why["IC24"]?.contains("add the others") == true, why["IC24"] ?? "")
        XCTAssertTrue(why["garbage.bin"]?.contains("no RISC OS") == true, why["garbage.bin"] ?? "")
        XCTAssertTrue(why["odd.bin"]?.contains("not a RISC OS ROM size") == true, why["odd.bin"] ?? "")
    }

    func testZipOfChipsAndInstall() throws {
        let four = Self.chips(Self.fakeROM(), count: 4)
        let zip = HardDiscBuilderTests.zip((0..<4).map { ("riscos/IC2\($0 + 4).ROM", four[$0], $0 % 2 == 0, nil) })
        let dir = NSTemporaryDirectory() + "macarch-roms-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let zipPath = dir + "/set.zip"
        try Data(zip).write(to: URL(fileURLWithPath: zipPath))
        let r = ROMImporter.scan(urls: [URL(fileURLWithPath: zipPath)])
        XCTAssertEqual(r.found.count, 1)
        XCTAssertEqual(r.found.first?.origin, "set.zip: riscos/IC24.ROM – IC27.ROM")

        let lib = dir + "/ROMs"
        let path = try ROMImporter.install(r.found[0].rom, into: lib)
        XCTAssertEqual((path as NSString).lastPathComponent, "RISC OS 9.99 (01 Jan 2000).rom")
        XCTAssertEqual(try ROMImporter.install(r.found[0].rom, into: lib), path, "installing again finds the copy")
        XCTAssertEqual(try ROMImage.load(paths: [path]).sha256, r.found[0].rom.sha256, "the installed image loads as a single file")
    }

    func testModels() {
        let ro2 = ROMImage(data: [], sha256: "", versionString: "RISC OS 2.00 (05 Oct 1988)", sources: [], layoutNote: "")
        let ro3 = ROMImage(data: [], sha256: "", versionString: "RISC OS 3.11 (29 Sep 1992)", sources: [], layoutNote: "")
        XCTAssertFalse(ROMImporter.models(for: ro2).contains(.a5000))
        XCTAssertTrue(ROMImporter.models(for: ro2).contains(.a3000))
        XCTAssertEqual(ROMImporter.models(for: ro3), MachineModel.allCases)
    }

    /// The user's chip sets are recognised as the known-good dumps.
    func testRealChipSetsAreKnown() throws {
        let roms = GameSmokeTests.root.appendingPathComponent("roms")
        guard FileManager.default.fileExists(atPath: roms.path) else { throw XCTSkip("no ./roms") }
        let r = ROMImporter.scan(urls: [roms])
        XCTAssertFalse(r.found.isEmpty)
        for f in r.found { XCTAssertNotNil(f.known, "\(f.rom.versionString) from \(f.origin)") }
    }
}
