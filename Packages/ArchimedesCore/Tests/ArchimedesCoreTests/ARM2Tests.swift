import XCTest
@testable import ArchimedesCore

final class ARM2Tests: XCTestCase {

    // MARK: Reset

    func testResetState() {
        let h = CPUHarness()
        XCTAssertEqual(h.cpu.mode, .supervisor)
        XCTAssertEqual(h.cpu.pc, 0)
        XCTAssertEqual(h.cpu.psr & 0x0C00_0000, 0x0C00_0000, "I and F set on reset")
    }

    // MARK: Data processing arithmetic and flags

    func testAddFlags() {
        let h = CPUHarness()
        h.cpu.r[1] = 0xFFFF_FFFF; h.cpu.r[2] = 1
        h.exec([A.dpr(.add, s: true, rd: 0, rn: 1, rm: 2)])
        XCTAssertEqual(h.cpu.r[0], 0)
        XCTAssertTrue(h.z); XCTAssertTrue(h.c); XCTAssertFalse(h.v); XCTAssertFalse(h.n)

        h.cpu.r[1] = 0x7FFF_FFFF; h.cpu.r[2] = 1
        h.exec([A.dpr(.add, s: true, rd: 0, rn: 1, rm: 2)])
        XCTAssertEqual(h.cpu.r[0], 0x8000_0000)
        XCTAssertTrue(h.n); XCTAssertTrue(h.v); XCTAssertFalse(h.c); XCTAssertFalse(h.z)
    }

    func testSubAndCompareFlags() {
        let h = CPUHarness()
        h.cpu.r[1] = 5; h.cpu.r[2] = 5
        h.exec([A.dpr(.cmp, s: true, rn: 1, rm: 2)])
        XCTAssertTrue(h.z); XCTAssertTrue(h.c, "no borrow sets C"); XCTAssertFalse(h.v)

        h.cpu.r[1] = 4; h.cpu.r[2] = 5
        h.exec([A.dpr(.sub, s: true, rd: 0, rn: 1, rm: 2)])
        XCTAssertEqual(h.cpu.r[0], 0xFFFF_FFFF)
        XCTAssertTrue(h.n); XCTAssertFalse(h.c, "borrow clears C")

        h.cpu.r[1] = 0x8000_0000; h.cpu.r[2] = 1
        h.exec([A.dpr(.sub, s: true, rd: 0, rn: 1, rm: 2)])
        XCTAssertEqual(h.cpu.r[0], 0x7FFF_FFFF)
        XCTAssertTrue(h.v); XCTAssertTrue(h.c)
    }

    func testAdcSbcRscCarryChains() {
        let h = CPUHarness()
        // 64-bit add: (R1:R0) = (0x1:0xFFFFFFFF) + (0x0:0x1)
        h.cpu.r[0] = 0xFFFF_FFFF; h.cpu.r[1] = 1; h.cpu.r[2] = 1; h.cpu.r[3] = 0
        h.exec([A.dpr(.add, s: true, rd: 0, rn: 0, rm: 2), A.dpr(.adc, s: true, rd: 1, rn: 1, rm: 3)])
        XCTAssertEqual(h.cpu.r[0], 0); XCTAssertEqual(h.cpu.r[1], 2)

        // 64-bit subtract: (0x2:0x0) - (0x0:0x1) = (0x1:0xFFFFFFFF)
        h.cpu.r[0] = 0; h.cpu.r[1] = 2; h.cpu.r[2] = 1; h.cpu.r[3] = 0
        h.exec([A.dpr(.sub, s: true, rd: 0, rn: 0, rm: 2), A.dpr(.sbc, s: true, rd: 1, rn: 1, rm: 3)])
        XCTAssertEqual(h.cpu.r[0], 0xFFFF_FFFF); XCTAssertEqual(h.cpu.r[1], 1)

        // RSC with carry clear: op2 - Rn - 1
        h.setFlags(c: false)
        h.cpu.r[1] = 3
        h.exec([A.dpi(.rsc, rd: 0, rn: 1, imm: 10)])
        XCTAssertEqual(h.cpu.r[0], 6)
        // SBC with zero result and carry boundary: 0 - 0 - 1 with C clear
        h.setFlags(c: false)
        h.cpu.r[1] = 0
        h.exec([A.dpi(.sbc, s: true, rd: 0, rn: 1, imm: 0)])
        XCTAssertEqual(h.cpu.r[0], 0xFFFF_FFFF); XCTAssertFalse(h.c)
        h.setFlags(c: true)
        h.exec([A.dpi(.sbc, s: true, rd: 0, rn: 1, imm: 0)])
        XCTAssertEqual(h.cpu.r[0], 0); XCTAssertTrue(h.c); XCTAssertTrue(h.z)
    }

