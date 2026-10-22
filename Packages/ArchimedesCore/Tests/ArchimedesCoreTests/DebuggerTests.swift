import Foundation
import XCTest
@testable import ArchimedesCore

/// The debugger on a small program in physical RAM (run in SVC mode):
///
///     +00  MOV R0, #0
///     +04  loop: ADD R0, R0, #1
///     +08  BL sub
///     +0C  STR R0, [R1]          ; R1 = data
///     +10  LDR R2, [R1]
///     +14  B loop
///     +20  sub: ADD R3, R3, #1
///     +24  MOV PC, R14
final class DebuggerTests: XCTestCase {
    let base: UInt32 = 0x0200_1000
    var data: UInt32 { base + 0x100 }

    func machine() throws -> Machine {
        let m = try syntheticMachine()
        _ = m.memc.readWord(0x0380_0000, sequential: false) // leave the reset overlay
        let program: [UInt32] = [
            A.dpi(.mov, rd: 0, imm: 0),
            A.dpi(.add, rd: 0, rn: 0, imm: 1),
            A.b(from: base + 0x08, to: base + 0x20, link: true),
            A.str(rd: 0, rn: 1),
            A.ldr(rd: 2, rn: 1),
            A.b(from: base + 0x14, to: base + 0x04),
            A.nop, A.nop,
            A.dpi(.add, rd: 3, rn: 3, imm: 1),
            A.dpr(.mov, rd: 15, rm: 14),
        ]
        m.memc.write(program: program, at: base)
        m.cpu.setRegister(15, base | 0x0C00_0003) // SVC, interrupts off
        m.cpu.r[1] = data
        return m
    }

    func testExecuteBreakpointStopsBeforeTheInstructionAndContinues() throws {
        let m = try machine()
        let d = m.debugger
        try d.addBreakpoint(.init(id: 0, kind: .execute, start: base + 0x20))
        XCTAssertEqual(m.run(seconds: 0.01), .stopped)
        XCTAssertEqual(m.cpu.pc, base + 0x20)
        XCTAssertEqual(m.cpu.r[3], 0, "stopped before the ADD")
        XCTAssertEqual(d.stopReason, .breakpoint(id: 1, address: base + 0x20, kind: .execute))
        XCTAssertEqual(m.run(seconds: 0.01), .stopped, "runs return at once while stopped")
        XCTAssertEqual(m.cpu.r[3], 0)
        d.resume()
        XCTAssertEqual(m.run(seconds: 0.01), .stopped)
        XCTAssertEqual(m.cpu.r[3], 1, "continuing ran the ADD, then the next pass stopped")
        XCTAssertEqual(d.breakpoints[0].hitCount, 2)
    }

    func testConditionsHitCountsAndLogPoints() throws {
        let m = try machine()
        let d = m.debugger
        try d.addBreakpoint(.init(id: 0, kind: .execute, start: base + 0x20, condition: "R0 == 5 && [&2001003] == &E3"))
        m.run(seconds: 0.01)
        XCTAssertEqual(m.cpu.r[0], 5)
        d.removeAllBreakpoints()
        try d.addBreakpoint(.init(id: 0, kind: .execute, start: base + 0x20, hitTarget: 3))
        d.resume()
        m.run(seconds: 0.01)
        XCTAssertEqual(m.cpu.r[0], 8, "third hit after the condition's stop")
        d.removeAllBreakpoints()
        try d.addBreakpoint(.init(id: 0, kind: .execute, start: base + 0x20, logMessage: "R0={R0} R3={R3}"))
        d.resume()
        m.run(ticks: 2000)
        XCTAssertFalse(d.isStopped, "log points don't stop")
        XCTAssertGreaterThan(d.log.count, 3)
        XCTAssertEqual(d.log.first?.text, "R0=&9 R3=&8")
    }

