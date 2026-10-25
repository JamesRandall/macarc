import XCTest
@testable import ArchimedesCore

final class BasicExpressionTests: XCTestCase {
    func evaluate(_ source: String) throws -> BasicValue {
        let memory = BasicMemory(read: { _ in 0 }, write: { _, _ in false }, workspace: 0x8700)
        let context = BasicExpression.Context(variable: { ["A%": .integer(7), "x": .real(2.5), "s$": .string("hi")][$0] },
                                              element: { $0 == "a(" && $1 == [2] ? .integer(9) : nil }, memory: memory)
        return try BasicExpression(source).evaluate(context)
    }

    func testArithmeticAsBASIC() throws {
        XCTAssertEqual(try evaluate("1+2*3"), .integer(7))
        XCTAssertEqual(try evaluate("(1+2)*3"), .integer(9))
        XCTAssertEqual(try evaluate("7 DIV 2"), .integer(3))
        XCTAssertEqual(try evaluate("7 MOD 2"), .integer(1))
        XCTAssertEqual(try evaluate("7/2"), .real(3.5))
        XCTAssertEqual(try evaluate("2^10"), .real(1024))
        XCTAssertEqual(try evaluate("&FF AND 15"), .integer(15))
        XCTAssertEqual(try evaluate("-A%"), .integer(-7))
        XCTAssertEqual(try evaluate("NOT 0"), .integer(-1))
    }

    func testComparisonsAndLogic() throws {
        XCTAssertEqual(try evaluate("A%=7"), .integer(-1))
        XCTAssertEqual(try evaluate("A%<>7"), .integer(0))
        XCTAssertEqual(try evaluate("x>2 AND A%<=7"), .integer(-1))
        XCTAssertEqual(try evaluate("x>3 OR FALSE"), .integer(0))
        XCTAssertEqual(try evaluate("s$=\"hi\""), .integer(-1))
        XCTAssertEqual(try evaluate("s$+\"!\""), .string("hi!"))
        XCTAssertEqual(try evaluate("a(1+1)"), .integer(9))
    }

    func testErrors() {
        XCTAssertThrowsError(try BasicExpression("1+"))
        XCTAssertThrowsError(try BasicExpression("(1"))
        XCTAssertThrowsError(try evaluate("nope"))
        XCTAssertThrowsError(try evaluate("s$+1"))
        XCTAssertThrowsError(try evaluate("1 DIV 0"))
    }

    func testFormatsRealsAsPRINT() {
        XCTAssertEqual(BasicValue.real(12).description, "12")
        XCTAssertEqual(BasicValue.real(3.5).description, "3.5")
        XCTAssertEqual(BasicValue.real(1.0 / 3).description, "0.333333333")
        XCTAssertEqual(BasicValue.real(1e10).description, "1E10")
    }

    func testEncodesRealsAsBASICV() {
        // 1.5 and -2.25, as BASIC V stores them (seen in memory).
        XCTAssertEqual(BasicMemory.encodeReal(1.5), [0, 0, 0, 0x40, 0x81])
        XCTAssertEqual(BasicMemory.encodeReal(-2.25), [0, 0, 0, 0x90, 0x82])
        for x in [1.0, -2.75, 1e-7, 123456.789, 3e30] {
            let bytes = BasicMemory.encodeReal(x)
            let m = BasicMemory(read: { bytes[Int($0)] }, write: { _, _ in false }, workspace: 0x8700)
            XCTAssertLessThanOrEqual(abs(m.real(at: 0) - x), abs(x) * 1e-9)
        }
    }
}

