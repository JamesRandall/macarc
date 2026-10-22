/// Debugger expressions, for breakpoint conditions, log points and
/// addresses:
///
///     R0 == &41 && [R1] > 3        registers, flags, memory
///     {&8000}                      a 32-bit little-endian word
///     PC >= &3800000 && MODE == 3
///     OS_WriteC_entry              a symbol
///
/// Numbers: &FF or $FF or 0xFF (hex), %1010 (binary), 42 (decimal), 'A'.
/// Names: R0-R15, SP (R13), LR (R14), PC, PSR (R15 with flags), MODE
/// (0 USR, 1 FIQ, 2 IRQ, 3 SVC), the flags N Z C V I F, CYCLES (24 MHz
/// ticks) and INSTRUCTIONS; anything else is looked up as a symbol.
/// [x] reads a byte, {x} a word, through the MEMC as the CPU would.
/// Operators, loosest first: || && == != < > <= >= | ^ & << >> + - * / %
/// and the unary ! - ~. Values are integers; true is non-zero.
public struct DebugExpression: Sendable, CustomStringConvertible {
    public let source: String
    let root: Node

    indirect enum Node: Sendable {
        case number(Int)
        case name(String)
        case byte(Node)
        case word(Node)
        case unary(String, Node)
        case binary(String, Node, Node)
    }

    public var description: String { source }

    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    public struct EvaluationError: Error, CustomStringConvertible {
        public let description: String
    }

    public protocol Context {
        func register(_ name: String) -> Int?
        func readByte(_ address: UInt32) -> UInt8
        func readWord(_ address: UInt32) -> UInt32
        func symbol(_ name: String) -> Int?
    }

    public init(_ source: String) throws {
        self.source = source
        var p = Parser(tokens: try Self.lex(source), source: source)
        root = try p.expression(0)
        if p.position < p.tokens.count { throw ParseError(description: "unexpected \(p.tokens[p.position].text) in \"\(source)\"") }
    }

    public func evaluate(_ c: Context) throws -> Int { try Self.eval(root, c) }

    // MARK: Lexing

    struct Token { enum Kind { case number(Int), name, op } ; let kind: Kind; let text: String }

    static let operators = ["||", "&&", "==", "!=", "<=", ">=", "<<", ">>", "<", ">", "|", "^", "&", "+", "-", "*", "/", "%", "!", "~", "(", ")", "[", "]", "{", "}"]

    static func lex(_ s: String) throws -> [Token] {
        let c = Array(s)
        var out: [Token] = []
        var i = 0
        func afterOperand() -> Bool {
            guard let last = out.last else { return false }
            switch last.kind {
            case .number, .name: return true
            case .op: return [")", "]", "}"].contains(last.text)
            }
        }
        func isHex(_ ch: Character) -> Bool { ch.isHexDigit }
        while i < c.count {
            let ch = c[i]
            if ch.isWhitespace { i += 1; continue }
            // & and % start numbers unless they follow an operand.
            if (ch == "&" || ch == "$") && i + 1 < c.count && isHex(c[i + 1]) && (ch == "$" || !afterOperand()) {
                var j = i + 1
                while j < c.count && isHex(c[j]) { j += 1 }
                guard let v = Int(String(c[(i + 1)..<j]), radix: 16) else { throw ParseError(description: "bad number in \"\(s)\"") }
                out.append(Token(kind: .number(v), text: String(c[i..<j]))); i = j; continue
            }
            if ch == "%" && i + 1 < c.count && (c[i + 1] == "0" || c[i + 1] == "1") && !afterOperand() {
                var j = i + 1
                while j < c.count && (c[j] == "0" || c[j] == "1") { j += 1 }
                out.append(Token(kind: .number(Int(String(c[(i + 1)..<j]), radix: 2)!), text: String(c[i..<j]))); i = j; continue
            }
            // 'A': a character code.
            if ch == "'" && i + 2 < c.count && c[i + 2] == "'", let v = c[i + 1].asciiValue {
                out.append(Token(kind: .number(Int(v)), text: String(c[i...(i + 2)]))); i += 3; continue
            }
            if ch.isNumber {
                var j = i
                if ch == "0" && i + 1 < c.count && (c[i + 1] == "x" || c[i + 1] == "X") {
                    j = i + 2
                    while j < c.count && isHex(c[j]) { j += 1 }
                    guard j > i + 2, let v = Int(String(c[(i + 2)..<j]), radix: 16) else { throw ParseError(description: "bad number in \"\(s)\"") }
                    out.append(Token(kind: .number(v), text: String(c[i..<j]))); i = j; continue
                }
                while j < c.count && c[j].isNumber { j += 1 }
                guard let v = Int(String(c[i..<j])) else { throw ParseError(description: "bad number in \"\(s)\"") }
                out.append(Token(kind: .number(v), text: String(c[i..<j]))); i = j; continue
            }
            if ch.isLetter || ch == "_" || ch == "." || ch == "@" {
                var j = i
                while j < c.count && (c[j].isLetter || c[j].isNumber || c[j] == "_" || c[j] == "." || c[j] == "@") { j += 1 }
                out.append(Token(kind: .name, text: String(c[i..<j]))); i = j; continue
            }
            let rest = String(c[i...])
            guard let op = operators.first(where: { rest.hasPrefix($0) }) else { throw ParseError(description: "unexpected \(ch) in \"\(s)\"") }
            out.append(Token(kind: .op, text: op)); i += op.count
        }
        return out
    }

