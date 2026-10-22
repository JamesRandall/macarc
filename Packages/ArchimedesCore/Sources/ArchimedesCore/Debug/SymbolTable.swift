import Foundation

/// A line of a source file.
public struct SourceLocation: Sendable, Hashable, CustomStringConvertible {
    public let file: String
    public let line: Int
    public init(file: String, line: Int) { self.file = file; self.line = line }
    public var description: String { "\((file as NSString).lastPathComponent):\(line)" }
}

/// Names for addresses: the built-in ones (exception vectors, the I/O
/// chips' registers) and any loaded from label files or the assembler,
/// which also says which source line made the code at each address.
public struct SymbolTable: Sendable {
    public private(set) var byName: [String: UInt32] = [:]
    public private(set) var byAddress: [UInt32: [String]] = [:]
    public private(set) var lines: [UInt32: SourceLocation] = [:]
    /// File, then line, then the addresses that line made.
    private var byLine: [String: [Int: [UInt32]]] = [:]

    public init() {}

    public var count: Int { byName.count }
    public var lineCount: Int { lines.count }

    public mutating func add(_ name: String, _ address: UInt32) {
        if let old = byName[name] { byAddress[old]?.removeAll { $0 == name } }
        byName[name] = address
        byAddress[address, default: []].append(name)
    }

    public mutating func merge(_ other: SymbolTable) {
        for (n, a) in other.byName { add(n, a) }
        for (a, l) in other.lines { addLine(a, l) }
    }

    // MARK: Source lines

    public mutating func addLine(_ address: UInt32, _ location: SourceLocation) {
        if let old = lines[address] { byLine[old.file]?[old.line]?.removeAll { $0 == address } }
        lines[address] = location
        byLine[location.file, default: [:]][location.line, default: []].append(address)
    }

    public var sourceFiles: Set<String> { Set(byLine.keys) }

    public mutating func removeLines(inFiles files: Set<String>) {
        for f in files {
            for addresses in (byLine[f] ?? [:]).values { for a in addresses { lines[a] = nil } }
            byLine[f] = nil
        }
    }

    /// The source line that made the code at `address`.
    public func location(at address: UInt32) -> SourceLocation? { lines[address] }

    /// The code a source line made: the line itself, or if it made none
    /// (a comment, a label) the next one that did, within 20 lines. `file`
    /// is a full path, or just a file name when only one loaded file has it.
    public func addresses(file: String, line: Int) -> (line: Int, addresses: [UInt32])? {
        guard let table = byLine[(file as NSString).standardizingPath] ?? byLine[file] ?? {
            let name = (file as NSString).lastPathComponent
            let matches = byLine.keys.filter { ($0 as NSString).lastPathComponent == name }
            return matches.count == 1 ? byLine[matches[0]] : nil
        }() else { return nil }
        for l in line..<(line + 20) {
            if let a = table[l], !a.isEmpty { return (l, a.sorted()) }
        }
        return nil
    }

    /// "file.s:12" (a source line with code) to its first address.
    public func address(ofLine text: String) -> UInt32? {
        guard let colon = text.lastIndex(of: ":"), let line = Int(text[text.index(after: colon)...]), colon > text.startIndex else { return nil }
        return addresses(file: String(text[..<colon]), line: line)?.addresses.first
    }

    public func address(of name: String) -> UInt32? {
        if let a = byName[name] { return a }
        let l = name.lowercased()
        return byName.first { $0.key.lowercased() == l }?.value
    }

    public func names(at address: UInt32) -> [String] { byAddress[address] ?? [] }

    /// The nearest name at or below `address` (within 4 KB), with the offset.
    public func nearest(below address: UInt32, within range: UInt32 = 4096) -> (name: String, offset: UInt32)? {
        var best: (String, UInt32)?
        for (a, names) in byAddress where a <= address && address - a < range && !names.isEmpty {
            if best == nil || a > best!.1 { best = (names[0], a) }
        }
        return best.map { ($0.0, address - $0.1) }
    }

    /// "name" or "name+&10" for an address, if one is near.
    public func describe(_ address: UInt32) -> String? {
        guard let n = nearest(below: address) else { return nil }
        return n.offset == 0 ? n.name : n.name + String(format: "+&%X", n.offset)
    }

    // MARK: Built in