    func testLogicalOpsPreserveOverflowAndUseShifterCarry() {
        let h = CPUHarness()
        h.setFlags(v: true)
        h.cpu.r[1] = 0x8000_0001
        h.exec([A.dpr(.mov, s: true, rd: 0, rm: 1, shift: .lsr, amount: 1)])
        XCTAssertEqual(h.cpu.r[0], 0x4000_0000)
        XCTAssertTrue(h.c, "carry out = bit 0")
        XCTAssertTrue(h.v, "V unaffected by logical ops")
    }

    func testImmediateRotationCarry() {
        let h = CPUHarness()
        h.setFlags(c: false)
        // MOVS R0, #0xF0000000 (rotated immediate sets C from bit 31)
        h.exec([A.dpi(.mov, s: true, rd: 0, imm: 0xF000_0000)])
        XCTAssertEqual(h.cpu.r[0], 0xF000_0000)
        XCTAssertTrue(h.c); XCTAssertTrue(h.n)
        // Unrotated immediate leaves C unchanged
        h.exec([A.dpi(.mov, s: true, rd: 0, imm: 1)])
        XCTAssertTrue(h.c)
    }

    // MARK: Shifter special cases

    func testImmediateShiftSpecialEncodings() {
        let h = CPUHarness()
        h.cpu.r[1] = 0x8000_0000
        // LSR #0 means LSR #32
        h.exec([A.dpr(.mov, s: true, rd: 0, rm: 1, shift: .lsr, amount: 0)])
        XCTAssertEqual(h.cpu.r[0], 0); XCTAssertTrue(h.c); XCTAssertTrue(h.z)
        // ASR #0 means ASR #32
        h.exec([A.dpr(.mov, s: true, rd: 0, rm: 1, shift: .asr, amount: 0)])
        XCTAssertEqual(h.cpu.r[0], 0xFFFF_FFFF); XCTAssertTrue(h.c)
        // ROR #0 means RRX
        h.setFlags(c: true)
        h.cpu.r[1] = 0x0000_0002
        h.exec([A.dpr(.mov, s: true, rd: 0, rm: 1, shift: .ror, amount: 0)])
        XCTAssertEqual(h.cpu.r[0], 0x8000_0001); XCTAssertFalse(h.c)
        // LSL #0 leaves C unchanged
        h.setFlags(c: true)
        h.exec([A.dpr(.mov, s: true, rd: 0, rm: 1, shift: .lsl, amount: 0)])
        XCTAssertEqual(h.cpu.r[0], 2); XCTAssertTrue(h.c)
    }

