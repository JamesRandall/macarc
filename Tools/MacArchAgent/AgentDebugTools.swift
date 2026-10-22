import ArchimedesCore
import Foundation

// The debugging tools: memory, registers, breakpoints, stepping (forwards
// and back), the trace, symbols, the profiler and the log.

func hexDump(_ m: Machine, from start: UInt32, length: Int, space: MEMC.DebugSpace) -> String? {
    var rows: [String] = []
    var a = start
    var total = 0
    outer: while total < length {
        var bytes: [UInt8] = []
        for i in 0..<min(16, length - total) {
            guard let b = m.memc.debugRead(a &+ UInt32(i), space: space) else {
                if !bytes.isEmpty { rows.append(row(a, bytes)) }
                break outer
            }
            bytes.append(b)
        }
        rows.append(row(a, bytes))
        total += bytes.count
        a &+= UInt32(bytes.count)
    }
    return rows.isEmpty ? nil : rows.joined(separator: "\n")

    func row(_ a: UInt32, _ bytes: [UInt8]) -> String {
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ").padding(toLength: 47, withPad: " ", startingAt: 0)
        let ascii = String(bytes.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "." })
        return String(format: "%08X  ", a) + hex + "  " + ascii
    }
}

let debugTools: [Tool] = [
    Tool(name: "peek",
         description: "Read memory without side effects (I/O isn't read). Returns a hex dump. Addresses can be numbers or expressions (e.g. \"PC\", \"{R13}\", \"R0+&100\").",
         schema: schema(["address": prop("string", "Start address: &8000, $8000, 0x8000, decimal or an expression"),
                         "length": prop("integer", "Bytes (default 64, max 4096)"), "space": spaceProp], required: ["address"]),
         run: { s, a in
             let m = try s.require()
             let (sp, base) = try space(a)
             guard let addr = try address(a, "address", m) else { throw ToolError(message: "address is required") }
             let length = max(1, min(4096, int(a, "length") ?? 64))
             guard let dump = hexDump(m, from: base &+ addr, length: length, space: sp) else { throw ToolError(message: "nothing at \(hex(addr)) in \(str(a, "space") ?? "logical")") }
             return ToolOutput(dump)
         }),
    Tool(name: "poke",
         description: "Write bytes to memory: RAM through the CPU's view (logical, the default), or physical RAM (space physical). Not I/O.",
         schema: schema(["address": prop("string", "Start address or expression"),
                         "bytes": ["type": "array", "items": ["type": "integer"], "description": "Values 0-255"], "space": spaceProp], required: ["address", "bytes"]),
         run: { s, a in
             let m = try s.require()
             let (sp, base) = try space(a)
             guard let addr = try address(a, "address", m) else { throw ToolError(message: "address is required") }
             guard let raw = a["bytes"] as? [Any] else { throw ToolError(message: "bytes must be an array of 0-255") }
             let bytes = try raw.map { v -> UInt8 in
                 guard let n = (v as? Int) ?? (v as? Double).map({ Int($0) }), (0...255).contains(n) else { throw ToolError(message: "bytes must be an array of 0-255") }
                 return UInt8(n)
             }
             for (i, b) in bytes.enumerated() where !m.memc.debugWrite(base &+ addr &+ UInt32(i), b, space: sp) {
                 throw ToolError(message: "can't write \(hex(addr &+ UInt32(i))) (I/O, ROM or nothing there); wrote \(i) bytes")
             }
             s.rewinder.keyframe(m)
             return ToolOutput("wrote \(bytes.count) bytes at \(hex(addr)) in \(str(a, "space") ?? "logical")")
         }),
    Tool(name: "disassemble",
         description: "Disassemble ARM code as the CPU sees memory now (SWIs by name, branch targets by symbol). Default: around the current instruction. Marks the PC and breakpoints.",
         schema: schema(["address": prop("string", "Start address or expression (default PC)"), "count": prop("integer", "Instructions (default 16)")]),
         run: { s, a in
             let m = try s.require()
             let start = (try address(a, "address", m) ?? m.cpu.pc) & ~3
             return ToolOutput(disassembly(m, from: start, count: max(1, min(256, int(a, "count") ?? 16))))
         }),
    Tool(name: "memory_regions",
         description: "The memory map (for peek/poke's space) and MEMC's current settings: page size, mapped pages, video and sound buffers.",
         schema: schema([:]), run: { s, _ in
             let m = try s.require()
             let mm = m.memc
             var lines = [
                 "logical      &0000000-&1FFFFFF  RAM mapped through MEMC's page table (the CPU's view)",
                 String(format: "physical     &2000000-&%07X  physical RAM (%d KB); as space physical, offsets from 0", 0x0200_0000 + mm.ramSize - 1, mm.ramSize / 1024),
                 "io           &3000000-&33FFFFF  IOC and its peripherals (not peeked)",
                 "vidc/memc    &3400000-&37FFFFF  write-only registers",
                 String(format: "rom          &3800000-&3FFFFFF  RISC OS ROM (%d KB)", mm.romSize / 1024),
             ]
             lines.append("MEMC: \(4 << Int(mm.pageSizeCode)) KB pages, \(mm.mappedPages.mapped) of \(mm.mappedPages.total) mapped, ROM overlay \(mm.romOverlay ? "on" : "off")")
             lines.append(String(format: "video: Vstart &%X Vend &%X Vinit &%X; sound: Sstart &%X SendN &%X", mm.vstart, mm.vend, mm.vinit, mm.sstart, mm.sendNext))
             return ToolOutput(lines.joined(separator: "\n"))
         }),
    Tool(name: "registers",
         description: "CPU registers (with the banked FIQ, IRQ and SVC sets), flags (upper case = set), mode, and whether the debugger has stopped the machine.",
         schema: schema([:]), run: { s, _ in
             let m = try s.require()
             var lines = [registerLine(m)]
             for mode in [ARM2<MEMC>.Mode.user, .fiq, .irq, .supervisor] where mode != m.cpu.mode {
                 let b = m.cpu.bankedRegisters(mode)
                 lines.append("\(mode): " + (mode == .fiq ? (8...14) : (13...14)).map { String(format: "R%d=%08X", $0, b[$0 - 8]) }.joined(separator: " "))
             }
             lines.append("instruction \(m.cpu.instructionCount), cycle \(m.ticks)")
             if let r = m.debuggerIfCreated?.stopReason { lines.append("stopped: \(r)") }
             return ToolOutput(lines.joined(separator: "\n"))
         }),
    Tool(name: "set_register",
         description: "Set a register (R0-R14 as the current mode sees them, SP, LR, PC, PSR, MODE 0-3) or flag (N Z C V I F).",
         schema: schema(["name": prop("string", "Register or flag"), "value": prop("string", "Value or expression")], required: ["name", "value"]),
         run: { s, a in
             let m = try s.require()
             guard let name = str(a, "name"), let v = try address(a, "value", m) else { throw ToolError(message: "name and value are required") }
             do { try m.debugger.setRegister(name, v) } catch { throw ToolError(message: "\(error)") }
             s.rewinder.keyframe(m)
             return ToolOutput(registerLine(m))
         }),
    Tool(name: "set_breakpoint",
         description: "Stop when the CPU executes an address (default), or reads or writes it (a watchpoint; it stops after the instruction). Then use continue. Ranges, conditions (e.g. \"R0 == &41 && [R1] > 3\"), hit counts, a processor mode, and log points (log_message, with {expression}s, instead of stopping) are supported. Returns the breakpoint's ID.",
         schema: schema(["address": prop("string", "Address, expression or symbol"),
                         "end": prop("string", "Last address of a range (default: just address)"),
                         "type": ["type": "string", "enum": ["execute", "read", "write", "access"], "description": "What to stop on (default execute; access is read or write)"],
                         "condition": prop("string", "Only when this is true"),
                         "hit_count": prop("integer", "Only stop on this hit (and later ones)"),
                         "log_message": prop("string", "Log this instead of stopping, e.g. \"R0={R0} at {PC}\""),
                         "mode": ["type": "string", "enum": ["USR", "FIQ", "IRQ", "SVC"], "description": "Only in this processor mode"]], required: ["address"]),
         run: { s, a in
             let m = try s.require()
             guard let start = try address(a, "address", m) else { throw ToolError(message: "address is required") }
             let end = try address(a, "end", m)
             let kinds: [String: Debugger.Breakpoint.Kind] = ["execute": .execute, "read": .read, "write": .write, "access": .access]
             guard let kind = kinds[str(a, "type") ?? "execute"] else { throw ToolError(message: "type must be execute, read, write or access") }
             let modes: [String: ARM2<MEMC>.Mode] = ["USR": .user, "FIQ": .fiq, "IRQ": .irq, "SVC": .supervisor]
             let mode = try str(a, "mode").map { n -> ARM2<MEMC>.Mode in
                 guard let md = modes[n.uppercased()] else { throw ToolError(message: "mode must be USR, FIQ, IRQ or SVC") }
                 return md
             }
             do {
                 let b = try m.debugger.addBreakpoint(.init(id: 0, kind: kind, start: kind == .execute ? start & ~3 : start, end: end, mode: mode,
                                                           condition: str(a, "condition").flatMap { $0.isEmpty ? nil : $0 },
                                                           hitTarget: int(a, "hit_count"), logMessage: str(a, "log_message").flatMap { $0.isEmpty ? nil : $0 }))
                 return ToolOutput("breakpoint \(b.id): \(b.describe)")
             } catch {
                 throw ToolError(message: "condition: \(error)")
             }
         }),
    Tool(name: "list_breakpoints",
         description: "The breakpoints, with hit counts.",
         schema: schema([:]), run: { s, _ in
             let bps = try s.require().debugger.breakpoints
             return ToolOutput(bps.isEmpty ? "no breakpoints" : bps.map { "\($0.id): \($0.describe)" }.joined(separator: "\n"))
         }),
    Tool(name: "delete_breakpoint",
         description: "Delete a breakpoint by ID, or all of them.",
         schema: schema(["id": prop("integer", "Breakpoint ID"), "all": prop("boolean", "Delete them all")]),
         run: { s, a in
             let d = try s.require().debugger
             if bool(a, "all") == true { d.removeAllBreakpoints(); return ToolOutput("deleted all breakpoints") }
             guard let id = int(a, "id") else { throw ToolError(message: "give id, or all: true") }
             guard d.removeBreakpoint(id) else { throw ToolError(message: "no breakpoint \(id)") }
             return ToolOutput("deleted breakpoint \(id)")
         }),
    Tool(name: "continue",
         description: "Run until a breakpoint or watchpoint hits (or max_seconds of emulated time). Also resumes after a stop. Returns where it stopped, the registers and the code there.",
         schema: schema(["max_seconds": prop("number", "Longest to run (default 30)")]),
         run: { s, a in
             let m = try s.require()
             let r = m.debugger.run(.continue, maxTicks: UInt64((num(a, "max_seconds") ?? 30) * 24_000_000)) { s.advance(ticks: $0) }
             return ToolOutput(debugSummary(s.machine ?? m, r))
         }),
    Tool(name: "step",
         description: "Step the CPU: instruction (into calls), over (a BL or SWI runs to the next instruction), out (until the routine returns to R14, or the interrupt handler ends), scanline, frame, interrupt (until an IRQ or FIQ is taken), to (an address, given in address), or back (to the previous instruction, using the rewind history). Repeats count times. Returns the registers and code.",
         schema: schema(["kind": ["type": "string", "enum": ["instruction", "over", "out", "scanline", "frame", "interrupt", "to", "back"], "description": "What to step (default instruction)"],
                         "count": prop("integer", "How many (default 1, max 10000)"),
                         "address": prop("string", "For kind to: where to run to"),
                         "max_seconds": prop("number", "Longest per step (default 10)")]),
         run: { s, a in
             var m = try s.require()
             let count = max(1, min(10000, int(a, "count") ?? 1))
             let kind = str(a, "kind") ?? "instruction"
             if kind == "back" {
                 var reason: Debugger.StopReason?
                 for _ in 0..<count {
                     let back = try m.debugger.stepBack(s.rewinder)
                     s.replace(with: back)
                     m = back
                     reason = back.debugger.stopReason
                     if reason == .historyStart { break }
                 }
                 return ToolOutput(debugSummary(m, reason))
             }
             let command: Debugger.RunCommand
             switch kind {
             case "instruction": command = .stepInstruction
             case "over": command = .stepOver
             case "out": command = .stepOut
             case "scanline": command = .nextScanline
             case "frame": command = .nextFrame
             case "interrupt": command = .nextInterrupt
             case "to":
                 guard let t = try address(a, "address", m) else { throw ToolError(message: "to needs an address") }
                 command = .runToAddress(t)
             default: throw ToolError(message: "unknown kind \(kind)")
             }
             var reason: Debugger.StopReason?
             let maxTicks = UInt64((num(a, "max_seconds") ?? 10) * 24_000_000)
             for _ in 0..<count {
                 reason = m.debugger.run(command, maxTicks: maxTicks) { s.advance(ticks: $0) }
                 if reason == nil { break }
                 if case .breakpoint = reason { break }
             }
             return ToolOutput(debugSummary(m, reason))
         }),
    Tool(name: "reverse_continue",
         description: "Run backwards to the last time a breakpoint or watchpoint hit (e.g. \"who wrote &8000?\": set a write breakpoint on &8000, then reverse_continue), using the rewind history (about the last 60 seconds). Stops there, as if it had just hit.",
         schema: schema([:]), run: { s, _ in
             let m = try s.require()
             let back = try m.debugger.reverseContinue(s.rewinder)
             s.replace(with: back)
             return ToolOutput(debugSummary(back, back.debugger.stopReason))
         }),
    Tool(name: "rewind",
         description: "Go back in time: by seconds (of emulated time), or to an exact cycle (24 MHz ticks). History covers about the last 60 seconds. Running on afterwards replaces what came after.",
         schema: schema(["seconds": prop("number", "How far back"), "cycle": prop("integer", "Or: the cycle to go to")]),
         run: { s, a in
             let m = try s.require()
             guard let earliest = s.rewinder.earliestTicks else { throw ToolError(message: "no rewind history") }
             let target: UInt64
             if let c = num(a, "cycle") { target = UInt64(c) } else if let sec = num(a, "seconds") {
                 let back = UInt64(sec * 24_000_000)
                 target = m.ticks > back ? m.ticks - back : 0
             } else { throw ToolError(message: "give seconds or cycle") }
             guard let n = try s.rewinder.machine(at: max(earliest, target), from: m) else { throw ToolError(message: "no rewind history") }
             s.replace(with: n)
             return ToolOutput(summary(s, "now at cycle \(n.ticks) (history from cycle \(s.rewinder.earliestTicks ?? earliest))"))
         }),
    Tool(name: "trace",
         description: "Instruction trace: with enable, start recording the last N instructions (0 stops); otherwise show the last count recorded, with the registers before each.",
         schema: schema(["enable": prop("integer", "Start recording this many instructions (0 to stop)"), "count": prop("integer", "Show the last this many (default 32)")]),
         run: { s, a in
             let d = try s.require().debugger
             if let n = int(a, "enable") {
                 d.setTracing(min(max(0, n), 10_000_000))
                 return ToolOutput(n > 0 ? "tracing the last \(n) instructions" : "tracing off")
             }
             guard let t = d.trace else { return ToolOutput("tracing is off; call trace with enable first") }
             let entries = t.last(max(1, min(10_000, int(a, "count") ?? 32)))
             guard !entries.isEmpty else { return ToolOutput("nothing traced yet") }
             return ToolOutput(entries.map { e in
                 if let i = e.interrupt { return "\(e.ticks)  \(String(format: "%08X", e.pc))  -- \(i) --" }
                 return "\(e.ticks)  " + String(format: "%08X  ", e.pc) + Disassembler.disassemble(e.instruction, at: e.pc, symbols: d.symbols).padding(toLength: 34, withPad: " ", startingAt: 0) + " " + e.registerText
             }.joined(separator: "\n"))
         }),
    Tool(name: "load_symbols",
         description: "Load symbols for the debugger from a label file: lines like \"name = &8000\", \"name: &8000\", \"name EQU &8000\", \".name &8000\", or nm output (\"00008000 T name\"). Then addresses and expressions can use the names, and disassembly shows them. The exception vectors and the I/O chips' registers are always known; SWIs show by name.",
         schema: schema(["path": prop("string", "The label file"), "clear": prop("boolean", "Forget previously loaded symbols first")], required: ["path"]),
         run: { s, a in
             let d = try s.require().debugger
             let path = try checkPath(str(a, "path") ?? "")
             if bool(a, "clear") == true { d.clearSymbols() }
             do {
                 let t = try SymbolTable.load(path: path)
                 d.addSymbols(t)
                 return ToolOutput("loaded \(t.count) symbols")
             } catch { throw ToolError(message: "\(error)") }
         }),
    Tool(name: "assemble",
         description: "Assemble an ARM source file (BBC BASIC V assembler syntax as a file of its own; see the server instructions), load its labels and source lines into the debugger (so breakpoints can be \"game.s:42\"), and run it from the * prompt (F12 from the desktop) with *Go, where it should end with SWI OS_Exit. Returns the errors (with lines) or what it printed and the screen. With run false, the code is loaded but not started: set breakpoints, then run_command \"*Go <entry>\".",
         schema: schema(["source": prop("string", "The source file (.s)"),
                         "run": prop("boolean", "Start it (default true)"),
                         "output": prop("string", "Also write the assembled bytes to this file"),
                         "max_seconds": prop("number", "Longest to run before returning (default 10)"),
                         "resume": resumeProp],
                        required: ["source"]),
         run: { s, a in
             let path = try checkPath(str(a, "source") ?? "")
             let assembly: ARMAssembler.Assembly
             do { assembly = try ARMAssembler.assemble(file: path) } catch { throw ToolError(message: "\(error)") }
             if let out = str(a, "output") {
                 try Data(assembly.bytes).write(to: URL(fileURLWithPath: try checkPath(out)))
             }
             var report = String(format: "assembled %@: %d bytes at &%X-&%X, entry &%X; %d labels, %d source lines",
                                 (path as NSString).lastPathComponent, assembly.bytes.count, assembly.origin, assembly.end, assembly.entry,
                                 assembly.symbols.count, assembly.symbols.lineCount)
             if !assembly.warnings.isEmpty { report += "\nwarnings:\n" + assembly.warnings.map(\.description).joined(separator: "\n") }
             let m = try s.require()
             resumeIfStopped(m, a)
             try commandPrompt(s)
             try loadProgram(s.machine ?? m, assembly)
             s.rewinder.keyframe(s.machine ?? m)
             let go = String(format: "*Go %X", assembly.entry)
             guard bool(a, "run") ?? true else { return ToolOutput(report + "\nloaded; start it with run_command \"\(go)\"") }
             return ToolOutput(report + "\n" + command(s, go, maxSeconds: num(a, "max_seconds") ?? 10))
         }),
    Tool(name: "lookup_symbol",
         description: "A symbol's address, or the symbols (and assembled source line) at or near an address.",
         schema: schema(["name": prop("string", "Symbol name"), "address": prop("string", "Or an address")]),
         run: { s, a in
             let m = try s.require()
             let d = m.debugger
             if let n = str(a, "name") {
                 guard let v = d.symbols.address(of: n) else { throw ToolError(message: "no symbol \(n)") }
                 return ToolOutput("\(n) = \(hex(v))")
             }
             guard let addr = try address(a, "address", m) else { throw ToolError(message: "give name or address") }
             var parts = d.symbols.names(at: addr)
             if parts.isEmpty, let near = d.symbols.describe(addr) { parts.append(near) }
             if let l = d.symbols.location(at: addr) { parts.append("from \(l)") }
             return ToolOutput(parts.isEmpty ? "nothing known at \(hex(addr))" : "\(hex(addr)): " + parts.joined(separator: ", "))
         }),
    Tool(name: "profile",
         description: "Profile: run for some seconds (of emulated time) counting the time spent at every instruction, then report the busiest routines (by symbol, else by 4 KB page) and instructions, time in interrupt handlers (IRQ and FIQ mode), and time per frame.",
         schema: schema(["seconds": prop("number", "How long (default 1, up to 120)"), "top": prop("integer", "How many instructions to list (default 15, max 200)"), "resume": resumeProp]),
         run: { s, a in
             let m = try s.require()
             resumeIfStopped(m, a)
             let seconds = max(0.01, min(120, num(a, "seconds") ?? 1))
             let d = m.debugger
             d.startProfiling()
             s.advance(until: { false }, maxSeconds: seconds)
             d.stopProfiling()
             guard let p = (s.machine ?? m).debugger.profiler else { return ToolOutput("no profile") }
             let top = max(1, min(200, int(a, "top") ?? 15))
             let r = p.report(top: top, symbols: d.symbols)
             let total = max(1, Double(r.totalTicks))
             var lines = [String(format: "profiled %.2fs: %llu cycles (24 MHz), %d frames (%.0f cycles a frame)", seconds, r.totalTicks, r.frames, r.ticksPerFrame),
                          String(format: "in interrupt handlers: %5.1f%%", 100 * r.interruptShare), "routines:"]
             lines += r.routines.prefix(15).map { String(format: "  %5.1f%%  %@", 100 * Double($0.ticks) / total, $0.name) }
             lines.append("busiest instructions:")
             for e in r.hottest {
                 let word = m.memc.debugReadWord(e.address, space: .logical) ?? 0
                 let text = Disassembler.disassemble(word, at: e.address, symbols: d.symbols).padding(toLength: 30, withPad: " ", startingAt: 0)
                 lines.append(String(format: "  %5.1f%%  &%07X  %@ %d runs", 100 * Double(e.ticks) / total, e.address, text, e.executions))
             }
             return ToolOutput(lines.joined(separator: "\n"))
         }),
    Tool(name: "debug_log",
         description: "Output from log-point breakpoints (log_message), oldest first.",
         schema: schema(["count": prop("integer", "How many (default 50)")]),
         run: { s, a in
             let log = try s.require().debugger.log.suffix(max(1, int(a, "count") ?? 50))
             return ToolOutput(log.isEmpty ? "no log output" : log.map { "[\($0.ticks)] \($0.text)" }.joined(separator: "\n"))
         }),
]

