/// ARM2 processor core: original 26-bit programmer's model.
///
/// R15 holds the PC (bits 25-2) together with the PSR: N Z C V (31-28),
/// I F (27-26) and the mode (1-0). Here the PC and PSR parts are kept apart
/// (`pc`, `psr`) and recombined whenever software observes R15.
///
/// Execution model: when an instruction at address A executes, `pc` already
/// holds A+4, so reading R15 normally yields `pc + 4` (= A+8, the pipelined
/// value), and A+12 for the cases where the ARM2 has advanced a further stage
/// (register-specified shifts, STR/STM of R15).
///
/// Differences from later cores that are deliberately modelled:
///  * no SWP/SWPB unless an ARM3 or ARM250 is modelled (`hasSWP`); otherwise these
///    encodings take the undefined-instruction trap;
///  * no coprocessors except the ARM3's CP15 (cache control, privileged
///    MCR/MRC only); every other CDP/LDC/STC/MCR/MRC is undefined;
///  * no MRS/MSR/CPSR/SPSR (ARMv3) — TST/TEQ/CMP/CMN with S=0 are no-ops;
///  * LDR into R15 writes only the PC field; LDM with ^ and R15 restores PSR;
///  * data addresses with any of bits 26-31 set raise the address exception.
public final class ARM2<Bus: ARMBus> {
    public enum Mode: UInt32, CustomStringConvertible, Sendable {
        case user = 0, fiq = 1, irq = 2, supervisor = 3
        public var description: String {
            switch self {
            case .user: return "USR"
            case .fiq: return "FIQ"
            case .irq: return "IRQ"
            case .supervisor: return "SVC"
            }
        }
    }

    public static var pcMask: UInt32 { 0x03FF_FFFC }
    public static var flagN: UInt32 { 0x8000_0000 }
    public static var flagZ: UInt32 { 0x4000_0000 }
    public static var flagC: UInt32 { 0x2000_0000 }
    public static var flagV: UInt32 { 0x1000_0000 }
    public static var flagI: UInt32 { 0x0800_0000 }
    public static var flagF: UInt32 { 0x0400_0000 }

    public enum Vector: UInt32 {
        case reset = 0x00, undefined = 0x04, swi = 0x08, prefetchAbort = 0x0C
        case dataAbort = 0x10, addressException = 0x14, irq = 0x18, fiq = 0x1C
    }

    public let bus: Bus
    /// The ARM3's cache controller (CP15), when an ARM3 is fitted.
    public private(set) var cp15: ARM3Cache?
    /// SWP/SWPB (ARM3 and ARM250).
    public var hasSWP = false

    /// Currently visible R0-R14 (index 15 unused; use `r15`).
    public let r: UnsafeMutablePointer<UInt32>
    /// User-mode R8-R14 (R8-R12 are only authoritative while in FIQ mode).
    let userBank: UnsafeMutablePointer<UInt32>
    let fiqBank: UnsafeMutablePointer<UInt32>
    let irqBank: UnsafeMutablePointer<UInt32>
    let svcBank: UnsafeMutablePointer<UInt32>

    /// Address of the next instruction to fetch (while an instruction is
    /// executing: its address + 4).
    public var pc: UInt32 = 0
    /// Flags/interrupt mask/mode; PC bits always zero.
    public var psr: UInt32 = 0x0C00_0003

    /// Interrupt request lines driven by IOC (active high here).
    public var irqLine = false
    public var fiqLine = false

    var sequentialFetch = false
    let conditions: UnsafeMutablePointer<UInt16>

    // Diagnostics
    public var instructionCount: UInt64 = 0
    public var exceptionCounts = [UInt64](repeating: 0, count: 8)
    public var lastException: (vector: Vector, address: UInt32, instructionCount: UInt64)?
    public var stopReason: StopReason = .none
    /// The machine's debugger, called for every instruction (and data
    /// access) while `debugHooks` is on.
    public unowned(unsafe) var debugger: Debugger?
    public var debugHooks = false
    /// Address of the instruction currently/last executed.
    public private(set) var currentInstructionAddress: UInt32 = 0
    /// Optional hook invoked for SWIs (diagnostics only; never alters behaviour).
    public var swiObserver: ((UInt32, UInt32) -> Void)?

    public enum StopReason: Equatable, Sendable {
        case none
        case debugger
        case budget
    }

