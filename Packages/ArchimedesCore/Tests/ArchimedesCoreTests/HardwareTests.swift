import Foundation
import XCTest
@testable import ArchimedesCore

/// Builds a machine around a tiny synthetic "ROM" (a branch-to-self), so
/// MEMC/IOC/VIDC can be exercised without a user-supplied RISC OS image.
func syntheticMachine(ramKB: Int = 2048) throws -> Machine {
    var rom = [UInt8](repeating: 0, count: 4096)
    // B . (0xEAFFFFFE) at the reset vector
    rom[0] = 0xFE; rom[1] = 0xFF; rom[2] = 0xFF; rom[3] = 0xEA
    let image = try ROMImage.build(parts: [rom], sources: ["synthetic"])
    var c = MachineConfiguration()
    c.ramKB = ramKB
    let m = try Machine(configuration: c, rom: image)
    m.powerOn()
    return m
}

final class MEMCTests: XCTestCase {
    func testROMOverlayUntilA25Access() throws {
        let m = try syntheticMachine()
        XCTAssertTrue(m.memc.romOverlay)
        XCTAssertEqual(m.memc.readWord(0, sequential: false), 0xEAFF_FFFE)
        _ = m.memc.readWord(0x0380_0000, sequential: false)
        XCTAssertFalse(m.memc.romOverlay)
    }

    /// Regression: the CAM decodes A0/A1 of the write address, so a word
    /// store to an unaligned CAM address must reach MEMC unmasked
    /// (RISC OS 3.11 POST maps page &3F with STR to &380807D).
    func testUnalignedCAMWriteDecodesLowAddressBits() throws {
        let m = try syntheticMachine()
        _ = m.memc.readWord(0x0380_0000, sequential: false)
        m.memc.writeWord(0x036E_000C, 0, sequential: false) // control: 32 KB pages
        // Mark physical page 0x3F (32 KB pages) and map it to logical page 1.
        m.memc.writeWord(0x0200_0000 + 0x3F * 32768, 0xCAFE_F00D, sequential: false)
        let cpu = m.cpu
        cpu.r[0] = 0x0380_807D
        cpu.r[1] = 0
        // STR R1, [R0]
        m.memc.write(program: [0xE580_1000], at: 0x0200_8000)
        cpu.pc = 0x0200_8000
        m.step(1)
        XCTAssertEqual(m.memc.readWord(0x8000, sequential: false), 0xCAFE_F00D)
        XCTAssertFalse(m.memc.abort)
    }

    /// Regression: when two physical pages claim one logical page, the most
    /// recently written CAM entry wins (needed by the POST protection test).
    func testMostRecentCAMEntryWins() throws {
        let m = try syntheticMachine()
        _ = m.memc.readWord(0x0380_0000, sequential: false)
        m.memc.writeWord(0x036E_0000, 0, sequential: false) // 4 KB pages
        m.memc.writeWord(0x0200_0000 + 5 * 4096, 5, sequential: false)
        m.memc.writeWord(0x0200_0000 + 2 * 4096, 2, sequential: false)
        m.memc.writeWord(0x0380_0005, 0, sequential: false) // ppn 5 -> lpn 0
        m.memc.writeWord(0x0380_0002, 0, sequential: false) // ppn 2 -> lpn 0
        XCTAssertEqual(m.memc.readWord(0, sequential: false), 2)
        m.memc.writeWord(0x0380_0005 | 0x100, 0, sequential: false) // ppn 5 again, PPL 1
        XCTAssertEqual(m.memc.readWord(0, sequential: false), 5)
    }

    func testUserModeProtection() throws {
        let m = try syntheticMachine()
        _ = m.memc.readWord(0x0380_0000, sequential: false)
        m.memc.writeWord(0x036E_0000, 0, sequential: false)
        m.memc.writeWord(0x0380_0001 | (1 << 8), 0, sequential: false) // ppn 1 -> lpn 0, PPL 1
        m.memc.privileged = false
        _ = m.memc.readWord(0, sequential: false)
        XCTAssertFalse(m.memc.abort, "PPL 1 readable in user mode")
        m.memc.writeWord(0, 1, sequential: false)
        XCTAssertTrue(m.memc.abort, "PPL 1 not writable in user mode")
        m.memc.abort = false
        _ = m.memc.readWord(0x0200_0000, sequential: false)
        XCTAssertTrue(m.memc.abort, "physical RAM is supervisor only")
    }
}

