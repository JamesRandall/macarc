import Foundation

/// The floppy controller in the 82C711 (a µPD765 / 82077-compatible core)
/// as wired in the A5000, A4000, A3010 and A3020: registers at PC ports
/// &3F2-&3F7 in IOC bank 1, INT on IOC IRQ B bit 4, DRQ on FIQ bit 0, and
/// data moved by the FIQ handler through the DACK range &3012000-&302A000,
/// where an access at &302A000 also asserts terminal count.
///
/// Sector timing is simplified: an ID field is found after the rotational
/// delay to it, then each byte is requested once the previous one has been
/// taken and a byte time has passed, so there are no overruns.
public final class FDC765 {
    /// The drives (and their discs) belong to the machine's floppy interface,
    /// shared with the WD1772 so inserting and ejecting work the same.
    unowned(unsafe) let wd: WD1772
    var drives: [WD1772.Drive] {
        get { wd.drives }
        set { wd.drives = newValue }
    }

    var dor: UInt8 = 0
    /// Milliseconds a step, from Specify's step rate (at 500 kbit/s).
    var stepMs = 3
    /// Motor and head movements, for the drives' noises.
    var driveEvent: ((Int, DiscDriveEvent) -> Void)?
    var dataRate: UInt8 = 2
    /// Bytes of the command being collected.
    var commandBytes: [UInt8] = []
    var results: [UInt8] = []
    var resultIndex = 0
    enum Phase: UInt8 { case command, execution, result }
    var phase = Phase.command
    /// Seek/recalibrate/reset completions waiting for Sense Interrupt Status.
    var pendingSense: [(st0: UInt8, pcn: UInt8)] = []
    var interrupt = false
    var dataRequest = false
    var terminalCount = false

    // Transfer in progress.
    var unit = 0, head = 0
    var c: UInt8 = 0, h: UInt8 = 0, r: UInt8 = 0, n: UInt8 = 0, eot: UInt8 = 0
    var multiTrack = false
    var buffer: [UInt8] = []
    var bufferIndex = 0
    var current: SectorHeader?
    var fillByte: UInt8 = 0
    var formatSectors = 0

    unowned(unsafe) let scheduler: Scheduler
    unowned(unsafe) let ioc: IOC
    public var log: ((String) -> Void)?

    static let revolutionTicks = WD1772.revolutionTicks

    init(scheduler: Scheduler, ioc: IOC, drives wd: WD1772) {
        self.scheduler = scheduler
        self.ioc = ioc
        self.wd = wd
        scheduler.setHandler(.fdc765) { [unowned self] in self.event() }
        scheduler.setHandler(.fdcIndex) { [unowned self] in self.indexPulse() }
    }

    var byteTicks: UInt64 { MasterClock.ticks(microseconds: dataRate == 0 ? 16 : dataRate == 1 ? 27 : 32) }
    var motorOn: Bool { dor & 0xF0 != 0 }
    public func light(drive d: Int) -> Bool { dor & (0x10 << UInt8(d)) != 0 }

    func reset() {
        scheduler.cancel(.fdc765)
        job = .none
        phase = .command; commandBytes = []; results = []; resultIndex = 0
        dataRequest = false; terminalCount = false
        updateLines()
        // Leaving reset reports a ready change on each drive (polling).
        pendingSense = (0..<4).map { (0xC0 | UInt8($0), UInt8(drives[$0].headTrack)) }
        setInterrupt(true)
    }

    func setInterrupt(_ on: Bool) { interrupt = on; updateLines() }

    /// The selected drive's index hole, once a revolution while its motor
    /// runs, on IOC IRQ A bit 2 (ADFS uses it to tell whether a disc is in).
    func updateIndex() {
        if dor & (0x10 << (dor & 3)) != 0 {
            if !scheduler.isScheduled(.fdcIndex) {
                let rev = Self.revolutionTicks
                scheduler.schedule(.fdcIndex, after: rev - scheduler.now % rev)
            }
        } else {
            scheduler.cancel(.fdcIndex)
        }
    }

