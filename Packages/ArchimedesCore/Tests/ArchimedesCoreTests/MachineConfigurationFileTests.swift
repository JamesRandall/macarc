import XCTest
@testable import ArchimedesCore

final class MachineConfigurationFileTests: XCTestCase {
    func directory() throws -> URL {
        let p = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: p) }
        return p
    }
    func testPortableRoundTripPreservesCMOSAndBootSettings() throws {
        let p = try directory(), rom = p.appendingPathComponent("ArcLibre.rom")
        try Data([1,2,3,4]).write(to: rom) // File-format test; ROM parsing is separate.
        var c = MachineConfiguration(model: .a440)
        c.romPaths = [rom.path]; c.ramKB = 4096; c.cmosSettings = [.drive(0), .init(byte: 185, value: 10)]
        c.rtcEpoch = 42; c.powerOnKeys = [0x34]; c.powerOnKeysMs = 500
        let json = p.appendingPathComponent("ArcLibre.machine.json"), cmos = (0..<256).map { UInt8($0) }
        try MachineConfigurationFile.save(c, cmos: cmos, to: json)
        let raw = try JSONDecoder().decode(MachineConfiguration.self, from: Data(contentsOf: json))
        XCTAssertEqual(raw.romPaths, ["ArcLibre.rom"])
        XCTAssertFalse(try XCTUnwrap(raw.cmosPath).hasPrefix("/"))
        let loaded = try MachineConfigurationFile.load(from: json)
        c.cmosPath = loaded.cmosPath
        XCTAssertEqual(loaded, c)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: loaded.cmosPath!)), Data(cmos))
        // Moving both the config and its referenced files still works.
        let moved = p.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        for name in [json.lastPathComponent, rom.lastPathComponent, raw.cmosPath!] {
            try FileManager.default.moveItem(at: p.appendingPathComponent(name), to: moved.appendingPathComponent(name))
        }
        XCTAssertEqual(try MachineConfigurationFile.load(from: moved.appendingPathComponent(json.lastPathComponent)).romPaths, [moved.appendingPathComponent(rom.lastPathComponent).path])
    }
    func testRejectsUnsupportedAndMalformedSettings() throws {
        var c = MachineConfiguration(model: .a440); c.romPaths = ["rom"]
        for mutate: (inout MachineConfiguration) -> Void in [
            { $0.version = 999 }, { $0.ramKB = Int.max }, { $0.monitor = "typo" },
            { $0.hardDiscs = ["a", "b", "c"] }, { $0.powerOnKeysMs = -1 },
            { $0.cmosSettings = [.init(byte: -1, value: 1)] }, { $0.econetStation = 255 }
        ] {
            var bad = c; mutate(&bad)
            XCTAssertThrowsError(try MachineConfigurationFile.validate(bad))
        }
    }
    func testMissingFilesAndTruncatedCMOSFail() throws {
        let p = try directory(), json = p.appendingPathComponent("machine.json")
        var c = MachineConfiguration(model: .a440); c.romPaths = ["missing.rom"]
        try JSONEncoder().encode(c).write(to: json)
        XCTAssertThrowsError(try MachineConfigurationFile.load(from: json))
        try Data([0]).write(to: p.appendingPathComponent("missing.rom"))
        c.cmosPath = "short.cmos"
        try Data([0]).write(to: p.appendingPathComponent("short.cmos"))
        try JSONEncoder().encode(c).write(to: json)
        XCTAssertThrowsError(try MachineConfigurationFile.load(from: json))
        try Data("{not json}".utf8).write(to: json)
        XCTAssertThrowsError(try MachineConfigurationFile.load(from: json))
    }
}