    func testRegisterShiftAmounts() {
        let h = CPUHarness()
        func shift(_ v: UInt32, _ type: A.Shift, _ amount: UInt32, carryIn: Bool = false) -> (UInt32, Bool) {
            h.setFlags(c: carryIn)
            h.cpu.r[1] = v; h.cpu.r[2] = amount
            h.exec([A.dprs(.mov, s: true, rd: 0, rm: 1, shift: type, rs: 2)])
            return (h.cpu.r[0], h.c)
        }
        XCTAssertTrue(shift(0x1234, .lsl, 0, carryIn: true) == (0x1234, true))
        XCTAssertTrue(shift(1, .lsl, 32) == (0, true))
        XCTAssertTrue(shift(1, .lsl, 33) == (0, false))
        XCTAssertTrue(shift(0x8000_0000, .lsr, 32) == (0, true))
        XCTAssertTrue(shift(0x8000_0000, .lsr, 40) == (0, false))
        XCTAssertTrue(shift(0x8000_0000, .asr, 200) == (0xFFFF_FFFF, true))
        XCTAssertTrue(shift(0x8000_0001, .ror, 32) == (0x8000_0001, true))
        XCTAssertTrue(shift(0x0000_0003, .ror, 33) == (0x8000_0001, true))
        // Only the bottom byte of Rs counts
        XCTAssertTrue(shift(1, .lsl, 0x101) == (2, false))
    }

    // MARK: R15 semantics

    func testPCReadIsAddressPlus8AndPlus12ForRegisterShift() {
        let h = CPUHarness()
        h.cpu.r[2] = 0
        h.exec([A.dpr(.mov, rd: 0, rm: 15)], at: 0x8000)
        // Rm=R15 includes the PSR bits (SVC mode, I+F set)
        XCTAssertEqual(h.cpu.r[0], 0x8008 | 0x0C00_0003)
        h.exec([A.dprs(.add, rd: 0, rn: 15, rm: 2, shift: .lsl, rs: 2)], at: 0x8000)
        XCTAssertEqual(h.cpu.r[0], 0x800C, "Rn=PC with register shift reads PC+12 without PSR")
        h.exec([A.dpi(.add, rd: 0, rn: 15, imm: 0)], at: 0x8000)
        XCTAssertEqual(h.cpu.r[0], 0x8008, "Rn=PC excludes PSR")
    }

    func testStrPCStoresPlus12WithPSR() {
        let h = CPUHarness()
        h.cpu.r[1] = 0x1000
        h.exec([A.str(rd: 15, rn: 1)], at: 0x8000)
        XCTAssertEqual(h.bus.word(0x1000), 0x800C | 0x0C00_0003)
    }

    func testMovPCWithoutSDoesNotChangePSR() {
        let h = CPUHarness()
        h.setFlags(z: true)
        h.cpu.r[14] = 0x9000 | 0xF000_0000 // flags in the value must be ignored
        h.load([A.dpr(.mov, rd: 15, rm: 14)])
        h.run(1)
        XCTAssertEqual(h.cpu.pc, 0x9000)
        XCTAssertTrue(h.z); XCTAssertFalse(h.n)
        XCTAssertEqual(h.cpu.mode, .supervisor)
    }

    func testMovsPCRestoresFullPSRInPrivilegedMode() {
        let h = CPUHarness()
        // Return to user mode with N set and interrupts enabled.
        h.cpu.r[14] = 0x8000_0000 | 0xA000 | 0 // USR mode
        h.load([A.dpr(.mov, s: true, rd: 15, rm: 14)])
        h.run(1)
        XCTAssertEqual(h.cpu.pc, 0xA000)
        XCTAssertEqual(h.cpu.mode, .user)
        XCTAssertTrue(h.n)
        XCTAssertEqual(h.cpu.psr & 0x0C00_0000, 0, "I and F cleared")
    }

    func testMovsPCInUserModeOnlyChangesFlags() {
        let h = CPUHarness()
        h.enter(.user)
        h.cpu.psr &= ~0x0C00_0000
        h.cpu.r[14] = 0xF000_0000 | 0x0C00_0000 | 0xA000 | 3 // tries to set I, F and SVC
        h.load([A.dpr(.mov, s: true, rd: 15, rm: 14)])
        h.run(1)
        XCTAssertEqual(h.cpu.mode, .user)
        XCTAssertEqual(h.cpu.psr & 0x0C00_0000, 0)
        XCTAssertTrue(h.n && h.z && h.c && h.v)
    }

