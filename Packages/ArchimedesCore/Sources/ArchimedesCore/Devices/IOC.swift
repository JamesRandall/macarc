import Foundation

/// Acorn IOC (VL86C410): interrupt controller, four 16-bit 2 MHz timers,
/// keyboard serial link (KART), control port (I2C, flyback) and I/O bank
/// decoding for the A3000 peripherals (WD1772, latches).
public final class IOC {
    // IRQ A
    public static let irqAPrinterBusy: UInt8 = 0x01
    public static let irqASerialRing: UInt8 = 0x02
    public static let irqAPrinterAck: UInt8 = 0x04
    public static let irqAVsync: UInt8 = 0x08
    public static let irqAPowerOn: UInt8 = 0x10
    public static let irqATimer0: UInt8 = 0x20
    public static let irqATimer1: UInt8 = 0x40
    public static let irqAForce: UInt8 = 0x80
    // IRQ B
    public static let irqBPoduleFIQ: UInt8 = 0x01
    public static let irqBSound: UInt8 = 0x02
    public static let irqBSerial: UInt8 = 0x04
    public static let irqBHardDisc: UInt8 = 0x08
    public static let irqBDiscChanged: UInt8 = 0x10
    public static let irqBPodule: UInt8 = 0x20
    public static let irqBKeyboardTx: UInt8 = 0x40
    public static let irqBKeyboardRx: UInt8 = 0x80
    // FIQ
    public static let fiqFloppyData: UInt8 = 0x01
    public static let fiqFloppyIRQ: UInt8 = 0x02
    public static let fiqEconet: UInt8 = 0x04
    public static let fiqForce: UInt8 = 0x80

    public private(set) var irqAStatus: UInt8 = IOC.irqAForce | IOC.irqAPowerOn
    public private(set) var irqAMask: UInt8 = 0
    public private(set) var irqBStatus: UInt8 = IOC.irqBKeyboardTx
    public private(set) var irqBMask: UInt8 = 0
    public private(set) var fiqStatus: UInt8 = IOC.fiqForce
    public private(set) var fiqMask: UInt8 = 0
    public private(set) var control: UInt8 = 0xFF

    struct Timer {
        var latch: UInt16 = 0xFFFF
        var periodLatch: UInt16 = 0xFFFF
        var output: UInt16 = 0
        var loadTick: UInt64 = 0
    }
    var timers = [Timer](repeating: Timer(), count: 4)
    static let ticksPerTimerCount: UInt64 = 12 // 2 MHz

    var txByte: UInt8 = 0
    var rxByte: UInt8 = 0
    var rxPending: UInt8 = 0

    public private(set) var latchA: UInt8 = 0xFF
    public private(set) var latchB: UInt8 = 0xFF

    unowned(unsafe) let bus: MEMC
    unowned(unsafe) let scheduler: Scheduler
    let keyboard: Keyboard
    let rtc: PCF8583
    unowned(unsafe) var fdc: WD1772!
    /// The 400 series' ST506 controller (bank 5), when fitted.
    var hdc: HD63463?
    /// The A5000 family's 82C711 (bank 1) and IOEB (bank 5).
    var superIO: SuperIO?
    var updateLines: (Bool, Bool) -> Void = { _, _ in }
    public var unknownAccess: ((String) -> Void)?

    // Diagnostics
    public var irqCounts = [UInt64](repeating: 0, count: 24)

    init(bus: MEMC, scheduler: Scheduler, keyboard: Keyboard, rtc: PCF8583) {
        self.bus = bus
        self.scheduler = scheduler
        self.keyboard = keyboard
        self.rtc = rtc
        scheduler.setHandler(.timer0) { [unowned self] in self.timerExpired(0) }
        scheduler.setHandler(.timer1) { [unowned self] in self.timerExpired(1) }
        scheduler.setHandler(.keyboardTx) { [unowned self] in self.keyboardTxDone() }
        scheduler.setHandler(.keyboardRx) { [unowned self] in self.keyboardRxDone() }
    }

