import Foundation
import XCTest
@testable import ArchimedesCore

final class ARM3Tests: XCTestCase {
    func arm3() -> CPUHarness {
        let h = CPUHarness()
        h.cpu.fitARM3(cache: ARM3Cache())
        return h
    }

    func testSwapWordAndByte() {
        let h = arm3()
        h.bus.put(0x1000, 0x1122_3344)
        h.cpu.r[1] = 0x1000; h.cpu.r[2] = 0xAABB_CCDD
        h.exec([0xE100_0092 | 1 << 16 | 0 << 12]) // SWP r0, r2, [r1]
        XCTAssertEqual(h.cpu.r[0], 0x1122_3344)
        XCTAssertEqual(h.bus.word(0x1000), 0xAABB_CCDD)

        h.cpu.r[1] = 0x1001
        h.exec([0xE140_0092 | 1 << 16 | 3 << 12]) // SWPB r3, r2, [r1]
        XCTAssertEqual(h.cpu.r[3], 0xCC)
        XCTAssertEqual(h.bus.word(0x1000), 0xAABB_DDDD)
    }

    func testSwapIsUndefinedOnARM2() {
        let h = CPUHarness()
        h.cpu.r[1] = 0x1000
        h.exec([0xE100_0092 | 1 << 16])
        XCTAssertEqual(h.cpu.pc, 0x04)
    }

    func testCP15IdentityAndControl() {
        let h = arm3()
        h.exec([0xEE10_0F10]) // MRC p15, 0, r0, c0, c0
        XCTAssertEqual(h.cpu.r[0], 0x4156_0300)
        h.cpu.r[1] = 1
        h.exec([0xEE02_1F10, 0xEE12_4F10]) // MCR c2 (cache on), MRC r4, c2
        XCTAssertEqual(h.cpu.r[4], 1)
        XCTAssertTrue(h.cpu.cp15!.enabled)
    }

    func testCP15IsPrivileged() {
        let h = arm3()
        h.cpu.setRegister(15, 0) // user mode
        h.exec([0xEE10_0F10])
        XCTAssertEqual(h.cpu.pc, 0x04, "MRC from user mode is undefined")
        XCTAssertEqual(h.cpu.mode, .supervisor)
    }

    /// A cached word costs one processor cycle; a miss fetches a line.
    func testCacheHitIsFasterThanMiss() throws {
        var rom = [UInt8](repeating: 0, count: 4096)
        rom[0] = 0xFE; rom[1] = 0xFF; rom[2] = 0xFF; rom[3] = 0xEA
        var c = MachineConfiguration(model: .a3000)
        c.cpu = .arm3
        let m = try Machine(configuration: c, rom: ROMImage.build(parts: [rom], sources: ["synthetic"]))
        m.powerOn()
        let memc = m.memc
        _ = memc.readWord(0x0380_0000, sequential: false) // leave the reset overlay
        let cache = try XCTUnwrap(memc.cache)
        cache.write(3, 1 << 28) // ROM area cacheable
        cache.write(2, 1)
        memc.cacheControlChanged()
        func cost(_ a: UInt32) -> UInt64 { let t = memc.ticks; _ = memc.readWord(a, sequential: false); return memc.ticks - t }
        let miss = cost(0x0380_0100), hit = cost(0x0380_0104)
        XCTAssertEqual(hit, 1)
        XCTAssertGreaterThan(miss, 4 * memc.sCycle)
        cache.write(1, 0) // flush
        XCTAssertEqual(cost(0x0380_0104), miss)
    }
}

final class MachineModelTests: XCTestCase {
    func testConfigurationRejectsWrongMemoryAndProcessor() throws {
        var bytes = [UInt8](repeating: 0, count: 4096)
        bytes[0] = 0xFE; bytes[1] = 0xFF; bytes[2] = 0xFF; bytes[3] = 0xEA // B .
        let rom = try ROMImage.build(parts: [bytes], sources: ["synthetic"])
        var c = MachineConfiguration(model: .a440)
        c.ramKB = 512
        XCTAssertThrowsError(try Machine(configuration: c, rom: rom))
        c = MachineConfiguration(model: .a540)
        c.cpu = .arm2
        XCTAssertThrowsError(try Machine(configuration: c, rom: rom))
        c = MachineConfiguration(model: .a540)
        XCTAssertEqual(try Machine(configuration: c, rom: rom).memc.camEntries.count, 128)
        c.ramKB = 16384
        XCTAssertEqual(try Machine(configuration: c, rom: rom).memc.camEntries.count, 512)
    }