    func indexPulse() {
        if drives[Int(dor & 3)].disc != nil { ioc.setIRQA(IOC.irqAPrinterAck) } // new I/O: disc index
        if dor & (0x10 << (dor & 3)) != 0 { scheduler.schedule(.fdcIndex, at: scheduler.firingTime &+ Self.revolutionTicks) }
    }

    func updateLines() {
        ioc.setIRQB(IOC.irqBDiscChanged, interrupt) // new I/O: floppy INT on IRQ B bit 4
        ioc.setFIQ(IOC.fiqFloppyData, dataRequest)
    }

    // MARK: Registers (PC port numbers)

    func read(port: Int) -> UInt8 {
        switch port {
        case 0x3F4: return mainStatus
        case 0x3F5: return readFIFO()
        case 0x3F7: // DIR: bit 7 is disc changed (set while the drive is empty)
            return drives[Int(dor & 3)].disc == nil ? 0x80 : 0
        default: return 0xFF
        }
    }

    func write(port: Int, _ v: UInt8) {
        switch port {
        case 0x3F2:
            let wasReset = dor & 0x04 == 0
            for d in 0..<4 where (dor ^ v) & (0x10 << UInt8(d)) != 0 {
                driveEvent?(d, v & (0x10 << UInt8(d)) != 0 ? .startSpinning : .stopSpinning)
            }
            dor = v
            updateIndex()
            if v & 0x04 == 0 {
                scheduler.cancel(.fdc765); dataRequest = false; setInterrupt(false)
            } else if wasReset {
                reset()
            }
        case 0x3F4: // data rate select; bit 7 software reset
            dataRate = v & 3
            if v & 0x80 != 0 { reset() }
        case 0x3F5: writeFIFO(v)
        case 0x3F7: dataRate = v & 3
        default: break
        }
    }

    var mainStatus: UInt8 {
        switch phase {
        case .command: return 0x80 | (commandBytes.isEmpty ? 0 : 0x10)
        case .execution: return 0x10
        case .result: return 0xD0
        }
    }

    func readFIFO() -> UInt8 {
        guard phase == .result, resultIndex < results.count else { return 0xFF }
        // Reading the result phase acknowledges the interrupt (except after
        // Sense Interrupt Status, which leaves any further ones pending).
        if resultIndex == 0 && pendingSense.isEmpty { setInterrupt(false) }
        let v = results[resultIndex]
        resultIndex += 1
        if resultIndex == results.count { phase = .command; results = [] }
        return v
    }

    /// Parameter bytes each command takes (including the command byte).
    static func length(_ op: UInt8) -> Int {
        switch op & 0x1F {
        case 0x03: return 3                 // Specify
        case 0x04, 0x07: return 2           // Sense Drive Status, Recalibrate
        case 0x05, 0x06, 0x09, 0x0C: return 9 // Write/Read Data (and deleted)
        case 0x0A: return 2                 // Read ID
        case 0x0D: return 6                 // Format Track
        case 0x0F: return 3                 // Seek
        case 0x12: return 2                 // Perpendicular Mode
        case 0x13: return 4                 // Configure
        default: return 1                   // Sense Interrupt, Version, Dump, Lock, invalid
        }
    }

    func writeFIFO(_ v: UInt8) {
        guard phase == .command else { return }
        commandBytes.append(v)
        guard commandBytes.count >= Self.length(commandBytes[0]) else { return }
        let cmd = commandBytes
        commandBytes = []
        execute(cmd)
    }

    func finish(_ r: [UInt8], interrupt irq: Bool) {
        dataRequest = false
        results = r; resultIndex = 0
        phase = r.isEmpty ? .command : .result
        setInterrupt(irq)
    }

    func select(_ b: UInt8) { unit = Int(b & 3); head = Int(b >> 2) & 1 }

    func st0(_ code: UInt8) -> UInt8 { code | UInt8(head << 2) | UInt8(unit) }

    // MARK: Commands

