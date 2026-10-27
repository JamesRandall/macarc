import Foundation
import XCTest
@testable import ArchimedesCore

/// Changing the files on ADFS discs (`ADFSVolume`): blank D, E and L floppies,
/// real E and F discs, old-map hard discs; and RISC OS reading the changes.
final class DiscEditingTests: XCTestCase {
    static func store(_ format: ADFSFloppyFormatter.Format) -> ADFSMemoryStore {
        ADFSMemoryStore(bytes: ADFSFloppyFormatter.blank(format, name: "Blank"), sectorSize: format == .l ? 256 : 1024)
    }

    static func disc(_ name: String) throws -> ADFSMemoryStore {
        let url = ClassicsTests.root.appendingPathComponent("top25/" + name)
        guard let d = FileManager.default.contents(atPath: url.path) else { throw XCTSkip("\(name) not present in ./top25") }
        var bytes = [UInt8](d)
        // Some images are short of the last track.
        let full = bytes.count <= 819_200 ? 819_200 : 1_638_400
        bytes += [UInt8](repeating: 0, count: full - bytes.count)
        return ADFSMemoryStore(bytes: bytes, sectorSize: 1024)
    }

    /// Every file on the disc, by path, with its contents.
    static func files(_ v: ADFSVolume, _ path: [String] = []) throws -> [String: [UInt8]] {
        var out: [String: [UInt8]] = [:]
        for e in try v.entries(at: path) {
            let p = (path + [e.name]).joined(separator: ".")
            if e.isDirectory { out.merge(try files(v, path + [e.name])) { a, _ in a } } else { out[p] = try v.contents(of: e.name, at: path) }
        }
        return out
    }

    func testBlankDiscsAreEmptyAndSound() throws {
        for format in ADFSFloppyFormatter.Format.allCases {
            let v = try ADFSVolume(store: Self.store(format))
            XCTAssertEqual(v.formatName, "ADFS " + format.rawValue.uppercased())
            XCTAssertEqual(try v.entries(at: []), [])
            XCTAssertEqual(v.discName, "Blank")
            XCTAssertEqual(try v.check(), [])
            XCTAssertEqual(v.freeBytes, [.e: 819_200 - 4096, .d: 819_200 - 0xC00, .l: 655_360 - 0x700][format])
            XCTAssertEqual(v.hasOldDirectories, format == .l)
        }
        // The reader the game library uses agrees.
        XCTAssertEqual(try ADFSDiscReader.read(bytes: ADFSFloppyFormatter.blank(.e, name: "X")).items.count, 0)
    }

