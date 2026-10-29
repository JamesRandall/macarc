import ArchimedesCore
import ArchimedesEmbedding
import Foundation
import XCTest

/// The embedding facade natively. The same schedules run under WebAssembly
/// in web/tests/parity.mjs, and both check the results in
/// Tests/Fixtures/wasm-parity.json, so native and WASM are held to the
/// same numbers.
final class EmbeddedMachineTests: XCTestCase {
    static let fixturesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/wasm-parity.json")

    struct Fixtures: Codable {
        struct Synthetic: Codable {
            var source: String
            var romWords: [UInt32]
            var romBytes: Int
            var sliceTicks: Int
            var slices: Int
            var ticks: UInt64
            var pc: UInt32
            var ramSHA256: String
        }
        struct Checkpoint: Codable {
            var seconds: Int
            var frame: UInt64
            var checksum: String
        }
        struct Classic: Codable {
            var romSHA256: String
            var discSHA256: String
            var sliceTicks: Int
            var checkpoints: [Checkpoint]
        }
        var synthetic: Synthetic
        var zarch: Classic
    }

    static func fixtures() throws -> Fixtures {
        try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: fixturesURL))
    }

    /// A ROM of our own: jumps to its high-ROM address, then fills 64 KB of
    /// RAM with a recurrence for ever.
    static func syntheticROM(_ f: Fixtures.Synthetic) -> [UInt8] {
        var rom = [UInt8](repeating: 0, count: f.romBytes)
        for (i, w) in f.romWords.enumerated() {
            for b in 0..<4 { rom[i * 4 + b] = UInt8(truncatingIfNeeded: w >> UInt32(b * 8)) }
        }
        return rom
    }

    func testSyntheticROMAssemblesToFixture() throws {
        let f = try Self.fixtures().synthetic
        let a = try ARMAssembler.assemble(source: f.source)
        let words = stride(from: 0, to: a.bytes.count, by: 4).map {
            UInt32(a.bytes[$0]) | UInt32(a.bytes[$0 + 1]) << 8 | UInt32(a.bytes[$0 + 2]) << 16 | UInt32(a.bytes[$0 + 3]) << 24
        }
        XCTAssertEqual(words, f.romWords)
    }

    func testSyntheticRunMatchesFixture() throws {
        let f = try Self.fixtures().synthetic
        let m = try EmbeddedMachine(model: "A3000", cmosReset: false, rom: Self.syntheticROM(f))
        for _ in 0..<f.slices { try m.run(ticks: UInt64(f.sliceTicks)) }
        let ram = try m.readMemory(0x0200_0000, count: 65536, logical: true)
        print("synthetic: ticks \(m.ticks) pc \(String(m.cpuPC, radix: 16)) ram \(SHA256.hex(ram))")
        XCTAssertEqual(m.ticks, f.ticks)
        XCTAssertEqual(m.cpuPC, f.pc)
        XCTAssertEqual(SHA256.hex(ram), f.ramSHA256)
    }

    func testSnapshotRoundTripContinuesIdentically() throws {
        let f = try Self.fixtures().synthetic
        let rom = Self.syntheticROM(f)
        let a = try EmbeddedMachine(model: "A3000", cmosReset: false, rom: rom)
        try a.run(ticks: 1_000_000)
        let state = a.saveState()
        let b = try EmbeddedMachine(model: "A3000", cmosReset: false, rom: rom)
        try b.restoreState(state)
        XCTAssertEqual(a.ticks, b.ticks)
        try a.run(ticks: 500_000)
        try b.run(ticks: 500_000)
        XCTAssertEqual(a.ticks, b.ticks)
        XCTAssertEqual(try a.readMemory(0x0200_0000, count: 65536, logical: true), try b.readMemory(0x0200_0000, count: 65536, logical: true))
    }

    func testInvalidInputsFailCleanly() throws {
        let f = try Self.fixtures().synthetic
        let rom = Self.syntheticROM(f)
        XCTAssertThrowsError(try EmbeddedMachine(model: "BBC Micro", rom: rom))
        XCTAssertThrowsError(try EmbeddedMachine(model: "A3000", rom: [1, 2, 3]))
        XCTAssertThrowsError(try EmbeddedMachine(model: "A3000", ramKB: 3, rom: rom))
        let m = try EmbeddedMachine(model: "A3000", cmosReset: false, rom: rom)
        XCTAssertThrowsError(try m.insertFloppy([1, 2, 3]))
        XCTAssertThrowsError(try m.insertFloppy([UInt8](repeating: 0, count: 819_200), drive: 9))
        XCTAssertThrowsError(try m.key(0x200, down: true))
        XCTAssertThrowsError(try m.run(ticks: EmbeddedMachine.maxRunTicks + 1))
        XCTAssertThrowsError(try m.restoreState([0, 1, 2, 3]))
        XCTAssertThrowsError(try m.restoreState(Array(m.saveState().prefix(100))))
        XCTAssertThrowsError(try m.readMemory(0, count: 2 << 20, logical: false))
        XCTAssertThrowsError(try m.startClassic(gameJSON: Array("{}".utf8), discs: []))
        // Still works afterwards.
        try m.run(ticks: 24_000)
    }

    func testMachinesAreIndependent() throws {
        let f = try Self.fixtures().synthetic
        let rom = Self.syntheticROM(f)
        let a = try EmbeddedMachine(model: "A3000", cmosReset: false, rom: rom)
        let b = try EmbeddedMachine(model: "A5000", cmosReset: false, rom: rom)
        try a.run(ticks: 480_000)
        XCTAssertEqual(b.ticks, 0)
        try b.run(ticks: 480_000)
        XCTAssertGreaterThan(a.ticks, 0)
    }

    // MARK: Licensed local fixtures (skipped when absent)

    static let romPath = ProcessInfo.processInfo.environment["MACARCH_TEST_ROM"]
        ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../roms/arclibre.rom").standardized.path
    static let zarchPath = ProcessInfo.processInfo.environment["MACARCH_TEST_ZARCH"]
        ?? NSString(string: "~/code/macarc/top25/Zarch (1987)(Superior Software).adf").expandingTildeInPath
    static let cataloguePath = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../Apps/MacArch/Resources/Classics/classics.json").standardized.path

    func testZarchLaunchMatchesFixture() throws {
        guard let rom = FileManager.default.contents(atPath: Self.romPath),
              let disc = FileManager.default.contents(atPath: Self.zarchPath),
              let catalogue = FileManager.default.contents(atPath: Self.cataloguePath) else {
            throw XCTSkip("needs a RISC OS ROM, the Zarch disc and classics.json")
        }
        let f = try Self.fixtures().zarch
        XCTAssertEqual(SHA256.hex([UInt8](rom)), f.romSHA256)
        XCTAssertEqual(SHA256.hex([UInt8](disc)), f.discSHA256)
        let json = try JSONSerialization.jsonObject(with: catalogue) as! [String: Any]
        let game = (json["games"] as! [[String: Any]]).first { $0["id"] as? String == "zarch" }!
        let m = try EmbeddedMachine(model: "A3000", rom: [UInt8](rom))
        try m.startClassic(gameJSON: [UInt8](try JSONSerialization.data(withJSONObject: game)), discs: [[UInt8](disc)])
        var second = 0
        for c in f.checkpoints {
            while second < c.seconds {
                for _ in 0..<(EmbeddedMachine.ticksPerSecond / f.sliceTicks) { try m.run(ticks: UInt64(f.sliceTicks)) }
                second += 1
            }
            let hex = String(m.frameChecksum, radix: 16, uppercase: true)
            let sum = String(repeating: "0", count: 16 - hex.count) + hex
            print("zarch: \(c.seconds) s frame \(m.frameCount) \(sum)")
            XCTAssertEqual(m.frameCount, c.frame, "frame at \(c.seconds) s")
            XCTAssertEqual(sum, c.checksum, "checksum at \(c.seconds) s")
        }
        XCTAssertTrue(m.classicStarted)
    }

    /// The bundled ArcLibre 4 MB ROM, which the browser runs on an A5000.
    static let arcLibre4MBPath: String? = {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../Apps/MacArch/Resources/ArcLibre").standardized
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.first { $0.hasSuffix("-4mb.rom") }.map { dir.appendingPathComponent($0).path }
    }()

    /// Following the host's pointer: RISC OS's goes where it's sent, and
    /// stays inside the display area.
    func testFollowPointerSteersRISCOSPointer() throws {
        guard let path = Self.arcLibre4MBPath, let rom = FileManager.default.contents(atPath: path) else {
            throw XCTSkip("needs ArcLibre's 4 MB ROM in Apps/MacArch/Resources/ArcLibre")
        }
        let m = try EmbeddedMachine(model: "A5000", ramKB: 4096, rom: [UInt8](rom))
        let second = UInt64(EmbeddedMachine.ticksPerSecond)
        for _ in 0..<25 { try m.run(ticks: second) }
        XCTAssertTrue(m.machine.vidc.pointerShown, "the desktop's pointer is on")
        guard let d = m.machine.vidc.lastFrame.displayArea else { return XCTFail("no display area") }
        let spots = [(d.x + 20, d.y + 20), (d.x + d.width - 30, d.y + d.height - 30), (d.x + d.width / 2, d.y + d.height / 2),
                     (d.x + d.width / 2 + 3, d.y + d.height / 2 - 2)]
        for (x, y) in spots {
            XCTAssertTrue(m.followPointer(to: (x, y)), "\(x), \(y) is in the display area")
            try m.run(ticks: second / 2)
            let p = m.machine.vidc.pointerHotspot
            XCTAssertLessThanOrEqual(abs(p.x - x), 1, "sent to \(x), \(y); it's at \(p.x), \(p.y)")
            XCTAssertLessThanOrEqual(abs(p.y - y), 1, "sent to \(x), \(y); it's at \(p.x), \(p.y)")
        }
        // In the border, it waits at the edge.
        XCTAssertFalse(m.followPointer(to: (d.x - 10, d.y + 40)), "the border isn't the display area")
        try m.run(ticks: second / 2)
        let p = m.machine.vidc.pointerHotspot
        XCTAssertLessThanOrEqual(abs(p.x - d.x), 1, "held at the left edge; it's at \(p.x)")
        // Snapshots keep following.
        let state = m.saveState()
        try m.restoreState(state)
        m.followPointer(to: (d.x + 60, d.y + 60))
        try m.run(ticks: second / 2)
        let q = m.machine.vidc.pointerHotspot
        XCTAssertLessThanOrEqual(abs(q.x - (d.x + 60)), 1, "after a restore; it's at \(q.x), \(q.y)")
        XCTAssertLessThanOrEqual(abs(q.y - (d.y + 60)), 1, "after a restore; it's at \(q.x), \(q.y)")
        m.followPointer(to: nil)
    }
}