    /// Snapshots written before models existed carry no model, processor or
    /// hard disc fields; they read as an A3000 with an ARM2.
    func testVersion1ConfigurationDecodes() throws {
        let json = #"{"version":1,"model":"A3000","cpu":"ARM2","ramKB":1024,"romPaths":["x"],"rtcEpoch":0,"powerOnKeys":[],"powerOnKeysMs":4000,"floppyController":"WD1772","monitor":"standard"}"#
        let c = try JSONDecoder().decode(MachineConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(c.model, .a3000)
        XCTAssertEqual(c.cpu, .arm2)
        XCTAssertEqual(c.ramKB, 1024)
        XCTAssertEqual(c.hardDiscs, [])
    }

    func rom(_ name: String) throws -> String {
        guard let dir = GameSmokeTests.romDir(name) else { throw XCTSkip("\(name) ROM not present in ./roms") }
        return dir
    }

    /// The A540's slave MEMCs: RISC OS 3.11 finds all 16 MB.
    func testA540SixteenMegabytes() throws {
        var c = MachineConfiguration(model: .a540)
        c.ramKB = 16384
        c.romPaths = [try rom("riscos3_11")]
        c.powerOnKeys = [0x34]
        let m = try Machine(configuration: c)
        m.powerOn()
        m.run(seconds: 25)
        XCTAssertTrue(m.recentText.contains("RISC OS 16384K"), m.recentText.suffix(200).description)
        XCTAssertEqual(m.cpu.exceptionCounts[5], 0)
    }

    /// Both ROMs on each A540 memory size. RISC OS 3.11 finds and maps it
    /// all. RISC OS 2.00 (the A540 shipped with 2.01) only ever programs
    /// the master and first slave (A7), never A12's two, so it stops at
    /// 8 MB; and over 4 MB its Window Manager 2.00 gives up with "Too many
    /// pages in this machine!", whose error path then unstacks from a
    /// workspace word ("TASK") and takes an address exception. That's the
    /// ROM, not the emulation.
    func testA540MemorySizesBothROMs() throws {
        for romName in ["riscos2_00", "riscos3_11"] {
            for kb in [4096, 8192, 16384] {
                var c = MachineConfiguration(model: .a540)
                c.ramKB = kb
                c.romPaths = [try rom(romName)]
                c.powerOnKeys = [0x34]
                let m = try Machine(configuration: c)
                m.powerOn()
                m.run(seconds: 25)
                let found = romName == "riscos2_00" ? min(kb, 8192) : kb
                XCTAssertTrue(m.recentText.contains("RISC OS \(found)K"), "\(romName) \(kb)K: " + m.recentText.suffix(200).description)
                XCTAssertEqual(m.memc.mappedPages.mapped, found / 32, "\(romName) \(kb)K: pages mapped")
                let wimpGivesUp = romName == "riscos2_00" && kb > 4096
                XCTAssertEqual(m.cpu.exceptionCounts[5], wimpGivesUp ? 1 : 0, "\(romName) \(kb)K: address exceptions")
            }
        }
    }

    /// A first boot holds Delete to reset CMOS, and RISC OS only looks
    /// after clearing memory: an 8 or 16 MB A540 must still get the reset,
    /// and so start the desktop in colour (not the Supervisor prompt and
    /// mode 0, as an empty CMOS gives).
    func testA540FirstBootResetsCMOS() throws {
        for kb in [8192, 16384] {
            var c = MachineConfiguration(model: .a540)
            c.ramKB = kb
            c.romPaths = [try rom("riscos3_11")]
            c.powerOnKeys = [0x34]
            let m = try Machine(configuration: c)
            XCTAssertTrue(Machine.cmosNeverConfigured(m.cmos))
            m.powerOn()
            m.run(seconds: 30)
            XCTAssertFalse(Machine.cmosNeverConfigured(m.cmos), "\(kb)K: CMOS reset")
            XCTAssertFalse(m.recentText.contains("Supervisor"), "\(kb)K: the desktop starts")
            XCTAssertTrue(m.recentText.contains("Apps"), "\(kb)K: the desktop starts")
        }
    }

    /// The A540's MEMCs, from the databook and the A540's decoding: A7 and
    /// A12 choose the MEMC a CAM write programs (at any page size), each
    /// MEMC's pages lie in its own 4 MB, and a MEMC that isn't fitted
    /// neither takes CAM writes nor answers physical accesses.
    func testA540SlaveMEMCs() {
        let m = MEMC(ramSize: 8 << 20, rom: [UInt8](repeating: 0, count: 4), slaveMEMCs: true)
        XCTAssertEqual(m.memcCount, 2)
        m.privileged = true
        _ = m.readWord(0x0380_0000, sequential: false) // leave the reset overlay
        m.writeWord(0x0240_0000, 0x5151_5151, sequential: false) // first slave's DRAM
        m.writeWord(0x0200_0000, 0x4D4D_4D4D, sequential: false) // master's
        m.setPageSize(3)
        // Physical page 0, logical page 1 (&8000), for the first slave (A7).
        m.writeCAM(0x0380_0000 | 1 << 15 | 1 << 7)
        XCTAssertEqual(m.readWord(0x8000, sequential: false), 0x5151_5151)
        XCTAssertFalse(m.abort)
        // Logical page 2 for the second slave (A12), which isn't fitted.
        m.writeCAM(0x0380_0000 | 2 << 15 | 1 << 12)
        _ = m.readWord(0x1_0000, sequential: false)
        XCTAssertTrue(m.abort, "no MEMC maps it")
        m.abort = false
        // Nothing answers the second slave's physical space.
        XCTAssertEqual(m.readWord(0x0280_0000, sequential: false), 0xFFFF_FFFF)
        XCTAssertEqual(m.readByte(0x0280_0001), 0xFF)
        m.writeWord(0x0280_0000, 0x1234_5678, sequential: false)
        XCTAssertEqual(m.readWord(0x0200_0000, sequential: false), 0x4D4D_4D4D, "the write went nowhere")
        // With 4 KB pages A7 still chooses the slave.
        m.setPageSize(0)
        // (an even logical page: with 4 KB pages A12 is also its lowest bit)
        m.writeCAM(0x0380_0000 | 2 << 12 | 1 << 7)
        XCTAssertEqual(m.readWord(0x2000, sequential: false), 0x5151_5151)

        // One MEMC ignores A22 and up: its physical space repeats.
        let single = MEMC(ramSize: 4 << 20, rom: [UInt8](repeating: 0, count: 4))
        single.privileged = true
        _ = single.readWord(0x0380_0000, sequential: false)
        single.writeWord(0x0200_0000, 0x0102_0304, sequential: false)
        XCTAssertEqual(single.readWord(0x0240_0000, sequential: false), 0x0102_0304)
    }

    /// RISC OS 3.11 finds the ARM3 and turns its cache on, and the same
    /// BASIC loop then runs several times faster than on an ARM2.
    func testARM3CacheOnAndFaster() throws {
        func loopTime(_ cpu: CPUType) throws -> (Int, Machine) {
            var c = MachineConfiguration(model: .a3000)
            c.cpu = cpu
            c.romPaths = [try rom("riscos3_11")]
            c.powerOnKeys = [0x34]
            let m = try Machine(configuration: c)
            m.powerOn()
            m.run(seconds: 20)
            m.keyDown(0x0C); m.run(seconds: 0.1); m.keyUp(0x0C) // F12: command line
            m.run(seconds: 1)
            m.scheduleTyping("*BASIC\nT%=TIME:FOR I%=1 TO 50000:A%=I% AND 7:NEXT:PRINT \"T=\";STR$(TIME-T%)\n", intervalMs: 40)
            m.run(seconds: 30)
            let line = m.recentText.components(separatedBy: "\n").last { $0.hasPrefix("T=") }
            return (Int(line?.dropFirst(2) ?? "") ?? -1, m)
        }
        let (arm2, _) = try loopTime(.arm2)
        let (arm3, m3) = try loopTime(.arm3)
        XCTAssertTrue(m3.memc.cache?.enabled ?? false, "RISC OS enables the cache")
        XCTAssertGreaterThan(arm2, 0); XCTAssertGreaterThan(arm3, 0)
        let ratio = Double(arm2) / Double(arm3)
        XCTAssertTrue((3.0...6.0).contains(ratio), "ARM3 speed-up \(ratio) (ARM2 \(arm2) cs, ARM3 \(arm3) cs)")
    }

    /// The turbo ARM3s run the same loop faster (by less than their clock
    /// ratio, as memory doesn't speed up), while the machine's clock keeps
    /// real time: ten seconds of emulation is still about 1000 centiseconds
    /// to RISC OS.
    func testTurboARM3IsFasterButKeepsRealTime() throws {
        func measure(_ cpu: CPUType) throws -> (loop: Int, tenSeconds: Int) {
            var c = MachineConfiguration(model: .a3000)
            c.cpu = cpu
            c.romPaths = [try rom("riscos3_11")]
            c.powerOnKeys = [0x34]
            let m = try Machine(configuration: c)
            m.powerOn()
            m.run(seconds: 20)
            m.keyDown(0x0C); m.run(seconds: 0.1); m.keyUp(0x0C) // F12: command line
            m.run(seconds: 1)
            m.scheduleTyping("*BASIC\nT%=TIME:FOR I%=1 TO 50000:A%=I% AND 7:NEXT:PRINT \"T=\";STR$(TIME-T%)\n", intervalMs: 40)
            m.run(seconds: 30)
            m.scheduleTyping("S%=TIME\n", intervalMs: 40)
            m.run(seconds: 10)
            m.scheduleTyping("PRINT \"S=\";STR$(TIME-S%)\n", intervalMs: 40)
            m.run(seconds: 3)
            let lines = m.recentText.components(separatedBy: "\n")
            func value(_ p: String) -> Int { Int(lines.last { $0.hasPrefix(p) }?.dropFirst(2) ?? "") ?? -1 }
            return (value("T="), value("S="))
        }
        let base = try measure(.arm3), x2 = try measure(.arm3x2), x4 = try measure(.arm3x4)
        XCTAssertTrue((1000...1250).contains(base.tenSeconds), "10 s and some typing: \(base.tenSeconds) cs")
        for r in [base, x2, x4] {
            XCTAssertGreaterThan(r.loop, 0)
            // About 10 s, plus typing the PRINT: the same whatever the processor.
            XCTAssertEqual(Double(r.tenSeconds), Double(base.tenSeconds), accuracy: 3, "RISC OS's clock keeps real time")
        }
        let r2 = Double(base.loop) / Double(x2.loop), r4 = Double(base.loop) / Double(x4.loop)
        // Less than the clock ratio: writes and cache misses run at memory speed.
        XCTAssertTrue((1.5...2.0).contains(r2), "×2 speed-up \(r2) (\(base.loop) cs, \(x2.loop) cs)")
        XCTAssertTrue((2.2...4.0).contains(r4), "×4 speed-up \(r4) (\(base.loop) cs, \(x4.loop) cs)")
    }
}

/// The ST506 controller driven through IOC bank 5 the way ADFS does:
/// Specify, Seek, then Read and Write Data with each sector moved through
/// the DACK addresses on the data request interrupt.
final class HD63463Tests: XCTestCase {
    var dir: String!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "macarch-hdc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: dir) }

