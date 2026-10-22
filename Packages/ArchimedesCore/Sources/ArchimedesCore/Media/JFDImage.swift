import Foundation

/// Loader for JFD ("JFDI") track-level floppy images, the format ADFFS uses
/// for copy-protected Archimedes software. Usually gzip-compressed.
///
/// Layout (little-endian words):
///   +0  "JFDI"            +4  minimum reader version   +8  image size
///   +12 sequence number   +16 game ID                  +20 image version
///   +24 track table       +28 sector table base        +32 data base
///   +36..+44 delta (written-data) tables, 0 when absent
///   +48 title (256 bytes, CR or NUL terminated), then flags/fps/obey length
///
/// The track table holds one word per physical track and side
/// (`track * 2 + side`): 0xFFFFFFFF for an unformatted track, otherwise an
/// offset from the sector table base to a list of 8-byte entries
/// (header word, data offset from the data base) ending with 0xFFFFFFFF.
///
/// Sector header word: bits 0-1 size code (128 << n), bit 4 ID CRC error,
/// bit 5 data CRC error, bits 8-15 sector ID, bits 16-19 density
/// (2 = double), bits 24-31 ID position in ms after index (0xFF = unknown).
public enum JFDImage {
    static let magic: [UInt8] = Array("JFDI".utf8)
    static let revolutionMs = 200.0
    /// Raw MFM bytes per revolution at 250 kbit/s and 300 rpm.
    static let trackBytes = 6250.0
    /// Approximate ID field + gaps + data mark overhead per sector, in bytes.
    static let sectorOverhead = 62.0

    public struct Info: Sendable {
        public var title: String
        public var tracks: Int
        public var formattedTracks: Int
        public var sectors: Int
        public var hasDeltaData: Bool
    }

    public static func load(_ file: [UInt8], sourcePath: String?, writeProtected: Bool) throws -> FloppyImage {
        let (layouts, store, info) = try parse(file)
        let g = DiscGeometry(sides: 2, tracks: layouts.count / 2, sectorsPerTrack: 5, sectorSize: 1024,
                             firstSectorID: 0, formatName: "JFD \"\(info.title)\"")
        return FloppyImage(store: store, layouts: layouts, geometry: g, sha256: SHA256.hex(file),
                           sourcePath: sourcePath, writeProtected: writeProtected)
    }

    public static func info(_ file: [UInt8]) throws -> Info { try parse(file).2 }

    static func parse(_ file: [UInt8]) throws -> ([[SectorHeader]], [UInt8], Info) {
        var raw = file
        if file.count >= 2 && file[0] == 0x1F && file[1] == 0x8B {
            guard let d = Gzip.inflate(file) else { throw MediaError.unreadable("JFD: gzip stream is corrupt") }
            raw = d
        }
        guard raw.count >= 48 + 256, Array(raw[0..<4]) == magic else { throw MediaError.unsupportedFormat("not a JFD image") }
        func word(_ o: Int) -> UInt32? {
            guard o >= 0, o + 4 <= raw.count else { return nil }
            return UInt32(raw[o]) | UInt32(raw[o + 1]) << 8 | UInt32(raw[o + 2]) << 16 | UInt32(raw[o + 3]) << 24
        }
        let trackTable = Int(word(24)!), sectorBase = Int(word(28)!), dataBase = word(32)!
        let hasDelta = word(36)! != 0 || word(40)! != 0 || word(44)! != 0
        guard trackTable < sectorBase, sectorBase <= raw.count else { throw MediaError.unsupportedFormat("JFD: bad table offsets") }
        let titleBytes = raw[48..<(48 + 256)].prefix { $0 != 0 && $0 != 13 }
        let title = String(decoding: titleBytes, as: UTF8.self)

        let entries = (sectorBase - trackTable) / 4
        guard entries <= 2 * 90 else { throw MediaError.unsupportedFormat("JFD: \(entries / 2) tracks") }
        var store = raw
        // Sectors recorded without data read back as 0xFF fill.
        var fillOffset: Int?
        var layouts: [[SectorHeader]] = []
        var sectorCount = 0
        for i in 0..<entries {
            guard let t = word(trackTable + i * 4) else { throw MediaError.unsupportedFormat("JFD: truncated track table") }
            if t == 0xFFFF_FFFF { layouts.append([]); continue }
            var list: [SectorHeader] = []
            var p = sectorBase + Int(t)
            var bytePos = 0.0
            while true {
                guard let h = word(p) else { throw MediaError.unsupportedFormat("JFD: truncated sector table") }
                if h == 0xFFFF_FFFF { break }
                guard let off = word(p + 4) else { throw MediaError.unsupportedFormat("JFD: truncated sector table") }
                p += 8
                var hdr = SectorHeader(cylinder: UInt8(i / 2), head: UInt8(i % 2), id: UInt8((h >> 8) & 0xFF),
                                       sizeCode: UInt8(h & 3), position: 0,
                                       doubleDensity: (h >> 16) & 0xF == 2,
                                       idCRCError: h & 0x10 != 0, dataCRCError: h & 0x20 != 0, dataOffset: 0)
                let ms = h >> 24
                hdr.position = ms == 0xFF ? bytePos / trackBytes : Double(ms) / revolutionMs
                bytePos = hdr.position * trackBytes + Double(hdr.size) + sectorOverhead
                if dataBase == 0xFFFF_FFFF || off == 0xFFFF_FFFF {
                    if fillOffset == nil { fillOffset = store.count; store += [UInt8](repeating: 0xFF, count: 1024) }
                    hdr.dataOffset = fillOffset!
                } else {
                    hdr.dataOffset = Int(dataBase) + Int(off)
                    guard hdr.dataOffset + hdr.size <= raw.count else { throw MediaError.unsupportedFormat("JFD: sector data out of range") }
                }
                list.append(hdr)
            }
            list.sort { $0.position < $1.position }
            sectorCount += list.count
            layouts.append(list)
        }
        if entries % 2 == 1 { layouts.append([]) }
        let info = Info(title: title, tracks: layouts.count / 2, formattedTracks: layouts.filter { !$0.isEmpty }.count,
                        sectors: sectorCount, hasDeltaData: hasDelta)
        return (layouts, store, info)
    }
}