    func execute(_ cmd: [UInt8]) {
        let op = cmd[0]
        log?("FDC command " + cmd.map { String(format: "%02X", $0) }.joined(separator: " ") + " (rate \(dataRate), track \(drives[Int(cmd.count > 1 ? cmd[1] & 3 : 0)].headTrack))")
        switch op & 0x1F {
        case 0x03: // Specify
            stepMs = 16 - Int(cmd[1] >> 4)
            finish([], interrupt: false)
        case 0x04: // Sense Drive Status
            select(cmd[1])
            let d = drives[unit]
            var st3 = UInt8(head << 2) | UInt8(unit) | 0x28 // ready, two-sided
            if d.headTrack == 0 { st3 |= 0x10 }
            if d.disc?.writeProtected ?? true { st3 |= 0x40 }
            finish([st3], interrupt: false)
        case 0x07: // Recalibrate
            select(cmd[1])
            driveEvent?(unit, .seekStart(steps: drives[unit].headTrack, stepMs: stepMs))
            drives[unit].headTrack = 0
            pendingSense.append((0x20 | UInt8(unit), 0))
            phase = .execution
            job = .seek
            scheduler.schedule(.fdc765, after: MasterClock.ticks(milliseconds: 2))
        case 0x0F: // Seek
            select(cmd[1])
            driveEvent?(unit, .seekStart(steps: abs(min(Int(cmd[2]), 83) - drives[unit].headTrack), stepMs: stepMs))
            drives[unit].headTrack = min(Int(cmd[2]), 83)
            pendingSense.append((0x20 | UInt8(unit), cmd[2]))
            phase = .execution
            job = .seek
            scheduler.schedule(.fdc765, after: MasterClock.ticks(milliseconds: 2))
        case 0x08: // Sense Interrupt Status
            if pendingSense.isEmpty {
                finish([0x80], interrupt: false)
            } else {
                let p = pendingSense.removeFirst()
                finish([p.st0, p.pcn], interrupt: !pendingSense.isEmpty)
            }
        case 0x05, 0x06: // Write Data, Read Data
            select(cmd[1])
            multiTrack = op & 0x80 != 0
            c = cmd[2]; h = cmd[3]; r = cmd[4]; n = cmd[5]; eot = cmd[6]
            terminalCount = false
            phase = .execution
            job = op & 0x1F == 0x05 ? .write : .read
            findSector()
        case 0x0A: // Read ID
            select(cmd[1])
            phase = .execution
            job = .readID
            let next = nextHeader(where: { _ in true })
            current = next?.0
            scheduler.schedule(.fdc765, after: next?.1 ?? 2 * Self.revolutionTicks)
        case 0x0D: // Format Track: N SC GPL D, then C H R N per sector by DMA
            select(cmd[1])
            n = cmd[2]; formatSectors = Int(cmd[3]); fillByte = cmd[5]
            terminalCount = false
            buffer = []; bufferIndex = 0
            phase = .execution
            job = .format
            scheduler.schedule(.fdc765, after: rotationalDelay(to: 0))
        case 0x10: finish([0x90], interrupt: false) // Version: enhanced controller
        case 0x0E: finish([UInt8](repeating: 0, count: 10), interrupt: false) // Dump Registers
        case 0x12, 0x13: finish([], interrupt: false) // Perpendicular, Configure
        case 0x14: finish([op & 0x80 != 0 ? 0x10 : 0], interrupt: false) // Lock / Unlock
        default: finish([0x80], interrupt: false) // invalid
        }
    }

    // MARK: Disc access

    enum Job: UInt8 { case none, seek, readID, read, write, format }
    var job = Job.none
    /// Bytes moved by DMA in the current command (diagnostics).
    var bytesMoved = 0
    var firstDACK: UInt32 = 0

    /// ID fields the controller can read: only MFM ones recorded at the
    /// selected data rate (high density tracks hold over 6 KB and need
    /// 500 kbit/s; double density needs 250 or 300).
    func visibleHeaders() -> [SectorHeader] {
        guard let disc = drives[unit].disc else { return [] }
        let headers = disc.layout(side: head, track: drives[unit].headTrack).filter(\.doubleDensity)
        let highDensity = headers.reduce(0) { $0 + $1.size } > 6400
        return (dataRate == 0) == highDensity ? headers : []
    }

    func rotationalDelay(to p: Double) -> UInt64 {
        let rev = Self.revolutionTicks
        let pos = scheduler.now % rev
        let target = UInt64(p * Double(rev)) % rev
        return target >= pos ? (target - pos) + 1 : (rev - pos + target) + 1
    }