    func testTeqpChangesModeAndBanks() {
        let h = CPUHarness()
        h.cpu.r[13] = 0x5555 // SVC R13
        // TEQP PC, #0x0C000002 -> IRQ mode with I and F set (PC operand has no PSR)
        h.exec([A.dpi(.teq, s: true, rd: 15, rn: 15, imm: 0x0C00_0002)])
        XCTAssertEqual(h.cpu.mode, .irq)
        XCTAssertNotEqual(h.cpu.r[13], 0x5555)
        h.cpu.r[13] = 0x6666
        h.exec([A.dpi(.teq, s: true, rd: 15, rn: 15, imm: 0x0C00_0003)])
        XCTAssertEqual(h.cpu.mode, .supervisor)
        XCTAssertEqual(h.cpu.r[13], 0x5555)
        XCTAssertEqual(h.cpu.bankedRegisters(.irq)[5], 0x6666)
    }

    func testFIQBanksR8ToR14() {
        let h = CPUHarness()
        for i in 8...14 { h.cpu.r[i] = UInt32(i) }
        h.exec([A.dpi(.teq, s: true, rd: 15, rn: 15, imm: 0x0C00_0001)])
        XCTAssertEqual(h.cpu.mode, .fiq)
        for i in 8...14 { h.cpu.r[i] = UInt32(100 + i) }
        h.exec([A.dpi(.teq, s: true, rd: 15, rn: 15, imm: 0x0C00_0003)])
        for i in 8...12 { XCTAssertEqual(h.cpu.r[i], UInt32(i), "R\(i) restored") }
        XCTAssertEqual(h.cpu.bankedRegisters(.fiq), (8...14).map { UInt32(100 + $0) })
    }

    func testTstWithoutSIsNoOpOnARM2() {
        let h = CPUHarness()
        h.setFlags(z: true)
        h.cpu.r[0] = 0x1234
        // Encoding of MRS R0, CPSR on ARMv3: TST with S=0. ARM2 must ignore it.
        h.exec([0xE10F_0000])
        XCTAssertEqual(h.cpu.r[0], 0x1234)
        XCTAssertTrue(h.z)
        XCTAssertEqual(h.cpu.exceptionCounts[1], 0)
    }

    // MARK: Conditions

    func testAllConditionCodes() {
        let h = CPUHarness()
        for flags in 0..<16 {
            let n = flags & 8 != 0, z = flags & 4 != 0, c = flags & 2 != 0, v = flags & 1 != 0
            let expected: [Bool] = [z, !z, c, !c, n, !n, v, !v, c && !z, !c || z, n == v, n != v, !z && n == v, z || n != v, true, false]
            for cond in 0..<16 {
                h.setFlags(n: n, z: z, c: c, v: v)
                h.cpu.r[0] = 0
                h.exec([A.dpi(.mov, rd: 0, imm: 1, cond: UInt32(cond))])
                XCTAssertEqual(h.cpu.r[0] == 1, expected[cond], "cond \(cond) flags \(flags)")
            }
        }
    }

    // MARK: Loads and stores

    func testUnalignedLoadRotates() {
        let h = CPUHarness()
        h.bus.put(0x1000, 0x4433_2211)
        h.cpu.r[1] = 0x1001
        h.exec([A.ldr(rd: 0, rn: 1)])
        XCTAssertEqual(h.cpu.r[0], 0x1144_3322)
        h.cpu.r[1] = 0x1003
        h.exec([A.ldr(rd: 0, rn: 1)])
        XCTAssertEqual(h.cpu.r[0], 0x3322_1144)
        h.exec([A.ldr(rd: 0, rn: 1, byte: true)])
        XCTAssertEqual(h.cpu.r[0], 0x44)
    }