final class IOCTests: XCTestCase {
    func testTimer0InterruptPeriod() throws {
        let m = try syntheticMachine()
        _ = m.memc.readWord(0x0380_0000, sequential: false)
        // Latch 19999 -> 20000 counts at 2 MHz = 10 ms.
        m.memc.writeByte(0x0320_0040, 0x1F)
        m.memc.writeByte(0x0320_0044, 0x4E)
        m.memc.writeByte(0x0320_0048, 0)
        let start = m.ticks
        m.memc.writeByte(0x0320_0014, 0x20)
        while m.ioc.irqAStatus & 0x20 == 0 { m.run(ticks: 240) }
        let elapsed = Double(m.ticks - start) / 24_000_000
        XCTAssertEqual(elapsed, 0.010, accuracy: 0.0002)
    }

    func testVsyncSetsIRQA() throws {
        let m = try syntheticMachine()
        m.run(seconds: 0.05)
        XCTAssertGreaterThan(m.ioc.irqCounts[3], 0)
        XCTAssertGreaterThan(m.vidc.frameCount, 0)
    }
}

final class VIDCTests: XCTestCase {
    /// Regression: video DMA cycle stealing must not stretch the raster line.
    /// Lemmings times its panel palette split with IOC timer 1 from vsync;
    /// 64 µs + DMA cost per line ran frames at 45.6 Hz and split 17 lines early.
    func testFrameRateUnaffectedByVideoDMA() throws {
        let m = try syntheticMachine()
        _ = m.memc.readWord(0x0380_0000, sequential: false)
        func vidc(_ reg: UInt32, _ v: UInt32) { m.memc.writeWord(0x0340_0000, reg << 24 | v, sequential: false) }
        // Mode 13-like: 512-pixel lines at 8 MHz (64 µs), 312 lines, 4 bpp.
        vidc(0x80, 255 << 14); vidc(0x84, 35 << 14); vidc(0x88, 40 << 14); vidc(0x8C, 60 << 14)
        vidc(0x90, 220 << 14); vidc(0x94, 240 << 14)
        vidc(0xA0, 311 << 14); vidc(0xA4, 2 << 14); vidc(0xA8, 21 << 14); vidc(0xAC, 37 << 14)
        vidc(0xB0, 293 << 14); vidc(0xB4, 309 << 14)
        vidc(0xE0, 0x08)
        m.memc.writeWord(0x036E_0000 | 1 << 10, 0, sequential: false) // video DMA on
        let start = m.vidc.frameCount
        m.run(seconds: 1)
        XCTAssertEqual(Double(m.vidc.frameCount - start), 1_000_000 / (64.0 * 312), accuracy: 1)
    }
}

final class FloppyTests: XCTestCase {
    #if !canImport(ObjectiveC)
    /// swift-corelibs-xctest (Linux) has no plain initialiser, and other
    /// tests make one of these for its helpers.
    convenience init() { self.init(name: "helper", testClosure: { _ in }) }
    #endif

    func syntheticDisc() -> FloppyImage {
        var data = [UInt8](repeating: 0, count: 819_200)
        for i in 0..<data.count { data[i] = UInt8(truncatingIfNeeded: i / 1024) }
        let g = DiscGeometry(sides: 2, tracks: 80, sectorsPerTrack: 5, sectorSize: 1024, firstSectorID: 0, formatName: "test")
        return FloppyImage(data: data, geometry: g)
    }

    func testReadSectorThroughController() throws {
        let m = try syntheticMachine()
        _ = m.memc.readWord(0x0380_0000, sequential: false)
        m.insertFloppy(syntheticDisc())
        m.memc.writeByte(0x0335_0040, 0xFE) // latch A: drive 0, side 0... (active low)
        m.memc.writeByte(0x0335_0018, 0xFD) // latch B: no reset, double density
        // Seek to track 3
        m.memc.writeByte(0x0331_000C, 3)
        m.memc.writeByte(0x0331_0000, 0x10)
        while m.fdc.status & 1 != 0 || m.fdc.command != .idle { m.run(ticks: 24_000) }
        XCTAssertEqual(m.fdc.drives[0].headTrack, 3)
        // Read sector 2 on track 3 side 1: image offset ((3*2+1)*5+2)*1024
        m.memc.writeByte(0x0335_0040, 0xEE) // side 1 (bit 4 low)
        m.memc.writeByte(0x0331_0008, 2)
        m.memc.writeByte(0x0331_0000, 0x88)
        var bytes: [UInt8] = []
        var guardTicks = 0
        while bytes.count < 1024 && guardTicks < 50_000 {
            m.run(ticks: 120)
            guardTicks += 1
            if m.ioc.fiqStatus & 1 != 0 { bytes.append(UInt8(m.memc.readByte(0x0331_000C))) }
        }
        XCTAssertEqual(bytes.count, 1024)
        XCTAssertEqual(bytes.first, UInt8(truncatingIfNeeded: (3 * 2 + 1) * 5 + 2))
        m.run(seconds: 0.01)
        XCTAssertEqual(m.ioc.fiqStatus & 2, 2, "INTRQ at end of command")
    }

