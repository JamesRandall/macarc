/// The memory/timing interface the ARM2 core drives.
///
/// All addresses are the full 32-bit values placed on the address bus by the
/// CPU; address-exception checking (bits 26-31 set) is done by the CPU before
/// calling these. Implementations charge their own access time to `ticks` and
/// set `abort` when the access is refused (MEMC page fault / privilege).
public protocol ARMBus: AnyObject {
    /// Master clock (24 MHz ticks). Advanced by every bus access and by the CPU
    /// for internal cycles.
    var ticks: UInt64 { get set }
    /// The CPU returns from `run` as soon as `ticks >= stopAt`.
    var stopAt: UInt64 { get set }
    /// Set by an access that aborts; cleared by the CPU.
    var abort: Bool { get set }
    /// Mirrors the processor's privileged state (any mode other than USR),
    /// overridden for LDRT/STRT.
    var privileged: Bool { get set }

    func fetch(_ address: UInt32, sequential: Bool) -> UInt32
    func readWord(_ address: UInt32, sequential: Bool) -> UInt32
    func readByte(_ address: UInt32) -> UInt32
    func writeWord(_ address: UInt32, _ value: UInt32, sequential: Bool)
    func writeByte(_ address: UInt32, _ value: UInt8)

    /// Ticks per internal (I) cycle at the processor's current clock.
    var iCycle: UInt64 { get }
    /// The ARM3 cache's enable bit (CP15 register 2) changed.
    func cacheControlChanged()
}

extension ARMBus {
    public var iCycle: UInt64 { MasterClock.iCycle }
    public func cacheControlChanged() {}
}

/// 24 MHz master clock helpers. 8 MHz ARM S-cycle = 3 ticks.
public enum MasterClock {
    public static let ticksPerSecond: UInt64 = 24_000_000
    public static let sCycle: UInt64 = 3
    public static let nCycle: UInt64 = 6
    public static let iCycle: UInt64 = 3
    public static func ticks(microseconds us: UInt64) -> UInt64 { us * 24 }
    public static func ticks(milliseconds ms: UInt64) -> UInt64 { ms * 24_000 }
}
