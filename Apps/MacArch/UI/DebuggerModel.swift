import AppKit
import ArchimedesCore
import Observation

/// What the debugger window looks at: which code, which memory.
struct DebugView: Equatable {
    /// nil follows the PC.
    var disassemblyStart: UInt32?
    var disassemblyLines = 48
    var memorySpace = DebugMemorySpace.logical
    var memoryAddress: UInt32 = 0x8000
    var memoryLength = 512
    var traceCount = 200
}

enum DebugMemorySpace: String, CaseIterable, Identifiable {
    case logical, physical, rom
    var id: Self { self }
    var name: String {
        switch self {
        case .logical: "Logical (the CPU's view)"
        case .physical: "Physical RAM"
        case .rom: "ROM"
        }
    }
    func resolve(_ a: UInt32) -> (MEMC.DebugSpace, UInt32) {
        switch self {
        case .logical: (.logical, a)
        case .physical: (.physical, a)
        case .rom: (.logical, 0x0380_0000 &+ a)
        }
    }
}

/// Everything the debugger window shows, gathered on the emulation thread
/// in one go.
struct DebugSnapshot {
    struct Line: Identifiable {
        let address: UInt32
        let word: UInt32?
        let text: String
        let isPC: Bool
        let breakpoints: [Int]
        let labels: [String]
        /// The assembled source line, as "hello.s:12".
        let source: String?
        let heat: Double
        var id: UInt32 { address }
    }

    struct TraceLine: Identifiable {
        let id: Int
        let pc: UInt32
        let text: String
        let registers: String
    }

    var view: DebugView
    var stopReason: String?
    var isRunningCommand: Bool
    var ticks: UInt64
    var instructions: UInt64
    var registers: [(String, UInt32)]
    var psr: UInt32
    var mode: String
    var banked: [(String, [UInt32])]
    var pc: UInt32
    var disassembly: [Line]
    var memory: [UInt8?]
    var stack: [(UInt32, UInt32?)]
    var breakpoints: [Debugger.Breakpoint]
    var hardware: [HardwareSection]
    var tracing: Bool
    var trace: [TraceLine]
    var log: [Debugger.LogEntry]
    var profile: Profiler.Report?
    var isProfiling: Bool
    var symbolCount: Int

    init(machine m: Machine, view: DebugView) {
        let d = m.debugger
        let c = m.cpu
        self.view = view
        stopReason = d.stopReason.map { "\($0)" }
        isRunningCommand = d.isRunningCommand
        ticks = m.ticks
        instructions = c.instructionCount
        registers = (0...14).map { ("R\($0)", c.r[$0]) } + [("PC", c.pc & ARM2<MEMC>.pcMask)]
        psr = c.psr
        mode = "\(c.mode)"
        banked = [ARM2<MEMC>.Mode.user, .fiq, .irq, .supervisor].filter { $0 != c.mode }.map { ("\($0)", c.bankedRegisters($0)) }
        let pc = c.pc & ARM2<MEMC>.pcMask
        self.pc = pc
        let profile = d.profiler?.report(top: 30, symbols: d.symbols)
        self.profile = profile
        isProfiling = d.profiling
        let hottest = Double(profile?.hottest.first?.ticks ?? 0)
        let start = view.disassemblyStart ?? (pc &- 4 * 12)
        let bpsAt = Dictionary(grouping: d.breakpoints.filter { $0.kind.contains(.execute) }, by: \.start)
        disassembly = (0..<view.disassemblyLines).map { i in
            let a = (start & ~3) &+ UInt32(i * 4)
            let w = m.memc.debugReadWord(a, space: .logical)
            let heat = hottest > 0 ? Double(profile?.ticksByAddress[a] ?? 0) / hottest : 0
            return Line(address: a, word: w, text: w.map { Disassembler.disassemble($0, at: a, symbols: d.symbols) } ?? "(unmapped)",
                        isPC: a == pc, breakpoints: (bpsAt[a] ?? []).map(\.id), labels: d.symbols.names(at: a),
                        source: d.symbols.location(at: a)?.description, heat: heat)
        }
        let (space, base) = view.memorySpace.resolve(view.memoryAddress)
        memory = (0..<view.memoryLength).map { m.memc.debugRead(base &+ UInt32($0), space: space) }
        stack = d.stack(count: 32)
        breakpoints = d.breakpoints
        hardware = m.hardwareState
        tracing = d.trace != nil
        let entries = d.trace?.last(view.traceCount) ?? []
        trace = entries.enumerated().map { i, e in
            if let v = e.interrupt { return TraceLine(id: i, pc: e.pc, text: "— \(v) —", registers: "") }
            return TraceLine(id: i, pc: e.pc, text: Disassembler.disassemble(e.instruction, at: e.pc, symbols: d.symbols), registers: e.registerText)
        }
        log = Array(d.log.suffix(200))
        symbolCount = d.loadedSymbols.count
    }
}

