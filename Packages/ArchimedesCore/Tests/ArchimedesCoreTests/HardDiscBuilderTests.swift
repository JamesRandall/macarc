import Foundation
import XCTest
@testable import ArchimedesCore

final class HardDiscBuilderTests: XCTestCase {
    /// A ZIP archive built by hand: one stored member with an Acorn extra
    /// field, one deflated member without.
    static func zip(_ members: [(name: String, data: [UInt8], deflate: Bool, acorn: (UInt32, UInt32)?)]) -> [UInt8] {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        var out: [UInt8] = [], central: [UInt8] = []
        for m in members {
            let body = m.deflate ? [UInt8](try! (Data(m.data) as NSData).compressed(using: .zlib) as Data) : m.data
            var extra: [UInt8] = []
            if let (load, exec) = m.acorn {
                extra = le16(0x4341) + le16(20) + Array("ARC0".utf8) + le32(load) + le32(exec) + le32(3) + le32(0)
            }
            let name = Array(m.name.utf8)
            let common = le16(20) + le16(0) + le16(m.deflate ? 8 : 0) + le16(0) + le16(0x21) + le32(0)
                + le32(UInt32(body.count)) + le32(UInt32(m.data.count)) + le16(name.count) + le16(extra.count)
            central += le32(0x0201_4B50) + le16(20) + common + le16(0) + le16(0) + le16(0) + le32(0) + le32(UInt32(out.count)) + name + extra
            out += le32(0x0403_4B50) + common + name + extra + body
        }
        let start = out.count
        out += central
        out += le32(0x0605_4B50) + le16(0) + le16(0) + le16(members.count) + le16(members.count)
            + le32(UInt32(central.count)) + le32(UInt32(start)) + le16(0)
        return out
    }

    func testZipMembersAndAcornTypes() throws {
        let text = Array(String(repeating: "Hello, Archimedes. ", count: 40).utf8)
        let file = Self.zip([
            ("!App/!Run", Array("Run <Obey$Dir>.Code\n".utf8), false, (0xFFFF_EB12, 0x3456_7890)),
            ("!App/Docs/Read.me", text, true, nil),
        ])
        let members = try ZipArchive.read(file)
        XCTAssertEqual(members.map(\.path), ["!App/!Run", "!App/Docs/Read.me"])
        XCTAssertEqual(members[0].load, 0xFFFF_EB12)
        XCTAssertEqual(members[1].data, text)

        let items = try ADFSHardDiscBuilder.items(fromZip: file)
        XCTAssertEqual(items[0].path, ["!App", "!Run"])
        XCTAssertEqual(items[0].load, 0xFFFF_EB12)
        XCTAssertEqual(items[1].path, ["!App", "Docs", "Read/me"])
        XCTAssertEqual((items[1].load >> 8) & 0xFFF, 0xFFD, "no Acorn information: Data")
    }

    func testHostNamesAndTypes() {
        XCTAssertEqual(ADFSHardDiscBuilder.hostItem(["Game", "Code,ff8"], data: [], date: Date()).path, ["Game", "Code"])
        XCTAssertEqual((ADFSHardDiscBuilder.hostItem(["Game", "Code,ff8"], data: [], date: Date()).load >> 8) & 0xFFF, 0xFF8)
        XCTAssertEqual((ADFSHardDiscBuilder.hostItem(["!App", "!Run"], data: [], date: Date()).load >> 8) & 0xFFF, 0xFEB)
        XCTAssertEqual(ADFSHardDiscBuilder.hostItem(["my file.txt"], data: [], date: Date()).path, ["my\u{A0}file/txt"])
        XCTAssertEqual(ADFSHardDiscBuilder.latin1("my\u{A0}file"), [0x6D, 0x79, 0xA0, 0x66, 0x69, 0x6C, 0x65])
    }

