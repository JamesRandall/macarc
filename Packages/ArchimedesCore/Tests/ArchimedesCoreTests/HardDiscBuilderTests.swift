import Foundation
import XCTest
import zlib
@testable import ArchimedesCore

final class HardDiscBuilderTests: XCTestCase {
    /// A ZIP archive built by hand: one stored member with an Acorn extra
    /// field, one deflated member without.
    static func zip(_ members: [(name: String, data: [UInt8], deflate: Bool, acorn: (UInt32, UInt32)?)]) -> [UInt8] {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        var out: [UInt8] = [], central: [UInt8] = []
        for m in members {
            #if canImport(Darwin)
            let body = m.deflate ? [UInt8](try! (Data(m.data) as NSData).compressed(using: .zlib) as Data) : m.data
            #else
            // A zlib stream less its 2-byte header and Adler-32 is raw deflate.
            let body = m.deflate ? Array(Zlib.compress(m.data).dropFirst(2).dropLast(4)) : m.data
            #endif
            var extra: [UInt8] = []
            if let (load, exec) = m.acorn {
                extra = le16(0x4341) + le16(20) + Array("ARC0".utf8) + le32(load) + le32(exec) + le32(3) + le32(0)
            }
            let name = Array(m.name.utf8)
            let crc = m.data.withUnsafeBufferPointer { UInt32(crc32(0, $0.baseAddress, uInt($0.count))) }
            let common = le16(20) + le16(0) + le16(m.deflate ? 8 : 0) + le16(0) + le16(0x21) + le32(crc)
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

    // MARK: Adding to an existing drive

    static func listing(_ path: String) throws -> [String: Int] {
        let v = try ADFSHardDiscWriter.Volume(path: path)
        var out: [String: Int] = [:]
        func walk(_ address: Int, _ prefix: String) throws {
            for e in try v.directory(at: address, path: prefix).entries {
                let name = prefix + (prefix.isEmpty ? "" : ".") + String(decoding: e.name, as: UTF8.self)
                if e.isDirectory { try walk(e.sector * 256, name) } else { out[name] = Int(e.length) }
            }
        }
        try walk(0x400, "")
        return out
    }

    func testAddFilesToExistingDrive() throws {
        for g in [HardDiscGeometry(cylinders: 615, heads: 4), HardDiscGeometry(cylinders: 977, heads: 5, sectorsPerTrack: 17, sectorSize: 512)] {
            let path = NSTemporaryDirectory() + "macarch-add-\(UUID().uuidString).hdf"
            defer { try? FileManager.default.removeItem(atPath: path) }
            try ADFSHardDiscBuilder.create(path: path, geometry: g, name: "Base", items: [
                .init(path: ["Games", "Notes"], data: [UInt8](repeating: 1, count: 300), type: 0xFFF),
                .init(path: ["zeta"], data: [1, 2, 3], type: 0xFFD),
            ])
            let before = try Data(contentsOf: URL(fileURLWithPath: path))
            let items: [ADFSHardDiscBuilder.Item] = [
                .init(path: ["Games", "Extra"], data: [UInt8](repeating: 2, count: 5000), type: 0xFFD),
                .init(path: ["New", "Deep", "File"], data: [UInt8](repeating: 3, count: 10), type: 0xFFD),
                .init(path: ["zeta"], data: [UInt8](repeating: 4, count: 4000), type: 0xFFD),
                .init(path: ["Alpha"], data: [], type: 0xFFD),
            ]
            let plan = try ADFSHardDiscWriter.plan(path: path, items: items)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before, "planning changes nothing")
            XCTAssertEqual(plan.added, ["Games.Extra", "New.Deep.File", "Alpha"])
            XCTAssertEqual(plan.replaced, ["zeta"])
            XCTAssertEqual(plan.directoriesMade, ["New", "New.Deep"])

            let done = try ADFSHardDiscWriter.add(path: path, items: items)
            XCTAssertEqual(done, plan)
            XCTAssertEqual(try Self.listing(path), ["Alpha": 0, "Games.Extra": 5000, "Games.Notes": 300, "New.Deep.File": 10, "zeta": 4000])
            let v = try ADFSHardDiscWriter.Volume(path: path)
            XCTAssertEqual(try v.directory(at: 0x400, path: "$").entries.map { String(decoding: $0.name, as: UTF8.self) }, ["Alpha", "Games", "New", "zeta"])
            XCTAssertTrue(v.free.allSatisfy { $0.start % v.unit == 0 }, "allocation keeps to whole sectors")
            XCTAssertEqual(v.free.reduce(0) { $0 + $1.length } * 256, done.bytesFree)

            // Shrinking a file gives its space back, merged with its neighbours.
            try ADFSHardDiscWriter.add(path: path, items: [.init(path: ["zeta"], data: [5], type: 0xFFD)])
            let after = try ADFSHardDiscWriter.Volume(path: path)
            XCTAssertLessThanOrEqual(after.free.count, 2)
            XCTAssertThrowsError(try ADFSHardDiscWriter.add(path: path, items: [.init(path: ["Games"], data: [], type: 0xFFD)]))
            XCTAssertThrowsError(try ADFSHardDiscWriter.add(path: path, items: [.init(path: ["Big"], data: [UInt8](repeating: 0, count: g.byteCount), type: 0xFFD)]))
            XCTAssertEqual(try Self.listing(path)["zeta"], 1, "a failed add leaves the drive as it was")
        }
    }

    /// RISC OS reads files added to a drive, and can go on writing to it.
    func testRISCOSUsesDriveAfterAdding() throws {
        guard let dir = GameSmokeTests.romDir("riscos3_11") else { throw XCTSkip("RISC OS 3.11 ROM not present") }
        let path = NSTemporaryDirectory() + "macarch-added-\(UUID().uuidString).hdf"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try ADFSHardDiscBuilder.create(path: path, geometry: HardDiscGeometry(cylinders: 615, heads: 4), name: "Built", items: [
            .init(path: ["Games", "Notes"], data: Array("Original\n".utf8), type: 0xFFF),
            .init(path: ["Games", "Old"], data: [UInt8](repeating: 9, count: 20_000), type: 0xFFD),
        ])
        let big = (0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        try ADFSHardDiscWriter.add(path: path, items: [
            .init(path: ["Games", "Notes"], data: Array("Replaced by MacArch\n".utf8), type: 0xFFF),
            .init(path: ["Games", "Old"], data: [1], type: 0xFFD),
            .init(path: ["Added", "Blob"], data: big, type: 0xFFD),
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
        m.scheduleTyping("*Type :4.$.Games.Notes\n*Load :4.$.Added.Blob 10000\n*CDir :4.$.Added.Made\n*Save :4.$.Added.Made.Copy 10000 +8000\n*Delete :4.$.Games.Old\n*Ex :4.$.Added\n", intervalMs: 40)
        m.run(seconds: 25)
        m.hdc?.drives.forEach { $0?.synchronize() }
        let text = m.recentText
        XCTAssertTrue(text.contains("Replaced by MacArch"), String(text.suffix(600)))
        XCTAssertTrue(text.contains("Made"), String(text.suffix(600)))
        for bad in ["Broken directory", "Bad free space map", "Map full", "not found", "Disc error"] {
            XCTAssertFalse(text.contains(bad), "\(bad): " + String(text.suffix(600)))
        }
        let loaded = (0..<big.count).map { m.memc.debugRead(0x10000 + UInt32($0), space: .logical) ?? 0 }
        XCTAssertEqual(loaded, big)
        // What RISC OS wrote is still a drive files can be added to.
        let listing = try Self.listing(path)
        XCTAssertEqual(listing["Added.Made.Copy"], 0x8000)
        XCTAssertNil(listing["Games.Old"])
        try ADFSHardDiscWriter.add(path: path, items: [.init(path: ["Added", "Made", "Again"], data: [1, 2], type: 0xFFD)])
    }

    /// Every file's contents, by path.
    static func contents(_ path: String) throws -> [String: [UInt8]] {
        let v = try ADFSHardDiscWriter.Volume(path: path)
        var out: [String: [UInt8]] = [:]
        func walk(_ address: Int, _ prefix: String) throws {
            for e in try v.directory(at: address, path: prefix).entries {
                let name = prefix + (prefix.isEmpty ? "" : ".") + String(decoding: e.name, as: UTF8.self)
                if e.isDirectory { try walk(e.sector * 256, name) } else { out[name] = v.read(e.sector * 256, Int(e.length)) }
            }
        }
        try walk(0x400, "")
        return out
    }

    /// A 20 MB drive with gaps where two 3 MB files were, and a directory
    /// (with one inside it) above them.
    static func fragmentedDrive(_ path: String, geometry g: HardDiscGeometry = HardDiscGeometry(cylinders: 615, heads: 4)) throws -> [String: [UInt8]] {
        func pattern(_ n: Int, _ seed: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: $0 &* (seed * 2 + 1) &+ seed) } }
        var items: [ADFSHardDiscBuilder.Item] = (1...5).map { .init(path: ["File\($0)"], data: pattern(3 << 20, $0), type: 0xFFD) }
        items.append(.init(path: ["Sub", "Notes"], data: Array("Moved by compaction\n".utf8), type: 0xFFF))
        items.append(.init(path: ["Sub", "Deeper", "Blob"], data: pattern(70_000, 9), type: 0xFFD))
        try ADFSHardDiscBuilder.create(path: path, geometry: g, name: "Frag", items: items)
        try ADFSHardDiscWriter.add(path: path, items: [.init(path: ["File2"], data: [2], type: 0xFFD), .init(path: ["File4"], data: [4], type: 0xFFD)])
        return try contents(path)
    }

    func testCompactingMakesRoom() throws {
        for g in [HardDiscGeometry(cylinders: 615, heads: 4), HardDiscGeometry(cylinders: 160, heads: 8, sectorsPerTrack: 32, sectorSize: 512)] {
            let path = NSTemporaryDirectory() + "macarch-frag-\(UUID().uuidString).hdf"
            defer { try? FileManager.default.removeItem(atPath: path) }
            let before = try Self.fragmentedDrive(path, geometry: g)
            let big = ADFSHardDiscBuilder.Item(path: ["Big"], data: (0..<(5 << 20)).map { UInt8(truncatingIfNeeded: $0 >> 3) }, type: 0xFFD)
            XCTAssertThrowsError(try ADFSHardDiscWriter.plan(path: path, items: [big])) { e in
                XCTAssertTrue((e as? ADFSHardDiscWriter.WriteError)?.isFragmented == true, "\(e)")
            }
            let plan = try ADFSHardDiscWriter.plan(path: path, items: [big], compact: true)
            XCTAssertGreaterThan(plan.bytesMoved, 6 << 20)
            XCTAssertEqual(try Self.contents(path), before, "planning changes nothing")
            let done = try ADFSHardDiscWriter.add(path: path, items: [big], compact: true)
            XCTAssertEqual(done, plan)
            var expected = before
            expected["Big"] = big.data
            XCTAssertEqual(try Self.contents(path), expected, "every file kept its contents")
            let v = try ADFSHardDiscWriter.Volume(path: path)
            XCTAssertEqual(v.free.count, 1, "the free space is one area")
            // The moved directories point at their moved parents.
            let sub = try v.directory(at: 0x400, path: "$").entries.first { $0.name == Array("Sub".utf8) }!
            let subDir = try v.directory(at: sub.sector * 256, path: "Sub")
            let deeper = try v.directory(at: subDir.entries.first { $0.name == Array("Deeper".utf8) }!.sector * 256, path: "Deeper")
            XCTAssertEqual(Int(deeper.bytes[2010]) | Int(deeper.bytes[2011]) << 8 | Int(deeper.bytes[2012]) << 16, sub.sector)
            XCTAssertEqual(Int(subDir.bytes[2010]) | Int(subDir.bytes[2011]) << 8, 0x4)
        }
    }

    /// RISC OS uses a drive MacArch compacted: moved files in moved
    /// directories, and writing more.
    func testRISCOSUsesCompactedDrive() throws {
        guard let dir = GameSmokeTests.romDir("riscos3_11") else { throw XCTSkip("RISC OS 3.11 ROM not present") }
        let path = NSTemporaryDirectory() + "macarch-compacted-\(UUID().uuidString).hdf"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let before = try Self.fragmentedDrive(path)
        try ADFSHardDiscWriter.add(path: path, items: [.init(path: ["Big"], data: [UInt8](repeating: 0x5A, count: 5 << 20), type: 0xFFD)], compact: true)
        var c = MachineConfiguration(model: .a440)
        c.romPaths = [dir]
        c.hardDiscs = [path]
        c.powerOnKeys = [0x34]
        let m = try Machine(configuration: c)
        m.powerOn()
        m.run(seconds: 25)
        m.keyDown(0x0C); m.run(seconds: 0.1); m.keyUp(0x0C) // F12
        m.run(seconds: 1)
        m.scheduleTyping("*Type :4.$.Sub.Notes\n*Load :4.$.Sub.Deeper.Blob 10000\n*CDir :4.$.Sub.Deeper.New\n*Save :4.$.Sub.Deeper.New.Copy 10000 +8000\n*Delete :4.$.File3\n*Ex :4.$.Sub.Deeper\n", intervalMs: 40)
        m.run(seconds: 25)
        m.hdc?.drives.forEach { $0?.synchronize() }
        let text = m.recentText
        XCTAssertTrue(text.contains("Moved by compaction"), String(text.suffix(600)))
        for bad in ["Broken directory", "Bad free space map", "Map full", "not found", "Disc error"] {
            XCTAssertFalse(text.contains(bad), "\(bad): " + String(text.suffix(600)))
        }
        let blob = before["Sub.Deeper.Blob"]!
        XCTAssertEqual((0..<blob.count).map { m.memc.debugRead(0x10000 + UInt32($0), space: .logical) ?? 0 }, blob)
        let after = try Self.contents(path)
        XCTAssertEqual(after["Sub.Deeper.New.Copy"]?.count, 0x8000)
        XCTAssertNil(after["File3"])
        XCTAssertEqual(after["File5"], before["File5"])
    }

    // MARK: Resizing

    func testResizeGrowsAndShrinks() throws {
        let presets = [(HardDiscGeometry.presets[0].geometry, HardDiscGeometry.presets[1].geometry),
                       (HardDiscGeometry(cylinders: 160, heads: 8, sectorsPerTrack: 32, sectorSize: 512), HardDiscGeometry.idePresets[0].geometry)]
        for (small, large) in presets {
            let path = NSTemporaryDirectory() + "macarch-resize-\(UUID().uuidString).hdf"
            defer { try? FileManager.default.removeItem(atPath: path) }
            let before = try Self.fragmentedDrive(path, geometry: small)
            let start = try ADFSHardDiscWriter.usage(path: path)
            XCTAssertEqual(start.size, small.byteCount)

            let grown = try ADFSHardDiscWriter.resize(path: path, to: large)
            XCTAssertEqual(grown.size, large.byteCount)
            XCTAssertEqual(grown.bytesFree, start.bytesFree + large.byteCount - small.byteCount)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int, large.byteCount)
            XCTAssertEqual(try HardDiscImage.open(path: path, sectorSize: large.sectorSize).geometry, large, "the boot block describes the new shape")
            XCTAssertEqual(try Self.contents(path), before)
            // The new space is usable: more than the old drive's size in one file.
            try ADFSHardDiscWriter.add(path: path, items: [.init(path: ["Huge"], data: [UInt8](repeating: 1, count: small.byteCount / 2 + (4 << 20)), type: 0xFFD)])
            try ADFSHardDiscWriter.add(path: path, items: [.init(path: ["Huge"], data: [], type: 0xFFD)])

            // Back down: the files reach past the end until compacted.
            let half = HardDiscGeometry(cylinders: small.cylinders / 2, heads: small.heads, sectorsPerTrack: small.sectorsPerTrack, sectorSize: small.sectorSize)
            XCTAssertThrowsError(try ADFSHardDiscWriter.resize(path: path, to: half)) { e in
                guard case .tooSmall(let n, let c)? = e as? ADFSHardDiscWriter.WriteError else { return XCTFail("\(e)") }
                XCTAssertGreaterThan(n, half.byteCount)
                XCTAssertLessThanOrEqual(c, half.byteCount)
            }
            XCTAssertEqual(try Self.contents(path)["File5"], before["File5"], "a refused resize changes nothing")
            let shrunk = try ADFSHardDiscWriter.resize(path: path, to: half, compact: true)
            XCTAssertEqual(shrunk.size, half.byteCount)
            XCTAssertEqual(try HardDiscImage.open(path: path, sectorSize: half.sectorSize).geometry, half)
            var expected = before
            expected["Huge"] = []
            XCTAssertEqual(try Self.contents(path), expected)
            XCTAssertThrowsError(try ADFSHardDiscWriter.resize(path: path, to: HardDiscGeometry(cylinders: 10, heads: 4)), "too small even compacted")
            XCTAssertThrowsError(try ADFSHardDiscWriter.resize(path: path, to: small.sectorSize == 256 ? HardDiscGeometry.idePresets[1].geometry : HardDiscGeometry.presets[2].geometry), "sector size is kept")
        }
    }

    /// RISC OS uses a grown drive's new space.
    func testRISCOSUsesGrownDrive() throws {
        guard let dir = GameSmokeTests.romDir("riscos3_11") else { throw XCTSkip("RISC OS 3.11 ROM not present") }
        let path = NSTemporaryDirectory() + "macarch-grown-\(UUID().uuidString).hdf"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try ADFSHardDiscBuilder.create(path: path, geometry: HardDiscGeometry.presets[0].geometry, name: "Grow", items: [
            .init(path: ["Notes"], data: Array("Still here\n".utf8), type: 0xFFF),
            .init(path: ["Filler"], data: [UInt8](repeating: 7, count: 18 << 20), type: 0xFFD),
        ])
        try ADFSHardDiscWriter.resize(path: path, to: HardDiscGeometry.presets[1].geometry)
        var c = MachineConfiguration(model: .a440)
        c.romPaths = [dir]
        c.hardDiscs = [path]
        c.powerOnKeys = [0x34]
        let m = try Machine(configuration: c)
        m.powerOn()
        m.run(seconds: 25)
        m.keyDown(0x0C); m.run(seconds: 0.1); m.keyUp(0x0C) // F12
        m.run(seconds: 1)
        // 3 MB (of ROM) didn't fit before (about 1.2 MB was free).
        m.scheduleTyping("*Type :4.$.Notes\n*Save :4.$.Big 3800000 +300000\n*CDir :4.$.Dir\n*Ex :4.$\n", intervalMs: 40)
        m.run(seconds: 40)
        m.hdc?.drives.forEach { $0?.synchronize() }
        let text = m.recentText
        XCTAssertTrue(text.contains("Still here"), String(text.suffix(600)))
        for bad in ["Broken directory", "Bad free space map", "Disc full", "Map full", "Disc error", "not found"] {
            XCTAssertFalse(text.contains(bad), "\(bad): " + String(text.suffix(600)))
        }
        let after = try Self.contents(path)
        XCTAssertEqual(after["Big"]?.count, 0x300000)
        XCTAssertGreaterThan(try ADFSHardDiscWriter.usage(path: path).usedEnd, HardDiscGeometry.presets[0].geometry.byteCount, "written beyond the old end")
    }

    // MARK: Copying between drive types

    /// An ST506 drive's files, empty directory and name on a new IDE
    /// drive, which an A5000 reads.
    func testCopyST506DriveToIDE() throws {
        let st = NSTemporaryDirectory() + "macarch-st-\(UUID().uuidString).hdf"
        let ide = NSTemporaryDirectory() + "macarch-ide-\(UUID().uuidString).hdf"
        defer { try? FileManager.default.removeItem(atPath: st); try? FileManager.default.removeItem(atPath: ide) }
        try ADFSHardDiscBuilder.create(path: st, geometry: HardDiscGeometry.presets[0].geometry, name: "Games", items: [
            .init(path: ["!App", "!Run"], data: Array("Echo Copied by MacArch\n".utf8), load: 0xFFFF_EB12, exec: 0x3456_7890, attributes: 0x0B & 0x37),
            .init(path: ["!App", "Data"], data: (0..<40_000).map { UInt8(truncatingIfNeeded: $0 &* 3) }, type: 0xFFD),
        ], directories: [["!App", "Scrap"]])
        try ADFSHardDiscWriter.copy(from: st, to: ide, geometry: HardDiscGeometry.idePresets[0].geometry)

        let a = try ADFSHardDiscWriter.contents(path: st), b = try ADFSHardDiscWriter.contents(path: ide)
        XCTAssertEqual(b.name, "Games")
        XCTAssertEqual(b.directories, [["!App"], ["!App", "Scrap"]])
        XCTAssertEqual(b.files.map(\.path), a.files.map(\.path))
        for (x, y) in Swift.zip(a.files, b.files) {
            XCTAssertEqual([x.load, x.exec], [y.load, y.exec])
            XCTAssertEqual(x.attributes, y.attributes)
            XCTAssertEqual(x.data, y.data)
        }
        XCTAssertEqual(try ADFSHardDiscWriter.usage(path: ide).geometry, HardDiscGeometry.idePresets[0].geometry)

        guard let dir = GameSmokeTests.romDir("riscos3_11") else { throw XCTSkip("RISC OS 3.11 ROM not present") }
        var c = MachineConfiguration(model: .a5000)
        c.romPaths = [dir]
        c.hardDiscs = [ide]
        c.powerOnKeys = [0x34]
        let m = try Machine(configuration: c)
        m.powerOn()
        m.run(seconds: 25)
        m.keyDown(0x0C); m.run(seconds: 0.1); m.keyUp(0x0C) // F12
        m.run(seconds: 1)
        m.scheduleTyping("*Run :4.$.!App.!Run\n*Ex :4.$.!App\n", intervalMs: 40)
        m.run(seconds: 15)
        let text = m.recentText
        XCTAssertTrue(text.contains("Copied by MacArch"), String(text.suffix(600)))
        XCTAssertTrue(text.contains("Scrap"), String(text.suffix(600)))
        for bad in ["Broken directory", "Bad free space map", "not found", "Disc error"] {
            XCTAssertFalse(text.contains(bad), "\(bad): " + String(text.suffix(600)))
        }
    }
}

extension HardDiscBuilderTests {
    /// A new drive with !System and !Scrap: RISC OS sees them, and running
    /// their !Boot files (as the Filer does) loads their icons and points
    /// System: and Wimp$Scrap at them.
    func testNewDriveWithSystem() throws {
        guard let dir = GameSmokeTests.romDir("riscos3_11") else { throw XCTSkip("RISC OS 3.11 ROM not present") }
        let path = NSTemporaryDirectory() + "macarch-system-\(UUID().uuidString).hdf"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try ADFSFormatter.createFormattedImage(path: path, geometry: HardDiscGeometry(cylinders: 615, heads: 4), name: "Sys", system: true)
        XCTAssertEqual(Set(try Self.listing(path).keys), Set(["!System", "!Scrap"].flatMap { app in
            ["!Boot", "!Run", "!Help", "!Sprites", "!Sprites22"].map { "\(app).\($0)" } }))
        let existing = ADFSFormatter.withSystem([.init(path: ["!System", "!Boot"], data: [], type: 0xFEB)])
        XCTAssertEqual(existing.items.filter { $0.path[0] == "!System" }.count, 1, "an existing !System is left alone")
        XCTAssertEqual(existing.directories, [["!Scrap", "ScrapDir"]], "and !Scrap is still added")
        var c = MachineConfiguration(model: .a440)
        c.romPaths = [dir]
        c.hardDiscs = [path]
        c.powerOnKeys = [0x34]
        let m = try Machine(configuration: c)
        m.powerOn()
        m.run(seconds: 25)
        m.keyDown(0x0C); m.run(seconds: 0.1); m.keyUp(0x0C) // F12
        m.run(seconds: 1)
        m.scheduleTyping("*Run :4.$.!System.!Boot\n*Run :4.$.!Scrap.!Boot\n*Ex System:Modules\n*Show System$Path\n*Show Wimp$Scrap*\n", intervalMs: 40)
        m.run(seconds: 15)
        let text = m.recentText
        XCTAssertTrue(text.contains("$.!System."), String(text.suffix(400)))
        XCTAssertTrue(text.contains("$.!Scrap.ScrapDir.ScrapFile"), String(text.suffix(400)))
        XCTAssertFalse(text.contains("not found") || text.contains("Broken directory") || text.contains("sprite"), String(text.suffix(400)))
    }
}
