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
    /// Show the BASIC program (and gather `DebugSnapshot.basic`).
    var basic = false
    /// BASIC arrays to show the elements of, by name (e.g. "grid%(").
    var basicExpanded: Set<String> = []
    /// BASIC expressions to show the values of.
    var basicWatches: [String] = []
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
    /// A stop in BASIC (rather than in machine code).
    var isBasicStop: Bool
    /// The BASIC program, if the view asks for it.
    var basic: BasicDebugSnapshot?

    init(machine m: Machine, view: DebugView) {
        let d = m.debugger
        let c = m.cpu
        self.view = view
        stopReason = d.stopReason.map { "\($0)" }
        isBasicStop = d.stopReason?.isBasic ?? false
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
        basic = view.basic ? BasicDebugSnapshot(machine: m, view: view) : nil
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
                // A BASIC stop shows the program.
                if count != self.lastStopCount, snap.isBasicStop, !self.view.basic {
                    self.view.basic = true
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

    // MARK: BASIC

    var basic: BasicDebugSnapshot? { snapshot?.basic }

    /// A line the listing should scroll to (`serial` so the same line
    /// can be asked for again).
    struct ScrollRequest: Equatable {
        var line: Int
        var serial: Int
    }

    private(set) var basicScrollRequest: ScrollRequest?

    func showBasicLine(_ line: Int) {
        basicScrollRequest = ScrollRequest(line: line, serial: (basicScrollRequest?.serial ?? 0) + 1)
    }

    /// In BASIC, Pause stops at the next statement (so it's somewhere in
    /// the program).
    func basicPauseOrContinue() {
        if isStopped {
            command { $0.machine.debugger.resume() }
        } else {
            command { $0.machine.debugger.begin(basic: .into) }
        }
    }

    func basicStep(_ kind: BasicStep) {
        command { $0.machine.debugger.begin(basic: kind) }
    }

    /// Adds a breakpoint on the line, or removes the line's.
    func toggleBasicBreakpoint(line: Int) {
        command { s in
            let basic = s.machine.debugger.basic
            let existing = basic.breakpoints.filter { $0.line == line }
            if existing.isEmpty {
                try basic.add(BasicBreakpoint(line: line))
            } else {
                for b in existing { basic.remove(id: b.id) }
            }
        }
    }

    func addBasicBreakpoint(_ breakpoint: BasicBreakpoint) {
        command { try $0.machine.debugger.basic.add(breakpoint) }
    }

    func updateBasicBreakpoint(_ breakpoint: BasicBreakpoint) {
        command { try $0.machine.debugger.basic.update(breakpoint) }
    }

    func removeBasicBreakpoint(id: Int) {
        command { $0.machine.debugger.basic.remove(id: id) }
    }

    func removeAllBasicBreakpoints() {
        command { $0.machine.debugger.basic.removeAllBreakpoints() }
    }

    func setBasicErrorStop(_ mode: BasicDebugger.ErrorStop) {
        command { $0.machine.debugger.basic.errorStop = mode }
    }

    /// Sets a variable (or an array element) to a BASIC expression's value.
    func setBasicVariable(_ name: String, indices: [Int]? = nil, to expression: String) {
        command { s in
            try s.machine.debugger.basic.set(name, indices: indices, to: expression)
            s.rewinder.keyframe(s.machine)
        }
    }

    func toggleBasicArray(_ name: String) {
        if view.basicExpanded.contains(name) {
            view.basicExpanded.remove(name)
        } else {
            view.basicExpanded.insert(name)
        }
    }

    func addBasicWatch(_ expression: String) {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !view.basicWatches.contains(trimmed) else { return }
        view.basicWatches.append(trimmed)
    }

    func removeBasicWatch(_ expression: String) {
        view.basicWatches.removeAll { $0 == expression }
    }

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

/// What the debugger window shows of a BASIC program, gathered with the
/// rest of a `DebugSnapshot`. (After MacBeeb's.)
struct BasicDebugSnapshot {
    struct Line: Identifiable {
        var number: Int
        var text: String
        /// The BASIC breakpoints on it.
        var breakpoints: [BasicBreakpoint]
        var id: Int { number }
    }

    struct Element: Identifiable {
        var indices: [Int]
        var value: BasicValue
        var id: [Int] { indices }
    }

    struct Watch: Identifiable {
        var expression: String
        /// The value, or why there isn't one.
        var result: Result<BasicValue, WatchError>
        var id: String { expression }
    }

    struct WatchError: Error {
        var message: String
    }

    /// The BASIC found in the ROM, e.g. "BASIC V 1.05".
    var interpreter: String?
    var lines: [Line]
    /// Where it stopped in BASIC, if it did.
    var stop: BasicLocation?
    var error: BasicError?
    /// Innermost first; empty unless stopped in BASIC.
    var frames: [BasicFrame]
    var variables: [BasicVariable]
    /// The elements of the arrays asked for (`DebugView.basicExpanded`),
    /// by name.
    var elements: [String: [Element]]
    var watches: [Watch]
    var breakpoints: [BasicBreakpoint]
    var errorStop: BasicDebugger.ErrorStop
    /// A step (or a pause, waiting for a statement) is under way.
    var isStepping: Bool

    /// The most array elements gathered for each array.
    static let elementLimit = 256

    init(machine m: Machine, view: DebugView) {
        let basic = m.debugger.basic
        interpreter = basic.interpreter?.name
        breakpoints = basic.breakpoints
        let byLine = Dictionary(grouping: basic.breakpoints, by: \.line)
        lines = interpreter == nil ? [] : basic.listing().map { Line(number: $0.number, text: $0.text, breakpoints: byLine[$0.number] ?? []) }
        stop = basic.stop
        error = basic.error
        frames = basic.callStack()
        variables = interpreter == nil ? [] : basic.variables()
        var elements: [String: [Element]] = [:]
        for variable in variables where variable.dimensions != nil && view.basicExpanded.contains(variable.name) {
            elements[variable.name] = basic.elements(of: variable, count: Self.elementLimit).map { Element(indices: $0.0, value: $0.1) }
        }
        self.elements = elements
        watches = view.basicWatches.map { expression in
            do {
                return Watch(expression: expression, result: .success(try basic.evaluate(expression)))
            } catch {
                return Watch(expression: expression, result: .failure(WatchError(message: "\(error)")))
            }
        }
        errorStop = basic.errorStop
        isStepping = basic.isStepping
    }
}