    func testSavesReadsRenamesAndDeletes() throws {
        for format in ADFSFloppyFormatter.Format.allCases {
            let store = Self.store(format)
            let big = (0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 13) }
            try ADFSVolume.edit(store) { v in
                let (l, e) = ADFSVolume.stamp(type: 0xFFF, date: Date(timeIntervalSince1970: 1_000_000_000))
                try v.save(Array("Hello\n".utf8), name: "ReadMe", at: [], load: l, exec: e)
                try v.makeDirectory("!App", at: [])
                try v.save(Array("Run <Obey$Dir>.!RunImage\n".utf8), name: "!Run", at: ["!App"], load: 0xFFFFEB00, exec: 0)
                try v.save(big, name: "Big", at: ["!App"], load: 0x8000, exec: 0x8000)
                try v.makeDirectory("Deep", at: ["!App"])
                try v.save([1, 2, 3], name: "Tiny", at: ["!App", "Deep"], load: 0xFFFFFD00, exec: 0)
            }
            var v = try ADFSVolume(store: store)
            XCTAssertEqual(try v.check(), [], "\(format)")
            XCTAssertEqual(try v.entries(at: []).map(\.name), ["!App", "ReadMe"], "sorted")
            let readMe = try v.entry("readme", at: [])
            XCTAssertEqual(readMe.fileType, 0xFFF)
            XCTAssertEqual(readMe.date, Date(timeIntervalSince1970: 1_000_000_000))
            XCTAssertEqual(readMe.access, "WR/")
            XCTAssertEqual(try v.contents(of: "Big", at: ["!App"]), big)
            XCTAssertEqual(try v.entry("Big", at: ["!App"]).fileType, nil, "untyped")
            XCTAssertEqual(try v.contents(of: "Tiny", at: ["!App", "Deep"]), [1, 2, 3])
            if format != .l { XCTAssertEqual(try ADFSDiscReader.read(bytes: store.bytes).items.count, 4, "the game library's reader sees them") }

            try ADFSVolume.edit(store) { v in
                try v.rename("Deep", at: ["!App"], to: "Deeper")
                try v.rename("ReadMe", at: [], to: "Notes")
                try v.setInfo("Notes", at: [], attributes: 0x37)
            }
            v = try ADFSVolume(store: store)
            XCTAssertEqual(try v.check(), [])
            XCTAssertEqual(try v.entry("Notes", at: []).access, format == .l ? "LWR/" : "LWR/wr", "old directories keep no public access")
            XCTAssertEqual(try v.contents(of: "Tiny", at: ["!App", "Deeper"]), [1, 2, 3])
            XCTAssertEqual(try v.title(at: ["!App", "Deeper"]), "Deeper")
            XCTAssertTrue(try v.entry("Notes", at: []).isLocked)

            // Locked things, and directories with things in, stay.
            XCTAssertThrowsError(try ADFSVolume.edit(store) { try $0.delete("Notes", at: []) }) { XCTAssertEqual($0 as? ADFSError, .locked("Notes")) }
            XCTAssertThrowsError(try ADFSVolume.edit(store) { try $0.delete("!App", at: []) }) { XCTAssertEqual($0 as? ADFSError, .notEmpty("!App")) }
            let free = try ADFSVolume(store: store).freeBytes
            try ADFSVolume.edit(store) { try $0.delete("!App", at: [], recursive: true) }
            v = try ADFSVolume(store: store)
            XCTAssertEqual(try v.check(), [])
            XCTAssertEqual(try v.entries(at: []).map(\.name), ["Notes"])
            XCTAssertGreaterThan(v.freeBytes, free + big.count, "the space is free again")
        }
    }

    func testAFailedChangeLeavesTheDiscAlone() throws {
        for format in ADFSFloppyFormatter.Format.allCases {
            let store = Self.store(format)
            try ADFSVolume.edit(store) { try $0.save([9], name: "Keep", at: [], load: 0, exec: 0) }
            let before = store.bytes
            XCTAssertThrowsError(try ADFSVolume.edit(store) { v in
                try v.save([UInt8](repeating: 1, count: 500_000), name: "A", at: [], load: 0, exec: 0)
                try v.save([UInt8](repeating: 2, count: 500_000), name: "B", at: [], load: 0, exec: 0)
            }) { error in
                guard case .discFull = error as? ADFSError else { return XCTFail("\(error)") }
            }
            XCTAssertEqual(store.bytes, before, "\(format): all or nothing")
            XCTAssertThrowsError(try ADFSVolume.edit(store) { try $0.save([1], name: "Bad.Name", at: [], load: 0, exec: 0) })
            XCTAssertThrowsError(try ADFSVolume.edit(store) { v in
                for i in 0..<78 { try v.save([1], name: "F\(i)", at: [], load: 0, exec: 0) }
            }) { XCTAssertEqual($0 as? ADFSError, .directoryFull("$")) }
            XCTAssertEqual(store.bytes, before)
        }
    }

    /// L format's old directories: access in the names' top bits, as RISC
    /// OS writes them, ASCII names only, and 47 entries.
    func testOldDirectories() throws {
        let store = Self.store(.l)
        try ADFSVolume.edit(store) { v in
            try v.makeDirectory("Sub", at: [])
            try v.save([1, 2], name: "Top", at: [], load: 0x8000, exec: 0x8000, attributes: 0x07)
        }
        // As RISC OS 3.11's *CDir and *Save left them: "Sub" with D in the
        // fourth byte's top bit (its terminator), "Top" with R, W and L.
        let root = Array(store.bytes[0x200..<0x700])
        XCTAssertEqual(Array(root[5..<9]), [0x53, 0x75, 0x62, 0x8D])
        XCTAssertEqual(Array(root[31..<35]), [0xD4, 0xEF, 0xF0, 0x0D])
        XCTAssertEqual(root[30], root[0], "an entry's sequence number is the directory's when it changed")
        XCTAssertEqual(Array(store.bytes[0x200 + 1228..<0x200 + 1234]), Array("Blank\r".utf8), "the root is named after the disc")
        var v = try ADFSVolume(store: store)
        XCTAssertEqual(try v.check(), [])
        XCTAssertEqual(try v.entries(at: []).map(\.name), ["Sub", "Top"])
        XCTAssertEqual(try v.entry("Top", at: []).access, "LWR/")
        XCTAssertEqual(try v.entry("Sub", at: []).length, 1280)
        XCTAssertEqual(try v.title(at: ["Sub"]), "Sub")

        XCTAssertThrowsError(try ADFSVolume.edit(store) { try $0.save([1], name: "Caf\u{E9}", at: [], load: 0, exec: 0) }) {
            XCTAssertEqual($0 as? ADFSError, .badName("Caf\u{E9}"))
        }
        try ADFSVolume.edit(store) { v in
            try ADFSHostFile(name: "My\u{A0}Notes", load: 0, exec: 0, attributes: 0x03, data: [7], children: []).add(to: v, at: ["Sub"])
        }
        v = try ADFSVolume(store: store)
        XCTAssertEqual(try v.contents(of: "My_Notes", at: ["Sub"]), [7], "a Mac space comes in as _")

        XCTAssertThrowsError(try ADFSVolume.edit(store) { v in
            for i in 0..<47 { try v.save([1], name: "F\(i)", at: ["Sub"], load: 0, exec: 0) }
        }) { XCTAssertEqual($0 as? ADFSError, .directoryFull("$.Sub")) }
        try ADFSVolume.edit(store) { v in
            for i in 0..<46 { try v.save([UInt8(i)], name: "F\(i)", at: ["Sub"], load: 0, exec: 0) }
        }
        v = try ADFSVolume(store: store)
        XCTAssertEqual(try v.entries(at: ["Sub"]).count, 47)
        XCTAssertEqual(try v.contents(of: "F45", at: ["Sub"]), [45])
        XCTAssertEqual(try v.check(), [])
    }

    /// ADFS numbers an L disc's sectors through side 0, then side 1; D, E
    /// and F alternate sides track by track.
    func testFloppySectorOrder() throws {
        let l = FloppyImage.blank(.l, name: "L"), e = FloppyImage.blank(.e, name: "E")
        try ADFSFloppyStore(image: l).write(16 * 256, [0xAB])
        XCTAssertEqual(l.readSector(side: 0, track: 1, sectorID: 0)?.first, 0xAB)
        try ADFSFloppyStore(image: l).write(80 * 16 * 256, [0xCD])
        XCTAssertEqual(l.readSector(side: 1, track: 0, sectorID: 0)?.first, 0xCD)
        try ADFSFloppyStore(image: e).write(5 * 1024, [0xEF])
        XCTAssertEqual(e.readSector(side: 1, track: 0, sectorID: 0)?.first, 0xEF)
    }

    func testFillingAndFreeingFragmentsTheNewMap() throws {
        let store = Self.store(.e)
        // Alternate sizes, delete every other one, then fit one bigger than any gap.
        try ADFSVolume.edit(store) { v in
            for i in 0..<20 { try v.save([UInt8](repeating: UInt8(i), count: 30_000), name: "F\(i)", at: [], load: 0, exec: 0) }
        }
        try ADFSVolume.edit(store) { v in
            for i in stride(from: 0, to: 20, by: 2) { try v.delete("F\(i)", at: []) }
        }
        let free = try ADFSVolume(store: store).freeBytes
        let spread = (0..<300_000).map { UInt8(truncatingIfNeeded: $0 / 7) }
        try ADFSVolume.edit(store) { try $0.save(spread, name: "Spread", at: [], load: 0, exec: 0) }
        let v = try ADFSVolume(store: store)
        XCTAssertEqual(try v.check(), [])
        XCTAssertEqual(try v.contents(of: "Spread", at: []), spread)
        XCTAssertGreaterThan(try v.map.extents(v.entry("Spread", at: []).address, length: spread.count).count, 1, "in several fragments")
        XCTAssertEqual(free - v.freeBytes, 300_032, "whole sectors")
        for i in stride(from: 1, to: 20, by: 2) { XCTAssertEqual(try v.contents(of: "F\(i)", at: []), [UInt8](repeating: UInt8(i), count: 30_000)) }
        XCTAssertEqual(try ADFSDiscReader.read(bytes: store.bytes).items.first { $0.path == ["Spread"] }?.data, spread)
    }

    func testUndo() throws {
        let store = Self.store(.e)
        try ADFSVolume.edit(store) { try $0.save([1, 2, 3], name: "One", at: [], load: 0, exec: 0) }
        let change = try ADFSVolume.edit(store) { v in
            try v.delete("One", at: [])
            try v.save([4, 5], name: "Two", at: [], load: 0, exec: 0)
        }
        let undo = try change.revert(on: store)
        var v = try ADFSVolume(store: store)
        XCTAssertEqual(try v.entries(at: []).map(\.name), ["One"])
        XCTAssertEqual(try v.check(), [])
        _ = try undo.revert(on: store)
        v = try ADFSVolume(store: store)
        XCTAssertEqual(try v.entries(at: []).map(\.name), ["Two"], "and redo")
        // Not once something else has changed it.
        try ADFSVolume.edit(store) { try $0.save([6], name: "Three", at: [], load: 0, exec: 0) }
        XCTAssertThrowsError(try undo.revert(on: store)) { XCTAssertEqual($0 as? ADFSError, .changedSince) }
    }

    /// Every disc there is to hand reads without a problem.
    func testRealDiscsCheckOut() throws {
        let folder = ClassicsTests.root.appendingPathComponent("top25")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".adf") }.sorted()
        guard !names.isEmpty else { throw XCTSkip("no discs in ./top25") }
        var formats: [String: Int] = [:]
        for name in names {
            let v = try ADFSVolume(store: Self.disc(name))
            formats[v.formatName, default: 0] += 1
            XCTAssertEqual(try v.check(), [], name)
            XCTAssertFalse(try Self.files(v).isEmpty, name)
        }
        print("checked", formats)
    }

    func testRealEDisc() throws {
        let store = try Self.disc("Zarch (1987)(Superior Software).adf")
        let v0 = try ADFSVolume(store: store)
        XCTAssertEqual(v0.formatName, "ADFS E")
        XCTAssertEqual(v0.discName, "Zarch")
        XCTAssertEqual(try v0.check(), [])
        let before = try Self.files(v0)
        XCTAssertFalse(before.isEmpty)
        try ADFSVolume.edit(store) { v in
            try v.save([UInt8](repeating: 7, count: 12_345), name: "Added", at: ["!Zarch"], load: 0, exec: 0)
            try v.setDiscName("Zarch2")
            v.setBootOption(2)
        }
        let v = try ADFSVolume(store: store)
        XCTAssertEqual(try v.check(), [])
        XCTAssertEqual(v.discName, "Zarch2")
        XCTAssertEqual(v.bootOption, 2)
        var after = try Self.files(v)
        XCTAssertEqual(after.removeValue(forKey: "!Zarch.Added"), [UInt8](repeating: 7, count: 12_345))
        XCTAssertEqual(after, before, "everything else as it was")
    }

    func testRealDDisc() throws {
        let store = try Self.disc("Pacmania (1991)(Krisalis).adf")
        let v0 = try ADFSVolume(store: store)
        XCTAssertEqual(v0.formatName, "ADFS D")
        XCTAssertEqual(try v0.check(), [])
        let before = try Self.files(v0)
        let first = try XCTUnwrap(try v0.entries(at: []).first { !$0.isDirectory && !$0.isLocked })
        try ADFSVolume.edit(store) { v in
            try v.save([UInt8](repeating: 3, count: 5000), name: "Added", at: [], load: 0, exec: 0)
            try v.delete(first.name, at: [])
        }
        let v = try ADFSVolume(store: store)
        XCTAssertEqual(try v.check(), [])
        var after = try Self.files(v)
        XCTAssertEqual(after.removeValue(forKey: "Added"), [UInt8](repeating: 3, count: 5000))
        var expected = before
        expected[first.name] = nil
        XCTAssertEqual(after, expected)
    }

    func testRealFDisc() throws {
        let store = try Self.disc("Stunt Racer 2000 (1994)(Fourth Dimension)(RPC compatible).adf")
        let v0 = try ADFSVolume(store: store)
        XCTAssertEqual(v0.formatName, "ADFS F")
        XCTAssertEqual(v0.discName, "SR2KComp")
        XCTAssertEqual(try v0.check(), [])
        let before = try Self.files(v0)
        let blob = (0..<120_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        try ADFSVolume.edit(store) { v in
            try v.makeDirectory("Extra", at: [])
            try v.save(blob, name: "Blob", at: ["Extra"], load: 0, exec: 0)
            try v.setDiscName("SR2K")
        }
        let v = try ADFSVolume(store: store)
        XCTAssertEqual(try v.check(), [])
        XCTAssertEqual(v.discName, "SR2K")
        var after = try Self.files(v)
        XCTAssertEqual(after.removeValue(forKey: "Extra.Blob"), blob)
        XCTAssertEqual(after, before)
        // The boot block's copy of the disc record follows the map's.
        let boot = try store.read(0xC00, 0x200)
        XCTAssertEqual(Array(boot[0x1C0 + 22..<0x1C0 + 26]), Array("SR2K".utf8))
        XCTAssertEqual(ADFSFormatter.checksum(boot, 0, 0x200), boot[0x1FF])
    }

    func testOldMapHardDisc() throws {
        for g in [HardDiscGeometry(cylinders: 615, heads: 4), HardDiscGeometry(cylinders: 977, heads: 5, sectorsPerTrack: 17, sectorSize: 512)] {
            let path = NSTemporaryDirectory() + "macarch-edit-\(UUID().uuidString).hdf"
            defer { try? FileManager.default.removeItem(atPath: path) }
            try ADFSHardDiscBuilder.create(path: path, geometry: g, name: "Base", items: [
                .init(path: ["Games", "Notes"], data: [UInt8](repeating: 1, count: 300), type: 0xFFF),
                .init(path: ["zeta"], data: [1, 2, 3], type: 0xFFD),
            ])
            let store = try ADFSFileStore(path: path, sectorSize: g.sectorSize, writable: true)
            try ADFSVolume.edit(store) { v in
                try v.delete("Notes", at: ["Games"])
                try v.save([UInt8](repeating: 5, count: 70_000), name: "Big", at: ["Games"], load: 0, exec: 0)
                try v.rename("zeta", at: [], to: "Zeta2")
            }
            let v = try ADFSVolume(store: store)
            XCTAssertEqual(v.formatName, "Old-map hard disc")
            XCTAssertEqual(v.discName, "Base")
            XCTAssertEqual(try v.check(), [])
            XCTAssertEqual(try Self.files(v), ["Games.Big": [UInt8](repeating: 5, count: 70_000), "Zeta2": [1, 2, 3]])
            XCTAssertEqual(try ADFSHardDiscWriter.contents(path: path).files.count, 2, "the hard disc writer agrees")
        }
    }

    // MARK: Mac files

    func testMacFilesComeInTyped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macarch-host-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("!Game")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("Run <Obey$Dir>.!RunImage\n".utf8).write(to: app.appendingPathComponent("!Run"))
        try Data([1, 2, 3]).write(to: app.appendingPathComponent("Sprites,ff9"))
        try Data([4]).write(to: app.appendingPathComponent("Code,00008000-0000801c"))
        try Data("10 PRINT \"HI\"\n20 END\n".utf8).write(to: app.appendingPathComponent("Prog.bas"))
        try Data("Read me\n".utf8).write(to: app.appendingPathComponent("Read Me.txt"))
        try Data([5, 6]).write(to: app.appendingPathComponent("odd.thing"))
        try Data([7]).write(to: app.appendingPathComponent("ELITE"))
        try Data("$.ELITE     FF1900 FF8023 000001 L\n".utf8).write(to: app.appendingPathComponent("ELITE.inf"))
        try Data([8]).write(to: app.appendingPathComponent(".DS_Store"))
        try Data([9]).write(to: app.appendingPathComponent("AVeryLongFileName"))

        let host = try XCTUnwrap(try ADFSHostFile.read(app))
        XCTAssertEqual(host.fileCount, 8)
        let store = Self.store(.e)
        try ADFSVolume.edit(store) { try host.add(to: $0, at: []) }
        let v = try ADFSVolume(store: store)
        XCTAssertEqual(try v.check(), [])
        let entries = Dictionary(uniqueKeysWithValues: try v.entries(at: ["!Game"]).map { ($0.name, $0) })
        XCTAssertEqual(Set(entries.keys), ["!Run", "Sprites", "Code", "Prog", "Read\u{A0}Me", "odd/thing", "ELITE", "AVeryLongF"])
        XCTAssertEqual(entries["!Run"]?.fileType, 0xFEB)
        XCTAssertEqual(entries["Sprites"]?.fileType, 0xFF9)
        XCTAssertEqual(entries["Code"]?.load, 0x8000)
        XCTAssertEqual(entries["Code"]?.exec, 0x801C)
        XCTAssertEqual(entries["Prog"]?.fileType, 0xFFB)
        XCTAssertTrue(BBCBasic.isProgram(try v.contents(of: "Prog", at: ["!Game"])), "tokenised")
        XCTAssertEqual(entries["Read\u{A0}Me"]?.fileType, 0xFFF)
        XCTAssertEqual(entries["odd/thing"]?.fileType, 0xFFD)
        XCTAssertEqual(entries["ELITE"]?.load, 0xFFFF_1900)
        XCTAssertEqual(entries["ELITE"]?.isLocked, true)

        // Out again, and back: the same.
        let out = dir.appendingPathComponent("out")
        try ADFSExport.write(try v.entry("!Game", at: []), from: v, at: [], to: out)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: out.path))
        XCTAssertTrue(names.isSuperset(of: ["!Run,feb", "Sprites,ff9", "Code,00008000-0000801c", "Read Me,fff", "odd.thing,ffd"]), "\(names)")
        let again = try XCTUnwrap(try ADFSHostFile.read(out))
        let store2 = Self.store(.d)
        try ADFSVolume.edit(store2) { try again.add(to: $0, at: []) }
        let v2 = try ADFSVolume(store: store2)
        XCTAssertEqual(try v2.entries(at: ["out"]).map { [$0.name, String($0.load), String($0.exec)] },
                       try v.entries(at: ["!Game"]).map { [$0.name, String($0.load), String($0.exec)] })
        XCTAssertEqual(try Self.files(v2, ["out"]).count, 8)
    }

    func testFileTypeNames() {
        XCTAssertEqual(RISCOSFileType.name(0xFFF), "Text")
        XCTAssertEqual(RISCOSFileType.name(0x123), "&123")
        XCTAssertEqual(RISCOSFileType.type(named: "basic"), 0xFFB)
        XCTAssertEqual(RISCOSFileType.type(named: "&ff9"), 0xFF9)
        XCTAssertEqual(RISCOSFileType.type(named: "1A"), 0x01A)
        XCTAssertNil(RISCOSFileType.type(named: "nonsense"))
    }

    // MARK: RISC OS

    /// RISC OS reads files put on a disc while it runs (after the disc has
    /// been looked at), and what it writes afterwards leaves a disc this
    /// can still read and change.
    func testRISCOSSeesChangesAndWritesSoundly() throws {
        for (format, rom, model) in [(ADFSFloppyFormatter.Format.e, "riscos3_11", MachineModel.a3000), (.d, "riscos2_00", .a310),
                                     (.l, "riscos3_11", .a3000), (.l, "riscos2_00", .a310)] {
            guard let dir = GameSmokeTests.romDir(rom) else { throw XCTSkip("\(rom) ROM not present") }
            let image = FloppyImage(data: ADFSFloppyFormatter.blank(format, name: "Test"), geometry: MediaDetector.detect(ADFSFloppyFormatter.blank(format, name: "Test")).geometry!)
            var c = MachineConfiguration(model: model)
            c.romPaths = [dir]
            c.powerOnKeys = [0x34]
            let m = try Machine(configuration: c)
            m.insertFloppy(image)
            m.powerOn()
            m.run(seconds: 20)
            m.keyDown(0x0C); m.run(seconds: 0.1); m.keyUp(0x0C) // F12
            m.run(seconds: 1)
            m.scheduleTyping("*Cat :0\n", intervalMs: 40)
            m.run(seconds: 8)
            // Now change it, once the drive is quiet.
            var waited = 0.0
            while !m.floppyIsIdle() && waited < 20 { m.run(seconds: 0.25); waited += 0.25 }
            XCTAssertTrue(m.floppyIsIdle(), "\(format)")
            try ADFSVolume.edit(ADFSFloppyStore(image: image)) { v in
                try v.makeDirectory("Docs", at: [])
                let (l, e) = ADFSVolume.stamp(type: 0xFFF, date: Date())
                try v.save(Array("Put here by MacArch\n".utf8), name: "Note", at: ["Docs"], load: l, exec: e)
            }
            m.noteFloppyChanged()
            m.scheduleTyping("*Type :0.$.Docs.Note\n*Save :0.$.Docs.Mem 8000 +1000\n*CDir :0.$.Made\n*Cat :0.$.Docs\n", intervalMs: 40)
            m.run(seconds: 25)
            let text = m.recentText
            XCTAssertTrue(text.contains("Put here by MacArch"), "\(format): " + String(text.suffix(600)))
            XCTAssertFalse(text.contains("Broken directory") || text.contains("Bad free space map") || text.contains("not found"), "\(format): " + String(text.suffix(600)))
            // What RISC OS wrote.
            let v = try ADFSVolume(store: ADFSFloppyStore(image: image))
            XCTAssertEqual(try v.check(), [], "\(format)")
            XCTAssertEqual(Set(try v.entries(at: ["Docs"]).map(\.id)), ["NOTE", "MEM"], "\(format)")
            XCTAssertEqual(try v.entry("Mem", at: ["Docs"]).length, 0x1000)
            XCTAssertTrue(try v.entry("Made", at: []).isDirectory)
            // And changing it again after RISC OS has.
            try ADFSVolume.edit(ADFSFloppyStore(image: image)) { v in
                try v.delete("Mem", at: ["Docs"])
                try v.save([UInt8](repeating: 1, count: 40_000), name: "More", at: ["Made"], load: 0, exec: 0)
            }
            XCTAssertEqual(try ADFSVolume(store: ADFSFloppyStore(image: image)).check(), [])
        }
    }

    /// A hard disc changed as the app changes one (the machine's writes
    /// held off, then a restart) reads in RISC OS.
    func testRISCOSReadsAChangedHardDiscAfterRestart() throws {
        guard let dir = GameSmokeTests.romDir("riscos3_11") else { throw XCTSkip("RISC OS 3.11 ROM not present") }
        let path = NSTemporaryDirectory() + "macarch-hdedit-\(UUID().uuidString).hdf"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let g = HardDiscGeometry(cylinders: 615, heads: 4)
        try ADFSHardDiscBuilder.create(path: path, geometry: g, name: "Edit", items: [
            .init(path: ["Old"], data: Array("Old file\n".utf8), type: 0xFFF),
        ])
        var c = MachineConfiguration(model: .a440)
        c.romPaths = [dir]
        c.hardDiscs = [path]
        c.powerOnKeys = [0x34]
        var m = try Machine(configuration: c)
        m.powerOn()
        m.run(seconds: 20)
        m.hardDiscImages.forEach { $0?.synchronize(); $0?.suppressWrites = true }
        try ADFSVolume.edit(ADFSFileStore(path: path, sectorSize: 256, writable: true)) { v in
            try v.delete("Old", at: [])
            try v.makeDirectory("New", at: [])
            let (l, e) = ADFSVolume.stamp(type: 0xFFF, date: Date())
            try v.save(Array("Changed from the Mac\n".utf8), name: "Note", at: ["New"], load: l, exec: e)
        }
        m = try Machine(configuration: c)
        m.powerOn()
        m.run(seconds: 25)
        m.keyDown(0x0C); m.run(seconds: 0.1); m.keyUp(0x0C) // F12
        m.run(seconds: 1)
        m.scheduleTyping("*Type :4.$.New.Note\n*Cat :4\n", intervalMs: 40)
        m.run(seconds: 10)
        let text = m.recentText
        XCTAssertTrue(text.contains("Changed from the Mac"), String(text.suffix(400)))
        XCTAssertFalse(text.contains("Broken directory") || text.contains("Bad free space map"), String(text.suffix(400)))
    }
}
