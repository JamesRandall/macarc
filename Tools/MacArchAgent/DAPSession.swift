import ArchimedesCore
import Foundation

// A Debug Adapter Protocol session: lets VS Code (or any DAP client) debug
// the Archimedes, with breakpoints in ARM assembler source. After MacBeeb's.
//
// There is one thread, the ARM. Stops are noticed by polling, so they're
// reported whoever caused them (this client, the app's debugger window,
// an agent). What the program prints goes to the debug console.

/// Where a session's machine lives. `inspect` looks at the machine on its
/// thread without counting as a command (the session polls with it).
public protocol DebugAdapterHost: AgentContext {
    func inspect<T>(_ body: @escaping (Machine) -> T) -> T?
}

public final class DAPSession: @unchecked Sendable {
    let host: DebugAdapterHost
    private let send: ([String: Any]) -> Void
    /// Requests are handled in order, one at a time, here; polling too.
    let queue = DispatchQueue(label: "MacArch DAP session")
    private var sequence = 1

    private var launchArguments: [String: Any] = [:]
    private var launching = false
    /// What configurationDone starts: the program's entry point.
    private var entry: UInt32?
    private var entryBreakpoint: Int?
    /// Breakpoints set through this session, so they can be replaced and
    /// removed: by source file, function names, instructions and data.
    private var sourceBreakpoints: [String: [Int]] = [:]
    private var functionBreakpoints: [Int] = []
    private var instructionBreakpoints: [Int] = []
    private var dataBreakpoints: [Int] = []

    private var timer: DispatchSourceTimer?
    private var last = PollState()
    /// What the machine prints goes to the debug console: from attaching,
    /// or from the start of the launched program.
    private var forwardText = true
    private var closed = false

    static let thread = 1

    public init(host: DebugAdapterHost, send: @escaping ([String: Any]) -> Void) {
        self.host = host
        self.send = send
    }

    // MARK: Messages

    /// Takes a message from the client; requests are answered in order.
    public func handle(_ message: [String: Any]) {
        queue.async { self.process(message) }
    }

    /// The client has gone: remove its breakpoints and let the machine run.
    public func close() {
        queue.async {
            guard !self.closed else { return }
            try? self.disconnect()
        }
    }

    private func process(_ message: [String: Any]) {
        guard message["type"] as? String == "request", let command = message["command"] as? String else { return }
        let seq = message["seq"] as? Int ?? 0
        let arguments = message["arguments"] as? [String: Any] ?? [:]
        do {
            let body = try request(command, arguments)
            respond(seq, command, success: true, body: body)
        } catch {
            respond(seq, command, success: false, message: "\(error)")
        }
        if command == "initialize" { event("initialized") }
        if command == "terminate" { event("terminated") }
    }

    private func respond(_ requestSeq: Int, _ command: String, success: Bool, body: [String: Any]? = nil, message: String? = nil) {
        var r: [String: Any] = ["type": "response", "request_seq": requestSeq, "success": success, "command": command]
        if let body { r["body"] = body }
        if let message { r["message"] = message }
        emit(r)
    }

    private func event(_ name: String, _ body: [String: Any]? = nil) {
        var e: [String: Any] = ["type": "event", "event": name]
        if let body { e["body"] = body }
        emit(e)
    }

    private func emit(_ message: [String: Any]) {
        var m = message
        m["seq"] = sequence
        sequence += 1
        send(m)
    }

    private func output(_ text: String, category: String = "console") {
        event("output", ["category": category, "output": text])
    }

    struct DAPError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    /// Runs `body` with the machine, on its thread.
    private func machine<T>(_ body: @escaping (AgentSession) throws -> T) throws -> T {
        do {
            return try host.perform { s in
                guard s.machine != nil else { throw DAPError("there's no machine (no ROM chosen)") }
                return try body(s)
            }
        } catch let e as ToolError {
            throw DAPError(e.message)
        }
    }

    // MARK: Requests