    func machine(disc: String) throws -> Machine {
        var bytes = [UInt8](repeating: 0, count: 4096)
        bytes[0] = 0xFE; bytes[1] = 0xFF; bytes[2] = 0xFF; bytes[3] = 0xEA // B .
        var c = MachineConfiguration(model: .a440)
        c.hardDiscs = [disc]
        let m = try Machine(configuration: c, rom: ROMImage.build(parts: [bytes], sources: ["synthetic"]))
        m.powerOn()
        _ = m.memc.readWord(0x0380_0000, sequential: false) // leave the reset overlay
        return m
    }

    let base: UInt32 = 0x0335_0000
    func write(_ m: Machine, _ reg: UInt32, _ v: UInt16) { m.memc.writeWord(base | reg, UInt32(v) << 16, sequential: false) }
    func read(_ m: Machine, _ reg: UInt32) -> UInt16 { UInt16(truncatingIfNeeded: m.memc.readWord(base | reg, sequential: false)) }
    func status(_ m: Machine) -> UInt8 { UInt8(read(m, 0x20) >> 8) }
    func params(_ m: Machine, _ bytes: [UInt8]) {
        for i in stride(from: 0, to: bytes.count, by: 2) { write(m, 0x04, UInt16(bytes[i]) << 8 | UInt16(i + 1 < bytes.count ? bytes[i + 1] : 0)) }
    }
    func results(_ m: Machine, _ n: Int) -> [UInt8] {
        (0..<(n + 1) / 2).flatMap { _ -> [UInt8] in let w = read(m, 0x24); return [UInt8(w >> 8), UInt8(w & 0xFF)] }
    }
    func command(_ m: Machine, _ c: UInt8) { write(m, 0x00, UInt16(c)) }
    var irq: (Machine) -> Bool = { $0.ioc.irqBStatus & IOC.irqBHardDisc != 0 }