    public init(bus: Bus) {
        self.bus = bus
        r = .allocate(capacity: 16); r.initialize(repeating: 0, count: 16)
        userBank = .allocate(capacity: 7); userBank.initialize(repeating: 0, count: 7)
        fiqBank = .allocate(capacity: 7); fiqBank.initialize(repeating: 0, count: 7)
        irqBank = .allocate(capacity: 2); irqBank.initialize(repeating: 0, count: 2)
        svcBank = .allocate(capacity: 2); svcBank.initialize(repeating: 0, count: 2)
        conditions = .allocate(capacity: 16)
        for c in 0..<16 { conditions[c] = conditionTable[c] }
        reset()
    }

    deinit {
        r.deallocate(); userBank.deallocate(); fiqBank.deallocate()
        irqBank.deallocate(); svcBank.deallocate(); conditions.deallocate()
    }

    /// Make this an ARM3: SWP/SWPB and the CP15 cache controller, whose
    /// cache sits in front of the bus.
    public func fitARM3(cache: ARM3Cache) { cp15 = cache; hasSWP = true }

    // MARK: - Architectural state access

    public var mode: Mode { Mode(rawValue: psr & 3)! }

    /// R15 as the programmer sees it (PC of next instruction | PSR).
    public var r15: UInt32 { (pc & Self.pcMask) | psr }

    public func reset() {
        exceptionCounts[0] &+= 1
        let old = r15
        setMode(3)
        r[14] = old
        psr = Self.flagI | Self.flagF | 3
        pc = 0
        sequentialFetch = false
        flushPipeline()
        bus.privileged = true
    }

    /// Debugger/test read of any register as visible in the current mode.
    public func register(_ n: Int) -> UInt32 { n == 15 ? r15 : r[n] }

    /// Debugger/test write of a register in the current mode.
    public func setRegister(_ n: Int, _ value: UInt32) {
        if n == 15 {
            pc = value & Self.pcMask
            setPSR(value & 0xFC00_0003)
            sequentialFetch = false
            flushPipeline()
        } else {
            r[n] = value
        }
    }

    /// Registers of a specific bank (for diagnostics). Returns R8-R14 for the
    /// requested mode, regardless of the current mode.
    public func bankedRegisters(_ m: Mode) -> [UInt32] {
        let cur = psr & 3
        var out = [UInt32](repeating: 0, count: 7)
        for i in 0..<7 {
            let idx = 8 + i
            if m.rawValue == cur { out[i] = r[idx]; continue }
            switch m {
            case .fiq: out[i] = fiqBank[i]
            case .user:
                if idx < 13 { out[i] = cur == 1 ? userBank[i] : r[idx] } else { out[i] = userBank[i] }
            case .irq:
                if idx < 13 { out[i] = cur == 1 ? userBank[i] : r[idx] } else { out[i] = irqBank[idx - 13] }
            case .supervisor:
                if idx < 13 { out[i] = cur == 1 ? userBank[i] : r[idx] } else { out[i] = svcBank[idx - 13] }
            }
        }
        return out
    }

    @inline(__always) func setMode(_ newMode: UInt32) {
        let oldMode = psr & 3
        if oldMode == newMode { return }
        // Save outgoing registers.
        if oldMode == 1 {
            for i in 0..<7 { fiqBank[i] = r[8 + i] }
        } else {
            for i in 0..<5 { userBank[i] = r[8 + i] }
            switch oldMode {
            case 0: userBank[5] = r[13]; userBank[6] = r[14]
            case 2: irqBank[0] = r[13]; irqBank[1] = r[14]
            default: svcBank[0] = r[13]; svcBank[1] = r[14]
            }
        }
        // Load incoming registers.
        if newMode == 1 {
            for i in 0..<7 { r[8 + i] = fiqBank[i] }
        } else {
            for i in 0..<5 { r[8 + i] = userBank[i] }
            switch newMode {
            case 0: r[13] = userBank[5]; r[14] = userBank[6]
            case 2: r[13] = irqBank[0]; r[14] = irqBank[1]
            default: r[13] = svcBank[0]; r[14] = svcBank[1]
            }
        }
        psr = (psr & ~3) | newMode
        bus.privileged = newMode != 0
    }

    /// Install a complete PSR value (flags, I, F, mode), swapping banks.
    @inline(__always) func setPSR(_ value: UInt32) {
        setMode(value & 3)
        psr = value & 0xFC00_0003
    }

    /// Write the PSR portion of R15 obeying the 26-bit privilege rules: in
    /// user mode only N Z C V may change.
    @inline(__always) func writePSRFromR15(_ value: UInt32) {
        if psr & 3 == 0 {
            psr = (psr & 0x0FFF_FFFF) | (value & 0xF000_0000)
        } else {
            setPSR(value)
        }
    }

