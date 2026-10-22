@testable import ArchimedesCore

/// Flat 1 MB memory bus for CPU tests. Addresses >= `abortFrom` abort.
final class TestBus: ARMBus {
    var ticks: UInt64 = 0
    var stopAt: UInt64 = .max
    var abort = false
    var privileged = true
    var mem = [UInt8](repeating: 0, count: 1 << 20)
    var abortFrom: UInt32 = 0x0010_0000
    var writes: [(UInt32, UInt32)] = []

    func fetch(_ a: UInt32, sequential: Bool) -> UInt32 { readWord(a, sequential: sequential) }
    func readWord(_ a: UInt32, sequential: Bool) -> UInt32 {
        ticks += 3
        if a >= abortFrom { abort = true; return 0 }
        let i = Int(a & ~3)
        return UInt32(mem[i]) | UInt32(mem[i + 1]) << 8 | UInt32(mem[i + 2]) << 16 | UInt32(mem[i + 3]) << 24
    }
    func readByte(_ a: UInt32) -> UInt32 {
        ticks += 3
        if a >= abortFrom { abort = true; return 0 }
        return UInt32(mem[Int(a)])
    }
    func writeWord(_ a: UInt32, _ v: UInt32, sequential: Bool) {
        ticks += 3
        if a >= abortFrom { abort = true; return }
        let i = Int(a & ~3)
        mem[i] = UInt8(v & 0xFF); mem[i + 1] = UInt8((v >> 8) & 0xFF); mem[i + 2] = UInt8((v >> 16) & 0xFF); mem[i + 3] = UInt8(v >> 24)
        writes.append((a, v))
    }
    func writeByte(_ a: UInt32, _ v: UInt8) {
        ticks += 3
        if a >= abortFrom { abort = true; return }
        mem[Int(a)] = v
        writes.append((a, UInt32(v)))
    }
    func word(_ a: UInt32) -> UInt32 { readWord(a, sequential: false) }
    func put(_ a: UInt32, _ v: UInt32) {
        let i = Int(a)
        mem[i] = UInt8(v & 0xFF); mem[i + 1] = UInt8((v >> 8) & 0xFF); mem[i + 2] = UInt8((v >> 16) & 0xFF); mem[i + 3] = UInt8(v >> 24)
    }
}

/// Minimal ARM2 instruction encoder for tests.
enum A {
    static let EQ: UInt32 = 0, NE: UInt32 = 1, CS: UInt32 = 2, CC: UInt32 = 3, MI: UInt32 = 4, PL: UInt32 = 5
    static let VS: UInt32 = 6, VC: UInt32 = 7, HI: UInt32 = 8, LS: UInt32 = 9, GE: UInt32 = 10, LT: UInt32 = 11
    static let GT: UInt32 = 12, LE: UInt32 = 13, AL: UInt32 = 14, NV: UInt32 = 15

    enum Op: UInt32 { case and = 0, eor, sub, rsb, add, adc, sbc, rsc, tst, teq, cmp, cmn, orr, mov, bic, mvn }
    enum Shift: UInt32 { case lsl = 0, lsr, asr, ror }

    /// Data processing with immediate operand (value must be encodable).
    static func dpi(_ op: Op, s: Bool = false, rd: UInt32 = 0, rn: UInt32 = 0, imm: UInt32, cond: UInt32 = AL) -> UInt32 {
        var rot: UInt32 = 0
        var v = imm
        while v > 0xFF && rot < 16 { v = (v << 2) | (v >> 30); rot += 1 }
        precondition(v <= 0xFF, "immediate not encodable")
        return cond << 28 | 1 << 25 | op.rawValue << 21 | (s ? 1 << 20 : 0) | rn << 16 | rd << 12 | rot << 8 | v
    }

    /// Data processing with register operand shifted by immediate.
    static func dpr(_ op: Op, s: Bool = false, rd: UInt32 = 0, rn: UInt32 = 0, rm: UInt32, shift: Shift = .lsl, amount: UInt32 = 0, cond: UInt32 = AL) -> UInt32 {
        cond << 28 | op.rawValue << 21 | (s ? 1 << 20 : 0) | rn << 16 | rd << 12 | amount << 7 | shift.rawValue << 5 | rm
    }

    /// Data processing with register operand shifted by register.
    static func dprs(_ op: Op, s: Bool = false, rd: UInt32 = 0, rn: UInt32 = 0, rm: UInt32, shift: Shift, rs: UInt32, cond: UInt32 = AL) -> UInt32 {
        cond << 28 | op.rawValue << 21 | (s ? 1 << 20 : 0) | rn << 16 | rd << 12 | rs << 8 | shift.rawValue << 5 | 1 << 4 | rm
    }

