// A local Econet: one shared, half-duplex line, its clock, and the stations
// plugged into it. Its stations run in lockstep: each runs a quantum of
// emulated time in turn, then the line delivers what they sent. What a
// station transmits reaches the others `delay` ticks after its last bit,
// never less than a quantum, so it never arrives in a station's past and
// the order the stations run in doesn't matter. (After MacBeeb's EconetBus.)
//
// Network time is counted in 24 MHz ticks. That's the Archimedes' own
// clock, and a BBC Micro's 2 MHz cycle is exactly 12 of them, so MacBeeb's
// stations can share the line's time without rounding when the two apps are
// connected. The quantum and delay are MacBeeb's: 16 µs.

/// Times on an Econet line.
public enum EconetTime {
    public static let ticksPerSecond: UInt64 = 24_000_000
    /// How long a symbol takes to cross the line, and the longest quantum:
    /// 16 µs. After a scout the sender counts 15 idle bits (75 µs at
    /// 200 kbit/s) as "not listening", so each hop must stay well inside
    /// half of that.
    public static let delay: UInt64 = 384
    /// A typical school network's clock: 200 kbit/s.
    public static let defaultClockRate = 200_000
    /// The clock rates a clock box offered.
    public static let clockRates = [50_000, 100_000, 125_000, 200_000, 250_000]

    /// One bit at `rate` bits a second, in ticks.
    public static func bitTime(rate: Int) -> Int { max(1, Int(ticksPerSecond) / max(1, rate)) }
}

/// The line, as an observer sees it: every byte-time anyone transmitted.
public struct EconetLineEvent: Sendable, Equatable {
    /// When it started, in network ticks.
    public var time: UInt64
    public var station: UInt8
    public var symbol: EconetSymbol
    /// Someone else was transmitting at the same time.
    public var collided: Bool
}

/// Something plugged into the line: an emulated machine's Econet module,
/// or (later) a link to stations in another app. Its times are its own.
public protocol EconetInterface: AnyObject {
    var station: UInt8 { get }
    /// Its clock now, in ticks.
    var localTime: UInt64 { get }
    /// The line's delay, which its receiver allows for.
    func plugIn(delay: UInt64)
    /// Unplugged: no clock, and nothing more arrives.
    func unplug()
    /// The clock (and its bit-time), and whether its transmission collided.
    func setLine(clock: Bool, bitTime: Int, collision: Bool)
    /// What it has sent since last asked, at its own times.
    func takeOutbox() -> [(time: UInt64, symbol: EconetSymbol)]
    /// Symbols from the line, at its own times when their last bit is in.
    func deliver(_ symbols: [(time: UInt64, symbol: EconetSymbol)])
}

/// Something on the line that isn't an emulated machine's Econet module
/// (an Internet gateway). It works in the network's time, and hears and
/// drives the line as a station does. (After MacBeeb's.)
public protocol EconetLineDevice: AnyObject, Sendable {
    /// Runs to `end` (network ticks): takes in what it's heard up to then,
    /// and returns what it puts on the line in [`start`, `end`), each symbol
    /// at its start time and as the station it's transmitting for.
    func run(from start: UInt64, to end: UInt64, clock: Bool, bitTime: Int, delay: UInt64) -> [(time: UInt64, station: UInt8, symbol: EconetSymbol)]
    /// Symbols from the others, at the network time each is in (all still to
    /// come, in time order).
    func hear(_ symbols: [(time: UInt64, symbol: EconetSymbol)])
}

public final class EconetLine {
    /// The clock's rate in bits a second, or nil if there's no clock.
    public var clockRate: Int?
    public let delay: UInt64
    /// Sees every symbol, if set. Called on the network's thread.
    public var observer: ((EconetLineEvent) -> Void)?

    final class Port {
        let interface: EconetInterface
        /// The network's time minus the station's, this quantum.
        var offset: Int64 = 0
        var running = true
        /// When its last symbol ended (network time).
        var lastEnd: UInt64 = 0
        var collidedUntil: UInt64 = 0
        /// What it was last told of the line (clock, bit time, collision).
        var told: (Bool, Int, Bool)?

        init(_ interface: EconetInterface) { self.interface = interface }
    }

    private(set) var ports: [Port] = []
    /// Devices on the line that aren't machines, and when each last finished
    /// a symbol (and was collided with until).
    private var devices: [(device: EconetLineDevice, lastEnd: UInt64, collidedUntil: UInt64)] = []

    /// Plugs in a device (an Internet gateway).
    public func attach(device: EconetLineDevice) {
        guard !devices.contains(where: { $0.device === device }) else { return }
        devices.append((device, 0, 0))
    }

    public func detach(device: EconetLineDevice) {
        devices.removeAll { $0.device === device }
    }
    /// The network's time at the start of the quantum.
    public private(set) var time: UInt64 = 0