    private func request(_ command: String, _ a: [String: Any]) throws -> [String: Any]? {
        switch command {
        case "initialize":
            startPolling()
            return capabilities
        case "launch": try launch(a, launching: true); return nil
        case "attach": try launch(a, launching: false); return nil
        case "configurationDone": try start(); return nil
        case "setBreakpoints": return try setBreakpoints(a)
        case "setFunctionBreakpoints": return try setFunctionBreakpoints(a)
        case "setInstructionBreakpoints": return try setInstructionBreakpoints(a)
        case "setExceptionBreakpoints": return ["breakpoints": []]
        case "dataBreakpointInfo": return try dataBreakpointInfo(a)
        case "setDataBreakpoints": return try setDataBreakpoints(a)
        case "threads": return ["threads": [["id": Self.thread, "name": "ARM"]]]
        case "stackTrace": return try stackTrace()
        case "scopes": return scopes()
        case "variables": return try variables(a)
        case "setVariable": return try setVariable(a)
        case "evaluate": return try evaluate(a)
        case "readMemory": return try readMemory(a)
        case "writeMemory": return try writeMemory(a)
        case "disassemble": return try disassemble(a)
        case "continue":
            try machine { $0.machine!.debugger.resume() }
            return ["allThreadsContinued": true]
        case "next": try step(.stepOver); return nil
        case "stepIn": try step(.stepInstruction); return nil
        case "stepOut": try step(.stepOut); return nil
        case "stepBack":
            try machine { s in s.replace(with: try s.machine!.debugger.stepBack(s.rewinder)) }
            return nil
        case "reverseContinue":
            try machine { s in s.replace(with: try s.machine!.debugger.reverseContinue(s.rewinder)) }
            return nil
        case "pause":
            try machine { $0.machine!.debugger.requestStop() }
            return nil
        case "disconnect", "terminate":
            try disconnect()
            return nil
        default:
            throw DAPError("\(command) isn't supported")
        }
    }

    private var capabilities: [String: Any] {
        [
            "supportsConfigurationDoneRequest": true,
            "supportsConditionalBreakpoints": true,
            "supportsHitConditionalBreakpoints": true,
            "supportsLogPoints": true,
            "supportsFunctionBreakpoints": true,
            "supportsInstructionBreakpoints": true,
            "supportsDataBreakpoints": true,
            "supportsStepBack": true,
            "supportsSetVariable": true,
            "supportsEvaluateForHovers": true,
            "supportsReadMemoryRequest": true,
            "supportsWriteMemoryRequest": true,
            "supportsDisassembleRequest": true,
            "supportsSteppingGranularity": true,
            "supportsTerminateRequest": true,
        ]
    }

    // MARK: Launching

    /// launch: source (assembled here) or program (+ loadAddress,
    /// execAddress), symbols, model, disc, stopOnEntry. attach: symbols.
    private func launch(_ a: [String: Any], launching: Bool) throws {
        launchArguments = a
        self.launching = launching
        entry = nil
        forwardText = !launching

        var program: ARMAssembler.Assembly?
        if launching, let source = a["source"] as? String {
            do {
                program = try ARMAssembler.assemble(file: source)
            } catch let f as ARMAssembler.Failure {
                output(f.description + "\n", category: "stderr")
                let first = f.diagnostics.prefix(5).map(\.description).joined(separator: "\n")
                throw DAPError("Assembly failed:\n" + first + (f.diagnostics.count > 5 ? "\n…" : ""))
            }
            let p = program!
            for w in p.warnings { output("\(w.location): warning: \(w.message)\n") }
            output(String(format: "Assembled %@: %d bytes at &%X, entry &%X; %d labels, %d source lines\n",
                          (source as NSString).lastPathComponent, p.bytes.count, p.origin, p.entry, p.symbols.count, p.symbols.lineCount))
        } else if launching, let path = a["program"] as? String {
            guard let d = FileManager.default.contents(atPath: path) else { throw DAPError("can't read \(path)") }
            let origin = Self.number(a["loadAddress"]) ?? 0x8000
            program = ARMAssembler.Assembly(origin: origin, bytes: [UInt8](d), entry: Self.number(a["execAddress"]) ?? origin)
        }

        var symbols: SymbolTable?
        if let path = a["symbols"] as? String {
            do { symbols = try SymbolTable.load(path: path) } catch { throw DAPError("\(error)") }
            output("Loaded \(symbols!.count) symbols from \((path as NSString).lastPathComponent)\n")
        }

        let model = (a["model"] as? String).flatMap { name in
            MachineModel.allCases.first { $0.rawValue.lowercased() == name.lowercased() || $0.displayName.lowercased() == name.lowercased() }
        }
        if a["model"] != nil && model == nil { throw DAPError("unknown model \(a["model"]!)") }
        let disc = a["disc"] as? String

        try machine { s in
            let d = s.machine!.debugger
            if launching { d.resume() }
            if launching, let model, s.machine!.configuration.model != model {
                var change = HardwareChange()
                change.model = model
                try s.powerCycle(change)
                _ = runUntilIdle(s, maxSeconds: 60)
            }
            if let disc {
                s.machine!.insertFloppy(try FloppyImage.open(path: disc), drive: 0)
                s.rewinder.keyframe(s.machine!)
            }
            let m = s.machine!
            if launching { m.debugger.clearSymbols() }
            if let symbols { m.debugger.addSymbols(symbols) }
            if let program {
                try commandPrompt(s)
                try loadProgram(s.machine!, program)
                s.rewinder.keyframe(s.machine!)
            }
        }
        entry = program?.entry
    }