    static func ldr(rd: UInt32, rn: UInt32, offset: Int32 = 0, pre: Bool = true, wb: Bool = false, byte: Bool = false, cond: UInt32 = AL) -> UInt32 {
        sdt(load: true, rd: rd, rn: rn, offset: offset, pre: pre, wb: wb, byte: byte, cond: cond)
    }
    static func str(rd: UInt32, rn: UInt32, offset: Int32 = 0, pre: Bool = true, wb: Bool = false, byte: Bool = false, cond: UInt32 = AL) -> UInt32 {
        sdt(load: false, rd: rd, rn: rn, offset: offset, pre: pre, wb: wb, byte: byte, cond: cond)
    }
    static func sdt(load: Bool, rd: UInt32, rn: UInt32, offset: Int32, pre: Bool, wb: Bool, byte: Bool, cond: UInt32) -> UInt32 {
        let up = offset >= 0
        let mag = UInt32(abs(offset))
        return cond << 28 | 1 << 26 | (pre ? 1 << 24 : 0) | (up ? 1 << 23 : 0) | (byte ? 1 << 22 : 0) | (wb ? 1 << 21 : 0) | (load ? 1 << 20 : 0) | rn << 16 | rd << 12 | mag
    }

    static func ldm(rn: UInt32, regs: [UInt32], pre: Bool = false, up: Bool = true, wb: Bool = false, s: Bool = false, cond: UInt32 = AL) -> UInt32 {
        bdt(load: true, rn: rn, regs: regs, pre: pre, up: up, wb: wb, s: s, cond: cond)
    }
    static func stm(rn: UInt32, regs: [UInt32], pre: Bool = false, up: Bool = true, wb: Bool = false, s: Bool = false, cond: UInt32 = AL) -> UInt32 {
        bdt(load: false, rn: rn, regs: regs, pre: pre, up: up, wb: wb, s: s, cond: cond)
    }
    static func bdt(load: Bool, rn: UInt32, regs: [UInt32], pre: Bool, up: Bool, wb: Bool, s: Bool, cond: UInt32) -> UInt32 {
        var list: UInt32 = 0
        for r in regs { list |= 1 << r }
        return cond << 28 | 4 << 25 | (pre ? 1 << 24 : 0) | (up ? 1 << 23 : 0) | (s ? 1 << 22 : 0) | (wb ? 1 << 21 : 0) | (load ? 1 << 20 : 0) | rn << 16 | list
    }

    static func b(from: UInt32, to: UInt32, link: Bool = false, cond: UInt32 = AL) -> UInt32 {
        let off = (Int64(to) - Int64(from) - 8) >> 2
        return cond << 28 | 5 << 25 | (link ? 1 << 24 : 0) | (UInt32(truncatingIfNeeded: off) & 0x00FF_FFFF)
    }

    static func swi(_ n: UInt32, cond: UInt32 = AL) -> UInt32 { cond << 28 | 0xF << 24 | (n & 0xFF_FFFF) }

    static func mul(rd: UInt32, rm: UInt32, rs: UInt32, s: Bool = false) -> UInt32 {
        AL << 28 | (s ? 1 << 20 : 0) | rd << 16 | rs << 8 | 0x90 | rm
    }
    static func mla(rd: UInt32, rm: UInt32, rs: UInt32, rn: UInt32, s: Bool = false) -> UInt32 {
        AL << 28 | 1 << 21 | (s ? 1 << 20 : 0) | rd << 16 | rn << 12 | rs << 8 | 0x90 | rm
    }
    static let nop: UInt32 = 0xE1A0_0000 // MOV R0, R0
}

final class CPUHarness {
    let bus = TestBus()
    let cpu: ARM2<TestBus>

    init() {
        cpu = ARM2(bus: bus)
        // Reset leaves SVC mode, IRQ/FIQ disabled, PC = 0.
    }

    /// Place a program at `at` and point the PC at it.
    func load(_ program: [UInt32], at: UInt32 = 0x8000) {
        for (i, w) in program.enumerated() { bus.put(at + UInt32(i * 4), w) }
        cpu.pc = at
        cpu.flushPipeline()
    }

    func run(_ n: Int) { for _ in 0..<n { cpu.step() } }

    /// Execute a straight-line program to completion.
    func exec(_ program: [UInt32], at: UInt32 = 0x8000) {
        load(program, at: at)
        run(program.count)
    }

    var n: Bool { cpu.psr & 0x8000_0000 != 0 }
    var z: Bool { cpu.psr & 0x4000_0000 != 0 }
    var c: Bool { cpu.psr & 0x2000_0000 != 0 }
    var v: Bool { cpu.psr & 0x1000_0000 != 0 }

    func setFlags(n: Bool = false, z: Bool = false, c: Bool = false, v: Bool = false) {
        cpu.psr = (cpu.psr & 0x0FFF_FFFF) | (n ? 0x8000_0000 : 0) | (z ? 0x4000_0000 : 0) | (c ? 0x2000_0000 : 0) | (v ? 0x1000_0000 : 0)
    }

    /// Switch to a mode via the debugger path (banks registers).
    func enter(_ mode: ARM2<TestBus>.Mode) {
        cpu.setPSR((cpu.psr & ~3) | mode.rawValue)
    }
}
