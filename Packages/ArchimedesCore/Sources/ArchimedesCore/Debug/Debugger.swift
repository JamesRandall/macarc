import Foundation

/// The debugger: breakpoints on execute, read or write (ranges, conditions,
/// hit counts, processor-mode qualifiers and log points), stepping by
/// instruction, over, out, scanline, frame or interrupt, an instruction
/// trace, a log, and the profiler.
///
/// It is created when first used (`Machine.debugger`). The CPU calls it only
/// while `ARM2.debugHooks` is on, which it is only while something needs it:
/// with nothing set, a run costs one Bool test per CPU slice. Execute
/// breakpoints and steps stop before the instruction runs; read and write
/// watchpoints stop after the instruction that made the access.
public final class Debugger {
    public struct Breakpoint: Codable, Identifiable, Sendable, Equatable {
        public struct Kind: OptionSet, Codable, Sendable, Hashable {
            public let rawValue: UInt8
            public init(rawValue: UInt8) { self.rawValue = rawValue }
            public static let execute = Kind(rawValue: 1)
            public static let read = Kind(rawValue: 2)
            public static let write = Kind(rawValue: 4)
            public static let access: Kind = [.read, .write]

            public var name: String {
                switch self {
                case .execute: return "execute"
                case .read: return "read"
                case .write: return "write"
                default: return "access"
                }
            }
        }

        public var id: Int
        public var kind: Kind
        public var start: UInt32
        public var end: UInt32
        /// Only in this processor mode (USR, FIQ, IRQ or SVC).
        public var mode: ARM2<MEMC>.Mode?
        public var condition: String?
        public var hitTarget: Int?
        public var logMessage: String?
        public var enabled = true
        public var hitCount = 0

        public init(id: Int, kind: Kind, start: UInt32, end: UInt32? = nil, mode: ARM2<MEMC>.Mode? = nil,
                    condition: String? = nil, hitTarget: Int? = nil, logMessage: String? = nil) {
            self.id = id; self.kind = kind; self.start = start; self.end = end ?? start; self.mode = mode
            self.condition = condition; self.hitTarget = hitTarget; self.logMessage = logMessage
        }

        func covers(_ a: UInt32) -> Bool { start <= end ? (a >= start && a <= end) : (a >= start || a <= end) }

        public var describe: String {
            var s = kind.name + String(format: " &%X", start) + (end != start ? String(format: "-&%X", end) : "")
            if let mode { s += " in \(mode)" }
            if let condition { s += " if \(condition)" }
            if let hitTarget { s += " from hit \(hitTarget)" }
            if let logMessage { s += " log \"\(logMessage)\"" }
            if !enabled { s += " (disabled)" }
            return s + ", hit \(hitCount) time" + (hitCount == 1 ? "" : "s")
        }
    }

    public enum StopReason: Equatable, Sendable, CustomStringConvertible {
        case breakpoint(id: Int, address: UInt32, kind: Breakpoint.Kind)
        case stepped
        case frame
        case scanline
        case interrupt(String)
        case requested
        case historyStart
        /// A BASIC breakpoint, on `line`.
        case basicBreakpoint(id: Int, line: Int)
        /// A BASIC step reached its statement.
        case basicStepped
        /// A BASIC error (see `basic.error`).
        case basicError(number: Int)

        public var description: String {
            switch self {
            case .breakpoint(let id, let a, let k): return String(format: "breakpoint %d (%@ &%X)", id, k.name, a)
            case .stepped: return "step finished"
            case .frame: return "start of frame"
            case .scanline: return "start of scanline"
            case .interrupt(let v): return "\(v) taken"
            case .requested: return "stopped"
            case .historyStart: return "reached the start of the rewind history"
            case .basicBreakpoint(let id, let line): return "BASIC breakpoint \(id) at line \(line)"
            case .basicStepped: return "BASIC step finished"
            case .basicError(let number): return "BASIC error \(number)"
            }
        }