    func nextHeader(where match: (SectorHeader) -> Bool) -> (SectorHeader, UInt64)? {
        visibleHeaders().filter(match).map { ($0, rotationalDelay(to: $0.position)) }.min { $0.1 < $1.1 }
    }

    /// The data transfer result: ST0-ST2, then C H R N of the next sector.
    func transferResult(st0 code: UInt8, st1: UInt8 = 0, st2: UInt8 = 0) {
        scheduler.cancel(.fdc765)
        job = .none
        log?(String(format: "FDC result %02X %02X %02X  C%d H%d R%d N%d (%d bytes, first DACK %07X, TC %@)", st0(code), st1, st2, c, h, r, n, bytesMoved, firstDACK, terminalCount ? "yes" : "no"))
        bytesMoved = 0
        finish([st0(code), st1, st2, c, h, r, n], interrupt: true)
    }

    /// Looks for sector R on this track; the transfer starts when it arrives.
    func findSector() {
        guard let disc = drives[unit].disc else { transferResult(st0: 0x48, st1: 0x01); return }
        if job == .write && disc.writeProtected { transferResult(st0: 0x40, st1: 0x02); return }
        // As with the WD1772: a write to a missing standard sector on a
        // formatted track creates it (JFD images omit unreadable sectors
        // that were writable on the original, e.g. Holed Out's CMOS backup).
        if job == .write, r < 5, c == UInt8(drives[unit].headTrack), !visibleHeaders().isEmpty,
           !visibleHeaders().contains(where: { $0.id == self.r && $0.cylinder == self.c && $0.head == self.h }) {
            _ = disc.addSector(side: head, track: drives[unit].headTrack, id: r)
        }
        guard let (hd, delay) = nextHeader(where: { $0.id == self.r && $0.cylinder == self.c && $0.head == self.h }) else {
            let wrongCylinder = visibleHeaders().contains { $0.id == self.r && $0.cylinder != self.c }
            transferResult(st0: 0x40, st1: 0x04, st2: wrongCylinder ? 0x10 : 0)
            return
        }
        current = hd
        bufferIndex = 0
        buffer = job == .write ? [UInt8](repeating: 0, count: hd.size) : disc.readData(hd)
        scheduler.schedule(.fdc765, after: delay)
    }

    /// Steps R (and the head or cylinder) past the sector just transferred.
    /// Returns false past the end of the track.
    func nextSector() -> Bool {
        if r != eot { r &+= 1; return true }
        r = 1
        if multiTrack && h == 0 { h = 1; head = 1; return true }
        if multiTrack { h = 0; head = 0 }
        c &+= 1
        return false
    }

    func event() {
        switch job {
        case .none:
            break
        case .seek:
            job = .none
            finish([], interrupt: true)
        case .readID:
            job = .none
            if let hd = current {
                c = hd.cylinder; h = hd.head; r = hd.id; n = hd.sizeCode
                transferResult(st0: 0)
            } else {
                transferResult(st0: 0x40, st1: 0x01)
            }
        case .read, .write, .format:
            dataRequest = true // the next byte is due
            updateLines()
        }
    }

    // MARK: DMA (DACK range)

    func dmaRead(terminal: Bool, address: UInt32 = 0) -> UInt8 {
        guard dataRequest, job == .read else {
            if terminal { terminalCountBetweenSectors() }
            return 0xFF
        }
        if bytesMoved == 0 { firstDACK = address }
        bytesMoved += 1
        dataRequest = false
        updateLines()
        let v = bufferIndex < buffer.count ? buffer[bufferIndex] : 0
        bufferIndex += 1
        if terminal { terminalCount = true }
        // Terminal count stops the requests; the sector is finished internally.
        if bufferIndex >= buffer.count || terminalCount {
            sectorDone()
        } else {
            scheduler.schedule(.fdc765, after: byteTicks)
        }
        return v
    }

