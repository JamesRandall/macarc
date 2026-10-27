import Foundation

/// RISC OS filetypes, by the names the Filer shows.
public enum RISCOSFileType {
    public static let names: [UInt16: String] = [
        0x004: "AIM", 0x132: "ICO", 0x188: "ARMovie", 0x1AD: "AutoCAD", 0x3FB: "Pinboard",
        0x695: "GIF", 0x69C: "BMP", 0x6A2: "RISC OS Font", 0xA91: "Zip", 0xADF: "PDF",
        0xAE7: "ARMovie", 0xAFF: "DrawFile", 0xB60: "PNG", 0xBBC: "BBC ROM", 0xBC5: "Squash",
        0xC32: "RTF", 0xC85: "JPEG", 0xCB6: "Tracker", 0xD3C: "SoundSamp", 0xD94: "Archive",
        0xDDC: "Archive", 0xDEA: "DXF", 0xDFE: "CSV", 0xF79: "Basic stamp", 0xF81: "JSScript",
        0xF89: "GZip", 0xFAF: "HTML", 0xFB1: "WAVE", 0xFC3: "Patch", 0xFC8: "DOSDisc",
        0xFCA: "Squash", 0xFD1: "BASICTxt", 0xFDC: "SoftLink", 0xFE4: "DOS", 0xFE5: "EPROM",
        0xFE6: "UNIX Ex", 0xFEA: "Desktop", 0xFEB: "Obey", 0xFEC: "Template", 0xFED: "Palette",
        0xFF0: "TIFF", 0xFF1: "Config", 0xFF2: "Config", 0xFF4: "Printout", 0xFF5: "PoScript",
        0xFF6: "Font", 0xFF7: "BBC font", 0xFF8: "Absolute", 0xFF9: "Sprite", 0xFFA: "Module",
        0xFFB: "BASIC", 0xFFC: "Utility", 0xFFD: "Data", 0xFFE: "Command", 0xFFF: "Text",
    ]

    /// The Filer's name for a type, or its number ("&123") when it has none.
    public static func name(_ type: UInt16) -> String { names[type] ?? String(format: "&%03X", type) }

    /// A type from its name ("Text") or number ("fff", "&FFF").
    public static func type(named s: String) -> UInt16? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let (k, _) = names.first(where: { $0.value.caseInsensitiveCompare(t) == .orderedSame }) {
            // Prefer the usual one where two numbers share a name.
            return ["Archive": 0xDDC, "ARMovie": 0xAE7, "Squash": 0xFCA, "Config": 0xFF2][names[k]!] ?? k
        }
        let hex = t.hasPrefix("&") ? String(t.dropFirst()) : t.lowercased().hasPrefix("0x") ? String(t.dropFirst(2)) : t
        guard (1...3).contains(hex.count), let v = UInt16(hex, radix: 16) else { return nil }
        return v
    }

    /// Mac file extensions that stand for a RISC OS type.
    public static let byExtension: [String: UInt16] = [
        "txt": 0xFFF, "text": 0xFFF, "bas": 0xFFB, "htm": 0xFAF, "html": 0xFAF, "csv": 0xDFE,
        "png": 0xB60, "jpg": 0xC85, "jpeg": 0xC85, "gif": 0x695, "bmp": 0x69C, "tif": 0xFF0, "tiff": 0xFF0,
        "pdf": 0xADF, "zip": 0xA91, "ps": 0xFF5, "rtf": 0xC32, "wav": 0xFB1, "mod": 0xCB6, "gz": 0xF89,
    ]
}

/// A file or folder from the Mac, ready to go on an ADFS disc.
///
/// Its RISC OS name and type come, in turn, from a ".inf" file beside it
/// (a BBC name and addresses, as MacBeeb and other emulators write), a
/// ",xxx" type suffix or ",llllllll-eeeeeeee" load and execution addresses
/// (the convention RISC OS emulators and file servers use), a known
/// extension (dropped), or the usual names (!Run is Obey, !Sprites a
/// sprite file); otherwise it's Data. A ".bas" file of text is tokenised
/// as a BASIC program. Names lose characters RISC OS can't hold ("."
/// becomes "/", spaces hard spaces, others "_") and are cut to ten.
public struct ADFSHostFile: Sendable {
    public var name: String
    public var load: UInt32
    public var exec: UInt32
    public var attributes: UInt8
    /// nil for a folder.
    public var data: [UInt8]?
    public var children: [ADFSHostFile]