    /// After the breakpoints are set: run the program.
    private func start() throws {
        let stopOnEntry = launchArguments["stopOnEntry"] as? Bool ?? false
        if launching, let entry {
            let (id, owner, text) = try machine { s -> (Int?, ObjectIdentifier, UInt64) in
                let m = s.machine!
                let id = stopOnEntry ? try m.debugger.addBreakpoint(Debugger.Breakpoint(id: 0, kind: .execute, start: entry)).id : nil
                m.scheduleTyping(String(format: "*Go %X\n", entry), intervalMs: 40)
                return (id, ObjectIdentifier(m), m.textOutput.totalAppended)
            }
            entryBreakpoint = id
            // The debug console shows what's printed from here on.
            if last.machine == owner { last.textTotal = text }
            forwardText = true
        } else if stopOnEntry {
            try machine { $0.machine!.debugger.requestStop() }
        }
    }

    private func disconnect() throws {
        closed = true
        timer?.cancel()
        timer = nil
        let ids = sourceBreakpoints.values.flatMap { $0 } + functionBreakpoints + instructionBreakpoints + dataBreakpoints + [entryBreakpoint].compactMap { $0 }
        try? machine { s in
            let d = s.machine!.debugger
            for id in ids { _ = d.removeBreakpoint(id) }
            d.resume()
        }
        sourceBreakpoints = [:]
        functionBreakpoints = []
        instructionBreakpoints = []
        dataBreakpoints = []
        entryBreakpoint = nil
    }

    // MARK: Stops, the log and the program's output

    struct PollState {
        var machine: ObjectIdentifier?
        var stopCount = 0
        var reason: Debugger.StopReason?
        var logTotal = 0
        var log: [String] = []
        var textTotal: UInt64 = 0
        var text: [UInt8] = []
    }

