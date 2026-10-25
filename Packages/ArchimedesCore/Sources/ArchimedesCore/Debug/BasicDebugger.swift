import Foundation

// Debugging BBC BASIC programs: breakpoints on lines, stepping by
// statement, stopping on errors, and the program's calls and variables.
// (After MacBeeb's.)
//
// It works by the interpreter's own code (see BasicMemory): a hook on the
// instruction each statement is dispatched from, and one where BASIC's
// error handling starts. The hooks are on only while a BASIC breakpoint,
// step or error stop is set.

/// A breakpoint on a program line.
public struct BasicBreakpoint: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var line: Int
    /// Only this statement in the line (1 for the first). Without one, it
    /// stops as the line is entered: not at each statement in it, but
    /// again each time a loop goes back to it.
    public var statement: Int?
    /// A BASIC expression: only stop (or log) when it's true (not 0).
    public var condition: String?
    /// Only stop once hit this many times.
    public var hitTarget: Int?
    /// Log this (with {expression} replaced by its value) instead of
    /// stopping.
    public var logMessage: String?
    public var enabled = true
    public var hitCount = 0

    public init(id: Int = 0, line: Int, statement: Int? = nil, condition: String? = nil, hitTarget: Int? = nil,
                logMessage: String? = nil) {
        self.id = id
        self.line = line
        self.statement = statement
        self.condition = condition
        self.hitTarget = hitTarget
        self.logMessage = logMessage
    }
}

/// How far a BASIC step goes.
public enum BasicStep: String, Sendable, CaseIterable {
    /// To the next statement, into PROCs and FNs.
    case into
    /// To the next statement in this PROC or FN (or its caller's, once it
    /// returns).
    case over
    /// Until this PROC or FN returns.
    case out
}

/// The error a BASIC program stopped on.
public struct BasicError: Sendable, Equatable {
    public var number: Int
    public var message: String
    public var location: BasicLocation
    /// Whether the program has an ON ERROR handler for it.
    public var trapped: Bool
}

public final class BasicDebugger {
    public enum ErrorStop: String, Sendable, CaseIterable {
        case off
        /// Errors without an ON ERROR to handle them (Escape too, and STOP).
        case untrapped
        /// Every error, before ON ERROR sees it.
        case all
    }

    unowned let debugger: Debugger
    var machine: Machine { debugger.machine }

    /// The BASIC in the ROM (looked for once).
    public var interpreter: BasicInterpreter? {
        if let found { return found }
        let found = findInterpreter()
        self.found = .some(found)
        return found
    }
    private var found: BasicInterpreter??

    public private(set) var breakpoints: [BasicBreakpoint] = []
    private var nextBreakpointID = 1
    private var conditions: [Int: BasicExpression] = [:]
    public var errorStop = ErrorStop.off {
        didSet { if errorStop != oldValue { debugger.updateHooks() } }
    }

    /// Where the machine stopped in BASIC (until it resumes).
    public private(set) var stop: BasicLocation?
    /// The error, if it stopped on one.
    public private(set) var error: BasicError?
    /// The stop's depth (see `BasicMemory.frameKey`), at a statement.
    private var stopKey: UInt32?
    /// A step in progress, from a stop at `key` (or from anywhere, nil).
    private var step: (kind: BasicStep, key: UInt32?)?
    /// Per call depth: the last statement started, so a line's breakpoint
    /// stops only on entering it.
    private var lastStatements: [UInt32: BasicLocation] = [:]
    private var lineCache: (page: UInt32, top: UInt32, lines: [BasicLine])?

    init(debugger: Debugger) {
        self.debugger = debugger
    }

    // MARK: Breakpoints

    @discardableResult
    public func add(_ breakpoint: BasicBreakpoint) throws(BasicExpression.ParseError) -> BasicBreakpoint {
        var b = breakpoint
        b.id = nextBreakpointID
        b.hitCount = 0
        if let condition = b.condition {
            conditions[b.id] = try BasicExpression(condition)
        }
        nextBreakpointID += 1
        breakpoints.append(b)
        debugger.updateHooks()
        return b
    }