        /// A stop in a BASIC program.
        public var isBasic: Bool {
            switch self {
            case .basicBreakpoint, .basicStepped, .basicError: true
            default: false
            }
        }
    }

    public enum RunCommand: Equatable, Sendable {
        case `continue`, stepInstruction, stepOver, stepOut, runToAddress(UInt32), nextScanline, nextFrame, nextInterrupt
    }

    public struct TraceEntry: Sendable {
        public var ticks: UInt64
        public var pc: UInt32
        public var instruction: UInt32
        public var registers: [UInt32] // R0-R14 as visible, then R15 (PC and PSR)
        public var interrupt: String?

        public var registerText: String {
            var s = (0..<15).map { String(format: "R%d=%X", $0, registers[$0]) }.joined(separator: " ")
            let psr = registers[15]
            s += " " + Debugger.flagText(psr) + " " + ARM2<MEMC>.Mode(rawValue: psr & 3)!.description
            return s
        }
    }

    public struct LogEntry: Sendable {
        public var ticks: UInt64
        public var text: String
    }

    unowned let machine: Machine
    var cpu: ARM2<MEMC> { machine.cpu }

    public private(set) var breakpoints: [Breakpoint] = []
    var nextID = 1
    var compiled: [Int: DebugExpression] = [:]
    var executeKinds = false, dataKinds = false

    public private(set) var stopReason: StopReason?
    /// Counts stops, so watchers can tell a new stop from the same one.
    public private(set) var stopCount = 0
    public var isStopped: Bool { stopReason != nil }
    /// A step or run-to command is under way (the UI's begin).
    public var isRunningCommand: Bool { command != nil || basicIfCreated?.isStepping == true }

    var command: RunCommand?
    var armMode: UInt32 = 0
    var stepTarget: UInt32 = 0
    var instructionsSinceArm = 0
    /// The first instruction after a resume does not re-hit its breakpoint.
    var resumeAddress: UInt32?
    var pendingDataStop: StopReason?
    var videoEvent: StopReason?

    public private(set) var log: [LogEntry] = []
    /// Entries ever logged (the log keeps the latest), so watchers can tell what's new.
    public private(set) var logTotal = 0
    public static let logLimit = 1000

    public private(set) var trace: RingBuffer<TraceEntry>?
    public var traceCapacity: Int { trace?.capacity ?? 0 }

    public private(set) var symbols = SymbolTable.builtIn
    public private(set) var loadedSymbols = SymbolTable()

    public private(set) var profiler: Profiler?
    public private(set) var profiling = false

    /// While rewinding, every executed instruction and data access goes here
    /// instead of to breakpoints, the trace or the profiler.
    var replayObserver: ((ReplayEvent) -> Void)?
    /// Forces the hooks on (reverse search).
    var forceHooks = false

    private var basicIfCreated: BasicDebugger?
    /// BASIC programs' breakpoints, steps and errors (created when first used).
    public var basic: BasicDebugger {
        if let b = basicIfCreated { return b }
        let b = BasicDebugger(debugger: self)
        basicIfCreated = b
        return b
    }
    /// The instructions BASIC's hooks are on (unaligned, so never, when off).
    var basicHooks: (UInt32, UInt32) = (1, 1)

    init(machine: Machine) { self.machine = machine }

    // MARK: Hooks

    /// Turns the CPU's (and VIDC's) calls into the debugger on only when needed.
    func updateHooks() {
        basicHooks = basicIfCreated?.hooks ?? (1, 1)
        let any = breakpoints.contains { $0.enabled } || command != nil || trace != nil || profiling || forceHooks
            || basicHooks.0 != 1
        executeKinds = breakpoints.contains { $0.enabled && $0.kind.contains(.execute) }
        dataKinds = breakpoints.contains { $0.enabled && !$0.kind.intersection(.access).isEmpty }
        cpu.debugHooks = any
        let video = command == .nextFrame || command == .nextScanline || profiling
        machine.vidc.debugLineHook = video ? { [unowned self] line in self.videoLine(line) } : nil
    }

    // MARK: Breakpoints