    func powerOn() {
        irqAStatus = Self.irqAForce | Self.irqAPowerOn
        irqBStatus = Self.irqBKeyboardTx
        fiqStatus = Self.fiqForce
        irqAMask = 0; irqBMask = 0; fiqMask = 0
        control = 0xFF
        for i in 0..<4 { timers[i] = Timer(); timers[i].loadTick = bus.ticks }
        scheduleTimer(0); scheduleTimer(1)
        scheduler.cancel(.keyboardRx); scheduler.cancel(.keyboardTx)
        rxPending = 0
        updateInterrupts()
    }

    /// IOC is not reset by the reset button on the A3000 beyond its masks.
    func reset() {
        irqAMask = 0; irqBMask = 0; fiqMask = 0
        irqAStatus &= ~Self.irqAPowerOn
        updateInterrupts()
    }

    // MARK: Interrupt lines

    @inline(__always) func updateInterrupts() {
        let irq = (irqAStatus & irqAMask) | (irqBStatus & irqBMask) != 0
        let fiq = (fiqStatus & fiqMask) != 0
        updateLines(irq, fiq)
    }

    /// Diagnostics hook for timer GO commands and IRQ A events (off by default).
    public var eventTrace: ((String) -> Void)?

    func setIRQA(_ bits: UInt8) {
        eventTrace?(String(format: "IRQA set %02X", bits))
        irqAStatus |= bits; irqCounts[bits.trailingZeroBitCount] &+= 1; updateInterrupts() }
    func setIRQB(_ bits: UInt8, _ on: Bool) {
        if on { if irqBStatus & bits == 0 { irqCounts[8 + bits.trailingZeroBitCount] &+= 1 }; irqBStatus |= bits } else { irqBStatus &= ~bits }
        updateInterrupts()
    }
    func setFIQ(_ bits: UInt8, _ on: Bool) {
        if on { if fiqStatus & bits == 0 { irqCounts[16 + bits.trailingZeroBitCount] &+= 1 }; fiqStatus |= bits } else { fiqStatus &= ~bits }
        updateInterrupts()
    }

    func setSoundInterrupt(_ on: Bool) { setIRQB(Self.irqBSound, on) }

    func setFlyback(_ on: Bool) {
        if on {
            control |= 0x80
            setIRQA(Self.irqAVsync)
        } else {
            control &= ~0x80
        }
    }

    // MARK: Bus interface

    /// Read from the I/O space 0x3000000-0x33FFFFF.
    func read(_ a: UInt32) -> UInt32 {
        let cycle = (a >> 19) & 3
        bus.ticks &+= cycleTicks(cycle)
        if let superIO, SuperIO.isDACK(a) { return superIO.dmaRead(a) }
        // Address bit 21 selects IOC's own registers in bank 0; the new I/O
        // chips are addressed with it clear as well (the 82C711 at &3010000).
        guard a & 0x0020_0000 != 0 || (superIO != nil && (a >> 16) & 7 != 0) else { return 0xFFFF_FFFF }
        let bank = (a >> 16) & 7
        let reg = a & 0x7C
        switch bank {
        case 0:
            return UInt32(readInternal(reg))
        case 1:
            if let superIO { return superIO.read(a) }
            return UInt32(fdc.read(Int((a >> 2) & 3)))
        case 5:
            if let superIO { return superIO.readIOEB(a) }
            if let hdc, [0x08, 0x0C, 0x20, 0x24].contains(reg) { return hdc.read(reg) }
            unknownAccess?(String(format: "IOC read bank 5 reg %02X", reg))
            return 0xFFFF_FFFF
        default:
            unknownAccess?(String(format: "IOC read bank %d addr %07X", bank, a))
            return 0xFFFF_FFFF
        }
    }