    func testCopyOnWriteOverlay() {
        let d = syntheticDisc()
        let before = d.sha256
        d.writeSector(side: 0, track: 0, sectorID: 0, data: [UInt8](repeating: 0xAA, count: 1024))
        XCTAssertTrue(d.isModified)
        XCTAssertEqual(d.readSector(side: 0, track: 0, sectorID: 0)?.first, 0xAA)
        XCTAssertEqual(d.sha256, before, "base image hash unchanged")
        d.discardChanges()
        XCTAssertEqual(d.readSector(side: 0, track: 0, sectorID: 0)?.first, 0)
    }

    func testFormatDetection() {
        XCTAssertEqual(MediaDetector.detect([UInt8](repeating: 0, count: 819_200)).geometry?.sectorSize, 1024)
        XCTAssertNil(MediaDetector.detect([UInt8](repeating: 0, count: 1234)).geometry)
    }
}

final class ROMBootTests: XCTestCase {
    static var romDir: String? {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../roms/riscos3_11").standardized.path
        return FileManager.default.fileExists(atPath: root) ? root : nil
    }

    /// Boots the user-supplied RISC OS 3.11 ROM; skipped when absent.
    func testRISCOS311BootsDeterministically() throws {
        guard let dir = Self.romDir else { throw XCTSkip("RISC OS 3.11 ROM not present in ./roms/riscos3_11") }
        func boot() throws -> (UInt64, UInt64, Machine) {
            var c = MachineConfiguration()
            c.romPaths = [dir]
            c.powerOnKeys = [0x34]
            let m = try Machine(configuration: c)
            m.powerOn()
            m.run(seconds: 20)
            return (m.cpu.instructionCount, m.currentFrame.checksum, m)
        }
        let (i1, f1, m) = try boot()
        let (i2, f2, _) = try boot()
        XCTAssertEqual(i1, i2)
        XCTAssertEqual(f1, f2)
        XCTAssertTrue(m.recentText.contains("Acorn ADFS"), "banner printed: \(m.recentText)")
        XCTAssertEqual(m.cpu.exceptionCounts[5], 0, "no address exceptions")
    }
}

final class RISCOS2BootTests: XCTestCase {
    /// RISC OS 2.00, the spec's second ROM profile, reaches its desktop
    /// with no address exceptions; skipped without the ROM.
    func testRISCOS200Boots() throws {
        guard let dir = GameSmokeTests.romDir("riscos2_00") else { throw XCTSkip("RISC OS 2.00 ROM not present in ./roms/riscos2_00") }
        var c = MachineConfiguration()
        c.romPaths = [dir]
        c.powerOnKeys = [0x34]
        let m = try Machine(configuration: c)
        XCTAssertTrue(m.rom.versionString.hasPrefix("RISC OS 2.00"))
        m.powerOn()
        m.run(seconds: 15)
        XCTAssertTrue(m.recentText.contains("Acorn ADFS"), "banner printed: \(m.recentText)")
        XCTAssertTrue(m.recentText.contains(":0"), "desktop drive icon")
        XCTAssertEqual(m.cpu.exceptionCounts[5], 0, "no address exceptions")
    }
}

