import Foundation

/// Read-only ADFS catalogue reader for `disk_inspect`. It is an inspection
/// convenience only; the emulated machine always reads discs through the
/// WD1772 model.
public enum ADFSInspector {
    public struct Entry: Codable, Sendable {
        public var name: String
        public var load: UInt32
        public var exec: UInt32
        public var length: UInt32
        public var discAddress: UInt32
        public var isDirectory: Bool
        public var fileType: String?
        public var children: [Entry]?
    }

    public struct Report: Codable, Sendable {
        public var format: String
        public var notes: String
        public var geometry: DiscGeometry?
        public var sha256: String
        public var size: Int
        public var directoryFormat: String?
        public var discTitle: String?
        public var root: [Entry]
        public var warnings: [String]
    }

    public static func inspect(path: String) throws -> Report {
        guard let d = FileManager.default.contents(atPath: path) else { throw MediaError.unreadable(path) }
        return inspect(bytes: [UInt8](d))
    }

    public static func inspect(bytes d: [UInt8]) -> Report {
        let det = MediaDetector.detect(d)
        if det.format == "JFD" {
            // Flatten the standard sectors to an ADF-ordered image and read that.
            do {
                let img = try JFDImage.load(d, sourcePath: nil, writeProtected: true)
                let info = try JFDImage.info(d)
                // ADFS D/E occupies the first 80 tracks; extra tracks hold protection.
                var r = inspect(bytes: Array(img.mergedImage().prefix(819_200)))
                r.format = "JFD"
                r.notes = det.notes + "; title \"\(info.title)\", \(info.formattedTracks) of \(info.tracks * 2) track sides formatted, \(info.sectors) sectors"
                r.geometry = img.geometry
                r.sha256 = SHA256.hex(d)
                r.size = d.count
                r.warnings += nonStandardTracks(img).map { "non-standard: " + $0 }
                if info.hasDeltaData { r.warnings.append("image carries delta (written-data) tables, which are ignored") }
                return r
            } catch {
                return Report(format: "JFD", notes: "\(error)", geometry: nil, sha256: SHA256.hex(d), size: d.count,
                              directoryFormat: nil, discTitle: nil, root: [], warnings: [])
            }
        }
        if det.format == "HFE" {
            do {
                let img = try HFEImage.load(d, sourcePath: nil, writeProtected: true)
                let info = try HFEImage.info(d)
                var r = inspect(bytes: Array(img.mergedImage().prefix(819_200)))
                r.format = "HFE"
                r.notes = det.notes + "; \(info.encoding), \(info.formattedTracks) of \(info.tracks * 2) track sides formatted, \(info.sectors) sectors" + (info.crcErrors > 0 ? ", \(info.crcErrors) with CRC errors" : "")
                r.geometry = img.geometry
                r.sha256 = SHA256.hex(d)
                r.size = d.count
                r.warnings += nonStandardTracks(img).map { "non-standard: " + $0 }
                return r
            } catch {
                return Report(format: "HFE", notes: "\(error)", geometry: nil, sha256: SHA256.hex(d), size: d.count,
                              directoryFormat: nil, discTitle: nil, root: [], warnings: [])
            }
        }
        var report = Report(format: det.format, notes: det.notes, geometry: det.geometry, sha256: SHA256.hex(d),
                            size: d.count, directoryFormat: nil, discTitle: nil, root: [], warnings: [])
        guard det.geometry != nil else { return report }
        if d.count > 0x405, Array(d[0x401...0x404]) == Array("Hugo".utf8) {
            report.directoryFormat = d.count >= 819_200 ? "old map, big 'Hugo' directories (ADFS D)" : "old map, 'Hugo' directories"
            let dirSize = d.count >= 819_200 ? 2048 : 1280
            var depth = 0
            report.root = readOldDirectory(d, at: 0x400, size: dirSize, depth: &depth, warnings: &report.warnings)
            if dirSize == 2048, d.count > 0x400 + 2048 {
                report.discTitle = string(d, 0x400 + 2048 - 41 + 19, 19)
            }
        } else if d.count > 0x805, Array(d[0x801...0x804]) == Array("Nick".utf8) || Array(d[0x401...0x404]) == Array("Nick".utf8) {
            report.directoryFormat = "new map, 'Nick' directories (ADFS E)"
            let at = Array(d[0x401...0x404]) == Array("Nick".utf8) ? 0x400 : 0x800
            report.root = readNewDirectoryNamesOnly(d, at: at)
            report.warnings.append("E-format fragment addresses are not resolved; listing root names only")
        } else {
            report.warnings.append("no recognisable ADFS root directory")
        }
        return report
    }

