import XCTest
@testable import ArchimedesCore

final class AssemblerTests: XCTestCase {
    func words(_ source: String) throws -> [UInt32] {
        let a = try ARMAssembler.assemble(source: source)
        return stride(from: 0, to: a.bytes.count - 3, by: 4).map {
            UInt32(a.bytes[$0]) | UInt32(a.bytes[$0 + 1]) << 8 | UInt32(a.bytes[$0 + 2]) << 16 | UInt32(a.bytes[$0 + 3]) << 24
        }
    }

    func failure(_ source: String) -> String {
        do { _ = try ARMAssembler.assemble(source: source); return "" } catch { return "\(error)" }
    }

    func testEncodings() throws {
        let cases: [(String, UInt32)] = [
            ("MOV R0, #1", 0xE3A0_0001),
            ("MOVS R0, R1", 0xE1B0_0001),
            ("MOV R0, #-1", 0xE3E0_0000),             // as MVN R0, #0
            ("ADDEQS R1, R2, #&FF000000", 0x0292_14FF),
            ("ADDSEQ R1, R2, #&FF000000", 0x0292_14FF),
            ("ADD R0, R0, #-4", 0xE240_0004),         // as SUB
            ("ADD R0, #1", 0xE280_0001),              // Rd is Rn
            ("SUB R0, R1, R2, LSL #2", 0xE041_0102),
            ("ORR R0, R1, R2, ROR R3", 0xE181_0372),
            ("MOV R0, R1, RRX", 0xE1A0_0061),
            ("MOV R0, R1, LSR #32", 0xE1A0_0021),
            ("CMP R0, #-1", 0xE370_0001),             // as CMN
            ("TEQP PC, #0", 0xE33F_F000),
            ("TST R0, #3", 0xE310_0003),
            ("MUL R0, R1, R2", 0xE000_0291),
            ("MLAS R0, R1, R2, R3", 0xE030_3291),
            ("LDR R0, [R1]", 0xE591_0000),
            ("LDR R0, [R1, #4]!", 0xE5B1_0004),
            ("LDRB R0, [R1, #-4]", 0xE551_0004),
            ("STR R0, [R1], #4", 0xE481_0004),
            ("LDRBT R0, [R1], #1", 0xE4F1_0001),
            ("LDR R0, [R1, -R2, LSL #2]", 0xE711_0102),
            ("STR R0, [R1], R2", 0xE681_0002),
            ("STMFD R13!, {R0-R3, R14}", 0xE92D_400F),
            ("LDMFD R13!, {R0-R3, PC}^", 0xE8FD_800F),
            ("LDMIA R0, {R1}", 0xE890_0002),
            ("STMEQIB R0, {R1, R2}", 0x0980_0006),
            ("SWI OS_WriteC", 0xEF00_0000),
            ("SWI \"XOS_Write0\"", 0xEF02_0002),
            ("SWI OS_WriteI+'A'", 0xEF00_0141),
            ("SWINE &400C7", 0x1F04_00C7),
            ("SWP R0, R1, [R2]", 0xE102_0091),
            ("SWPB R0, R1, [R2]", 0xE142_0091),
            ("MCR p15, 0, R0, c2, c0", 0xEE02_0F10),
            ("MRC p15, 0, R1, c0, c0", 0xEE10_1F10),
            ("NOP", 0xE1A0_0000),
            ("MOV a1, sp", 0xE1A0_000D),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(try words(" " + text).first, expected, text)
        }
    }

    func testBranchesLabelsAndData() throws {
        let w = try words("""
                    ORG &9000
            .start  B later         ; forward
            loop:   SUBS R0, R0, #1
                    BNE loop
                    BL start
            later   BLE loop
                    ADR R1, text
                    LDR R2, value
            text    EQUS "Hi", 0
                    ALIGN
            value   EQUD &12345678, start
            count   EQU 3
                    EQUW count, -1
            """)
        XCTAssertEqual(w[0], 0xEA00_0002)   // B &9010
        XCTAssertEqual(w[2], 0x1AFF_FFFD)   // BNE &9004
        XCTAssertEqual(w[3], 0xEBFF_FFFB)   // BL &9000
        XCTAssertEqual(w[4], 0xDAFF_FFFB)   // BLE &9004
        XCTAssertEqual(w[5], 0xE28F_1000)   // ADR R1, &901C (from &9014)
        XCTAssertEqual(w[6], 0xE59F_2000)   // LDR R2, &9020 (from &9018)
        XCTAssertEqual(w[7], 0x0000_6948)   // "Hi\0" and a pad byte
        XCTAssertEqual(w[8], 0x1234_5678)
        XCTAssertEqual(w[9], 0x9000)
        XCTAssertEqual(w[10], 0xFFFF_0003)
    }