    func testLayoutChecksumsAndSortedDirectories() throws {
        let g = HardDiscGeometry(cylinders: 615, heads: 4)
        let items = [
            ADFSHardDiscBuilder.Item(path: ["zeta"], data: [1, 2, 3], type: 0xFFD),
            ADFSHardDiscBuilder.Item(path: ["Alpha", "inner"], data: [UInt8](repeating: 7, count: 700), type: 0xFFF),
            ADFSHardDiscBuilder.Item(path: ["beta"], data: [], type: 0xFFD),
        ]
        let d = try ADFSHardDiscBuilder.build(geometry: g, name: "Test", items: items)
        XCTAssertEqual(d[0x0FF], ADFSFormatter.checksum(d, 0x000, 0x100))
        XCTAssertEqual(d[0x1FF], ADFSFormatter.checksum(d, 0x100, 0x100))
        XCTAssertEqual(d[0xDFF], ADFSFormatter.checksum(d, 0xC00, 0x200), "boot block untouched")
        XCTAssertEqual(d[0x400 + 2047], ADFSFormatter.directoryCheckByte(Array(d[0x400..<0xC00])))
        // Free space starts after the files and runs to the end of the drive.
        let free = Int(d[0]) | Int(d[1]) << 8 | Int(d[2]) << 16
        XCTAssertEqual(free * 256, d.count)

        // Read back as an 800K image (the inspector knows floppy sizes).
        let report = ADFSInspector.inspect(bytes: d + [UInt8](repeating: 0, count: 819_200 - d.count))
        XCTAssertEqual(report.root.map(\.name), ["Alpha", "beta", "zeta"])
        guard report.root.count == 3 else { return }
        XCTAssertEqual(report.root[0].isDirectory, true)
        XCTAssertEqual(report.root[0].children?.map(\.name), ["inner"])
        XCTAssertEqual(report.root[0].children?.first?.fileType, "FFF")
        XCTAssertEqual(report.root[2].length, 3)

        XCTAssertThrowsError(try ADFSHardDiscBuilder.build(geometry: g, name: "T", items: [.init(path: ["much_too_long"], data: [], type: 0xFFD)]))
        XCTAssertThrowsError(try ADFSHardDiscBuilder.build(geometry: g, name: "T", items: (0..<78).map { .init(path: ["f\($0)"], data: [], type: 0xFFD) }))
        XCTAssertThrowsError(try ADFSHardDiscBuilder.build(geometry: g, name: "T", items: [.init(path: ["a"], data: [], type: 0xFFD), .init(path: ["a", "b"], data: [], type: 0xFFD)]))
    }

    /// RISC OS reads a built drive: the catalogue, a nested file's text, and
    /// the free space left.
    func testRISCOSReadsBuiltDrive() throws {
        guard let dir = GameSmokeTests.romDir("riscos3_11") else { throw XCTSkip("RISC OS 3.11 ROM not present") }
        let path = NSTemporaryDirectory() + "macarch-built-\(UUID().uuidString).hdf"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let big = (0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        try ADFSHardDiscBuilder.create(path: path, geometry: HardDiscGeometry(cylinders: 615, heads: 4), name: "Built", items: [
            .init(path: ["Games", "Notes"], data: Array("Built by MacArch\n".utf8), type: 0xFFF),
            .init(path: ["Games", "Blob"], data: big, type: 0xFFD),
        ])
        var c = MachineConfiguration(model: .a440)
        c.romPaths = [dir]
        c.hardDiscs = [path]
        c.powerOnKeys = [0x34]
        let m = try Machine(configuration: c)
        m.powerOn()
        m.run(seconds: 25)
        m.keyDown(0x0C); m.run(seconds: 0.1); m.keyUp(0x0C) // F12
        m.run(seconds: 1)
        m.scheduleTyping("*Type :4.$.Games.Notes\n*Load :4.$.Games.Blob 10000\n*Ex :4.$.Games\n", intervalMs: 40)
        m.run(seconds: 20)
        let text = m.recentText
        XCTAssertTrue(text.contains("Built by MacArch"), String(text.suffix(400)))
        XCTAssertTrue(text.contains("Text"), String(text.suffix(400)))
        XCTAssertFalse(text.contains("Broken directory") || text.contains("Bad free space map"), String(text.suffix(400)))
        let loaded = (0..<big.count).map { m.memc.debugRead(0x10000 + UInt32($0), space: .logical) ?? 0 }
        XCTAssertEqual(loaded, big)
    }
}