    @discardableResult
    public func addBreakpoint(_ b: Breakpoint) throws -> Breakpoint {
        var b = b
        b.id = nextID
        nextID += 1
        if let c = b.condition { compiled[b.id] = try DebugExpression(c) }
        if let m = b.logMessage { try validateLog(m) }
        breakpoints.append(b)
        updateHooks()
        return b
    }

    public func updateBreakpoint(_ b: Breakpoint) throws {
        guard let i = breakpoints.firstIndex(where: { $0.id == b.id }) else { return }
        if let c = b.condition { compiled[b.id] = try DebugExpression(c) } else { compiled[b.id] = nil }
        breakpoints[i] = b
        updateHooks()
    }

    @discardableResult
    public func removeBreakpoint(_ id: Int) -> Bool {
        guard let i = breakpoints.firstIndex(where: { $0.id == id }) else { return false }
        breakpoints.remove(at: i)
        compiled[id] = nil
        updateHooks()
        return true
    }

    public func removeAllBreakpoints() {
        breakpoints.removeAll()
        compiled.removeAll()
        updateHooks()
    }

    /// Adds or removes a plain execute breakpoint at `address`.
    public func toggleBreakpoint(at address: UInt32) {
        if let b = breakpoints.first(where: { $0.kind == .execute && $0.start == address && $0.end == address && $0.condition == nil && $0.logMessage == nil }) {
            removeBreakpoint(b.id)
        } else {
            _ = try? addBreakpoint(Breakpoint(id: 0, kind: .execute, start: address & ~3))
        }
    }