    /// Runs until the interrupt line rises (or a time limit passes).
    func waitForIRQ(_ m: Machine) {
        for _ in 0..<1000 where !irq(m) { m.run(seconds: 0.0005) }
    }

    func specifyAndSeek(_ m: Machine, cylinder: UInt16) {
        // OM0 OM1(DMA, PSK) OM2 CUL(units 1,2) NCH NCL NH NS SH/RL gaps...
        params(m, [0x00, 0x80, 0x1F, 0x06, 0x02, 0x66, 3, 31, 0x01, 0, 0, 0, 0, 0, 0, 0])
        command(m, 0xE8)
        command(m, 0x08)
        params(m, [1, 0, UInt8(cylinder >> 8), UInt8(cylinder & 0xFF)])
        command(m, 0xC0)
        XCTAssertEqual(status(m) & 0x30, 0x30, "seek: command end and seek end")
        XCTAssertTrue(irq(m))
        command(m, 0x08)
        XCTAssertFalse(irq(m), "recall clears the interrupt")
    }

    func testReadAndWriteSectorsThroughDACK() throws {
        let path = dir + "/disc.hdf"
        let g = HardDiscGeometry(cylinders: 615, heads: 4)
        let img = try HardDiscImage.create(path: path, geometry: g)
        // Cylinder 10, head 2, sectors 31 and (next head) 0.
        img.write(cylinder: 10, head: 2, sector: 31, (0..<256).map { UInt8($0) })
        img.write(cylinder: 10, head: 3, sector: 0, (0..<256).map { UInt8(255 - $0) })
        let m = try machine(disc: path)
        specifyAndSeek(m, cylinder: 10)

        params(m, [1, 2, 0, 10, 2, 31, 0, 2]) // US PHA LCA LHA LSA SCNT=2
        command(m, 0x40)
        var got: [[UInt8]] = []
        for _ in 0..<2 {
            waitForIRQ(m)
            XCTAssertEqual(status(m) & 0x80, 0x80, "busy during transfer")
            got.append((0..<128).flatMap { _ -> [UInt8] in let w = read(m, 0x08); return [UInt8(w & 0xFF), UInt8(w >> 8)] })
        }
        waitForIRQ(m)
        XCTAssertEqual(status(m) & 0xA4, 0x20, "command end, not busy, no error")
        XCTAssertEqual(got[0], (0..<256).map { UInt8($0) })
        XCTAssertEqual(got[1], (0..<256).map { UInt8(255 - $0) })
        XCTAssertEqual(results(m, 10), [0, 0, 1, 3, 0, 10, 3, 1, 0, 0], "results: next sector, count 0")
        command(m, 0x08)

        params(m, [1, 0, 0, 10, 0, 5, 0, 1])
        command(m, 0x87)
        waitForIRQ(m)
        for i in 0..<128 { write(m, 0x28, UInt16(i * 2) | UInt16(i * 2 + 1) << 8) }
        waitForIRQ(m)
        XCTAssertEqual(status(m) & 0xA4, 0x20)
        XCTAssertEqual(img.read(cylinder: 10, head: 0, sector: 5), (0..<256).map { UInt8($0 & 0xFF) })
    }

