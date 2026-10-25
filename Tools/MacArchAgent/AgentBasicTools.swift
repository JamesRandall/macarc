import ArchimedesCore
import Foundation

// Debugging BBC BASIC programs: loading one, breakpoints on lines, stepping
// by statement, stopping on errors, the call stack and variables. (After
// MacBeeb's.)

func describe(_ b: BasicBreakpoint) -> String {
    var text = "line \(b.line)" + (b.statement.map { " statement \($0)" } ?? "")
    if let condition = b.condition { text += " if \(condition)" }
    if let target = b.hitTarget { text += ", from hit \(target)" }
    if let message = b.logMessage { text += ", logging \"\(message)\"" }
    if !b.enabled { text += " (disabled)" }
    return text + " (hits: \(b.hitCount))"
}

func describe(_ v: BasicVariable) -> String {
    let local = v.isLocal ? " (LOCAL)" : ""
    if let dimensions = v.dimensions {
        return "\(v.name)\(dimensions.map(String.init).joined(separator: ","))) array of \(v.kind.rawValue)\(local)"
    }
    return "\(v.name) = \(v.value.map { "\($0)" } ?? "?")\(local)"
}

/// Where BASIC stopped: the line, the error (if any) and the calls.
func basicWhere(_ m: Machine) -> String? {
    let basic = m.debugger.basic
    guard let stop = basic.stop else { return nil }
    var text = "BASIC stopped at \(stop)"
    if let line = basic.listing().first(where: { $0.number == stop.line }) {
        text += ":\n  \(line.number)\(line.text)"
    }
    if let error = basic.error {
        text += "\nerror \(error.number): \(error.message)" + (error.trapped ? " (ON ERROR will handle it)" : "")
    }
    let frames = basic.callStack()
    if frames.count > 1 {
        text += "\ncalls (innermost first):\n" + frames.map { frame in
            "  \(frame.name ?? "main program") at \(frame.location.map { "\($0)" } ?? "a command typed in")"
        }.joined(separator: "\n")
    }
    let locals = basic.variables().filter(\.isLocal)
    if !locals.isEmpty {
        text += "\nlocals: " + locals.map(describe).joined(separator: ", ")
    }
    return text
}

/// After a BASIC stop (or none), where it is.
func basicSummary(_ m: Machine, _ reason: Debugger.StopReason?) -> String {
    if let text = basicWhere(m) { return text }
    return reason.map { "stopped: \($0)" } ?? "still running (time limit reached)"
}

