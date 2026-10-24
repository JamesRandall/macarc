import Foundation
import XCTest
@testable import ArchimedesCore

// Internet Econet's client: the binary protocol against the service's
// published test vectors (acornplayground's econet/protocol/fixtures),
// service addresses, and (with a service running:
// MACARCH_ECONET_SERVICE=http://localhost:8787, from acornplayground's
// `npm run dev`) two networks in a real room, over real WebSockets.

final class EconetTrafficTests: XCTestCase {
    struct Fixtures: Decodable {
        struct Valid: Decodable {
            var name, type, frame, encoded: String
            var final: Bool
            var stage: Int
            var transaction: UInt32
            var from, to: UInt8
        }
        struct Invalid: Decodable { var name, encoded, error: String }
        var valid: [Valid]
        var invalid: [Invalid]
    }

    static let fixtures: Fixtures = {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Resources/internet-econet/traffic.json")
        return try! JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    }()

    static func hex(_ s: String) -> Data {
        Data(stride(from: 0, to: s.count, by: 2).map { UInt8(s.dropFirst($0).prefix(2), radix: 16)! })
    }

    func testDecodesAndEncodesTheServicesVectors() throws {
        XCTAssertFalse(Self.fixtures.valid.isEmpty)
        for f in Self.fixtures.valid {
            let message = try EconetTraffic.decode(Self.hex(f.encoded))
            let expected: EconetGatewayMessage = switch f.type {
            case "frame": .frame(transaction: f.transaction, stage: f.stage, final: f.final, bytes: [UInt8](Self.hex(f.frame)))
            case "noReply": .noReply(transaction: f.transaction, from: f.from, to: f.to)
            default: .broadcast(bytes: [UInt8](Self.hex(f.frame)))
            }
            XCTAssertEqual(message, expected, f.name)
            XCTAssertEqual(EconetTraffic.encode(message), Self.hex(f.encoded), f.name)
        }
    }

    func testRefusesWhatTheServiceRefuses() {
        for f in Self.fixtures.invalid {
            let expected: EconetTraffic.DecodeError = switch f.error {
            case "unsupportedVersion": .unsupportedVersion
            case "badAddress": .badAddress
            case "tooLarge": .tooLarge
            default: .malformed
            }
            XCTAssertThrowsError(try EconetTraffic.decode(Self.hex(f.encoded)), f.name) { error in
                XCTAssertEqual(error as? EconetTraffic.DecodeError, expected, f.name)
            }
        }
    }

    func testServiceAddresses() throws {
        XCTAssertEqual(try InternetEconetService.validate("econet.example.org").get().absoluteString, "https://econet.example.org")
        XCTAssertEqual(try InternetEconetService.validate(" https://econet.example.org/ ").get().absoluteString, "https://econet.example.org")
        XCTAssertEqual(try InternetEconetService.validate("http://localhost:8787").get().absoluteString, "http://localhost:8787")
        XCTAssertEqual(InternetEconetService.validate("http://econet.example.org"), .failure(.notSecure))
        XCTAssertEqual(InternetEconetService.validate("https://econet.example.org/v1"), .failure(.hasPath))
        XCTAssertEqual(InternetEconetService.origin(URL(string: "https://Econet.Example.org/x")!), "https://econet.example.org")
    }
}

/// Two networks in a room on a real service, in real time.
final class InternetEconetLiveTests: XCTestCase {
    static let service = ProcessInfo.processInfo.environment["MACARCH_ECONET_SERVICE"].flatMap(URL.init(string:))

    /// Runs the networks in step with the wall clock until `done`.
    func run(_ nets: [EconetNetwork], seconds: Double, until done: () -> Bool) -> Bool {
        let start = Date()
        var emulated = 0.0
        while Date().timeIntervalSince(start) < seconds {
            if done() { return true }
            for net in nets { net.run(seconds: 0.01) }
            emulated += 0.01
            let ahead = emulated - Date().timeIntervalSince(start)
            if ahead > 0 { Thread.sleep(forTimeInterval: ahead) }
        }
        return done()
    }

