import Foundation

/// Loader for HxC Floppy Emulator ("HXCPICFE", HFE version 1) images: the
/// raw cell stream of each track, as a drive head would see it. The tracks
/// are decoded here into ID fields and sectors, so protection (odd sector
/// IDs, missing sectors, CRC errors) survives as it does for JFD.
///
/// Layout (little-endian):
///   +0  "HXCPICFE"       +8  format revision (0)
///   +9  tracks           +10 sides
///   +11 track encoding (0 = ISO/IBM MFM, 2 = ISO/IBM FM, ...)
///   +12 bit rate (kbit/s)  +14 RPM  +16 interface mode
///   +18 track list offset, in 512-byte blocks
///   +20 write allowed (0xFF = yes)
///
/// The track list has one 4-byte entry per track: the offset of its data
/// in 512-byte blocks and its length in bytes. A track's data runs in
/// 512-byte blocks, the first 256 bytes for side 0 and the next 256 for
/// side 1. Cells are stored least significant bit first; at 250 kbit/s a
/// revolution is about 100,000 cells (two per data bit).
public enum HFEImage {
    static let magic: [UInt8] = Array("HXCPICFE".utf8)

    public struct Info: Sendable {
        public var tracks: Int
        public var sides: Int
        public var bitRate: Int
        public var encoding: String
        public var formattedTracks: Int
        public var sectors: Int
        public var crcErrors: Int
    }

    public static func load(_ file: [UInt8], sourcePath: String?, writeProtected: Bool) throws -> FloppyImage {
        let (layouts, store, info) = try parse(file)
        let g = DiscGeometry(sides: 2, tracks: layouts.count / 2, sectorsPerTrack: 5, sectorSize: 1024,
                             firstSectorID: 0, formatName: "HFE (\(info.encoding))")
        return FloppyImage(store: store, layouts: layouts, geometry: g, sha256: SHA256.hex(file),
                           sourcePath: sourcePath, writeProtected: writeProtected)
    }

    public static func info(_ file: [UInt8]) throws -> Info { try parse(file).2 }

    static func parse(_ file: [UInt8]) throws -> ([[SectorHeader]], [UInt8], Info) {
        guard file.count >= 512, Array(file[0..<8]) == magic else {
            if file.count >= 8, file.starts(with: Array("HXCHFEV3".utf8)) {
                throw MediaError.unsupportedFormat("HFE version 3 images are not supported (save it as version 1 from the HxC software)")
            }
            throw MediaError.unsupportedFormat("not an HFE image")
        }
        func u16(_ o: Int) -> Int { Int(file[o]) | Int(file[o + 1]) << 8 }
        let tracks = Int(file[9]), sides = Int(file[10]), encoding = file[11]
        let bitRate = u16(12), listOffset = u16(18) * 512
        guard tracks > 0, tracks <= 90, sides == 1 || sides == 2 else {
            throw MediaError.unsupportedFormat("HFE: \(tracks) tracks, \(sides) sides")
        }
        guard encoding == 0 else {
            // FM and the Amiga/Apple encodings carry no ADFS D/E discs.
            throw MediaError.unsupportedFormat("HFE: track encoding \(encoding) (only ISO/IBM MFM is supported)")
        }
        guard listOffset + tracks * 4 <= file.count else { throw MediaError.unsupportedFormat("HFE: truncated track list") }

        var store: [UInt8] = []
        var layouts: [[SectorHeader]] = []
        var sectorCount = 0, crcErrors = 0
        for t in 0..<tracks {
            let entry = listOffset + t * 4
            let offset = u16(entry) * 512, length = u16(entry + 2)
            guard offset + length <= file.count else { throw MediaError.unsupportedFormat("HFE: track \(t) data out of range") }
            for side in 0..<2 {
                guard side < sides else { layouts.append([]); continue }
                // Gather this side's bytes: 256 of every 512.
                var bytes: [UInt8] = []
                bytes.reserveCapacity(length / 2)
                var block = 0
                while block * 512 < length {
                    let start = offset + block * 512 + side * 256
                    let n = min(256, max(0, (length - block * 512) / 2))
                    if n > 0 { bytes += file[start..<(start + n)] }
                    block += 1
                }
                let sectors = decodeMFMTrack(cells(bytes), store: &store)
                sectorCount += sectors.count
                crcErrors += sectors.filter { $0.idCRCError || $0.dataCRCError }.count
                layouts.append(sectors)
            }
        }
        let info = Info(tracks: tracks, sides: sides, bitRate: bitRate, encoding: "MFM, \(bitRate) kbit/s",
                        formattedTracks: layouts.filter { !$0.isEmpty }.count, sectors: sectorCount, crcErrors: crcErrors)
        return (layouts, store, info)
    }

