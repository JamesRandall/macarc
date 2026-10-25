// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ArchimedesCore

final class OriginalDiscChangeTests: XCTestCase {
    func machine(_ model: MachineModel = .a440) throws -> Machine {
        // Original test ROM containing B .; no commercial ROM is opened.
        var data = [UInt8](repeating: 0, count: 2 * 1024 * 1024)
        data[0..<4] = [0xfe, 0xff, 0xff, 0xea]
        let rom = try ROMImage.build(parts: [data], sources: [])
        return try Machine(configuration: MachineConfiguration(model: model), rom: rom)
    }
    func disc(_ value: UInt8) -> FloppyImage {
        FloppyImage(data: [UInt8](repeating: value, count: 819200), geometry: DiscGeometry(sides: 2, tracks: 80, sectorsPerTrack: 5, sectorSize: 1024, firstSectorID: 0, formatName: "test"), writeProtected: true)
    }
    func changed(_ m: Machine) -> Bool { m.ioc.irqBStatus & IOC.irqBDiscChanged != 0 }

    func testInsertClearEjectAndEmptyCannotBeCleared() throws {
        let m = try machine(); let d = disc(0)
        m.fdc.latchAChanged(0xfe) // select 0, reset line inactive
        XCTAssertTrue(changed(m)) // selected drive is empty
        m.insertFloppy(d); XCTAssertTrue(changed(m))
        m.fdc.latchAChanged(0x7e); XCTAssertFalse(changed(m))
        m.fdc.latchAChanged(0xfe); XCTAssertFalse(changed(m))
        m.ejectFloppy(); XCTAssertTrue(changed(m))
        m.fdc.latchAChanged(0x7e); XCTAssertTrue(changed(m))
        m.fdc.latchAChanged(0xff); XCTAssertFalse(changed(m)) // no selected drive
        XCTAssertTrue(d.writeProtected); XCTAssertFalse(d.isModified)
    }
    func testDirectMediaReplacementAndIndependentDriveLatches() throws {
        let m = try machine(); let a = disc(1), b = disc(2)
        m.fdc.drives[0].disc = a; m.fdc.drives[1].disc = b
        m.fdc.latchAChanged(0x7e); m.fdc.latchAChanged(0xfe); XCTAssertFalse(changed(m))
        m.fdc.latchAChanged(0xfd); XCTAssertTrue(changed(m))
        m.fdc.latchAChanged(0x7d); m.fdc.latchAChanged(0xfd); XCTAssertFalse(changed(m))
        m.fdc.drives[0].disc = b; XCTAssertFalse(changed(m))
        m.fdc.latchAChanged(0xfe); XCTAssertTrue(changed(m))
        m.fdc.latchAChanged(0x7e); m.fdc.latchAChanged(0xfe)
        m.fdc.drives[0].headTrack = 3; XCTAssertFalse(changed(m))
        m.fdc.drives[0].disc = b; XCTAssertFalse(changed(m)) // same medium
    }
    func testIRQMaskAndOtherModelsUnaffected() throws {
        let m = try machine(); m.insertFloppy(disc(1)); m.fdc.latchAChanged(0xfe)
        m.ioc.writeInternal(0x28, IOC.irqBDiscChanged); XCTAssertTrue(m.cpu.irqLine)
        m.fdc.latchAChanged(0x7e); XCTAssertFalse(m.cpu.irqLine)
        for model: MachineModel in [.a3000, .a5000, .a3010, .a3020, .a4000] {
            let other = try machine(model); other.insertFloppy(disc(2)); other.fdc.latchAChanged(0xfe)
            XCTAssertFalse(changed(other)); other.ejectFloppy(); XCTAssertFalse(changed(other))
        }
    }
    func testSnapshotPreservesSelectedAndUnselectedChanges() throws {
        let m = try machine(); let a = disc(1), b = disc(2)
        m.insertFloppy(a); m.insertFloppy(b, drive: 1)
        m.fdc.latchAChanged(0x7e); m.fdc.latchAChanged(0xfe)
        XCTAssertEqual(m.fdc.discChangeState, [false,true,false,false])
        let data = m.snapshot(); let h = try Snapshot.header(of:data)
        XCTAssertEqual(h.floppyDiscChanged, [false,true,false,false])
        let restored = try Machine.restore(snapshot:data,rom:m.rom,resolveDisc:{$0.drive == 0 ? a:b})
        XCTAssertFalse(changed(restored)); XCTAssertEqual(restored.fdc.discChangeState,m.fdc.discChangeState)
        restored.fdc.latchAChanged(0xfd); XCTAssertTrue(changed(restored))
        // An old v2 header has no latch metadata. Its state body is unchanged.
        let n = Int(data[12]) | Int(data[13])<<8 | Int(data[14])<<16 | Int(data[15])<<24
        var fields = try JSONSerialization.jsonObject(with:Data(data[16..<16+n])) as! [String:Any]
        fields.removeValue(forKey:"floppyDiscChanged")
        let oldHeader = Array(try JSONSerialization.data(withJSONObject:fields,options:[.sortedKeys]))
        var writer = StateWriter(); writer.raw(Array(data.prefix(12))); writer.data(oldHeader); writer.raw(Array(data.dropFirst(16+n)))
        let old = try Machine.restore(snapshot:writer.bytes,rom:m.rom,resolveDisc:{$0.drive == 0 ? a:b})
        XCTAssertEqual(old.fdc.discChangeState,[false,false,false,false]); XCTAssertFalse(changed(old))
    }
}