    func testIndexingAndWriteback() {
        let h = CPUHarness()
        h.bus.put(0x1000, 0xAAAA); h.bus.put(0x1004, 0xBBBB)
        h.cpu.r[1] = 0x1000
        h.exec([A.ldr(rd: 0, rn: 1, offset: 4, pre: false)]) // post-indexed: always writes back
        XCTAssertEqual(h.cpu.r[0], 0xAAAA); XCTAssertEqual(h.cpu.r[1], 0x1004)
        h.exec([A.ldr(rd: 0, rn: 1, offset: -4, pre: true, wb: true)])
        XCTAssertEqual(h.cpu.r[0], 0xAAAA); XCTAssertEqual(h.cpu.r[1], 0x1000)
        h.exec([A.ldr(rd: 0, rn: 1, offset: 4)])
        XCTAssertEqual(h.cpu.r[0], 0xBBBB); XCTAssertEqual(h.cpu.r[1], 0x1000)
        // Load into the base register with writeback: loaded value wins.
        h.exec([A.ldr(rd: 1, rn: 1, offset: 4, pre: false)])
        XCTAssertEqual(h.cpu.r[1], 0xAAAA)
    }

    func testByteStoreAndRegisterOffset() {
        let h = CPUHarness()
        h.cpu.r[0] = 0x1234_56AB; h.cpu.r[1] = 0x1000; h.cpu.r[2] = 2
        // STRB R0, [R1, R2, LSL #1]
        let i: UInt32 = 0xE7C1_0082
        h.exec([i])
        XCTAssertEqual(h.bus.mem[0x1004], 0xAB)
        XCTAssertEqual(h.bus.mem[0x1005], 0)
    }

    func testLdrPCKeepsFlags() {
        let h = CPUHarness()
        h.setFlags(n: true, c: true)
        h.bus.put(0x1000, 0x0000_9000 | 0x4000_0003) // Z set + SVC bits in loaded value
        h.cpu.r[1] = 0x1000
        h.load([A.ldr(rd: 15, rn: 1)])
        h.run(1)
        XCTAssertEqual(h.cpu.pc, 0x9000)
        XCTAssertTrue(h.n); XCTAssertTrue(h.c); XCTAssertFalse(h.z)
    }

    func testAddressException() {
        let h = CPUHarness()
        h.cpu.r[1] = 0x0400_0000
        h.load([A.ldr(rd: 0, rn: 1)], at: 0x8000)
        h.run(1)
        XCTAssertEqual(h.cpu.pc, 0x14)
        XCTAssertEqual(h.cpu.mode, .supervisor)
        XCTAssertEqual(h.cpu.r[14] & 0x03FF_FFFC, 0x8008)
    }

    func testDataAbort() {
        let h = CPUHarness()
        h.bus.abortFrom = 0x80000
        h.cpu.r[1] = 0x90000
        h.cpu.r[0] = 0x77
        h.load([A.ldr(rd: 0, rn: 1)], at: 0x8000)
        h.run(1)
        XCTAssertEqual(h.cpu.pc, 0x10)
        XCTAssertEqual(h.cpu.r[0], 0x77, "destination not written on abort")
        XCTAssertEqual(h.cpu.r[14] & 0x03FF_FFFC, 0x8008)
    }

    func testPrefetchAbort() {
        let h = CPUHarness()
        h.bus.abortFrom = 0x80000
        h.cpu.pc = 0x90000
        h.run(1)
        XCTAssertEqual(h.cpu.pc, 0x0C)
        XCTAssertEqual(h.cpu.r[14] & 0x03FF_FFFC, 0x90004)
    }

    // MARK: Block transfers

