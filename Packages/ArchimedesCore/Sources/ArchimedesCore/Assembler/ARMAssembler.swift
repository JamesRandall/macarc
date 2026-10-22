import Foundation

/// An assembler for ARM2, ARM3 and ARM250 code, so programs can be
/// written and debugged on MacArch (VS Code's launch with `source`, the
/// MCP `assemble` tool, `macarch-cli assemble`). The syntax is BBC BASIC
/// V's assembler as a file of its own, with some ObjAsm spellings:
///
///             ORG &8000               ; where it loads (the default)
///     .start  ADR R0, message         ; labels: .name, name:, or a name in column 1
///             SWI "OS_Write0"         ; or SWI OS_Write0, SWI XOS_Write0, SWI &02
///             SWI OS_NewLine
///             SWI OS_Exit
///     .message
///             EQUS "Hello, world!"
///             EQUB 0
///             ALIGN
///
/// Instructions: everything the ARM2 has (data processing with S, and P
/// for TSTP and the like; MUL, MLA; LDR/STR with B and T and every
/// addressing mode, `LDR R0, =value` from a literal pool, `LDR R0, label`;
/// LDM/STM with IA IB DA DB FD ED FA EA, ! and ^; B, BL; SWI by name or
/// number; CDP, MRC, MCR, LDC, STC), SWP (ARM3 and ARM250), and ADR,
/// ADRL and NOP. Conditions go before or after the suffixes (ADDEQS or
/// ADDSEQ). An immediate that doesn't fit is tried the other way round
/// (MOV R0, #-1 becomes MVN R0, #0). Registers: R0-R15, PC, LR, SP, the
/// APCS names (a1-a4, v1-v6, sl, fp, ip), and `name RN 5`.
///
/// Directives: ORG, ENTRY (start here rather than at the first byte),
/// ALIGN [n], EQUB/DCB, EQUW/DCW, EQUD/DCD, EQUS/DCS (bytes, words and
/// strings, comma separated), SKIP/SPACE n, LTORG (place the literal pool;
/// otherwise it goes at the end), INCLUDE "file", INCBIN "file", END;
/// and constants: `name EQU value`, `name * value` or `name = value`.
/// Expressions are the debugger's (&hex, $hex, 0x, %binary, 'c', the C
/// operators), with labels, constants, SWI names, and `.` for the address
/// of the current statement. Comments start with ; \ or //.
public enum ARMAssembler {
    public struct Diagnostic: Sendable, CustomStringConvertible {
        public let location: SourceLocation
        public let message: String
        public var description: String { "\(location): \(message)" }
    }

    /// What went wrong: every error found, with its line.
    public struct Failure: Error, CustomStringConvertible {
        public let diagnostics: [Diagnostic]
        public var description: String { diagnostics.map(\.description).joined(separator: "\n") }
    }

    public struct Assembly: Sendable {
        /// Where the code loads.
        public let origin: UInt32
        public let bytes: [UInt8]
        /// Where it starts: ENTRY, or the origin.
        public let entry: UInt32
        /// The labels, and the source line of every instruction.
        public let symbols: SymbolTable
        public let warnings: [Diagnostic]
        public var end: UInt32 { origin &+ UInt32(bytes.count) }

        /// A program built some other way: its bytes, where they load and start.
        public init(origin: UInt32, bytes: [UInt8], entry: UInt32, symbols: SymbolTable = SymbolTable(), warnings: [Diagnostic] = []) {
            self.origin = origin; self.bytes = bytes; self.entry = entry; self.symbols = symbols; self.warnings = warnings
        }
    }

    /// Assembles a file (and the files it includes).
    public static func assemble(file path: String) throws -> Assembly {
        var statements: [Statement] = []
        var problems: [Diagnostic] = []
        load(absolute(path), from: nil, into: &statements, problems: &problems, depth: 0)
        return try assemble(statements, problems)
    }

    /// Assembles source text; INCLUDEs are found beside `file`.
    public static func assemble(source: String, file: String = "source.s") throws -> Assembly {
        var statements: [Statement] = []
        var problems: [Diagnostic] = []
        expand(source, file: absolute(file), into: &statements, problems: &problems, depth: 0)
        return try assemble(statements, problems)
    }

    // MARK: Reading the source

    struct Statement {
        let location: SourceLocation
        var label: String?
        /// The mnemonic or directive, upper case.
        var op: String?
        var operands: String = ""
        /// INCBIN's bytes.
        var data: [UInt8] = []
    }

    static func absolute(_ path: String) -> String {
        let p = (path as NSString).expandingTildeInPath
        let full = p.hasPrefix("/") ? p : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(p)
        return (full as NSString).standardizingPath
    }

    static func load(_ path: String, from: SourceLocation?, into statements: inout [Statement], problems: inout [Diagnostic], depth: Int) {
        guard let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? (try? String(contentsOfFile: path, encoding: .isoLatin1)) else {
            problems.append(Diagnostic(location: from ?? SourceLocation(file: path, line: 0), message: "can't read \(path)"))
            return
        }
        expand(text, file: path, into: &statements, problems: &problems, depth: depth)
    }

    /// Parses the lines, following INCLUDEs. Lines that can't be parsed
    /// become problems, and assembly carries on to find the others.
    static func expand(_ text: String, file: String, into statements: inout [Statement], problems: inout [Diagnostic], depth: Int) {
        let directory = (file as NSString).deletingLastPathComponent
        for (i, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let location = SourceLocation(file: file, line: i + 1)
            do {
                var s = try parse(String(raw), at: location)
                switch s.op {
                case "INCLUDE", "GET":
                    guard depth < 16 else { throw message("INCLUDEs nest too deeply") }
                    let name = try quoted(s.operands)
                    load(name.hasPrefix("/") ? name : (directory as NSString).appendingPathComponent(name), from: location, into: &statements, problems: &problems, depth: depth + 1)
                    if let label = s.label { statements.append(Statement(location: location, label: label)) }
                    continue
                case "INCBIN", "BIN":
                    let name = try quoted(s.operands)
                    let path = name.hasPrefix("/") ? name : (directory as NSString).appendingPathComponent(name)
                    guard let d = FileManager.default.contents(atPath: path) else { throw message("can't read \(path)") }
                    s.data = [UInt8](d)
                default: break
                }
                statements.append(s)
            } catch {
                problems.append(Diagnostic(location: location, message: "\(error)"))
                // Keep the addresses after it right, if it was meant to be an instruction.
                statements.append(Statement(location: location, op: "NOP"))
            }
        }
    }