    // MARK: Parsing

    static let levels: [[String]] = [["||"], ["&&"], ["==", "!=", "<", ">", "<=", ">="], ["|"], ["^"], ["&"], ["<<", ">>"], ["+", "-"], ["*", "/", "%"]]

    struct Parser {
        let tokens: [Token]
        let source: String
        var position = 0

        mutating func expression(_ level: Int) throws -> Node {
            if level == DebugExpression.levels.count { return try unary() }
            var left = try expression(level + 1)
            while position < tokens.count, case .op = tokens[position].kind, DebugExpression.levels[level].contains(tokens[position].text) {
                let op = tokens[position].text
                position += 1
                left = .binary(op, left, try expression(level + 1))
            }
            return left
        }

        mutating func unary() throws -> Node {
            guard position < tokens.count else { throw ParseError(description: "expression ends early") }
            let t = tokens[position]
            if case .op = t.kind, ["!", "-", "~"].contains(t.text) {
                position += 1
                return .unary(t.text, try unary())
            }
            return try primary()
        }

        mutating func expect(_ text: String) throws {
            guard position < tokens.count, tokens[position].text == text else { throw ParseError(description: "missing \(text)") }
            position += 1
        }

        mutating func primary() throws -> Node {
            guard position < tokens.count else { throw ParseError(description: "expression ends early") }
            let t = tokens[position]
            position += 1
            switch t.kind {
            case .number(let v): return .number(v)
            case .name: return .name(t.text)
            case .op:
                switch t.text {
                case "(": let e = try expression(0); try expect(")"); return e
                case "[": let e = try expression(0); try expect("]"); return .byte(e)
                case "{": let e = try expression(0); try expect("}"); return .word(e)
                default: throw ParseError(description: "unexpected \(t.text) in \"\(source)\"")
                }
            }
        }
    }

    // MARK: Evaluation

    static func eval(_ n: Node, _ c: Context) throws -> Int {
        switch n {
        case .number(let v): return v
        case .name(let s):
            if let v = c.register(s.uppercased()) { return v }
            if let v = c.symbol(s) { return v }
            throw EvaluationError(description: "unknown name \(s)")
        case .byte(let e): return Int(c.readByte(UInt32(truncatingIfNeeded: try eval(e, c))))
        case .word(let e): return Int(c.readWord(UInt32(truncatingIfNeeded: try eval(e, c))))
        case .unary(let op, let e):
            let v = try eval(e, c)
            switch op {
            case "!": return v == 0 ? 1 : 0
            case "-": return 0 &- v
            default: return ~v & 0xFFFF_FFFF
            }
        case .binary(let op, let l, let r):
            if op == "&&" { return try eval(l, c) != 0 && eval(r, c) != 0 ? 1 : 0 }
            if op == "||" { return try eval(l, c) != 0 || eval(r, c) != 0 ? 1 : 0 }
            let a = try eval(l, c), b = try eval(r, c)
            switch op {
            case "==": return a == b ? 1 : 0
            case "!=": return a != b ? 1 : 0
            case "<": return a < b ? 1 : 0
            case ">": return a > b ? 1 : 0
            case "<=": return a <= b ? 1 : 0
            case ">=": return a >= b ? 1 : 0
            case "|": return a | b
            case "^": return a ^ b
            case "&": return a & b
            case "<<": return (0...62).contains(b) ? a << b : 0
            case ">>": return (0...62).contains(b) ? a >> b : 0
            case "+": return a &+ b
            case "-": return a &- b
            case "*": return a &* b
            case "/": guard b != 0 else { throw EvaluationError(description: "division by zero") }; return a / b
            default: guard b != 0 else { throw EvaluationError(description: "division by zero") }; return a % b
            }
        }
    }
}
