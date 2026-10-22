import Foundation

/// Physical sector layout of a disc as seen by the floppy controller.
public struct DiscGeometry: Equatable, Sendable, Codable {
    public var sides: Int
    public var tracks: Int
    public var sectorsPerTrack: Int
    public var sectorSize: Int
    public var firstSectorID: Int
    public var formatName: String

    public var sizeCode: UInt8 {
        switch sectorSize { case 128: return 0; case 256: return 1; case 512: return 2; default: return 3 }
    }
    public var totalBytes: Int { sides * tracks * sectorsPerTrack * sectorSize }
}

public enum MediaError: Error, CustomStringConvertible {
    case unreadable(String)
    case unsupportedFormat(String)
    public var description: String {
        switch self {
        case .unreadable(let s): return "Cannot read disc image: \(s)"
        case .unsupportedFormat(let s): return "Unsupported disc image format: \(s)"
        }
    }
}

/// One sector as it appears on a physical track: the ID field the
/// controller reads, where it sits in the revolution, and any recorded
/// CRC faults (copy-protected images rely on these).
public struct SectorHeader: Equatable, Sendable {
    public var cylinder: UInt8
    public var head: UInt8
    public var id: UInt8
    public var sizeCode: UInt8
    /// Start of the ID field as a fraction of a revolution after the index pulse.
    public var position: Double
    public var doubleDensity = true
    public var idCRCError = false
    public var dataCRCError = false
    /// Byte offset of the sector data in the image's backing store.
    var dataOffset: Int

    public var size: Int { 128 << Int(sizeCode & 3) }
}

/// A floppy disc image with a copy-on-write overlay. The base image bytes
/// are never modified; writes land in `overlay` keyed by the sector's byte
/// offset in the backing store.
///
/// Raw sector images (ADF, ADL, ...) derive each track's layout from their
/// geometry. Track-level images (JFD) carry an explicit per-track sector
/// list, so missing sectors, unformatted tracks and CRC errors survive.
public final class FloppyImage {
    public let geometry: DiscGeometry
    public private(set) var sourcePath: String?
    /// SHA-256 of the image file as loaded (or last saved).
    public private(set) var sha256: String
    private(set) var base: [UInt8]
    /// Explicit layouts indexed by `track * 2 + side`; nil for raw images.
    let trackLayouts: [[SectorHeader]]?
    public private(set) var overlay: [Int: [UInt8]] = [:]
    /// Sectors added by writes to IDs a track-level image lacks, by track index.
    var addedSectors: [Int: [SectorHeader]] = [:]
    public var writeProtected: Bool

    public var isModified: Bool { !overlay.isEmpty || !addedSectors.isEmpty }

    public init(data: [UInt8], geometry: DiscGeometry, sourcePath: String? = nil, writeProtected: Bool = false) {
        self.base = data
        self.geometry = geometry
        self.sourcePath = sourcePath
        self.writeProtected = writeProtected
        self.sha256 = SHA256.hex(data)
        self.trackLayouts = nil
    }

    /// Track-level image: `store` holds sector data at each header's `dataOffset`.
    init(store: [UInt8], layouts: [[SectorHeader]], geometry: DiscGeometry, sha256: String, sourcePath: String?, writeProtected: Bool) {
        self.base = store
        self.trackLayouts = layouts
        self.geometry = geometry
        self.sha256 = sha256
        self.sourcePath = sourcePath
        self.writeProtected = writeProtected
    }

    /// Open an image file, detecting its format from size and content.
    public static func open(path: String, writeProtected: Bool = false) throws -> FloppyImage {
        guard let d = FileManager.default.contents(atPath: path) else { throw MediaError.unreadable(path) }
        // Absolute, so snapshots can reopen it from any working directory.
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        let bytes = [UInt8](d)
        let det = MediaDetector.detect(bytes)
        if det.format == "JFD" { return try JFDImage.load(bytes, sourcePath: path, writeProtected: writeProtected) }
        if det.format == "HFE" { return try HFEImage.load(bytes, sourcePath: path, writeProtected: writeProtected) }
        guard let g = det.geometry else { throw MediaError.unsupportedFormat("\(det.format): \(det.notes)") }
        return FloppyImage(data: bytes, geometry: g, sourcePath: path, writeProtected: writeProtected)
    }