    @inline(__always) func readUserRegister(_ n: Int) -> UInt32 {
        let m = psr & 3
        if n < 8 || m == 0 { return n == 15 ? r15 : r[n] }
        if n == 15 { return r15 }
        if m == 1 { return userBank[n - 8] }
        return n < 13 ? r[n] : userBank[n - 8]
    }

    @inline(__always) func writeUserRegister(_ n: Int, _ v: UInt32) {
        let m = psr & 3
        if n < 8 || m == 0 { r[n] = v; return }
        if m == 1 { userBank[n - 8] = v; return }
        if n < 13 { r[n] = v } else { userBank[n - 8] = v }
    }

    // MARK: - Exceptions

    @inline(__always) func exception(_ vector: Vector, returnAddress: UInt32) {
        let index = Int(vector.rawValue >> 2)
        exceptionCounts[index] &+= 1
        lastException = (vector, currentInstructionAddress, instructionCount)
        let saved = (returnAddress & Self.pcMask) | psr
        let newMode: UInt32
        switch vector {
        case .irq: newMode = 2
        case .fiq: newMode = 1
        default: newMode = 3
        }
        setMode(newMode)
        r[14] = saved
        psr |= Self.flagI
        if vector == .fiq || vector == .reset { psr |= Self.flagF }
        pc = vector.rawValue
        sequentialFetch = false
        bus.ticks &+= 2 * bus.iCycle
    }

    // MARK: - Execution

    /// Execute until `bus.ticks >= bus.stopAt`, a debugger stop, or the
    /// instruction budget is exhausted.
    @discardableResult
    public func run(maxInstructions: UInt64 = .max) -> StopReason {
        stopReason = .none
        if debugHooks, let d = debugger { return runDebug(d, maxInstructions: maxInstructions) }
        var remaining = maxInstructions
        while bus.ticks < bus.stopAt {
            if remaining == 0 { stopReason = .budget; break }
            remaining &-= 1
            step()
        }
        return stopReason
    }

    /// The same execution as `run`, one instruction at a time, telling the
    /// debugger before and after each. An interrupt is entered first and the
    /// debugger sees the vector's instruction as the next one, so it can stop
    /// there.
    func runDebug(_ d: Debugger, maxInstructions: UInt64) -> StopReason {
        var remaining = maxInstructions
        while bus.ticks < bus.stopAt {
            if remaining == 0 { stopReason = .budget; break }
            if let v = takeInterrupt() {
                d.interruptTaken(v == .fiq ? "FIQ" : "IRQ")
                if d.isStopped { stopReason = .debugger; break }
            }
            if d.beforeExecute(pc) { stopReason = .debugger; break }
            remaining &-= 1
            let a = pc, t = bus.ticks, mode = psr & 3
            executeOne()
            d.afterExecute(a, ticks: bus.ticks &- t, mode: mode)
            if d.isStopped { stopReason = .debugger; break }
        }
        return stopReason
    }

    /// Execute exactly one instruction (or take one pending interrupt and
    /// execute the first handler instruction).
    var lastInstruction: UInt32 = 0

    // Three-stage pipeline: when the instruction at A executes, the words at
    // A+4 and A+8 have already been fetched, so stores to them are not seen
    // (software, e.g. Elite's loader, relies on this). `pipeAddress` is the
    // address of `pipe0`; any PC change away from it refills the pipeline.
    var pipeAddress: UInt32 = 0xFFFF_FFFF
    var pipe0: UInt32 = 0, pipe1: UInt32 = 0
    var pipeAbort0 = false, pipeAbort1 = false

    /// Discard prefetched instructions (after an external PC change).
    public func flushPipeline() { pipeAddress = 0xFFFF_FFFF }

    @inline(__always) func fetchWord(_ a: UInt32, sequential: Bool) -> (UInt32, Bool) {
        let w = bus.fetch(a, sequential: sequential)
        if bus.abort { bus.abort = false; return (w, true) }
        return (w, false)
    }

    /// Execute exactly one instruction (or take one pending interrupt and
    /// execute the first handler instruction).
    @inline(__always)
    public func step() {
        _ = takeInterrupt()
        executeOne()
    }

    /// Enters a pending FIQ or IRQ, if one is unmasked.
    @inline(__always)
    func takeInterrupt() -> Vector? {
        if fiqLine && (psr & Self.flagF) == 0 {
            exception(.fiq, returnAddress: pc &+ 4)
            return .fiq
        } else if irqLine && (psr & Self.flagI) == 0 {
            exception(.irq, returnAddress: pc &+ 4)
            return .irq
        }
        return nil
    }

