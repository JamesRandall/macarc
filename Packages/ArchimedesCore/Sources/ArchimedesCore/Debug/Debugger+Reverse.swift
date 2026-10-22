import Foundation

/// Debugging backwards, through the rewind history: replay windows of it
/// with an observer instead of breakpoints, newest first, and stop at the
/// last moment that matches.
extension Debugger {
    public enum ReverseError: Error, CustomStringConvertible {
        case noHistory
        public var description: String { "there's no rewind history to go back through" }
    }

    struct Position {
        var instructions: UInt64
        var ticks: UInt64
        var reason: StopReason
    }

    /// Replays the history up to now, window by window from the newest.
    /// `match` sees each instruction and data access as it replays (with
    /// the replaying machine's debugger, whose registers are those of that
    /// moment, and the instruction count); the last match in the newest
    /// window that has one wins.
    func searchBackwards(_ rewinder: Rewinder, match: @escaping (Debugger, ReplayEvent, UInt64) -> Position?) throws -> Position? {
        guard !rewinder.points.isEmpty else { throw ReverseError.noHistory }
        let now = machine.cpu.instructionCount
        let nowTicks = machine.ticks
        let discs = machine.hardDiscImages.compactMap { $0 }
        discs.forEach { $0.suppressWrites = true }
        defer { discs.forEach { $0.suppressWrites = false } }
        for i in stride(from: rewinder.points.count - 1, through: 0, by: -1) {
            let p = rewinder.points[i]
            guard p.instructions < now else { continue }
            let end = i + 1 < rewinder.points.count ? min(rewinder.points[i + 1].instructions, now) : now
            let m = try rewinder.restore(i, from: machine, inputsThrough: nowTicks)
            let d = m.debugger
            d.adopt(self)
            var last: Position?
            d.replayObserver = { [unowned m, unowned d] e in
                if let found = match(d, e, m.cpu.instructionCount) { last = found }
            }
            d.forceHooks = true
            d.updateHooks()
            if end > m.cpu.instructionCount { m.run(untilTick: .max, maxInstructions: end - m.cpu.instructionCount) }
            d.replayObserver = nil
            d.forceHooks = false
            if let last { return last }
        }
        return nil
    }

    /// Goes back one instruction. Returns the machine to continue with.
    public func stepBack(_ rewinder: Rewinder) throws -> Machine {
        let now = machine.cpu.instructionCount
        let found = try searchBackwards(rewinder) { _, e, count in
            if case .execute(_, let t) = e, count < now { return Position(instructions: count, ticks: t, reason: .stepped) }
            return nil
        }
        return try go(to: found, rewinder)
    }

    /// Goes back to the last time a breakpoint or watchpoint would have hit.
    public func reverseContinue(_ rewinder: Rewinder) throws -> Machine {
        let now = machine.cpu.instructionCount
        let found = try searchBackwards(rewinder) { d, e, count in
            switch e {
            case .execute(let pc, let t) where count < now && d.executeKinds:
                return d.wouldHit(pc, .execute).map { Position(instructions: count, ticks: t, reason: $0) }
            case .data(let a, let write, let t) where count < now && d.dataKinds:
                // A watchpoint stops after the instruction that made the access
                // (the count already includes it).
                return d.wouldHit(a & 0x03FF_FFFF, write ? .write : .read).map { Position(instructions: count, ticks: t, reason: $0) }
            default:
                return nil
            }
        }
        return try go(to: found, rewinder)
    }

    /// The machine at `p`, stopped there; or at the start of the history.
    func go(to p: Position?, _ rewinder: Rewinder) throws -> Machine {
        let target = p ?? Position(instructions: rewinder.points[0].instructions, ticks: rewinder.points[0].ticks, reason: .historyStart)
        guard let m = try rewinder.machine(atInstruction: target.instructions, ticks: target.ticks, from: machine) else { throw ReverseError.noHistory }
        m.debugger.stop(target.reason)
        return m
    }

    /// Whether a breakpoint would stop here, without counting a hit (the
    /// replay machine's registers stand for that moment).
    func wouldHit(_ address: UInt32, _ kind: Breakpoint.Kind) -> StopReason? {
        let mode = cpu.psr & 3
        for b in breakpoints where b.enabled && b.logMessage == nil && !b.kind.intersection(kind).isEmpty && b.covers(address) {
            if let m = b.mode, m.rawValue != mode { continue }
            if let c = compiled[b.id], ((try? c.evaluate(context)) ?? 0) == 0 { continue }
            return .breakpoint(id: b.id, address: address, kind: kind)
        }
        return nil
    }
}