/// Runs BASIC programs on RISC OS 3 (and 2), under the debugger.
final class BasicDebuggerTests: XCTestCase {
    static let program = """
    10 A%=1
    15 PROCouter
    20 total=0
    30 FOR I%=1 TO 3
    40 PROCadd(I%)
    50 NEXT
    60 name$="DONE":n1%=5:n12%=6:n123%=7:n1234%=8
    70 DIM grid%(2,3)
    75 grid%(1,2)=42
    80 END
    100 DEF PROCadd(N%)
    110 LOCAL T
    120 T=N%*2
    130 total=total+T
    140 ENDPROC
    300 DEF PROCouter
    310 LOCAL Z
    320 Z=1+FNinner(3)
    330 ENDPROC
    400 DEF FNinner(Q)
    410 =Q*2
    """

    /// A machine at BASIC's prompt with `program` loaded.
    func machine(_ program: String = BasicDebuggerTests.program, rom: String = "riscos3_11") throws -> Machine {
        guard let dir = GameSmokeTests.romDir(rom) else { throw XCTSkip("\(rom) ROM not present") }
        var c = MachineConfiguration()
        c.romPaths = [dir]
        c.powerOnKeys = [0x34]
        let m = try Machine(configuration: c)
        m.powerOn()
        m.run(seconds: 20)
        m.keyDown(0x0C); m.run(seconds: 0.1); m.keyUp(0x0C)
        m.run(seconds: 0.5)
        type(m, "BASIC\r")
        try m.debugger.basic.loadAtPrompt(try BasicDebugger.program(fromFile: Array(program.utf8)))
        return m
    }

    func type(_ m: Machine, _ text: String) {
        m.scheduleTyping(text, startingAt: m.nominalTicks, intervalMs: 25)
        m.run(seconds: Double(text.count) * 0.055 + 0.3)
    }

    /// Types `text` (if any) and runs until the debugger stops it, or a
    /// few seconds have passed.
    @discardableResult
    func run(_ m: Machine, _ text: String? = "RUN", seconds: Double = 4) -> Debugger.StopReason? {
        m.debugger.resume()
        if let text { m.scheduleTyping(text + "\r", startingAt: m.nominalTicks, intervalMs: 25) }
        var left = seconds + Double(text?.count ?? 0) * 0.05
        while left > 0 && !m.debugger.isStopped {
            m.run(seconds: 0.1)
            left -= 0.1
        }
        return m.debugger.stopReason
    }

    @discardableResult
    func step(_ m: Machine, _ kind: BasicStep) -> Debugger.StopReason? {
        m.debugger.run(basic: kind, maxTicks: 24_000_000 * 4) { m.run(ticks: $0) }
    }

    func value(_ m: Machine, _ name: String) -> BasicValue? {
        m.debugger.basic.variable(name)?.value
    }

    func testFindsTheInterpreterAndStopsAtABreakpoint() throws {
        for rom in ["riscos3_11", "riscos2_00"] {
            let m = try machine(rom: rom)
            let basic = m.debugger.basic
            XCTAssertTrue(basic.interpreter?.name.hasPrefix("BASIC V") == true, rom)
            try basic.add(BasicBreakpoint(line: 120))
            XCTAssertEqual(run(m), .basicBreakpoint(id: 1, line: 120), rom)
            XCTAssertEqual(basic.stop?.line, 120)
            XCTAssertEqual(basic.stop?.statement, 1)
            XCTAssertEqual(value(m, "N%"), .integer(1))
            XCTAssertEqual(basic.callStack().map(\.name), ["PROCadd", nil], rom)
            XCTAssertEqual(basic.callStack().map { $0.location?.line }, [120, 40], rom)
            XCTAssertEqual(basic.variables().filter(\.isLocal).map(\.name).sorted(), ["N%", "T"], rom)
            // Again for the next time round the loop.
            XCTAssertEqual(run(m, nil), .basicBreakpoint(id: 1, line: 120))
            XCTAssertEqual(value(m, "N%"), .integer(2))
            XCTAssertEqual(value(m, "total"), .real(2))
        }
    }