    /// Replaces a breakpoint (same ID), keeping its hit count.
    public func update(_ breakpoint: BasicBreakpoint) throws(BasicExpression.ParseError) {
        guard let index = breakpoints.firstIndex(where: { $0.id == breakpoint.id }) else { return }
        conditions[breakpoint.id] = try breakpoint.condition.map { (c) throws(BasicExpression.ParseError) in try BasicExpression(c) }
        var b = breakpoint
        b.hitCount = breakpoints[index].hitCount
        breakpoints[index] = b
        debugger.updateHooks()
    }

    public func remove(id: Int) {
        breakpoints.removeAll { $0.id == id }
        conditions[id] = nil
        debugger.updateHooks()
    }

    public func removeAllBreakpoints() {
        breakpoints = []
        conditions = [:]
        debugger.updateHooks()
    }

    /// Takes on another machine's breakpoints and error stop.
    func adopt(_ other: BasicDebugger) {
        breakpoints = other.breakpoints
        nextBreakpointID = other.nextBreakpointID
        conditions = other.conditions
        errorStop = other.errorStop
        found = other.found
    }

    // MARK: Hooks

    var watchesStatements: Bool { step != nil || breakpoints.contains { $0.enabled } }
    var isActive: Bool { watchesStatements || errorStop != .off }

    /// The addresses to call `executing` at (the same one twice if only
    /// one is needed); nil when none are.
    var hooks: (UInt32, UInt32)? {
        guard isActive, let i = interpreter else { return nil }
        let statement = watchesStatements ? i.statement : i.errorHandler
        let error = errorStop != .off ? i.errorHandler : i.statement
        return (statement, error)
    }

    func findInterpreter() -> BasicInterpreter? {
        // The ROM: up to 2 MB (smaller ones repeat).
        let base: UInt32 = 0x0380_0000
        let memc = machine.memc
        var rom: [UInt32] = []
        rom.reserveCapacity(0x8_0000)
        for i in 0..<0x8_0000 {
            guard let w = memc.debugReadWord(base &+ UInt32(i * 4), space: .logical) else { break }
            rom.append(w)
        }
        return BasicInterpreter.find(rom, base: base)
    }

    /// An instruction with a hook is about to run.
    func executing(_ address: UInt32) {
        guard let i = interpreter else { return }
        if address == i.statement && watchesStatements {
            statement(i)
        }
        if address == i.errorHandler && errorStop != .off {
            errorRaised(i)
        }
    }

    private func statement(_ i: BasicInterpreter) {
        let cpu = debugger.cpu
        let character = cpu.r[10] & 0xFF
        // Spaces, colons, ends of lines and the ELSE of a one-line IF are
        // skipped past, not statements.
        guard character != 0x20, character != 0x3A, character != 0x0D, character != 0x8B else { return }
        // Commands typed in aren't stopped in.
        guard let location = location(of: cpu.r[12] &- 1) else { return }
        let m = memory()
        let key = m.frameKey(sp: cpu.r[13])
        let last = lastStatements[key]
        // Deeper calls have returned.
        if lastStatements.keys.contains(where: { $0 < key }) {
            lastStatements = lastStatements.filter { $0.key > key }
        }
        lastStatements[key] = location

        if let step {
            let done: Bool
            if let start = step.key, step.kind != .into {
                done = key > start || step.kind == .over && key == start
            } else {
                done = true
            }
            if done {
                stopHere(.basicStepped, location, key)
                return
            }
        }

        for index in breakpoints.indices where breakpoints[index].enabled && breakpoints[index].line == location.line {
            let b = breakpoints[index]
            if let statement = b.statement, statement != location.statement { continue }
            // Running on through the line (or statement) isn't entering it.
            if let last, last.line == location.line, location.address > last.address,
               b.statement == nil || last.statement == location.statement {
                continue
            }
            if let condition = conditions[b.id] {
                guard (try? condition.isTrue(context())) == true else { continue }
            }
            breakpoints[index].hitCount += 1
            if let target = b.hitTarget, breakpoints[index].hitCount < target { continue }
            if let message = b.logMessage {
                debugger.appendLog(interpolate(message))
                continue
            }
            stopHere(.basicBreakpoint(id: b.id, line: location.line), location, key)
            return
        }
    }

