import Foundation

// BBC BASIC V as a debugger sees it: the interpreter in the ROM, and the
// program, variables and PROC/FN calls in memory. (After MacBeeb's BASIC 2
// version; the layout here was found by watching the RISC OS 2 and 3 ROMs'
// BASIC run.)
//
// BASIC keeps its workspace pointer (ARGP, &8700) in R8, the text pointer in
// R12 between statements and its stack in R13, full descending from HIMEM.
// Relative to ARGP:
//   -&700 the command line (typed, then tokenised at -&500)
//   -&200 the heads of the variable lists, a word per initial character
//         from @ (the list for c at -&200 + 4 * (c - &40))
//   -&100 @% to Z%
//   -&94 PAGE  -&90 TOP  -&8C the end of the variables  -&88 LOMEM
//   -&84 HIMEM  -&80 ERR  -&7C the ON ERROR handler  -&74 ERL
// A variable is a link word, the rest of its name (with its % $ or (), a
// 0, then its value: an integer's 4 bytes; a real's 4-byte mantissa (its
// top bit the sign, the 1 it stands for implied) and exponent (excess
// &80); a string's address (4 bytes) and length; an array's block's
// address. An array's block is its dimensions' sizes (each its highest
// index plus one), a 0, the number of elements, then the elements.
//
// A PROC or FN call pushes a frame on BASIC's stack: the token (a word,
// &F2 PROC or &A4 FN), the text pointer after the call, the PROC's name
// (or the start of the statement calling the FN), then its LOCALs, each saved as the value's address,
// its type and its old value. A GOSUB pushes RETURN's token (&F8) and the
// text pointer after it.

/// The BASIC module in the ROM, found by the code in it.
public struct BasicInterpreter: Sendable, Equatable {
    /// E.g. "BASIC V 1.05".
    public var name: String
    /// The instruction each statement is dispatched from: R10 is its
    /// first character, at R12 - 1.
    var statement: UInt32
    /// The start of BASIC's error handling: R14 points to the error (its
    /// number, then the message), R12 - 2 to where it happened.
    var errorHandler: UInt32
    /// Where BASIC's command loop continues after reading a command line
    /// (the user R14 while it waits for one).
    var promptReturn: UInt32
    /// ARGP.
    var workspace: UInt32
    /// Roughly where the module's code is.
    var code: ClosedRange<UInt32>

    /// The interpreter in a ROM image whose first word is at `base`.
    static func find(_ rom: [UInt32], base: UInt32) -> BasicInterpreter? {
        func search(_ pattern: [UInt32?], from start: Int = 0) -> Int? {
            var i = start
            outer: while i + pattern.count <= rom.count {
                for (j, word) in pattern.enumerated() where word != nil && rom[i + j] != word {
                    i += 1
                    continue outer
                }
                return i
            }
            return nil
        }
        func address(_ index: Int) -> UInt32 { base &+ UInt32(index * 4) }
        // The statement dispatch: LDR R4, [PC, R10, LSL #2] : ADD PC, PC, R4,
        // after LDRB R10, [R12], #1 (and in RISC OS 2, skipping spaces).
        var statement: Int?
        var from = 0
        while let i = search([0xE79F_410A, 0xE08F_F004], from: from) {
            if (1...3).contains(where: { i - $0 >= 0 && rom[i - $0] == 0xE4DC_A001 }) {
                statement = i
                break
            }
            from = i + 1
        }
        guard let statement else { return nil }
        // Error handling starts MOV R8, #&8700 (ARGP), soon followed by
        // MOV R0, #&DA (OS_Byte &DA, flushing the VDU queue).
        var errorHandler: Int?
        from = 0
        while let i = search([0xE3A0_8C87], from: from) {
            if (1...4).contains(where: { i + $0 < rom.count && rom[i + $0] == 0xE3A0_00DA }) {
                errorHandler = i
                break
            }
            from = i + 1
        }
        // The command loop: SWI OS_WriteI+'>' : BL (read a line).
        guard let errorHandler,
              let prompt = search([0xEF00_013E, nil]).flatMap({ rom[$0 + 1] >> 24 == 0xEB ? $0 : nil }) else { return nil }
        let lowest = address(min(statement, errorHandler, prompt))
        let highest = address(max(statement, errorHandler, prompt))
        return BasicInterpreter(name: Self.name(rom, near: statement), statement: address(statement),
                                errorHandler: address(errorHandler), promptReturn: address(prompt + 2),
                                workspace: 0x8700, code: (lowest &- 0x4000)...(highest &+ 0x8000))
    }

