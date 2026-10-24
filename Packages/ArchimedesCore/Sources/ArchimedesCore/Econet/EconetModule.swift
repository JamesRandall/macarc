import Foundation

// The Econet module an Archimedes takes on its internal header (ADF10 on
// the A300/400 series, A3000 and A5000; AEH52 on the A3020 and A4000): an
// MC68B54 at &33A0000 (IOC bank 2, sync), registers a word apart (only LA2
// and LA3 reach it), its /IRQ on IOC's FIQ bit 2. Unlike the BBC's there's
// no station number on the module: RISC OS keeps it in CMOS byte 0.
// Sources: A3000 TRM pp.8, 10-11 and 21-22; RISC OS's hdr/IO/IOC-A1.

public final class EconetModule: EconetInterface {
    public let adlc = MC6854()
    /// The station number, as the network knows it (RISC OS reads CMOS).
    public let station: UInt8
    /// Its machine's clock.
    let clock: () -> UInt64
    /// What's arrived from the line, by the time (in the machine's ticks) it
    /// reaches the ADLC. A nil symbol is the start of one: the line's busy
    /// from its first bit, though the byte isn't in until its last.
    private var inbox: [(time: UInt64, symbol: EconetSymbol?)] = []
    private var inboxNext = 0
    /// What the ADLC has sent this quantum, at the machine's ticks.
    private var outbox: [(time: UInt64, symbol: EconetSymbol)] = []
    /// When something next happens: the machine runs `advance` then.
    public private(set) var nextEvent: UInt64 = .max
    /// Told whenever `nextEvent` changes (the machine's scheduler).
    var onReschedule: (UInt64) -> Void = { _ in }
    /// The /IRQ line out (to IOC's FIQ bit 2).
    var onIRQ: (Bool) -> Void = { _ in }
    /// Whether it's on a line (without one there's no clock).
    public private(set) var pluggedIn = false
    /// Sees every CPU access (for tests and debugging).
    public var accessObserver: ((String) -> Void)?
    /// FIQs the ADLC has raised, for tests and the inspector.
    public private(set) var irqCount = 0

    init(station: UInt8, clock: @escaping () -> UInt64) {
        self.station = station
        self.clock = clock
        adlc.onTransmit = { [unowned self] symbol, time in outbox.append((time, symbol)) }
        adlc.onIRQChange = { [unowned self] on in
            if on { irqCount += 1 }
            onIRQ(on)
        }
        adlc.setLine(clock: false, bitTime: EconetTime.bitTime(rate: EconetTime.defaultClockRate), collision: false, now: 0)
    }

    /// Power on and reset (the module's NRST).
    func reset(now: UInt64) {
        adlc.reset(now: now)
        reschedule()
    }

    // MARK: The CPU's side

    func read(_ register: Int, now: UInt64) -> UInt8 {
        advance(to: now)
        let v = adlc.read(register, now: now)
        reschedule()
        accessObserver?("\(now) R\(register) = \(String(v, radix: 16)) irq \(adlc.irq)")
        return v
    }

    func write(_ register: Int, _ value: UInt8, now: UInt64) {
        advance(to: now)
        adlc.write(register, value, now: now)
        reschedule()
        accessObserver?("\(now) W\(register) \(String(value, radix: 16)) -> sr1 \(String(adlc.sr1, radix: 16)) sr2 \(String(adlc.sr2, radix: 16)) irq \(adlc.irq)")
    }

    // MARK: The line's side

    /// Runs the ADLC and the line up to `now`, in time order.
    public func advance(to now: UInt64) {
        while true {
            let symbolTime = inboxNext < inbox.count ? inbox[inboxNext].time : .max
            let adlcTime = adlc.nextEventTime ?? .max
            let time = min(symbolTime, adlcTime)
            guard time <= now else { break }
            if symbolTime <= adlcTime {
                let symbol = inbox[inboxNext].symbol
                inboxNext += 1
                adlc.advance(to: symbolTime)
                if let symbol { adlc.receive(symbol, at: symbolTime) } else { adlc.lineBusy(at: symbolTime) }
            } else {
                adlc.advance(to: adlcTime)
            }
        }
        if inboxNext > 64 {
            inbox.removeFirst(inboxNext)
            inboxNext = 0
        }
        adlc.advance(to: now)
        reschedule()
    }