    func write(_ a: UInt32, _ busValue: UInt32) {
        let cycle = (a >> 19) & 3
        bus.ticks &+= cycleTicks(cycle)
        if let superIO, SuperIO.isDACK(a) { superIO.dmaWrite(a, busValue); return }
        guard a & 0x0020_0000 != 0 || (superIO != nil && (a >> 16) & 7 != 0) else { return }
        // Peripheral data bus BD0-15 is driven from ARM D16-31.
        let v = UInt8(truncatingIfNeeded: busValue >> 16)
        let bank = (a >> 16) & 7
        let reg = a & 0x7C
        switch bank {
        case 0:
            writeInternal(reg, v)
        case 1:
            if let superIO { superIO.write(a, busValue) } else { fdc.write(Int((a >> 2) & 3), v) }
        case 5:
            if let superIO { superIO.writeIOEB(a, busValue); return }
            switch reg {
            case 0x18:
                latchB = v
                fdc.latchBChanged(v)
            case 0x40:
                latchA = v
                fdc.latchAChanged(v)
            case 0x00, 0x04, 0x28, 0x2C:
                if let hdc { hdc.write(reg, UInt16(truncatingIfNeeded: busValue >> 16)) } else { fallthrough }
            default:
                unknownAccess?(String(format: "IOC write bank 5 reg %02X = %02X", reg, v))
            }
        default:
            unknownAccess?(String(format: "IOC write bank %d addr %07X = %02X", bank, a, v))
        }
    }

    func cycleTicks(_ cycle: UInt32) -> UInt64 {
        // MEMC stretches I/O cycles; modelled as one N cycle for fast
        // accesses and two for the slower IOC cycle types.
        switch cycle {
        case 2: return MasterClock.nCycle
        default: return 2 * MasterClock.nCycle
        }
    }

    func readInternal(_ reg: UInt32) -> UInt8 {
        switch reg {
        case 0x00:
            var v = control & 0xFC
            if rtc.sda && (control & 1) != 0 { v |= 1 }
            if control & 2 != 0 { v |= 2 }
            return v
        case 0x04:
            irqBStatus &= ~Self.irqBKeyboardRx
            updateInterrupts()
            let b = rxByte
            pumpKeyboard()
            return b
        case 0x10: return irqAStatus
        case 0x14: return irqAStatus & irqAMask
        case 0x18: return irqAMask
        case 0x20: return irqBStatus
        case 0x24: return irqBStatus & irqBMask
        case 0x28: return irqBMask
        case 0x30: return fiqStatus
        case 0x34: return fiqStatus & fiqMask
        case 0x38: return fiqMask
        case 0x40, 0x50, 0x60, 0x70: return UInt8(truncatingIfNeeded: timers[Int((reg >> 4) - 4)].output)
        case 0x44, 0x54, 0x64, 0x74: return UInt8(truncatingIfNeeded: timers[Int((reg >> 4) - 4)].output >> 8)
        default:
            unknownAccess?(String(format: "IOC read internal reg %02X", reg))
            return 0xFF
        }
    }

    func writeInternal(_ reg: UInt32, _ v: UInt8) {
        switch reg {
        case 0x00:
            control = (control & 0xC0) | (v & 0x3F)
            // C3-C5 appear inverted in the FIQ status register.
            fiqStatus = (fiqStatus & ~0x38) | (~v & 0x38)
            rtc.write(sda: v & 1 != 0, scl: v & 2 != 0)
            updateInterrupts()
        case 0x04:
            txByte = v
            irqBStatus &= ~Self.irqBKeyboardTx
            updateInterrupts()
            scheduler.schedule(.keyboardTx, after: keyboardByteTicks)
        case 0x14:
            irqAStatus &= ~(v & 0x7C)
            updateInterrupts()
        case 0x18: irqAMask = v; updateInterrupts()
        case 0x28: irqBMask = v; updateInterrupts()
        case 0x38: fiqMask = v; updateInterrupts()
        case 0x40, 0x50, 0x60, 0x70:
            let t = Int((reg >> 4) - 4)
            timers[t].latch = (timers[t].latch & 0xFF00) | UInt16(v)
        case 0x44, 0x54, 0x64, 0x74:
            let t = Int((reg >> 4) - 4)
            timers[t].latch = (timers[t].latch & 0x00FF) | (UInt16(v) << 8)
        case 0x48, 0x58, 0x68, 0x78:
            let t = Int((reg >> 4) - 4)
            timers[t].periodLatch = timers[t].latch
            timers[t].loadTick = bus.ticks
            eventTrace?("timer \(t) GO latch=\(timers[t].latch)")
            if t < 2 { scheduleTimer(t) }
        case 0x4C, 0x5C, 0x6C, 0x7C:
            let t = Int((reg >> 4) - 4)
            timers[t].output = timerCount(t)
        default:
            unknownAccess?(String(format: "IOC write internal reg %02X = %02X", reg, v))
        }
    }

