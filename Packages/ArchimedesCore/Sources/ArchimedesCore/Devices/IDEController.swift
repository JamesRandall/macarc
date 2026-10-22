import Foundation

/// The AT (IDE) task file in the 82C711 of the A5000, A4000 and A3020, with
/// up to two drives. Programmed I/O only, as RISC OS 3.1's ADFS uses it:
/// the data port is 16 bits wide (IOC bank 1 +&7C0), the other registers
/// are bytes at PC port addresses &1F1-&1F7 and &3F6. INTRQ drives IOC IRQ B
/// bit 3. Drives use 512-byte sectors in CHS order, addressed through the
/// geometry the host sets with Initialise Device Parameters (or the drive's
/// own until it does).
public final class IDEController {
    // Status bits.
    static let busy: UInt8 = 0x80, ready: UInt8 = 0x40, seekComplete: UInt8 = 0x10
    static let dataRequest: UInt8 = 0x08, error: UInt8 = 0x01
    // Error bits.
    static let aborted: UInt8 = 0x04, idNotFound: UInt8 = 0x10

    public var drives: [HardDiscImage?] = [nil, nil]

    var features: UInt8 = 0, errorReg: UInt8 = 0
    var sectorCount: UInt8 = 0, sectorNumber: UInt8 = 0
    var cylinderLow: UInt8 = 0, cylinderHigh: UInt8 = 0
    var driveHead: UInt8 = 0xA0
    var status: UInt8 = 0
    var control: UInt8 = 0
    var interruptPending = false

    /// Logical geometry per drive (from Initialise Device Parameters).
    var logicalHeads = [0, 0], logicalSectors = [0, 0]

    var buffer = [UInt8](repeating: 0, count: 512)
    var bufferPointer = 0
    var command: UInt8 = 0
    var remaining = 0

    unowned let scheduler: Scheduler
    unowned let ioc: IOC
    public var log: ((String) -> Void)?

    static let sectorTime = MasterClock.ticks(microseconds: 200)
    static let commandTime = MasterClock.ticks(microseconds: 50)

    init(scheduler: Scheduler, ioc: IOC) {
        self.scheduler = scheduler
        self.ioc = ioc
        scheduler.setHandler(.ide) { [unowned self] in self.event() }
    }

    var unit: Int { Int(driveHead >> 4) & 1 }
    var image: HardDiscImage? { drives[unit] }

    func reset() {
        scheduler.cancel(.ide)
        errorReg = 1 // diagnostic code: no error
        sectorCount = 1; sectorNumber = 1; cylinderLow = 0; cylinderHigh = 0; driveHead = 0xA0
        status = image != nil ? Self.ready | Self.seekComplete : 0
        bufferPointer = 512
        for u in 0..<2 {
            logicalHeads[u] = drives[u]?.geometry.heads ?? 0
            logicalSectors[u] = drives[u]?.geometry.sectorsPerTrack ?? 0
        }
        setInterrupt(false)
    }

    func setInterrupt(_ on: Bool) {
        interruptPending = on
        ioc.setIRQB(IOC.irqBHardDisc, on && control & 0x02 == 0)
    }

    // MARK: Bus (PC port numbers)

    func read(port: Int) -> UInt8 {
        switch port {
        case 0x1F0: return UInt8(truncatingIfNeeded: readData())
        case 0x1F1: return errorReg
        case 0x1F2: return sectorCount
        case 0x1F3: return sectorNumber
        case 0x1F4: return cylinderLow
        case 0x1F5: return cylinderHigh
        case 0x1F6: return driveHead
        case 0x1F7:
            setInterrupt(false)
            return image == nil ? 0 : status
        case 0x3F6: return image == nil ? 0 : status
        default: return 0xFF
        }
    }

    func write(port: Int, _ v: UInt8) {
        switch port {
        case 0x1F0: writeData(UInt16(v))
        case 0x1F1: features = v
        case 0x1F2: sectorCount = v
        case 0x1F3: sectorNumber = v
        case 0x1F4: cylinderLow = v
        case 0x1F5: cylinderHigh = v
        case 0x1F6: driveHead = v | 0xA0
        case 0x1F7: start(v)
        case 0x3F6:
            if v & 0x04 != 0 && control & 0x04 == 0 { reset() }
            control = v
            setInterrupt(interruptPending)
        default: break
        }
    }