final class MemorySizeTests: XCTestCase {
    /// Every fitted RAM size passes the ROM's memory sizing and POST and is
    /// reported in the banner. Regression: 512 KB and 1 MB machines stopped
    /// on a red POST failure screen under RISC OS 3.11 when physical RAM
    /// simply wrapped instead of following MEMC's DRAM address multiplexing.
    func testEveryRAMSizeBootsOnEachROM() throws {
        var ran = 0
        for rom in ["riscos3_11", "riscos2_00"] {
            guard let dir = GameSmokeTests.romDir(rom) else { continue }
            for kb in [512, 1024, 2048, 4096] {
                var c = MachineConfiguration()
                c.romPaths = [dir]
                c.ramKB = kb
                c.powerOnKeys = [0x34]
                let m = try Machine(configuration: c)
                m.powerOn()
                m.run(seconds: 20)
                XCTAssertTrue(m.recentText.contains("RISC OS \(kb)K"), "\(rom) \(kb) KB banner: \(m.recentText.suffix(200))")
                ran += 1
            }
        }
        if ran == 0 { throw XCTSkip("no RISC OS ROMs in ./roms") }
    }

    /// With the page size that matches the fitted DRAM, physical addresses
    /// map straight through; with 32 KB pages on 1 MB, bit 13 (row 9) reaches
    /// no chip and bit 21 (column 3) lands on bit 13.
    func testDRAMMultiplexing() {
        let memc = MEMC(ramSize: 1 << 20, rom: [UInt8](repeating: 0, count: 4))
        memc.setPageSize(1)
        XCTAssertEqual(memc.physicalOffset(0x0201_2345), 0x1_2345)
        memc.setPageSize(3)
        XCTAssertEqual(memc.physicalOffset(0x0200_2000), 0)
        XCTAssertEqual(memc.physicalOffset(0x0220_0000), 0x2000)
        XCTAssertEqual(memc.physicalOffset(0x0200_1000), 0x1000)
    }
}

extension MEMC {
    /// Test helper: place instruction words in physical RAM (via 0x2000000).
    func write(program: [UInt32], at address: UInt32) {
        for (i, w) in program.enumerated() { writeWord(address + UInt32(i * 4), w, sequential: false) }
    }
}

final class AudioTests: XCTestCase {
    /// Regression: 1-channel RISC OS sound (48 µs, 20.8 kHz) must be
    /// upsampled, not emitted one host sample per guest byte.
    func testResamplerUpsamplesSlowGuestRate() {
        var r = BoxResampler(outputRate: 48_000, gain: 1)
        var out: [Float] = []
        for _ in 0..<20_833 { r.push(left: 0.5, right: -0.5, inputRate: 1_000_000 / 48) { l, _ in out.append(l) } }
        XCTAssertEqual(Double(out.count), 48_000, accuracy: 2)
        XCTAssertTrue(out.allSatisfy { abs($0 - 0.5) < 1e-4 })
    }

    func testResamplerDownsamplesAndAverages() {
        var r = BoxResampler(outputRate: 48_000, gain: 1)
        var out: [Float] = []
        // 8 channels at 6 µs per byte: alternating +1/-1 averages to ~0.
        for i in 0..<166_666 { r.push(left: i & 1 == 0 ? 1 : -1, right: 0, inputRate: 1_000_000 / 6) { l, _ in out.append(l) } }
        XCTAssertEqual(Double(out.count), 48_000, accuracy: 2)
        XCTAssertLessThan(out.map { abs($0) }.max()!, 0.3)
    }

    /// Sound DMA streams a guest buffer from physical RAM to the sink.
    func testSoundDMAStreamsGuestBuffer() throws {
        let m = try syntheticMachine()
        _ = m.memc.readWord(0x0380_0000, sequential: false)
        for i in 0..<64 { m.memc.writeByte(0x0200_1000 + UInt32(i), 0x80) }
        func memc(_ reg: UInt32, _ addr: UInt32) { m.memc.writeWord(0x0360_0000 | reg << 17 | (addr >> 4) << 2, 0, sequential: false) }
        memc(5, 0x1030) // SendN
        memc(4, 0x1000) // Sstart
        memc(6, 0) // Sptr reset: start the buffer
        m.memc.writeWord(0x036E_0000 | 1 << 11, 0, sequential: false) // control: sound DMA on
        m.memc.writeWord(0x0340_0000, 0xC000_0100 | 4, sequential: false) // VIDC SFR: 6 µs per byte
        m.run(seconds: 0.01)
        XCTAssertGreaterThan(m.vidc.soundBytesNonSilent, 0)
        XCTAssertGreaterThan(m.vidc.soundBytesOutput, 1000)
    }
}

