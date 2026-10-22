/// Philips PCF8583 clock/calendar with 240 bytes of battery-backed RAM
/// (the Archimedes "CMOS RAM"), attached to IOC's I2C lines at address 0xA0.
///
/// The clock runs from guest time: `epochSeconds` plus elapsed guest ticks,
/// so a run with the same configuration is reproducible.
public final class PCF8583 {
    public var ram = [UInt8](repeating: 0, count: 256)

    /// Unix time corresponding to guest tick `epochTicks`.
    public var epochSeconds: Int64
    var epochTicks: UInt64 = 0
    var clockTicks: () -> UInt64 = { 0 }

    // I2C slave state
    enum Phase: UInt8 { case idle, rx, rxAck, tx, txAck }
    enum RxKind: UInt8 { case deviceAddress, wordAddress, data }
    var phase: Phase = .idle
    var rxKind: RxKind = .deviceAddress
    var nextAfterAck: RxKind? = nil
    var transmitAfterAck = false
    var shift: UInt8 = 0
    var bitCount = 0
    var txByte: UInt8 = 0
    var masterAck = false
    var address: UInt8 = 0
    var scl = true
    var sdaMaster = true
    var sdaSlave = true
    public var log: ((String) -> Void)?

    public init(epochSeconds: Int64 = 770_428_800) { // 1994-06-01 00:00:00 UTC
        self.epochSeconds = epochSeconds
    }

    /// Current level of SDA as seen by IOC.
    public var sda: Bool { sdaMaster && sdaSlave }
    public var clockLine: Bool { scl }

    func write(sda newSDA: Bool, scl newSCL: Bool) {
        if scl && newSCL && sdaMaster != newSDA {
            if !newSDA {
                // START (or repeated START)
                phase = .rx; rxKind = .deviceAddress; shift = 0; bitCount = 0; sdaSlave = true
            } else {
                // STOP
                phase = .idle; sdaSlave = true
            }
        } else if !scl && newSCL {
            rising(line: newSDA && sdaSlave)
        } else if scl && !newSCL {
            falling()
        }
        sdaMaster = newSDA
        scl = newSCL
    }

    func rising(line: Bool) {
        switch phase {
        case .rx:
            if bitCount < 8 { shift = (shift << 1) | (line ? 1 : 0); bitCount += 1 }
        case .txAck:
            masterAck = !line
        default: break
        }
    }

    func falling() {
        switch phase {
        case .rx:
            guard bitCount == 8 else { return }
            let b = shift
            shift = 0; bitCount = 0
            switch rxKind {
            case .deviceAddress:
                guard b & 0xFE == 0xA0 else { phase = .idle; return }
                sdaSlave = false
                phase = .rxAck
                if b & 1 != 0 { transmitAfterAck = true } else { transmitAfterAck = false; nextAfterAck = .wordAddress }
            case .wordAddress:
                address = b
                sdaSlave = false; phase = .rxAck; transmitAfterAck = false; nextAfterAck = .data
            case .data:
                writeRegister(address, b)
                address &+= 1
                sdaSlave = false; phase = .rxAck; transmitAfterAck = false; nextAfterAck = .data
            }
        case .rxAck:
            sdaSlave = true
            if transmitAfterAck {
                startTransmit()
            } else {
                phase = .rx; rxKind = nextAfterAck ?? .data
            }
        case .tx:
            if bitCount < 8 {
                sdaSlave = (txByte >> (7 - UInt8(bitCount))) & 1 != 0
                bitCount += 1
            } else {
                sdaSlave = true
                phase = .txAck
                masterAck = false
            }
        case .txAck:
            if masterAck {
                address &+= 1
                startTransmit()
            } else {
                phase = .idle; sdaSlave = true
            }
        case .idle: break
        }
    }

    func startTransmit() {
        txByte = readRegister(address)
        sdaSlave = txByte & 0x80 != 0
        bitCount = 1
        phase = .tx
    }

    // MARK: Registers

    func readRegister(_ a: UInt8) -> UInt8 {
        if a >= 1 && a <= 6 { refreshClockRegisters() }
        return ram[Int(a)]
    }

    func writeRegister(_ a: UInt8, _ v: UInt8) {
        if a >= 1 && a <= 6 { refreshClockRegisters() }
        ram[Int(a)] = v
        if a >= 1 && a <= 6 { adoptClockRegisters() }
        ramWritten?(Int(a))
    }