    /// Executes the instruction at the PC.
    @inline(__always)
    func executeOne() {
        let address = pc
        currentInstructionAddress = address
        if address != pipeAddress {
            (pipe0, pipeAbort0) = fetchWord(address, sequential: false)
            (pipe1, pipeAbort1) = fetchWord((address &+ 4) & Self.pcMask, sequential: true)
            sequentialFetch = true
        }
        let instr = pipe0
        let aborted = pipeAbort0
        // Fetch A+8 before this instruction's own memory accesses.
        pipe0 = pipe1; pipeAbort0 = pipeAbort1
        (pipe1, pipeAbort1) = fetchWord((address &+ 8) & Self.pcMask, sequential: sequentialFetch)
        pipeAddress = (address &+ 4) & Self.pcMask
        lastInstruction = instr
        instructionCount &+= 1
        if aborted {
            exception(.prefetchAbort, returnAddress: address &+ 4)
            return
        }
        sequentialFetch = true
        pc = (address &+ 4) & Self.pcMask
        let cond = instr >> 28
        if cond != 0xE {
            if (conditions[Int(cond)] >> (psr >> 28)) & 1 == 0 { return }
        }
        execute(instr)
    }

    @inline(__always) func execute(_ i: UInt32) {
        switch (i >> 25) & 7 {
        case 0:
            if (i & 0x0FC0_00F0) == 0x0000_0090 {
                multiply(i)
            } else if (i & 0x0FB0_0FF0) == 0x0100_0090 && hasSWP {
                swap(i)
            } else if (i & 0x0E00_0090) == 0x0000_0090 {
                // SWP (ARM3 only) and ARMv4 halfword encodings.
                undefined()
            } else {
                dataProcessing(i)
            }
        case 1:
            dataProcessing(i)
        case 2:
            singleDataTransfer(i)
        case 3:
            if i & 0x10 != 0 { undefined() } else { singleDataTransfer(i) }
        case 4:
            blockDataTransfer(i)
        case 5:
            branch(i)
        case 6:
            undefined() // LDC/STC: no coprocessor fitted
        default:
            if i & 0x0100_0000 != 0 {
                swiObserver?(currentInstructionAddress, i & 0x00FF_FFFF)
                exception(.swi, returnAddress: pc)
            } else if i & 0x10 != 0 && (i >> 8) & 0xF == 15 && cp15 != nil && psr & 3 != 0 {
                coprocessor15(i)
            } else {
                undefined() // CDP/MCR/MRC
            }
        }
    }

    @inline(__always) func undefined() {
        exception(.undefined, returnAddress: pc)
    }

    // MARK: Flags helpers

    @inline(__always) func setNZ(_ v: UInt32) {
        psr = (psr & 0x3FFF_FFFF) | (v & 0x8000_0000) | (v == 0 ? 0x4000_0000 : 0)
    }

    @inline(__always) func setNZC(_ v: UInt32, _ c: UInt32) {
        psr = (psr & 0x1FFF_FFFF) | (v & 0x8000_0000) | (v == 0 ? 0x4000_0000 : 0) | (c << 29)
    }

    @inline(__always) func setNZCV(_ v: UInt32, _ c: UInt32, _ ov: UInt32) {
        psr = (psr & 0x0FFF_FFFF) | (v & 0x8000_0000) | (v == 0 ? 0x4000_0000 : 0) | (c << 29) | (ov << 28)
    }

    @inline(__always) var carry: UInt32 { (psr >> 29) & 1 }

    // MARK: Shifter

    /// Immediate-amount shift. Returns (value, carry-out).
    @inline(__always) func shiftImmediate(_ v: UInt32, type: UInt32, amount: UInt32) -> (UInt32, UInt32) {
        switch type {
        case 0: // LSL
            if amount == 0 { return (v, carry) }
            return (v << amount, (v >> (32 - amount)) & 1)
        case 1: // LSR (#0 encodes #32)
            if amount == 0 { return (0, v >> 31) }
            return (v >> amount, (v >> (amount - 1)) & 1)
        case 2: // ASR (#0 encodes #32)
            if amount == 0 { let s = UInt32(bitPattern: Int32(bitPattern: v) >> 31); return (s, v >> 31) }
            return (UInt32(bitPattern: Int32(bitPattern: v) >> Int32(amount)), (v >> (amount - 1)) & 1)
        default: // ROR (#0 encodes RRX)
            if amount == 0 { return ((carry << 31) | (v >> 1), v & 1) }
            return ((v >> amount) | (v << (32 - amount)), (v >> (amount - 1)) & 1)
        }
    }