    /// The 16-bit data port: two bytes per access, first byte in D0-7.
    func readData() -> UInt16 {
        guard status & Self.dataRequest != 0, bufferPointer < 512 else { return 0xFFFF }
        let w = UInt16(buffer[bufferPointer]) | UInt16(buffer[bufferPointer + 1]) << 8
        bufferPointer += 2
        if bufferPointer == 512 { bufferEmptied() }
        return w
    }

    func writeData(_ w: UInt16) {
        guard status & Self.dataRequest != 0, bufferPointer < 512 else { return }
        buffer[bufferPointer] = UInt8(truncatingIfNeeded: w)
        buffer[bufferPointer + 1] = UInt8(w >> 8)
        bufferPointer += 2
        if bufferPointer == 512 { bufferFilled() }
    }

    // MARK: Commands

    var cylinder: Int { Int(cylinderHigh) << 8 | Int(cylinderLow) }

    /// The current task-file address as a physical sector, or nil.
    func currentSector() -> (Int, Int, Int)? {
        guard let img = image else { return nil }
        let heads = logicalHeads[unit], spt = logicalSectors[unit]
        let s = Int(sectorNumber)
        guard heads > 0, spt > 0, s >= 1, s <= spt, Int(driveHead & 0x0F) < heads else { return nil }
        let lba = (cylinder * heads + Int(driveHead & 0x0F)) * spt + s - 1
        let g = img.geometry
        guard lba < g.sectorCount else { return nil }
        return (lba / (g.heads * g.sectorsPerTrack), (lba / g.sectorsPerTrack) % g.heads, lba % g.sectorsPerTrack)
    }

    /// Steps the task file to the next sector (sector, then head, then cylinder).
    func advance() {
        let heads = logicalHeads[unit], spt = logicalSectors[unit]
        if Int(sectorNumber) < spt { sectorNumber += 1; return }
        sectorNumber = 1
        if Int(driveHead & 0x0F) + 1 < heads {
            driveHead = (driveHead & 0xF0) | ((driveHead + 1) & 0x0F)
        } else {
            driveHead &= 0xF0
            let c = cylinder + 1
            cylinderLow = UInt8(c & 0xFF); cylinderHigh = UInt8((c >> 8) & 0xFF)
        }
    }

    func start(_ code: UInt8) {
        guard image != nil else { return }
        log?(String(format: "IDE command %02X drive %d CHS %d/%d/%d count %d", code, unit, cylinder, driveHead & 0x0F, sectorNumber, sectorCount))
        command = code
        errorReg = 0
        setInterrupt(false)
        remaining = sectorCount == 0 ? 256 : Int(sectorCount)
        status = Self.busy
        scheduler.schedule(.ide, after: Self.commandTime)
    }

    func finish(error: UInt8 = 0) {
        errorReg = error
        status = Self.ready | Self.seekComplete | (error != 0 ? Self.error : 0)
        setInterrupt(true)
    }

    func event() {
        guard let img = image else { return }
        switch command {
        case 0x20, 0x21: // Read Sectors
            guard let (c, h, s) = currentSector(), let data = img.read(cylinder: c, head: h, sector: s) else { finish(error: Self.idNotFound); return }
            buffer = data
            bufferPointer = 0
            status = Self.ready | Self.seekComplete | Self.dataRequest
            setInterrupt(true)
        case 0x30, 0x31: // Write Sectors: ask for the first sector's data
            bufferPointer = 0
            status = Self.ready | Self.seekComplete | Self.dataRequest
        case 0x50: // Format Track: a sector's worth of interleave table, then blank sectors
            bufferPointer = 0
            status = Self.ready | Self.seekComplete | Self.dataRequest
        case 0x40, 0x41: // Read Verify
            for _ in 0..<remaining {
                guard currentSector() != nil else { finish(error: Self.idNotFound); return }
                advance()
            }
            finish()
        case 0x10...0x1F: // Recalibrate
            cylinderLow = 0; cylinderHigh = 0
            finish()
        case 0x70...0x7F: // Seek
            finish(error: cylinder < img.geometry.cylinders ? 0 : Self.idNotFound)
        case 0x90: // Execute Device Diagnostic
            errorReg = 1
            status = Self.ready | Self.seekComplete
            setInterrupt(true)
        case 0x91: // Initialise Device Parameters
            logicalHeads[unit] = Int(driveHead & 0x0F) + 1
            logicalSectors[unit] = Int(sectorCount)
            finish()
        case 0xEC: // Identify Device
            buffer = identify(img)
            bufferPointer = 0
            status = Self.ready | Self.seekComplete | Self.dataRequest
            setInterrupt(true)
        case 0xE0...0xE5, 0xEF, 0xC6: // power management, set features, set multiple
            finish()
        default:
            finish(error: Self.aborted)
        }
    }