    public var isFolder: Bool { data == nil }
    /// Files in all, counting those in folders.
    public var fileCount: Int { isFolder ? children.reduce(0) { $0 + $1.fileCount } : 1 }

    /// nil for things that don't go on the disc: hidden files and .inf files.
    public static func read(_ url: URL) throws -> ADFSHostFile? {
        let macName = url.lastPathComponent
        guard !macName.hasPrefix("."), url.pathExtension.lowercased() != "inf" else { return nil }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
        let date = values.contentModificationDate ?? Date()
        if values.isDirectory == true {
            let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let (load, exec) = ADFSVolume.stamp(type: 0xFFD, date: date)
            return ADFSHostFile(name: riscOSName(macName), load: load, exec: exec, attributes: 0x08, data: nil,
                                children: try urls.compactMap { try read($0) })
        }
        var data = [UInt8](try Data(contentsOf: url))
        if let inf = inf(beside: url) {
            return ADFSHostFile(name: riscOSName(inf.name), load: inf.load, exec: inf.exec, attributes: inf.locked ? 0x07 : 0x03,
                                data: data, children: [])
        }
        let (stem, type, addresses) = parse(macName)
        var t = type
        var name = stem
        if t == nil, addresses == nil {
            let ext = (stem as NSString).pathExtension.lowercased()
            if let known = RISCOSFileType.byExtension[ext] {
                t = known
                name = (stem as NSString).deletingPathExtension
                // BASIC as text is tokenised; a tokenised program stays as it is.
                if ext == "bas", !BBCBasic.isProgram(data), let text = String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1),
                   let program = try? BBCBasic.tokenise(text) {
                    data = program
                }
            } else {
                switch stem.lowercased() {
                case "!run", "!boot": t = 0xFEB
                case "!sprites", "!sprites22", "!sprites23": t = 0xFF9
                case "!help": t = 0xFFF
                case "!runimage": t = BBCBasic.isProgram(data) ? 0xFFB : 0xFF8
                default: t = 0xFFD
                }
            }
        }
        let (load, exec) = addresses ?? ADFSVolume.stamp(type: t ?? 0xFFD, date: date)
        return ADFSHostFile(name: riscOSName(name), load: load, exec: exec, attributes: 0x03, data: data, children: [])
    }

    /// A name's ",xxx" type or ",llllllll-eeeeeeee" addresses, and the name without them.
    public static func parse(_ macName: String) -> (name: String, type: UInt16?, addresses: (UInt32, UInt32)?) {
        guard let comma = macName.lastIndex(of: ",") else { return (macName, nil, nil) }
        let suffix = String(macName[macName.index(after: comma)...]), stem = String(macName[..<comma])
        if suffix.count == 3, let t = UInt16(suffix, radix: 16) { return (stem, t, nil) }
        let parts = suffix.split(separator: "-")
        if parts.count == 2, parts.allSatisfy({ $0.count == 8 }), let l = UInt32(parts[0], radix: 16), let e = UInt32(parts[1], radix: 16) {
            return (stem, nil, (l, e))
        }
        return (macName, nil, nil)
    }

    struct Inf { var name: String; var load: UInt32; var exec: UInt32; var locked: Bool }

    /// "NAME.inf" or, for "NAME.ext", "NAME.inf": a name (the last part of
    /// a path such as "$.Games.Elite"), then hex load and exec addresses,
    /// then perhaps a length and "L" or "Locked".
    static func inf(beside url: URL) -> Inf? {
        let dir = url.deletingLastPathComponent()
        let candidates = [url.lastPathComponent + ".inf", url.deletingPathExtension().lastPathComponent + ".inf"]
        for c in candidates {
            guard let text = try? String(contentsOf: dir.appendingPathComponent(c), encoding: .isoLatin1) else { continue }
            let words = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).map(String.init)
            guard words.count >= 3 else { continue }
            func hex(_ s: String) -> UInt32? {
                guard s.count <= 8, var v = UInt32(s, radix: 16) else { return nil }
                if s.count == 6 && s.uppercased().hasPrefix("FF") { v |= 0xFF00_0000 }
                return v
            }
            guard let load = hex(words[1]), let exec = hex(words[2]) else { continue }
            let name = words[0].split(separator: ".").last.map(String.init) ?? words[0]
            let locked = words.dropFirst(3).contains { $0.uppercased() == "L" || $0.uppercased() == "LOCKED" }
            return Inf(name: name, load: load, exec: exec, locked: locked)
        }
        return nil
    }

    /// A Mac name as a RISC OS one (see the type's notes).
    public static func riscOSName(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case ".": out.append("/")
            case " ": out.append("\u{A0}")
            default:
                let ok = ch.unicodeScalars.count == 1 && ch.unicodeScalars.first!.value > 0x20 && ch.unicodeScalars.first!.value <= 0xFF
                    && ch.unicodeScalars.first!.value != 0x7F && !"$&@^%\\:#*\"|".contains(ch)
                out.append(ok ? ch : "_")
            }
        }
        return String(out.prefix(10))
    }

    /// Puts it on the disc in the directory at `path`: a file replacing an
    /// unlocked one of the same name, a folder merging into a directory.
    public func add(to volume: ADFSVolume, at path: [String]) throws {
        let name = volume.storableName(name)
        if let data {
            try volume.save(data, name: name, at: path, load: load, exec: exec, attributes: attributes)
        } else {
            try volume.makeDirectory(name, at: path, date: ADFSVolume.date(load: load, exec: exec))
            for c in children { try c.add(to: volume, at: path + [name]) }
        }
    }
}