    struct Message: Error, CustomStringConvertible { let description: String }
    static func message(_ s: String) -> Message { Message(description: s) }

    static let directives: Set<String> = [
        "ORG", "ENTRY", "ALIGN", "EQUB", "DCB", "EQUW", "DCW", "EQUD", "DCD", "EQUS", "DCS", "SKIP", "SPACE",
        "LTORG", "INCLUDE", "GET", "INCBIN", "BIN", "END", "EQU", "RN",
    ]

    static func isOpcode(_ word: String) -> Bool {
        directives.contains(word.uppercased()) || mnemonic(word) != nil
    }

    /// The text before any comment.
    static func stripComment(_ s: String) -> String {
        let c = Array(s)
        var i = 0
        var quote = false
        while i < c.count {
            let ch = c[i]
            if quote {
                if ch == "\\" { i += 2; continue }
                if ch == "\"" { quote = false }
            } else if ch == "\"" {
                quote = true
            } else if ch == "'" && i + 2 < c.count && c[i + 2] == "'" {
                i += 3; continue
            } else if ch == ";" || ch == "\\" || (ch == "/" && i + 1 < c.count && c[i + 1] == "/") {
                return String(c[..<i])
            }
            i += 1
        }
        return s
    }

    static func isNameStart(_ c: Character) -> Bool { c.isLetter || c == "_" }
    static func isNameChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

    static func parse(_ raw: String, at location: SourceLocation) throws -> Statement {
        let text = stripComment(raw)
        var s = Statement(location: location)
        var rest = Substring(text)
        let column1 = !(text.first.map { $0.isWhitespace } ?? true)
        rest = rest.drop { $0.isWhitespace }
        if rest.isEmpty { return s }

        func word(_ t: Substring) -> (Substring, Substring) {
            let w = t.prefix { !$0.isWhitespace }
            return (w, t.dropFirst(w.count).drop { $0.isWhitespace })
        }

        // name EQU value, name * value, name = value, name RN 3.
        let name = rest.prefix(while: isNameChar)
        if let f = name.first, isNameStart(f) {
            let after = rest.dropFirst(name.count).drop { $0.isWhitespace }
            let (w, value) = word(after)
            if ["EQU", "RN"].contains(w.uppercased()) {
                s.label = String(name); s.op = w.uppercased(); s.operands = String(value).trimmingCharacters(in: .whitespaces)
                return s
            }
            if let op = after.first, op == "=" || op == "*", !after.hasPrefix("==") {
                s.label = String(name); s.op = "EQU"; s.operands = after.dropFirst().trimmingCharacters(in: .whitespaces)
                return s
            }
        }

        // Labels: .name, name:, or a name in column 1.
        if rest.hasPrefix(".") {
            let n = rest.dropFirst().prefix(while: isNameChar)
            guard let f = n.first, isNameStart(f) else { throw message("bad label") }
            s.label = String(n)
            rest = rest.dropFirst(1 + n.count).drop { $0.isWhitespace || $0 == ":" }
        } else {
            let (w, after) = word(rest)
            if w.hasSuffix(":"), let f = w.first, isNameStart(f), w.dropLast().allSatisfy(isNameChar) {
                s.label = String(w.dropLast())
                rest = after
            } else if column1, let f = w.first, isNameStart(f), w.allSatisfy(isNameChar), !isOpcode(String(w)) {
                s.label = String(w)
                rest = after
            }
        }
        if rest.isEmpty { return s }
        let (op, operands) = word(rest)
        s.op = op.uppercased()
        s.operands = operands.trimmingCharacters(in: .whitespaces)
        guard isOpcode(s.op!) else { throw message("unknown instruction \(op)") }
        return s
    }

