import Foundation

/// Western Digital WD1772 floppy disc controller with the A3000 drive
/// interface (drive/side/motor from IOC latch A, density/reset from latch B).
/// DRQ and INTRQ are wired to IOC FIQ status bits 0 and 1.
public final class WD1772 {
    public struct Drive {
        public var disc: FloppyImage?
        public var headTrack = 0
    }

    public enum Command: String, Sendable {
        case idle, restore, seek, step, stepIn, stepOut, readSector, writeSector, readAddress, readTrack, writeTrack
    }

    public struct TraceEvent: Sendable, CustomStringConvertible {
        public var tick: UInt64
        public var pc: UInt32
        public var text: String
        public var description: String { String(format: "%012llu pc=%07X ", tick, pc) + text }
    }

    public var drives = [Drive(), Drive(), Drive(), Drive()]
    public private(set) var selectedDrive: Int? = 0
    public private(set) var side = 0
    public private(set) var doubleDensity = true

    public private(set) var status: UInt8 = 0
    public private(set) var trackRegister: UInt8 = 0
    public private(set) var sectorRegister: UInt8 = 1
    public private(set) var dataRegister: UInt8 = 0
    var commandRegister: UInt8 = 0
    public private(set) var command: Command = .idle
    var stepDirection = 1
    var typeI = true

    var motorOn = false
    /// Drive activity light (A3000: lit while the drive is selected and its motor runs).
    public func light(drive d: Int) -> Bool { motorOn && selectedDrive == d }
    var motorIdleRevolutions = 0
    var busy: Bool { status & 1 != 0 }

    // Transfer state
    var buffer: [UInt8] = []
    var bufferIndex = 0
    var phase = 0
    var drq = false
    var intrq = false
    /// ID field matched by the current Read/Write Sector.
    var currentSector: SectorHeader?

    unowned(unsafe) let scheduler: Scheduler
    unowned(unsafe) let ioc: IOC
    public var trace = RingBuffer<TraceEvent>(capacity: 512)
    public var traceEnabled = true
    var currentPC: () -> UInt32 = { 0 }
    public private(set) var commandCount: UInt64 = 0

    static let byteTicks = MasterClock.ticks(microseconds: 32)        // 250 kbit/s MFM
    static let revolutionTicks = MasterClock.ticks(milliseconds: 200) // 300 rpm
    static let stepRatesMs: [UInt64] = [6, 12, 2, 3]

    init(scheduler: Scheduler, ioc: IOC) {
        self.scheduler = scheduler
        self.ioc = ioc
        scheduler.setHandler(.floppy) { [unowned self] in self.event() }
        status = 0x04
    }

    var drive: Drive? {
        guard let d = selectedDrive else { return nil }
        return drives[d]
    }

    var disc: FloppyImage? { drive?.disc }

    func log(_ s: String) {
        guard traceEnabled else { return }
        trace.append(TraceEvent(tick: scheduler.now, pc: currentPC(), text: s))
    }

    // MARK: Lines

    func setDRQ(_ on: Bool) {
        drq = on
        if on { status |= 0x02 } else { status &= ~0x02 }
        ioc.setFloppyDRQ(on)
    }

    func setINTRQ(_ on: Bool) {
        intrq = on
        ioc.setFloppyIRQ(on)
    }

    // MARK: Latches

    func latchAChanged(_ v: UInt8) {
        let sel = ~v & 0x0F
        selectedDrive = sel == 0 ? nil : sel.trailingZeroBitCount
        side = (v & 0x10) == 0 ? 1 : 0
    }

    func latchBChanged(_ v: UInt8) {
        doubleDensity = (v & 0x02) == 0
        if v & 0x08 == 0 { log(String(format: "master reset (latch B %02X)", v)); masterReset() }
    }

    func masterReset() {
        scheduler.cancel(.floppy)
        command = .idle
        status = 0
        commandRegister = 0
        sectorRegister = 1
        setDRQ(false)
        setINTRQ(false)
        typeI = true
    }

    // MARK: Register interface

    func read(_ reg: Int) -> UInt8 {
        switch reg {
        case 0:
            setINTRQ(false)
            return statusValue()
        case 1: return trackRegister
        case 2: return sectorRegister
        default:
            setDRQ(false)
            return dataRegister
        }
    }

    func statusValue() -> UInt8 {
        var s = status
        if motorOn { s |= 0x80 } else { s &= ~0x80 }
        if typeI {
            s &= ~0x46
            if let d = drive {
                if d.headTrack == 0 { s |= 0x04 }
                if d.disc?.writeProtected == true { s |= 0x40 }
                if d.disc != nil && motorOn && (scheduler.now % Self.revolutionTicks) < MasterClock.ticks(milliseconds: 4) { s |= 0x02 }
            }
        }
        return s
    }