    func testErrors() throws {
        let path = dir + "/disc.hdf"
        try HardDiscImage.create(path: path, geometry: HardDiscGeometry(cylinders: 615, heads: 4))
        let m = try machine(disc: path)
        params(m, [1, 0, 0, 0])
        command(m, 0xC0)
        XCTAssertEqual(results(m, 2), [0, 0x10], "commands before Specify: not specified")
        command(m, 0x08)
        specifyAndSeek(m, cylinder: 0)
        params(m, [2, 0])
        command(m, 0x28)
        XCTAssertEqual(results(m, 2), [0, 0x20], "unit 2 has no drive: not ready")
        command(m, 0x08)
        params(m, [1, 0, 0x03, 0x00, 0, 0, 0, 1]) // cylinder 768: beyond the drive
        command(m, 0x40)
        waitForIRQ(m)
        XCTAssertEqual(status(m) & 0x24, 0x24, "abnormal end")
        XCTAssertEqual(results(m, 2), [0, 0x58], "ID not found")
    }
}

final class ADFSFormatterTests: XCTestCase {
    /// Check bytes for a 615 x 4 drive, id &1234, no name (worked out
    /// independently from the PRM's algorithms).
    func testBlankLayoutCheckBytes() {
        let d = ADFSFormatter.layout(geometry: HardDiscGeometry(cylinders: 615, heads: 4), name: "", id: 0x1234)
        XCTAssertEqual(Array(d[0x0FC...0x0FF]), [0x80, 0x33, 0x01, 0xC2])
        XCTAssertEqual(Array(d[0x100...0x102]), [0x72, 0x33, 0x01])
        XCTAssertEqual(d[0x1FF], 0xEF)
        XCTAssertEqual(d[0xBFF], 0x2C, "root directory check byte")
        XCTAssertEqual(Array(d[0xDB0...0xDBF]), [0, 0, 0, 0, 0x0A, 0x20, 0x0C, 0x0D, 0xFF, 0x03, 0x80, 0, 0, 0, 0x33, 0x01])
        XCTAssertEqual(Array(d[0xDC0...0xDC3]), [8, 32, 4, 0])
        XCTAssertEqual(Array(d[0xDD0...0xDD3]), [0x00, 0x80, 0x33, 0x01])
        XCTAssertEqual(d[0xDFF], 0xFF, "boot block checksum")
        for (g, c0, c1, boot) in [(HardDiscGeometry(cylinders: 820, heads: 6), 0x77, 0xA3, 0x2B), (HardDiscGeometry(cylinders: 1024, heads: 8), 0x12, 0x3E, 0x22)] {
            let d = ADFSFormatter.layout(geometry: g, name: "", id: 0x1234)
            XCTAssertEqual([d[0xFF], d[0x1FF], d[0xDFF]], [UInt8(c0), UInt8(c1), UInt8(boot)])
        }
    }
}

/// RISC OS drives an A440's ST506 disc that MacArch formatted: it mounts,
/// takes a 128 KB file (multi-sector transfers across tracks and heads)
/// and reads it back intact. The CMOS reset at power-on configures the
/// fitted drive.
final class HardDiscROMTests: XCTestCase {
    func testSaveAndLoadOnFormattedDisc() throws {
        var ran = 0
        for rom in ["riscos3_11", "riscos2_00"] {
            guard let dir = GameSmokeTests.romDir(rom) else { continue }
            let path = NSTemporaryDirectory() + "macarch-hd-\(UUID().uuidString).hdf"
            defer { try? FileManager.default.removeItem(atPath: path) }
            try ADFSFormatter.createFormattedImage(path: path, geometry: HardDiscGeometry(cylinders: 615, heads: 4), name: "HardDisc4")
            var c = MachineConfiguration(model: .a440)
            c.romPaths = [dir]
            c.hardDiscs = [path]
            c.powerOnKeys = [0x34]
            let m = try Machine(configuration: c)
            m.powerOn()
            m.run(seconds: 25)
            m.keyDown(0x0C); m.run(seconds: 0.1); m.keyUp(0x0C) // F12
            m.run(seconds: 1)
            m.scheduleTyping("*Save :4.$.Big 3800000 +20000\n*Load :4.$.Big 10000\n*Free :4\n", intervalMs: 40)
            m.run(seconds: 30)
            XCTAssertTrue(m.recentText.contains("Bytes free &01317200"), "\(rom): \(m.recentText.suffix(300))")
            var same = true
            for i in stride(from: 0, to: 0x20000, by: 251) where m.memc.debugRead(0x10000 + UInt32(i), space: .logical) != m.memc.rom[i] { same = false; break }
            XCTAssertTrue(same, "\(rom): file read back differs from what was saved")
            ran += 1
        }
        if ran == 0 { throw XCTSkip("no RISC OS ROMs in ./roms") }
    }
}

final class ModelSnapshotTests: XCTestCase {
    /// An ARM3 A440 with a hard disc, mid-way through disc activity,
    /// restores from a snapshot and runs on exactly as the original does.
    func testARM3A440SnapshotIsDeterministic() throws {
        // The turbo ARM3 also carries a fraction of a tick between snapshots.
        for cpu in [CPUType.arm3, .arm3x4] { try snapshotIsDeterministic(cpu) }
    }

