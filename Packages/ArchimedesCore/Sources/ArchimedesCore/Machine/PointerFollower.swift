/// Moves RISC OS's pointer to a spot on the screen, for a Mac cursor the
/// machine follows without capturing it. The Archimedes mouse only counts
/// movement, and how far a count moves the pointer depends on the mode and
/// on *Configure MouseStep, so this steers: once a frame it looks at where
/// the hardware pointer is, sends the counts that should close the gap, and
/// learns from how far the last ones moved it.
///
/// It steers only for a while after the target moves, so a program that
/// puts the pointer somewhere itself isn't fought. While the hardware
/// pointer is off (games that draw their own), movement is passed on as
/// counts instead.
public final class PointerFollower {
    /// Where the pointer should be, in frame pixels; nil to leave it be.
    public var target: (x: Int, y: Int)? {
        didSet {
            guard let t = target else { return }
            if let o = oldValue, o == t { return }
            framesLeft = Self.steerFrames
        }
    }

    /// Frames to keep steering after the target last moved.
    static let steerFrames = 50
    private var framesLeft = 0

    /// Pixels a count moves the pointer, across and down, as last seen.
    private(set) var gain = (x: 1.0, y: 1.0)
    /// Counts sent and not yet seen to move the pointer, and where it was.
    private var sent: (dx: Int, dy: Int, from: (x: Int, y: Int), frames: Int)?

    public init() {}

    /// Movement while the hardware pointer is off, in counts (+y up).
    public func moveBy(dx: Int, dy: Int, in m: Machine) {
        if !m.vidc.pointerShown, dx != 0 || dy != 0 { m.mouseMove(dx: dx, dy: dy) }
    }

    /// Called once a frame.
    public func frame(_ m: Machine) {
        guard let t = target, m.vidc.pointerShown else { sent = nil; return }
        let p = m.vidc.pointerHotspot
        if let s = sent {
            // Wait for RISC OS to take the counts and move the pointer.
            let waiting = m.keyboard.mouseDX != 0 || m.keyboard.mouseDY != 0
            let moved = (x: p.x - s.from.x, y: p.y - s.from.y)
            if (waiting || (moved.x == 0 && moved.y == 0)) && s.frames < 4 {
                sent = (s.dx, s.dy, s.from, s.frames + 1)
                return
            }
            sent = nil
            gain.x = Self.learn(gain.x, moved: moved.x, counts: s.dx)
            gain.y = Self.learn(gain.y, moved: moved.y, counts: -s.dy)
        }
        guard framesLeft > 0 else { return }
        framesLeft -= 1
        let dx = Self.counts(t.x - p.x, gain.x), dy = -Self.counts(t.y - p.y, gain.y)
        if dx == 0 && dy == 0 { framesLeft = 0; return }
        m.mouseMove(dx: dx, dy: dy)
        sent = (dx, dy, p, 0)
    }

    private static func counts(_ error: Int, _ gain: Double) -> Int {
        max(-256, min(256, Int((Double(error) / gain).rounded())))
    }

    /// A new estimate of pixels a count, from a move big enough to tell
    /// and not stopped short by the edge of the screen.
    private static func learn(_ gain: Double, moved: Int, counts: Int) -> Double {
        guard abs(counts) >= 4, moved != 0, (moved > 0) == (counts > 0) else { return gain }
        let seen = Double(moved) / Double(counts)
        return max(0.125, min(8, (gain + seen) / 2))
    }
}