    /// Called after the guest writes a RAM byte (the machine watches CMOS).
    var ramWritten: ((Int) -> Void)?

    var nowSeconds: (Int64, Int) {
        let elapsed = clockTicks() &- epochTicks
        let hundredths = Int64(elapsed / 240_000)
        let total = epochSeconds * 100 + hundredths
        return (total / 100, Int(total % 100))
    }

    static func bcd(_ v: Int) -> UInt8 { UInt8(((v / 10) << 4) | (v % 10)) }
    static func unbcd(_ v: UInt8) -> Int { Int(v >> 4) * 10 + Int(v & 0xF) }

    func refreshClockRegisters() {
        let (secs, cs) = nowSeconds
        let (y, mo, d, h, mi, s, wd) = civil(secs)
        ram[1] = Self.bcd(cs)
        ram[2] = Self.bcd(s)
        ram[3] = Self.bcd(mi)
        ram[4] = Self.bcd(h)
        ram[5] = UInt8((y % 4) << 6) | Self.bcd(d)
        ram[6] = UInt8(wd << 5) | Self.bcd(mo)
    }

    func adoptClockRegisters() {
        let (secs, _) = nowSeconds
        let (y, _, _, _, _, _, _) = civil(secs)
        let cs = Self.unbcd(ram[1])
        let s = Self.unbcd(ram[2]), mi = Self.unbcd(ram[3] & 0x7F), h = Self.unbcd(ram[4] & 0x3F)
        let d = Self.unbcd(ram[5] & 0x3F), mo = Self.unbcd(ram[6] & 0x1F)
        // Choose the year closest to the current one with matching (year % 4).
        var year = y - (y % 4) + Int(ram[5] >> 6)
        if year > y + 1 { year -= 4 }
        let t = Self.daysFromCivil(year, max(1, mo), max(1, d)) * 86400 + Int64(h * 3600 + mi * 60 + s)
        epochSeconds = t
        epochTicks = clockTicks() &- UInt64(cs) * 240_000
    }

    func civil(_ t: Int64) -> (Int, Int, Int, Int, Int, Int, Int) {
        let days = t >= 0 ? t / 86400 : (t - 86399) / 86400
        let rem = Int(t - days * 86400)
        // Howard Hinnant's civil_from_days
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        var y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        if m <= 2 { y += 1 }
        let wd = Int((days + 4) % 7 + 7) % 7 // 0 = Sunday
        return (Int(y), Int(m), Int(d), rem / 3600, (rem / 60) % 60, rem % 60, wd)
    }

    static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int64 {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = m > 2 ? m - 3 : m + 9
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return Int64(era * 146_097 + doe - 719_468)
    }
}

// MARK: - Snapshot state

extension PCF8583 {
    func saveState(_ w: inout StateWriter) {
        w.raw(ram); w.u64(UInt64(bitPattern: epochSeconds)); w.u64(epochTicks)
        w.u8(phase.rawValue); w.u8(rxKind.rawValue); w.u8(nextAfterAck.map { $0.rawValue } ?? 0xFF)
        w.bool(transmitAfterAck); w.u8(shift); w.i64(bitCount); w.u8(txByte); w.bool(masterAck); w.u8(address)
        w.bool(scl); w.bool(sdaMaster); w.bool(sdaSlave)
    }

    func loadState(_ r: inout StateReader) throws {
        ram = try r.raw(256); epochSeconds = Int64(bitPattern: try r.u64()); epochTicks = try r.u64()
        guard let ph = Phase(rawValue: try r.u8()), let rk = RxKind(rawValue: try r.u8()) else { throw SnapshotError.corrupt("I2C state") }
        phase = ph; rxKind = rk
        let next = try r.u8()
        if next == 0xFF { nextAfterAck = nil } else {
            guard let k = RxKind(rawValue: next) else { throw SnapshotError.corrupt("I2C state") }
            nextAfterAck = k
        }
        transmitAfterAck = try r.bool(); shift = try r.u8(); bitCount = try r.i64(); txByte = try r.u8()
        masterAck = try r.bool(); address = try r.u8()
        scl = try r.bool(); sdaMaster = try r.bool(); sdaSlave = try r.bool()
    }
}
