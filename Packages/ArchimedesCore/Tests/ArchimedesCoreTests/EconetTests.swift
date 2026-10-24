import XCTest
@testable import ArchimedesCore

/// Econet between Archimedes, through RISC OS's own Econet module. SWIs
/// are called by number: RISC OS 2 starts with Caps Lock on, and names are
/// case sensitive (&40000 CreateReceive, &40001 ExamineReceive, &40009
/// DoTransmit, &4000A ReadLocalStationAndNet).
final class EconetTests: XCTestCase {
    /// A3000s with RISC OS 3.11 and Econet modules, cabled to one network
    /// from power-on, then each at the command line in BASIC.
    func stations(_ numbers: [Int], clockRate: Int? = EconetTime.defaultClockRate, roms: [String]? = nil) throws -> (EconetNetwork, [Machine]) {
        let net = EconetNetwork(clockRate: clockRate)
        let machines = try numbers.enumerated().map { i, n -> Machine in
            let rom = roms?[i] ?? "riscos3_11"
            guard let dir = GameSmokeTests.romDir(rom) else { throw XCTSkip("ROM not present in ./roms/\(rom)") }
            var c = MachineConfiguration()
            c.romPaths = [dir]
            c.powerOnKeys = [0x34]
            c.econetStation = n
            let m = try Machine(configuration: c)
            net.add(m)
            return m
        }
        net.run(seconds: 21)
        for m in machines { m.keyDown(0x0C) } // F12: command line
        net.run(seconds: 0.1)
        for m in machines { m.keyUp(0x0C) }
        net.run(seconds: 0.5)
        for m in machines { m.scheduleTyping("BASIC\n", startingAt: m.nominalTicks) }
        net.run(seconds: 2)
        return (net, machines)
    }

    func screen(_ m: Machine) -> String { m.screenText.joined(separator: "\n") }

    func type(_ m: Machine, _ text: String, on net: EconetNetwork, seconds: Double) {
        m.scheduleTyping(text, startingAt: m.nominalTicks, intervalMs: 30)
        while m.pendingInputEvents > 0 { net.run(seconds: 0.1) }
        net.run(seconds: seconds)
    }

    func testStationNumberInCMOS() throws {
        let (net, ms) = try stations([7])
        let m = ms[0]
        XCTAssertEqual(m.cmos[Machine.cmosStation], 7)
        type(m, "SYS &4000A TO S%,N%:PRINT \"STN \";S%;\" NET \";N%\n", on: net, seconds: 2)
        XCTAssertTrue(screen(m).contains("STN 7 NET 0"), String(screen(m).suffix(400)))
    }

    /// The four-way handshake between two machines' Econet modules: one
    /// opens a receive block, the other transmits to it.
    func testTransmitAndReceive() throws {
        try transmitAndReceive(roms: nil)
    }

    /// RISC OS 2.00 sending to RISC OS 3.11, and back.
    func testRISCOS2() throws {
        try transmitAndReceive(roms: ["riscos2_00", "riscos3_11"])
        try transmitAndReceive(roms: ["riscos3_11", "riscos2_00"])
    }

    func transmitAndReceive(roms: [String]?) throws {
        let (net, ms) = try stations([1, 2], roms: roms)
        let (a, b) = (ms[0], ms[1])
        let trace = EconetTrace()
        net.line.observer = { trace.observe($0) }
        type(b, "DIM B% 64:SYS &40000,&77,1,0,B%,64 TO H%:PRINT \"RX \";H%\n", on: net, seconds: 2)
        XCTAssertTrue(screen(b).contains("RX "), String(screen(b).suffix(400)))
        type(a, "DIM B% 64:$B%=\"HELLO ARC\":SYS &40009,&80,&77,2,0,B%,10,10,100 TO S%:PRINT \"SENT \";S%\n", on: net, seconds: 3)
        XCTAssertTrue(screen(a).contains("SENT 0"), String(screen(a).suffix(400)) + "\n" + (a.econet?.statusReport() ?? ""))
        type(b, "SYS &40001,H% TO S%:PRINT \"STATUS \";S%;\" \";$B%\n", on: net, seconds: 2)
        XCTAssertTrue(screen(b).contains("STATUS 9 HELLO ARC"), String(screen(b).suffix(400)))
        let kinds = trace.frames.filter { $0.status == .valid }.map(\.kind)
        XCTAssertEqual(Array(kinds.prefix(4)), [.scout, .acknowledgement, .data, .acknowledgement], "\(trace.frames.map(\.summary))")
    }

    /// A network's run repeats exactly: the same frames at the same times.
    func testDeterministic() throws {
        func run() throws -> [EconetFrame] {
            let (net, ms) = try stations([1, 2])
            let trace = EconetTrace()
            net.line.observer = { trace.observe($0) }
            type(ms[1], "DIM B% 64:SYS &40000,&77,1,0,B%,64 TO H%\n", on: net, seconds: 1)
            type(ms[0], "DIM B% 64:SYS &40009,&80,&77,2,0,B%,40,10,100 TO S%\n", on: net, seconds: 2)
            return trace.frames
        }
        let first = try run(), second = try run()
        XCTAssertGreaterThanOrEqual(first.count, 4)
        XCTAssertEqual(first, second)
    }

    /// Machines on several threads give the same run as on one.
    func testThreadsDontChangeTheRun() throws {
        func run(threads: Int) throws -> ([EconetFrame], [String]) {
            let (net, ms) = try stations([1, 2, 3])
            net.useThreads(threads)
            let trace = EconetTrace()
            net.line.observer = { trace.observe($0) }
            type(ms[1], "DIM B% 64:SYS &40000,&77,1,0,B%,64 TO H%\n", on: net, seconds: 1)
            type(ms[2], "DIM B% 64:SYS &40000,&77,1,0,B%,64 TO H%\n", on: net, seconds: 1)
            type(ms[0], "DIM B% 64:SYS &40009,&80,&77,2,0,B%,40,10,100 TO S%:SYS &40009,&80,&77,3,0,B%,40,10,100 TO S%\n", on: net, seconds: 2)
            net.useThreads(1)
            return (trace.frames, ms.map(screen))
        }
        let one = try run(threads: 1), three = try run(threads: 3)
        XCTAssertGreaterThanOrEqual(one.0.count, 8)
        XCTAssertEqual(one.0, three.0)
        XCTAssertEqual(one.1, three.1)
    }

    /// Nobody at the station: "not listening" (3). No clock: 4.
    func testNotListeningAndNoClock() throws {
        let (net, ms) = try stations([1])
        let a = ms[0]
        type(a, "DIM B% 64:SYS &40009,&80,&77,9,0,B%,4,2,10 TO S%:PRINT \"SENT \";S%\n", on: net, seconds: 3)
        XCTAssertTrue(screen(a).contains("SENT 3"), String(screen(a).suffix(400)))
        net.line.clockRate = nil
        type(a, "SYS &40009,&80,&77,9,0,B%,4,2,10 TO S%:PRINT \"NOCLK \";S%\n", on: net, seconds: 3)
        XCTAssertTrue(screen(a).contains("NOCLK 4"), String(screen(a).suffix(400)))
    }
}