    /// The module's name and version, from its help string ("BBC BASIC V",
    /// a tab and the version).
    static func name(_ rom: [UInt32], near index: Int) -> String {
        let start = max(0, index - 0x8000), end = min(rom.count, index + 0x1000)
        var bytes: [UInt8] = []
        bytes.reserveCapacity((end - start) * 4)
        for word in rom[start..<end] {
            bytes += [UInt8(word & 0xFF), UInt8(word >> 8 & 0xFF), UInt8(word >> 16 & 0xFF), UInt8(word >> 24)]
        }
        let tag = Array("BASIC V\t".utf8)
        var i = 0
        while i + tag.count < bytes.count {
            if bytes[i..<i + tag.count].elementsEqual(tag) {
                var j = i + tag.count
                while j < bytes.count, bytes[j] == 0x09 { j += 1 }
                var version = ""
                while j < bytes.count, bytes[j] == 0x2E || (0x30...0x39).contains(bytes[j]) {
                    version.unicodeScalars.append(Unicode.Scalar(bytes[j]))
                    j += 1
                }
                if !version.isEmpty { return "BASIC V \(version)" }
            }
            i += 1
        }
        return "BASIC V"
    }
}

/// Where a statement is.
public struct BasicLocation: Sendable, Equatable, Hashable, CustomStringConvertible {
    public var line: Int
    /// 1 for the first in the line; each colon starts another.
    public var statement: Int
    /// The statement's first character (or, for an error or a call, the
    /// text pointer's place in it).
    public var address: UInt32

    public init(line: Int, statement: Int = 1, address: UInt32 = 0) {
        self.line = line
        self.statement = statement
        self.address = address
    }

    public var description: String {
        statement > 1 ? "line \(line) statement \(statement)" : "line \(line)"
    }
}

/// A BASIC number or string.
public enum BasicValue: Sendable, Equatable, CustomStringConvertible {
    case integer(Int32)
    case real(Double)
    case string(String)

    /// As PRINT shows it, with strings in quotes.
    public var description: String {
        switch self {
        case .integer(let n): String(n)
        case .real(let x): Self.format(x)
        case .string(let s): "\"\(s)\""
        }
    }

    /// As PRINT shows a real by default: 9 significant figures, with an
    /// exponent if it's below 0.1 or 1E9 or more.
    static func format(_ x: Double) -> String {
        guard x != 0 else { return "0" }
        guard x.isFinite else { return x > 0 ? "1.7E38" : "-1.7E38" }
        let parts = String(format: "%.8e", x).split(separator: "e")
        guard parts.count == 2, var exponent = Int(parts[1]) else { return String(x) }
        let negative = parts[0].hasPrefix("-")
        var digits = parts[0].filter(\.isNumber)
        if digits.count > 9 {
            // %.8e rounded to 9 digits; "10.0..." when it rounded up a power.
            digits.removeLast()
            exponent += 1
        }
        while digits.count > 1 && digits.hasSuffix("0") { digits.removeLast() }
        var text: String
        if exponent >= -1 && exponent < 9 {
            if exponent < 0 {
                text = "0." + digits
            } else if digits.count > exponent + 1 {
                text = digits.prefix(exponent + 1) + "." + digits.dropFirst(exponent + 1)
            } else {
                text = digits + String(repeating: "0", count: exponent + 1 - digits.count)
            }
        } else {
            text = String(digits.prefix(1))
            if digits.count > 1 { text += "." + digits.dropFirst() }
            text += "E\(exponent)"
        }
        return (negative ? "-" : "") + text
    }

    var number: Double? {
        switch self {
        case .integer(let n): Double(n)
        case .real(let x): x
        case .string: nil
        }
    }
}

/// A variable, from BASIC's lists.
public struct BasicVariable: Sendable, Equatable {
    public enum Kind: String, Sendable { case integer, real, string }