    func dmaWrite(_ v: UInt8, terminal: Bool) {
        guard dataRequest, job == .write || job == .format else {
            if terminal { terminalCountBetweenSectors() }
            return
        }
        dataRequest = false
        updateLines()
        if terminal { terminalCount = true }
        if job == .format {
            buffer.append(v)
            if buffer.count == 4 { formatOne() } else { scheduler.schedule(.fdc765, after: byteTicks) }
            return
        }
        if bufferIndex < buffer.count { buffer[bufferIndex] = v }
        bufferIndex += 1
        // On terminal count the rest of the sector is written as zeros.
        if bufferIndex >= buffer.count || terminalCount {
            for i in bufferIndex..<max(bufferIndex, buffer.count) { buffer[i] = 0 }
            if let hd = current { _ = drives[unit].disc?.writeData(hd, buffer) }
            sectorDone()
        } else {
            scheduler.schedule(.fdc765, after: byteTicks)
        }
    }

    /// Terminal count is decoded from the DACK address, so software can
    /// assert it with no byte requested (ADFS does when its buffer list ends
    /// part-way through a multi-sector command). Between sectors that ends
    /// the command at once, normally.
    func terminalCountBetweenSectors() {
        guard job == .read || job == .write || job == .format else { return }
        terminalCount = true
        if bufferIndex == 0 || bufferIndex >= buffer.count { transferResult(st0: 0) }
    }

    /// A whole sector has moved: stop on terminal count, else go on to the
    /// next sector (a multi-sector transfer) or report the end of the track.
    func sectorDone() {
        let more = nextSector()
        if terminalCount {
            transferResult(st0: 0)
        } else if more {
            findSector()
        } else {
            transferResult(st0: 0x40, st1: 0x80) // end of cylinder
        }
    }

    /// One ID (C H R N) has arrived: write that sector blank.
    func formatOne() {
        let id = buffer
        buffer = []
        c = id[0]; h = id[1]; r = id[2]; n = id[3]
        if let disc = drives[unit].disc, !disc.writeProtected {
            let track = drives[unit].headTrack
            disc.formatSector(side: head, track: track, sectorID: Int(id[2]), data: [UInt8](repeating: fillByte, count: 128 << Int(id[3] & 3)))
        }
        formatSectors -= 1
        if formatSectors <= 0 || terminalCount {
            transferResult(st0: 0)
        } else {
            scheduler.schedule(.fdc765, after: byteTicks)
        }
    }

    // MARK: Snapshot

    func saveState(_ w: inout StateWriter) {
        w.u8(dor); w.u8(dataRate); w.u8(phase.rawValue)
        w.data(commandBytes); w.data(results); w.u32(UInt32(resultIndex))
        w.u32(UInt32(pendingSense.count)); for p in pendingSense { w.u8(p.st0); w.u8(p.pcn) }
        w.bool(interrupt); w.bool(dataRequest); w.bool(terminalCount)
        for v in [c, h, r, n, eot, fillByte] { w.u8(v) }
        for v in [unit, head, bufferIndex, formatSectors] { w.u32(UInt32(v)) }
        w.bool(multiTrack); w.data(buffer); w.u8(job.rawValue)
        for d in drives { w.u32(UInt32(d.headTrack)) }
    }

    func loadState(_ rd: inout StateReader) throws {
        dor = try rd.u8(); dataRate = try rd.u8(); phase = Phase(rawValue: try rd.u8()) ?? .command
        commandBytes = try rd.data(); results = try rd.data(); resultIndex = Int(try rd.u32())
        let n = Int(try rd.u32())
        pendingSense = try (0..<n).map { _ in (try rd.u8(), try rd.u8()) }
        interrupt = try rd.bool(); dataRequest = try rd.bool(); terminalCount = try rd.bool()
        c = try rd.u8(); h = try rd.u8(); r = try rd.u8(); self.n = try rd.u8(); eot = try rd.u8(); fillByte = try rd.u8()
        unit = Int(try rd.u32()); head = Int(try rd.u32()); bufferIndex = Int(try rd.u32()); formatSectors = Int(try rd.u32())
        multiTrack = try rd.bool(); buffer = try rd.data(); job = Job(rawValue: try rd.u8()) ?? .none
        for i in 0..<4 { drives[i].headTrack = Int(try rd.u32()) }
        current = nil
    }
}