    // MARK: Timers

    func timerCount(_ t: Int) -> UInt16 {
        let tm = timers[t]
        let period = UInt64(tm.periodLatch) + 1
        let elapsed = (bus.ticks &- tm.loadTick) / Self.ticksPerTimerCount
        return UInt16(truncatingIfNeeded: UInt64(tm.periodLatch) - (elapsed % period))
    }

    func scheduleTimer(_ t: Int) {
        let slot: Scheduler.Slot = t == 0 ? .timer0 : .timer1
        let tm = timers[t]
        if tm.periodLatch == 0 { scheduler.cancel(slot); return }
        let period = (UInt64(tm.periodLatch) + 1) * Self.ticksPerTimerCount
        scheduler.schedule(slot, at: tm.loadTick &+ period)
    }

    func timerExpired(_ t: Int) {
        let period = (UInt64(timers[t].periodLatch) + 1) * Self.ticksPerTimerCount
        timers[t].loadTick &+= period
        timers[t].periodLatch = timers[t].latch
        setIRQA(t == 0 ? Self.irqATimer0 : Self.irqATimer1)
        scheduleTimer(t)
    }

    // MARK: Keyboard serial link

    /// Byte time: timer 3 sets the KART bit rate at (latch+1)*16 µs per bit; 11 bits per byte.
    var keyboardByteTicks: UInt64 {
        let us = UInt64(timers[3].latch &+ 1) * 16 * 11
        return MasterClock.ticks(microseconds: max(us, 100))
    }

    func keyboardTxDone() {
        irqBStatus |= Self.irqBKeyboardTx
        updateInterrupts()
        keyboard.receive(txByte)
        pumpKeyboard()
    }

    func keyboardRxDone() {
        rxByte = rxPending
        irqBStatus |= Self.irqBKeyboardRx
        irqCounts[15] &+= 1
        updateInterrupts()
    }

    /// Start transmitting the keyboard's next byte if the link is free.
    public func pumpKeyboard() {
        if scheduler.isScheduled(.keyboardRx) { return }
        if irqBStatus & Self.irqBKeyboardRx != 0 { return }
        guard let b = keyboard.nextByteToSend() else { return }
        keyboard.byteSent()
        rxPending = b
        scheduler.schedule(.keyboardRx, after: keyboardByteTicks)
    }

    // MARK: Floppy lines

    func setFloppyDRQ(_ on: Bool) { setFIQ(Self.fiqFloppyData, on) }
    func setFloppyIRQ(_ on: Bool) { setFIQ(Self.fiqFloppyIRQ, on) }

    public var timerLatches: [UInt16] { timers.map { $0.latch } }
}

// MARK: - Snapshot state

extension IOC {
    func saveState(_ w: inout StateWriter) {
        for v in [irqAStatus, irqAMask, irqBStatus, irqBMask, fiqStatus, fiqMask, control, txByte, rxByte, rxPending, latchA, latchB] { w.u8(v) }
        for t in timers { w.u16(t.latch); w.u16(t.periodLatch); w.u16(t.output); w.u64(t.loadTick) }
    }

    func loadState(_ r: inout StateReader) throws {
        irqAStatus = try r.u8(); irqAMask = try r.u8(); irqBStatus = try r.u8(); irqBMask = try r.u8()
        fiqStatus = try r.u8(); fiqMask = try r.u8(); control = try r.u8()
        txByte = try r.u8(); rxByte = try r.u8(); rxPending = try r.u8(); latchA = try r.u8(); latchB = try r.u8()
        for i in 0..<4 {
            timers[i] = Timer(latch: try r.u16(), periodLatch: try r.u16(), output: try r.u16(), loadTick: try r.u64())
        }
    }
}