    /// Register-amount shift (bottom byte of Rs).
    @inline(__always) func shiftRegister(_ v: UInt32, type: UInt32, amount: UInt32) -> (UInt32, UInt32) {
        if amount == 0 { return (v, carry) }
        switch type {
        case 0:
            if amount < 32 { return (v << amount, (v >> (32 - amount)) & 1) }
            if amount == 32 { return (0, v & 1) }
            return (0, 0)
        case 1:
            if amount < 32 { return (v >> amount, (v >> (amount - 1)) & 1) }
            if amount == 32 { return (0, v >> 31) }
            return (0, 0)
        case 2:
            if amount < 32 { return (UInt32(bitPattern: Int32(bitPattern: v) >> Int32(amount)), (v >> (amount - 1)) & 1) }
            return (UInt32(bitPattern: Int32(bitPattern: v) >> 31), v >> 31)
        default:
            let a = amount & 31
            if a == 0 { return (v, v >> 31) }
            return ((v >> a) | (v << (32 - a)), (v >> (a - 1)) & 1)
        }
    }

    // MARK: Data processing

    @inline(__always) func dataProcessing(_ i: UInt32) {
        let opcode = (i >> 21) & 0xF
        let s = (i & 0x0010_0000) != 0
        let rn = Int((i >> 16) & 0xF)
        let rd = Int((i >> 12) & 0xF)
        var op2: UInt32
        var shc: UInt32
        var a: UInt32

        if i & 0x0200_0000 != 0 {
            let rot = (i >> 7) & 0x1E
            let imm = i & 0xFF
            if rot == 0 {
                op2 = imm; shc = carry
            } else {
                op2 = (imm >> rot) | (imm << (32 - rot)); shc = op2 >> 31
            }
            a = rn == 15 ? (pc &+ 4) & Self.pcMask : r[rn]
        } else {
            let rm = Int(i & 0xF)
            let type = (i >> 5) & 3
            if i & 0x10 == 0 {
                let v = rm == 15 ? ((pc &+ 4) & Self.pcMask) | psr : r[rm]
                (op2, shc) = shiftImmediate(v, type: type, amount: (i >> 7) & 0x1F)
                a = rn == 15 ? (pc &+ 4) & Self.pcMask : r[rn]
            } else {
                bus.ticks &+= bus.iCycle
                let rs = Int((i >> 8) & 0xF)
                let amount = (rs == 15 ? (pc &+ 8) : r[rs]) & 0xFF
                let v = rm == 15 ? ((pc &+ 8) & Self.pcMask) | psr : r[rm]
                (op2, shc) = shiftRegister(v, type: type, amount: amount)
                a = rn == 15 ? (pc &+ 8) & Self.pcMask : r[rn]
            }
        }

        var result: UInt32 = 0
        switch opcode {
        case 0x0: // AND
            result = a & op2
            if s && rd != 15 { setNZC(result, shc) }
        case 0x1: // EOR
            result = a ^ op2
            if s && rd != 15 { setNZC(result, shc) }
        case 0x2: // SUB
            result = a &- op2
            if s && rd != 15 { setNZCV(result, a >= op2 ? 1 : 0, ((a ^ op2) & (a ^ result)) >> 31) }
        case 0x3: // RSB
            result = op2 &- a
            if s && rd != 15 { setNZCV(result, op2 >= a ? 1 : 0, ((op2 ^ a) & (op2 ^ result)) >> 31) }
        case 0x4: // ADD
            result = a &+ op2
            if s && rd != 15 { setNZCV(result, result < a ? 1 : 0, ((a ^ result) & (op2 ^ result)) >> 31) }
        case 0x5: // ADC
            let sum = UInt64(a) &+ UInt64(op2) &+ UInt64(carry)
            result = UInt32(truncatingIfNeeded: sum)
            if s && rd != 15 { setNZCV(result, UInt32(sum >> 32), ((a ^ result) & (op2 ^ result)) >> 31) }
        case 0x6: // SBC
            let borrow = 1 &- carry
            result = a &- op2 &- borrow
            if s && rd != 15 {
                let c: UInt32 = UInt64(a) >= UInt64(op2) &+ UInt64(borrow) ? 1 : 0
                setNZCV(result, c, ((a ^ op2) & (a ^ result)) >> 31)
            }
        case 0x7: // RSC
            let borrow = 1 &- carry
            result = op2 &- a &- borrow
            if s && rd != 15 {
                let c: UInt32 = UInt64(op2) >= UInt64(a) &+ UInt64(borrow) ? 1 : 0
                setNZCV(result, c, ((op2 ^ a) & (op2 ^ result)) >> 31)
            }
        case 0x8, 0x9, 0xA, 0xB: // TST TEQ CMP CMN
            if !s { return } // ARM2: no MRS/MSR; behaves as a no-op
            switch opcode {
            case 0x8:
                result = a & op2
                if rd != 15 { setNZC(result, shc) }
            case 0x9:
                result = a ^ op2
                if rd != 15 { setNZC(result, shc) }
            case 0xA:
                result = a &- op2
                if rd != 15 { setNZCV(result, a >= op2 ? 1 : 0, ((a ^ op2) & (a ^ result)) >> 31) }
            default:
                result = a &+ op2
                if rd != 15 { setNZCV(result, result < a ? 1 : 0, ((a ^ result) & (op2 ^ result)) >> 31) }
            }
            // TSTP/TEQP/CMPP/CMNP: the result is written to the PSR only.
            if rd == 15 { writePSRFromR15(result) }
            return
        case 0xC: // ORR
            result = a | op2
            if s && rd != 15 { setNZC(result, shc) }
        case 0xD: // MOV
            result = op2
            if s && rd != 15 { setNZC(result, shc) }
        case 0xE: // BIC
            result = a & ~op2
            if s && rd != 15 { setNZC(result, shc) }
        default: // MVN
            result = ~op2
            if s && rd != 15 { setNZC(result, shc) }
        }

        if rd == 15 {
            if s { writePSRFromR15(result) }
            pc = result & Self.pcMask
            sequentialFetch = false
        } else {
            r[rd] = result
        }
    }