let basicTools: [Tool] = [
    Tool(name: "basic_load",
         description: "Load a BBC BASIC program and (unless run is false) RUN it: from a file (text, with or without line numbers, or tokenised as SAVE writes it) or as text. Goes to BASIC's prompt first (F12 and BASIC from the desktop). Set BASIC breakpoints before, or after with run false. Returns what it printed in the first seconds, or where it stopped.",
         schema: schema(["path": prop("string", "A .bas file on the Mac"),
                         "text": prop("string", "Or the program's text, a line per line"),
                         "run": prop("boolean", "RUN it (default true)"),
                         "max_seconds": prop("number", "How long to let it run before returning (default 3)")]),
         run: { s, a in
             let bytes: [UInt8]
             if let path = str(a, "path") {
                 guard let data = FileManager.default.contents(atPath: path) else { throw ToolError(message: "can't read \(path)") }
                 bytes = [UInt8](data)
             } else if let text = str(a, "text") {
                 bytes = Array(text.utf8)
             } else {
                 throw ToolError(message: "give path or text")
             }
             let program: [UInt8]
             do { program = try BasicDebugger.program(fromFile: bytes) } catch { throw ToolError(message: error.localizedDescription) }
             let m = try s.require()
             m.debugger.resume()
             try basicPrompt(s)
             m.debugger.basic.load(program)
             s.rewinder.keyframe(m)
             let lines = m.debugger.basic.listing().count
             guard bool(a, "run") ?? true else { return ToolOutput("loaded \(lines) lines at PAGE (\(program.count) bytes)") }
             let before = m.textOutput.totalAppended
             m.scheduleTyping("RUN\n", intervalMs: 40)
             _ = s.advance(until: { m.debugger.isStopped }, maxSeconds: num(a, "max_seconds") ?? 3)
             var out = "loaded \(lines) lines and ran it"
             let printed = m.textOutput.totalAppended &- before
             if printed > 0 {
                 let recent: [UInt8] = Array(m.textOutput.elements.suffix(Int(min(printed, UInt64(m.textOutput.count)))))
                 var text = ""
                 for b in recent where b == 10 || b == 13 || (b >= 32 && b < 127) {
                     text.append(b == 13 ? "\n" : Character(UnicodeScalar(b)))
                 }
                 out += "\nprinted:\n" + text.replacingOccurrences(of: "\n\n", with: "\n")
             }
             if m.debugger.isStopped { out += "\n" + basicSummary(m, m.debugger.stopReason) }
             return ToolOutput(out)
         }),
    Tool(name: "basic_set_breakpoint",
         description: "Stop a BASIC program at a line (as it enters the line: not at each statement in it, but each time a loop goes back to it), or one statement in a line. Conditions are BASIC expressions with the program's variables (e.g. \"I%>10 AND name$=\\\"FRED\\\"\"); log_message logs instead of stopping, with {expression}s. Works with BBC BASIC V in RISC OS 2 and 3. Then run the program (basic_load, or type RUN) or continue; stops return where it is, with the call stack.",
         schema: schema(["line": prop("integer", "Line number"),
                         "statement": prop("integer", "Only this statement in the line (1 is the first; each : starts another)"),
                         "condition": prop("string", "Only when this BASIC expression is true"),
                         "hit_count": prop("integer", "Only stop on this hit (and later ones)"),
                         "log_message": prop("string", "Log this instead of stopping, e.g. \"I%={I%} total={total}\"")],
                        required: ["line"]),
         run: { s, a in
             guard let line = int(a, "line"), (0...65279).contains(line) else { throw ToolError(message: "line must be 0-65279") }
             let m = try s.require()
             let basic = m.debugger.basic
             let breakpoint = BasicBreakpoint(line: line, statement: int(a, "statement"), condition: str(a, "condition"),
                                              hitTarget: int(a, "hit_count"), logMessage: str(a, "log_message"))
             let added: BasicBreakpoint
             do { added = try basic.add(breakpoint) } catch { throw ToolError(message: "condition: \(error)") }
             var text = "BASIC breakpoint \(added.id): \(describe(added))"
             if basic.interpreter == nil {
                 text += "\n(this ROM's BASIC isn't one the debugger knows)"
             } else if !basic.listing().isEmpty, !basic.listing().contains(where: { $0.number == line }) {
                 text += "\n(the program in memory has no line \(line))"
             }
             return ToolOutput(text)
         }),
    Tool(name: "basic_list_breakpoints",
         description: "The BASIC breakpoints, with hit counts, and whether errors stop the program.",
         schema: schema([:]), run: { s, _ in
             let basic = try s.require().debugger.basic
             let list = basic.breakpoints.isEmpty ? "no BASIC breakpoints" : basic.breakpoints.map { "\($0.id): \(describe($0))" }.joined(separator: "\n")
             return ToolOutput(list + "\nstop on errors: \(basic.errorStop.rawValue)")
         }),
    Tool(name: "basic_delete_breakpoint",
         description: "Delete a BASIC breakpoint by ID, or all of them.",
         schema: schema(["id": prop("integer", "Breakpoint ID"), "all": prop("boolean", "Delete them all")]),
         run: { s, a in
             let basic = try s.require().debugger.basic
             if bool(a, "all") == true {
                 basic.removeAllBreakpoints()
                 return ToolOutput("deleted all BASIC breakpoints")
             }
             guard let id = int(a, "id") else { throw ToolError(message: "give id, or all: true") }
             guard basic.breakpoints.contains(where: { $0.id == id }) else { throw ToolError(message: "no BASIC breakpoint \(id)") }
             basic.remove(id: id)
             return ToolOutput("deleted BASIC breakpoint \(id)")
         }),
    Tool(name: "basic_stop_on_errors",
         description: "Whether a BASIC error stops the program in the debugger, where it happened (with the call stack and variables as they were): off, untrapped (errors no ON ERROR handles, including Escape and STOP), or all (before ON ERROR sees them). Errors in commands typed in don't stop.",
         schema: schema(["mode": ["type": "string", "enum": ["off", "untrapped", "all"], "description": "Default untrapped"]]),
         run: { s, a in
             guard let mode = BasicDebugger.ErrorStop(rawValue: str(a, "mode") ?? "untrapped") else {
                 throw ToolError(message: "mode must be off, untrapped or all")
             }
             try s.require().debugger.basic.errorStop = mode
             return ToolOutput("stop on errors: \(mode.rawValue)")
         }),
    Tool(name: "basic_step",
         description: "Step a BASIC program from where it stopped: into (to the next statement, into PROCs, FNs and GOSUBs), over (the next statement in this PROC/FN/subroutine, or its caller once it returns), or out (until this PROC/FN/subroutine returns). Repeats count times. If BASIC isn't stopped, runs to the next statement. Returns where it stopped.",
         schema: schema(["kind": ["type": "string", "enum": ["into", "over", "out"], "description": "Default over"],
                         "count": prop("integer", "How many (default 1, max 1000)"),
                         "max_seconds": prop("number", "Longest per step (default 10)")]),
         run: { s, a in
             guard let kind = BasicStep(rawValue: str(a, "kind") ?? "over") else { throw ToolError(message: "kind must be into, over or out") }
             let m = try s.require()
             let count = max(1, min(1000, int(a, "count") ?? 1))
             let maxTicks = UInt64((num(a, "max_seconds") ?? 10) * 24_000_000)
             var reason: Debugger.StopReason?
             for _ in 0..<count {
                 reason = m.debugger.run(basic: kind, maxTicks: maxTicks) { s.advance(ticks: $0) }
                 guard reason == .basicStepped else { break }
             }
             return ToolOutput(basicSummary(m, reason))
         }),
    Tool(name: "basic_where",
         description: "Where the BASIC program is stopped: the line, the error it stopped on (if any), the PROC/FN calls (innermost first) and the current PROC/FN's LOCALs. Also which BASIC the ROM has.",
         schema: schema([:]), run: { s, _ in
             let m = try s.require()
             let basic = m.debugger.basic
             let rom = basic.interpreter.map { "BASIC: \($0.name)" } ?? "this ROM's BASIC isn't one the debugger knows"
             guard let text = basicWhere(m) else {
                 return ToolOutput(rom + "\nnot stopped in BASIC" + (m.debugger.stopReason.map { " (stopped: \($0))" } ?? "")
                                   + (basic.isAtPrompt ? "; BASIC is at its prompt" : ""))
             }
             return ToolOutput(text + "\n" + rom)
         }),
    Tool(name: "basic_list",
         description: "The BASIC program in memory, as LIST shows it, marking where it's stopped (>) and breakpoints (*).",
         schema: schema(["from": prop("integer", "First line number (default the start)"),
                         "to": prop("integer", "Last line number (default the end)")]),
         run: { s, a in
             let basic = try s.require().debugger.basic
             let from = int(a, "from") ?? 0, to = int(a, "to") ?? 65535
             let listing = basic.listing()
             let lines = listing.filter { (from...max(from, to)).contains($0.number) }
             guard !lines.isEmpty else { return ToolOutput(listing.isEmpty ? "no program in memory" : "no lines there") }
             let here = basic.stop?.line
             let breakpoints = Set(basic.breakpoints.filter(\.enabled).map(\.line))
             let width = String(lines.last!.number).count
             return ToolOutput(lines.map { line in
                 let mark = (line.number == here ? ">" : " ") + (breakpoints.contains(line.number) ? "*" : " ")
                 let number = String(line.number)
                 return mark + String(repeating: " ", count: width - number.count) + number + line.text
             }.joined(separator: "\n"))
         }),
    Tool(name: "basic_variables",
         description: "The BASIC program's variables and their values: @% to Z% (the non-zero ones, unless all), then the rest; arrays with their sizes (elements: show their values too). LOCALs and parameters of the PROC/FN it's stopped in are marked. Reading them doesn't disturb the program.",
         schema: schema(["filter": prop("string", "Only names starting with this"),
                         "all": prop("boolean", "Include @% to Z% when they're 0"),
                         "elements": prop("integer", "Show up to this many of each array's elements (default 0)")]),
         run: { s, a in
             let basic = try s.require().debugger.basic
             let filter = str(a, "filter") ?? ""
             let all = bool(a, "all") ?? false
             let elements = max(0, min(1000, int(a, "elements") ?? 0))
             let variables = basic.variables().filter { v in
                 v.name.hasPrefix(filter) && (all || !v.isResident || v.value != .integer(0))
             }
             guard !variables.isEmpty else { return ToolOutput("no variables" + (filter.isEmpty ? "" : " starting \(filter)")) }
             return ToolOutput(variables.map { v in
                 var text = describe(v)
                 if elements > 0, v.dimensions != nil {
                     text += "\n" + basic.elements(of: v, count: elements).map { indices, value in
                         "  \(v.name)\(indices.map(String.init).joined(separator: ","))) = \(value)"
                     }.joined(separator: "\n")
                 }
                 return text
             }.joined(separator: "\n"))
         }),
    Tool(name: "basic_evaluate",
         description: "Evaluate a BASIC expression with the program's variables: numbers, strings, variables, array elements, ? ! $ indirection, PAGE TOP LOMEM HIMEM ERR ERL, and BASIC's operators (+ - * / ^ DIV MOD = <> < > <= >= AND OR EOR NOT). No function calls: nothing in the program runs.",
         schema: schema(["expression": prop("string", "e.g. \"total/count%\" or \"grid%(X%,Y%)\"")], required: ["expression"]),
         run: { s, a in
             guard let source = str(a, "expression") else { throw ToolError(message: "expression is required") }
             do { return ToolOutput("\(try s.require().debugger.basic.evaluate(source))") } catch let e as ToolError { throw e } catch {
                 throw ToolError(message: "\(error)")
             }
         }),
    Tool(name: "basic_set_variable",
         description: "Set a BASIC variable (one that exists) or array element to an expression's value. A string can't be made longer than the space BASIC gave it.",
         schema: schema(["name": prop("string", "e.g. \"count%\", \"total\", \"name$\", or an array as \"grid%(\""),
                         "indices": ["type": "array", "items": ["type": "integer"], "description": "An array element's indices"],
                         "value": prop("string", "A BASIC expression, e.g. \"42\", \"\\\"text\\\"\", \"total*2\"")],
                        required: ["name", "value"]),
         run: { s, a in
             guard let name = str(a, "name"), let value = str(a, "value") else { throw ToolError(message: "name and value are required") }
             let indices = (a["indices"] as? [Any])?.compactMap { ($0 as? Int) ?? ($0 as? Double).map { Int($0) } }
             let m = try s.require()
             let basic = m.debugger.basic
             do {
                 try basic.set(name, indices: indices, to: value)
                 s.rewinder.keyframe(m)
                 let element = indices.map { "\(name)\($0.map(String.init).joined(separator: ",")))" }
                 return ToolOutput("\(element ?? name) = \(try basic.evaluate(element ?? name))")
             } catch {
                 throw ToolError(message: "\(error)")
             }
         }),
]