/// Copying files off an ADFS disc to the Mac.
public enum ADFSExport {
    /// A name for the Mac: "/" back to ".", hard spaces to spaces, and a
    /// ",xxx" type suffix (or ",llllllll-eeeeeeee" addresses for an untyped
    /// file), so it comes back as it went.
    public static func macName(_ e: ADFSVolume.Entry) -> String {
        let base = String(e.name.map { $0 == "/" ? "." : $0 == "\u{A0}" ? " " : $0 == ":" ? "-" : $0 })
        if e.isDirectory { return base }
        if let t = e.fileType { return base + String(format: ",%03x", t) }
        return base + String(format: ",%08x-%08x", e.load, e.exec)
    }

    /// Writes the entry `e` (a file, or a directory and everything in it)
    /// from the directory at `path` to `url`, dated as it is on the disc.
    public static func write(_ e: ADFSVolume.Entry, from volume: ADFSVolume, at path: [String], to url: URL) throws {
        let fm = FileManager.default
        if e.isDirectory {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            for child in try volume.entries(at: path + [e.name]) {
                try write(child, from: volume, at: path + [e.name], to: url.appendingPathComponent(macName(child)))
            }
        } else {
            try Data(volume.contents(of: e.name, at: path)).write(to: url)
        }
        if let date = e.date { try? fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
    }
}

/// Blank floppies, as *Format makes them.
public enum ADFSFloppyFormatter {
    public enum Format: String, CaseIterable, Sendable {
        /// 800K, new map: RISC OS 3's usual format.
        case e
        /// 800K, old map: what RISC OS 2 reads.
        case d
        /// 640K, old map and old directories: Arthur's, and the BBC Master's.
        case l

        public var name: String {
            switch self {
            case .e: return "ADFS E (800K, RISC OS 3)"
            case .d: return "ADFS D (800K, RISC OS 2)"
            case .l: return "ADFS L (640K, Arthur and BBC Master)"
            }
        }
    }