    // MARK: Multiply

    @inline(__always) func multiply(_ i: UInt32) {
        let rd = Int((i >> 16) & 0xF)
        let rn = Int((i >> 12) & 0xF)
        let rs = Int((i >> 8) & 0xF)
        let rm = Int(i & 0xF)
        let accumulate = i & 0x0020_0000 != 0
        let mVal = rm == 15 ? r15 &+ 4 : r[rm]
        let sVal = rs == 15 ? r15 &+ 4 : r[rs]
        var result = mVal &* sVal
        if accumulate { result = result &+ (rn == 15 ? r15 &+ 4 : r[rn]) }
        // Booth's algorithm, 2 bits per internal cycle with early termination.
        var cycles: UInt64 = 1
        var t = sVal >> 2
        while t != 0 && cycles < 16 { cycles += 1; t >>= 2 }
        bus.ticks &+= cycles * bus.iCycle
        if rd != 15 { r[rd] = result }
        if i & 0x0010_0000 != 0 { setNZ(result) } // C becomes meaningless on ARM2; left unchanged.
    }

    // MARK: Single data transfer

    @inline(__always) func singleDataTransfer(_ i: UInt32) {
        let load = i & 0x0010_0000 != 0
        let writeBackBit = i & 0x0020_0000 != 0
        let byte = i & 0x0040_0000 != 0
        let up = i & 0x0080_0000 != 0
        let pre = i & 0x0100_0000 != 0
        let rn = Int((i >> 16) & 0xF)
        let rd = Int((i >> 12) & 0xF)

        let offset: UInt32
        if i & 0x0200_0000 == 0 {
            offset = i & 0xFFF
        } else {
            let rm = Int(i & 0xF)
            let v = rm == 15 ? ((pc &+ 4) & Self.pcMask) | psr : r[rm]
            offset = shiftImmediate(v, type: (i >> 5) & 3, amount: (i >> 7) & 0x1F).0
        }
        let base = rn == 15 ? (pc &+ 4) & Self.pcMask : r[rn]
        let offsetAddress = up ? base &+ offset : base &- offset
        let address = pre ? offsetAddress : base
        let writeBack = !pre || writeBackBit
        let forceUser = !pre && writeBackBit && (psr & 3) != 0

        sequentialFetch = false
        if address & 0xFC00_0000 != 0 {
            exception(.addressException, returnAddress: pc &+ 4)
            return
        }
        if debugHooks { debugger?.dataAccess(address, write: !load) }
        if forceUser { bus.privileged = false }

        if load {
            var value: UInt32
            if byte {
                value = bus.readByte(address)
            } else {
                value = bus.readWord(address, sequential: false)
                let rot = (address & 3) << 3
                if rot != 0 { value = (value >> rot) | (value << (32 - rot)) }
            }
            if forceUser { bus.privileged = true }
            bus.ticks &+= bus.iCycle
            if bus.abort {
                bus.abort = false
                exception(.dataAbort, returnAddress: pc &+ 4)
                return
            }
            if writeBack { writeBase(rn, offsetAddress) }
            if rd == 15 {
                pc = value & Self.pcMask
            } else {
                r[rd] = value
            }
        } else {
            let value = rd == 15 ? ((pc &+ 8) & Self.pcMask) | psr : r[rd]
            if byte {
                bus.writeByte(address, UInt8(truncatingIfNeeded: value))
            } else {
                bus.writeWord(address, value, sequential: false)
            }
            if forceUser { bus.privileged = true }
            if bus.abort {
                bus.abort = false
                exception(.dataAbort, returnAddress: pc &+ 4)
                return
            }
            if writeBack { writeBase(rn, offsetAddress) }
        }
    }

