/// ARM2 (26-bit) disassembler producing conventional Acorn-style syntax.
public enum Disassembler {
    static let conds = ["EQ", "NE", "CS", "CC", "MI", "PL", "VS", "VC", "HI", "LS", "GE", "LT", "GT", "LE", "", "NV"]
    static let dpOps = ["AND", "EOR", "SUB", "RSB", "ADD", "ADC", "SBC", "RSC", "TST", "TEQ", "CMP", "CMN", "ORR", "MOV", "BIC", "MVN"]
    static let shifts = ["LSL", "LSR", "ASR", "ROR"]

    static func reg(_ n: UInt32) -> String {
        switch n {
        case 13: return "R13"
        case 14: return "R14"
        case 15: return "PC"
        default: return "R\(n)"
        }
    }

    static func hex(_ v: UInt32) -> String { "&" + String(v, radix: 16, uppercase: true) }

    static func shiftOperand(_ i: UInt32) -> String {
        let rm = reg(i & 0xF)
        let type = (i >> 5) & 3
        if i & 0x10 != 0 {
            return "\(rm), \(shifts[Int(type)]) \(reg((i >> 8) & 0xF))"
        }
        let amount = (i >> 7) & 0x1F
        if amount == 0 {
            switch type {
            case 0: return rm
            case 3: return "\(rm), RRX"
            default: return "\(rm), \(shifts[Int(type)]) #32"
            }
        }
        return "\(rm), \(shifts[Int(type)]) #\(amount)"
    }

    /// With symbols: branch targets show their names.
    public static func disassemble(_ i: UInt32, at address: UInt32, symbols: SymbolTable) -> String {
        var text = disassemble(i, at: address)
        if (i >> 25) & 7 == 5 {
            let offset = UInt32(bitPattern: Int32(bitPattern: i << 8) >> 6)
            let target = (address &+ 8 &+ offset) & 0x03FF_FFFC
            if let name = symbols.describe(target) { text += " ; \(name)" }
        }
        return text
    }