    func testBlockTransferAddressingModes() {
        let h = CPUHarness()
        for (pre, up, firstAddr) in [(false, true, UInt32(0x1000)), (true, true, 0x1004), (false, false, 0x0FF8), (true, false, 0x0FF4)] {
            h.bus.mem = [UInt8](repeating: 0, count: 1 << 20)
            h.cpu.r[0] = 0x1000
            h.cpu.r[1] = 1; h.cpu.r[2] = 2; h.cpu.r[3] = 3
            h.exec([A.stm(rn: 0, regs: [1, 2, 3], pre: pre, up: up, wb: true)])
            XCTAssertEqual(h.bus.word(firstAddr), 1)
            XCTAssertEqual(h.bus.word(firstAddr + 4), 2)
            XCTAssertEqual(h.bus.word(firstAddr + 8), 3)
            XCTAssertEqual(h.cpu.r[0], up ? 0x100C : 0x0FF4)
            // Reload with the matching LDM
            h.cpu.r[1] = 0; h.cpu.r[2] = 0; h.cpu.r[3] = 0
            h.exec([A.ldm(rn: 0, regs: [1, 2, 3], pre: !pre, up: !up, wb: true)])
            XCTAssertEqual([h.cpu.r[1], h.cpu.r[2], h.cpu.r[3]], [1, 2, 3])
            XCTAssertEqual(h.cpu.r[0], 0x1000)
        }
    }

    func testStmBaseInListFirstStoresOriginal() {
        let h = CPUHarness()
        h.cpu.r[1] = 0x1000; h.cpu.r[2] = 0x22
        h.exec([A.stm(rn: 1, regs: [1, 2], wb: true)])
        XCTAssertEqual(h.bus.word(0x1000), 0x1000, "base first in list: original value")
        h.cpu.r[2] = 0x2000; h.cpu.r[1] = 0x11
        h.exec([A.stm(rn: 2, regs: [1, 2], wb: true)])
        XCTAssertEqual(h.bus.word(0x2004), 0x2008, "base not first: written-back value")
    }

    func testLdmWithPSRRestore() {
        let h = CPUHarness()
        h.bus.put(0x1000, 0x55)
        h.bus.put(0x1004, 0x2000_0000 | 0xB000 | 0) // C set, USR mode
        h.cpu.r[0] = 0x1000
        h.load([A.ldm(rn: 0, regs: [1, 15], s: true)])
        h.run(1)
        XCTAssertEqual(h.cpu.pc, 0xB000)
        XCTAssertEqual(h.cpu.mode, .user)
        XCTAssertTrue(h.c)
        XCTAssertEqual(h.cpu.r[1], 0x55)

        // Without ^ only the PC is loaded.
        let h2 = CPUHarness()
        h2.bus.put(0x1000, 0xF000_0000 | 0xB000 | 0)
        h2.cpu.r[0] = 0x1000
        h2.load([A.ldm(rn: 0, regs: [15])])
        h2.run(1)
        XCTAssertEqual(h2.cpu.pc, 0xB000)
        XCTAssertEqual(h2.cpu.mode, .supervisor)
        XCTAssertFalse(h2.n)
    }

    func testUserBankTransfers() {
        let h = CPUHarness()
        h.enter(.user)
        h.cpu.r[13] = 0xAAAA; h.cpu.r[14] = 0xBBBB
        h.enter(.supervisor)
        h.cpu.r[13] = 0x1000; h.cpu.r[14] = 0xCCCC
        h.exec([A.stm(rn: 13, regs: [13, 14], s: true)])
        XCTAssertEqual(h.bus.word(0x1000), 0xAAAA)
        XCTAssertEqual(h.bus.word(0x1004), 0xBBBB)
        h.bus.put(0x1000, 0x1111); h.bus.put(0x1004, 0x2222)
        h.exec([A.ldm(rn: 13, regs: [13, 14], s: true)])
        XCTAssertEqual(h.cpu.r[13], 0x1000, "SVC R13 untouched")
        XCTAssertEqual(h.cpu.r[14], 0xCCCC)
        XCTAssertEqual(h.cpu.bankedRegisters(.user)[5], 0x1111)
        XCTAssertEqual(h.cpu.bankedRegisters(.user)[6], 0x2222)
    }