    func type(_ m: Machine, _ text: String, _ nets: [EconetNetwork]) {
        m.scheduleTyping(text, startingAt: m.nominalTicks, intervalMs: 30)
        _ = run(nets, seconds: 30) { m.pendingInputEvents == 0 }
    }

    func testTransmitAcrossARealRoom() async throws {
        guard let service = Self.service else { throw XCTSkip("MACARCH_ECONET_SERVICE not set") }
        guard let rom = GameSmokeTests.romDir("riscos3_11") else { throw XCTSkip("ROM not present in ./roms/riscos3_11") }
        let api = RoomAPI(service: service)
        let created = try await api.createRoom(name: "MacArch live test", displayName: "Host")
        let preview = try await api.resolve(code: created.invite.code.lowercased())
        XCTAssertEqual(preview.room.name, "MacArch live test")
        let joined = try await api.join(roomId: created.roomId, code: created.invite.code, displayName: "Guest")

        var nets: [EconetNetwork] = [], machines: [Machine] = []
        for station in [1, 2] {
            let net = EconetNetwork()
            var c = MachineConfiguration()
            c.romPaths = [rom]
            c.powerOnKeys = [0x34]
            c.econetStation = station
            let m = try Machine(configuration: c)
            net.add(m)
            nets.append(net)
            machines.append(m)
        }
        let links = [
            InternetEconetLink(api: api, roomId: created.roomId,
                               credentials: RoomCredentials(participantId: created.participantId, memberToken: created.memberToken),
                               claims: [StationClaim(station: 1, kind: "Acorn A3000", label: "Host A3000")], shared: [1]),
            InternetEconetLink(api: api, roomId: created.roomId,
                               credentials: RoomCredentials(participantId: joined.participantId, memberToken: joined.memberToken),
                               claims: [StationClaim(station: 2, kind: "Acorn A3000", label: "Guest A3000")], shared: [2]),
        ]
        for (net, link) in zip(nets, links) { link.start(attach: { net.line.attach(device: $0) }, detach: { net.line.detach(device: $0) }) }
        defer { for link in links { link.stop() } }
        XCTAssertTrue(run(nets, seconds: 10) { links[0].gateway.remoteStations == [2] && links[1].gateway.remoteStations == [1] })

        // Both at BASIC (they boot in emulated time; run them flat out).
        for net in nets { net.run(seconds: 21) }
        for m in machines { m.keyDown(0x0C) }
        for net in nets { net.run(seconds: 0.1) }
        for m in machines { m.keyUp(0x0C) }
        for net in nets { net.run(seconds: 0.5) }
        for m in machines { m.scheduleTyping("BASIC\n", startingAt: m.nominalTicks) }
        for net in nets { net.run(seconds: 2) }

        type(machines[1], "DIM B% 64:SYS &40000,&77,1,0,B%,64 TO H%:PRINT \"RX \";H%\n", nets)
        type(machines[0], "DIM B% 64:$B%=\"HELLO ROOM\":SYS &40009,&80,&77,2,0,B%,11,10,100 TO S%:PRINT \"SENT \";S%\n", nets)
        let screen = { (m: Machine) in m.screenText.joined(separator: "\n") }
        XCTAssertTrue(run(nets, seconds: 20) { screen(machines[0]).contains("SENT ") }, screen(machines[0]))
        XCTAssertTrue(screen(machines[0]).contains("SENT 0"), screen(machines[0]))
        type(machines[1], "SYS &40001,H% TO S%:PRINT \"STATUS \";S%;\" \";$B%\n", nets)
        XCTAssertTrue(run(nets, seconds: 5) { screen(machines[1]).contains("STATUS 9 HELLO ROOM") }, screen(machines[1]))
        try? await api.close(roomId: created.roomId, ownerToken: created.ownerToken)
    }
}