    func write(_ reg: Int, _ v: UInt8) {
        switch reg {
        case 0: writeCommand(v)
        case 1: if !busy { trackRegister = v }
        case 2: if !busy { sectorRegister = v }
        default:
            dataRegister = v
            setDRQ(false)
        }
    }

    func writeCommand(_ v: UInt8) {
        if v & 0xF0 == 0xD0 {
            forceInterrupt(v)
            return
        }
        if busy { log(String(format: "command %02X ignored while busy", v)); return }
        commandCount &+= 1
        commandRegister = v
        setINTRQ(false)
        setDRQ(false)
        status = 0x01
        motorIdleRevolutions = 0
        let spinUp = !motorOn && (v & 0x08) == 0
        motorOn = true
        phase = 0
        switch v >> 4 {
        case 0x0: command = .restore; typeI = true
        case 0x1: command = .seek; typeI = true
        case 0x2, 0x3: command = .step; typeI = true
        case 0x4, 0x5: command = .stepIn; typeI = true
        case 0x6, 0x7: command = .stepOut; typeI = true
        case 0x8, 0x9: command = .readSector; typeI = false
        case 0xA, 0xB: command = .writeSector; typeI = false
        case 0xC: command = .readAddress; typeI = false
        case 0xE: command = .readTrack; typeI = false
        default: command = .writeTrack; typeI = false
        }
        log(String(format: "cmd %02X %@ drive=%@ side=%d trk=%d sec=%d data=%d head=%d", v, command.rawValue,
                   selectedDrive.map { String($0) } ?? "none", side, trackRegister, sectorRegister, dataRegister,
                   drive?.headTrack ?? -1))
        let delay = spinUp ? 6 * Self.revolutionTicks : MasterClock.ticks(microseconds: 48)
        scheduler.schedule(.floppy, after: delay)
    }

    func forceInterrupt(_ v: UInt8) {
        log(String(format: "force interrupt %02X (busy=%d)", v, busy ? 1 : 0))
        let wasBusy = busy
        scheduler.cancel(.floppy)
        status &= ~0x01
        setDRQ(false)
        if !wasBusy { typeI = true }
        command = .idle
        if v & 0x08 != 0 { setINTRQ(true) }
        scheduleMotorOff()
    }

    // MARK: Command execution

    func finish(_ extra: UInt8 = 0) {
        status = (status & ~0x01) | extra
        setDRQ(false)
        setINTRQ(true)
        log(String(format: "done %@ status=%02X", command.rawValue, statusValue()))
        command = .idle
        scheduleMotorOff()
    }

    func scheduleMotorOff() {
        // Motor turns off after 9 idle revolutions.
        phase = -1
        scheduler.schedule(.floppy, after: 9 * Self.revolutionTicks)
    }

    var stepTicks: UInt64 { MasterClock.ticks(milliseconds: Self.stepRatesMs[Int(commandRegister & 3)]) }

    func event() {
        switch command {
        case .idle:
            if phase == -1 { motorOn = false }
        case .restore, .seek, .step, .stepIn, .stepOut:
            typeIEvent()
        case .readSector, .writeSector:
            sectorEvent()
        case .readAddress:
            readAddressEvent()
        case .readTrack:
            readTrackEvent()
        case .writeTrack:
            writeTrackEvent()
        }
    }

    func typeIEvent() {
        if phase == 0 {
            status |= 0x20 // spin-up complete
            switch command {
            case .restore:
                trackRegister = 0xFF; dataRegister = 0; phase = 1
            case .seek: phase = 1
            case .stepIn: stepDirection = 1; phase = 2
            case .stepOut: stepDirection = -1; phase = 2
            default: phase = 2
            }
        }
        if phase == 1 {
            // Seek loop: compare track and data registers.
            if trackRegister == dataRegister { phase = 3 } else {
                stepDirection = dataRegister > trackRegister ? 1 : -1
                if command == .restore, let d = drive, d.headTrack == 0 {
                    trackRegister = 0
                    phase = 3
                } else {
                    trackRegister = UInt8(truncatingIfNeeded: Int(trackRegister) + stepDirection)
                    stepHead()
                    scheduler.schedule(.floppy, after: stepTicks)
                    return
                }
            }
        }
        if phase == 2 {
            // Single step (Step/Step-in/Step-out): update track register if u flag.
            if commandRegister & 0x10 != 0 { trackRegister = UInt8(truncatingIfNeeded: Int(trackRegister) + stepDirection) }
            stepHead()
            phase = 3
            scheduler.schedule(.floppy, after: stepTicks)
            return
        }
        if phase == 3 {
            if commandRegister & 0x04 != 0 {
                phase = 4
                scheduler.schedule(.floppy, after: MasterClock.ticks(milliseconds: 15))
                return
            }
            finish()
            return
        }
        if phase == 4 {
            var extra: UInt8 = 0
            if let d = drive, d.disc != nil {
                // Verify: an ID field on this track must carry the track register's value.
                if !visibleHeaders().contains(where: { $0.cylinder == trackRegister && !$0.idCRCError }) { extra |= 0x10 }
            } else {
                extra |= 0x10
            }
            finish(extra)
        }
    }