    func testStmR15StoresPCPlus12AndPSR() {
        let h = CPUHarness()
        h.cpu.r[0] = 0x1000
        h.exec([A.stm(rn: 0, regs: [15])], at: 0x8000)
        XCTAssertEqual(h.bus.word(0x1000), 0x800C | 0x0C00_0003)
    }

    // MARK: Branches and exceptions

    func testBranchAndLink() {
        let h = CPUHarness()
        h.setFlags(z: true)
        h.load([A.b(from: 0x8000, to: 0x9000, link: true)], at: 0x8000)
        h.run(1)
        XCTAssertEqual(h.cpu.pc, 0x9000)
        XCTAssertEqual(h.cpu.r[14], 0x8004 | 0x4000_0000 | 0x0C00_0003)
        h.load([A.b(from: 0x9000, to: 0x8000)], at: 0x9000)
        h.run(1)
        XCTAssertEqual(h.cpu.pc, 0x8000)
    }

    func testSWIEntry() {
        let h = CPUHarness()
        h.enter(.user)
        h.cpu.psr &= ~0x0C00_0000
        h.setFlags(c: true)
        h.load([A.swi(0x10)], at: 0x8000)
        h.run(1)
        XCTAssertEqual(h.cpu.pc, 0x08)
        XCTAssertEqual(h.cpu.mode, .supervisor)
        XCTAssertEqual(h.cpu.r[14], 0x8004 | 0x2000_0000, "next instruction + old PSR (USR, C)")
        XCTAssertNotEqual(h.cpu.psr & 0x0800_0000, 0, "IRQs disabled")
        XCTAssertEqual(h.cpu.psr & 0x0400_0000, 0, "FIQ unchanged")
    }

    func testUndefinedInstructionsOnARM2() {
        for instr: UInt32 in [0xE100_0091, // SWP R0, R1, [R0] (ARM3+)
                              0xEE00_0F10, // MCR p15
                              0xEC90_0100, // LDC
                              0xE1D0_00B0, // LDRH (ARMv4)
                              0xE600_0010] { // undefined space
            let h = CPUHarness()
            h.load([instr], at: 0x8000)
            h.run(1)
            XCTAssertEqual(h.cpu.pc, 0x04, String(format: "%08X should be undefined", instr))
            XCTAssertEqual(h.cpu.r[14] & 0x03FF_FFFC, 0x8004)
        }
    }

    func testIRQEntryAndReturnAddress() {
        let h = CPUHarness()
        h.cpu.psr &= ~0x0C00_0000
        h.load([A.nop, A.nop], at: 0x8000)
        h.run(1)
        h.cpu.irqLine = true
        h.run(1) // takes IRQ then executes the first handler instruction at 0x18
        XCTAssertEqual(h.cpu.mode, .irq)
        XCTAssertEqual(h.cpu.r[14] & 0x03FF_FFFC, 0x8008, "SUBS PC, R14, #4 returns to 0x8004")
        XCTAssertEqual(h.cpu.pc, 0x1C)
    }

    func testFIQPriorityAndMasking() {
        let h = CPUHarness()
        h.cpu.psr &= ~0x0C00_0000
        h.load([A.nop], at: 0x8000)
        h.cpu.irqLine = true
        h.cpu.fiqLine = true
        h.run(1)
        XCTAssertEqual(h.cpu.mode, .fiq)
        XCTAssertNotEqual(h.cpu.psr & 0x0C00_0000, 0x0000_0000)
        // Masked: nothing taken
        let h2 = CPUHarness()
        h2.load([A.nop], at: 0x8000)
        h2.cpu.irqLine = true
        h2.run(1)
        XCTAssertEqual(h2.cpu.pc, 0x8004)
    }

    // MARK: Multiply

