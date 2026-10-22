/// The ARM3's 4 KB mixed instruction and data cache, modelled for timing.
///
/// 256 lines of 16 bytes, in four sets chosen by address bits 4-5, each set
/// of 64 lines fully associative with pseudo-random replacement. The cache
/// sits before MEMC and holds logical addresses. Data always comes from
/// memory here: only whether a line is resident is tracked, which decides
/// whether an access runs at the processor clock or waits for a line fill.
/// (Real ARM3s can return stale data when software forgets to flush; RISC
/// OS flushes correctly, so that is not modelled.)
public final class ARM3Cache {
    /// One bit per 16-byte line of the 64 MB address space.
    private var present = [UInt64](repeating: 0, count: 1 << 16)
    /// Resident line numbers per set (or -1).
    private var slots = [[Int32]](repeating: [Int32](repeating: -1, count: 64), count: 4)
    /// Replacement generator (a linear congruential sequence: deterministic).
    private var victim: UInt32 = 1

    // CP15 registers.
    public internal(set) var control: UInt32 = 0
    public internal(set) var cacheable: UInt32 = 0
    public internal(set) var updateable: UInt32 = 0
    public internal(set) var disruptive: UInt32 = 0

    public var enabled: Bool { control & 1 != 0 }

    public init() {}

    @inline(__always) func isCacheable(_ a: UInt32) -> Bool { (cacheable >> (a >> 21)) & 1 != 0 }

    @inline(__always) func contains(_ a: UInt32) -> Bool {
        let line = Int(a >> 4)
        return (present[line >> 6] >> UInt64(line & 63)) & 1 != 0
    }

    /// Fill the line holding `a`, evicting a pseudo-randomly chosen line.
    func fill(_ a: UInt32) {
        let line = Int32(a >> 4)
        let set = Int(line & 3)
        victim = victim &* 1_103_515_245 &+ 12345
        let slot = Int((victim >> 16) & 63)
        let old = slots[set][slot]
        if old >= 0 { present[Int(old) >> 6] &= ~(1 << UInt64(old & 63)) }
        slots[set][slot] = line
        present[Int(line) >> 6] |= 1 << UInt64(line & 63)
    }

    public func flush() {
        for set in 0..<4 {
            for slot in 0..<64 where slots[set][slot] >= 0 {
                let old = slots[set][slot]
                present[Int(old) >> 6] &= ~(1 << UInt64(old & 63))
                slots[set][slot] = -1
            }
        }
    }

    public func reset() {
        flush()
        control = 0
    }

    /// MRC: read CP15 register `n`.
    func read(_ n: UInt32) -> UInt32 {
        switch n {
        case 0: 0x4156_0300 // ARM3 identity
        case 2: control
        case 3: cacheable
        case 4: updateable
        case 5: disruptive
        default: 0
        }
    }

    /// MCR: write CP15 register `n`.
    func write(_ n: UInt32, _ v: UInt32) {
        switch n {
        case 1: flush()
        case 2: control = v & 7
        case 3: cacheable = v
        case 4: updateable = v
        case 5: disruptive = v
        default: break
        }
    }

    func saveState(_ w: inout StateWriter) {
        w.u32(control); w.u32(cacheable); w.u32(updateable); w.u32(disruptive); w.u32(victim)
        for set in 0..<4 { for slot in 0..<64 { w.u32(UInt32(bitPattern: slots[set][slot])) } }
    }

    func loadState(_ r: inout StateReader) throws {
        flush()
        control = try r.u32(); cacheable = try r.u32(); updateable = try r.u32(); disruptive = try r.u32(); victim = try r.u32()
        for set in 0..<4 {
            for slot in 0..<64 {
                let line = Int32(bitPattern: try r.u32())
                slots[set][slot] = line
                if line >= 0 { present[Int(line) >> 6] |= 1 << UInt64(line & 63) }
            }
        }
    }
}