    func stepHead() {
        guard let d = selectedDrive else { return }
        var t = drives[d].headTrack + stepDirection
        if t < 0 { t = 0 }
        if t > 83 { t = 83 }
        drives[d].headTrack = t
    }

    /// Ticks until the start of the given sector passes the head.
    func rotationalDelay(toSectorIndex idx: Int, sectorsPerTrack spt: Int) -> UInt64 {
        let rev = Self.revolutionTicks
        let pos = scheduler.now % rev
        let target = UInt64(idx) * rev / UInt64(max(1, spt))
        return target >= pos ? (target - pos) + 1 : (rev - pos + target) + 1
    }

    /// Ticks until the given fraction of a revolution passes the head.
    func rotationalDelay(toPosition p: Double) -> UInt64 {
        let rev = Self.revolutionTicks
        let pos = scheduler.now % rev
        let target = UInt64(p * Double(rev)) % rev
        return target >= pos ? (target - pos) + 1 : (rev - pos + target) + 1
    }

    /// ID fields the controller can read on the current track at its density.
    func visibleHeaders() -> [SectorHeader] {
        guard let d = drive, let disc = d.disc else { return [] }
        return disc.layout(side: side, track: d.headTrack).filter { $0.doubleDensity == doubleDensity }
    }

    /// The next ID field satisfying `match` to pass the head, with its delay.
    func nextHeader(where match: (SectorHeader) -> Bool) -> (SectorHeader, UInt64)? {
        visibleHeaders().filter(match).map { ($0, rotationalDelay(toPosition: $0.position)) }.min { $0.1 < $1.1 }
    }

    func sectorEvent() {
        switch phase {
        case 0:
            if commandRegister & 0x04 != 0 {
                phase = 1
                scheduler.schedule(.floppy, after: MasterClock.ticks(milliseconds: 15))
                return
            }
            fallthrough
        case 1:
            if command == .writeSector, disc?.writeProtected == true {
                status |= 0x40
                finish()
                return
            }
            // The ID field must match both the track and sector registers.
            let matches: (SectorHeader) -> Bool = { $0.cylinder == self.trackRegister && $0.id == self.sectorRegister }
            // JFD images omit sectors the imager could not read. Holed Out
            // saves a file into one (track 14 side 1 sector 4), so on the
            // original it was writable: a write to a missing standard sector
            // on a formatted track creates it in the copy-on-write overlay.
            if command == .writeSector, let d = drive, let disc = d.disc, trackRegister == UInt8(d.headTrack),
               sectorRegister < 5, !visibleHeaders().contains(where: matches) {
                _ = disc.addSector(side: side, track: d.headTrack, id: sectorRegister)
                log(String(format: "created sector side=%d trk=%d sec=%d", side, trackRegister, sectorRegister))
            }
            guard let (h, delay) = nextHeader(where: { matches($0) && !$0.idCRCError }) else {
                // Record not found after searching for 5 revolutions; a
                // matching ID with a bad CRC also reports a CRC error.
                if visibleHeaders().contains(where: matches) { status |= 0x08 }
                log(String(format: "RNF side=%d trk=%d sec=%d head=%d", side, trackRegister, sectorRegister, drive?.headTrack ?? -1))
                phase = 9
                scheduler.schedule(.floppy, after: 5 * Self.revolutionTicks)
                return
            }
            currentSector = h
            phase = 2
            scheduler.schedule(.floppy, after: delay)
        case 2:
            guard let disc, let h = currentSector else { phase = 9; event(); return }
            if command == .readSector {
                buffer = disc.readData(h)
                bufferIndex = 0
                phase = 3
                scheduler.schedule(.floppy, after: Self.byteTicks)
            } else {
                buffer = []
                bufferIndex = 0
                setDRQ(true) // first byte must be supplied before the data mark
                phase = 5
                scheduler.schedule(.floppy, after: 11 * Self.byteTicks)
            }
        case 3:
            // Read: deliver one byte per byte time.
            if drq { status |= 0x04 } // lost data
            dataRegister = buffer[bufferIndex]
            bufferIndex += 1
            setDRQ(true)
            if bufferIndex < buffer.count {
                scheduler.schedule(.floppy, after: Self.byteTicks)
            } else {
                phase = 4
                scheduler.schedule(.floppy, after: 3 * Self.byteTicks)
            }
        case 4:
            if command == .readSector, currentSector?.dataCRCError == true {
                // Data field CRC error terminates the command.
                finish(0x08)
                return
            }
            if commandRegister & 0x10 != 0 {
                // Multiple sectors: continue with the next sector ID.
                sectorRegister &+= 1
                phase = 1
                event()
            } else {
                status &= ~0x01
                setINTRQ(true)
                log(String(format: "done %@ status=%02X", command.rawValue, statusValue()))
                command = .idle
                scheduleMotorOff()
            }
        case 5:
            if drq {
                status |= 0x04
                finish()
                return
            }
            buffer.append(dataRegister)
            setDRQ(true)
            phase = 7
            scheduler.schedule(.floppy, after: Self.byteTicks)
        case 7:
            if drq { status |= 0x04; buffer.append(0) } else { buffer.append(dataRegister) }
            let size = currentSector?.size ?? 1024
            if buffer.count < size {
                setDRQ(true)
                scheduler.schedule(.floppy, after: Self.byteTicks)
            } else {
                setDRQ(false)
                if let disc, let h = currentSector { disc.writeData(h, buffer) }
                phase = 4
                scheduler.schedule(.floppy, after: 3 * Self.byteTicks)
            }
        default:
            finish(0x10)
        }
    }