    func testMultiply() {
        let h = CPUHarness()
        h.cpu.r[1] = 0xFFFF_FFFF; h.cpu.r[2] = 3
        h.exec([A.mul(rd: 0, rm: 1, rs: 2, s: true)])
        XCTAssertEqual(h.cpu.r[0], 0xFFFF_FFFD); XCTAssertTrue(h.n)
        h.cpu.r[3] = 5
        h.exec([A.mla(rd: 0, rm: 1, rs: 2, rn: 3, s: true)])
        XCTAssertEqual(h.cpu.r[0], 2); XCTAssertFalse(h.n); XCTAssertFalse(h.z)
        h.cpu.r[2] = 0
        h.exec([A.mul(rd: 0, rm: 1, rs: 2, s: true)])
        XCTAssertTrue(h.z)
    }

    func testMultiplyTimingEarlyTermination() {
        let h = CPUHarness()
        h.cpu.r[1] = 7; h.cpu.r[2] = 1
        h.load([A.mul(rd: 0, rm: 1, rs: 2)])
        let t0 = h.bus.ticks
        h.run(1)
        let small = h.bus.ticks - t0
        h.cpu.r[2] = 0x8000_0000
        h.load([A.mul(rd: 0, rm: 1, rs: 2)])
        let t1 = h.bus.ticks
        h.run(1)
        let large = h.bus.ticks - t1
        XCTAssertGreaterThan(large, small)
    }

    // MARK: Pipeline

    /// Regression (Elite loader): a store to the very next instruction is not
    /// seen, because the ARM2 has already fetched it.
    func testStoreToNextInstructionDoesNotTakeEffect() {
        let h = CPUHarness()
        h.cpu.r[0] = 0
        h.cpu.r[4] = A.dpi(.mov, rd: 0, imm: 2)
        h.cpu.r[5] = 0x8004
        h.load([A.str(rd: 4, rn: 5), A.dpi(.mov, rd: 0, imm: 1), A.dpi(.mov, rd: 1, imm: 0)], at: 0x8000)
        h.run(2)
        XCTAssertEqual(h.cpu.r[0], 1, "old (prefetched) instruction executed")
        XCTAssertEqual(h.bus.word(0x8004), A.dpi(.mov, rd: 0, imm: 2), "memory was updated")
        // After a branch back the modified instruction is fetched afresh.
        h.load([A.b(from: 0x8008, to: 0x8004)], at: 0x8008)
        h.cpu.pc = 0x8008
        h.run(2)
        XCTAssertEqual(h.cpu.r[0], 2)
    }

    func testStoreTwoInstructionsAheadAlsoNotSeen() {
        let h = CPUHarness()
        h.cpu.r[4] = A.dpi(.mov, rd: 0, imm: 2)
        h.cpu.r[5] = 0x8008
        h.load([A.str(rd: 4, rn: 5), A.nop, A.dpi(.mov, rd: 0, imm: 1), A.dpi(.mov, rd: 3, imm: 9)], at: 0x8000)
        h.run(3)
        XCTAssertEqual(h.cpu.r[0], 1)
        h.run(1)
        XCTAssertEqual(h.cpu.r[3], 9)
    }

    // MARK: Disassembler

    func testDisassembler() {
        XCTAssertEqual(Disassembler.disassemble(A.dpi(.mov, rd: 0, imm: 1), at: 0), "MOV R0, #1")
        XCTAssertEqual(Disassembler.disassemble(A.b(from: 0x8000, to: 0x9000, link: true), at: 0x8000), "BL &9000")
        XCTAssertEqual(Disassembler.disassemble(A.ldm(rn: 13, regs: [0, 1, 2, 3, 15], wb: true, s: true), at: 0), "LDMIA R13!, {R0-R3,PC}^")
        XCTAssertEqual(Disassembler.disassemble(A.swi(0x20000 | 0x10), at: 0), "SWI XOS_GetEnv")
        XCTAssertEqual(Disassembler.disassemble(A.dpi(.teq, s: true, rd: 15, rn: 15, imm: 0x0C00_0003), at: 0), "TEQP PC, #&C000003")
    }
}