    public init(clockRate: Int? = EconetTime.defaultClockRate, delay: UInt64 = EconetTime.delay) {
        self.clockRate = clockRate
        self.delay = delay
    }

    var bitTime: Int { EconetTime.bitTime(rate: clockRate ?? EconetTime.defaultClockRate) }

    /// Plugs a station in.
    public func attach(_ interface: EconetInterface) {
        detach(interface)
        interface.plugIn(delay: delay)
        ports.append(Port(interface))
        ports.sort { $0.interface.station < $1.interface.station }
    }

    public func detach(_ interface: EconetInterface) {
        guard let i = ports.firstIndex(where: { $0.interface === interface }) else { return }
        ports.remove(at: i)
        interface.unplug()
    }

    public var stations: [UInt8] { ports.map(\.interface.station) }

    /// Which stations will run (the others aren't listening), until it's
    /// said again.
    public func setRunning(_ running: (EconetInterface) -> Bool) {
        for port in ports { port.running = running(port.interface) }
    }

    /// Before the stations run: the line's state for each that will.
    public func beginQuantum() {
        for port in ports where port.running {
            let local = port.interface.localTime
            port.offset = Int64(bitPattern: time) - Int64(bitPattern: local)
            let line = (clockRate != nil, bitTime, time < port.collidedUntil)
            if port.told.map({ $0 != line }) ?? true {
                port.told = line
                port.interface.setLine(clock: line.0, bitTime: line.1, collision: line.2)
            }
        }
    }

    /// After the stations have each run `ticks`: what they sent goes onto
    /// the line, collisions spoil it, and it's delivered to the others.
    public func endQuantum(ticks: UInt64) {
        struct Sent {
            var port: Int
            var time: UInt64
            var symbol: EconetSymbol
            var collided = false
        }
        var sent: [Sent] = []
        for (index, port) in ports.enumerated() where port.running {
            for (t, symbol) in port.interface.takeOutbox() {
                sent.append(Sent(port: index, time: UInt64(Int64(bitPattern: t) + port.offset), symbol: symbol))
            }
        }
        // Devices are ports after the machines', transmitting as the
        // stations they speak for.
        var deviceStation: [Int: [UInt64: UInt8]] = [:]
        for (index, entry) in devices.enumerated() {
            let port = ports.count + index
            for (t, station, symbol) in entry.device.run(from: time, to: time + ticks, clock: clockRate != nil, bitTime: bitTime,
                                                           delay: delay) {
                sent.append(Sent(port: port, time: t, symbol: symbol))
                deviceStation[port, default: [:]][t] = station
            }
        }
        func lastEnd(_ port: Int) -> UInt64 { port < ports.count ? ports[port].lastEnd : devices[port - ports.count].lastEnd }
        let byteTime = UInt64(bitTime * 8)
        if !sent.isEmpty {
            // Two stations driving the line at once.
            for i in sent.indices {
                let start = sent[i].time, end = start + byteTime
                for j in sent.indices where sent[j].port != sent[i].port {
                    if sent[j].time < end && sent[j].time + byteTime > start { sent[i].collided = true }
                }
                for index in 0..<(ports.count + devices.count) where index != sent[i].port && lastEnd(index) > start
                    && !sent.contains(where: { $0.port == index }) {
                    sent[i].collided = true
                }
            }
            for item in sent where item.collided {
                if item.port < ports.count {
                    ports[item.port].collidedUntil = item.time + byteTime * 2
                } else {
                    devices[item.port - ports.count].collidedUntil = item.time + byteTime * 2
                }
            }
            sent.sort { ($0.time, $0.port) < ($1.time, $1.port) }
            for item in sent {
                let station: UInt8
                if item.port < ports.count {
                    ports[item.port].lastEnd = max(ports[item.port].lastEnd, item.time + byteTime)
                    station = ports[item.port].interface.station
                } else {
                    let d = item.port - ports.count
                    devices[d].lastEnd = max(devices[d].lastEnd, item.time + byteTime)
                    station = deviceStation[item.port]?[item.time] ?? 0
                }
                observer?(EconetLineEvent(time: item.time, station: station, symbol: item.symbol, collided: item.collided))
            }
            for (index, port) in ports.enumerated() where port.running {
                let arriving = sent.filter { $0.port != index }.map { item in
                    // A byte's received when its last bit is in.
                    (time: UInt64(Int64(bitPattern: item.time + byteTime + delay) - port.offset),
                     symbol: item.collided ? EconetSymbol.garbage : item.symbol)
                }
                if !arriving.isEmpty { port.interface.deliver(arriving) }
            }
            for (index, entry) in devices.enumerated() {
                let port = ports.count + index
                let arriving = sent.filter { $0.port != port }.map { item in
                    (time: item.time + byteTime + delay, symbol: item.collided ? EconetSymbol.garbage : item.symbol)
                }
                if !arriving.isEmpty { entry.device.hear(arriving) }
            }
        }
        time += ticks
    }
}