final class JFDTests: XCTestCase {
    func testGzipMultiMember() throws {
        // Two concatenated gzip members ("Hello, " and "world").
        let a: [UInt8] = [31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 243, 72, 205, 201, 201, 215, 81, 0, 0, 5, 111, 87, 222, 7, 0, 0, 0]
        let b: [UInt8] = [31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 43, 207, 47, 202, 73, 1, 0, 67, 17, 119, 58, 5, 0, 0, 0]
        XCTAssertEqual(Gzip.inflate(a + b).map { String(decoding: $0, as: UTF8.self) }, "Hello, world")
    }

    func testHoledOutImageLoads() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../discimages/Holed Out!! (1989) (The Fourth Dimension) F1019900/Discs/Holed Out!! (1989) (The Fourth Dimension) F1019901.jfd").standardized.path
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("Holed Out JFD not present") }
        let img = try FloppyImage.open(path: path)
        XCTAssertEqual(img.geometry.tracks, 83)
        XCTAssertTrue(img.layout(side: 0, track: 15).isEmpty, "protection track is unformatted")
        XCTAssertEqual(img.layout(side: 1, track: 14).map(\.id), [0, 1, 2, 3])
        XCTAssertEqual(img.layout(side: 1, track: 17).map(\.id), [4])
        XCTAssertEqual(img.layout(side: 1, track: 17).first?.position ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(Array(img.readSector(side: 0, track: 0, sectorID: 1)![1...4]), Array("Hugo".utf8))
        let report = ADFSInspector.inspect(bytes: [UInt8](FileManager.default.contents(atPath: path)!))
        XCTAssertTrue(report.root.contains { $0.name == "!BOOT" })
    }
}

/// WD1772 behaviour on track-level images with protection features.
final class TrackLayoutTests: XCTestCase {
    /// 2 tracks x 2 sides: track 0 side 0 has sectors 0-3 only (4 missing),
    /// track 1 side 0 is unformatted, track 0 side 1 has sector 2 with a data CRC error.
    func protectedDisc() -> FloppyImage {
        var store = [UInt8](repeating: 0, count: 8 * 1024)
        for i in 0..<store.count { store[i] = UInt8(i / 1024 + 1) }
        func h(_ t: Int, _ side: Int, _ id: Int, _ slot: Int, dataCRC: Bool = false) -> SectorHeader {
            SectorHeader(cylinder: UInt8(t), head: UInt8(side), id: UInt8(id), sizeCode: 3, position: Double(id) / 5,
                         dataCRCError: dataCRC, dataOffset: slot * 1024)
        }
        let layouts: [[SectorHeader]] = [
            [h(0, 0, 0, 0), h(0, 0, 1, 1), h(0, 0, 2, 2), h(0, 0, 3, 3)],
            [h(0, 1, 2, 4, dataCRC: true)],
            [], [],
        ]
        let g = DiscGeometry(sides: 2, tracks: 2, sectorsPerTrack: 5, sectorSize: 1024, firstSectorID: 0, formatName: "test")
        return FloppyImage(store: store, layouts: layouts, geometry: g, sha256: "test", sourcePath: nil, writeProtected: false)
    }

    func machine(_ disc: FloppyImage) throws -> Machine {
        let m = try syntheticMachine()
        _ = m.memc.readWord(0x0380_0000, sequential: false)
        m.insertFloppy(disc)
        m.memc.writeByte(0x0335_0040, 0xFE) // latch A: drive 0, side 1 bit high = side 0
        m.memc.writeByte(0x0335_0018, 0xFD) // latch B: no reset, double density
        return m
    }

    func command(_ m: Machine, _ c: UInt8, track: UInt8? = nil, sector: UInt8? = nil) -> (status: UInt8, bytes: [UInt8]) {
        if let track { m.memc.writeByte(0x0331_0004, track) }
        if let sector { m.memc.writeByte(0x0331_0008, sector) }
        m.memc.writeByte(0x0331_0000, c)
        var bytes: [UInt8] = []
        for _ in 0..<400_000 { // up to 2 s: RNF waits 5-6 revolutions
            m.run(ticks: 120)
            if m.ioc.fiqStatus & 1 != 0 { bytes.append(UInt8(m.memc.readByte(0x0331_000C))) }
            if m.fdc.command == .idle && m.fdc.status & 1 == 0 { break }
        }
        return (m.fdc.status, bytes)
    }

    func seek(_ m: Machine, _ t: UInt8) {
        m.memc.writeByte(0x0331_000C, t)
        _ = command(m, 0x10)
    }