    func readAddressEvent() {
        switch phase {
        case 0:
            // Next ID field to pass under the head; none on an unformatted
            // track gives Record Not Found after 6 index pulses.
            guard let (h, delay) = nextHeader(where: { _ in true }) else {
                phase = 9
                scheduler.schedule(.floppy, after: 6 * Self.revolutionTicks)
                return
            }
            let header: [UInt8] = [h.cylinder, h.head, h.id, h.sizeCode]
            var crc = CRC16.ccitt([0xA1, 0xA1, 0xA1, 0xFE] + header)
            if h.idCRCError { crc ^= 0xFFFF; status |= 0x08 }
            buffer = header + [UInt8(crc >> 8), UInt8(crc & 0xFF)]
            bufferIndex = 0
            phase = 1
            scheduler.schedule(.floppy, after: delay)
        case 1:
            if drq { status |= 0x04 }
            dataRegister = buffer[bufferIndex]
            bufferIndex += 1
            setDRQ(true)
            if bufferIndex < buffer.count {
                scheduler.schedule(.floppy, after: Self.byteTicks)
            } else {
                // The track address is copied into the sector register.
                sectorRegister = buffer[0]
                phase = 2
                scheduler.schedule(.floppy, after: Self.byteTicks)
            }
        case 2:
            finish()
        default:
            finish(0x10)
        }
    }

    func readTrackEvent() {
        switch phase {
        case 0:
            buffer = synthesizeTrack()
            bufferIndex = 0
            phase = 1
            scheduler.schedule(.floppy, after: rotationalDelay(toSectorIndex: 0, sectorsPerTrack: 1))
        case 1:
            if drq { status |= 0x04 }
            dataRegister = bufferIndex < buffer.count ? buffer[bufferIndex] : 0x4E
            bufferIndex += 1
            setDRQ(true)
            if bufferIndex < 6250 { scheduler.schedule(.floppy, after: Self.byteTicks) } else { phase = 2; scheduler.schedule(.floppy, after: Self.byteTicks) }
        default:
            finish()
        }
    }

    func writeTrackEvent() {
        switch phase {
        case 0:
            if disc?.writeProtected ?? true {
                if disc != nil { status |= 0x40 }
                finish()
                return
            }
            buffer = []
            setDRQ(true)
            phase = 1
            scheduler.schedule(.floppy, after: rotationalDelay(toSectorIndex: 0, sectorsPerTrack: 1) + 3 * Self.byteTicks)
        case 1:
            if drq { status |= 0x04; finish(); return }
            phase = 2
            fallthrough
        case 2:
            buffer.append(drq ? 0x4E : dataRegister)
            if buffer.count < 6250 {
                setDRQ(true)
                scheduler.schedule(.floppy, after: Self.byteTicks)
            } else {
                applyFormattedTrack(buffer)
                finish()
            }
        default:
            finish()
        }
    }