    /// Track sides whose layout differs from 5 x 1 KB sectors 0-4 (protection).
    static func nonStandardTracks(_ img: FloppyImage) -> [String] {
        var out: [String] = []
        for t in 0..<img.geometry.tracks {
            for side in 0..<2 {
                let l = img.layout(side: side, track: t)
                let standard = l.count == 5 && l.enumerated().allSatisfy { $0.element.id == $0.offset && $0.element.size == 1024 && !$0.element.idCRCError && !$0.element.dataCRCError }
                if standard { continue }
                let desc = l.isEmpty ? "unformatted" : l.map { h in
                    "\(h.id)/\(h.size)" + (h.idCRCError ? " idCRC" : "") + (h.dataCRCError ? " dataCRC" : "") + (h.doubleDensity ? "" : " SD")
                }.joined(separator: ", ")
                out.append("track \(t) side \(side): \(desc)")
            }
        }
        return out
    }

    static func string(_ d: [UInt8], _ o: Int, _ n: Int) -> String {
        var s = ""
        for i in 0..<n where o + i < d.count {
            let c = d[o + i] & 0x7F
            if c < 0x20 { break }
            s.append(Character(UnicodeScalar(c)))
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func le32(_ d: [UInt8], _ o: Int) -> UInt32 {
        UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
    }

    static func readOldDirectory(_ d: [UInt8], at base: Int, size: Int, depth: inout Int, warnings: inout [String]) -> [Entry] {
        guard base + size <= d.count else { warnings.append("directory at \(base) beyond image"); return [] }
        var out: [Entry] = []
        var p = base + 5
        let maxEntries = (size - 5 - 41) / 26
        for _ in 0..<maxEntries {
            if d[p] == 0 { break }
            let name = string(d, p, 10)
            // Big (2048-byte) directories keep attributes in byte 25; the
            // older 1280-byte ones in the top bit of the name's 4th character.
            let attrHigh = size == 2048 ? d[p + 25] & 0x08 != 0 : d[p + 3] & 0x80 != 0
            let load = le32(d, p + 10), exec = le32(d, p + 14), length = le32(d, p + 18)
            let addr = UInt32(d[p + 22]) | UInt32(d[p + 23]) << 8 | UInt32(d[p + 24]) << 16
            var e = Entry(name: name, load: load, exec: exec, length: length, discAddress: addr * 256,
                          isDirectory: attrHigh, fileType: nil, children: nil)
            if load & 0xFFF0_0000 == 0xFFF0_0000 { e.fileType = String(format: "%03X", (load >> 8) & 0xFFF) }
            if attrHigh && depth < 6 {
                depth += 1
                e.children = readOldDirectory(d, at: Int(addr) * 256, size: size, depth: &depth, warnings: &warnings)
                depth -= 1
            }
            out.append(e)
            p += 26
        }
        return out
    }

    static func readNewDirectoryNamesOnly(_ d: [UInt8], at base: Int) -> [Entry] {
        var out: [Entry] = []
        var p = base + 5
        for _ in 0..<77 {
            guard p + 26 <= d.count, d[p] != 0 else { break }
            let name = string(d, p, 10)
            let load = le32(d, p + 10)
            var e = Entry(name: name, load: load, exec: le32(d, p + 14), length: le32(d, p + 18),
                          discAddress: UInt32(d[p + 22]) | UInt32(d[p + 23]) << 8 | UInt32(d[p + 24]) << 16,
                          isDirectory: d[p + 25] & 0x08 != 0, fileType: nil, children: nil)
            if load & 0xFFF0_0000 == 0xFFF0_0000 { e.fileType = String(format: "%03X", (load >> 8) & 0xFFF) }
            out.append(e)
            p += 26
        }
        return out
    }
}