    func testCallStackThroughAnFNInAnExpression() throws {
        let m = try machine()
        try m.debugger.basic.add(BasicBreakpoint(line: 410))
        XCTAssertEqual(run(m), .basicBreakpoint(id: 1, line: 410))
        let frames = m.debugger.basic.callStack()
        XCTAssertEqual(frames.map(\.name), ["FNinner", "PROCouter", nil])
        XCTAssertEqual(frames.map { $0.location?.line }, [410, 320, 15])
        XCTAssertEqual(value(m, "Q"), .real(3))
    }

    func testSteps() throws {
        let m = try machine()
        let basic = m.debugger.basic
        try basic.add(BasicBreakpoint(line: 40))
        XCTAssertEqual(run(m), .basicBreakpoint(id: 1, line: 40))
        basic.removeAllBreakpoints()
        // Over the PROC.
        XCTAssertEqual(step(m, .over), .basicStepped)
        XCTAssertEqual(basic.stop?.line, 50)
        XCTAssertEqual(value(m, "total"), .real(2))
        XCTAssertEqual(step(m, .over), .basicStepped)
        XCTAssertEqual(basic.stop?.line, 40)
        // Into it, then out again.
        XCTAssertEqual(step(m, .into), .basicStepped)
        XCTAssertEqual(basic.stop?.line, 110)
        XCTAssertEqual(step(m, .into), .basicStepped)
        XCTAssertEqual(basic.stop?.line, 120)
        XCTAssertEqual(step(m, .out), .basicStepped)
        XCTAssertEqual(basic.stop?.line, 50)
        XCTAssertEqual(value(m, "total"), .real(6))
        XCTAssertFalse(m.debugger.isRunningCommand)
    }

    func testStepsOverAnFN() throws {
        let m = try machine()
        let basic = m.debugger.basic
        try basic.add(BasicBreakpoint(line: 320))
        XCTAssertEqual(run(m), .basicBreakpoint(id: 1, line: 320))
        basic.removeAllBreakpoints()
        XCTAssertEqual(step(m, .over), .basicStepped)
        XCTAssertEqual(basic.stop?.line, 330)
        XCTAssertEqual(value(m, "Z"), .real(7))
    }

    func testRecursionWithStringLocals() throws {
        let m = try machine("""
        10 PROCrec(3,"a")
        20 END
        100 DEF PROCrec(N%,s$)
        110 LOCAL t$
        120 t$=s$+"b"
        130 IF N%>0 PROCrec(N%-1,t$)
        140 PRINT N%;s$
        150 ENDPROC
        """)
        let basic = m.debugger.basic
        try basic.add(BasicBreakpoint(line: 140, condition: "N%=0"))
        XCTAssertEqual(run(m), .basicBreakpoint(id: 1, line: 140))
        let frames = basic.callStack()
        XCTAssertEqual(frames.map(\.name), ["PROCrec", "PROCrec", "PROCrec", "PROCrec", nil])
        XCTAssertEqual(frames.map { $0.location?.line }, [140, 130, 130, 130, 10])
        XCTAssertEqual(value(m, "s$"), .string("abbb"))
        XCTAssertEqual(basic.variables().filter(\.isLocal).map(\.name).sorted(), ["N%", "s$", "t$"])
        // Out of one level.
        basic.removeAllBreakpoints()
        XCTAssertEqual(step(m, .out), .basicStepped)
        XCTAssertEqual(basic.stop?.line, 140)
        XCTAssertEqual(value(m, "N%"), .integer(1))
        XCTAssertEqual(basic.callStack().map { $0.location?.line }, [140, 130, 130, 10])
    }

    func testCallStackAtAnErrorPartWayThroughExpressions() throws {
        let m = try machine("""
        10 PROCa
        20 END
        100 DEF PROCa
        110 LOCAL x
        120 x=2+FNb(1)
        130 ENDPROC
        200 DEF FNb(y)
        210 =3+y/0
        """)
        let basic = m.debugger.basic
        basic.errorStop = .untrapped
        XCTAssertEqual(run(m), .basicError(number: 18))
        XCTAssertEqual(basic.error?.message, "Division by zero")
        let frames = basic.callStack()
        XCTAssertEqual(frames.map(\.name), ["FNb", "PROCa", nil])
        XCTAssertEqual(frames.map { $0.location?.line }, [210, 120, 10])
        XCTAssertEqual(basic.variables().filter(\.isLocal).map(\.name), ["y"])
    }