    func snapshotIsDeterministic(_ cpu: CPUType) throws {
        guard let dir = GameSmokeTests.romDir("riscos3_11") else { throw XCTSkip("RISC OS 3.11 ROM not present") }
        let path = NSTemporaryDirectory() + "macarch-snap-\(UUID().uuidString).hdf"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try ADFSFormatter.createFormattedImage(path: path, geometry: HardDiscGeometry(cylinders: 615, heads: 4), name: "Snap")
        var c = MachineConfiguration(model: .a440)
        c.cpu = cpu
        c.romPaths = [dir]
        c.hardDiscs = [path]
        c.powerOnKeys = [0x34]
        let a = try Machine(configuration: c)
        a.powerOn()
        a.run(seconds: 25)
        a.keyDown(0x0C); a.run(seconds: 0.1); a.keyUp(0x0C)
        a.run(seconds: 1)
        a.scheduleTyping("*Cat :4\n*Cat :4\n", intervalMs: 40)
        a.run(seconds: 0.5)
        let snap = a.snapshot()
        let b = try Machine.restore(snapshot: snap, rom: a.rom, hardDiscs: a.hdc?.drives)
        a.run(seconds: 3)
        b.run(seconds: 3)
        XCTAssertEqual(a.cpu.instructionCount, b.cpu.instructionCount)
        let sa = a.stateSections(), sb = b.stateSections()
        for ((ta, da), (_, db)) in zip(sa, sb) { XCTAssertEqual(da, db, "section \(ta) differs") }
        XCTAssertTrue(a.memc.cache?.enabled ?? false)
        XCTAssertEqual(try Snapshot.header(of: snap).hardDiscs?.first?.path, path)
    }
}

/// The A5000 family's new I/O under RISC OS 3.11: the 82C711's floppy
/// controller and IDE interface, and the IOEB.
final class NewIOTests: XCTestCase {
    func boot(_ model: MachineModel, disc: String? = nil, hardDisc: String? = nil) throws -> Machine {
        guard let dir = GameSmokeTests.romDir("riscos3_11") else { throw XCTSkip("RISC OS 3.11 ROM not present") }
        var c = MachineConfiguration(model: model)
        c.romPaths = [dir]
        c.powerOnKeys = [0x34]
        if let hardDisc { c.hardDiscs = [hardDisc] }
        let m = try Machine(configuration: c)
        if let disc { m.insertFloppy(try FloppyImage.open(path: disc)) }
        m.powerOn()
        m.run(seconds: 25)
        m.keyDown(0x0C); m.run(seconds: 0.1); m.keyUp(0x0C)
        m.run(seconds: 1)
        return m
    }