    func testMissingSectorGivesRecordNotFound() throws {
        let m = try machine(protectedDisc())
        let ok = command(m, 0x88, track: 0, sector: 3)
        XCTAssertEqual(ok.bytes.count, 1024)
        XCTAssertEqual(ok.status & 0x18, 0)
        let missing = command(m, 0x88, sector: 4)
        XCTAssertEqual(missing.status & 0x10, 0x10, "RNF")
        XCTAssertTrue(missing.bytes.isEmpty)
    }

    func testReadAddressOnUnformattedTrackFails() throws {
        let m = try machine(protectedDisc())
        let ra0 = command(m, 0xC8)
        XCTAssertEqual(ra0.bytes.count, 6)
        XCTAssertEqual(ra0.status & 0x10, 0)
        seek(m, 1)
        XCTAssertEqual(m.fdc.drives[0].headTrack, 1)
        XCTAssertEqual(command(m, 0xC8).status & 0x10, 0x10)
    }

    func testDataCRCErrorReported() throws {
        let m = try machine(protectedDisc())
        m.memc.writeByte(0x0335_0040, 0xEE) // side 1
        let r = command(m, 0x88, track: 0, sector: 2)
        XCTAssertEqual(r.bytes.count, 1024)
        XCTAssertEqual(r.status & 0x08, 0x08, "CRC error")
    }

    func testWriteCreatesMissingSectorOnFormattedTrackOnly() throws {
        let disc = protectedDisc()
        let m = try machine(disc)
        m.memc.writeByte(0x0331_0004, 0)
        m.memc.writeByte(0x0331_0008, 4)
        m.memc.writeByte(0x0331_0000, 0xA8)
        var n = 0
        for _ in 0..<200_000 {
            m.run(ticks: 120)
            if m.ioc.fiqStatus & 1 != 0 { m.memc.writeByte(0x0331_000C, 0x5A); n += 1 }
            if m.fdc.command == .idle && m.fdc.status & 1 == 0 { break }
        }
        XCTAssertEqual(m.fdc.status & 0x10, 0)
        XCTAssertEqual(disc.readSector(side: 0, track: 0, sectorID: 4)?.first, 0x5A)
        XCTAssertNil(disc.addSector(side: 0, track: 1, id: 0), "unformatted tracks stay unformatted")
    }
}

final class SnapshotTests: XCTestCase {
    #if !canImport(ObjectiveC)
    /// swift-corelibs-xctest (Linux) has no plain initialiser, and other
    /// tests make one of these for its helpers.
    convenience init() { self.init(name: "helper", testClosure: { _ in }) }
    #endif

    func fingerprint(_ m: Machine) -> [String] {
        var ramHash: UInt64 = 0xCBF2_9CE4_8422_2325
        for i in 0..<m.memc.ramSize { ramHash = (ramHash ^ UInt64(m.memc.ram[i])) &* 0x100_0000_01B3 }
        return ["ticks \(m.ticks)", "instr \(m.cpu.instructionCount)", "pc \(m.cpu.pc)", "psr \(m.cpu.psr)",
                "frame \(m.vidc.frameCount) \(m.currentFrame.checksum)", "ram \(ramHash)", "sound \(m.vidc.soundHash)",
                "fdc \(m.fdc.commandCount) \(m.fdc.status)", "cmos \(m.cmos)"]
    }

    func testRoundTripIsByteIdentical() throws {
        let m = try syntheticMachine()
        m.run(seconds: 0.05)
        let a = m.snapshot()
        let m2 = try Machine.restore(snapshot: a, rom: m.rom)
        XCTAssertEqual(m2.snapshot(), a)
        XCTAssertEqual(fingerprint(m2), fingerprint(m))
    }

    func testBadSnapshotsAreRejected() throws {
        let m = try syntheticMachine()
        var s = m.snapshot()
        XCTAssertThrowsError(try Machine.restore(snapshot: Array("hello".utf8), rom: m.rom)) {
            XCTAssertEqual("\($0)", "\(SnapshotError.notASnapshot)")
        }
        s[s.count - 10] ^= 0xFF // damage the compressed body
        XCTAssertThrowsError(try Machine.restore(snapshot: s, rom: m.rom))
        var otherBytes = [UInt8](repeating: 1, count: 4096)
        otherBytes[0...3] = [0xFE, 0xFF, 0xFF, 0xEA]
        let other = try ROMImage.build(parts: [otherBytes], sources: ["other"])
        XCTAssertThrowsError(try Machine.restore(snapshot: m.snapshot(), rom: other)) {
            guard case SnapshotError.romMismatch = $0 else { return XCTFail("\($0)") }
        }
    }