    /// The exception vectors and the I/O chips' registers.
    public static let builtIn: SymbolTable = {
        var t = SymbolTable()
        for (i, n) in ["Reset", "UndefinedInstruction", "SWIVector", "PrefetchAbort", "DataAbort", "AddressException", "IRQVector", "FIQVector"].enumerated() {
            t.add("Vector_" + n, UInt32(i * 4))
        }
        let ioc: [(String, UInt32)] = [
            ("IOC_Control", 0x00), ("IOC_KbdData", 0x04), ("IOC_IRQStatusA", 0x10), ("IOC_IRQRequestA", 0x14), ("IOC_IRQMaskA", 0x18),
            ("IOC_IRQStatusB", 0x20), ("IOC_IRQRequestB", 0x24), ("IOC_IRQMaskB", 0x28), ("IOC_FIQStatus", 0x30), ("IOC_FIQRequest", 0x34),
            ("IOC_FIQMask", 0x38), ("IOC_Timer0Low", 0x40), ("IOC_Timer0High", 0x44), ("IOC_Timer0Go", 0x48), ("IOC_Timer0Latch", 0x4C),
            ("IOC_Timer1Low", 0x50), ("IOC_Timer1High", 0x54), ("IOC_Timer1Go", 0x58), ("IOC_Timer1Latch", 0x5C),
            ("IOC_Timer2Low", 0x60), ("IOC_Timer2High", 0x64), ("IOC_Timer2Go", 0x68), ("IOC_Timer2Latch", 0x6C),
            ("IOC_Timer3Low", 0x70), ("IOC_Timer3High", 0x74), ("IOC_Timer3Go", 0x78), ("IOC_Timer3Latch", 0x7C),
        ]
        for (n, o) in ioc { t.add(n, 0x0320_0000 + o) }
        t.add("FDC_WD1772", 0x0321_0000)
        t.add("Latches", 0x0335_0000)
        t.add("VIDC", 0x0340_0000)
        t.add("MEMC_Vinit", 0x0360_0000); t.add("MEMC_Vstart", 0x0362_0000); t.add("MEMC_Vend", 0x0364_0000)
        t.add("MEMC_Cinit", 0x0366_0000); t.add("MEMC_Sstart", 0x0368_0000); t.add("MEMC_SendN", 0x036A_0000)
        t.add("MEMC_Sptr", 0x036C_0000); t.add("MEMC_Control", 0x036E_0000)
        return t
    }()

    // MARK: Loading

    public enum LoadError: Error, CustomStringConvertible {
        case unreadable(String), empty(String)
        public var description: String {
            switch self {
            case .unreadable(let p): return "can't read \(p)"
            case .empty(let p): return "no symbols found in \(p)"
            }
        }
    }

    /// A label file: lines such as `name = &8000`, `name: &8000`,
    /// `name EQU &8000`, `.name &8000`, or nm output (`00008000 T name`).
    public static func load(path: String) throws -> SymbolTable {
        guard let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? (try? String(contentsOfFile: path, encoding: .isoLatin1)) else {
            throw LoadError.unreadable(path)
        }
        let t = parse(text)
        if t.count == 0 { throw LoadError.empty(path) }
        return t
    }

    static func number(_ s: Substring) -> UInt32? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if let semi = t.firstIndex(of: ";") { t = String(t[..<semi]).trimmingCharacters(in: .whitespaces) }
        if t.hasPrefix("&") || t.hasPrefix("$") { return UInt32(t.dropFirst(), radix: 16) }
        if t.hasPrefix("0x") || t.hasPrefix("0X") { return UInt32(t.dropFirst(2), radix: 16) }
        return UInt32(t)
    }

    static func isName(_ s: Substring) -> Bool {
        guard let f = s.first, f.isLetter || f == "_" else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" || $0 == "." }
    }

    public static func parse(_ text: String) -> SymbolTable {
        var t = SymbolTable()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            // nm: 00008000 T name
            if parts.count == 3, parts[1].count == 1, let a = UInt32(parts[0], radix: 16), isName(parts[2]) {
                t.add(String(parts[2]), a); continue
            }
            // name = value, name: value
            if let eq = line.firstIndex(where: { $0 == "=" || $0 == ":" }) {
                let name = line[..<eq].trimmingCharacters(in: .whitespaces)
                if isName(Substring(name)), let a = number(line[line.index(after: eq)...]) { t.add(name, a); continue }
            }
            // name EQU value, .name value
            if parts.count >= 3, parts[1].uppercased() == "EQU" || parts[1] == "*", isName(parts[0]), let a = number(parts[2]) {
                t.add(String(parts[0]), a); continue
            }
            if parts.count >= 2, parts[0].hasPrefix("."), isName(parts[0].dropFirst()), let a = number(parts[1]) {
                t.add(String(parts[0].dropFirst()), a)
            }
        }
        return t
    }
}

