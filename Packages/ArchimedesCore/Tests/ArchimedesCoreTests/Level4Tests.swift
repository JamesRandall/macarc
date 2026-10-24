import XCTest
@testable import ArchimedesCore

/// Acorn's Level 4 File Server, set up from the user's Release 3 disc
/// (discimages/release3/Level 4.adf, not in the repository), serving a
/// RISC OS 3.11 client.
final class Level4Tests: XCTestCase {
    static var disc: [UInt8]? {
        let url = GameSmokeTests.root.appendingPathComponent("discimages/release3/Level 4.adf")
        return FileManager.default.contents(atPath: url.path).map { [UInt8]($0) }
    }

    func testReadsTheLevel4Disc() throws {
        guard let disc = Self.disc else { throw XCTSkip("discimages/release3/Level 4.adf not present") }
        XCTAssertTrue(Level4.isLevel4Disc(disc))
        let items = try Level4.serverItems(fromDisc: disc)
        let paths = Set(items.map { $0.path.joined(separator: ".") })
        XCTAssertTrue(paths.contains("!Server.!RunImage"))
        XCTAssertTrue(paths.contains("!System.Modules.ABCLib"))
        XCTAssertTrue(paths.contains("!Boot"))
        let image = try ADFSHardDiscBuilder.build(geometry: HardDiscGeometry(cylinders: 615, heads: 4), name: "FileServer", items: items, bootOption: 2)
        XCTAssertEqual(image[0x1FD], 2)
        XCTAssertTrue(Level4.isLevel4Disc(image)) // the server's disc reads back
    }

    func testCMOSSettings() {
        XCTAssertEqual(CMOSSetting.boot.physical, 0x50)
        XCTAssertEqual(CMOSSetting.rmaSize(pages: 1).physical, 210)
        XCTAssertEqual(CMOSSetting(byte: 239, value: 0).physical, 63)
        XCTAssertEqual(Level4.cmosSettings(ramKB: 4096).last, .rmaSize(pages: 32))
        XCTAssertEqual(Level4.cmosSettings(ramKB: 1024).last, .rmaSize(pages: 128))
    }

    func testServesAClient() throws {
        guard let disc = Self.disc else { throw XCTSkip("discimages/release3/Level 4.adf not present") }
        guard let rom = GameSmokeTests.romDir("riscos3_11") else { throw XCTSkip("ROM not present in ./roms/riscos3_11") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("level4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let hd = dir.appendingPathComponent("server.hdf").path
        try Level4.createServerDisc(path: hd, geometry: HardDiscGeometry(cylinders: 615, heads: 4), fromDisc: disc)

        let net = EconetNetwork()
        var s = MachineConfiguration(model: .a440)
        s.romPaths = [rom]
        s.ramKB = 4096
        s.powerOnKeys = [0x34]
        s.econetStation = 254
        s.hardDiscs = [hd]
        s.cmosSettings = Level4.cmosSettings(ramKB: s.ramKB)
        let server = try Machine(configuration: s)
        var c = MachineConfiguration()
        c.romPaths = [rom]
        c.powerOnKeys = [0x34]
        c.econetStation = 1
        let client = try Machine(configuration: c)
        net.add(server)
        net.add(client)
        net.run(seconds: 40)
        capture(server, "server")

        client.keyDown(0x0C)
        net.run(seconds: 0.1)
        client.keyUp(0x0C)
        net.run(seconds: 0.5)
        client.scheduleTyping("NET\n", startingAt: client.nominalTicks, intervalMs: 30)
        net.run(seconds: 2)
        client.scheduleTyping("I AM SYST\n", startingAt: client.nominalTicks, intervalMs: 30)
        while client.pendingInputEvents > 0 { net.run(seconds: 0.1) }
        net.run(seconds: 5)
        client.scheduleTyping("CAT\n", startingAt: client.nominalTicks, intervalMs: 30)
        while client.pendingInputEvents > 0 { net.run(seconds: 0.1) }
        net.run(seconds: 5)
        capture(client, "client")
        capture(server, "server-after")
        let text = client.screenText.joined(separator: "\n")
        XCTAssertTrue(text.contains("!Server"), String(text.suffix(800)))
    }

    func capture(_ m: Machine, _ name: String) {
        guard let out = ProcessInfo.processInfo.environment["MACARCH_LEVEL4_CAPTURE"] else { return }
        let f = m.currentFrame
        try? PNGEncoder.encode(f, scaleX: f.scaleX, scaleY: f.scaleY).write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png"))
        try? m.screenText.joined(separator: "\n").write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
    }
}