    /// With its % or $, and ( for an array.
    public var name: String
    public var kind: Kind
    /// An array's highest index in each dimension (as DIMmed).
    public var dimensions: [Int]?
    /// A scalar's value.
    public var value: BasicValue?
    /// The value's address (an array's first element's).
    public var address: UInt32
    /// Saved by a LOCAL (or as a parameter) in the PROC or FN running now.
    public var isLocal = false
    /// One of @% to Z%.
    public var isResident = false
}

/// A PROC or FN call being run, or the main program.
public struct BasicFrame: Sendable, Equatable {
    /// "PROCname" or "FNname", or nil for the main program.
    public var name: String?
    /// Where it is: the statement running, or for a caller, the call.
    /// Nil when that's a command typed in, not a program line.
    public var location: BasicLocation?
}

/// A program line in memory.
struct BasicLine: Equatable {
    /// The &0D before it.
    var start: UInt32
    var number: Int
    var length: Int
    /// Its text: after the number and length, to the next &0D.
    var text: Range<UInt32> { start + 4..<start + UInt32(length) }
}

/// A PROC or FN call's frame on BASIC's stack.
struct BasicCall: Equatable {
    /// &F2 PROC, &A4 FN.
    var token: UInt8
    /// The frame's address (deeper calls' are lower).
    var frame: UInt32
    /// For a PROC, its name (after the token); for an FN, the start of the
    /// statement calling it. Then where the text continues after the call.
    var caller: UInt32
    var after: UInt32
}

/// BASIC's memory, through the CPU's view.
struct BasicMemory {
    let read: (UInt32) -> UInt8
    let write: (UInt32, UInt8) -> Bool
    /// ARGP.
    let workspace: UInt32

    subscript(_ address: UInt32) -> UInt8 { read(address) }

    func word(_ address: UInt32) -> UInt32 {
        UInt32(self[address]) | UInt32(self[address &+ 1]) << 8 | UInt32(self[address &+ 2]) << 16 | UInt32(self[address &+ 3]) << 24
    }

    func writeWord(_ address: UInt32, _ value: UInt32) -> Bool {
        (0..<4).allSatisfy { write(address &+ UInt32($0), UInt8(value >> (8 * UInt32($0)) & 0xFF)) }
    }

    var page: UInt32 { word(workspace &- 0x94) }
    var top: UInt32 { word(workspace &- 0x90) }
    var vartop: UInt32 { word(workspace &- 0x8C) }
    var lomem: UInt32 { word(workspace &- 0x88) }
    var himem: UInt32 { word(workspace &- 0x84) }
    var err: UInt32 { word(workspace &- 0x80) }
    var errorHandler: UInt32 { word(workspace &- 0x7C) }
    var erl: UInt32 { word(workspace &- 0x74) }
    /// Where commands typed in are kept (as typed, then tokenised).
    var commandLine: Range<UInt32> { workspace &- 0x700..<workspace &- 0x300 }

    /// Whether `address` is in the program or a command typed in.
    func isText(_ address: UInt32) -> Bool {
        (address >= page && address < top) || commandLine.contains(address)
    }

    // MARK: The program

    /// The program's lines, in order.
    func lines() -> [BasicLine] {
        var lines: [BasicLine] = []
        var a = page
        let end = max(top, page)
        while a < end, self[a] == 0x0D, self[a &+ 1] != 0xFF, lines.count < 0x10000 {
            let length = Int(self[a &+ 3])
            guard length >= 4 else { break }
            lines.append(BasicLine(start: a, number: Int(self[a &+ 1]) << 8 | Int(self[a &+ 2]), length: length))
            a &+= UInt32(length)
        }
        return lines
    }

    func bytes(_ range: Range<UInt32>) -> [UInt8] { range.map { self[$0] } }