    /// Byte offset of a sector in a side-interleaved raw image, or nil.
    func offset(side: Int, track: Int, sectorID: Int) -> Int? {
        let g = geometry
        let s = sectorID - g.firstSectorID
        guard side >= 0, side < g.sides, track >= 0, track < g.tracks, s >= 0, s < g.sectorsPerTrack else { return nil }
        return ((track * g.sides + side) * g.sectorsPerTrack + s) * g.sectorSize
    }

    /// Sectors on a physical track in rotational order (empty if unformatted).
    public func layout(side: Int, track: Int) -> [SectorHeader] {
        if let t = trackLayouts {
            let i = track * 2 + side
            guard side >= 0 && side < 2 && track >= 0 && i < t.count else { return [] }
            guard let extra = addedSectors[i] else { return t[i] }
            return (t[i] + extra).sorted { $0.position < $1.position }
        }
        let g = geometry
        guard side >= 0, side < g.sides, track >= 0, track < g.tracks else { return [] }
        return (0..<g.sectorsPerTrack).map { s in
            SectorHeader(cylinder: UInt8(track), head: UInt8(side), id: UInt8(s + g.firstSectorID), sizeCode: g.sizeCode,
                         position: Double(s) / Double(g.sectorsPerTrack),
                         dataOffset: ((track * g.sides + side) * g.sectorsPerTrack + s) * g.sectorSize)
        }
    }

    func header(side: Int, track: Int, sectorID: Int) -> SectorHeader? {
        layout(side: side, track: track).first { Int($0.id) == sectorID }
    }

    public func readData(_ h: SectorHeader) -> [UInt8] {
        if let ov = overlay[h.dataOffset] { return ov }
        let o = h.dataOffset, end = o + h.size
        if o < 0 { return [UInt8](repeating: 0, count: h.size) }
        if end <= base.count { return Array(base[o..<end]) }
        // Short image: pad with zeroes.
        var out = [UInt8](repeating: 0, count: h.size)
        if o < base.count { for i in o..<base.count { out[i - o] = base[i] } }
        return out
    }

    @discardableResult
    public func writeData(_ h: SectorHeader, _ data: [UInt8]) -> Bool {
        guard !writeProtected else { return false }
        var d = Array(data.prefix(h.size))
        if d.count < h.size { d += [UInt8](repeating: 0, count: h.size - d.count) }
        overlay[h.dataOffset] = d
        return true
    }

    public func readSector(side: Int, track: Int, sectorID: Int) -> [UInt8]? {
        header(side: side, track: track, sectorID: sectorID).map(readData)
    }

    @discardableResult
    public func writeSector(side: Int, track: Int, sectorID: Int, data: [UInt8]) -> Bool {
        guard let h = header(side: side, track: track, sectorID: sectorID) else { return false }
        return writeData(h, data)
    }

    /// Full image contents with overlay applied, in raw (ADF-style) sector
    /// order. Track-level images are flattened: sectors outside the nominal
    /// geometry are dropped and missing ones read as zero.
    public func mergedImage() -> [UInt8] {
        if trackLayouts == nil {
            var out = base
            if out.count < geometry.totalBytes { out += [UInt8](repeating: 0, count: geometry.totalBytes - out.count) }
            for (o, d) in overlay { for i in 0..<d.count where o + i < out.count { out[o + i] = d[i] } }
            return out
        }
        let g = geometry
        var out = [UInt8](repeating: 0, count: g.totalBytes)
        for t in 0..<g.tracks {
            for side in 0..<g.sides {
                for s in 0..<g.sectorsPerTrack {
                    guard let o = offset(side: side, track: t, sectorID: s + g.firstSectorID),
                          let d = readSector(side: side, track: t, sectorID: s + g.firstSectorID) else { continue }
                    for i in 0..<min(d.count, g.sectorSize) { out[o + i] = d[i] }
                }
            }
        }
        return out
    }