    func testLiteralPool() throws {
        let a = try ARMAssembler.assemble(source: """
                    LDR R0, =&12345678
                    LDR R1, =&FF
                    LDR R2, =later
                    MOV PC, R14
                    LTORG
            later   LDR R3, =&ABCDEF01
            """)
        let w = stride(from: 0, to: a.bytes.count, by: 4).map { UInt32(a.bytes[$0]) | UInt32(a.bytes[$0 + 1]) << 8 | UInt32(a.bytes[$0 + 2]) << 16 | UInt32(a.bytes[$0 + 3]) << 24 }
        XCTAssertEqual(w[0], 0xE59F_0008)   // LDR R0, [PC, #8]  -> &8010
        XCTAssertEqual(w[1], 0xE3A0_10FF)   // a MOV
        XCTAssertEqual(w[2], 0xE59F_2004)   // -> &8014
        XCTAssertEqual(w[4], 0x1234_5678)
        XCTAssertEqual(w[5], 0x8018)
        XCTAssertEqual(w[6], 0xE51F_3004)   // LDR R3, [PC, #-4]: the pool is just after it
        XCTAssertEqual(w[7], 0xABCD_EF01)
    }

    func testEntrySymbolsAndLines() throws {
        let a = try ARMAssembler.assemble(source: """
            ; a comment
                    ORG &A000
            data    EQUD 0
                    ENTRY
            .main   MOV R0, #0

                    SWI OS_Exit
            """, file: "/tmp/prog.s")
        XCTAssertEqual(a.origin, 0xA000)
        XCTAssertEqual(a.entry, 0xA004)
        XCTAssertEqual(a.symbols.address(of: "main"), 0xA004)
        XCTAssertEqual(a.symbols.location(at: 0xA004), SourceLocation(file: "/tmp/prog.s", line: 5))
        XCTAssertEqual(a.symbols.addresses(file: "prog.s", line: 6)?.line, 7)       // a blank line: the next with code
        XCTAssertEqual(a.symbols.address(ofLine: "prog.s:7"), 0xA008)
    }

    func testErrorsHaveLines() {
        let e = failure("""
                MOV R0, #&101
                FOO R1
                B nowhere
                LDR R0, [R1, #5000]
            """)
        XCTAssertTrue(e.contains("source.s:1: can't make &101"), e)
        XCTAssertTrue(e.contains("source.s:2: unknown instruction FOO"), e)
        let e2 = failure(" B nowhere\n LDR R0, [R1, #5000]\n MUL R0, R0, R1\n")
        XCTAssertTrue(e2.contains("source.s:1: unknown name nowhere"), e2)
        XCTAssertTrue(e2.contains("source.s:2: offset out of range"), e2)
        XCTAssertTrue(failure(" SWI \"OS_Nonsense\"").contains("unknown SWI"))
        XCTAssertTrue(failure("x EQU 1\nx EQU 2").contains("defined twice"))
    }

    func testIncludes() throws {
        let dir = NSTemporaryDirectory() + "asm-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "value EQU 42\n        MOV R1, #value\n".write(toFile: dir + "/defs.s", atomically: true, encoding: .utf8)
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: dir + "/blob.bin"))
        try " INCLUDE \"defs.s\"\n MOV R0, #value\n INCBIN \"blob.bin\"\n".write(toFile: dir + "/main.s", atomically: true, encoding: .utf8)
        let a = try ARMAssembler.assemble(file: dir + "/main.s")
        XCTAssertEqual(Array(a.bytes.prefix(8)), [42, 0x10, 0xA0, 0xE3, 42, 0x00, 0xA0, 0xE3])
        XCTAssertEqual(Array(a.bytes.suffix(3)), [1, 2, 3])
        XCTAssertEqual(a.symbols.location(at: 0x8000)?.file, dir + "/defs.s")
    }

    /// Whatever the disassembler prints, the assembler takes back to an
    /// instruction that disassembles the same.
    func testRoundTripsTheDisassembler() throws {
        // Seeded, so a failure happens again.
        struct SplitMix: RandomNumberGenerator {
            var state: UInt64
            mutating func next() -> UInt64 {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return z ^ (z >> 31)
            }
        }
        var rng = SplitMix(state: 0x4152_4D32)
        var checked = 0
        for _ in 0..<100_000 {
            let w = UInt32.random(in: 0...UInt32.max, using: &rng)
            let text = Disassembler.disassemble(w, at: 0x8000)
            if text.hasPrefix("UND") || text.hasPrefix("NOP") || text.contains("{}") { continue }
            // Branches and PC-relative loads that wrap round the address space.
            if (w >> 25) & 7 == 5 {
                let target = Int64(0x8008) + Int64(Int32(bitPattern: w << 8) >> 6)
                if target < 0 || target >= 0x400_0000 { continue }
            }
            let code = text.split(separator: ";", maxSplits: 1)[0]
            let back: [UInt32]
            do { back = try words(" ORG &8000\n " + code) } catch {
                XCTFail("\(String(format: "%08X", w)) \(text): \(error)"); continue
            }
            XCTAssertEqual(Disassembler.disassemble(back[0], at: 0x8000), text, String(format: "%08X", w))
            checked += 1
        }
        XCTAssertGreaterThan(checked, 75_000)
    }
}