    /// The statement `address` is in, in `line`.
    func location(of address: UInt32, in line: BasicLine) -> BasicLocation {
        var statement = 1
        var quoted = false
        var a = line.text.lowerBound
        while a < address && a < line.text.upperBound {
            let byte = self[a]
            if byte == 0x22 {
                quoted.toggle()
            } else if !quoted {
                if byte == 0x3A {
                    statement += 1
                } else if byte == 0xF4 || byte == 0xDC {
                    // REM and DATA: the rest is text.
                    break
                } else if byte == 0x8D {
                    a &+= 3
                } else if (0xC6...0xC8).contains(byte) {
                    a &+= 1
                }
            }
            a &+= 1
        }
        return BasicLocation(line: line.number, statement: statement, address: address)
    }

    /// The name a DEF line defines (e.g. "PROCdraw"), if it's one.
    func definition(_ line: BasicLine) -> String? {
        var a = line.text.lowerBound
        while a < line.text.upperBound && self[a] == 0x20 { a += 1 }
        guard self[a] == 0xDD else { return nil }
        a += 1
        while a < line.text.upperBound && self[a] == 0x20 { a += 1 }
        return name(at: a)
    }

    /// The PROC or FN name at `address` (its token, then the name).
    func name(at address: UInt32) -> String? {
        let kind: String
        switch self[address] {
        case 0xF2: kind = "PROC"
        case 0xA4: kind = "FN"
        default: return nil
        }
        var name = kind
        var a = address &+ 1
        while Self.isNameCharacter(self[a]), name.count < 256 {
            name.unicodeScalars.append(Unicode.Scalar(self[a]))
            a &+= 1
        }
        return name
    }

    /// The parameters' names in a DEF line, after the name.
    func parameters(_ line: BasicLine) -> [String] {
        var a = line.text.lowerBound
        while a < line.text.upperBound && self[a] != 0xF2 && self[a] != 0xA4 { a += 1 }
        a += 1
        while a < line.text.upperBound && Self.isNameCharacter(self[a]) { a += 1 }
        while a < line.text.upperBound && self[a] == 0x20 { a += 1 }
        guard a < line.text.upperBound, self[a] == 0x28 else { return [] }
        var names: [String] = []
        var name = ""
        a += 1
        while a < line.text.upperBound {
            let c = self[a]
            if c == 0x2C || c == 0x29 {
                if !name.isEmpty { names.append(name) }
                name = ""
                if c == 0x29 { break }
            } else if Self.isNameCharacter(c) || c == 0x25 || c == 0x24 || c == 0x28 {
                name.unicodeScalars.append(Unicode.Scalar(c))
            }
            a += 1
        }
        return names
    }

    static func isNameCharacter(_ c: UInt8) -> Bool {
        (0x30...0x39).contains(c) || (0x40...0x5A).contains(c) || (0x5F...0x7A).contains(c)
    }

    // MARK: PROC and FN calls

    /// The PROC and FN frames on BASIC's stack, from `sp` up to HIMEM:
    /// innermost first.
    func calls(sp: UInt32) -> [BasicCall] {
        var calls: [BasicCall] = []
        let top = himem
        guard sp < top, top &- sp < 0x40_0000 else { return [] }
        var a = sp & ~3
        while a &+ 12 <= top {
            let token = word(a)
            if token == 0xF2 || token == 0xA4 {
                let after = word(a &+ 4), caller = word(a &+ 8)
                if isText(after), isText(caller), caller < after, after &- caller < 256 {
                    calls.append(BasicCall(token: UInt8(token), frame: a, caller: caller, after: after))
                    a &+= 12
                    continue
                }
            }
            a &+= 4
        }
        return calls
    }

    /// The innermost call's or GOSUB's frame's address (its depth: lower
    /// is deeper), or for the main program, the top of memory. A GOSUB
    /// pushes RETURN's token (&F8) and the text pointer after the GOSUB.
    func frameKey(sp: UInt32) -> UInt32 {
        let top = himem
        guard sp < top, top &- sp < 0x40_0000 else { return .max }
        var a = sp & ~3
        while a &+ 8 <= top {
            let token = word(a)
            if token == 0xF2 || token == 0xA4, a &+ 12 <= top {
                let after = word(a &+ 4), caller = word(a &+ 8)
                if isText(after), isText(caller), caller < after, after &- caller < 256 { return a }
            } else if token == 0xF8 {
                let after = word(a &+ 4)
                if isText(after), (1...8).contains(where: { self[after &- UInt32($0)] == 0xE4 }) { return a }
            }
            a &+= 4
        }
        return .max
    }