    private func reschedule() {
        let symbolTime = inboxNext < inbox.count ? inbox[inboxNext].time : .max
        let next = min(symbolTime, adlc.nextEventTime ?? .max)
        if next != nextEvent {
            nextEvent = next
            onReschedule(next)
        }
    }

    // MARK: EconetInterface

    public var localTime: UInt64 { clock() }

    public func plugIn(delay: UInt64) {
        adlc.lineDelay = Int(delay)
        pluggedIn = true
    }

    public func unplug() {
        inbox.removeAll()
        inboxNext = 0
        outbox.removeAll()
        pluggedIn = false
        setLine(clock: false, bitTime: adlc.bitTime, collision: false)
    }

    public func setLine(clock: Bool, bitTime: Int, collision: Bool) {
        let now = self.clock()
        advance(to: now)
        adlc.setLine(clock: clock, bitTime: bitTime, collision: collision, now: now)
        reschedule()
    }

    public func takeOutbox() -> [(time: UInt64, symbol: EconetSymbol)] {
        defer { outbox.removeAll(keepingCapacity: true) }
        return outbox
    }

    public func deliver(_ symbols: [(time: UInt64, symbol: EconetSymbol)]) {
        let byteTime = UInt64(adlc.bitTime * 8)
        var events: [(time: UInt64, symbol: EconetSymbol?)] = []
        for (time, symbol) in symbols {
            events.append((time - byteTime, nil))
            events.append((time, symbol))
        }
        // Merge with what's still to come (deliveries overlap by a byte).
        var pending = Array(inbox[inboxNext...]) + events
        pending.sort { $0.time < $1.time }
        inbox = pending
        inboxNext = 0
        reschedule()
    }

    // MARK: Reporting

    /// The module's state, for agents and the inspector.
    public func statusReport() -> String {
        let a = adlc
        func bits(_ value: UInt8, _ names: [String]) -> String {
            let set = (0..<8).filter { value & (1 << $0) != 0 }.map { names[$0] }
            return String(format: "&%02X", value) + (set.isEmpty ? "" : " (" + set.joined(separator: " ") + ")")
        }
        let line = "line: \(pluggedIn ? "plugged in" : "not plugged in"), " + (a.noClock ? "no clock (/DCD high)" : "clock, bit time \(a.bitTime) ticks")
        let tx = a.txFIFO.map { String(format: "%02X", $0.byte) + ($0.last ? "(last)" : "") }
        let rx = a.rxFIFO.map { e -> String in
            String(format: "%02X", e.byte) + (e.address ? "(address)" : "") + (e.end != nil ? "(end)" : "")
        }
        var lines = ["station: \(station)", line]
        lines.append("CR1 " + bits(a.cr1, ["AC", "RIE", "TIE", "RDSR", "TDSR", "discontinue", "RX reset", "TX reset"]))
        lines.append("CR2 " + bits(a.cr2, ["PSE", "2-byte", "flag idle", "FC", "TX last", "clear RX", "clear TX", "RTS"]))
        lines.append("CR3 " + bits(a.cr3, ["LCF", "CEX", "AEX", "01/11 idle", "FDSE", "loop", "test", "DTR"]))
        lines.append("CR4 " + bits(a.cr4, ["double flag", "TX len", "TX len", "RX len", "RX len", "abort", "abort ext", "NRZ"]))
        lines.append("SR1 " + bits(a.sr1, ["RDA", "S2RQ", "loop", "FD", "CTS", "TU", "TDRA/FC", "IRQ"]))
        lines.append("SR2 " + bits(a.sr2, ["AP", "FV", "idle", "abort", "error", "DCD", "overrun", "RDA"]))
        lines.append("/CTS: \(a.notClearToSend ? "high (mustn't send)" : "low (clear to send)"), RTS out: \(a.rtsOut ? "on" : "off")")
        lines.append("transmitter: \(a.txState), FIFO \(tx)")
        lines.append("receiver: \(a.rxState), FIFO \(rx)")
        lines.append("FIQ: \(a.irq ? "asserted" : "off"), \(irqCount) raised")
        return lines.joined(separator: "\n")
    }
}