    func testStepsOverAndOutOfGOSUBs() throws {
        let m = try machine("10 GOSUB 100\n20 PRINT \"back\"\n30 GOSUB 100\n40 END\n100 A%=1\n110 A%=2\n120 RETURN")
        let basic = m.debugger.basic
        try basic.add(BasicBreakpoint(line: 10))
        XCTAssertEqual(run(m), .basicBreakpoint(id: 1, line: 10))
        basic.removeAllBreakpoints()
        XCTAssertEqual(step(m, .over), .basicStepped)
        XCTAssertEqual(basic.stop?.line, 20)
        XCTAssertEqual(step(m, .over), .basicStepped)
        XCTAssertEqual(step(m, .into), .basicStepped)
        XCTAssertEqual(basic.stop?.line, 100)
        XCTAssertEqual(step(m, .over), .basicStepped)
        XCTAssertEqual(basic.stop?.line, 110)
        XCTAssertEqual(step(m, .out), .basicStepped)
        XCTAssertEqual(basic.stop?.line, 40)
    }

    func testConditionsHitCountsAndLogPoints() throws {
        let m = try machine()
        let basic = m.debugger.basic
        try basic.add(BasicBreakpoint(line: 130, condition: "N%=3"))
        XCTAssertEqual(run(m), .basicBreakpoint(id: 1, line: 130))
        XCTAssertEqual(value(m, "N%"), .integer(3))
        basic.removeAllBreakpoints()
        try basic.add(BasicBreakpoint(line: 120, hitTarget: 2))
        XCTAssertEqual(run(m), .basicBreakpoint(id: 2, line: 120))
        XCTAssertEqual(value(m, "N%"), .integer(2))
        XCTAssertThrowsError(try basic.add(BasicBreakpoint(line: 10, condition: "1+")))
        basic.removeAllBreakpoints()
        try basic.add(BasicBreakpoint(line: 130, logMessage: "N%={N%} T={T}"))
        XCTAssertNil(run(m))
        XCTAssertEqual(m.debugger.log.map(\.text).suffix(3), ["N%=1 T=2", "N%=2 T=4", "N%=3 T=6"])
    }

    func testALineIsEnteredOncePerLoop() throws {
        let m = try machine("10 FOR I%=1 TO 3:PRINT I%:NEXT\n20 END")
        let basic = m.debugger.basic
        try basic.add(BasicBreakpoint(line: 10))
        var stops: [Int] = []
        var reason = run(m)
        while case .basicBreakpoint = reason {
            stops.append(basic.stop!.statement)
            reason = run(m, nil)
        }
        // FOR, then PRINT each time NEXT goes back.
        XCTAssertEqual(stops, [1, 2, 2])
        // A statement's breakpoint is for that statement.
        try basic.add(BasicBreakpoint(line: 10, statement: 3))
        basic.remove(id: 1)
        stops = []
        reason = run(m)
        while case .basicBreakpoint = reason {
            stops.append(basic.stop!.statement)
            reason = run(m, nil)
        }
        XCTAssertEqual(stops, [3, 3, 3])
    }

    func testStopsOnErrors() throws {
        for rom in ["riscos3_11", "riscos2_00"] {
            let m = try machine("10 X=1\n20 PRINT X/0\n30 END", rom: rom)
            let basic = m.debugger.basic
            basic.errorStop = .untrapped
            XCTAssertEqual(run(m), .basicError(number: 18), rom)
            XCTAssertEqual(basic.error?.message, "Division by zero")
            XCTAssertEqual(basic.error?.location.line, 20)
            XCTAssertEqual(basic.error?.trapped, false)
            XCTAssertEqual(basic.callStack().map { $0.location?.line }, [20])
            // A mistake typed in isn't stopped on.
            XCTAssertNil(run(m, "PRINT 1/0"), rom)
        }
    }