    /// The LOCALs saved in a call's frame: their values' addresses. Each is
    /// saved as the address, the type (4 integer, 5 real, &80 string) and
    /// the old value (a string's length and characters), in words.
    func locals(_ call: BasicCall) -> Set<UInt32> {
        var addresses: Set<UInt32> = []
        var a = call.frame &+ 12
        let top = himem
        while a &+ 8 <= top, addresses.count < 256 {
            let address = word(a)
            guard address >= workspace &- 0x100, address < top else { break }
            let size: UInt32
            switch word(a &+ 4) {
            case 4: size = 4
            case 5: size = 8
            case 0x80: size = (UInt32(self[a &+ 8]) + 4) & ~3
            default: return addresses
            }
            addresses.insert(address)
            a &+= 8 &+ size
        }
        return addresses
    }

    /// The PROC or FN a call is to: the last one before where the text
    /// carries on (from its name, for a PROC, or the start of the
    /// statement, for an FN).
    func callee(_ call: BasicCall) -> String? {
        var found: UInt32?
        var quoted = false
        var a = call.caller &- 1
        while a < call.after {
            let byte = self[a]
            if byte == 0x22 { quoted.toggle() }
            if !quoted && (byte == 0xF2 || byte == 0xA4) { found = a }
            a &+= 1
        }
        return found.flatMap { name(at: $0) }
    }

    // MARK: Variables

    /// Every variable (not PROCs and FNs), @% to Z% first.
    func variables() -> [BasicVariable] {
        var variables: [BasicVariable] = []
        for c in 0x40...0x5A {
            let name = String(Unicode.Scalar(UInt8(c))) + "%"
            let address = workspace &- 0x100 &+ UInt32((c - 0x40) * 4)
            variables.append(BasicVariable(name: name, kind: .integer, value: integer(at: address), address: address,
                                           isResident: true))
        }
        let low = page, high = himem
        for c in 0x41...0x7A {
            var entry = word(workspace &- 0x200 &+ UInt32((c - 0x40) * 4))
            var seen = 0
            while entry >= low, entry < high, seen < 4096 {
                seen += 1
                var name = String(Unicode.Scalar(UInt8(c)))
                var a = entry &+ 4
                while self[a] != 0, a < entry &+ 4 &+ 255 {
                    name.unicodeScalars.append(Unicode.Scalar(self[a]))
                    a &+= 1
                }
                if let variable = variable(name, valueAt: a &+ 1) {
                    variables.append(variable)
                }
                entry = word(entry)
            }
        }
        return variables
    }

    func variable(_ name: String, valueAt a: UInt32) -> BasicVariable? {
        let array = name.hasSuffix("(")
        let base = array ? String(name.dropLast()) : name
        let kind: BasicVariable.Kind = base.hasSuffix("%") ? .integer : base.hasSuffix("$") ? .string : .real
        guard array else {
            // Integers are word-aligned.
            let at = kind == .integer ? (a + 3) & ~3 : a
            return BasicVariable(name: name, kind: kind, value: value(kind, at: at), address: at)
        }
        // An array: its block's address (word-aligned).
        let block = word((a + 3) & ~3)
        guard block >= page, block < himem else { return nil }
        var dimensions: [Int] = []
        var d = block
        while dimensions.count < 16 {
            let size = word(d)
            d &+= 4
            guard size != 0 else { break }
            dimensions.append(Int(size) - 1)
        }
        guard !dimensions.isEmpty else { return nil }
        // Then the number of elements.
        return BasicVariable(name: name, kind: kind, dimensions: dimensions, address: d &+ 4)
    }

    func elementSize(_ kind: BasicVariable.Kind) -> Int { kind == .integer ? 4 : 5 }

    /// An array's element, if the indices are in range.
    func element(_ array: BasicVariable, _ indices: [Int]) -> BasicValue? {
        guard let dimensions = array.dimensions, indices.count == dimensions.count,
              let offset = elementOffset(dimensions, indices) else { return nil }
        return value(array.kind, at: array.address &+ UInt32(offset * elementSize(array.kind)))
    }