    /// An 819,200-byte image (2 sides, 80 tracks, 5 sectors of 1024 bytes),
    /// or for L format 655,360 (2 sides, 80 tracks, 16 sectors of 256).
    public static func blank(_ format: Format, name: String) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: format == .l ? 655_360 : 819_200)
        let discName = Array(ADFSFormatter.discName(name).prefix(10))
        let padded = discName + [UInt8](repeating: 0x20, count: 10 - discName.count)
        let id = ADFSFormatter.discID(for: name)
        func put(_ v: Int, _ n: Int, at o: Int) { for i in 0..<n { d[o + i] = UInt8((v >> (8 * i)) & 0xFF) } }
        func oldMap(size: Int, free: Int) {
            put(free, 3, at: 0x000)
            put(size - free, 3, at: 0x100)
            put(size, 3, at: 0x0FC)
            for k in 0..<5 { d[0x0F7 + k] = padded[2 * k]; d[0x1F6 + k] = padded[2 * k + 1] }
            put(Int(id), 2, at: 0x1FB)
            d[0x1FE] = 3
            d[0x0FF] = ADFSFormatter.checksum(d, 0x000, 0x100)
            d[0x1FF] = ADFSFormatter.checksum(d, 0x100, 0x100)
        }
        func directory(at o: Int, parent: Int, signature: String) {
            for (i, c) in signature.utf8.enumerated() { d[o + 1 + i] = c; d[o + 2043 + i] = c }
            put(parent, 3, at: o + 2010)
            d[o + 2013] = 0x24; d[o + 2014] = 0x0D // title "$"
            d[o + 2032] = 0x24; d[o + 2033] = 0x0D // name "$"
            d[o + 2047] = ADFSFormatter.directoryCheckByte(Array(d[o..<(o + 2048)]))
        }
        switch format {
        case .d:
            // The map, the root at &400, free space from &C00.
            oldMap(size: 3200, free: 0xC00 >> 8)
            directory(at: 0x400, parent: 0x400 >> 8, signature: "Hugo")
        case .l:
            // The map, the root at &200 (1280 bytes, its own parent, named
            // after the disc, as *Format makes it), free space from &700.
            oldMap(size: 2560, free: 0x700 >> 8)
            let o = 0x200
            for (i, c) in "Hugo".utf8.enumerated() { d[o + 1 + i] = c; d[o + 1275 + i] = c }
            put(0x200 >> 8, 3, at: o + 1238)
            let root = discName.isEmpty ? [0x24] : discName
            for (i, c) in root.enumerated() { d[o + 1228 + i] = c; d[o + 1241 + i] = c }
            if root.count < 10 { d[o + 1228 + root.count] = 0x0D; d[o + 1241 + root.count] = 0x0D }
            d[o + 1279] = ADFSFormatter.directoryCheckByte(Array(d[o..<(o + 1280)]))
        case .e:
            // One zone at &000 and its copy at &400, the root at &800: all
            // fragment 2 (32 map bits of 128 bytes), then free space.
            let r = 4
            d[r] = 10; d[r + 1] = 5; d[r + 2] = 2; d[r + 3] = 2 // sector size, sectors, heads, density
            d[r + 4] = 15; d[r + 5] = 7; d[r + 6] = 1 // idlen, log2bpmb, skew
            d[r + 9] = 1 // zones
            put(0x520, 2, at: r + 10) // zone spare
            put(0x203, 4, at: r + 12) // root
            put(819_200, 4, at: r + 16)
            put(Int(id), 2, at: r + 20)
            for k in 0..<10 { d[r + 22 + k] = padded[k] }
            func setBit(_ b: Int) { d[b >> 3] |= 1 << UInt8(b & 7) }
            // Fragment 2: bits 512-543, the id then a stop bit.
            for i in 0..<15 where 2 >> i & 1 != 0 { setBit(512 + i) }
            setBit(543)
            // Free: bits 544-6911, the link (none) then a stop bit.
            setBit(6911)
            put((544 - 8) | 0x8000, 2, at: 1)
            d[3] = 0xFF // cross check (one zone)
            d[0] = ADFSNewMap.zoneCheck(Array(d[0..<1024]))
            d.replaceSubrange(0x400..<0x800, with: d[0..<0x400])
            directory(at: 0x800, parent: 0x203, signature: "Nick")
        }
        return d
    }
}

extension FloppyImage {
    /// A newly formatted disc with no file: everything on it counts as a
    /// change, to be saved somewhere.
    public static func blank(_ format: ADFSFloppyFormatter.Format, name: String) -> FloppyImage {
        let bytes = ADFSFloppyFormatter.blank(format, name: name)
        let g = MediaDetector.detect(bytes).geometry!
        let image = FloppyImage(data: [UInt8](repeating: 0, count: bytes.count), geometry: g)
        let store = ADFSFloppyStore(image: image)
        for s in stride(from: 0, to: bytes.count, by: g.sectorSize) where bytes[s..<(s + g.sectorSize)].contains(where: { $0 != 0 }) {
            try? store.write(s, Array(bytes[s..<(s + g.sectorSize)]))
        }
        return image
    }
}
