import XCTest
@testable import ArchimedesCore

final class FloppyFormatTests: XCTestCase {
    /// MFM cells for a stream of bytes; `sync` bytes are A1 with the missing clock.
    struct MFMWriter {
        var cells: [UInt8] = []
        var last: UInt8 = 0
        mutating func byte(_ b: UInt8) {
            for k in (0..<8).reversed() {
                let d = (b >> k) & 1
                cells.append(last == 0 && d == 0 ? 1 : 0)
                cells.append(d)
                last = d
            }
        }
        mutating func sync() {
            for c in [0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1] as [UInt8] { cells.append(c) }
            last = 1
        }
        mutating func gap(_ n: Int, _ v: UInt8 = 0x4E) { for _ in 0..<n { byte(v) } }
        mutating func field(_ mark: UInt8, _ body: [UInt8], corrupt: Bool = false) {
            gap(12, 0); sync(); sync(); sync()
            byte(mark); body.forEach { byte($0) }
            var crc = CRC16.ccitt([0xA1, 0xA1, 0xA1, mark] + body)
            if corrupt { crc ^= 0x5555 }
            byte(UInt8(crc >> 8)); byte(UInt8(crc & 0xFF))
        }
    }

    /// An ADFS D/E track: sectors 0-4 of 1 KB, with optional faults.
    static func track(_ t: Int, side: Int, skip: UInt8? = nil, badData: UInt8? = nil) -> [UInt8] {
        var w = MFMWriter()
        w.gap(60)
        for id: UInt8 in 0..<5 where id != skip {
            w.field(0xFE, [UInt8(t), UInt8(side), id, 3])
            w.gap(22)
            w.field(0xFB, (0..<1024).map { UInt8(truncatingIfNeeded: $0 &+ Int(id) * 7 &+ t &+ side * 3) }, corrupt: id == badData)
            w.gap(40)
        }
        while w.cells.count < 100_000 { w.byte(0x4E) }
        // Pack cells least significant bit first.
        return stride(from: 0, to: w.cells.count - 7, by: 8).map { i in (0..<8).reduce(UInt8(0)) { $0 | w.cells[i + $1] << $1 } }
    }

    static func hfe(tracks: Int, _ make: (Int, Int) -> [UInt8]) -> [UInt8] {
        var header = [UInt8](repeating: 0xFF, count: 512)
        header.replaceSubrange(0..<8, with: Array("HXCPICFE".utf8))
        header[8] = 0; header[9] = UInt8(tracks); header[10] = 2; header[11] = 0
        header[12] = 250; header[13] = 0; header[14] = 0; header[15] = 0; header[16] = 7; header[17] = 1
        header[18] = 1; header[19] = 0
        var list = [UInt8](repeating: 0xFF, count: 512)
        var body: [UInt8] = []
        var block = 2
        for t in 0..<tracks {
            let s0 = make(t, 0), s1 = make(t, 1)
            let len = max(s0.count, s1.count)
            let blocks = (len + 255) / 256
            for i in 0..<4 { list[t * 4 + i] = 0 }
            list[t * 4] = UInt8(block & 0xFF); list[t * 4 + 1] = UInt8(block >> 8)
            list[t * 4 + 2] = UInt8((blocks * 512) & 0xFF); list[t * 4 + 3] = UInt8((blocks * 512) >> 8)
            for b in 0..<blocks {
                for side in [s0, s1] {
                    var chunk = Array(side.dropFirst(b * 256).prefix(256))
                    chunk += [UInt8](repeating: 0x55, count: 256 - chunk.count)
                    body += chunk
                }
            }
            block += blocks
        }
        return header + list + body
    }

    func testHFEDecodesSectorsAndFaults() throws {
        let file = Self.hfe(tracks: 2) { t, side in
            t == 1 && side == 1 ? Self.track(t, side: side, skip: 2, badData: 4) : Self.track(t, side: side)
        }
        XCTAssertEqual(MediaDetector.detect(file).format, "HFE")
        let img = try HFEImage.load(file, sourcePath: nil, writeProtected: true)
        XCTAssertEqual(img.layout(side: 0, track: 0).map(\.id), [0, 1, 2, 3, 4])
        XCTAssertEqual(img.readSector(side: 1, track: 0, sectorID: 3), (0..<1024).map { UInt8(truncatingIfNeeded: $0 + 21 + 3) })
        let faulty = img.layout(side: 1, track: 1)
        XCTAssertEqual(faulty.map(\.id), [0, 1, 3, 4])
        XCTAssertEqual(faulty.map(\.dataCRCError), [false, false, false, true])
        XCTAssertFalse(faulty.contains { $0.idCRCError })
        XCTAssertTrue(faulty.map(\.position) == faulty.map(\.position).sorted())
        XCTAssertTrue(img.layout(side: 0, track: 2).isEmpty)
        XCTAssertFalse(img.canSaveAsRawImage)
    }

    func testTruncatedADFSImageIsAccepted() throws {
        var adf = [UInt8](repeating: 0, count: 819_200 - 5120)
        adf.replaceSubrange(0x401...0x404, with: Array("Hugo".utf8))
        let det = MediaDetector.detect(adf)
        XCTAssertEqual(det.format, "ADF")
        XCTAssertTrue(det.notes.contains("5120 bytes short"), det.notes)
        let img = FloppyImage(data: adf, geometry: det.geometry!)
        // The missing track was unformatted (protection on Play It Again Sam 1
        // verifies that it is), until a format writes it.
        XCTAssertTrue(img.layout(side: 1, track: 79).isEmpty)
        XCTAssertNil(img.readSector(side: 1, track: 79, sectorID: 4))
        XCTAssertEqual(img.layout(side: 0, track: 79).count, 5)
        XCTAssertTrue(img.formatSector(side: 1, track: 79, sectorID: 4, data: [UInt8](repeating: 0xE5, count: 1024)))
        XCTAssertEqual(img.readSector(side: 1, track: 79, sectorID: 4), [UInt8](repeating: 0xE5, count: 1024))
        // Without an ADFS directory, an odd size stays unknown.
        XCTAssertEqual(MediaDetector.detect([UInt8](repeating: 0, count: 819_200 - 5120)).format, "unknown")
    }

    /// The user's UIM HFE: every sector decodes with good CRCs, and it is
    /// the same disc as the ADF (the two dumps differ in some file data).
    func testUIMHFEDecodes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../discimages").standardized
        guard let hfe = FileManager.default.contents(atPath: root.appendingPathComponent("UIM (1989)(4th Dimension).hfe").path) else {
            throw XCTSkip("UIM HFE not present")
        }
        let info = try HFEImage.info([UInt8](hfe))
        XCTAssertEqual(info.sectors, 800)
        XCTAssertEqual(info.crcErrors, 0)
        let report = ADFSInspector.inspect(bytes: [UInt8](hfe))
        XCTAssertEqual(report.root.map(\.name), ["!Boot", "!Readme", "!UIM"])
    }
}