    func elementOffset(_ dimensions: [Int], _ indices: [Int]) -> Int? {
        var offset = 0
        for (index, highest) in zip(indices, dimensions) {
            guard (0...highest).contains(index) else { return nil }
            offset = offset * (highest + 1) + index
        }
        return offset
    }

    func value(_ kind: BasicVariable.Kind, at a: UInt32) -> BasicValue {
        switch kind {
        case .integer: integer(at: a)
        case .real: .real(real(at: a))
        case .string: .string(string(descriptorAt: a))
        }
    }

    func integer(at a: UInt32) -> BasicValue {
        .integer(Int32(bitPattern: word(a)))
    }

    /// A 5-byte real: the mantissa (4 bytes, its top bit the sign, the 1 it
    /// stands for implied), then the exponent (excess &80).
    func real(at a: UInt32) -> Double {
        let exponent = Int(self[a &+ 4])
        guard exponent != 0 else { return 0 }
        let stored = word(a)
        let magnitude = Double(stored | 0x8000_0000) * pow(2, Double(exponent - 0x80 - 32))
        return stored & 0x8000_0000 != 0 ? -magnitude : magnitude
    }

    static func encodeReal(_ x: Double) -> [UInt8] {
        guard x != 0, x.isFinite else { return [0, 0, 0, 0, 0] }
        var exponent = Int(x.magnitude.exponent) + 1
        var mantissa = (x.magnitude.significand * pow(2, 31)).rounded()
        if mantissa >= pow(2, 32) {
            mantissa /= 2
            exponent += 1
        }
        guard exponent + 0x80 > 0 else { return [0, 0, 0, 0, 0] }
        let m = UInt32(min(mantissa, Double(UInt32.max))) & 0x7FFF_FFFF | (x < 0 ? 0x8000_0000 : 0)
        return [UInt8(m & 0xFF), UInt8(m >> 8 & 0xFF), UInt8(m >> 16 & 0xFF), UInt8(m >> 24), UInt8(min(exponent + 0x80, 0xFF))]
    }

    /// A string variable's text, from its descriptor: address, length.
    func string(descriptorAt a: UInt32) -> String {
        let address = word(a)
        let length = UInt32(self[a &+ 4])
        guard length > 0 else { return "" }
        return Self.text(bytes(address..<address &+ length))
    }

    /// The space a string has: BASIC gives them whole words.
    func capacity(descriptorAt a: UInt32) -> Int {
        let length = Int(self[a &+ 4])
        return length == 0 ? 0 : (length + 3) & ~3
    }

    /// A string at an address, to its CR ($address).
    func string(at address: UInt32) -> String {
        var bytes: [UInt8] = []
        while bytes.count < 255, self[address &+ UInt32(bytes.count)] != 0x0D { bytes.append(self[address &+ UInt32(bytes.count)]) }
        return Self.text(bytes)
    }

    static func text(_ bytes: [UInt8]) -> String {
        String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
    }

    /// Writes a scalar's value; false if it's the wrong kind, or a string
    /// longer than the space it has.
    func set(_ kind: BasicVariable.Kind, at a: UInt32, to value: BasicValue) -> Bool {
        var bytes: [UInt8]
        var at = a
        switch (kind, value) {
        case (.integer, .integer(let n)):
            bytes = withUnsafeBytes(of: n.littleEndian, Array.init)
        case (.integer, .real(let x)):
            guard x.rounded(.towardZero) >= Double(Int32.min), x.rounded(.towardZero) <= Double(Int32.max) else { return false }
            bytes = withUnsafeBytes(of: Int32(x.rounded(.towardZero)).littleEndian, Array.init)
        case (.real, _):
            guard let x = value.number else { return false }
            bytes = Self.encodeReal(x)
        case (.string, .string(let s)):
            let text = s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
            guard text.count <= capacity(descriptorAt: a) || text.isEmpty else { return false }
            let address = word(a)
            for (i, byte) in text.enumerated() where !write(address &+ UInt32(i), byte) { return false }
            at = a &+ 4
            bytes = [UInt8(text.count)]
        default:
            return false
        }
        for (i, byte) in bytes.enumerated() where !write(at &+ UInt32(i), byte) { return false }
        return true
    }
}