    func temporaryCopy(of name: String) throws -> String {
        let src = GameSmokeTests.root.appendingPathComponent("discimages/" + name).path
        guard FileManager.default.fileExists(atPath: src) else { throw XCTSkip("\(name) not present") }
        let dst = NSTemporaryDirectory() + "macarch-\(UUID().uuidString)-" + name
        try FileManager.default.copyItem(atPath: src, toPath: dst)
        return dst
    }

    func readBack(_ m: Machine, at address: UInt32, length: Int) -> Bool {
        stride(from: 0, to: length, by: 61).allSatisfy { m.memc.debugRead(address + UInt32($0), space: .logical) == m.memc.rom[$0] }
    }

    /// The floppy (765 core: Read ID at the right data rate, DMA through
    /// the FIQ handler with terminal count) reads, writes and reads back.
    func testA5000FloppyRoundTrip() throws {
        let disc = try temporaryCopy(of: "adfs_Lemmings.adf")
        defer { try? FileManager.default.removeItem(atPath: disc) }
        let m = try boot(.a5000, disc: disc)
        m.scheduleTyping("*Cat :0\n*Save :0.$.Test 3800000 +3000\n*Load :0.$.Test 10000\n", intervalMs: 40)
        m.run(seconds: 25)
        XCTAssertTrue(m.recentText.contains("!Lemmings"), m.recentText.suffix(300).description)
        XCTAssertTrue(readBack(m, at: 0x10000, length: 0x3000), "file read back from the floppy")
        XCTAssertEqual(m.cpu.exceptionCounts[5], 0)
    }