    /// Add a standard-position 1 KB sector to a formatted track of a
    /// track-level image (see WD1772 write handling); returns its header.
    func addSector(side: Int, track: Int, id: UInt8) -> SectorHeader? {
        guard trackLayouts != nil, !writeProtected, !layout(side: side, track: track).isEmpty else { return nil }
        let h = SectorHeader(cylinder: UInt8(track), head: UInt8(side), id: id, sizeCode: 3,
                             position: Double(id % 5) / 5, dataOffset: -(track * 2 + side) * 256 - Int(id) - 1)
        addedSectors[track * 2 + side, default: []].append(h)
        return h
    }

    public func discardChanges() { overlay.removeAll(); addedSectors.removeAll() }

    /// Whether the changes can be written back as a raw sector image. Track-
    /// level images (JFD, HFE) cannot: flattening would lose their protection.
    public var canSaveAsRawImage: Bool { trackLayouts == nil }

    /// Writes the image with its changes to `path` (atomically), then makes
    /// that file the image's source: the changes become its base and the
    /// overlay is cleared. Never called implicitly; the app asks first.
    public func saveChanges(to path: String? = nil) throws {
        guard canSaveAsRawImage else {
            throw MediaError.unsupportedFormat("Track-level images (JFD, HFE) are kept read-only; use a save state to keep their changes")
        }
        guard let target = path ?? sourcePath else { throw MediaError.unreadable("no file to save to") }
        let merged = mergedImage()
        try Data(merged).write(to: URL(fileURLWithPath: target), options: .atomic)
        base = merged
        overlay.removeAll()
        sha256 = SHA256.hex(merged)
        sourcePath = URL(fileURLWithPath: target).standardizedFileURL.path
    }

    /// Logical byte read (ADFS disc address order) for inspection tools.
    public func logicalBytes(at address: Int, count: Int) -> [UInt8] {
        let merged = isModified || trackLayouts != nil ? mergedImage() : base
        let end = min(merged.count, address + count)
        return address < end ? Array(merged[address..<end]) : []
    }
}

/// Format detection by size and content (never by extension).
public enum MediaDetector {
    public struct Result: Sendable {
        public var format: String
        public var geometry: DiscGeometry?
        public var notes: String
    }