    private func errorRaised(_ i: BasicInterpreter) {
        let cpu = debugger.cpu
        let m = memory()
        let report = cpu.r[14] & ARM2<MEMC>.pcMask
        let number = Int(m.word(report))
        // Error 0 (STOP, and fatal errors) can't be trapped; the handler is
        // BASIC's own, in the ROM, when the program has none.
        let trapped = number != 0 && m.errorHandler < 0x0200_0000
        guard errorStop == .all || !trapped else { return }
        guard let location = location(of: cpu.r[12] &- 2) else { return }
        var message: [UInt8] = []
        while message.count < 255, m[report &+ 4 &+ UInt32(message.count)] != 0 {
            message.append(m[report &+ 4 &+ UInt32(message.count)])
        }
        let error = BasicError(number: number, message: BasicMemory.text(message), location: location, trapped: trapped)
        guard debugger.stopReason == nil else { return }
        debugger.stop(.basicError(number: number))
        stop = location
        self.error = error
        stopKey = nil
    }

    private func stopHere(_ reason: Debugger.StopReason, _ location: BasicLocation, _ key: UInt32) {
        guard debugger.stopReason == nil else { return }
        debugger.stop(reason)
        stop = location
        stopKey = key
        error = nil
    }

    // MARK: Running

    /// Starts a step from where BASIC stopped (from anywhere else, all go
    /// to the next statement).
    func arm(_ kind: BasicStep, from key: UInt32?) {
        step = (kind, key)
        debugger.updateHooks()
    }

    var origin: UInt32? { stop != nil ? stopKey : nil }

    func disarm() {
        guard step != nil else { return }
        step = nil
        debugger.updateHooks()
    }

    /// The machine resumed.
    func resumed() {
        stop = nil
        error = nil
        stopKey = nil
    }

    /// Any stop ends a step.
    func stopped() {
        step = nil
    }

    public var isStepping: Bool { step != nil }

    // MARK: The program

    func memory() -> BasicMemory {
        let memc = machine.memc
        return BasicMemory(read: { memc.debugRead($0, space: .logical) ?? 0xFF },
                           write: { memc.debugWrite($0, $1, space: .logical) },
                           workspace: interpreter?.workspace ?? 0x8700)
    }

    func lines() -> [BasicLine] {
        let m = memory()
        let page = m.page, top = m.top
        if let cached = lineCache, cached.page == page, cached.top == top {
            return cached.lines
        }
        let lines = m.lines()
        lineCache = (page, top, lines)
        return lines
    }

    /// The program line and statement `address` is in, if it's in one.
    public func location(of address: UInt32) -> BasicLocation? {
        let m = memory()
        guard address >= m.page && address < m.top else { return nil }
        for attempt in 0..<2 {
            let lines = self.lines()
            // The last line starting before it.
            var low = 0, high = lines.count
            while low < high {
                let mid = (low + high) / 2
                if lines[mid].start < address { low = mid + 1 } else { high = mid }
            }
            if low > 0 {
                let line = lines[low - 1]
                // Edited in place (TOP the same)? Then look again.
                if m[line.start] == 0x0D, Int(m[line.start + 3]) == line.length,
                   Int(m[line.start + 1]) << 8 | Int(m[line.start + 2]) == line.number {
                    return address < line.start + UInt32(line.length) ? m.location(of: address, in: line) : nil
                }
            }
            if attempt == 0 { lineCache = nil }
        }
        return nil
    }