    /// The host has read the whole buffer.
    func bufferEmptied() {
        status &= ~Self.dataRequest
        guard command == 0x20 || command == 0x21 else { status = Self.ready | Self.seekComplete; return }
        remaining -= 1
        advance()
        if remaining == 0 {
            status = Self.ready | Self.seekComplete
        } else {
            status = Self.busy
            scheduler.schedule(.ide, after: Self.sectorTime)
        }
    }

    /// The host has written a whole sector.
    func bufferFilled() {
        guard let img = image else { return }
        status = Self.busy
        if command == 0x50 {
            // Format: every sector of the addressed track becomes blank.
            let blank = [UInt8](repeating: 0, count: img.geometry.sectorSize)
            sectorNumber = 1
            for _ in 0..<max(1, logicalSectors[unit]) {
                if let (c, h, s) = currentSector() { img.write(cylinder: c, head: h, sector: s, blank) }
                if Int(sectorNumber) < logicalSectors[unit] { sectorNumber += 1 }
            }
            finish()
            return
        }
        guard let (c, h, s) = currentSector(), img.write(cylinder: c, head: h, sector: s, buffer) else { finish(error: Self.idNotFound); return }
        remaining -= 1
        advance()
        if remaining == 0 {
            finish()
        } else {
            bufferPointer = 0
            status = Self.ready | Self.seekComplete | Self.dataRequest
            setInterrupt(true)
        }
    }

    /// The IDENTIFY DEVICE block: geometry, capacity and model name.
    func identify(_ img: HardDiscImage) -> [UInt8] {
        var w = [UInt16](repeating: 0, count: 256)
        let g = img.geometry
        w[0] = 0x0040 // fixed drive
        w[1] = UInt16(g.cylinders); w[3] = UInt16(g.heads); w[6] = UInt16(g.sectorsPerTrack)
        w[4] = UInt16(512 * g.sectorsPerTrack); w[5] = 512
        func text(_ s: String, at first: Int, words: Int) {
            let b = Array(s.utf8) + [UInt8](repeating: 0x20, count: max(0, words * 2 - s.utf8.count))
            for i in 0..<words { w[first + i] = UInt16(b[2 * i]) << 8 | UInt16(b[2 * i + 1]) }
        }
        text("MACARCH0001", at: 10, words: 10)
        text("1.0", at: 23, words: 4)
        text("MacArch IDE hard disc", at: 27, words: 20)
        w[47] = 0x8001
        w[49] = 0x0000 // no DMA, no LBA
        w[54] = UInt16(g.cylinders); w[55] = UInt16(g.heads); w[56] = UInt16(g.sectorsPerTrack)
        let sectors = UInt32(g.sectorCount)
        w[57] = UInt16(sectors & 0xFFFF); w[58] = UInt16(sectors >> 16)
        return w.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
    }

    // MARK: Snapshot

    func saveState(_ wr: inout StateWriter) {
        for v in [features, errorReg, sectorCount, sectorNumber, cylinderLow, cylinderHigh, driveHead, status, control, command] { wr.u8(v) }
        wr.bool(interruptPending)
        for v in logicalHeads + logicalSectors + [bufferPointer, remaining] { wr.u32(UInt32(v)) }
        wr.raw(buffer)
    }

    func loadState(_ r: inout StateReader) throws {
        features = try r.u8(); errorReg = try r.u8(); sectorCount = try r.u8(); sectorNumber = try r.u8()
        cylinderLow = try r.u8(); cylinderHigh = try r.u8(); driveHead = try r.u8(); status = try r.u8()
        control = try r.u8(); command = try r.u8()
        interruptPending = try r.bool()
        logicalHeads = [Int(try r.u32()), Int(try r.u32())]
        logicalSectors = [Int(try r.u32()), Int(try r.u32())]
        bufferPointer = Int(try r.u32()); remaining = Int(try r.u32())
        buffer = try r.raw(512)
    }
}
