import Foundation

/// Hitachi HD63463 hard disc controller, as fitted to the Archimedes 400
/// series for ST506 drives. Behaviour follows the Hitachi datasheet; the
/// Acorn wiring is:
///
///  * 16-bit bus in IOC bank 5: write +&00 command, +&04 parameters; read
///    +&20 status (on D8-15), +&24 parameters. Parameters are big-endian.
///  * ADFS selects DMA mode, but there is no DMA controller: DREQ is wired
///    into the interrupt (IOC IRQ B bit 3, with the chip's own IRQ), and the
///    handler moves each 256-byte sector with "DACK" accesses (read +&08/&0C,
///    write +&28/&2C), two data bytes per word, first byte in D0-7.
///  * Drives answer as units 1 and 2.
///
/// Seeks complete at once; each sector takes about one 32nd of a 3600 rpm
/// revolution. Sector contents come from `HardDiscImage`s, addressed by the
/// logical cylinder, head and sector of each command (as standard formatting
/// writes them into the ID fields).
public final class HD63463 {
    // Status register bits.
    static let busy: UInt8 = 0x80, parameterRejection: UInt8 = 0x40, commandEnd: UInt8 = 0x20
    static let seekEnd: UInt8 = 0x10, driveError: UInt8 = 0x08, abnormalEnd: UInt8 = 0x04

    // Error codes (SSB).
    static let errAbort: UInt8 = 0x04, errInvalidCommand: UInt8 = 0x08, errNotSpecified: UInt8 = 0x10
    static let errNotReady: UInt8 = 0x20, errInvalidCylinder: UInt8 = 0x2C, errInvalidHead: UInt8 = 0x3C
    static let errTimeOver: UInt8 = 0x58

    /// Drive images for units 1 and 2.
    public var drives: [HardDiscImage?] = [nil, nil]
    public internal(set) var status: UInt8 = 0
    var ssb: UInt8 = 0
    var params = [UInt8](repeating: 0, count: 16)
    /// Reading results and writing parameters move separate pointers (ADFS
    /// reads the SSB after an Abort, then writes the next parameters from
    /// the start); each command resets both.
    var paramPointer = 0
    var writePointer = 0
    var buffer = [UInt8](repeating: 0, count: 256)
    var bufferPointer = 0
    var dataRequest = false

    // Specify.
    var specified = false
    var om1: UInt8 = 0
    var cul: UInt8 = 0
    var nc = 0, nh = 0, ns = 0

    var cylinder = [Int](repeating: 0, count: 4)

    // Command in progress.
    var command: UInt8 = 0
    var unit = 0, physicalHead = 0
    var logicalCylinder = 0, logicalHead = 0, logicalSector = 0
    var remaining = 0
    var awaitingFirstData = false

    unowned let scheduler: Scheduler
    unowned let ioc: IOC
    public var log: ((String) -> Void)?

    static let commandDelay = MasterClock.ticks(microseconds: 100)
    static let sectorTime = MasterClock.ticks(microseconds: 520)

    init(scheduler: Scheduler, ioc: IOC) {
        self.scheduler = scheduler
        self.ioc = ioc
        scheduler.setHandler(.hardDisc) { [unowned self] in self.event() }
    }

    func reset() {
        status = 0; ssb = 0; paramPointer = 0; writePointer = 0; bufferPointer = 0
        dataRequest = false; specified = false; om1 = 0; cul = 0
        scheduler.cancel(.hardDisc)
        updateInterrupt()
    }

    func image(unit u: Int) -> HardDiscImage? { (1...2).contains(u) ? drives[u - 1] : nil }

    // MARK: Bus

    func read(_ reg: UInt32) -> UInt32 {
        switch reg & 0x3C {
        case 0x20:
            return UInt32(status) << 8
        case 0x24:
            guard paramPointer < 16 else { return 0xFFFF }
            defer { paramPointer += 2 }
            return UInt32(params[paramPointer]) << 8 | UInt32(params[paramPointer + 1])
        case 0x08, 0x0C:
            guard dataRequest, bufferPointer < 256 else { return 0xFFFF }
            let w = UInt32(buffer[bufferPointer]) | UInt32(buffer[bufferPointer + 1]) << 8
            bufferPointer += 2
            if bufferPointer == 256 { sectorTransferred() }
            return w
        default:
            log?(String(format: "HDC read +%02X", reg))
            return 0xFFFF
        }
    }

    func write(_ reg: UInt32, _ v: UInt16) {
        switch reg & 0x3C {
        case 0x00:
            startCommand(UInt8(truncatingIfNeeded: v))
        case 0x04:
            guard writePointer < 16 else { return }
            params[writePointer] = UInt8(v >> 8)
            params[writePointer + 1] = UInt8(truncatingIfNeeded: v)
            writePointer += 2
        case 0x28, 0x2C:
            guard dataRequest, bufferPointer < 256 else { return }
            buffer[bufferPointer] = UInt8(truncatingIfNeeded: v)
            buffer[bufferPointer + 1] = UInt8(v >> 8)
            bufferPointer += 2
            if bufferPointer == 256 { sectorTransferred() }
        default:
            log?(String(format: "HDC write +%02X = %04X", reg, v))
        }
    }