    public static func disassemble(_ i: UInt32, at address: UInt32) -> String {
        let c = conds[Int(i >> 28)]
        switch (i >> 25) & 7 {
        case 0, 1:
            if (i & 0x0FC0_00F0) == 0x0000_0090 {
                let a = i & 0x0020_0000 != 0
                let s = i & 0x0010_0000 != 0 ? "S" : ""
                let rd = reg((i >> 16) & 0xF), rn = reg((i >> 12) & 0xF), rs = reg((i >> 8) & 0xF), rm = reg(i & 0xF)
                return a ? "MLA\(c)\(s) \(rd), \(rm), \(rs), \(rn)" : "MUL\(c)\(s) \(rd), \(rm), \(rs)"
            }
            if (i & 0x0FB0_0FF0) == 0x0100_0090 {
                let b = i & 0x0040_0000 != 0 ? "B" : ""
                return "SWP\(c)\(b) \(reg((i >> 12) & 0xF)), \(reg(i & 0xF)), [\(reg((i >> 16) & 0xF))] ; ARM3/ARM250"
            }
            if (i >> 25) & 7 == 0 && (i & 0x0E00_0090) == 0x0000_0090 {
                return "UND\(c) \(hex(i)) ; (halfword: undefined)"
            }
            let op = Int((i >> 21) & 0xF)
            let s = i & 0x0010_0000 != 0
            let rd = (i >> 12) & 0xF
            let rn = reg((i >> 16) & 0xF)
            let op2: String
            if i & 0x0200_0000 != 0 {
                let rot = (i >> 7) & 0x1E
                let imm = i & 0xFF
                let v = rot == 0 ? imm : (imm >> rot) | (imm << (32 - rot))
                op2 = "#" + (v < 10 ? String(v) : hex(v))
            } else {
                op2 = shiftOperand(i)
            }
            let name = dpOps[op]
            switch op {
            case 8...11:
                if !s { return "NOP\(c) ; \(name) with S=0" }
                let p = rd == 15 ? "P" : ""
                return "\(name)\(c)\(p) \(rn), \(op2)"
            case 13, 15:
                return "\(name)\(c)\(s ? "S" : "") \(reg(rd)), \(op2)"
            default:
                return "\(name)\(c)\(s ? "S" : "") \(reg(rd)), \(rn), \(op2)"
            }
        case 2, 3:
            if (i >> 25) & 7 == 3 && i & 0x10 != 0 { return "UND\(c) \(hex(i))" }
            let l = i & 0x0010_0000 != 0
            let w = i & 0x0020_0000 != 0
            let b = i & 0x0040_0000 != 0
            let u = i & 0x0080_0000 != 0
            let p = i & 0x0100_0000 != 0
            let rd = reg((i >> 12) & 0xF), rn = (i >> 16) & 0xF
            let name = (l ? "LDR" : "STR") + c + (b ? "B" : "") + (!p && w ? "T" : "")
            let sign = u ? "" : "-"
            var off: String
            if i & 0x0200_0000 == 0 {
                let o = i & 0xFFF
                if o == 0 { off = "" } else { off = ", #\(sign)\(o < 10 ? String(o) : hex(o))" }
                if rn == 15 && p && !w {
                    let pcv = address &+ 8
                    let target = u ? pcv &+ o : pcv &- o
                    return "\(name) \(rd), \(hex(target & 0x03FF_FFFF))"
                }
            } else {
                off = ", \(sign)\(shiftOperand(i))"
            }
            if p { return "\(name) \(rd), [\(reg(rn))\(off)]\(w ? "!" : "")" }
            // Post-indexed: "#0" keeps it from reading as pre-indexed.
            return "\(name) \(rd), [\(reg(rn))]\(off.isEmpty ? ", #0" : off)"
        case 4:
            let l = i & 0x0010_0000 != 0
            let w = i & 0x0020_0000 != 0
            let s = i & 0x0040_0000 != 0
            let u = i & 0x0080_0000 != 0
            let p = i & 0x0100_0000 != 0
            let mode = (u ? "I" : "D") + (p ? "B" : "A")
            var regs: [String] = []
            var n = 0
            while n < 16 {
                if i & (1 << n) != 0 {
                    var m = n
                    while m + 1 < 16 && i & (1 << (m + 1)) != 0 { m += 1 }
                    if m > n + 1 { regs.append("\(reg(UInt32(n)))-\(reg(UInt32(m)))"); n = m + 1; continue }
                    regs.append(reg(UInt32(n)))
                }
                n += 1
            }
            return "\(l ? "LDM" : "STM")\(c)\(mode) \(reg((i >> 16) & 0xF))\(w ? "!" : ""), {\(regs.joined(separator: ","))}\(s ? "^" : "")"
        case 5:
            let offset = UInt32(bitPattern: Int32(bitPattern: i << 8) >> 6)
            let target = (address &+ 8 &+ offset) & 0x03FF_FFFC
            return "B\(i & 0x0100_0000 != 0 ? "L" : "")\(c) \(hex(target))"
        case 6:
            // LDC/STC: undefined on these machines (no such coprocessor).
            let l = i & 0x0010_0000 != 0
            let n = i & 0x0040_0000 != 0 ? "L" : ""
            let u = i & 0x0080_0000 != 0, p = i & 0x0100_0000 != 0, w = i & 0x0020_0000 != 0
            let offset = (i & 0xFF) * 4
            let off = offset == 0 ? "" : ", #\(u ? "" : "-")\(offset < 10 ? String(offset) : hex(offset))"
            let rn = reg((i >> 16) & 0xF)
            let address = p ? "[\(rn)\(off)]\(w ? "!" : "")" : "[\(rn)]\(off.isEmpty ? ", #0" : off)"
            return "\(l ? "LDC" : "STC")\(c)\(n) p\((i >> 8) & 0xF), c\((i >> 12) & 0xF), \(address) ; no coprocessor"
        default:
            if i & 0x0100_0000 != 0 { return "SWI\(c) " + (SWINames.name(i & 0x00FF_FFFF) ?? hex(i & 0x00FF_FFFF)) }
            let cp = (i >> 8) & 0xF, crn = (i >> 16) & 0xF, crd = (i >> 12) & 0xF, crm = i & 0xF, op2 = (i >> 5) & 7
            let note = cp == 15 ? " ; ARM3 cache control" : " ; no coprocessor"
            if i & 0x10 != 0 {
                let l = i & 0x0010_0000 != 0
                return "\(l ? "MRC" : "MCR")\(c) p\(cp), \((i >> 21) & 7), \(reg(crd)), c\(crn), c\(crm)\(op2 == 0 ? "" : ", \(op2)")" + note
            }
            return "CDP\(c) p\(cp), \((i >> 20) & 0xF), c\(crd), c\(crn), c\(crm)\(op2 == 0 ? "" : ", \(op2)") ; no coprocessor"
        }
    }
}
