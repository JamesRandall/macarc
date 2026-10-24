/// Machines on one Econet line, run in lockstep on the caller's thread:
/// each runs a quantum, then the line delivers what they sent. Runs repeat
/// exactly. The app's network host does the same with its stations'
/// threads; this is for tests and tools.
public final class EconetNetwork {
    public let line: EconetLine
    public private(set) var machines: [Machine] = []
    private var slots: [LockstepWorkers.Slot] = []
    private let workers = LockstepWorkers(name: "Econet test")
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
        slots.append(LockstepWorkers.Slot { [unowned machine] in machine.run(ticks: $0) })
        line.attach(econet)
    }

    public func remove(_ machine: Machine) {
        if let econet = machine.econet { line.detach(econet) }
        if let i = machines.firstIndex(where: { $0 === machine }) {
            machines.remove(at: i)
            slots.remove(at: i)
        }
    }

    /// Runs every machine for `ticks` of network time.
    public func run(ticks n: UInt64) {
        var left = n
        while left > 0 {
            let q = min(left, line.delay)
            line.beginQuantum()
            if workers.count == 0 {
                for m in machines { m.run(ticks: q) }
            } else {
                workers.run(LockstepWorkers.balance(slots, into: workers.count + 1), ticks: q)
            }
            line.endQuantum(ticks: q)
            left -= q
        }
    }

    /// Runs the machines on `count` threads (this one and `count - 1`
    /// more). The results are the same however many.
    public func useThreads(_ count: Int) { workers.resize(to: max(0, count - 1)) }

    public func run(seconds s: Double) { run(ticks: UInt64(s * Double(EconetTime.ticksPerSecond))) }
}