    func testWatchpointsStopAfterTheAccessingInstruction() throws {
        let m = try machine()
        let d = m.debugger
        try d.addBreakpoint(.init(id: 0, kind: .write, start: data))
        m.run(seconds: 0.01)
        XCTAssertEqual(m.cpu.pc, base + 0x10, "after the STR")
        XCTAssertEqual(d.stopReason, .breakpoint(id: 1, address: data, kind: .write))
        d.removeAllBreakpoints()
        try d.addBreakpoint(.init(id: 0, kind: .read, start: data, end: data + 3))
        d.resume()
        m.run(seconds: 0.01)
        XCTAssertEqual(m.cpu.pc, base + 0x14, "after the LDR")
    }

    func testStepIntoOverAndOut() throws {
        let m = try machine()
        let d = m.debugger
        try d.addBreakpoint(.init(id: 0, kind: .execute, start: base + 0x08))
        m.run(seconds: 0.01)
        d.removeAllBreakpoints()
        let advance: (UInt64) -> Void = { m.run(ticks: $0) }
        d.run(.stepOver, maxTicks: 240_000, advance: advance)
        XCTAssertEqual(m.cpu.pc, base + 0x0C)
        XCTAssertEqual(m.cpu.r[3], 1, "the subroutine ran")
        d.run(.stepInstruction, maxTicks: 240_000, advance: advance)
        XCTAssertEqual(m.cpu.pc, base + 0x10)
        for _ in 0..<3 { d.run(.stepInstruction, maxTicks: 240_000, advance: advance) }
        XCTAssertEqual(m.cpu.pc, base + 0x08)
        d.run(.stepInstruction, maxTicks: 240_000, advance: advance)
        XCTAssertEqual(m.cpu.pc, base + 0x20, "into the BL")
        d.run(.stepOut, maxTicks: 240_000, advance: advance)
        XCTAssertEqual(m.cpu.pc, base + 0x0C, "out to the return address")
        XCTAssertEqual(d.stopReason, .stepped)
        d.run(.runToAddress(base + 0x14), maxTicks: 240_000, advance: advance)
        XCTAssertEqual(m.cpu.pc, base + 0x14)
    }

    func testTraceAndProfiler() throws {
        let m = try machine()
        let d = m.debugger
        d.setTracing(100)
        d.startProfiling()
        m.run(ticks: 24_000)
        d.stopProfiling()
        let trace = try XCTUnwrap(d.trace)
        XCTAssertEqual(trace.count, 100)
        XCTAssertTrue(trace.last(8).allSatisfy { $0.pc >= base && $0.pc < base + 0x28 })
        let r = try XCTUnwrap(d.profiler).report(top: 10, symbols: d.symbols)
        XCTAssertEqual(r.hottest.count, 8, "the eight instructions of the loop")
        XCTAssertGreaterThan(r.totalTicks, 20_000)
        XCTAssertEqual(r.interruptTicks, 0)
        d.setTracing(0)
        XCTAssertFalse(m.cpu.debugHooks, "hooks off once nothing needs them")
    }

    func testExpressions() throws {
        let m = try machine()
        let d = m.debugger
        m.cpu.r[5] = 0x41
        XCTAssertEqual(try d.evaluate("R5 == &41 && MODE == 3"), 1)
        XCTAssertEqual(try d.evaluate("{&2001000} & &FF"), 0)        // the MOV's low byte
        XCTAssertEqual(try d.evaluate("(PC - &2001000) / 4 + %101"), 5)
        XCTAssertEqual(try d.evaluate("Vector_IRQVector + 4"), 0x1C)
        XCTAssertEqual(try d.evaluate("-1 & &FF"), 0xFF)
        XCTAssertThrowsError(try d.evaluate("R5 +"))
        XCTAssertThrowsError(try d.evaluate("nosuchname"))
        XCTAssertEqual(d.interpolate("pc={PC} bad={x?"), "pc=&2001000 bad={x?")
    }