    func testMissingDiscIsReported() throws {
        let m = try syntheticMachine()
        m.insertFloppy(FloppyTests().syntheticDisc())
        let s = m.snapshot()
        XCTAssertThrowsError(try Machine.restore(snapshot: s, rom: m.rom)) {
            guard case SnapshotError.mediaMissing(drive: 0, _, _) = $0 else { return XCTFail("\($0)") }
        }
    }

    /// The restored machine must continue exactly as the original would,
    /// including mid-transfer floppy state and pending scripted input.
    func testRestoredRISCOSContinuesDeterministically() throws {
        guard let dir = ROMBootTests.romDir else { throw XCTSkip("RISC OS 3.11 ROM not present in ./roms/riscos3_11") }
        var c = MachineConfiguration()
        c.romPaths = [dir]
        c.powerOnKeys = [0x34]
        let m = try Machine(configuration: c)
        let disc = FloppyTests().syntheticDisc()
        m.insertFloppy(disc)
        m.powerOn()
        m.run(seconds: 21)
        // Script some input that straddles the snapshot point, then catch
        // the floppy controller mid-command (the Filer polls the drive).
        m.keyDown(0x0C); m.run(seconds: 0.1); m.keyUp(0x0C) // F12: command line
        m.run(seconds: 0.5)
        m.scheduleTyping("CAT\n")
        m.scheduleTyping("abc", startingAt: m.ticks + 24_000_000 * 8)
        let deadline = m.ticks + 24_000_000 * 5
        while m.fdc.command == .idle && m.ticks < deadline { m.run(ticks: 2_400) }
        XCTAssertNotEqual(m.fdc.command, .idle, "snapshot taken mid floppy command")
        XCTAssertGreaterThan(m.pendingInputEvents, 0, "snapshot taken with input pending")
        let s = m.snapshot()
        let m2 = try Machine.restore(snapshot: s, rom: m.rom) { _ in disc }
        XCTAssertEqual(fingerprint(m2), fingerprint(m))
        for _ in 0..<4 {
            m.run(seconds: 0.5); m2.run(seconds: 0.5)
            XCTAssertEqual(fingerprint(m2), fingerprint(m))
        }
    }
}

final class RunSplitTests: XCTestCase {
    /// Running in one call or in pieces must give the same machine.
    func testSplitRunMatchesSingleRun() throws {
        guard let dir = ROMBootTests.romDir else { throw XCTSkip("RISC OS 3.11 ROM not present in ./roms/riscos3_11") }
        var c = MachineConfiguration()
        c.romPaths = [dir]
        c.powerOnKeys = [0x34]
        let a = try Machine(configuration: c), b = try Machine(configuration: c)
        a.powerOn(); b.powerOn()
        a.run(seconds: 6)
        b.run(seconds: 2.5); b.run(seconds: 1.3); b.run(seconds: 2.2)
        for ((t, x), (_, y)) in zip(a.stateSections(), b.stateSections()) where x != y {
            let i = (0..<min(x.count, y.count)).first { x[$0] != y[$0] } ?? min(x.count, y.count)
            let lo = max(0, i - 8), hi = min(x.count, y.count, i + 16)
            let hx = x[lo..<hi].map { String(format: "%02X", $0) }.joined(), hy = y[lo..<hi].map { String(format: "%02X", $0) }.joined()
            print("DIFF section \(t) at byte \(i) of \(x.count): \(hx) vs \(hy)")
        }
        XCTAssertEqual(SnapshotTests().fingerprint(a), SnapshotTests().fingerprint(b))
    }
}