    /// Whether BASIC is waiting at its prompt for a command (rather than
    /// running a program).
    public var isAtPrompt: Bool {
        guard let i = interpreter else { return false }
        let cpu = debugger.cpu
        // Reading the line: in the OS (not USR mode), called from the
        // command loop.
        return cpu.psr & 3 != 0 && cpu.bankedRegisters(.user)[6] & ARM2<MEMC>.pcMask == i.promptReturn
    }

    /// Whether BASIC is the program running (at its prompt or not).
    public var isRunning: Bool {
        guard let i = interpreter else { return false }
        let cpu = debugger.cpu
        let pc = cpu.psr & 3 == 0 ? cpu.pc & ARM2<MEMC>.pcMask : cpu.bankedRegisters(.user)[6] & ARM2<MEMC>.pcMask
        return i.code.contains(pc) && cpu.bankedRegisters(.user)[0] == i.workspace
    }

    /// Puts a tokenised program at PAGE, as LOAD would.
    public func load(_ program: [UInt8]) {
        let m = memory()
        let page = m.page
        for (offset, byte) in program.enumerated() {
            _ = m.write(page &+ UInt32(offset), byte)
        }
        let top = page &+ UInt32(program.count)
        // TOP, and where the variables start.
        let start = (top + 3) & ~3
        _ = m.writeWord(m.workspace &- 0x90, top)
        _ = m.writeWord(m.workspace &- 0x8C, start)
        _ = m.writeWord(m.workspace &- 0x88, start)
        lineCache = nil
    }

    public enum LoadError: Error, CustomStringConvertible, Equatable {
        /// BASIC isn't running (or isn't in the ROM).
        case noBASIC
        /// BASIC is running a program.
        case running

        public var description: String {
            switch self {
            case .noBASIC: "BASIC isn't running: press F12 and type BASIC"
            case .running: "a BASIC program is running: stop it first (Escape)"
            }
        }
    }

    /// Loads a program (as `load`) if BASIC is at its prompt.
    public func loadAtPrompt(_ program: [UInt8]) throws(LoadError) {
        guard interpreter != nil else { throw .noBASIC }
        guard isAtPrompt else { throw isRunning ? .running : .noBASIC }
        load(program)
    }

    /// A program file's contents, tokenised: tokenised already (as SAVE
    /// writes it), or text, with or without line numbers.
    public static func program(fromFile bytes: [UInt8]) throws(BBCBasic.Error) -> [UInt8] {
        if BBCBasic.isProgram(bytes) { return bytes }
        return try BBCBasic.tokenise(String(decoding: bytes, as: UTF8.self))
    }

    /// The program as LIST shows it, a line at a time.
    public func listing() -> [(number: Int, text: String)] {
        let m = memory()
        return lines().map { line in (line.number, BBCBasic.listLine(m.bytes(line.text))) }
    }

    /// The calls being run, innermost first, ending with the main
    /// program; empty unless stopped in BASIC.
    public func callStack() -> [BasicFrame] {
        guard let stop else { return [] }
        let m = memory()
        let calls = m.calls(sp: debugger.cpu.r[13])
        var frames: [BasicFrame] = []
        var location: BasicLocation? = stop
        for call in calls {
            frames.append(BasicFrame(name: m.callee(call) ?? (call.token == 0xF2 ? "PROC?" : "FN?"), location: location))
            location = self.location(of: call.caller)
        }
        frames.append(BasicFrame(name: nil, location: location))
        return frames
    }

    // MARK: Variables