/// RISC OS SWI names for the disassembler (the OS's own and the Wimp's;
/// others show as numbers).
public enum SWINames {
    static let os: [String] = [
        "WriteC", "WriteS", "Write0", "NewLine", "ReadC", "CLI", "Byte", "Word", "File", "Args", "BGet", "BPut", "GBPB", "Find",
        "ReadLine", "Control", "GetEnv", "Exit", "SetEnv", "IntOn", "IntOff", "CallBack", "EnterOS", "BreakPt", "BreakCtrl",
        "UnusedSWI", "UpdateMEMC", "SetCallBack", "Mouse", "Heap", "Module", "Claim", "Release", "ReadUnsigned", "GenerateEvent",
        "ReadVarVal", "SetVarVal", "GSInit", "GSRead", "GSTrans", "BinaryToDecimal", "FSControl", "ChangeDynamicArea",
        "GenerateError", "ReadEscapeState", "EvaluateExpression", "SpriteOp", "ReadPalette", "ServiceCall", "ReadVduVariables",
        "ReadPoint", "UpCall", "CallAVector", "ReadModeVariable", "RemoveCursors", "RestoreCursors", "SWINumberToString",
        "SWINumberFromString", "ValidateAddress", "CallAfter", "CallEvery", "RemoveTickerEvent", "InstallKeyHandler",
        "CheckModeValid", "ChangeEnvironment", "ClaimScreenMemory", "ReadMonotonicTime", "SubstituteArgs", "PrettyPrint",
        "Plot", "WriteN", "AddToVector", "WriteEnv", "ReadArgs", "ReadRAMFsLimits", "ClaimDeviceVector", "ReleaseDeviceVector",
        "DelinkApplication", "RelinkApplication", "HeapSort", "ExitAndDie", "ReadMemMapInfo", "ReadMemMapEntries",
        "SetMemMapEntries", "AddCallBack", "ReadDefaultHandler", "SetECFOrigin", "SerialOp", "ReadSysInfo", "Confirm",
        "ChangedBox", "CRC", "ReadDynamicArea", "PrintChar",
    ]
    static let wimp: [String] = [
        "Initialise", "CreateWindow", "CreateIcon", "DeleteWindow", "DeleteIcon", "OpenWindow", "CloseWindow", "Poll",
        "RedrawWindow", "UpdateWindow", "GetRectangle", "GetWindowState", "GetWindowInfo", "SetIconState", "GetIconState",
        "GetPointerInfo", "DragBox", "ForceRedraw", "SetCaretPosition", "GetCaretPosition", "CreateMenu", "DecodeMenu",
        "WhichIcon", "SetExtent", "SetPointerShape", "OpenTemplate", "CloseTemplate", "LoadTemplate", "ProcessKey", "CloseDown",
        "StartTask", "ReportError", "GetWindowOutline", "PollIdle", "PlotIcon", "SetMode", "SetPalette", "ReadPalette",
        "SetColour", "SendMessage", "CreateSubMenu", "SpriteOp", "BaseOfSprites", "BlockCopy", "SlotSize", "ReadPixTrans",
        "ClaimFreeMemory", "CommandWindow", "TextColour", "TransferBlock", "ReadSysInfo", "SetFontColours",
    ]

    /// Every name to its number (OS_ and Wimp_, with and without X, and
    /// OS_WriteI), for the assembler.
    public static let numbers: [String: UInt32] = {
        var t: [String: UInt32] = ["OS_WriteI": 0x100, "XOS_WriteI": 0x20100]
        for (i, n) in os.enumerated() { t["OS_" + n] = UInt32(i); t["XOS_" + n] = UInt32(i) | 0x20000 }
        for (i, n) in wimp.enumerated() { t["Wimp_" + n] = 0x400C0 + UInt32(i); t["XWimp_" + n] = (0x400C0 + UInt32(i)) | 0x20000 }
        return t
    }()

    /// A SWI's number from its name (any case).
    public static func number(_ name: String) -> UInt32? {
        if let n = numbers[name] { return n }
        let l = name.lowercased()
        return numbers.first { $0.key.lowercased() == l }?.value
    }

    /// "OS_WriteC", "XWimp_Poll", "OS_WriteI+'A'", or nil when unknown.
    public static func name(_ swi: UInt32) -> String? {
        let x = swi & 0x20000 != 0 ? "X" : ""
        let n = swi & ~0x20000 & 0xFFFFFF
        if n < os.count { return x + "OS_" + os[Int(n)] }
        if (0x100...0x1FF).contains(n) {
            let c = n - 0x100
            return x + "OS_WriteI" + (c >= 32 && c < 127 ? "+'\(Character(UnicodeScalar(UInt8(c))))'" : String(format: "+&%02X", c))
        }
        if n >= 0x400C0 && n < 0x400C0 + UInt32(wimp.count) { return x + "Wimp_" + wimp[Int(n - 0x400C0)] }
        return nil
    }
}