    @inline(__always) func writeBase(_ rn: Int, _ value: UInt32) {
        if rn == 15 {
            pc = value & Self.pcMask
            sequentialFetch = false
        } else {
            r[rn] = value
        }
    }

    // MARK: ARM3 extensions

    /// SWP/SWPB: load from [Rn] and store Rm there in one locked transfer.
    @inline(__always) func swap(_ i: UInt32) {
        let byte = i & 0x0040_0000 != 0
        let rn = Int((i >> 16) & 0xF), rd = Int((i >> 12) & 0xF), rm = Int(i & 0xF)
        let address = r[rn]
        sequentialFetch = false
        if address & 0xFC00_0000 != 0 {
            exception(.addressException, returnAddress: pc &+ 4)
            return
        }
        if debugHooks, let d = debugger { d.dataAccess(address, write: false); d.dataAccess(address, write: true) }
        var value: UInt32
        if byte {
            value = bus.readByte(address)
        } else {
            value = bus.readWord(address, sequential: false)
            let rot = (address & 3) << 3
            if rot != 0 { value = (value >> rot) | (value << (32 - rot)) }
        }
        if bus.abort {
            bus.abort = false
            exception(.dataAbort, returnAddress: pc &+ 4)
            return
        }
        let source = r[rm]
        if byte { bus.writeByte(address, UInt8(truncatingIfNeeded: source)) } else { bus.writeWord(address, source, sequential: false) }
        if bus.abort {
            bus.abort = false
            exception(.dataAbort, returnAddress: pc &+ 4)
            return
        }
        bus.ticks &+= bus.iCycle
        if rd != 15 { r[rd] = value }
    }

    /// MCR/MRC to CP15: the ARM3 cache controller's registers.
    func coprocessor15(_ i: UInt32) {
        guard let c = cp15 else { return }
        let n = (i >> 16) & 0xF
        let rd = Int((i >> 12) & 0xF)
        if i & 0x0010_0000 != 0 {
            let v = c.read(n)
            if rd == 15 { psr = (psr & 0x0FFF_FFFF) | (v & 0xF000_0000) } else { r[rd] = v }
        } else {
            c.write(n, rd == 15 ? r15 &+ 4 : r[rd])
            if n == 2 { bus.cacheControlChanged() }
        }
        bus.ticks &+= bus.iCycle
    }

    // MARK: Block data transfer

    @inline(__always) func blockDataTransfer(_ i: UInt32) {
        let load = i & 0x0010_0000 != 0
        let writeBack = (i & 0x0020_0000 != 0) && ((i >> 16) & 0xF) != 15
        let sBit = i & 0x0040_0000 != 0
        let up = i & 0x0080_0000 != 0
        let pre = i & 0x0100_0000 != 0
        let rn = Int((i >> 16) & 0xF)
        let list = i & 0xFFFF
        let count = UInt32(list.nonzeroBitCount)

        let base = rn == 15 ? ((pc &+ 4) & Self.pcMask) | psr : r[rn]
        var start: UInt32
        let newBase: UInt32
        if up {
            start = pre ? base &+ 4 : base
            newBase = base &+ 4 &* count
        } else {
            start = pre ? base &- 4 &* count : base &- 4 &* count &+ 4
            newBase = base &- 4 &* count
        }
        sequentialFetch = false

        if start & 0xFC00_0000 != 0 {
            exception(.addressException, returnAddress: pc &+ 4)
            return
        }
        if count == 0 { return }
        if debugHooks, let d = debugger {
            for k in 0..<count { d.dataAccess(start &+ 4 &* k, write: !load) }
        }

        var aborted = false
        var address = start
        if load {
            let restorePSR = sBit && (list & 0x8000) != 0
            let userBankTransfer = sBit && (list & 0x8000) == 0
            if writeBack { r[rn] = newBase }
            var first = true
            var regs = list
            while regs != 0 {
                let n = regs.trailingZeroBitCount
                regs &= regs &- 1
                let v = bus.readWord(address, sequential: !first)
                first = false
                if bus.abort { bus.abort = false; aborted = true }
                if !aborted {
                    if n == 15 {
                        if restorePSR { writePSRFromR15(v) }
                        pc = v & Self.pcMask
                    } else if userBankTransfer {
                        writeUserRegister(n, v)
                    } else {
                        r[n] = v
                    }
                }
                address &+= 4
            }
            bus.ticks &+= bus.iCycle
            if aborted {
                // Base is restored to its written-back value after an abort.
                r[rn] = writeBack ? newBase : base
                exception(.dataAbort, returnAddress: pc &+ 4)
            }
        } else {
            let userBankTransfer = sBit && (psr & 3) != 0
            var first = true
            var regs = list
            while regs != 0 {
                let n = regs.trailingZeroBitCount
                regs &= regs &- 1
                let v: UInt32
                if n == 15 {
                    v = ((pc &+ 8) & Self.pcMask) | psr
                } else if userBankTransfer {
                    v = readUserRegister(n)
                } else {
                    v = r[n]
                }
                bus.writeWord(address, v, sequential: !first)
                if bus.abort { bus.abort = false; aborted = true }
                if first && writeBack {
                    if userBankTransfer { writeUserRegister(rn, newBase) } else { r[rn] = newBase }
                }
                first = false
                address &+= 4
            }
            if aborted {
                exception(.dataAbort, returnAddress: pc &+ 4)
            }
        }
    }