    private func startPolling() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(25), repeating: .milliseconds(25))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
        // Start from now: only what happens from here is reported.
        if let now = host.inspect({ m in Self.state(m, since: PollState()) }) { last = now }
    }

    static func state(_ m: Machine, since last: PollState) -> PollState {
        var p = PollState()
        p.machine = ObjectIdentifier(m)
        let d = m.debuggerIfCreated
        p.stopCount = d?.stopCount ?? 0
        p.reason = d?.stopReason
        p.logTotal = d?.logTotal ?? 0
        if let d, p.machine == last.machine, p.logTotal > last.logTotal {
            p.log = d.log.suffix(min(d.log.count, p.logTotal - last.logTotal)).map(\.text)
        }
        p.textTotal = m.textOutput.totalAppended
        if p.machine == last.machine, p.textTotal > last.textTotal {
            p.text = Array(m.textOutput.elements.suffix(Int(min(p.textTotal - last.textTotal, UInt64(m.textOutput.count)))))
        }
        return p
    }

    private func poll() {
        let previous = last
        guard let now = host.inspect({ m in Self.state(m, since: previous) }) else { return }
        last = now
        if forwardText, !now.text.isEmpty {
            var s = ""
            for b in now.text {
                if b == 13 || b == 10 { if !s.hasSuffix("\n") { s += "\n" } } else if b >= 32 && b < 127 { s.append(Character(UnicodeScalar(b))) }
            }
            if !s.isEmpty { output(s, category: "stdout") }
        }
        for line in now.log { output(line + "\n") }
        if let reason = now.reason, now.machine != previous.machine || now.stopCount != previous.stopCount || previous.reason == nil {
            reportStop(reason)
        } else if now.reason == nil && previous.reason != nil {
            event("continued", ["threadId": Self.thread, "allThreadsContinued": true])
        }
    }

    private func reportStop(_ stop: Debugger.StopReason) {
        var body: [String: Any] = ["threadId": Self.thread, "allThreadsStopped": true, "text": "\(stop)"]
        var reason: String
        switch stop {
        case .breakpoint(let id, let address, let kind):
            // The entry point, even if one of the client's breakpoints is there too.
            if let e = entryBreakpoint, kind == .execute, address == entry {
                reason = "entry"
                entryBreakpoint = nil
                _ = try? machine { $0.machine!.debugger.removeBreakpoint(e) }
            } else {
                reason = kind == .execute ? "breakpoint" : "data breakpoint"
                body["hitBreakpointIds"] = [id]
            }
        case .requested: reason = "pause"
        case .historyStart:
            reason = "step"
            body["description"] = "Reached the start of the rewind history"
        default: reason = "step"
        }
        body["reason"] = reason
        event("stopped", body)
    }

    private func step(_ command: Debugger.RunCommand) throws {
        try machine { $0.machine!.debugger.begin(command) }
    }

    // MARK: Breakpoints

    /// Breakpoint request fields that are the same for every kind.
    static func options(_ b: [String: Any]) -> (condition: String?, hitTarget: Int?, log: String?) {
        let condition = (b["condition"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let hit = (b["hitCondition"] as? String).flatMap { Int($0.filter(\.isNumber)) }
        // VS Code's {expression} interpolation is the debugger's too.
        let log = (b["logMessage"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (condition, hit, log)
    }

    private func setBreakpoints(_ a: [String: Any]) throws -> [String: Any] {
        guard let path = (a["source"] as? [String: Any])?["path"] as? String else { throw DAPError("source.path is required") }
        let requested = a["breakpoints"] as? [[String: Any]] ?? []
        let old = sourceBreakpoints[path] ?? []
        let (ids, results) = try machine { s -> ([Int], [[String: Any]]) in
            let d = s.machine!.debugger
            for id in old { _ = d.removeBreakpoint(id) }
            var ids: [Int] = []
            var results: [[String: Any]] = []
            for b in requested {
                guard let line = b["line"] as? Int else { continue }
                let (condition, hit, log) = Self.options(b)
                guard let found = d.symbols.addresses(file: path, line: line), let address = found.addresses.first else {
                    results.append(["verified": false, "line": line, "message": "No code at this line (has it been assembled?)"])
                    continue
                }
                do {
                    let added = try d.addBreakpoint(Debugger.Breakpoint(id: 0, kind: .execute, start: address, condition: condition, hitTarget: hit, logMessage: log))
                    ids.append(added.id)
                    results.append(["id": added.id, "verified": true, "line": found.line, "instructionReference": Self.reference(address)])
                } catch {
                    results.append(["verified": false, "line": line, "message": "\(error)"])
                }
            }
            return (ids, results)
        }
        sourceBreakpoints[path] = ids
        return ["breakpoints": results]
    }

    private func setFunctionBreakpoints(_ a: [String: Any]) throws -> [String: Any] {
        let requested = a["breakpoints"] as? [[String: Any]] ?? []
        let old = functionBreakpoints
        let (ids, results) = try machine { s -> ([Int], [[String: Any]]) in
            let d = s.machine!.debugger
            for id in old { _ = d.removeBreakpoint(id) }
            var ids: [Int] = []
            var results: [[String: Any]] = []
            for b in requested {
                let name = b["name"] as? String ?? ""
                let (condition, hit, log) = Self.options(b)
                guard let address = try? d.evaluate(name),
                      let added = try? d.addBreakpoint(Debugger.Breakpoint(id: 0, kind: .execute, start: address & ~3, condition: condition, hitTarget: hit, logMessage: log)) else {
                    results.append(["verified": false, "message": "Unknown symbol or bad expression \(name)"])
                    continue
                }
                ids.append(added.id)
                results.append(["id": added.id, "verified": true, "instructionReference": Self.reference(address & ~3)])
            }
            return (ids, results)
        }
        functionBreakpoints = ids
        return ["breakpoints": results]
    }

    private func setInstructionBreakpoints(_ a: [String: Any]) throws -> [String: Any] {
        let requested = a["breakpoints"] as? [[String: Any]] ?? []
        let old = instructionBreakpoints
        let (ids, results) = try machine { s -> ([Int], [[String: Any]]) in
            let d = s.machine!.debugger
            for id in old { _ = d.removeBreakpoint(id) }
            var ids: [Int] = []
            var results: [[String: Any]] = []
            for b in requested {
                guard let base = Self.parseReference(b["instructionReference"] as? String ?? "") else {
                    results.append(["verified": false]); continue
                }
                let address = UInt32(truncatingIfNeeded: Int(base) + (b["offset"] as? Int ?? 0)) & ~3
                let (condition, hit, log) = Self.options(b)
                guard let added = try? d.addBreakpoint(Debugger.Breakpoint(id: 0, kind: .execute, start: address, condition: condition, hitTarget: hit, logMessage: log)) else {
                    results.append(["verified": false]); continue
                }
                ids.append(added.id)
                results.append(["id": added.id, "verified": true])
            }
            return (ids, results)
        }
        instructionBreakpoints = ids
        return ["breakpoints": results]
    }

    /// A variable (a register's value, a symbol, an expression) is the
    /// memory it points at: watch the word there.
    private func dataBreakpointInfo(_ a: [String: Any]) throws -> [String: Any] {
        let name = a["name"] as? String ?? ""
        let address = try machine { s -> UInt32? in
            if let r = Self.parseReference(name) { return r }
            return try? s.machine!.debugger.evaluate(name)
        }
        guard let address else { return ["dataId": NSNull(), "description": "\(name) isn't a memory location"] }
        return ["dataId": Self.reference(address), "description": String(format: "%@ (&%X)", name, address),
                "accessTypes": ["read", "write", "readWrite"], "canPersist": false]
    }

    private func setDataBreakpoints(_ a: [String: Any]) throws -> [String: Any] {
        let requested = a["breakpoints"] as? [[String: Any]] ?? []
        let old = dataBreakpoints
        let (ids, results) = try machine { s -> ([Int], [[String: Any]]) in
            let d = s.machine!.debugger
            for id in old { _ = d.removeBreakpoint(id) }
            var ids: [Int] = []
            var results: [[String: Any]] = []
            for b in requested {
                guard let address = Self.parseReference(b["dataId"] as? String ?? "") else {
                    results.append(["verified": false]); continue
                }
                let kind: Debugger.Breakpoint.Kind = switch b["accessType"] as? String {
                case "read": .read
                case "readWrite": .access
                default: .write
                }
                let (condition, hit, _) = Self.options(b)
                // The whole word, so byte accesses to it count too.
                guard let added = try? d.addBreakpoint(Debugger.Breakpoint(id: 0, kind: kind, start: address, end: address | 3, condition: condition, hitTarget: hit)) else {
                    results.append(["verified": false]); continue
                }
                ids.append(added.id)
                results.append(["id": added.id, "verified": true])
            }
            return (ids, results)
        }
        dataBreakpoints = ids
        return ["breakpoints": results]
    }

    /// "0x00008000".
    static func reference(_ address: UInt32) -> String { String(format: "0x%08X", address) }

    static func parseReference(_ text: String) -> UInt32? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("0x") || t.hasPrefix("0X") { return UInt32(t.dropFirst(2), radix: 16) }
        if t.hasPrefix("&") || t.hasPrefix("$") { return UInt32(t.dropFirst(), radix: 16) }
        return UInt32(t)
    }

    static func number(_ v: Any?) -> UInt32? {
        if let i = v as? Int { return UInt32(truncatingIfNeeded: i) }
        if let d = v as? Double { return UInt32(d) }
        if let s = v as? String { return parseReference(s) }
        return nil
    }

    // MARK: State

    static func frameName(_ address: UInt32, _ symbols: SymbolTable) -> String {
        symbols.describe(address) ?? String(format: "&%08X", address)
    }

    /// The current instruction, then the caller if R14 holds a return
    /// address (the instruction before it is a BL).
    private func stackTrace() throws -> [String: Any] {
        let frames = try machine { s -> [[String: Any]] in
            let m = s.machine!
            let symbols = m.debugger.symbols
            var addresses = [m.cpu.pc & ARM2<MEMC>.pcMask]
            let ret = (m.cpu.r[14] & ARM2<MEMC>.pcMask) &- 4
            if let w = m.memc.debugReadWord(ret, space: .logical), (w >> 24) & 0xF == 0xB, ret != addresses[0] {
                addresses.append(ret)
            }
            return addresses.enumerated().map { i, a in
                var frame: [String: Any] = ["id": i, "name": Self.frameName(a, symbols), "instructionPointerReference": Self.reference(a), "line": 0, "column": 0]
                if let l = symbols.location(at: a) {
                    frame["source"] = ["name": (l.file as NSString).lastPathComponent, "path": l.file]
                    frame["line"] = l.line
                    frame["column"] = 1
                }
                return frame
            }
        }
        return ["stackFrames": frames, "totalFrames": frames.count]
    }

    // Variable references: 1 registers, 2 flags and mode, 3 the banked
    // registers, 10 hardware (11+ its sections).
    private func scopes() -> [String: Any] {
        ["scopes": [
            ["name": "Registers", "variablesReference": 1, "expensive": false],
            ["name": "Flags", "variablesReference": 2, "expensive": false],
            ["name": "Banked registers", "variablesReference": 3, "expensive": false],
            ["name": "Hardware", "variablesReference": 10, "expensive": true],
        ]]
    }

    static func value(_ v: UInt32) -> String { String(format: "&%08X (%d)", v, Int32(bitPattern: v)) }

    private func variables(_ a: [String: Any]) throws -> [String: Any] {
        let reference = a["variablesReference"] as? Int ?? 0
        let vars = try machine { s -> [[String: Any]] in
            let m = s.machine!
            let c = m.cpu
            switch reference {
            case 1:
                var rows: [[String: Any]] = (0...14).map { i in
                    let name = i == 13 ? "R13 (SP)" : i == 14 ? "R14 (LR)" : "R\(i)"
                    return ["name": name, "value": Self.value(c.r[i]), "variablesReference": 0, "memoryReference": Self.reference(c.r[i])]
                }
                rows.append(["name": "PC", "value": Self.value(c.pc & ARM2<MEMC>.pcMask), "variablesReference": 0,
                             "memoryReference": Self.reference(c.pc & ARM2<MEMC>.pcMask)])
                rows.append(["name": "R15 (PSR)", "value": String(format: "&%08X", c.r15), "variablesReference": 0])
                return rows
            case 2:
                let bits: [(String, UInt32)] = [("N", 0x8000_0000), ("Z", 0x4000_0000), ("C", 0x2000_0000), ("V", 0x1000_0000), ("I", 0x0800_0000), ("F", 0x0400_0000)]
                return bits.map { ["name": $0.0, "value": c.psr & $0.1 != 0 ? "1" : "0", "variablesReference": 0] }
                    + [["name": "MODE", "value": "\(c.psr & 3) (\(c.mode))", "variablesReference": 0]]
            case 3:
                return [ARM2<MEMC>.Mode.user, .fiq, .irq, .supervisor].filter { $0 != c.mode }.flatMap { mode -> [[String: Any]] in
                    let b = c.bankedRegisters(mode)
                    return (mode == .fiq ? Array(8...14) : [13, 14]).map { ["name": "\(mode) R\($0)", "value": Self.value(b[$0 - 8]), "variablesReference": 0] }
                }
            case 10:
                return m.hardwareState.enumerated().map { i, section in ["name": section.name, "value": "", "variablesReference": 11 + i] }
            default:
                let sections = m.hardwareState
                let i = reference - 11
                guard sections.indices.contains(i) else { return [] }
                return sections[i].rows.map { ["name": $0.label, "value": $0.value, "variablesReference": 0] }
            }
        }
        return ["variables": vars]
    }

    private func setVariable(_ a: [String: Any]) throws -> [String: Any] {
        let reference = a["variablesReference"] as? Int ?? 0
        guard reference == 1 || reference == 2, let label = a["name"] as? String, let text = a["value"] as? String else {
            throw DAPError("only registers and flags can be set")
        }
        // "R13 (SP)" is R13; "R15 (PSR)" is the PSR.
        let name = label.hasPrefix("R15") ? "PSR" : String(label.split(separator: " ")[0])
        let value = try machine { s -> UInt32 in
            let d = s.machine!.debugger
            let v: UInt32
            do { v = try d.evaluate(String(text.split(separator: " ").first ?? Substring(text))) } catch { throw DAPError("\(error)") }
            do { try d.setRegister(name, v) } catch { throw DAPError("\(error)") }
            s.rewinder.keyframe(s.machine!)
            return UInt32(truncatingIfNeeded: d.register(name == "PSR" ? "PSR" : name) ?? Int(v))
        }
        return ["value": reference == 1 ? (name == "PSR" ? String(format: "&%08X", value) : Self.value(value)) : "\(value)"]
    }

    private func evaluate(_ a: [String: Any]) throws -> [String: Any] {
        guard let expression = a["expression"] as? String else { throw DAPError("expression is required") }
        let context = a["context"] as? String ?? "repl"
        let (text, address) = try machine { s -> (String, UInt32?) in
            let m = s.machine!
            let d = m.debugger
            let v: UInt32
            do { v = try d.evaluate(expression) } catch { throw DAPError("\(error)") }
            var text = Self.value(v)
            // A label or address: show the memory there too.
            let isName = d.symbols.address(of: expression) != nil
            if context == "hover" || isName, let w = m.memc.debugReadWord(v & ~3, space: .logical) {
                let bytes = (0..<8).compactMap { m.memc.debugRead(v &+ UInt32($0), space: .logical) }
                text += String(format: "  {&%08X}  [", w) + bytes.map { String(format: "%02X", $0) }.joined(separator: " ") + "]"
            }
            return (text, v)
        }
        var body: [String: Any] = ["result": text, "variablesReference": 0]
        if let address { body["memoryReference"] = Self.reference(address) }
        return body
    }

    private func readMemory(_ a: [String: Any]) throws -> [String: Any] {
        guard let base = Self.parseReference(a["memoryReference"] as? String ?? "") else { throw DAPError("bad memoryReference") }
        let start = UInt32(truncatingIfNeeded: Int(base) + (a["offset"] as? Int ?? 0))
        let count = min(max(a["count"] as? Int ?? 0, 0), 0x10000)
        let bytes = try machine { s -> [UInt8] in
            var out: [UInt8] = []
            for i in 0..<count {
                guard let b = s.machine!.memc.debugRead(start &+ UInt32(i), space: .logical) else { break }
                out.append(b)
            }
            return out
        }
        return ["address": Self.reference(start), "data": Data(bytes).base64EncodedString(), "unreadableBytes": count - bytes.count]
    }

    private func writeMemory(_ a: [String: Any]) throws -> [String: Any] {
        guard let base = Self.parseReference(a["memoryReference"] as? String ?? ""),
              let data = (a["data"] as? String).flatMap({ Data(base64Encoded: $0) }) else { throw DAPError("bad memoryReference or data") }
        let start = UInt32(truncatingIfNeeded: Int(base) + (a["offset"] as? Int ?? 0))
        let written = try machine { s -> Int in
            var n = 0
            for (i, b) in data.enumerated() where s.machine!.memc.debugWrite(start &+ UInt32(i), b, space: .logical) { n += 1 }
            s.rewinder.keyframe(s.machine!)
            return n
        }
        return ["bytesWritten": written]
    }

    private func disassemble(_ a: [String: Any]) throws -> [String: Any] {
        guard let base = Self.parseReference(a["memoryReference"] as? String ?? "") else { throw DAPError("bad memoryReference") }
        let offset = a["offset"] as? Int ?? 0
        let instructionOffset = a["instructionOffset"] as? Int ?? 0
        let count = min(max(a["instructionCount"] as? Int ?? 0, 0), 4096)
        let start = UInt32(truncatingIfNeeded: (Int(base) + offset) & ~3 + instructionOffset * 4)
        let instructions = try machine { s -> [[String: Any]] in
            let m = s.machine!
            let symbols = m.debugger.symbols
            return (0..<count).map { i in
                let address = start &+ UInt32(i * 4)
                var row: [String: Any] = ["address": Self.reference(address)]
                if let w = m.memc.debugReadWord(address, space: .logical) {
                    row["instructionBytes"] = String(format: "%02X %02X %02X %02X", w & 0xFF, (w >> 8) & 0xFF, (w >> 16) & 0xFF, w >> 24)
                    row["instruction"] = Disassembler.disassemble(w, at: address, symbols: symbols)
                } else {
                    row["instruction"] = "(unmapped)"
                    row["presentationHint"] = "invalid"
                }
                if let name = symbols.names(at: address).first { row["symbol"] = name }
                if let l = symbols.location(at: address) {
                    row["location"] = ["name": (l.file as NSString).lastPathComponent, "path": l.file]
                    row["line"] = l.line
                }
                return row
            }
        }
        return ["instructions": instructions]
    }
}