/// The debugger window's model: a snapshot of the machine, refreshed while
/// it runs, and commands sent to the emulation thread.
@MainActor
@Observable
final class DebuggerModel {
    unowned let machine: MachineController
    private(set) var snapshot: DebugSnapshot?
    /// The memory as it was before the latest stop (for change highlighting).
    private(set) var previousMemory: [UInt8?] = []
    var view = DebugView() { didSet { if view != oldValue { refresh() } } }
    /// The last command's error, shown in red.
    var message: String?
    var isVisible = false {
        didSet {
            machine.inspecting = isVisible
            if isVisible { refresh() }
        }
    }
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var lastStopCount = -1

    init(machine: MachineController) { self.machine = machine }

    func start() {
        isVisible = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let host = self.machine.host else { return }
                if host.debugStop == nil || host.debugStopCount != self.lastStopCount { self.refresh() }
            }
        }
    }

    func stop() {
        isVisible = false
        timer?.invalidate(); timer = nil
    }

    var isStopped: Bool { snapshot?.stopReason != nil }

    func refresh() {
        guard let host = machine.host else { return }
        if refreshing { refreshAgain = true; return }
        refreshing = true
        let view = self.view
        host.send { [weak self] s in
            let snap = DebugSnapshot(machine: s.machine, view: view)
            let count = s.machine.debuggerIfCreated?.stopCount ?? 0
            Task { @MainActor in
                guard let self else { return }
                if let old = self.snapshot, count != self.lastStopCount, old.view.memorySpace == view.memorySpace, old.view.memoryAddress == view.memoryAddress {
                    self.previousMemory = old.memory
                }
                self.lastStopCount = count
                self.snapshot = snap
                self.refreshing = false
                if self.refreshAgain { self.refreshAgain = false; self.refresh() }
            }
        }
    }

    /// Runs `body` on the emulation thread; an error becomes the message.
    func command(_ body: @escaping (EmulatorHost.Session) throws -> Void) {
        guard let host = machine.host else { return }
        host.send { [weak self] s in
            var failure: String?
            do { try body(s) } catch { failure = "\(error)" }
            Task { @MainActor in
                self?.message = failure
                self?.refresh()
            }
        }
    }

    func pauseOrContinue() {
        command { s in
            let d = s.machine.debugger
            if d.isStopped { d.resume() } else { d.requestStop() }
        }
    }

    func run(_ c: Debugger.RunCommand) {
        view.disassemblyStart = nil
        command { $0.machine.debugger.begin(c) }
    }

    func stepBack() {
        view.disassemblyStart = nil
        command { s in s.replace(with: try s.machine.debugger.stepBack(s.rewinder), keepHistory: true) }
    }

    func reverseContinue() {
        view.disassemblyStart = nil
        command { s in s.replace(with: try s.machine.debugger.reverseContinue(s.rewinder), keepHistory: true) }
    }

    func toggleBreakpoint(at a: UInt32) { command { $0.machine.debugger.toggleBreakpoint(at: a) } }

    func addBreakpoint(_ b: Debugger.Breakpoint) { command { try $0.machine.debugger.addBreakpoint(b) } }

    func updateBreakpoint(_ b: Debugger.Breakpoint) { command { try $0.machine.debugger.updateBreakpoint(b) } }

    func removeBreakpoint(_ id: Int) { command { $0.machine.debugger.removeBreakpoint(id) } }

    func removeAllBreakpoints() { command { $0.machine.debugger.removeAllBreakpoints() } }

    func setRegister(_ name: String, _ value: UInt32) {
        command { s in
            try s.machine.debugger.setRegister(name, value)
            s.rewinder.keyframe(s.machine)
        }
    }

    func write(_ value: UInt8, at offset: Int) {
        let (space, base) = view.memorySpace.resolve(view.memoryAddress)
        command { s in
            guard s.machine.memc.debugWrite(base &+ UInt32(offset), value, space: space) else {
                throw DebuggerError(String(format: "can't write &%X there", base &+ UInt32(offset)))
            }
            s.rewinder.keyframe(s.machine)
        }
    }

    func loadSymbols(_ url: URL) {
        command { s in
            do { s.machine.debugger.addSymbols(try SymbolTable.load(path: url.path)) } catch { throw DebuggerError("\(error)") }
        }
    }

    func setProfiling(_ on: Bool) {
        command { s in if on { s.machine.debugger.startProfiling() } else { s.machine.debugger.stopProfiling() } }
    }

    func setTracing(_ on: Bool) { command { $0.machine.debugger.setTracing(on ? 100_000 : 0) } }

    func clearLog() { command { $0.machine.debugger.clearLog() } }

    /// A number (&hex, $hex, 0x, %binary, decimal) or a debugger expression,
    /// evaluated on the emulation thread.
    func address(_ text: String) -> UInt32? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let v = Self.parseNumber(t) { return v }
        guard let host = machine.host else { return nil }
        return host.sendAndWait { s in try? s.machine.debugger.evaluate(t) }
    }

    static func parseNumber(_ t: String) -> UInt32? {
        if t.hasPrefix("&") || t.hasPrefix("$") { return UInt32(t.dropFirst(), radix: 16) }
        if t.lowercased().hasPrefix("0x") { return UInt32(t.dropFirst(2), radix: 16) }
        if t.hasPrefix("%") { return UInt32(t.dropFirst(), radix: 2) }
        return UInt32(t)
    }
}

struct DebuggerError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
