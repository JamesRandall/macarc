import XCTest
@testable import ArchimedesCore

// Two networks, each its own line with its own Archimedes, joined through
// their Internet gateways by a simulated room that delivers each message
// after a delay (in emulated time, so runs repeat exactly). Everything
// between them is RISC OS's own Econet module.

final class GatewayRig {
    let sides: [EconetNetwork]
    let gateways: [EconetGateway]
    let machines: [[Machine]]
    /// One-way delay, in ticks.
    var latency: UInt64
    /// Messages in flight: when they arrive, and where.
    private var inFlight: [(at: UInt64, side: Int, message: EconetGatewayMessage)] = []
    private var now: UInt64 = 0
    private(set) var sent: [(side: Int, message: EconetGatewayMessage)] = []

    init(_ a: [Int], _ b: [Int], latency milliseconds: Double, rom: String) throws {
        latency = UInt64(milliseconds * 24_000)
        var sides: [EconetNetwork] = [], machines: [[Machine]] = []
        for stations in [a, b] {
            let net = EconetNetwork()
            var ms: [Machine] = []
            for n in stations {
                var c = MachineConfiguration()
                c.romPaths = [rom]
                c.powerOnKeys = [0x34]
                c.econetStation = n
                let m = try Machine(configuration: c)
                net.add(m)
                ms.append(m)
            }
            sides.append(net)
            machines.append(ms)
        }
        self.sides = sides
        self.machines = machines
        gateways = [EconetGateway(), EconetGateway()]
        for (index, gateway) in gateways.enumerated() {
            gateway.remoteStations = Set((index == 0 ? b : a).map { UInt8($0) })
            gateway.send = { [unowned self] message in
                sent.append((index, message))
                inFlight.append((now + self.latency, 1 - index, message))
            }
            sides[index].line.attach(device: gateway)
        }
    }

    func run(seconds: Double) {
        let quantum = sides[0].line.delay
        var left = UInt64(seconds * Double(EconetTime.ticksPerSecond))
        while left > 0 {
            let due = inFlight.filter { $0.at <= now }
            inFlight.removeAll { $0.at <= now }
            for item in due { gateways[item.side].receive(item.message) }
            for side in sides { side.run(ticks: quantum) }
            now += quantum
            left -= min(left, quantum)
        }
    }

    func screen(_ side: Int, _ index: Int) -> String { machines[side][index].screenText.joined(separator: "\n") }

    func type(_ side: Int, _ index: Int, _ text: String, seconds: Double) {
        let m = machines[side][index]
        m.scheduleTyping(text, startingAt: m.nominalTicks, intervalMs: 30)
        while m.pendingInputEvents > 0 { run(seconds: 0.1) }
        run(seconds: seconds)
    }

    /// Every machine at BASIC.
    func toBASIC() {
        run(seconds: 21)
        for m in machines.flatMap({ $0 }) { m.keyDown(0x0C) }
        run(seconds: 0.1)
        for m in machines.flatMap({ $0 }) { m.keyUp(0x0C) }
        run(seconds: 0.5)
        for m in machines.flatMap({ $0 }) { m.scheduleTyping("BASIC\n", startingAt: m.nominalTicks) }
        run(seconds: 2)
    }
}

final class EconetGatewayTests: XCTestCase {
    func rig(latency: Double) throws -> GatewayRig {
        guard let rom = GameSmokeTests.romDir("riscos3_11") else { throw XCTSkip("ROM not present in ./roms/riscos3_11") }
        let rig = try GatewayRig([1], [2], latency: latency, rom: rom)
        rig.toBASIC()
        return rig
    }

    /// Econet_DoTransmit on one network to a receive block on the other:
    /// the whole handshake, through both gateways, at Internet latencies.
    func testTransmitAcross() throws {
        for latency in [0.0, 20, 80] {
            let rig = try rig(latency: latency)
            rig.type(1, 0, "DIM B% 64:SYS &40000,&77,1,0,B%,64 TO H%:PRINT \"RX \";H%\n", seconds: 1)
            rig.type(0, 0, "DIM B% 64:$B%=\"HELLO ARC\":SYS &40009,&80,&77,2,0,B%,10,10,100 TO S%:PRINT \"SENT \";S%\n", seconds: 3)
            XCTAssertTrue(rig.screen(0, 0).contains("SENT 0"), "\(latency) ms: " + rig.screen(0, 0).suffix(300))
            rig.type(1, 0, "SYS &40001,H% TO S%:PRINT \"STATUS \";S%;\" \";$B%\n", seconds: 1)
            XCTAssertTrue(rig.screen(1, 0).contains("STATUS 9 HELLO ARC"), "\(latency) ms: " + rig.screen(1, 0).suffix(300))
            let frames = rig.sent.filter { if case .frame = $0.message { true } else { false } }
            XCTAssertEqual(frames.map(\.side).prefix(4), [0, 1, 0, 1], "\(latency) ms: \(rig.sent)")
        }
    }

    /// Nobody listening on the far side: "not listening", as on one network.
    func testNotListeningAcross() throws {
        let rig = try rig(latency: 40)
        rig.type(0, 0, "DIM B% 64:SYS &40009,&80,&77,2,0,B%,4,2,10 TO S%:PRINT \"SENT \";S%\n", seconds: 3)
        XCTAssertTrue(rig.screen(0, 0).contains("SENT 3"), rig.screen(0, 0).suffix(300).description)
    }
}