    /// Build an approximate MFM track byte stream (gaps, ID fields, data fields).
    func synthesizeTrack() -> [UInt8] {
        guard let disc else { return [] }
        let headers = visibleHeaders()
        // An unformatted track reads back as noise-free gap bytes.
        guard !headers.isEmpty else { return [] }
        var t: [UInt8] = Array(repeating: 0x4E, count: 60)
        for h in headers {
            // Pad with gap bytes up to the sector's recorded position.
            let start = Int(h.position * 6250) - 12
            if start > t.count { t += Array(repeating: 0x4E, count: start - t.count) }
            let id: [UInt8] = [0xA1, 0xA1, 0xA1, 0xFE, h.cylinder, h.head, h.id, h.sizeCode]
            var crc = CRC16.ccitt(id)
            if h.idCRCError { crc ^= 0xFFFF }
            t += Array(repeating: 0x00, count: 12) + id + [UInt8(crc >> 8), UInt8(crc & 0xFF)]
            t += Array(repeating: 0x4E, count: 22) + Array(repeating: 0x00, count: 12)
            let data = disc.readData(h)
            var dcrc = CRC16.ccitt([0xA1, 0xA1, 0xA1, 0xFB] + data)
            if h.dataCRCError { dcrc ^= 0xFFFF }
            t += [0xA1, 0xA1, 0xA1, 0xFB] + data + [UInt8(dcrc >> 8), UInt8(dcrc & 0xFF)] + Array(repeating: 0x4E, count: 24)
        }
        return t
    }

    /// Interpret a Write Track (format) stream: F5 writes A1 sync, F7 writes CRC.
    func applyFormattedTrack(_ s: [UInt8]) {
        guard let d = drive, let disc = d.disc else { return }
        var i = 0
        var pendingID: Int?
        let size = disc.geometry.sectorSize
        while i < s.count {
            if s[i] == 0xFE && i + 4 < s.count {
                pendingID = Int(s[i + 3])
                i += 5
            } else if (s[i] == 0xFB || s[i] == 0xF8), let id = pendingID, i + size < s.count {
                disc.writeSector(side: side, track: d.headTrack, sectorID: id, data: Array(s[(i + 1)...(i + size)]))
                pendingID = nil
                i += size + 1
            } else {
                i += 1
            }
        }
        log("format track \(d.headTrack) side \(side)")
    }
}

public enum CRC16 {
    public static func ccitt(_ data: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in data {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }
}

// MARK: - Snapshot state

extension WD1772 {
    func saveState(_ w: inout StateWriter) {
        for d in drives {
            w.i64(d.headTrack)
            w.bool(d.disc != nil)
            d.disc?.saveChanges(&w)
        }
        w.i64(selectedDrive ?? -1); w.i64(side); w.bool(doubleDensity)
        for v in [status, trackRegister, sectorRegister, dataRegister, commandRegister] { w.u8(v) }
        w.string(command.rawValue); w.i64(stepDirection); w.bool(typeI)
        w.bool(motorOn); w.i64(motorIdleRevolutions)
        w.data(buffer); w.i64(bufferIndex); w.i64(phase); w.bool(drq); w.bool(intrq)
        w.bool(currentSector != nil); currentSector?.save(&w)
        w.u64(commandCount)
    }

    func loadState(_ r: inout StateReader) throws {
        for i in 0..<4 {
            drives[i].headTrack = try r.i64()
            let present = try r.bool()
            guard present == (drives[i].disc != nil) else { throw SnapshotError.corrupt("drive \(i) media does not match the header") }
            try drives[i].disc?.loadChanges(&r)
        }
        let sel = try r.i64(); selectedDrive = sel < 0 ? nil : sel
        side = try r.i64(); doubleDensity = try r.bool()
        status = try r.u8(); trackRegister = try r.u8(); sectorRegister = try r.u8(); dataRegister = try r.u8(); commandRegister = try r.u8()
        guard let c = Command(rawValue: try r.string()) else { throw SnapshotError.corrupt("floppy command") }
        command = c; stepDirection = try r.i64(); typeI = try r.bool()
        motorOn = try r.bool(); motorIdleRevolutions = try r.i64()
        buffer = try r.data(max: 16384); bufferIndex = try r.i64(); phase = try r.i64(); drq = try r.bool(); intrq = try r.bool()
        currentSector = try r.bool() ? try SectorHeader.load(&r) : nil
        commandCount = try r.u64()
    }
}