    public static func detect(_ d: [UInt8]) -> Result {
        if d.count >= 2 && d[0] == 0x1F && d[1] == 0x8B {
            var notes = "gzip-compressed"
            if let inner = Gzip.inflateHeaderPeek(d), inner.starts(with: Array("JFDI".utf8)) {
                notes = "gzip-compressed JASPP JFD (protected/track-level format)"
                return Result(format: "JFD", geometry: nil, notes: notes)
            }
            return Result(format: "gzip", geometry: nil, notes: notes)
        }
        if d.starts(with: Array("JFDI".utf8)) {
            return Result(format: "JFD", geometry: nil, notes: "JASPP JFD track-level format")
        }
        if d.starts(with: HFEImage.magic) || d.starts(with: Array("HXCHFEV3".utf8)) {
            return Result(format: "HFE", geometry: nil, notes: "HxC Floppy Emulator track-level format")
        }
        let hugo = d.count > 0x405 && Array(d[0x401...0x404]) == Array("Hugo".utf8)
        let nick = d.count > 0x805 && Array(d[0x801...0x804]) == Array("Nick".utf8)
        // Some imagers stop before the last track or two of an 800K disc
        // (Krisalis titles turn up 5120 bytes short). Accept a truncated
        // ADFS D/E image; the missing tracks read as zeroes.
        let shortADFS = d.count < 819_200 && d.count >= 819_200 - 4 * 5120 && d.count % 1024 == 0 && (hugo || nick)
        switch d.count {
        case 819_200, _ where shortADFS:
            var notes = "ADFS D/E 800K raw sector image"
            if hugo { notes = "ADFS D (old map, 'Hugo' root directory)" }
            else if nick { notes = "ADFS E (new map, 'Nick' root directory)" }
            if d.count < 819_200 { notes += String(format: "; image is %d bytes short (the last %d sectors read as zeroes)", 819_200 - d.count, (819_200 - d.count) / 1024) }
            return Result(format: "ADF", geometry: DiscGeometry(sides: 2, tracks: 80, sectorsPerTrack: 5, sectorSize: 1024, firstSectorID: 0, formatName: "ADFS D/E"), notes: notes)
        case 655_360:
            return Result(format: "ADL", geometry: DiscGeometry(sides: 2, tracks: 80, sectorsPerTrack: 16, sectorSize: 256, firstSectorID: 0, formatName: "ADFS L"), notes: "ADFS L 640K")
        case 327_680:
            return Result(format: "ADM", geometry: DiscGeometry(sides: 1, tracks: 80, sectorsPerTrack: 16, sectorSize: 256, firstSectorID: 0, formatName: "ADFS M"), notes: "ADFS M 320K")
        case 163_840:
            return Result(format: "ADS", geometry: DiscGeometry(sides: 1, tracks: 40, sectorsPerTrack: 16, sectorSize: 256, firstSectorID: 0, formatName: "ADFS S"), notes: "ADFS S 160K")
        case 1_638_400:
            return Result(format: "ADF-HD", geometry: DiscGeometry(sides: 2, tracks: 80, sectorsPerTrack: 10, sectorSize: 1024, firstSectorID: 0, formatName: "ADFS F"), notes: "ADFS F 1.6MB (high density: not supported by A3000 drive)")
        default:
            return Result(format: "unknown", geometry: nil, notes: "size \(d.count) bytes")
        }
    }
}

// MARK: - Snapshot state

extension SectorHeader {
    func save(_ w: inout StateWriter) {
        w.u8(cylinder); w.u8(head); w.u8(id); w.u8(sizeCode); w.double(position)
        w.bool(doubleDensity); w.bool(idCRCError); w.bool(dataCRCError); w.i64(dataOffset)
    }

    static func load(_ r: inout StateReader) throws -> SectorHeader {
        SectorHeader(cylinder: try r.u8(), head: try r.u8(), id: try r.u8(), sizeCode: try r.u8(), position: try r.double(),
                     doubleDensity: try r.bool(), idCRCError: try r.bool(), dataCRCError: try r.bool(), dataOffset: try r.i64())
    }
}

extension FloppyImage {
    /// The copy-on-write state (the base image itself is referenced by hash).
    func saveChanges(_ w: inout StateWriter) {
        w.bool(writeProtected)
        let keys = overlay.keys.sorted()
        w.u32(UInt32(keys.count))
        for k in keys { w.i64(k); w.data(overlay[k]!) }
        let tracks = addedSectors.keys.sorted()
        w.u32(UInt32(tracks.count))
        for t in tracks {
            w.i64(t); w.u32(UInt32(addedSectors[t]!.count))
            for h in addedSectors[t]! { h.save(&w) }
        }
    }

    func loadChanges(_ r: inout StateReader) throws {
        writeProtected = try r.bool()
        overlay = [:]
        for _ in 0..<Int(try r.u32()) { let k = try r.i64(); overlay[k] = try r.data(max: 16384) }
        addedSectors = [:]
        for _ in 0..<Int(try r.u32()) {
            let t = try r.i64()
            addedSectors[t] = try (0..<Int(try r.u32())).map { _ in try SectorHeader.load(&r) }
        }
    }
}
