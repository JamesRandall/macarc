import ArchimedesCore
import Foundation

// The agent tools: one table shared by the headless MCP server and the app
// (which serves them on a local socket for `macarch-mcp --attach`). They
// follow MacBeeb's, so the two emulators work the same way for agents.
//
// File access is restricted to MACARCH_ALLOWED_DIRS (colon separated); by
// default the current directory and ~/Library/Application Support/MacArch.

/// Where a tool's machine lives: the app's window, or a headless machine.
public protocol AgentSession: AnyObject {
    var machine: Machine? { get }
    /// True when driving the app's machine.
    var isAttached: Bool { get }
    var rewinder: Rewinder { get }
    /// In the app the machine runs in real time between tool calls unless
    /// this holds it; a headless machine only runs during calls.
    var heldBetweenCalls: Bool { get set }
    var runsBetweenCalls: Bool { get }
    /// Runs the machine for `ticks`, recording rewind points (and in the
    /// app, keeping the window current).
    func advance(ticks: UInt64)
    /// Swaps in another machine (snapshot, state, rewind).
    func replace(with m: Machine)
    /// Switches off and on, with changed hardware if given.
    func powerCycle(_ change: HardwareChange?) throws
    func startRecording(to url: URL) throws
    func stopRecording() -> Bool
    var isRecording: Bool { get }
}

/// What power_cycle can change.
public struct HardwareChange {
    public var model: MachineModel?
    public var cpu: CPUType?
    public var ramKB: Int?
    public var romPath: String?
    public var hardDiscs: [String?]?
    public var monitor: MonitorType?
    public var cmosReset = false
    public init() {}
}

extension AgentSession {
    func require() throws -> Machine {
        guard let m = machine else {
            throw ToolError(message: "no machine: there's no RISC OS ROM. Run macarch-mcp with --rom <file or folder>, set MACARCH_ROM, choose one in the MacArch app, or call power_cycle with rom")
        }
        return m
    }

    func advance(seconds: Double) { advance(ticks: UInt64(max(0, seconds) * Double(MasterClock.ticksPerSecond))) }

    /// Runs until `done` (checked every millisecond of emulated time), a
    /// debugger stop, or `maxSeconds`. Returns whether `done` became true.
    @discardableResult
    func advance(until done: () -> Bool, maxSeconds: Double) -> Bool {
        let limit = UInt64(maxSeconds * Double(MasterClock.ticksPerSecond))
        var spent: UInt64 = 0
        while spent < limit {
            if done() { return true }
            guard let m = machine, !m.isStoppedByDebugger else { return false }
            let before = m.ticks
            advance(ticks: 24_000)
            spent &+= max(1, m.ticks &- before)
        }
        return done()
    }
}

/// Runs a tool against a session, on whatever thread owns the machine.
public protocol AgentContext: AnyObject {
    func perform<T>(_ body: @escaping (AgentSession) throws -> T) throws -> T
}

public enum AgentPaths {
    public static var supportDirectory: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/MacArch")
    }

    /// Directories tools may read and write.
    public static var allowedRoots: [String] = {
        if let env = ProcessInfo.processInfo.environment["MACARCH_ALLOWED_DIRS"], !env.isEmpty {
            return env.split(separator: ":").map { (String($0) as NSString).standardizingPath }
        }
        return [FileManager.default.currentDirectoryPath, supportDirectory].map { ($0 as NSString).standardizingPath }
    }()
}

/// Lists and calls tools; the result of a call is an MCP CallToolResult.
public protocol ToolProvider: AnyObject {
    var toolList: [[String: Any]] { get }
    func call(_ name: String, _ arguments: [String: Any]) -> [String: Any]
}

/// What a tool returns: text, and perhaps a PNG.
public struct ToolOutput {
    public var text: String
    public var png: Data?
    public init(_ text: String, png: Data? = nil) { self.text = text; self.png = png }
}

/// The tools, run in a context.
public final class AgentTools: ToolProvider {
    let context: AgentContext
    /// The app's networks; nil headless.
    public weak var directory: MachineDirectory?
    public init(context: AgentContext, directory: MachineDirectory? = nil) {
        self.context = context
        self.directory = directory
    }

    /// Named snapshots (save_snapshot), kept in memory for the process.
    nonisolated(unsafe) static var slots: [String: [UInt8]] = [:]