    /// The cell stream, least significant bit of each byte first.
    static func cells(_ bytes: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: bytes.count * 8)
        for (i, b) in bytes.enumerated() {
            for k in 0..<8 { out[i * 8 + k] = (b >> k) & 1 }
        }
        return out
    }

    /// Finds the address marks on one revolution of MFM cells and returns
    /// the sectors in rotational order; their data is appended to `store`.
    static func decodeMFMTrack(_ cells: [UInt8], store: inout [UInt8]) -> [SectorHeader] {
        let n = cells.count
        guard n > 64 else { return [] }
        // Fields can run past the index; read them around the end.
        func cell(_ i: Int) -> UInt8 { cells[i % n] }
        func byte(at i: Int) -> UInt8 {
            var v: UInt8 = 0
            for k in 0..<8 { v = v << 1 | cell(i + k * 2 + 1) }
            return v
        }
        // Three A1 bytes with a missing clock (cells 0x4489) precede every mark.
        struct Mark { var start: Int, after: Int, mark: UInt8 }
        var marks: [Mark] = []
        var window: UInt64 = 0
        for i in 0..<(n + 48) {
            window = (window << 1 | UInt64(cell(i))) & 0xFFFF_FFFF_FFFF
            if window == 0x4489_4489_4489 {
                let start = i - 47
                if start >= n { break }
                marks.append(Mark(start: start, after: i + 1, mark: byte(at: i + 1)))
            }
        }
        var sectors: [SectorHeader] = []
        for (k, m) in marks.enumerated() where m.mark == 0xFE {
            let p = m.after + 16
            let c = byte(at: p), h = byte(at: p + 16), r = byte(at: p + 32), sz = byte(at: p + 48)
            let crc = UInt16(byte(at: p + 64)) << 8 | UInt16(byte(at: p + 80))
            var hdr = SectorHeader(cylinder: c, head: h, id: r, sizeCode: sz & 3, position: Double(m.start) / Double(n),
                                   idCRCError: CRC16.ccitt([0xA1, 0xA1, 0xA1, 0xFE, c, h, r, sz]) != crc, dataOffset: 0)
            // The data mark follows within the gap (about 43 bytes in MFM);
            // a later ID mark first means the sector has no data field.
            let size = hdr.size
            let next = marks.indices.contains(k + 1) ? marks[k + 1]
                : marks.first.map { Mark(start: $0.start + n, after: $0.after + n, mark: $0.mark) } ?? Mark(start: .max, after: .max, mark: 0)
            if next.mark == 0xFB || next.mark == 0xF8, next.start - m.after < 60 * 16 {
                let d = next.after + 16
                let data = (0..<size).map { byte(at: d + $0 * 16) }
                let stored = UInt16(byte(at: d + size * 16)) << 8 | UInt16(byte(at: d + size * 16 + 16))
                hdr.dataCRCError = CRC16.ccitt([0xA1, 0xA1, 0xA1, next.mark] + data) != stored
                hdr.dataOffset = store.count
                store += data
            } else {
                hdr.dataCRCError = true
                hdr.dataOffset = store.count
                store += [UInt8](repeating: 0, count: size)
            }
            sectors.append(hdr)
        }
        return sectors
    }
}