    /// Operands split at top-level commas (not inside brackets, braces or quotes).
    static func split(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote = false
        let c = Array(s)
        var i = 0
        while i < c.count {
            let ch = c[i]
            if quote {
                current.append(ch)
                if ch == "\\" && i + 1 < c.count { current.append(c[i + 1]); i += 2; continue }
                if ch == "\"" { quote = false }
            } else if ch == "'" && i + 2 < c.count && c[i + 2] == "'" {
                current += String(c[i...(i + 2)]); i += 3; continue
            } else {
                switch ch {
                case "\"": quote = true; current.append(ch)
                case "[", "{", "(": depth += 1; current.append(ch)
                case "]", "}", ")": depth -= 1; current.append(ch)
                case "," where depth == 0:
                    parts.append(current.trimmingCharacters(in: .whitespaces)); current = ""
                default: current.append(ch)
                }
            }
            i += 1
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty || !parts.isEmpty { parts.append(last) }
        return parts
    }

    /// The contents of a "quoted string", with \n \r \t \0 \\ \" escapes
    /// (and "" for a quote, as BASIC has it).
    static func quoted(_ s: String) throws -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") else { throw message("expected a \"string\"") }
        let c = Array(t.dropFirst().dropLast())
        var out = ""
        var i = 0
        while i < c.count {
            if c[i] == "\\" && i + 1 < c.count {
                switch c[i + 1] {
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "0": out.append("\0")
                default: out.append(c[i + 1])
                }
                i += 2; continue
            }
            if c[i] == "\"" && i + 1 < c.count && c[i + 1] == "\"" { out.append("\""); i += 2; continue }
            out.append(c[i]); i += 1
        }
        return out
    }

    // MARK: Mnemonics

    static let conditions: [String: UInt32] = [
        "EQ": 0, "NE": 1, "CS": 2, "HS": 2, "CC": 3, "LO": 3, "MI": 4, "PL": 5, "VS": 6, "VC": 7,
        "HI": 8, "LS": 9, "GE": 10, "LT": 11, "GT": 12, "LE": 13, "AL": 14, "NV": 15,
    ]

    static let dataOps: [String: UInt32] = [
        "AND": 0, "EOR": 1, "SUB": 2, "RSB": 3, "ADD": 4, "ADC": 5, "SBC": 6, "RSC": 7,
        "TST": 8, "TEQ": 9, "CMP": 10, "CMN": 11, "ORR": 12, "MOV": 13, "BIC": 14, "MVN": 15,
    ]

    /// Longest first where one is a prefix of another (ADRL, ADR; BL, B).
    static let bases = ["ADRL", "ADR", "AND", "EOR", "SUB", "RSB", "ADD", "ADC", "SBC", "RSC", "TST", "TEQ", "CMP", "CMN",
                        "ORR", "MOV", "BIC", "MVN", "MUL", "MLA", "LDR", "STR", "LDM", "STM", "SWI", "SVC", "SWP",
                        "MRC", "MCR", "CDP", "LDC", "STC", "NOP", "BL", "B"]

    struct Mnemonic: Equatable {
        let base: String
        let condition: UInt32
        let flags: String
    }

    static let stackModes: Set<String> = ["IA", "IB", "DA", "DB", "FD", "ED", "FA", "EA"]

    static func validFlags(_ base: String, _ f: String) -> Bool {
        switch base {
        case "TST", "TEQ", "CMP", "CMN": return f == "" || f == "P" || f == "S"
        case "LDR", "STR": return ["", "B", "T", "BT", "TB"].contains(f)
        case "LDM", "STM": return f == "" || stackModes.contains(f)
        case "SWP": return f == "" || f == "B"
        case "LDC", "STC": return f == "" || f == "L"
        case "MUL", "MLA": return f == "" || f == "S"
        default: return dataOps[base] != nil ? (f == "" || f == "S") : f == ""
        }
    }

    static func mnemonic(_ word: String) -> Mnemonic? {
        let u = word.uppercased()
        for base in bases where u.hasPrefix(base) {
            let r = String(u.dropFirst(base.count))
            if validFlags(base, r) { return Mnemonic(base: base, condition: 14, flags: r) }
            if r.count >= 2 {
                if let c = conditions[String(r.prefix(2))], validFlags(base, String(r.dropFirst(2))) {
                    return Mnemonic(base: base, condition: c, flags: String(r.dropFirst(2)))
                }
                if let c = conditions[String(r.suffix(2))], validFlags(base, String(r.dropLast(2))) {
                    return Mnemonic(base: base, condition: c, flags: String(r.dropLast(2)))
                }
            }
        }
        return nil
    }

    /// The 12-bit operand for an immediate, if it is an 8-bit value rotated
    /// right by an even amount.
    public static func immediate(_ v: UInt32) -> UInt32? {
        for rotation in stride(from: 0, to: 32, by: 2) {
            let imm = rotation == 0 ? v : (v << UInt32(rotation)) | (v >> UInt32(32 - rotation))
            if imm <= 0xFF { return UInt32(rotation / 2) << 8 | imm }
        }
        return nil
    }

    static let standardRegisters: [String: UInt32] = {
        var t: [String: UInt32] = ["PC": 15, "LR": 14, "SP": 13, "SL": 10, "FP": 11, "IP": 12, "SB": 9]
        for i in 0...15 { t["R\(i)"] = UInt32(i) }
        for i in 1...4 { t["A\(i)"] = UInt32(i - 1) }
        for i in 1...6 { t["V\(i)"] = UInt32(i + 3) }
        return t
    }()

    // MARK: Assembling

    /// Decisions the first pass makes that the second must keep, so
    /// addresses don't move: whether `LDR Rd, =value` became a MOV.
    final class Shared {
        var literalIsMove: [Int: Bool] = [:]
    }

    static func assemble(_ statements: [Statement], _ problems: [Diagnostic]) throws -> Assembly {
        let shared = Shared()
        let first = Pass(final: false, previous: [:], shared: shared)
        first.run(statements)
        let second = Pass(final: true, previous: first.symbols, shared: shared)
        second.run(statements)
        let errors = (problems + second.errors).sorted { ($0.location.file, $0.location.line) < ($1.location.file, $1.location.line) }
        if !errors.isEmpty { throw Failure(diagnostics: Array(errors.prefix(100))) }
        var table = SymbolTable()
        for (name, value) in second.labels { table.add(name, value) }
        for (a, l) in second.lineMap { table.addLine(a, l) }
        return Assembly(origin: second.origin, bytes: second.bytes, entry: second.entry ?? second.origin,
                        symbols: table, warnings: second.warnings)
    }

    final class Pass {
        let final: Bool
        let previous: [String: Int]
        let shared: Shared
        var symbols: [String: Int] = [:]
        var labels: [String: UInt32] = [:]
        var aliases: [String: UInt32] = [:]
        var origin: UInt32 = 0x8000
        var pc: UInt32 = 0x8000
        var bytes: [UInt8] = []
        var entry: UInt32?
        var lineMap: [(UInt32, SourceLocation)] = []
        var errors: [Diagnostic] = []
        var warnings: [Diagnostic] = []
        /// Literals waiting for LTORG or the end: where the LDR is, and the value.
        var literals: [(offset: Int, address: UInt32, value: UInt32, location: SourceLocation)] = []
        /// The current statement: its address, and whether an expression
        /// used something not defined yet (first pass only).
        var here: UInt32 = 0
        var unresolved = false
        var location = SourceLocation(file: "", line: 0)

        init(final: Bool, previous: [String: Int], shared: Shared) {
            self.final = final
            self.previous = previous
            self.shared = shared
        }

        func run(_ statements: [Statement]) {
            for (index, s) in statements.enumerated() {
                location = s.location
                here = pc
                unresolved = false
                let start = bytes.count
                do {
                    if try statement(s, index) { break }
                } catch {
                    if final { errors.append(Diagnostic(location: s.location, message: "\(error)")) }
                    // Keep addresses where they'd be: an instruction is a word.
                    if let op = s.op, ARMAssembler.mnemonic(op) != nil, bytes.count == start {
                        emit(0)
                    }
                }
            }
            location = statements.last?.location ?? location
            do { try flushLiterals() } catch { if final { errors.append(Diagnostic(location: location, message: "\(error)")) } }
        }

        func warn(_ text: String) {
            if final { warnings.append(Diagnostic(location: location, message: text)) }
        }

        // MARK: Output

        func emit(_ w: UInt32) {
            lineMap.append((pc, location))
            bytes += [UInt8(w & 0xFF), UInt8((w >> 8) & 0xFF), UInt8((w >> 16) & 0xFF), UInt8(w >> 24)]
            pc &+= 4
        }

        func emitBytes(_ b: [UInt8]) {
            bytes += b
            pc &+= UInt32(b.count)
        }

        func patch(_ offset: Int, _ w: UInt32) {
            bytes[offset] = UInt8(w & 0xFF); bytes[offset + 1] = UInt8((w >> 8) & 0xFF)
            bytes[offset + 2] = UInt8((w >> 16) & 0xFF); bytes[offset + 3] = UInt8(w >> 24)
        }

        func flushLiterals() throws {
            for l in literals {
                let address = pc
                emitBytes([UInt8(l.value & 0xFF), UInt8((l.value >> 8) & 0xFF), UInt8((l.value >> 16) & 0xFF), UInt8(l.value >> 24)])
                let offset = Int64(address) - Int64(l.address) - 8
                guard (-4095...4095).contains(offset) else {
                    if final { errors.append(Diagnostic(location: l.location, message: "the literal pool is too far away (put an LTORG nearer)")) }
                    continue
                }
                var w = UInt32(bytes[l.offset]) | UInt32(bytes[l.offset + 1]) << 8 | UInt32(bytes[l.offset + 2]) << 16 | UInt32(bytes[l.offset + 3]) << 24
                if offset < 0 { w &= ~0x0080_0000 }
                patch(l.offset, w | UInt32(abs(offset)))
            }
            literals.removeAll()
        }

        // MARK: Expressions

        struct Context: DebugExpression.Context {
            unowned let pass: Pass
            func register(_ name: String) -> Int? { nil }
            func readByte(_ address: UInt32) -> UInt8 { 0 }
            func readWord(_ address: UInt32) -> UInt32 { 0 }
            func symbol(_ name: String) -> Int? {
                if name == "." { return Int(pass.here) }
                let n = name.hasPrefix(".") ? String(name.dropFirst()) : name
                if let v = pass.symbols[n] { return v }
                // Defined further on (in the first pass, it's in the second).
                if let v = pass.previous[n] { return v }
                if let v = SWINames.numbers[n] { return Int(v) }
                if !pass.final { pass.unresolved = true; return 0 }
                return nil
            }
        }

        func value(_ text: String) throws -> Int {
            let t = text.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { throw ARMAssembler.message("missing value") }
            let e = try DebugExpression(t)
            return try e.evaluate(Context(pass: self))
        }

        func word(_ text: String) throws -> UInt32 { UInt32(truncatingIfNeeded: try value(text)) }

        /// A value that decides how much space something takes, so must be known now.
        func size(_ text: String) throws -> Int {
            let v = try value(text)
            if unresolved { throw ARMAssembler.message("\(text) must be defined before it's used here") }
            return v
        }

        func define(_ name: String, _ v: Int) throws {
            if symbols[name] != nil { throw ARMAssembler.message("\(name) is defined twice") }
            if aliases[name.uppercased()] != nil || ARMAssembler.standardRegisters[name.uppercased()] != nil {
                throw ARMAssembler.message("\(name) is a register name")
            }
            symbols[name] = v
        }

        // MARK: Registers

        func register(_ text: String) throws -> UInt32 {
            let t = text.trimmingCharacters(in: .whitespaces).uppercased()
            if let r = ARMAssembler.standardRegisters[t] ?? aliases[t] { return r }
            throw ARMAssembler.message("expected a register, not \(text)")
        }

        func isRegister(_ text: String) -> Bool { (try? register(text)) != nil }

        /// p15, CP15 or 15.
        func coprocessor(_ text: String) throws -> UInt32 {
            var t = text.trimmingCharacters(in: .whitespaces).uppercased()
            if t.hasPrefix("CP") { t.removeFirst(2) } else if t.hasPrefix("P") { t.removeFirst() }
            guard let n = UInt32(t), n < 16 else { throw ARMAssembler.message("expected a coprocessor (p0-p15), not \(text)") }
            return n
        }

        /// c3, CR3 or 3.
        func coprocessorRegister(_ text: String) throws -> UInt32 {
            var t = text.trimmingCharacters(in: .whitespaces).uppercased()
            if t.hasPrefix("CR") { t.removeFirst(2) } else if t.hasPrefix("C") { t.removeFirst() }
            guard let n = UInt32(t), n < 16 else { throw ARMAssembler.message("expected a coprocessor register (c0-c15), not \(text)") }
            return n
        }

        func field(_ text: String, max: Int, _ what: String) throws -> UInt32 {
            let v = try value(text)
            guard (0...max).contains(v) else { throw ARMAssembler.message("\(what) must be 0-\(max)") }
            return UInt32(v)
        }

        // MARK: Statements

        /// Returns true at END.
        func statement(_ s: Statement, _ index: Int) throws -> Bool {
            let op = s.op ?? ""
            if let label = s.label, op != "EQU", op != "RN" {
                try define(label, Int(pc))
                labels[label] = pc
                if final, let old = previous[label], old != Int(pc) {
                    throw ARMAssembler.message("\(label) moved between passes (a size depends on something defined later)")
                }
            }
            guard s.op != nil else { return false }
            let operands = ARMAssembler.split(s.operands)
            switch op {
            case "EQU":
                let v = try value(s.operands)
                try define(s.label!, v)
            case "RN":
                aliases[s.label!.uppercased()] = try register(s.operands)
            case "ORG":
                let v = UInt32(truncatingIfNeeded: try size(s.operands))
                if bytes.isEmpty {
                    origin = v; pc = v
                } else if v >= pc {
                    emitBytes([UInt8](repeating: 0, count: Int(v - pc)))
                } else {
                    throw ARMAssembler.message("ORG can't go backwards once code is assembled")
                }
            case "ENTRY":
                entry = pc
            case "END":
                return true
            case "LTORG":
                try flushLiterals()
            case "ALIGN":
                let n = s.operands.isEmpty ? 4 : try size(s.operands)
                guard n > 0, n & (n - 1) == 0 else { throw ARMAssembler.message("ALIGN needs a power of two") }
                let pad = (n - Int(pc % UInt32(n))) % n
                emitBytes([UInt8](repeating: 0, count: pad))
            case "SKIP", "SPACE":
                guard let count = operands.first else { throw ARMAssembler.message("SKIP needs a size") }
                let n = try size(count)
                guard (0...0x100_0000).contains(n) else { throw ARMAssembler.message("SKIP size out of range") }
                let fill = operands.count > 1 ? UInt8(truncatingIfNeeded: try value(operands[1])) : 0
                emitBytes([UInt8](repeating: fill, count: n))
            case "INCBIN", "BIN":
                lineMap.append((pc, location))
                emitBytes(s.data)
            case "EQUB", "DCB", "EQUS", "DCS":
                lineMap.append((pc, location))
                for item in operands {
                    if item.hasPrefix("\"") {
                        emitBytes(Array(try ARMAssembler.quoted(item).utf8))
                    } else {
                        let v = try value(item)
                        if final, !(-128...255).contains(v) { warn("\(item) doesn't fit in a byte") }
                        emitBytes([UInt8(truncatingIfNeeded: v)])
                    }
                }
            case "EQUW", "DCW":
                lineMap.append((pc, location))
                for item in operands {
                    let v = try value(item)
                    if final, !(-32768...65535).contains(v) { warn("\(item) doesn't fit in 16 bits") }
                    emitBytes([UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)])
                }
            case "EQUD", "DCD":
                lineMap.append((pc, location))
                if pc & 3 != 0 { warn("EQUD at an address that isn't a multiple of 4 (use ALIGN)") }
                for item in operands {
                    let v = try word(item)
                    emitBytes([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
                }
            default:
                guard let m = ARMAssembler.mnemonic(op) else { throw ARMAssembler.message("unknown instruction \(op)") }
                if pc & 3 != 0 { throw ARMAssembler.message("instructions must be word aligned (use ALIGN after strings)") }
                try instruction(m, operands, index)
            }
            return false
        }

        func expect(_ operands: [String], _ counts: ClosedRange<Int>, _ form: String) throws {
            guard counts.contains(operands.count), !operands.contains(where: \.isEmpty) else {
                throw ARMAssembler.message("expected \(form)")
            }
        }

        func instruction(_ m: Mnemonic, _ ops: [String], _ index: Int) throws {
            let cond = m.condition << 28
            switch m.base {
            case "B", "BL":
                try expect(ops, 1...1, "\(m.base) address")
                let target = try word(ops[0])
                let offset = Int64(Int32(bitPattern: target &- (pc &+ 8)))
                if !unresolved {
                    guard offset & 3 == 0 else { throw ARMAssembler.message("branch target isn't word aligned") }
                    guard (-0x200_0000..<0x200_0000).contains(offset) else { throw ARMAssembler.message("branch target out of range") }
                }
                emit(cond | 0x0A00_0000 | (m.base == "BL" ? 0x0100_0000 : 0) | UInt32(truncatingIfNeeded: offset >> 2) & 0xFF_FFFF)
            case "SWI", "SVC":
                try expect(ops, 1...1, "SWI number or name")
                let n: UInt32
                if ops[0].hasPrefix("\"") {
                    let name = try ARMAssembler.quoted(ops[0])
                    guard let v = SWINames.number(name) else { throw ARMAssembler.message("unknown SWI \(name) (use its number)") }
                    n = v
                } else {
                    n = try word(ops[0])
                }
                guard n <= 0xFF_FFFF else { throw ARMAssembler.message("SWI number out of range") }
                emit(cond | 0x0F00_0000 | n)
            case "NOP":
                try expect(ops, 0...0, "no operands")
                emit(cond | 0x01A0_0000)
            case "MUL", "MLA":
                let mla = m.base == "MLA"
                try expect(ops, mla ? 4...4 : 3...3, mla ? "Rd, Rm, Rs, Rn" : "Rd, Rm, Rs")
                let rd = try register(ops[0]), rm = try register(ops[1]), rs = try register(ops[2])
                let rn = mla ? try register(ops[3]) : 0
                if rd == rm { warn("\(m.base) with Rd the same as Rm gives the wrong result on the ARM2") }
                if rd == 15 { warn("\(m.base) into PC is unpredictable") }
                emit(cond | (mla ? 0x0020_0000 : 0) | (m.flags == "S" ? 0x0010_0000 : 0) | rd << 16 | rn << 12 | rs << 8 | 0x90 | rm)
            case "SWP":
                try expect(ops, 3...3, "Rd, Rm, [Rn]")
                let rd = try register(ops[0]), rm = try register(ops[1])
                let address = ops[2].trimmingCharacters(in: .whitespaces)
                guard address.hasPrefix("["), address.hasSuffix("]") else { throw ARMAssembler.message("expected [Rn]") }
                let rn = try register(String(address.dropFirst().dropLast()))
                emit(cond | 0x0100_0090 | (m.flags == "B" ? 0x0040_0000 : 0) | rn << 16 | rd << 12 | rm)
            case "ADR":
                try expect(ops, 2...2, "Rd, address")
                let rd = try register(ops[0])
                let offset = try word(ops[1]) &- (pc &+ 8)
                if let imm = ARMAssembler.immediate(offset) {
                    emit(cond | 0x028F_0000 | rd << 12 | imm)
                } else if let imm = ARMAssembler.immediate(0 &- offset) {
                    emit(cond | 0x024F_0000 | rd << 12 | imm)
                } else if unresolved {
                    emit(cond | 0x028F_0000 | rd << 12)
                } else {
                    throw ARMAssembler.message("ADR can't reach that address in one instruction (use ADRL)")
                }
            case "ADRL":
                try expect(ops, 2...2, "Rd, address")
                let rd = try register(ops[0])
                let offset = try word(ops[1]) &- (pc &+ 8)
                let (add, magnitude) = Int32(bitPattern: offset) >= 0 ? (true, offset) : (false, 0 &- offset)
                guard let (a, b) = ARMAssembler.splitImmediate(magnitude) else {
                    if unresolved { emit(cond | 0x028F_0000 | rd << 12); emit(cond | 0x0280_0000 | rd << 16 | rd << 12); return }
                    throw ARMAssembler.message("ADRL can't reach that address in two instructions")
                }
                let op: UInt32 = add ? 0x0280_0000 : 0x0240_0000
                emit(cond | op | 15 << 16 | rd << 12 | a)
                emit(cond | op | rd << 16 | rd << 12 | b)
            case "LDR", "STR":
                try singleTransfer(m, ops, index)
            case "LDM", "STM":
                try blockTransfer(m, ops)
            case "MRC", "MCR":
                try expect(ops, 5...6, "p15, op1, Rd, CRn, CRm[, op2]")
                let cp = try coprocessor(ops[0]), op1 = try field(ops[1], max: 7, "op1")
                let rd = try register(ops[2]), crn = try coprocessorRegister(ops[3]), crm = try coprocessorRegister(ops[4])
                let op2 = ops.count > 5 ? try field(ops[5], max: 7, "op2") : 0
                emit(cond | 0x0E00_0010 | op1 << 21 | (m.base == "MRC" ? 0x0010_0000 : 0) | crn << 16 | rd << 12 | cp << 8 | op2 << 5 | crm)
            case "CDP":
                try expect(ops, 5...6, "p, op1, CRd, CRn, CRm[, op2]")
                let cp = try coprocessor(ops[0]), op1 = try field(ops[1], max: 15, "op1")
                let crd = try coprocessorRegister(ops[2]), crn = try coprocessorRegister(ops[3]), crm = try coprocessorRegister(ops[4])
                let op2 = ops.count > 5 ? try field(ops[5], max: 7, "op2") : 0
                emit(cond | 0x0E00_0000 | op1 << 20 | crn << 16 | crd << 12 | cp << 8 | op2 << 5 | crm)
            case "LDC", "STC":
                try coprocessorTransfer(m, ops)
            default:
                try dataProcessing(m, ops)
            }
        }

        // MARK: Data processing

        /// The register form of operand 2: Rm, or Rm with a shift.
        func shiftedRegister(_ ops: ArraySlice<String>, allowRegisterShift: Bool = true) throws -> UInt32 {
            guard let first = ops.first else { throw ARMAssembler.message("missing operand") }
            let rm = try register(first)
            guard ops.count > 1 else { return rm }
            guard ops.count == 2 else { throw ARMAssembler.message("too many operands") }
            return rm | (try shift(ops[ops.startIndex + 1], allowRegister: allowRegisterShift))
        }

        func isShift(_ text: String) -> Bool {
            let t = text.trimmingCharacters(in: .whitespaces).uppercased()
            return ["LSL", "ASL", "LSR", "ASR", "ROR", "RRX"].contains { t.hasPrefix($0) && (t.count == 3 || !ARMAssembler.isNameChar(t[t.index(t.startIndex, offsetBy: 3)])) }
        }

        /// Bits 4-11 for "LSL #3", "ASR R2", "RRX".
        func shift(_ text: String, allowRegister: Bool) throws -> UInt32 {
            let t = text.trimmingCharacters(in: .whitespaces)
            let name = t.prefix(3).uppercased()
            let rest = t.dropFirst(3).trimmingCharacters(in: .whitespaces)
            if name == "RRX" {
                guard rest.isEmpty else { throw ARMAssembler.message("RRX takes no amount") }
                return 3 << 5
            }
            let types: [String: UInt32] = ["LSL": 0, "ASL": 0, "LSR": 1, "ASR": 2, "ROR": 3]
            guard let type = types[name] else { throw ARMAssembler.message("expected a shift (LSL, LSR, ASR, ROR, RRX), not \(text)") }
            if rest.hasPrefix("#") {
                let n = try value(String(rest.dropFirst()))
                if unresolved { return type << 5 }
                switch type {
                case 0: guard (0...31).contains(n) else { throw ARMAssembler.message("LSL by 0-31") }
                case 3: guard (1...31).contains(n) else { throw ARMAssembler.message("ROR by 1-31 (RRX for a one-bit rotate through carry)") }
                default: guard (1...32).contains(n) else { throw ARMAssembler.message("\(name) by 1-32") }
                }
                return UInt32(n & 31) << 7 | type << 5
            }
            guard allowRegister else { throw ARMAssembler.message("only a shift by a constant here") }
            return try register(rest) << 8 | type << 5 | 0x10
        }

        func dataProcessing(_ m: Mnemonic, _ ops: [String]) throws {
            guard var op = ARMAssembler.dataOps[m.base] else { throw ARMAssembler.message("unknown instruction \(m.base)") }
            let compare = (8...11).contains(op)
            let move = op == 13 || op == 15
            var rd: UInt32 = 0, rn: UInt32 = 0
            let operand2: ArraySlice<String>
            if move || compare {
                try expect(ops, 2...3, compare ? "Rn, operand" : "Rd, operand")
                if compare { rn = try register(ops[0]); rd = m.flags == "P" ? 15 : 0 } else { rd = try register(ops[0]) }
                operand2 = ops[1...]
            } else {
                try expect(ops, 2...4, "Rd, Rn, operand")
                rd = try register(ops[0])
                // ADD R0, #1 and ADD R0, R1, LSL #2 mean Rd is also Rn.
                if ops.count == 2 || (ops.count == 3 && isShift(ops[2])) {
                    rn = rd; operand2 = ops[1...]
                } else {
                    rn = try register(ops[1]); operand2 = ops[2...]
                }
            }
            var bits: UInt32
            let first = operand2.first!
            if first.hasPrefix("#") {
                guard operand2.count == 1 else { throw ARMAssembler.message("an immediate takes no shift") }
                let v = try word(String(first.dropFirst()))
                if let imm = ARMAssembler.immediate(v) {
                    bits = 0x0200_0000 | imm
                } else if let (other, imm) = ARMAssembler.alternative(op, v) {
                    op = other; bits = 0x0200_0000 | imm
                } else if unresolved {
                    bits = 0x0200_0000
                } else {
                    throw ARMAssembler.message(String(format: "can't make &%X as an immediate (an 8-bit value rotated by an even amount); use LDR R, =value", v))
                }
            } else {
                bits = try shiftedRegister(operand2)
            }
            let s: UInt32 = compare || m.flags == "S" ? 0x0010_0000 : 0
            emit(m.condition << 28 | op << 21 | s | rn << 16 | rd << 12 | bits)
        }

        // MARK: Memory

        /// An offset: #value, or [+|-]Rm with a constant shift. Returns the
        /// bits (with I set for a register) and whether it adds.
        func offset(_ ops: ArraySlice<String>) throws -> (bits: UInt32, up: Bool) {
            guard let first = ops.first else { return (0, true) }
            if first.hasPrefix("#") {
                guard ops.count == 1 else { throw ARMAssembler.message("an immediate offset takes no shift") }
                let v = try value(String(first.dropFirst()))
                if unresolved { return (0, true) }
                guard (-4095...4095).contains(v) else { throw ARMAssembler.message("offset out of range (±4095)") }
                return (UInt32(abs(v)), v >= 0)
            }
            var r = first.trimmingCharacters(in: .whitespaces)
            var up = true
            if r.hasPrefix("-") { up = false; r.removeFirst() } else if r.hasPrefix("+") { r.removeFirst() }
            var rest = ops
            rest[rest.startIndex] = r
            return (0x0200_0000 | (try shiftedRegister(rest, allowRegisterShift: false)), up)
        }

        func singleTransfer(_ m: Mnemonic, _ ops: [String], _ index: Int) throws {
            guard ops.count >= 2, !ops[0].isEmpty, !ops[1].isEmpty else { throw ARMAssembler.message("expected Rd, address") }
            let load = m.base == "LDR"
            let rd = try register(ops[0])
            let byte: UInt32 = m.flags.contains("B") ? 0x0040_0000 : 0
            let translate = m.flags.contains("T")
            var base = m.condition << 28 | 0x0400_0000 | byte | (load ? 0x0010_0000 : 0) | rd << 12
            let address = ops[1].trimmingCharacters(in: .whitespaces)

            if address.hasPrefix("=") {
                guard load, ops.count == 2, !translate else { throw ARMAssembler.message("=value only with LDR Rd, =value") }
                let v = try word(String(address.dropFirst()))
                let decided = shared.literalIsMove[index]
                let move = decided ?? (!unresolved && (ARMAssembler.immediate(v) != nil || ARMAssembler.immediate(~v) != nil) && byte == 0)
                shared.literalIsMove[index] = move
                if move {
                    if let imm = ARMAssembler.immediate(v) { emit(m.condition << 28 | 0x03A0_0000 | rd << 12 | imm) }
                    else { emit(m.condition << 28 | 0x03E0_0000 | rd << 12 | (ARMAssembler.immediate(~v) ?? 0)) }
                } else {
                    literals.append((bytes.count, pc, v, location))
                    emit(base | 0x0180_0000 | 15 << 16)
                }
                return
            }

            if address.hasPrefix("[") {
                guard let close = address.lastIndex(of: "]") else { throw ARMAssembler.message("missing ]") }
                let inner = ARMAssembler.split(String(address[address.index(after: address.startIndex)..<close]))
                let after = address[address.index(after: close)...].trimmingCharacters(in: .whitespaces)
                guard let first = inner.first else { throw ARMAssembler.message("expected [Rn...]") }
                let rn = try register(first)
                base |= rn << 16
                if ops.count == 2 {
                    // Pre-indexed: [Rn, offset]{!}
                    guard after.isEmpty || after == "!" else { throw ARMAssembler.message("unexpected \(after)") }
                    guard !translate else { throw ARMAssembler.message("T only with post-indexed addressing ([Rn], offset)") }
                    let (bits, up) = try offset(inner[1...])
                    emit(base | 0x0100_0000 | (up ? 0x0080_0000 : 0) | (after == "!" ? 0x0020_0000 : 0) | bits)
                } else {
                    // Post-indexed: [Rn], offset
                    guard inner.count == 1, after.isEmpty else { throw ARMAssembler.message("expected [Rn], offset") }
                    let (bits, up) = try offset(ops[2...])
                    emit(base | (up ? 0x0080_0000 : 0) | (translate ? 0x0020_0000 : 0) | bits)
                }
                return
            }

            // A label: PC relative.
            guard ops.count == 2, !translate else { throw ARMAssembler.message("expected Rd, [Rn...] or Rd, label") }
            let offset = Int64(Int32(bitPattern: try word(address) &- (pc &+ 8)))
            if !unresolved, !(-4095...4095).contains(offset) { throw ARMAssembler.message("\(address) is out of range (±4095 bytes)") }
            let magnitude = unresolved ? 0 : UInt32(abs(offset))
            emit(base | 0x0100_0000 | 15 << 16 | (offset >= 0 ? 0x0080_0000 : 0) | magnitude)
        }

        func blockTransfer(_ m: Mnemonic, _ ops: [String]) throws {
            try expect(ops, 2...2, "Rn{!}, {registers}{^}")
            let load = m.base == "LDM"
            var rnText = ops[0].trimmingCharacters(in: .whitespaces)
            let writeBack = rnText.hasSuffix("!")
            if writeBack { rnText.removeLast() }
            let rn = try register(rnText)
            var list = ops[1].trimmingCharacters(in: .whitespaces)
            let psr = list.hasSuffix("^")
            if psr { list = String(list.dropLast()).trimmingCharacters(in: .whitespaces) }
            guard list.hasPrefix("{"), list.hasSuffix("}") else { throw ARMAssembler.message("expected {registers}") }
            var mask: UInt32 = 0
            for item in ARMAssembler.split(String(list.dropFirst().dropLast())) where !item.isEmpty {
                let range = item.split(separator: "-", maxSplits: 1).map(String.init)
                let a = try register(range[0])
                let b = range.count > 1 ? try register(range[1]) : a
                guard a <= b else { throw ARMAssembler.message("register range \(item) goes backwards") }
                for r in a...b { mask |= 1 << r }
            }
            guard mask != 0 else { throw ARMAssembler.message("no registers") }
            let mode = m.flags.isEmpty ? "IA" : m.flags
            let stack: [String: String] = load ? ["FD": "IA", "ED": "IB", "FA": "DA", "EA": "DB"] : ["FD": "DB", "ED": "DA", "FA": "IB", "EA": "IA"]
            let actual = stack[mode] ?? mode
            let pre: UInt32 = actual.hasSuffix("B") ? 0x0100_0000 : 0
            let up: UInt32 = actual.hasPrefix("I") ? 0x0080_0000 : 0
            if writeBack && load && mask & (1 << rn) != 0 { warn("loading the base register with write-back: the loaded value wins") }
            emit(m.condition << 28 | 0x0800_0000 | pre | up | (psr ? 0x0040_0000 : 0) | (writeBack ? 0x0020_0000 : 0) | (load ? 0x0010_0000 : 0) | rn << 16 | mask)
        }

        func coprocessorTransfer(_ m: Mnemonic, _ ops: [String]) throws {
            guard ops.count >= 3 else { throw ARMAssembler.message("expected p, CRd, [Rn, #offset]") }
            let cp = try coprocessor(ops[0]), crd = try coprocessorRegister(ops[1])
            var w = m.condition << 28 | 0x0C00_0000 | (m.flags == "L" ? 0x0040_0000 : 0) | (m.base == "LDC" ? 0x0010_0000 : 0) | crd << 12 | cp << 8
            func words(_ text: String?) throws -> (UInt32, Bool) {
                guard let text else { return (0, true) }
                guard text.hasPrefix("#") else { throw ARMAssembler.message("coprocessor offsets are #constants") }
                let v = try value(String(text.dropFirst()))
                if unresolved { return (0, true) }
                guard v % 4 == 0, (-1020...1020).contains(v) else { throw ARMAssembler.message("offset must be a multiple of 4 within ±1020") }
                return (UInt32(abs(v) / 4), v >= 0)
            }
            let address = ops[2].trimmingCharacters(in: .whitespaces)
            if address.hasPrefix("[") {
                guard let close = address.lastIndex(of: "]") else { throw ARMAssembler.message("missing ]") }
                let inner = ARMAssembler.split(String(address[address.index(after: address.startIndex)..<close]))
                let after = address[address.index(after: close)...].trimmingCharacters(in: .whitespaces)
                w |= try register(inner[0]) << 16
                if ops.count == 3 {
                    let (n, up) = try words(inner.count > 1 ? inner[1] : nil)
                    w |= 0x0100_0000 | (up ? 0x0080_0000 : 0) | (after == "!" ? 0x0020_0000 : 0) | n
                } else {
                    let (n, up) = try words(ops[3])
                    w |= 0x0020_0000 | (up ? 0x0080_0000 : 0) | n
                }
            } else {
                let offset = Int(Int32(bitPattern: try word(address) &- (pc &+ 8)))
                let (n, up) = try words("#\(unresolved ? 0 : offset)")
                w |= 0x0100_0000 | 15 << 16 | (up ? 0x0080_0000 : 0) | n
            }
            emit(w)
        }
    }

    /// An immediate that doesn't fit, done another way: MOV #-1 as MVN #0,
    /// ADD #-4 as SUB #4, CMP #-1 as CMN #1, AND #~x as BIC #x.
    static func alternative(_ op: UInt32, _ v: UInt32) -> (UInt32, UInt32)? {
        let pairs: [UInt32: (UInt32, UInt32)] = [13: (15, ~v), 15: (13, ~v), 0: (14, ~v), 14: (0, ~v), 4: (2, 0 &- v), 2: (4, 0 &- v),
                                                 10: (11, 0 &- v), 11: (10, 0 &- v), 5: (6, ~v), 6: (5, ~v)]
        guard let (other, w) = pairs[op], let imm = immediate(w) else { return nil }
        return (other, imm)
    }

    /// A value as the sum of two immediates (for ADRL).
    static func splitImmediate(_ v: UInt32) -> (UInt32, UInt32)? {
        if let a = immediate(v) { return (a, 0) }
        for shift in stride(from: 0, to: 32, by: 2) {
            let low = v & (0xFF << UInt32(shift))
            guard low != 0, let a = immediate(low), let b = immediate(v &- low) else { continue }
            return (a, b)
        }
        return nil
    }
}