    func updateInterrupt() {
        let pending = status & ~om1 & (Self.commandEnd | Self.seekEnd | Self.driveError) != 0
        ioc.setIRQB(IOC.irqBHardDisc, pending || dataRequest)
    }

    // MARK: Commands

    func startCommand(_ code: UInt8) {
        if status & Self.busy != 0 && code < 0xF0 { log?(String(format: "HDC command %02X while busy", code)); return }
        log?(String(format: "HDC command %02X params %@", code, params.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")))
        dataRequest = false
        command = code
        writePointer = 0
        paramPointer = 0
        if code != 0x08 && code < 0xF0 { ssb = 0 }
        switch code {
        case 0x08: // Recall: back to idle
            status = 0
            paramPointer = 0
        case 0x10, 0x18: // Polling on/off: seeks here have already ended
            status = 0
            paramPointer = 0
        case 0xE8:
            specify()
        case 0x28:
            checkDrive()
        case 0xC0, 0xC8:
            seek(recalibrate: code == 0xC8)
        case 0x40, 0x48, 0x87:
            beginTransfer()
        case 0xA3:
            beginFormat()
        case 0xF0...0xFF: // Abort
            scheduler.cancel(.hardDisc)
            status = (status & Self.parameterRejection) | Self.commandEnd
            ssb = Self.errAbort
            setResults([0, Self.errAbort])
        default:
            fail(Self.errInvalidCommand)
        }
        updateInterrupt()
    }

    /// Results replace the parameter block, read back from its start.
    func setResults(_ r: [UInt8]) {
        for i in 0..<16 { params[i] = i < r.count ? r[i] : 0 }
        paramPointer = 0
    }

    /// Error end: SSB, then the command's parameters as they stood.
    func fail(_ code: UInt8) {
        log?(String(format: "HDC command %02X error %02X", command, code))
        scheduler.cancel(.hardDisc)
        ssb = code
        dataRequest = false
        status = Self.abnormalEnd | Self.commandEnd
        setResults([0, code] + params.prefix(10))
        updateInterrupt()
    }

    func specify() {
        om1 = params[1]
        cul = params[3]
        nc = Int(params[4] & 3) << 8 | Int(params[5])
        nh = Int(params[6])
        ns = Int(params[7])
        specified = true
        status = Self.parameterRejection
        setResults([0, 0])
    }

    /// Validates US for a drive command; reports the error itself.
    func selectUnit() -> HardDiscImage? {
        guard specified else { fail(Self.errNotSpecified); return nil }
        unit = Int(params[0])
        guard let img = image(unit: unit), cul & (1 << UInt8(unit)) != 0 else { fail(Self.errNotReady); return nil }
        return img
    }

    var readyUnits: UInt8 {
        var v: UInt8 = 0
        for u in 1...2 where image(unit: u) != nil { v |= 1 << UInt8(u) }
        return v & cul
    }

    func checkDrive() {
        guard selectUnit() != nil else { return }
        let dst: UInt8 = 0xC0 | (cylinder[unit] == 0 ? 0x20 : 0) // READY, SCP, TRK0
        status = 0
        setResults([0, 0, UInt8(unit), 0, dst, 0])
    }

    func seek(recalibrate: Bool) {
        guard selectUnit() != nil else { return }
        let target = recalibrate ? 0 : Int(params[2] & 3) << 8 | Int(params[3])
        guard target <= nc else { fail(Self.errInvalidCylinder); return }
        cylinder[unit] = target
        status = Self.parameterRejection | Self.commandEnd | Self.seekEnd
        setResults([0, 0, UInt8(unit), readyUnits])
    }

    /// Read Data, Check Data, Write Data: US PHA LCAH LCAL LHA LSA SCNTH SCNTL.
    func beginTransfer() {
        guard selectUnit() != nil else { return }
        physicalHead = Int(params[1])
        guard physicalHead <= nh else { fail(Self.errInvalidHead); return }
        logicalCylinder = Int(params[2]) << 8 | Int(params[3])
        logicalHead = Int(params[4])
        logicalSector = Int(params[5])
        remaining = Int(params[6]) << 8 | Int(params[7])
        status = Self.parameterRejection | Self.busy
        awaitingFirstData = command == 0x87
        scheduler.schedule(.hardDisc, after: Self.commandDelay)
    }

    /// Write Format: US PHA SCNTH SCNTL; the ID list arrives as data.
    func beginFormat() {
        guard selectUnit() != nil else { return }
        physicalHead = Int(params[1])
        guard physicalHead <= nh else { fail(Self.errInvalidHead); return }
        logicalCylinder = cylinder[unit]
        logicalHead = physicalHead
        logicalSector = 0
        remaining = Int(params[2]) << 8 | Int(params[3])
        status = Self.parameterRejection | Self.busy
        awaitingFirstData = true
        scheduler.schedule(.hardDisc, after: Self.commandDelay)
    }

    func requestData() {
        bufferPointer = 0
        dataRequest = true
        updateInterrupt()
    }

    /// The host has moved a whole buffer through DACK.
    func sectorTransferred() {
        dataRequest = false
        updateInterrupt()
        scheduler.schedule(.hardDisc, after: Self.sectorTime)
    }

    func event() {
        guard let img = image(unit: unit) else { fail(Self.errNotReady); return }
        switch command {
        case 0x40, 0x48:
            if remaining == 0 { finishTransfer(); return }
            guard let data = img.read(cylinder: logicalCylinder, head: logicalHead, sector: logicalSector) else { fail(Self.errTimeOver); return }
            advance()
            if command == 0x40 {
                buffer = data
                requestData()
            } else {
                scheduler.schedule(.hardDisc, after: Self.sectorTime)
            }
        case 0x87:
            if awaitingFirstData {
                awaitingFirstData = false
                if remaining == 0 { finishTransfer() } else { requestData() }
                return
            }
            guard img.write(cylinder: logicalCylinder, head: logicalHead, sector: logicalSector, buffer) else { fail(Self.errTimeOver); return }
            advance()
            if remaining == 0 { finishTransfer() } else { requestData() }
        case 0xA3:
            if awaitingFirstData {
                awaitingFirstData = false
                if remaining == 0 { finishTransfer() } else { requestData() }
                return
            }
            // Each 4-byte ID (LCAH LCAL LHA LSA) formats one sector; the
            // data fields are written blank.
            let blank = [UInt8](repeating: 0, count: img.geometry.sectorSize)
            var i = 0
            while i < 256 && remaining > 0 {
                let sector = Int(buffer[i + 3])
                guard img.write(cylinder: logicalCylinder, head: physicalHead, sector: sector, blank) else { fail(Self.errTimeOver); return }
                remaining -= 1
                i += 4
            }
            if remaining == 0 { finishTransfer() } else { requestData() }
        default:
            break
        }
    }

    /// Past the last sector of a track the logical sector wraps and the head
    /// advances; the cylinder never changes by itself.
    func advance() {
        remaining -= 1
        logicalSector += 1
        if logicalSector > ns {
            logicalSector = 0
            logicalHead += 1
            physicalHead += 1
        }
    }

    func finishTransfer() {
        dataRequest = false
        status = Self.parameterRejection | Self.commandEnd
        let results: [UInt8]
        if command == 0xA3 {
            results = [0, 0, UInt8(unit), UInt8(physicalHead), UInt8(remaining >> 8), UInt8(truncatingIfNeeded: remaining)]
        } else {
            results = [0, 0, UInt8(unit), UInt8(physicalHead), UInt8(logicalCylinder >> 8), UInt8(truncatingIfNeeded: logicalCylinder),
                       UInt8(logicalHead), UInt8(logicalSector), UInt8(remaining >> 8), UInt8(truncatingIfNeeded: remaining)]
        }
        setResults(results)
        updateInterrupt()
    }

    // MARK: Snapshot

    func saveState(_ w: inout StateWriter) {
        w.u8(status); w.u8(ssb); w.raw(params); w.u32(UInt32(paramPointer)); w.u32(UInt32(writePointer))
        w.raw(buffer); w.u32(UInt32(bufferPointer)); w.bool(dataRequest)
        w.bool(specified); w.u8(om1); w.u8(cul)
        for v in [nc, nh, ns] + cylinder + [unit, physicalHead, logicalCylinder, logicalHead, logicalSector, remaining] { w.u32(UInt32(v)) }
        w.u8(command); w.bool(awaitingFirstData)
    }

    func loadState(_ r: inout StateReader) throws {
        status = try r.u8(); ssb = try r.u8(); params = try r.raw(16); paramPointer = Int(try r.u32()); writePointer = Int(try r.u32())
        buffer = try r.raw(256); bufferPointer = Int(try r.u32()); dataRequest = try r.bool()
        specified = try r.bool(); om1 = try r.u8(); cul = try r.u8()
        nc = Int(try r.u32()); nh = Int(try r.u32()); ns = Int(try r.u32())
        for i in 0..<4 { cylinder[i] = Int(try r.u32()) }
        unit = Int(try r.u32()); physicalHead = Int(try r.u32()); logicalCylinder = Int(try r.u32())
        logicalHead = Int(try r.u32()); logicalSector = Int(try r.u32()); remaining = Int(try r.u32())
        command = try r.u8(); awaitingFirstData = try r.bool()
    }
}