    /// The program's variables (with those LOCAL to the PROC or FN it's
    /// stopped in marked).
    public func variables() -> [BasicVariable] {
        let m = memory()
        var variables = m.variables()
        guard stop != nil else { return variables }
        let calls = m.calls(sp: debugger.cpu.r[13])
        guard let innermost = calls.first else { return variables }
        // LOCALs are saved in the frame, by their values' addresses;
        // parameters are named in the DEF.
        let saved = m.locals(innermost)
        var parameters: Set<String> = []
        if let name = m.callee(innermost),
           let line = lines().first(where: { m.definition($0) == name }) {
            parameters = Set(m.parameters(line))
        }
        for index in variables.indices
        where saved.contains(variables[index].address) || parameters.contains(variables[index].name) {
            variables[index].isLocal = true
        }
        return variables
    }

    public func variable(_ name: String) -> BasicVariable? {
        variables().first { $0.name == name }
    }

    /// An array's elements, from `first` (in the order BASIC stores them:
    /// the last index changing fastest).
    public func elements(of array: BasicVariable, from first: Int = 0, count: Int) -> [([Int], BasicValue)] {
        guard let dimensions = array.dimensions else { return [] }
        let m = memory()
        let total = dimensions.reduce(1) { $0 * ($1 + 1) }
        return (first..<min(first + count, total)).map { offset in
            var indices: [Int] = []
            var rest = offset
            for highest in dimensions.reversed() {
                indices.insert(rest % (highest + 1), at: 0)
                rest /= highest + 1
            }
            return (indices, m.value(array.kind, at: array.address &+ UInt32(offset * m.elementSize(array.kind))))
        }
    }

    func context() -> BasicExpression.Context {
        let m = memory()
        return BasicExpression.Context(
            variable: { name in
                if name.count == 2, name.hasSuffix("%"), let c = name.unicodeScalars.first, ("@"..."Z").contains(c) {
                    return m.integer(at: m.workspace &- 0x100 &+ (c.value - 0x40) * 4)
                }
                return m.variables().first { $0.name == name }?.value
            },
            element: { name, indices in
                m.variables().first { $0.name == name }.flatMap { m.element($0, indices) }
            },
            memory: m)
    }

    /// Evaluates a BASIC expression with the program's variables.
    public func evaluate(_ source: String) throws -> BasicValue {
        try BasicExpression(source).evaluate(context())
    }

    public enum SetError: Error, CustomStringConvertible {
        case noVariable(String)
        case badValue(String)

        public var description: String {
            switch self {
            case .noVariable(let name): "no variable \(name)"
            case .badValue(let why): why
            }
        }
    }

    /// Sets a variable (or with `indices`, an array element) to an
    /// expression's value.
    public func set(_ name: String, indices: [Int]? = nil, to source: String) throws {
        let value = try evaluate(source)
        let m = memory()
        guard let variable = variables().first(where: { $0.name == name }) else { throw SetError.noVariable(name) }
        var address = variable.address
        if let indices {
            guard let dimensions = variable.dimensions, indices.count == dimensions.count,
                  let offset = m.elementOffset(dimensions, indices) else {
                throw SetError.badValue("\(name) has no element (\(indices.map(String.init).joined(separator: ",")))")
            }
            address &+= UInt32(offset * m.elementSize(variable.kind))
        } else if variable.dimensions != nil {
            throw SetError.badValue("\(name) is an array: give the element's indices")
        }
        guard m.set(variable.kind, at: address, to: value) else {
            throw SetError.badValue(variable.kind == .string
                ? "a string can't be set to a number, or made longer than the space BASIC gave it (\(m.capacity(descriptorAt: address)) characters)"
                : "a number can't be set to a string (or it's too big)")
        }
    }

    /// Replaces each {expression} in `text` with its value.
    func interpolate(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            result += rest[..<open]
            let source = String(rest[rest.index(after: open)..<close])
            if let value = try? BasicExpression(source).evaluate(context()) {
                if case .string(let s) = value { result += s } else { result += "\(value)" }
            } else {
                result += "{\(source)?}"
            }
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }
}