    // MARK: Branch

    @inline(__always) func branch(_ i: UInt32) {
        let offset = UInt32(bitPattern: Int32(bitPattern: i << 8) >> 6)
        if i & 0x0100_0000 != 0 {
            r[14] = (pc & Self.pcMask) | psr
        }
        pc = (pc &+ 4 &+ offset) & Self.pcMask
        sequentialFetch = false
    }
}

/// conditionTable[cond] bit f is set when the condition passes for NZCV = f.
let conditionTable: [UInt16] = {
    var t = [UInt16](repeating: 0, count: 16)
    for cond in 0..<16 {
        var mask: UInt16 = 0
        for f in 0..<16 {
            let n = f & 8 != 0, z = f & 4 != 0, c = f & 2 != 0, v = f & 1 != 0
            let pass: Bool
            switch cond {
            case 0: pass = z
            case 1: pass = !z
            case 2: pass = c
            case 3: pass = !c
            case 4: pass = n
            case 5: pass = !n
            case 6: pass = v
            case 7: pass = !v
            case 8: pass = c && !z
            case 9: pass = !c || z
            case 10: pass = n == v
            case 11: pass = n != v
            case 12: pass = !z && n == v
            case 13: pass = z || n != v
            case 14: pass = true
            default: pass = false // NV: never
            }
            if pass { mask |= 1 << f }
        }
        t[cond] = mask
    }
    return t
}()

// MARK: - Snapshot state

extension ARM2 {
    func saveState(_ w: inout StateWriter) {
        for i in 0..<16 { w.u32(r[i]) }
        for i in 0..<7 { w.u32(userBank[i]) }
        for i in 0..<7 { w.u32(fiqBank[i]) }
        for i in 0..<2 { w.u32(irqBank[i]) }
        for i in 0..<2 { w.u32(svcBank[i]) }
        w.u32(pc); w.u32(psr)
        w.bool(irqLine); w.bool(fiqLine); w.bool(sequentialFetch)
        w.u64(instructionCount); w.u64s(exceptionCounts)
        w.u32(currentInstructionAddress); w.u32(lastInstruction)
        w.u32(pipeAddress); w.u32(pipe0); w.u32(pipe1); w.bool(pipeAbort0); w.bool(pipeAbort1)
    }

    func loadState(_ rd: inout StateReader) throws {
        for i in 0..<16 { r[i] = try rd.u32() }
        for i in 0..<7 { userBank[i] = try rd.u32() }
        for i in 0..<7 { fiqBank[i] = try rd.u32() }
        for i in 0..<2 { irqBank[i] = try rd.u32() }
        for i in 0..<2 { svcBank[i] = try rd.u32() }
        pc = try rd.u32(); psr = try rd.u32()
        irqLine = try rd.bool(); fiqLine = try rd.bool(); sequentialFetch = try rd.bool()
        instructionCount = try rd.u64(); exceptionCounts = try rd.u64s(count: 8)
        currentInstructionAddress = try rd.u32(); lastInstruction = try rd.u32()
        pipeAddress = try rd.u32(); pipe0 = try rd.u32(); pipe1 = try rd.u32()
        pipeAbort0 = try rd.bool(); pipeAbort1 = try rd.bool()
    }
}