    func validateLog(_ m: String) throws {
        var rest = Substring(m)
        while let open = rest.firstIndex(of: "{") {
            guard let close = rest[open...].firstIndex(of: "}") else { break }
            _ = try DebugExpression(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
        }
    }

    /// Breakpoints of `kind` that fire at `address` now (counting hits).
    func check(_ address: UInt32, _ kind: Breakpoint.Kind) -> StopReason? {
        var stop: StopReason?
        let mode = cpu.psr & 3
        for i in breakpoints.indices {
            let b = breakpoints[i]
            guard b.enabled, !b.kind.intersection(kind).isEmpty, b.covers(address) else { continue }
            if let m = b.mode, m.rawValue != mode { continue }
            if let c = compiled[b.id] { guard ((try? c.evaluate(context)) ?? 0) != 0 else { continue } }
            breakpoints[i].hitCount += 1
            if let t = b.hitTarget, breakpoints[i].hitCount < t { continue }
            if let m = b.logMessage {
                appendLog(interpolate(m))
                continue
            }
            if stop == nil { stop = .breakpoint(id: b.id, address: address, kind: kind) }
        }
        return stop
    }

    /// Replaces {expr} with its value (&hex), or {expr?} if it fails.
    public func interpolate(_ m: String) -> String {
        var out = ""
        var rest = Substring(m)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            out += rest[..<open]
            let src = String(rest[rest.index(after: open)..<close])
            if let e = try? DebugExpression(src), let v = try? e.evaluate(context) {
                out += String(format: "&%X", UInt32(truncatingIfNeeded: v))
            } else {
                out += "{\(src)?}"
            }
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    func appendLog(_ s: String) {
        log.append(LogEntry(ticks: machine.ticks, text: s))
        logTotal += 1
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }

    public func clearLog() { log.removeAll() }

    // MARK: Stops and commands

    public func resume() {
        basicIfCreated?.resumed()
        stopReason = nil
        pendingDataStop = nil
        videoEvent = nil
        resumeAddress = cpu.pc
    }

    public func requestStop() { stop(.requested) }

    func stop(_ r: StopReason) {
        guard stopReason == nil else { return }
        stopReason = r
        stopCount += 1
        command = nil
        if basicIfCreated?.isStepping == true { basicIfCreated?.stopped() }
        machine.memc.stopAt = 0 // end the current CPU slice
        updateHooks()
    }

    /// Starts a command and returns; the machine stops when it completes
    /// (the app's emulation thread keeps running it).
    public func begin(_ c: RunCommand) {
        resume()
        arm(c)
    }

    func arm(_ c: RunCommand) {
        armMode = cpu.psr & 3
        instructionsSinceArm = 0
        command = c
        switch c {
        case .stepOver:
            let i = machine.memc.debugReadWord(cpu.pc, space: .logical) ?? 0
            // BL, or SWI (which runs the OS before returning to pc+4).
            if i & 0x0F00_0000 == 0x0B00_0000 || i & 0x0F00_0000 == 0x0F00_0000 {
                stepTarget = (cpu.pc &+ 4) & ARM2<MEMC>.pcMask
            } else {
                command = .stepInstruction
            }
        case .stepOut:
            stepTarget = cpu.r[14] & ARM2<MEMC>.pcMask
        case .runToAddress(let a):
            stepTarget = a & ARM2<MEMC>.pcMask
        default:
            break
        }
        updateHooks()
    }

    /// Starts a BASIC step (from anywhere but a BASIC stop, to the next
    /// statement: Pause in BASIC) and returns.
    public func begin(basic step: BasicStep) {
        let origin = basic.origin
        resume()
        basic.arm(step, from: origin)
    }

    /// Runs a BASIC step until it stops the machine or `maxTicks` pass.
    @discardableResult
    public func run(basic step: BasicStep, maxTicks: UInt64, advance: (UInt64) -> Void) -> StopReason? {
        let origin = basic.origin
        resume()
        basic.arm(step, from: origin)
        defer { basic.disarm() }
        var remaining = maxTicks
        while stopReason == nil && remaining > 0 {
            let slice = min(remaining, 240_000)
            let start = machine.ticks
            advance(slice)
            let used = machine.ticks &- start
            remaining = used >= remaining ? 0 : remaining - max(used, 1)
        }
        return stopReason
    }

    /// Runs `c` until it stops the machine or `maxTicks` pass (tools).
    /// `advance` runs the machine (keeping rewind and the display current).
    @discardableResult
    public func run(_ c: RunCommand, maxTicks: UInt64, advance: (UInt64) -> Void) -> StopReason? {
        resume()
        arm(c)
        defer { if stopReason == nil { command = nil; updateHooks() } }
        var remaining = maxTicks
        while stopReason == nil && remaining > 0 {
            let slice = min(remaining, 240_000)
            let start = machine.ticks
            advance(slice)
            let used = machine.ticks &- start
            remaining = used >= remaining ? 0 : remaining - max(used, 1)
        }
        return stopReason
    }

    // MARK: CPU callbacks

    /// Before the instruction at `pc` runs. True stops the machine there.
    @inline(__always)
    func beforeExecute(_ pc: UInt32) -> Bool {
        if let observe = replayObserver { observe(.execute(pc, machine.ticks)); return false }
        if trace != nil { record(pc) }
        if let v = videoEvent { videoEvent = nil; stop(v); return true }
        if (pc == basicHooks.0 || pc == basicHooks.1) && resumeAddress != pc {
            basic.executing(pc)
            if stopReason != nil { return true }
        }
        if let c = command, instructionsSinceArm > 0 {
            let mode = cpu.psr & 3
            switch c {
            case .stepInstruction: stop(.stepped); return true
            case .stepOver, .runToAddress:
                if pc == stepTarget && mode == armMode { stop(.stepped); return true }
            case .stepOut:
                if (pc == stepTarget && mode == armMode) || ((armMode == 1 || armMode == 2) && mode != armMode) { stop(.stepped); return true }
            default: break
            }
        }
        if executeKinds {
            if resumeAddress == pc { return false }
            if let s = check(pc, .execute) { stop(s); return true }
        }
        return false
    }

    /// After the instruction at `pc` ran, taking `ticks`.
    @inline(__always)
    func afterExecute(_ pc: UInt32, ticks: UInt64, mode: UInt32) {
        instructionsSinceArm += 1
        resumeAddress = nil
        if replayObserver != nil { return }
        if profiling { profiler?.count(pc, ticks: ticks, interrupt: mode == 1 || mode == 2) }
        if let s = pendingDataStop { pendingDataStop = nil; stop(s) }
    }

    /// A data access by the instruction now executing.
    @inline(__always)
    func dataAccess(_ address: UInt32, write: Bool) {
        if let observe = replayObserver { observe(.data(address, write, machine.ticks)); return }
        guard dataKinds, pendingDataStop == nil else { return }
        if let s = check(address & 0x03FF_FFFF, write ? .write : .read) { pendingDataStop = s }
    }

    /// An IRQ or FIQ has just been taken (the PC is at its vector).
    func interruptTaken(_ vector: String) {
        if let observe = replayObserver { observe(.interrupt(machine.ticks)); return }
        trace?.append(TraceEntry(ticks: machine.ticks, pc: cpu.pc, instruction: 0, registers: [], interrupt: vector))
        if command == .nextInterrupt { stop(.interrupt(vector)) }
    }

    func videoLine(_ line: Int) {
        if profiling && line == 0 { profiler?.frames += 1 }
        switch command {
        case .nextScanline?: videoEvent = .scanline
        case .nextFrame? where line == 0: videoEvent = .frame
        default: break
        }
    }

    // MARK: Trace

    public func setTracing(_ capacity: Int) {
        trace = capacity > 0 ? RingBuffer(capacity: capacity) : nil
        updateHooks()
    }

    func record(_ pc: UInt32) {
        var regs = (0..<15).map { cpu.r[$0] }
        regs.append(cpu.r15)
        trace?.append(TraceEntry(ticks: machine.ticks, pc: pc, instruction: machine.memc.debugReadWord(pc, space: .logical) ?? 0,
                            registers: regs, interrupt: nil))
    }

    // MARK: Profiler

    public func startProfiling() {
        profiler = Profiler()
        profiling = true
        updateHooks()
    }

    public func stopProfiling() {
        profiling = false
        updateHooks()
    }

    // MARK: Symbols

    /// Adds names and source lines. A source file's lines replace any it
    /// had before (it has been assembled again).
    public func addSymbols(_ t: SymbolTable) {
        let files = t.sourceFiles
        loadedSymbols.removeLines(inFiles: files)
        symbols.removeLines(inFiles: files)
        loadedSymbols.merge(t)
        symbols.merge(t)
    }

    public func clearSymbols() {
        loadedSymbols = SymbolTable()
        symbols = SymbolTable.builtIn
    }

    // MARK: Carrying over

    /// Takes another machine's breakpoints, symbols, log and trace setting
    /// (after a snapshot restore, a state load or a power cycle).
    public func adopt(_ other: Debugger) {
        breakpoints = other.breakpoints
        nextID = other.nextID
        compiled = other.compiled
        loadedSymbols = other.loadedSymbols
        symbols = SymbolTable.builtIn
        symbols.merge(loadedSymbols)
        log = other.log
        logTotal = other.logTotal
        if other.traceCapacity > 0 { trace = RingBuffer(capacity: other.traceCapacity) }
        if let b = other.basicIfCreated { basic.adopt(b) }
        updateHooks()
    }

    // MARK: Registers

    public static func flagText(_ psr: UInt32) -> String {
        let names: [(String, UInt32)] = [("N", 0x8000_0000), ("Z", 0x4000_0000), ("C", 0x2000_0000), ("V", 0x1000_0000), ("I", 0x0800_0000), ("F", 0x0400_0000)]
        return names.map { psr & $0.1 != 0 ? $0.0 : $0.0.lowercased() }.joined()
    }

    public static let registerNames = (0...12).map { "R\($0)" } + ["R13", "R14", "PC"]

    /// Value of a register, flag or counter by name, for expressions.
    public func register(_ name: String) -> Int? {
        let c = cpu
        switch name {
        case "PC": return Int(c.pc & ARM2<MEMC>.pcMask)
        case "SP": return Int(c.r[13])
        case "LR": return Int(c.r[14])
        case "PSR", "R15": return Int(c.r15)
        case "MODE": return Int(c.psr & 3)
        case "N": return c.psr & 0x8000_0000 != 0 ? 1 : 0
        case "Z": return c.psr & 0x4000_0000 != 0 ? 1 : 0
        case "C": return c.psr & 0x2000_0000 != 0 ? 1 : 0
        case "V": return c.psr & 0x1000_0000 != 0 ? 1 : 0
        case "I": return c.psr & 0x0800_0000 != 0 ? 1 : 0
        case "F": return c.psr & 0x0400_0000 != 0 ? 1 : 0
        case "CYCLES": return Int(machine.ticks)
        case "INSTRUCTIONS": return Int(c.instructionCount)
        default:
            if name.hasPrefix("R"), let n = Int(name.dropFirst()), (0...14).contains(n) { return Int(c.r[n]) }
            return nil
        }
    }

    public enum RegisterError: Error, CustomStringConvertible {
        case unknown(String)
        public var description: String {
            switch self { case .unknown(let n): return "unknown register \(n)" }
        }
    }

    /// Sets R0-R14 (as visible), PC, PSR, MODE or a flag (N Z C V I F).
    public func setRegister(_ name: String, _ value: UInt32) throws {
        let c = cpu
        let flagBits: [String: UInt32] = ["N": 0x8000_0000, "Z": 0x4000_0000, "C": 0x2000_0000, "V": 0x1000_0000, "I": 0x0800_0000, "F": 0x0400_0000]
        switch name.uppercased() {
        case "PC": c.setRegister(15, (value & ARM2<MEMC>.pcMask) | c.psr)
        case "PSR", "R15": c.setRegister(15, value)
        case "SP": c.r[13] = value
        case "LR": c.r[14] = value
        case "MODE": c.setRegister(15, (c.pc & ARM2<MEMC>.pcMask) | (c.psr & ~3) | (value & 3))
        case let f where flagBits[f] != nil:
            let bit = flagBits[f]!
            c.setRegister(15, (c.pc & ARM2<MEMC>.pcMask) | (value != 0 ? c.psr | bit : c.psr & ~bit))
        case let r where r.hasPrefix("R"):
            guard let n = Int(r.dropFirst()), (0...14).contains(n) else { throw RegisterError.unknown(name) }
            c.r[n] = value
        default:
            throw RegisterError.unknown(name)
        }
    }

    /// Full-descending stack from R13: (address, word) pairs.
    public func stack(count: Int = 32) -> [(UInt32, UInt32?)] {
        let sp = cpu.r[13] & ~3
        return (0..<count).map { i in
            let a = sp &+ UInt32(i * 4)
            return (a, machine.memc.debugReadWord(a, space: .logical))
        }
    }

    // MARK: Expressions

    struct Context: DebugExpression.Context {
        unowned let debugger: Debugger
        func register(_ name: String) -> Int? { debugger.register(name) }
        func readByte(_ a: UInt32) -> UInt8 { debugger.machine.memc.debugRead(a, space: .logical) ?? 0xFF }
        func readWord(_ a: UInt32) -> UInt32 { debugger.machine.memc.debugReadWord(a & ~3, space: .logical) ?? 0xFFFF_FFFF }
        func symbol(_ name: String) -> Int? { debugger.symbols.address(of: name).map(Int.init) }
    }

    public var context: DebugExpression.Context { Context(debugger: self) }

    /// A number (&hex, $hex, 0x, %binary, decimal) or an expression.
    /// An expression, or a source line ("hello.s:12") from assembled code.
    public func evaluate(_ text: String) throws -> UInt32 {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.contains(":"), let a = symbols.address(ofLine: t) { return a }
        return UInt32(truncatingIfNeeded: try DebugExpression(t).evaluate(context))
    }

    enum ReplayEvent {
        case execute(UInt32, UInt64)
        case data(UInt32, Bool, UInt64)
        case interrupt(UInt64)
    }
}

extension ARM2.Mode: Codable {}