    /// Back through the rewind history: the previous instruction, and the
    /// last time a watchpoint would have hit, exactly.
    func testStepBackAndReverseContinue() throws {
        let m = try machine()
        let r = Rewinder(intervalSeconds: 0.0005, capacity: 400)
        r.attach(m)
        for _ in 0..<40 { m.run(ticks: 6_000); r.captureIfDue(m) }
        let now = m.cpu.instructionCount
        let r0 = m.cpu.r[0]

        try m.debugger.addBreakpoint(.init(id: 0, kind: .write, start: data))
        let back = try m.debugger.reverseContinue(r)
        XCTAssertEqual(back.cpu.pc, base + 0x10, "just after the last STR")
        XCTAssertLessThan(back.cpu.instructionCount, now)
        XCTAssertEqual(back.debugger.stopReason, .breakpoint(id: 1, address: data, kind: .write))
        XCTAssertEqual(back.memc.debugReadWord(data, space: .logical), back.cpu.r[0])
        XCTAssertTrue(back.cpu.r[0] == r0 || back.cpu.r[0] == r0 - 1)

        let count = back.cpu.instructionCount
        let previous = try back.debugger.stepBack(r)
        XCTAssertEqual(previous.cpu.instructionCount, count - 1)
        XCTAssertEqual(previous.cpu.pc, base + 0x0C, "the STR itself")
        XCTAssertEqual(previous.debugger.breakpoints.count, 1, "breakpoints come along")
    }

    func testSWINamesInDisassembly() {
        XCTAssertEqual(Disassembler.disassemble(0xEF00_0000, at: 0), "SWI OS_WriteC")
        XCTAssertEqual(Disassembler.disassemble(0xEF06_00C7, at: 0), "SWI XWimp_Poll")
        XCTAssertEqual(Disassembler.disassemble(0xEF00_0141, at: 0), "SWI OS_WriteI+'A'")
    }
}

final class DebuggerROMTests: XCTestCase {
    /// A breakpoint on the IRQ vector stops with the PC there, in IRQ mode,
    /// before its instruction runs.
    func testBreakpointOnIRQVector() throws {
        guard let dir = GameSmokeTests.romDir("riscos3_11") else { throw XCTSkip("RISC OS 3.11 ROM not present") }
        var c = MachineConfiguration()
        c.romPaths = [dir]
        c.powerOnKeys = [0x34]
        let m = try Machine(configuration: c)
        m.powerOn()
        m.run(seconds: 15) // interrupts are off for the first seconds of the boot
        try m.debugger.addBreakpoint(.init(id: 0, kind: .execute, start: 0x18))
        XCTAssertEqual(m.run(seconds: 1), .stopped)
        XCTAssertEqual(m.cpu.pc, 0x18)
        XCTAssertEqual(m.cpu.mode, .irq)
        let before = m.cpu.instructionCount
        m.debugger.removeAllBreakpoints()
        m.debugger.resume()
        m.run(ticks: 100)
        XCTAssertGreaterThan(m.cpu.instructionCount, before)
    }
}

final class RewindReplayTests: XCTestCase {
    /// Live key presses are recorded on their ticks and replayed, so going
    /// back and running forward again reaches exactly the same state.
    func testRewindReplaysLiveInput() throws {
        guard let dir = GameSmokeTests.romDir("riscos3_11") else { throw XCTSkip("RISC OS 3.11 ROM not present") }
        var c = MachineConfiguration()
        c.romPaths = [dir]
        c.powerOnKeys = [0x34]
        let m = try Machine(configuration: c)
        m.powerOn()
        m.run(seconds: 20)
        let r = Rewinder()
        r.attach(m)
        r.capture(m)
        m.keyDown(0x0C); m.run(seconds: 0.1); m.keyUp(0x0C) // F12
        m.run(seconds: 0.5)
        for code: UInt8 in [0x3C, 0x2B, 0x3B, 0x1D, 0x47] { // types a few letters, live
            m.keyDown(code); m.run(seconds: 0.05); m.keyUp(code); m.run(seconds: 0.05)
        }
        m.run(seconds: 0.3)
        let end = m.ticks
        let expected = m.stateSections()
        // Going back to the start and forward to the end again replays the
        // presses (MACH holds only run bookkeeping, which may differ).
        let back = try XCTUnwrap(r.machine(at: end, from: m))
        XCTAssertGreaterThan(back.ticks, r.points.first!.ticks)
        back.run(untilTick: end)
        XCTAssertEqual(back.ticks, end)
        for ((t, x), (_, y)) in zip(expected, back.stateSections()) where t != "MACH" { XCTAssertEqual(x, y, "section \(t) differs") }
    }
}
