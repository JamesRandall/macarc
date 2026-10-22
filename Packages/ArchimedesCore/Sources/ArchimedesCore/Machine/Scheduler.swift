/// Deterministic guest-time event scheduler with a fixed set of event slots.
/// Time is the MEMC master tick counter (24 MHz).
public final class Scheduler {
    public enum Slot: Int, CaseIterable, Sendable {
        case timer0, timer1, videoLine, keyboardTx, keyboardRx, floppy, sound, input, hardDisc, ide, fdc765, fdcIndex
    }

    var due = [UInt64](repeating: .max, count: Slot.allCases.count)
    var handlers = [(() -> Void)?](repeating: nil, count: Slot.allCases.count)
    public private(set) var next: UInt64 = .max
    unowned(unsafe) let bus: MEMC

    init(bus: MEMC) { self.bus = bus }

    func setHandler(_ slot: Slot, _ h: @escaping () -> Void) { handlers[slot.rawValue] = h }

    public var now: UInt64 { bus.ticks }

    func schedule(_ slot: Slot, at time: UInt64) {
        due[slot.rawValue] = time
        if time < next {
            next = time
            if time < bus.stopAt { bus.stopAt = time }
        } else {
            recompute()
        }
    }

    func schedule(_ slot: Slot, after delay: UInt64) { schedule(slot, at: bus.ticks &+ max(delay, 1)) }

    func cancel(_ slot: Slot) {
        due[slot.rawValue] = .max
        recompute()
    }

    func isScheduled(_ slot: Slot) -> Bool { due[slot.rawValue] != .max }
    func dueTime(_ slot: Slot) -> UInt64 { due[slot.rawValue] }

    @inline(__always) func recompute() {
        var m = UInt64.max
        for d in due where d < m { m = d }
        next = m
    }

    /// Due time of the event whose handler is running. Periodic devices
    /// schedule their next event from this, not from `bus.ticks`, so time a
    /// handler charges to the bus (DMA cycle stealing) or dispatch latency
    /// does not stretch the period.
    private(set) var firingTime: UInt64 = 0

    /// Run every handler whose time has arrived (in time order).
    func dispatch() {
        while next <= bus.ticks {
            var idx = 0
            var m = UInt64.max
            for (i, d) in due.enumerated() where d < m { m = d; idx = i }
            due[idx] = .max
            recompute()
            firingTime = m
            handlers[idx]?()
        }
    }
}

// MARK: - Snapshot state

extension Scheduler {
    func saveState(_ w: inout StateWriter) {
        w.u64s(due); w.u64(firingTime)
    }

    func loadState(_ r: inout StateReader) throws {
        // Snapshots from before a slot existed have fewer; those are idle.
        let saved = try r.u64s()
        guard saved.count <= Slot.allCases.count else { throw SnapshotError.corrupt("\(saved.count) scheduler slots") }
        due = saved + [UInt64](repeating: .max, count: Slot.allCases.count - saved.count)
        firingTime = try r.u64()
        recompute()
    }
}
