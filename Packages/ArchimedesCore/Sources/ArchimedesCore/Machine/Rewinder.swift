import Foundation

/// Rewind history: snapshots taken as the machine runs, with thumbnails.
///
/// Emulation is deterministic, so going back to any moment is restoring the
/// latest point at or before it and running forward to it, replaying the
/// live inputs (keys, buttons, mouse) recorded on their ticks. Points are
/// compressed snapshots (about 200 KB each); the default keeps two a second
/// for the last minute. Anything else from outside (discs, pokes, register
/// changes) should take a `keyframe`, so no replay crosses it.
public final class Rewinder {
    public struct Point: Sendable {
        public let ticks: UInt64
        let state: [UInt8]
        /// `thumbnailWidth` x `thumbnailHeight` pixels, 0xAARRGGBB.
        public let thumbnail: [UInt32]
        /// Hard disc sector writes so far (hard discs are not rewound).
        let hardDiscWrites: UInt64
        /// Instructions executed by then, and the input log's length.
        public let instructions: UInt64
        let inputIndex: Int
    }

    /// Live inputs, oldest first; `inputBase` is the index of the first.
    var inputs: [Machine.InputEvent] = []
    var inputBase = 0

    public static let thumbnailWidth = 208
    public static let thumbnailHeight = 144

    public let interval: UInt64
    public let capacity: Int
    public private(set) var points: [Point] = []

    public init(intervalSeconds: Double = 0.5, capacity: Int = 120) {
        interval = UInt64(intervalSeconds * Double(MasterClock.ticksPerSecond))
        self.capacity = capacity
    }

    public var earliestTicks: UInt64? { points.first?.ticks }

    /// Take a point if one is due. Call between runs.
    public func captureIfDue(_ m: Machine) {
        if let last = points.last, m.nominalTicks < last.ticks &+ interval { return }
        capture(m)
    }

    public func capture(_ m: Machine) {
        if let last = points.last, last.instructions == m.cpu.instructionCount, last.inputIndex == inputBase + inputs.count { return }
        attach(m)
        points.append(Point(ticks: m.nominalTicks, state: m.snapshot(createdBy: "rewind", compressionLevel: 1),
                            thumbnail: Self.thumbnail(of: m.currentFrame), hardDiscWrites: Self.hardDiscWrites(m),
                            instructions: m.cpu.instructionCount, inputIndex: inputBase + inputs.count))
        if points.count > capacity { points.removeFirst(points.count - capacity) }
        // Inputs before the oldest point can no longer be replayed.
        if let first = points.first, first.inputIndex > inputBase {
            inputs.removeFirst(first.inputIndex - inputBase)
            inputBase = first.inputIndex
        }
    }

    /// A point now, after something from outside changed the machine.
    public func keyframe(_ m: Machine) { capture(m) }

    public func reset() { points.removeAll(); inputBase += inputs.count; inputs.removeAll() }

    /// Records `m`'s live inputs (call when a machine joins the timeline).
    public func attach(_ m: Machine) {
        m.inputRecorder = { [weak self] e in self?.inputs.append(e) }
    }

    /// Recorded inputs from point `i` up to and including `ticks`.
    func inputs(from i: Int, through ticks: UInt64) -> [Machine.InputEvent] {
        let from = max(0, points[i].inputIndex - inputBase)
        return Array(inputs[min(from, inputs.count)...].prefix { $0.tick <= ticks })
    }

    /// A fresh machine at point `i`, with its later inputs (to `ticks`) queued.
    func restore(_ i: Int, from current: Machine, inputsThrough ticks: UInt64) throws -> Machine {
        let p = points[i]
        let discs = current.fdc.drives.map(\.disc)
        let m = try Machine.restore(snapshot: p.state, rom: current.rom, resolveDisc: { media in
            discs[media.drive].flatMap { $0.sha256 == media.sha256 ? $0 : nil }
        }, hardDiscs: current.hardDiscImages)
        m.replay(inputs(from: i, through: ticks))
        return m
    }

    /// Drops the history after a point the timeline now continues from.
    func truncate(afterPoint i: Int, inputsAfter ticks: UInt64) {
        points.removeSubrange((i + 1)...)
        let keep = inputs.prefix { $0.tick <= ticks }.count
        inputs.removeSubrange(keep...)
    }

    static func hardDiscWrites(_ m: Machine) -> UInt64 {
        m.hardDiscImages.reduce(0) { $0 &+ ($1?.writeCount ?? 0) }
    }

    /// Whether the hard discs have been written since the point a rewind
    /// to `ticks` would restore. Hard discs keep their contents, so RISC OS
    /// would then find the disc changed under its feet.
    public func hardDiscChanged(goingBackTo ticks: UInt64, from current: Machine) -> Bool {
        guard let p = points.last(where: { $0.ticks <= ticks }) ?? points.first else { return false }
        return p.hardDiscWrites != Self.hardDiscWrites(current)
    }

    /// A machine at guest time `ticks` (clamped to the history), built from
    /// the nearest earlier point and run forward. `current` lends its discs,
    /// hard discs and ROM. Later points are dropped: the timeline continues from here.
    public func machine(at ticks: UInt64, from current: Machine) throws -> Machine? {
        guard let i = points.lastIndex(where: { $0.ticks <= ticks }) ?? (points.isEmpty ? nil : 0) else { return nil }
        let p = points[i]
        let target = max(ticks, p.ticks)
        let m = try restore(i, from: current, inputsThrough: target)
        // Breakpoints come along only once there: replaying must not stop.
        if target > p.ticks { m.run(ticks: target - p.ticks) }
        if let d = current.debuggerIfCreated { m.debugger.adopt(d) }
        truncate(afterPoint: i, inputsAfter: target)
        attach(m)
        return m
    }

    /// A machine just before instruction number `n` (as counted by the CPU)
    /// was executed, with any interrupt taken first as it was then.
    public func machine(atInstruction n: UInt64, ticks: UInt64, from current: Machine) throws -> Machine? {
        guard let i = points.lastIndex(where: { $0.instructions <= n }) else { return nil }
        let m = try restore(i, from: current, inputsThrough: ticks)
        if n > m.cpu.instructionCount { m.run(untilTick: .max, maxInstructions: n - m.cpu.instructionCount) }
        if let d = current.debuggerIfCreated { m.debugger.adopt(d) }
        m.settleBeforeInstruction()
        truncate(afterPoint: i, inputsAfter: ticks)
        attach(m)
        return m
    }

    /// Nearest-neighbour reduction of a frame, keeping its display aspect.
    static func thumbnail(of f: VideoFrame) -> [UInt32] {
        let tw = thumbnailWidth, th = thumbnailHeight
        var out = [UInt32](repeating: 0xFF00_0000, count: tw * th)
        guard f.width > 1, f.height > 1 else { return out }
        let aspect = Double(f.width * f.scaleX) / Double(f.height * f.scaleY)
        var w = Double(tw), h = Double(tw) / aspect
        if h > Double(th) { h = Double(th); w = h * aspect }
        let x0 = (Double(tw) - w) / 2, y0 = (Double(th) - h) / 2
        for y in 0..<th {
            let v = (Double(y) + 0.5 - y0) / h
            guard v >= 0, v < 1 else { continue }
            let sy = Int(v * Double(f.height))
            for x in 0..<tw {
                let u = (Double(x) + 0.5 - x0) / w
                guard u >= 0, u < 1 else { continue }
                out[y * tw + x] = f.pixels[sy * f.width + Int(u * Double(f.width))]
            }
        }
        return out
    }
}