    func testTrappedErrorsOnlyWhenAsked() throws {
        let m = try machine("10 ON ERROR GOTO 100\n20 PRINT 1/0\n30 END\n100 PRINT \"trapped\":END")
        let basic = m.debugger.basic
        basic.errorStop = .untrapped
        XCTAssertNil(run(m))
        basic.errorStop = .all
        XCTAssertEqual(run(m), .basicError(number: 18))
        XCTAssertEqual(basic.error?.trapped, true)
    }

    func testVariablesAndArrays() throws {
        let m = try machine()
        let basic = m.debugger.basic
        try basic.add(BasicBreakpoint(line: 80))
        XCTAssertEqual(run(m), .basicBreakpoint(id: 1, line: 80))
        XCTAssertEqual(value(m, "A%"), .integer(1))
        XCTAssertEqual(value(m, "total"), .real(12))
        XCTAssertEqual(value(m, "name$"), .string("DONE"))
        XCTAssertEqual(["n1%", "n12%", "n123%", "n1234%"].map { value(m, $0) }, [.integer(5), .integer(6), .integer(7), .integer(8)])
        let grid = try XCTUnwrap(basic.variable("grid%("))
        XCTAssertEqual(grid.dimensions, [2, 3])
        XCTAssertEqual(try basic.evaluate("grid%(1,2)"), .integer(42))
        XCTAssertEqual(basic.elements(of: grid, from: 6, count: 1).first?.1, .integer(42))
        XCTAssertEqual(try basic.evaluate("total/2+A%"), .real(7))
        // Setting them.
        try basic.set("total", to: "99.5")
        XCTAssertEqual(value(m, "total"), .real(99.5))
        try basic.set("A%", to: "-5")
        XCTAssertEqual(value(m, "A%"), .integer(-5))
        try basic.set("name$", to: "\"OK\"")
        XCTAssertEqual(value(m, "name$"), .string("OK"))
        XCTAssertThrowsError(try basic.set("name$", to: "\"MUCH LONGER\""))
        try basic.set("grid%(", indices: [2, 3], to: "7")
        XCTAssertEqual(try basic.evaluate("grid%(2,3)"), .integer(7))
        // And BASIC sees them so.
        basic.removeAllBreakpoints()
        XCTAssertNil(run(m, nil, seconds: 1))
        type(m, "PRINT total;A%;name$;grid%(2,3)\r")
        XCTAssertTrue(m.screenText.contains { $0.contains("99.5-5OK7") }, m.screenText.suffix(4).joined(separator: "\n"))
    }

    func testListsTheProgram() throws {
        let m = try machine("10 PRINT \"HI\":GOTO 10")
        XCTAssertEqual(m.debugger.basic.listing().map { "\($0.number)\($0.text)" }, ["10 PRINT \"HI\":GOTO 10"])
    }

    func testLoadsAProgramAtThePrompt() throws {
        let m = try machine("PRINT \"LOADED \";6*7\nEND")
        XCTAssertNil(run(m, "RUN", seconds: 1))
        XCTAssertTrue(m.screenText.contains { $0.contains("LOADED 42") })
        // Not while a program's running (here, waiting at INPUT).
        try m.debugger.basic.loadAtPrompt(try BasicDebugger.program(fromFile: Array("INPUT A".utf8)))
        XCTAssertNil(run(m, "RUN", seconds: 1))
        XCTAssertThrowsError(try m.debugger.basic.loadAtPrompt([0x0D, 0xFF])) { XCTAssertEqual($0 as? BasicDebugger.LoadError, .running) }
    }
}