final class RewinderTests: XCTestCase {
    func testRewindReproducesThePast() throws {
        let m = try syntheticMachine()
        let r = Rewinder(intervalSeconds: 0.02, capacity: 10)
        var fingerprints: [UInt64: [String]] = [:]
        for _ in 0..<12 {
            m.run(seconds: 0.01)
            fingerprints[m.nominalTicks] = SnapshotTests().fingerprint(m)
            r.captureIfDue(m)
        }
        XCTAssertLessThanOrEqual(r.points.count, 10)
        // Any recorded moment after the earliest point can be revisited.
        let target = r.points[1].ticks + 240_000 // 10 ms after a point
        let back = try XCTUnwrap(try r.machine(at: target, from: m))
        XCTAssertEqual(SnapshotTests().fingerprint(back), fingerprints[target])
        XCTAssertEqual(r.points.last?.ticks, r.points[1].ticks, "later history discarded")
        XCTAssertEqual(r.points[0].thumbnail.count, Rewinder.thumbnailWidth * Rewinder.thumbnailHeight)
    }
}

final class SnapshotCostTests: XCTestCase {
    /// Rewind takes a snapshot a second on the emulation thread: keep it cheap.
    func testRewindSnapshotIsCheap() throws {
        let m = try syntheticMachine()
        m.run(seconds: 0.05)
        let start = Date()
        for _ in 0..<5 { _ = m.snapshot(compressionLevel: 1) }
        let each = Date().timeIntervalSince(start) / 5
        print(String(format: "snapshot (level 1): %.1f ms", each * 1000))
        XCTAssertLessThan(each, 0.1, "a rewind point must not stall the emulation thread")
        let r = Rewinder()
        let t = Date()
        r.capture(m)
        print(String(format: "rewind capture: %.1f ms", Date().timeIntervalSince(t) * 1000))
    }
}

final class DiscSaveTests: XCTestCase {
    func testSaveChangesWritesMergedImageAndResetsOverlay() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macarch-save-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("disc.adf").path
        try Data(FloppyTests().syntheticDisc().mergedImage()).write(to: URL(fileURLWithPath: path))
        let img = try FloppyImage.open(path: path)
        let originalHash = img.sha256
        img.writeSector(side: 1, track: 3, sectorID: 2, data: [UInt8](repeating: 0xAB, count: 1024))
        XCTAssertTrue(img.isModified)
        // Save As leaves the original untouched.
        let copy = dir.appendingPathComponent("copy.adf").path
        try img.saveChanges(to: copy)
        XCTAssertFalse(img.isModified)
        XCTAssertEqual(img.sourcePath, copy)
        XCTAssertEqual(SHA256.hex([UInt8](FileManager.default.contents(atPath: path)!)), originalHash)
        let reopened = try FloppyImage.open(path: copy)
        XCTAssertEqual(reopened.readSector(side: 1, track: 3, sectorID: 2)?.first, 0xAB)
        XCTAssertEqual(reopened.sha256, img.sha256)
    }

    func testJFDIsNotSavedAsRaw() throws {
        let store = [UInt8](repeating: 0, count: 1024)
        let h = SectorHeader(cylinder: 0, head: 0, id: 0, sizeCode: 3, position: 0, dataOffset: 0)
        let g = DiscGeometry(sides: 2, tracks: 1, sectorsPerTrack: 5, sectorSize: 1024, firstSectorID: 0, formatName: "t")
        let img = FloppyImage(store: store, layouts: [[h], []], geometry: g, sha256: "x", sourcePath: "/tmp/never.jfd", writeProtected: false)
        XCTAssertFalse(img.canSaveAsRawImage)
        XCTAssertThrowsError(try img.saveChanges())
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/never.jfd"))
    }
}

final class TypingTests: XCTestCase {
    /// Every printable ASCII character typed at the command line echoes back
    /// as itself under RISC OS 3.11 (checks `ArcKey.forCharacter`).
    func testTypedCharactersEcho() throws {
        guard let dir = ROMBootTests.romDir else { throw XCTSkip("RISC OS 3.11 ROM not present in ./roms/riscos3_11") }
        var c = MachineConfiguration()
        c.romPaths = [dir]
        c.powerOnKeys = [0x34]
        let m = try Machine(configuration: c)
        m.powerOn()
        m.run(seconds: 21)
        m.keyDown(0x0C); m.run(seconds: 0.1); m.keyUp(0x0C)
        m.run(seconds: 0.5)
        let text = "Ab1!2@3#4$5%6^7&8*9(0)-_=+[{]}\\|;:'\",<.>/?`~"
        m.scheduleTyping(text, startingAt: m.nominalTicks, intervalMs: 60)
        m.run(seconds: Double(text.count) * 0.12 + 1)
        XCTAssertTrue(m.recentText.hasSuffix(text), "echo: \(m.recentText.suffix(80))")
    }
}