/// The server's instructions to agents.
public let mcpInstructions = """
This server drives an emulated Acorn Archimedes running RISC OS from the user's own ROM: an A3000 (ARM2 at 8 MHz) by default, or an A305/A310, A410/1-A440/1 (with ST506 hard discs), A540, A5000 (ARM3, IDE) or A3010/A3020/A4000 (ARM250), with an optional ARM3. get_status says which; power_cycle with model/cpu/ram_kb/hard_discs switches. Time is emulated time: waits are exact and run much faster than real time.

Typical use: run_command for * commands and BASIC (it presses F12 for the command line from the desktop; returns what RISC OS printed and the screen); load_disc with an .adf/.jfd path, then run_command (e.g. "/:0.$.!App") or the mouse (three buttons: select, menu, adjust; x/y follow the pointer) on the desktop; type_text or press_keys for programs that read the keyboard directly; read_screen_text to see text on screen; screenshot for graphics and the desktop; run / run_until_idle to let time pass; peek, poke and disassemble for memory and code; start_recording/stop_recording to make a movie.

Debugging: set_breakpoint (execute, or read/write watchpoints, with conditions, a processor mode and log points), then continue; step (instruction, over, out, scanline, frame, interrupt, to, back); registers and set_register; trace for the last N instructions; profile to see where the time goes; peek/poke take a space (logical, physical, rom; see memory_regions) and addresses can be expressions such as "{R13}" or "PC+4"; load_symbols for names. When the debugger stops the machine it stays stopped (other tools say so) until continue or step, or a tool that runs the machine (press_keys, run, profile...) carries on from the stop; pass resume: false to leave it stopped. Breakpoints and symbols survive restore_snapshot, load_state and power_cycle. In the app, the machine runs in real time between tool calls; set_real_time on: false holds it still, so replays are exact. History: rewind goes back up to about 60 seconds; step kind back and reverse_continue debug backwards ("who wrote this?").

Writing programs: assemble takes an ARM source file in BBC BASIC V's assembler syntax as a file of its own: labels as .name (or name: or a name in column 1); instructions as on the ARM2/ARM3 (ADDEQS or ADDSEQ, LDR R0, =value, LDMFD R13!, {R0-R3, PC}^, SWI "OS_Write0" or SWI OS_Write0); directives ORG (default &8000), ENTRY, ALIGN, EQUB/EQUW/EQUD/EQUS (or DCB/DCW/DCD/DCS), SKIP, LTORG, INCLUDE, INCBIN, and name EQU value; comments after ; or \\ or //. It loads the code at the * prompt and runs it with *Go; end with SWI OS_Exit (or MOV PC, R14). Errors come back with their lines. Then set_breakpoint takes "file.s:line", and disassemble shows source lines.

The machine starts at the RISC OS desktop.
"""