    /// IDE on the A5000 and A3020: a formatted drive mounts and a 128 KB
    /// file (multi-sector, across heads) round-trips. IDEDiscs is set for
    /// the fitted drive after the CMOS reset.
    func testIDERoundTrip() throws {
        for model in [MachineModel.a5000, .a3020] {
            let path = NSTemporaryDirectory() + "macarch-ide-\(UUID().uuidString).hdf"
            defer { try? FileManager.default.removeItem(atPath: path) }
            try ADFSFormatter.createFormattedImage(path: path, geometry: HardDiscGeometry.idePresets[0].geometry, name: "IDE4")
            let m = try boot(model, hardDisc: path)
            m.scheduleTyping("*Save :4.$.Big 3800000 +20000\n*Load :4.$.Big 10000\n*Free :4\n", intervalMs: 40)
            m.run(seconds: 25)
            XCTAssertTrue(m.recentText.contains("Bytes used &00020E00"), "\(model): \(m.recentText.suffix(300))")
            XCTAssertTrue(readBack(m, at: 0x10000, length: 0x20000), "\(model): file read back from the IDE disc")
            XCTAssertEqual(m.configuredHardDiscs, 1)
        }
    }

    /// The A3010 (ARM250, no IDE) boots and finds its floppy drive.
    func testA3010Boots() throws {
        let m = try boot(.a3010)
        XCTAssertTrue(m.recentText.contains("RISC OS 1024K"))
        XCTAssertTrue(m.recentText.contains(":0"), "floppy drive icon")
        XCTAssertTrue(m.cpu.hasSWP)
        XCTAssertNil(m.cpu.cp15)
    }

    /// Mid-way through a floppy read, a snapshot restores and runs on
    /// exactly as the original (765 and IOEB state included).
    func testA5000SnapshotDuringFloppyRead() throws {
        let disc = try temporaryCopy(of: "adfs_Repton_3.adf")
        defer { try? FileManager.default.removeItem(atPath: disc) }
        let a = try boot(.a5000, disc: disc)
        a.scheduleTyping("*Cat :0\n", intervalMs: 40)
        a.run(seconds: 0.6)
        let snap = a.snapshot()
        let b = try Machine.restore(snapshot: snap, rom: a.rom) { _ in a.fdc.drives[0].disc }
        a.run(seconds: 3); b.run(seconds: 3)
        for ((t, x), (_, y)) in zip(a.stateSections(), b.stateSections()) { XCTAssertEqual(x, y, "section \(t) differs") }
    }
}

final class VIDCClockTests: XCTestCase {
    /// The IOEB's 25.175 MHz clock makes the same line shorter.
    func testLineTimeFollowsBaseClock() throws {
        let m = try syntheticMachine()
        let v = m.vidc
        v.writeRegister(0x8000_0000 | (511 << 14)) // HCR: 1024 pixels
        v.writeRegister(0xE000_0003)                 // control: 24 MHz pixel rate (divider 1)
        XCTAssertEqual(v.lineTicks, 1024)
        v.baseClockHz = 25_175_000
        XCTAssertEqual(v.lineTicks, 1024 * 24_000_000 / 25_175_000)
    }
}

final class CMOSDriveCountTests: XCTestCase {
    /// Regression: CMOS left configured for a hard disc that is no longer
    /// fitted made ADFS wait about 40 s at start-up and left a drive icon
    /// that only gave errors. Power-on now matches the count to the drives.
    func testRemovedDriveIsUnconfigured() throws {
        guard let dir = GameSmokeTests.romDir("riscos3_11") else { throw XCTSkip("RISC OS 3.11 ROM not present") }
        let path = NSTemporaryDirectory() + "macarch-cmos-\(UUID().uuidString).hdf"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try ADFSFormatter.createFormattedImage(path: path, geometry: HardDiscGeometry(cylinders: 615, heads: 4), name: "Gone")
        var c = MachineConfiguration(model: .a440)
        c.romPaths = [dir]
        c.hardDiscs = [path]
        c.powerOnKeys = [0x34]
        let first = try Machine(configuration: c)
        first.powerOn()
        first.run(seconds: 20)
        XCTAssertEqual(first.configuredHardDiscs, 1)

        c.hardDiscs = []
        c.powerOnKeys = []
        let second = try Machine(configuration: c)
        second.loadCMOS(Array(first.rtc.ram))
        second.powerOn()
        XCTAssertEqual(second.configuredHardDiscs, 0, "power-on drops the drive that is no longer fitted")
        second.run(seconds: 20)
        XCTAssertTrue(second.recentText.contains("Apps"), "desktop within 20 s")
    }
}