    public var toolList: [[String: Any]] {
        guard directory != nil else {
            return allTools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.schema] }
        }
        // With networks, every machine tool can name its machine.
        return allTools.map { tool in
            var schema = tool.schema
            var props = schema["properties"] as? [String: Any] ?? [:]
            props["machine"] = machineProp
            schema["properties"] = props
            return ["name": tool.name, "description": tool.description, "inputSchema": schema]
        } + Self.networkToolDefinitions
    }

    public func call(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        do {
            let out: ToolOutput
            if Self.networkToolNames.contains(name), let directory {
                out = try directory.networkTool(name, arguments)
            } else {
                guard let tool = allTools.first(where: { $0.name == name }) else { return errorResult("unknown tool \(name)") }
                var context = self.context
                if let machine = str(arguments, "machine"), !machine.isEmpty {
                    guard let directory else { throw ToolError(message: "there are no networks here: leave out `machine`") }
                    context = try directory.context(for: machine)
                }
                out = try context.perform { try tool.run($0, arguments) }
            }
            var content: [[String: Any]] = []
            if !out.text.isEmpty || out.png == nil { content.append(["type": "text", "text": out.text]) }
            if let png = out.png { content.append(["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]) }
            return ["content": content, "isError": false]
        } catch let e as ToolError {
            return errorResult(e.message)
        } catch {
            return errorResult("\(error)")
        }
    }
}

func errorResult(_ message: String) -> [String: Any] {
    ["content": [["type": "text", "text": message]], "isError": true]
}

public struct ToolError: Error { public let message: String; public init(message: String) { self.message = message } }

func checkPath(_ p: String) throws -> String {
    let allowedRoots = AgentPaths.allowedRoots
    let abs = ((p as NSString).expandingTildeInPath as NSString).standardizingPath
    let full = abs.hasPrefix("/") ? abs : ((FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(abs) as NSString).standardizingPath
    guard allowedRoots.contains(where: { full == $0 || full.hasPrefix($0 + "/") }) else {
        throw ToolError(message: "path \(full) is outside the allowed directories \(allowedRoots)")
    }
    return full
}

// MARK: Argument helpers

func str(_ a: [String: Any], _ k: String) -> String? { a[k] as? String }
func num(_ a: [String: Any], _ k: String) -> Double? {
    if let d = a[k] as? Double { return d }
    if let i = a[k] as? Int { return Double(i) }
    if let s = a[k] as? String { return parseNumber(s).map(Double.init) ?? Double(s) }
    return nil
}
func int(_ a: [String: Any], _ k: String) -> Int? { num(a, k).map { Int($0) } }
func bool(_ a: [String: Any], _ k: String) -> Bool? { a[k] as? Bool }
func parseNumber(_ s: String) -> UInt32? {
    let t = s.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("0x") || t.hasPrefix("0X") { return UInt32(t.dropFirst(2), radix: 16) }
    if t.hasPrefix("&") || t.hasPrefix("$") { return UInt32(t.dropFirst(), radix: 16) }
    return UInt32(t)
}

/// A number, or a debugger expression ("PC+4", "{R13}", a symbol).
func address(_ a: [String: Any], _ k: String, _ m: Machine) throws -> UInt32? {
    if let i = a[k] as? Int { return UInt32(truncatingIfNeeded: i) }
    if let d = a[k] as? Double { return UInt32(d) }
    guard let s = a[k] as? String else { return nil }
    if let v = parseNumber(s) { return v }
    do { return try m.debugger.evaluate(s) } catch { throw ToolError(message: "\(k): \(error)") }
}

func hex(_ v: UInt32) -> String { String(format: "&%X", v) }

// MARK: Shared parts of results

/// Notes, the stop if there is one, and the screen.
func summary(_ s: AgentSession, _ extra: String = "") -> String {
    guard let m = s.machine else { return extra }
    var out: [String] = []
    if !extra.isEmpty { out.append(extra) }
    if let r = m.debuggerIfCreated?.stopReason { out.append("(stopped in the debugger: \(r); continue or step to go on)") }
    out.append(String(format: "[t=%.2fs] screen:", m.seconds))
    out.append(contentsOf: m.screenText)
    return out.joined(separator: "\n")
}

/// Unless resume is false, a debugger stop is cleared before running.
func resumeIfStopped(_ m: Machine, _ a: [String: Any]) {
    if bool(a, "resume") != false, let d = m.debuggerIfCreated, d.isStopped { d.resume() }
}

/// Waiting for input: no typing still queued, no disc busy, and RISC OS
/// has stayed inside a blocking read: OS_ReadC or OS_ReadLine at a prompt
/// for 0.3 s, or Wimp_Poll in the desktop for 1 s (while the desktop starts
/// up it waits there in shorter spells); or a program has been polling the
/// keyboard (INKEY) with the screen still for half a second.
func runUntilIdle(_ s: AgentSession, maxSeconds: Double) -> Bool {
    guard let m = s.machine else { return false }
    var inside = 0
    var polls: [UInt64] = []
    var frames: [UInt64] = []
    return s.advance(until: {
        if let i = m.insideBlockingRead() { inside = i ? inside + 1 : 0 }
        polls.append(m.keyboardPolls); if polls.count > 500 { polls.removeFirst() }
        frames.append(m.currentFrame.checksum); if frames.count > 500 { frames.removeFirst() }
        guard m.pendingInputEvents == 0, !m.discsBusy else { return false }
        if inside >= (m.blockingReadIsWimp ? 1000 : 300) { return true }
        return polls.count == 500 && polls.last! - polls.first! >= 10 && Set(frames).count == 1
    }, maxSeconds: maxSeconds)
}

/// Types a command at the prompt (pressing F12 first from the desktop) and
/// runs until RISC OS waits for input again; returns what it printed, and
/// the screen.
func command(_ s: AgentSession, _ text: String, maxSeconds max: Double) -> String {
    guard let m = s.machine else { return "" }
    // At a prompt the last thing printed is the prompt ("*" or ">").
    let tail = m.recentText.trimmingCharacters(in: .whitespacesAndNewlines).last
    if tail != "*" && tail != ">" {
        m.keyDown(0x0C); s.advance(seconds: 0.1); m.keyUp(0x0C); s.advance(seconds: 0.3)
    }
    let before = m.textOutput.totalAppended
    m.scheduleTyping(text + (text.hasSuffix("\n") ? "" : "\n"), intervalMs: 40)
    s.advance(until: { m.pendingInputEvents == 0 }, maxSeconds: max)
    let idle = runUntilIdle(s, maxSeconds: max)
    let new = Int(min(m.textOutput.totalAppended - before, UInt64(m.textOutput.count)))
    var output = ""
    for b in m.textOutput.elements.suffix(new) {
        if b == 13 || b == 10 { if !output.hasSuffix("\n") { output += "\n" } } else if b >= 32 && b < 127 { output.append(Character(UnicodeScalar(b))) }
    }
    return summary(s, "output:\n" + output + (idle ? "" : "\n(still running after \(Int(max))s)"))
}

/// Gets to the * prompt, where programs run in application memory: F12
/// from the desktop, QUIT from BASIC.
public func commandPrompt(_ s: AgentSession) throws {
    let m = try s.require()
    func tail() -> Character? { m.recentText.trimmingCharacters(in: .whitespacesAndNewlines).last }
    if tail() == ">" {
        m.scheduleTyping("QUIT\n", intervalMs: 40)
        s.advance(until: { m.pendingInputEvents == 0 }, maxSeconds: 5)
        _ = runUntilIdle(s, maxSeconds: 10)
    }
    if tail() != "*" {
        m.keyDown(0x0C); s.advance(seconds: 0.1); m.keyUp(0x0C); s.advance(seconds: 0.3)
        _ = runUntilIdle(s, maxSeconds: 10)
    }
    guard tail() == "*" else {
        throw ToolError(message: "couldn't get to a * prompt (is a program still running? Press Escape, or reset)")
    }
}

/// Writes assembled code into memory at its origin and loads its symbols
/// and source lines into the debugger. At the * prompt, application
/// memory starts at &8000.
public func loadProgram(_ m: Machine, _ a: ARMAssembler.Assembly) throws {
    for (i, b) in a.bytes.enumerated() where !m.memc.debugWrite(a.origin &+ UInt32(i), b, space: .logical) {
        throw ToolError(message: String(format: "the code doesn't fit: nothing is mapped at &%X (from the * prompt, application memory starts at &8000)", a.origin &+ UInt32(i)))
    }
    m.debugger.addSymbols(a.symbols)
}

func registerLine(_ m: Machine) -> String {
    let c = m.cpu
    let regs = (0...12).map { String(format: "R%d=%08X", $0, c.r[$0]) }.joined(separator: " ")
    return regs + String(format: " SP=%08X LR=%08X PC=%08X ", c.r[13], c.r[14], c.pc) + Debugger.flagText(c.psr) + " \(c.mode)"
}

func disassembly(_ m: Machine, from start: UInt32, count: Int) -> String {
    let d = m.debugger
    let execute = Set(d.breakpoints.filter { $0.kind.contains(.execute) && $0.enabled }.map(\.start))
    return (0..<count).map { i -> String in
        let a = start &+ UInt32(i * 4)
        var lines = d.symbols.names(at: a).map { "\($0):" }
        let word = m.memc.debugReadWord(a, space: .logical)
        let text = word.map { String(format: "%08X  ", $0) + Disassembler.disassemble($0, at: a, symbols: d.symbols) } ?? "--------  (unmapped)"
        var line = (a == m.cpu.pc ? "> " : "  ") + String(format: "%08X  ", a) + text
        var notes: [String] = []
        if let l = d.symbols.location(at: a) { notes.append("\(l)") }
        if execute.contains(a) { notes.append("breakpoint") }
        if !notes.isEmpty { line = line.padding(toLength: max(line.count, 60), withPad: " ", startingAt: 0) + " ; " + notes.joined(separator: ", ") }
        lines.append(line)
        return lines.joined(separator: "\n")
    }.joined(separator: "\n")
}

func debugSummary(_ m: Machine, _ reason: Debugger.StopReason?) -> String {
    var out = [reason.map { "stopped: \($0)" } ?? "still running (time limit reached)", registerLine(m)]
    out.append(disassembly(m, from: m.cpu.pc &- 8, count: 6))
    let log = m.debugger.log.suffix(10)
    if !log.isEmpty { out.append("log:"); out += log.map { "  [\($0.ticks)] \($0.text)" } }
    out.append(String(format: "[t=%.6fs, instruction %llu]", m.seconds, m.cpu.instructionCount))
    return out.joined(separator: "\n")
}

func keyCode(_ name: String) throws -> UInt8 {
    let l = name.lowercased()
    if let c = ArcKey.names[l] { return c }
    let aliases: [String: String] = ["esc": "escape", "control": "ctrl", "caps": "capslock", "bs": "backspace", "end": "copy"]
    if let a = aliases[l], let c = ArcKey.names[a] { return c }
    if name.count == 1, let (c, _) = ArcKey.forCharacter(Character(name)) { return c }
    throw ToolError(message: "unknown key \(name)")
}

// MARK: Tools

public struct Tool {
    public let name: String
    public let description: String
    public let schema: [String: Any]
    let run: (AgentSession, [String: Any]) throws -> ToolOutput
}

func schema(_ props: [String: [String: Any]], required: [String] = []) -> [String: Any] {
    ["type": "object", "properties": props, "required": required]
}
func prop(_ type: String, _ description: String) -> [String: Any] { ["type": type, "description": description] }

let resumeProp = prop("boolean", "If the debugger has stopped the machine, carry on from the stop first (default true; breakpoints can stop it again). false leaves it stopped, so time doesn't pass")
let keepDebuggerProp = prop("boolean", "Keep the breakpoints, symbols, trace setting and log (default true)")
let spaceProp = prop("string", "Address space: logical (default: the CPU's view through MEMC), physical (RAM, from 0), rom; memory_regions lists them")

func space(_ a: [String: Any]) throws -> (MEMC.DebugSpace, UInt32) {
    switch str(a, "space")?.lowercased() ?? "logical" {
    case "logical", "cpu": return (.logical, 0)
    case "physical", "ram": return (.physical, 0)
    case "rom": return (.logical, 0x0380_0000)
    case let x: throw ToolError(message: "unknown space \(x); see memory_regions")
    }
}

let allTools: [Tool] = coreTools + debugTools + econetTools

let coreTools: [Tool] = [
    Tool(name: "get_status",
         description: "Machine state: emulated time, model, CPU registers, screen mode, discs in the drives, whether it's waiting for input.",
         schema: schema([:]), run: { s, _ in
             let m = try s.require()
             let c = m.configuration
             var lines = ["model: \(c.model.displayName), \(c.cpu.displayName), \(c.ramKB >= 1024 ? "\(c.ramKB / 1024) MB" : "\(c.ramKB) KB"), \(m.rom.versionString)",
                          String(format: "emulated time: %.3fs", m.seconds), registerLine(m),
                          "screen: \(m.currentFrame.width)x\(m.currentFrame.height), \(m.vidc.bitsPerPixel) bpp"]
             for (i, d) in m.fdc.drives.prefix(2).enumerated() {
                 lines.append("floppy :\(i): " + (d.disc.map { ($0.sourcePath.map { ($0 as NSString).lastPathComponent } ?? "disc") + ($0.isModified ? " (changed)" : "") } ?? "empty"))
             }
             for (i, d) in m.hardDiscImages.enumerated() {
                 lines.append("hard disc :\(i + 4): " + (d.map { ($0.path as NSString).lastPathComponent } ?? "none"))
             }
             lines.append("recording: \(s.isRecording)")
             lines.append("between tool calls: " + (s.runsBetweenCalls ? (s.heldBetweenCalls ? "held still" : "runs in real time") : "only runs during tool calls (headless)"))
             if let r = m.debuggerIfCreated?.stopReason { lines.append("stopped in the debugger: \(r)") }
             return ToolOutput(lines.joined(separator: "\n"))
         }),
    Tool(name: "set_real_time",
         description: "Whether the machine runs in real time between tool calls (in the app, it does to begin with, so people can watch and play). Turn it off to make experiments exact: the machine then moves only during tool calls, so e.g. restore_snapshot then press_keys replays exactly. The app's window shows the machine is held; it's let go when you disconnect. A headless machine only ever runs during tool calls.",
         schema: schema(["on": prop("boolean", "true: run in real time between calls; false: hold still")], required: ["on"]),
         run: { s, a in
             guard s.runsBetweenCalls else { return ToolOutput("this machine is headless: it only runs during tool calls anyway") }
             s.heldBetweenCalls = !(bool(a, "on") ?? true)
             return ToolOutput(s.heldBetweenCalls ? "held still between tool calls" : "running in real time between tool calls")
         }),
    Tool(name: "power_cycle",
         description: "Switch the Archimedes off and on again. Discs stay in the drives. Runs until RISC OS is waiting for input (the desktop). With model, switches machine (breakpoints and symbols are kept): A305, A310, A3000, A410/1, A420/1, A440/1, A540, A5000, A3010, A3020 or A4000; cpu (ARM2, ARM3 or ARM250), ram_kb, rom (a ROM file or folder) hard_discs (images for drives :4 and :5) and monitor (standard, multisync or vga; the A5000 family reads it to pick the desktop's mode) change those. cmos_reset holds Delete so RISC OS resets its CMOS settings.",
         schema: schema(["model": prop("string", "Machine to switch to (default: keep the current one)"),
                         "cpu": ["type": "string", "enum": ["ARM2", "ARM3", "ARM250"], "description": "Processor (default: the model's own)"],
                         "ram_kb": prop("integer", "Memory in KB (default: the model's)"),
                         "rom": prop("string", "RISC OS ROM image or folder of chip files"),
                         "hard_discs": ["type": "array", "items": ["type": "string"], "description": "Hard disc images (.hdf) for :4 and :5 (400 series, A5000, A3020, A4000)"],
                         "monitor": ["type": "string", "enum": MonitorType.allCases.map(\.rawValue), "description": "Monitor (default: keep the current one; standard after a model change)"],
                         "cmos_reset": prop("boolean", "Reset CMOS to RISC OS's defaults (hold Delete at power-on)"),
                         "max_seconds": prop("number", "Longest to wait for the desktop (default 60)")]),
         run: { s, a in
             var change: HardwareChange?
             if a["model"] != nil || a["cpu"] != nil || a["ram_kb"] != nil || a["rom"] != nil || a["hard_discs"] != nil || a["monitor"] != nil || a["cmos_reset"] != nil {
                 var c = HardwareChange()
                 if let n = str(a, "model") {
                     guard let model = MachineModel.allCases.first(where: { $0.rawValue.lowercased() == n.lowercased() || $0.rawValue.lowercased() == n.lowercased() + "/1" }) else {
                         throw ToolError(message: "unknown model \(n); one of " + MachineModel.allCases.map(\.rawValue).joined(separator: ", "))
                     }
                     c.model = model
                 }
                 if let n = str(a, "cpu") {
                     guard let cpu = CPUType(rawValue: n.uppercased()) else { throw ToolError(message: "cpu must be ARM2, ARM3 or ARM250") }
                     c.cpu = cpu
                 }
                 c.ramKB = int(a, "ram_kb")
                 if let r = str(a, "rom") { c.romPath = try checkPath(r) }
                 if let d = a["hard_discs"] as? [String] { c.hardDiscs = try d.map { $0.isEmpty ? nil : try checkPath($0) } }
                 if let n = str(a, "monitor") {
                     guard let mon = MonitorType(rawValue: n.lowercased()) else { throw ToolError(message: "monitor must be standard, multisync or vga") }
                     c.monitor = mon
                 }
                 c.cmosReset = bool(a, "cmos_reset") ?? false
                 change = c
             }
             try s.powerCycle(change)
             let max = num(a, "max_seconds") ?? 60
             let idle = runUntilIdle(s, maxSeconds: max)
             return ToolOutput(summary(s, idle ? "" : "(still starting after \(Int(max))s)"))
         }),
    Tool(name: "press_reset",
         description: "Press the reset button (RISC OS restarts; memory, CMOS and discs are kept). Then runs until it waits for input (up to max_seconds).",
         schema: schema(["max_seconds": prop("number", "Longest to wait for input (default 60)"), "resume": resumeProp]),
         run: { s, a in
             let m = try s.require()
             resumeIfStopped(m, a)
             m.reset()
             s.rewinder.keyframe(m)
             let max = num(a, "max_seconds") ?? 60
             let idle = runUntilIdle(s, maxSeconds: max)
             return ToolOutput(summary(s, idle ? "" : "(still running after \(Int(max))s)"))
         }),
    Tool(name: "load_disc",
         description: "Put a floppy disc image in a drive: ADFS .adf/.adl, or .jfd for protected originals. Returns the disc's catalogue. To start software, use run_command (e.g. \"/:0.$.!Game\") or the mouse on the desktop's :0 icon.",
         schema: schema(["path": prop("string", "The disc image"), "drive": prop("integer", "0 or 1 (default 0)")], required: ["path"]),
         run: { s, a in
             let m = try s.require()
             let path = try checkPath(str(a, "path") ?? "")
             let drive = int(a, "drive") ?? 0
             guard drive == 0 || drive == 1 else { throw ToolError(message: "drive must be 0 or 1") }
             let img = try FloppyImage.open(path: path)
             m.insertFloppy(img, drive: drive)
             s.rewinder.keyframe(m)
             var text = "drive :\(drive): \((path as NSString).lastPathComponent) (\(img.geometry.formatName))"
             if let cat = try? ADFSInspector.inspect(path: path), let d = try? JSONEncoder().encode(cat), let j = String(data: d, encoding: .utf8) {
                 text += "\n" + j
             }
             return ToolOutput(text)
         }),
    Tool(name: "eject_disc",
         description: "Remove the floppy disc from a drive.",
         schema: schema(["drive": prop("integer", "0 or 1 (default 0)")]),
         run: { s, a in
             let m = try s.require()
             let drive = int(a, "drive") ?? 0
             guard drive == 0 || drive == 1 else { throw ToolError(message: "drive must be 0 or 1") }
             m.fdc.drives[drive].disc = nil
             s.rewinder.keyframe(m)
             return ToolOutput("drive \(drive) empty")
         }),
    Tool(name: "run_command",
         description: "Enter a * command or a BASIC line as if typed, then run until RISC OS waits for input again. From the desktop it presses F12 first for the command line. Returns the text RISC OS printed, and the screen. Use \\n in text for several lines; a final Return is added.",
         schema: schema(["text": prop("string", "e.g. *CAT, *BASIC, PRINT 6*7"), "max_seconds": prop("number", "Longest to wait (default 30)"), "resume": resumeProp], required: ["text"]),
         run: { s, a in
             let m = try s.require()
             resumeIfStopped(m, a)
             return ToolOutput(command(s, str(a, "text") ?? "", maxSeconds: num(a, "max_seconds") ?? 30))
         }),
    Tool(name: "type_text",
         description: "Type text through the keyboard, key by key at a realistic speed (40ms per key, Shift as needed). Use for programs that read the keyboard directly; for commands, run_command is faster. \\n is Return. Then runs for settle_seconds.",
         schema: schema(["text": prop("string", "What to type"), "settle_seconds": prop("number", "Run this long afterwards (default 0.5)"), "resume": resumeProp], required: ["text"]),
         run: { s, a in
             let m = try s.require()
             resumeIfStopped(m, a)
             m.scheduleTyping(str(a, "text") ?? "", intervalMs: 40)
             s.advance(until: { m.pendingInputEvents == 0 }, maxSeconds: 600)
             s.advance(seconds: num(a, "settle_seconds") ?? 0.5)
             return ToolOutput(summary(s))
         }),
    Tool(name: "mouse",
         description: "Use the mouse (three buttons: select, menu and adjust). Move it by dx, dy counts, or to x, y (pixels on the screen, as in screenshot before scaling) by following the pointer; then click (or double_click), or hold buttons.",
         schema: schema(["dx": prop("integer", "Counts right (negative: left)"), "dy": prop("integer", "Counts up (negative: down)"),
                         "x": prop("integer", "Move the pointer's hot spot to this column of the screen"),
                         "y": prop("integer", "…and this row (from the top)"),
                         "buttons": ["type": "array", "items": ["type": "string", "enum": ["select", "menu", "adjust"]], "description": "Buttons to hold down after moving (default: as they were)"],
                         "click": ["type": "string", "enum": ["select", "menu", "adjust"], "description": "Click a button after moving"],
                         "double_click": prop("boolean", "With click, click it twice"),
                         "settle_seconds": prop("number", "Run this long afterwards (default 0.3)"), "resume": resumeProp]),
         run: { s, a in
             let m = try s.require()
             resumeIfStopped(m, a)
             var note = ""
             if let x = int(a, "x"), let y = int(a, "y") {
                 // Steer by the hardware pointer's tip: RISC OS's scaling varies by mode.
                 for _ in 0..<40 {
                     let p = m.vidc.pointerHotspot
                     let ex = x - p.x, ey = y - p.y
                     if abs(ex) <= 1 && abs(ey) <= 1 { break }
                     m.mouseMove(dx: max(-60, min(60, ex)), dy: max(-60, min(60, -ey)))
                     s.advance(seconds: 0.04)
                 }
             } else if let dx = int(a, "dx"), let dy = int(a, "dy") {
                 var rx = dx, ry = dy
                 while rx != 0 || ry != 0 {
                     let sx = max(-60, min(60, rx)), sy = max(-60, min(60, ry))
                     m.mouseMove(dx: sx, dy: sy); rx -= sx; ry -= sy
                     s.advance(seconds: 0.02)
                 }
             }
             s.advance(seconds: 0.1)
             let codes: [String: UInt8] = ["select": 0x70, "menu": 0x71, "adjust": 0x72]
             if let held = a["buttons"] as? [String] {
                 for (n, c) in codes { if held.contains(n) { m.keyDown(c) } else { m.keyUp(c) } }
             }
             if let b = str(a, "click"), let c = codes[b] {
                 for _ in 0..<(bool(a, "double_click") == true ? 2 : 1) {
                     m.keyDown(c); s.advance(seconds: 0.04); m.keyUp(c); s.advance(seconds: 0.04)
                 }
             }
             s.advance(seconds: num(a, "settle_seconds") ?? 0.3)
             let p = m.vidc.pointerHotspot
             note += (note.isEmpty ? "" : " ") + "pointer at \(p.x), \(p.y)"
             return ToolOutput(summary(s, note))
         }),
    Tool(name: "press_keys",
         description: "Hold keys down together, then release: e.g. [\"CTRL\",\"F12\"], [\"SHIFT\",\"F1\"], [\"ESCAPE\"]. Names: RETURN SPACE SHIFT CTRL ALT ESCAPE TAB BACKSPACE DELETE INSERT HOME COPY PAGEUP PAGEDOWN CAPSLOCK UP DOWN LEFT RIGHT F1-F12 PRINT SCROLLLOCK BREAK, keypad KP0-KP9 KP+ KP- KP* KP/ KP. ENTER, or a single character.",
         schema: schema(["keys": ["type": "array", "items": ["type": "string"], "description": "Key names"],
                         "hold_seconds": prop("number", "How long to hold them (default 0.1)"),
                         "settle_seconds": prop("number", "Run this long afterwards (default 0.2)"), "resume": resumeProp], required: ["keys"]),
         run: { s, a in
             let m = try s.require()
             resumeIfStopped(m, a)
             let codes = try (a["keys"] as? [String] ?? []).map(keyCode)
             for c in codes { m.keyDown(c); s.advance(seconds: 0.01) }
             s.advance(seconds: num(a, "hold_seconds") ?? 0.1)
             for c in codes.reversed() { m.keyUp(c); s.advance(seconds: 0.01) }
             s.advance(seconds: num(a, "settle_seconds") ?? 0.2)
             return ToolOutput(summary(s))
         }),
    Tool(name: "run",
         description: "Run the machine for some emulated time (seconds, or frames at 50 per second). Runs faster than real time.",
         schema: schema(["seconds": prop("number", "How long (default 1)"), "frames": prop("integer", "Or: this many frames"), "resume": resumeProp]),
         run: { s, a in
             let m = try s.require()
             resumeIfStopped(m, a)
             let seconds = int(a, "frames").map { Double($0) / 50 } ?? (num(a, "seconds") ?? 1)
             guard seconds >= 0 && seconds <= 3600 else { throw ToolError(message: "seconds must be 0-3600") }
             s.advance(until: { false }, maxSeconds: seconds)
             return ToolOutput(summary(s))
         }),
    Tool(name: "run_until_idle",
         description: "Run until RISC OS is waiting for input (at a prompt, in the desktop with nothing to do, or a program polling the keyboard), or max_seconds pass.",
         schema: schema(["max_seconds": prop("number", "Longest to wait (default 30)"), "resume": resumeProp]),
         run: { s, a in
             let m = try s.require()
             resumeIfStopped(m, a)
             let max = num(a, "max_seconds") ?? 30
             return ToolOutput(summary(s, runUntilIdle(s, maxSeconds: max) ? "waiting for input" : "still running after \(Int(max))s"))
         }),
    Tool(name: "run_until_address",
         description: "Run until the CPU is about to execute the instruction at an address (e.g. \"&8000\"), or max_seconds pass.",
         schema: schema(["address": prop("string", "Address: &8000, $8000, 0x8000, decimal, or an expression"), "max_seconds": prop("number", "Longest (default 30)"), "resume": resumeProp], required: ["address"]),
         run: { s, a in
             let m = try s.require()
             resumeIfStopped(m, a)
             guard let target = try address(a, "address", m) else { throw ToolError(message: "address is required") }
             let max = num(a, "max_seconds") ?? 30
             let r = m.debugger.run(.runToAddress(target), maxTicks: UInt64(max * 24_000_000)) { s.advance(ticks: $0) }
             if r == .stepped { m.debugger.resume() }
             return ToolOutput(summary(s, r == .stepped ? "reached \(hex(target))" : (r.map { "\($0)" } ?? "didn't reach \(hex(target)) in \(Int(max))s")))
         }),
    Tool(name: "screenshot",
         description: "The screen as a PNG image (VIDC's display and border at the mode's pixels, scaled to the monitor's aspect).",
         schema: schema([:]), run: { s, _ in
             let m = try s.require()
             let f = m.currentFrame
             guard f.width > 1 else { throw ToolError(message: "no frame yet") }
             // The mouse tool's x, y are frame pixels: divide image positions by the scale.
             return ToolOutput("\(f.width)x\(f.height) pixels, shown scaled by \(f.scaleX) across and \(f.scaleY) down", png: PNGEncoder.encode(f, scaleX: f.scaleX, scaleY: f.scaleY))
         }),
    Tool(name: "read_screen_text",
         description: "The text on the screen, matched against RISC OS's system font (works wherever text is on the character grid: the command line, BASIC, F12; ? marks cells that aren't characters, such as desktop graphics).",
         schema: schema([:]), run: { s, _ in ToolOutput(try s.require().screenText.joined(separator: "\n")) }),
    Tool(name: "save_snapshot",
         description: "Remember the machine's exact state under a name (in memory), to come back to with restore_snapshot. Restoring continues exactly: good for trying things.",
         schema: schema(["name": prop("string", "Name (default \"default\")")]),
         run: { s, a in
             let m = try s.require()
             let name = str(a, "name") ?? "default"
             AgentTools.slots[name] = m.snapshot(createdBy: "macarch-mcp")
             return ToolOutput(String(format: "saved snapshot \"%@\" at t=%.2fs", name, m.seconds))
         }),
    Tool(name: "restore_snapshot",
         description: "Go back to a snapshot taken with save_snapshot (machine, memory and floppies). The debugger's breakpoints and symbols stay as they are. In the app, the machine runs on in real time between tool calls unless set_real_time has turned that off: do so for an exact replay.",
         schema: schema(["name": prop("string", "Name (default \"default\")"), "keep_debugger": keepDebuggerProp]),
         run: { s, a in
             let m = try s.require()
             let name = str(a, "name") ?? "default"
             guard let data = AgentTools.slots[name] else { throw ToolError(message: "no snapshot named \(name)") }
             let discs = m.fdc.drives.map(\.disc)
             let n = try Machine.restore(snapshot: data, rom: m.rom, resolveDisc: { d in discs[d.drive].flatMap { $0.sha256 == d.sha256 ? $0 : nil } ?? Machine.reopenDisc(d) }, hardDiscs: m.hardDiscImages)
             if bool(a, "keep_debugger") != false, let d = m.debuggerIfCreated { n.debugger.adopt(d) }
             s.rewinder.reset() // a different timeline
             s.replace(with: n)
             return ToolOutput(summary(s, "restored \"\(name)\""))
         }),
    Tool(name: "save_state",
         description: "Save the machine's exact state to a .macarchstate file (floppies and hard discs are referenced by path; a floppy's unsaved changes are included).",
         schema: schema(["path": prop("string", "Output path")], required: ["path"]),
         run: { s, a in
             let m = try s.require()
             let path = try checkPath(str(a, "path") ?? "")
             let data = m.snapshot(createdBy: "macarch-mcp")
             try Data(data).write(to: URL(fileURLWithPath: path))
             return ToolOutput("saved \(data.count) bytes to \(path)")
         }),
    Tool(name: "load_state",
         description: "Load a .macarchstate file, replacing the machine. The debugger's breakpoints and symbols stay as they are.",
         schema: schema(["path": prop("string", "The state file"), "keep_debugger": keepDebuggerProp], required: ["path"]),
         run: { s, a in
             let m = try s.require()
             let path = try checkPath(str(a, "path") ?? "")
             guard let data = FileManager.default.contents(atPath: path) else { throw ToolError(message: "can't read \(path)") }
             let header = try Snapshot.header(of: [UInt8](data))
             let n = try Machine.restore(snapshot: [UInt8](data), rom: m.rom) { media in
                 guard let p = media.path, (try? checkPath(p)) != nil else { return nil }
                 return Machine.reopenDisc(media)
             }
             if bool(a, "keep_debugger") != false, let d = m.debuggerIfCreated { n.debugger.adopt(d) }
             s.rewinder.reset()
             s.replace(with: n)
             return ToolOutput(summary(s, "loaded state saved by \(header.createdBy)"))
         }),
    Tool(name: "start_recording",
         description: "Start recording video and sound to a movie file (.mp4 is H.264; .mov is ProRes). Time is emulated time, so recordings play at the right speed even though emulation runs faster.",
         schema: schema(["path": prop("string", "Output path")], required: ["path"]),
         run: { s, a in
             let path = try checkPath(str(a, "path") ?? "")
             try s.startRecording(to: URL(fileURLWithPath: path))
             return ToolOutput("recording to \(path)")
         }),
    Tool(name: "stop_recording",
         description: "Stop recording and finish the movie file.",
         schema: schema([:]), run: { s, _ in ToolOutput(s.stopRecording() ? "recording finished" : "not recording") }),
]
