/// Machines on one Econet line, run in lockstep on the caller's thread:
/// each runs a quantum, then the line delivers what they sent. Runs repeat
/// exactly. The app's network host does the same with its stations'
/// threads; this is for tests and tools.
public final class EconetNetwork {
    public let line: EconetLine
    public private(set) var machines: [Machine] = []
    /// Network time.
    public var ticks: UInt64 { line.time }

    public init(clockRate: Int? = EconetTime.defaultClockRate) {
        line = EconetLine(clockRate: clockRate)
    }

    /// Plugs a machine with an Econet module in.
    public func add(_ machine: Machine) {
        guard let econet = machine.econet else { return }
        if !machine.poweredOn { machine.powerOn() }
        machines.append(machine)
        line.attach(econet)
    }

    public func remove(_ machine: Machine) {
        if let econet = machine.econet { line.detach(econet) }
        machines.removeAll { $0 === machine }
    }

    /// Runs every machine for `ticks` of network time.
    public func run(ticks n: UInt64) {
        var left = n
        while left > 0 {
            let q = min(left, line.delay)
            line.beginQuantum()
            for m in machines { m.run(ticks: q) }
            line.endQuantum(ticks: q)
            left -= q
        }
    }

    public func run(seconds s: Double) { run(ticks: UInt64(s * Double(EconetTime.ticksPerSecond))) }
}
