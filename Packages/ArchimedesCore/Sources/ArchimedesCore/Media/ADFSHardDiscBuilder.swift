import Foundation

/// Builds a formatted hard disc image (old map, as `ADFSFormatter` lays it
/// out) holding a tree of files: software that only ever came as files,
/// such as an archive of a hard-disc-only game, can then be used without
/// a RISC OS machine to copy it across.
///
/// Directories are 2048-byte "Hugo" directories, as on ADFS D floppies and
/// old-map hard discs: up to 77 entries of 26 bytes, sorted by name without
/// regard to case. An entry holds the name (up to 10 characters, ended by
/// CR when shorter), load and execution addresses, length, a three-byte
/// disc address in 256-byte units, and an attribute byte (bit 0 R, 1 W,
/// 2 L, 3 directory, 4 r, 5 w). Files are placed one after another from
/// &E00, and the free space map gets the rest of the drive.
public enum ADFSHardDiscBuilder {
    public struct Item: Sendable {
        /// RISC OS path components below "$", e.g. ["!SC2000", "!Run"].
        public var path: [String]
        public var data: [UInt8]
        public var load: UInt32
        public var exec: UInt32
        public var attributes: UInt8

        public init(path: [String], data: [UInt8], load: UInt32, exec: UInt32, attributes: UInt8 = 0x03) {
            self.path = path; self.data = data; self.load = load; self.exec = exec; self.attributes = attributes
        }

        /// A typed, date-stamped file (`type` is the 12-bit RISC OS filetype).
        public init(path: [String], data: [UInt8], type: UInt16, date: Date = Date(timeIntervalSince1970: 0)) {
            let cs = UInt64(max(0, date.timeIntervalSince1970 + 2_208_988_800) * 100) // centiseconds since 1900
            self.init(path: path, data: data, load: 0xFFF0_0000 | UInt32(type & 0xFFF) << 8 | UInt32((cs >> 32) & 0xFF),
                      exec: UInt32(cs & 0xFFFF_FFFF))
        }
    }

    public enum BuildError: Error, CustomStringConvertible {
        case badName(String)
        case tooManyEntries(String, Int)
        case doesNotFit(needed: Int, available: Int)
        case conflict(String)

        public var description: String {
            switch self {
            case .badName(let s): return "\"\(s)\" can't be an ADFS name (at most 10 characters, none of $&@^%\\:.#*\"| or control characters)"
            case .tooManyEntries(let d, let n): return "\(d) has \(n) entries; an old-map ADFS directory holds at most 77"
            case .doesNotFit(let n, let a): return "the files need \(n / 1024) KB but the drive has \(a / 1024) KB free"
            case .conflict(let s): return "\(s) is both a file and a directory"
            }
        }
    }

    static let directorySize = 2048
    static let maxEntries = 77

    final class Node {
        var name: String
        var item: Item?
        var children: [String: Node] = [:]
        var address = 0
        var isDirectory: Bool { item == nil }
        init(name: String, item: Item? = nil) { self.name = name; self.item = item }
        var sortedChildren: [Node] { children.values.sorted { latin1($0.name.uppercased()).lexicographicallyPrecedes(latin1($1.name.uppercased())) } }
    }

    /// Creates `path` with the files in `items` on a freshly formatted drive.
    public static func create(path: String, geometry: HardDiscGeometry, name: String, items: [Item], directories: [[String]] = [],
                              bootOption: UInt8 = 0) throws {
        let image = try build(geometry: geometry, name: name, items: items, directories: directories, bootOption: bootOption)
        let img = try HardDiscImage.create(path: path, geometry: geometry)
        let size = geometry.sectorSize, g = geometry
        for start in stride(from: 0, to: image.count, by: size) {
            let chunk = Array(image[start..<min(start + size, image.count)])
            if chunk.allSatisfy({ $0 == 0 }) { continue } // the new image is already zero
            let lba = start / size
            img.write(cylinder: lba / (g.heads * g.sectorsPerTrack), head: (lba / g.sectorsPerTrack) % g.heads,
                      sector: lba % g.sectorsPerTrack, chunk)
        }
        img.synchronize()
    }

    /// The used part of the drive (everything after it is zero).
    /// `directories` adds directories that may be empty. `bootOption` is
    /// *Opt 4's: 0 none, 1 load, 2 run, 3 exec $.!Boot at start-up.
    public static func build(geometry g: HardDiscGeometry, name: String, items: [Item], directories: [[String]] = [],
                             bootOption: UInt8 = 0) throws -> [UInt8] {
        let root = Node(name: "$")
        for (path, item) in items.map({ ($0.path, Optional($0)) }) + directories.map({ ($0, nil) }) {
            var dir = root
            for (i, component) in path.enumerated() {
                guard isValidName(component) else { throw BuildError.badName(component) }
                let key = component.uppercased()
                let last = i == path.count - 1 && item != nil
                if let existing = dir.children[key] {
                    if last || !existing.isDirectory { throw BuildError.conflict(path.prefix(i + 1).joined(separator: ".")) }
                    dir = existing
                } else {
                    let node = Node(name: component, item: last ? item : nil)
                    dir.children[key] = node
                    dir = node
                }
            }
        }

        // Allocate: directories and files in tree order, aligned to sectors.
        let unit = max(256, g.sectorSize)
        func roundUp(_ n: Int) -> Int { (max(n, 1) + unit - 1) / unit * unit }
        var next = 0xE00
        root.address = 0x400
        func allocate(_ dir: Node, path: String) throws {
            let kids = dir.sortedChildren
            if kids.count > maxEntries { throw BuildError.tooManyEntries(path, kids.count) }
            for k in kids {
                k.address = next
                next += roundUp(k.isDirectory ? directorySize : k.item!.data.count)
            }
            for k in kids where k.isDirectory { try allocate(k, path: path + "." + k.name) }
        }
        try allocate(root, path: "$")
        guard next <= g.byteCount else { throw BuildError.doesNotFit(needed: next, available: g.byteCount - 0xE00) }

        var d = ADFSFormatter.layout(geometry: g, name: name, id: ADFSFormatter.discID(for: name))
        d += [UInt8](repeating: 0, count: next - d.count)
        // Free space map: what's left after the files, if anything.
        let sectors = g.byteCount / 256
        func put24(_ v: Int, at o: Int) { d[o] = UInt8(v & 0xFF); d[o + 1] = UInt8((v >> 8) & 0xFF); d[o + 2] = UInt8((v >> 16) & 0xFF) }
        if next < g.byteCount {
            put24(next >> 8, at: 0x000)
            put24(sectors - (next >> 8), at: 0x100)
            d[0x1FE] = 3
        } else {
            put24(0, at: 0x000); put24(0, at: 0x100)
            d[0x1FE] = 0
        }
        d[0x1FD] = bootOption & 3
        d[0x0FF] = ADFSFormatter.checksum(d, 0x000, 0x100)
        d[0x1FF] = ADFSFormatter.checksum(d, 0x100, 0x100)

        // The time stamp (centiseconds since 1900) of the newest typed file.
        func newest(_ n: Node) -> UInt64 {
            if let i = n.item {
                return i.load & 0xFFF0_0000 == 0xFFF0_0000 ? UInt64(i.load & 0xFF) << 32 | UInt64(i.exec) : 0
            }
            return n.children.values.map(newest).max() ?? 0
        }

        func write(_ dir: Node, parent: Int) {
            var b = [UInt8](repeating: 0, count: directorySize)
            for (i, c) in "Hugo".utf8.enumerated() { b[1 + i] = c; b[2043 + i] = c }
            var p = 5
            for k in dir.sortedChildren {
                let n = latin1(k.name)
                for (i, c) in n.enumerated() { b[p + i] = c }
                if n.count < 10 { b[p + n.count] = 0x0D }
                // A directory is dated by the newest file inside it.
                let dirStamp = k.isDirectory ? newest(k) : 0
                let (load, exec, length, attr): (UInt32, UInt32, Int, UInt8) = k.isDirectory
                    ? (0xFFFF_FD00 | UInt32((dirStamp >> 32) & 0xFF), UInt32(dirStamp & 0xFFFF_FFFF), directorySize, 0x08)
                    : (k.item!.load, k.item!.exec, k.item!.data.count, k.item!.attributes & 0x37)
                for i in 0..<4 {
                    b[p + 10 + i] = UInt8((load >> (8 * i)) & 0xFF)
                    b[p + 14 + i] = UInt8((exec >> (8 * i)) & 0xFF)
                    b[p + 18 + i] = UInt8((length >> (8 * i)) & 0xFF)
                }
                let sector = k.address >> 8
                b[p + 22] = UInt8(sector & 0xFF); b[p + 23] = UInt8((sector >> 8) & 0xFF); b[p + 24] = UInt8((sector >> 16) & 0xFF)
                b[p + 25] = attr
                p += 26
            }
            let ps = parent >> 8
            b[2010] = UInt8(ps & 0xFF); b[2011] = UInt8((ps >> 8) & 0xFF); b[2012] = UInt8((ps >> 16) & 0xFF)
            let title = Array(latin1(dir.name).prefix(19)), short = Array(latin1(dir.name).prefix(10))
            for (i, c) in title.enumerated() { b[2013 + i] = c }
            if title.count < 19 { b[2013 + title.count] = 0x0D }
            for (i, c) in short.enumerated() { b[2032 + i] = c }
            if short.count < 10 { b[2032 + short.count] = 0x0D }
            b[2047] = ADFSFormatter.directoryCheckByte(b)
            d.replaceSubrange(dir.address..<(dir.address + directorySize), with: b)
            for k in dir.sortedChildren {
                if k.isDirectory { write(k, parent: dir.address) }
                else { d.replaceSubrange(k.address..<(k.address + k.item!.data.count), with: k.item!.data) }
            }
        }
        write(root, parent: 0x400)
        return d
    }

    static func isValidName(_ s: String) -> Bool {
        guard s.unicodeScalars.allSatisfy({ $0.value <= 0xFF }) else { return false }
        let b = latin1(s)
        guard !b.isEmpty, b.count <= 10 else { return false }
        return b.allSatisfy { $0 > 0x20 && $0 != 0x7F && !"$&@^%\\:.#*\"|".utf8.contains($0) }
    }

    /// RISC OS names are Latin-1 bytes.
    static func latin1(_ s: String) -> [UInt8] { s.unicodeScalars.map { $0.value <= 0xFF ? UInt8($0.value) : 0x5F } }

    // MARK: - Sources

    /// The files in a ZIP archive, under a folder, or on an ADFS D or E
    /// format floppy image.
    public static func items(from path: String) throws -> [Item] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { throw MediaError.unreadable(path) }
        if isDir.boolValue { return try items(fromFolder: URL(fileURLWithPath: path)) }
        guard let d = FileManager.default.contents(atPath: path) else { throw MediaError.unreadable(path) }
        let bytes = [UInt8](d)
        if ZipArchive.isZip(bytes) { return try items(fromZip: bytes) }
        if let disc = try? ADFSDiscReader.read(bytes: bytes) { return disc.items }
        throw MediaError.unsupportedFormat("\(path) is not a folder, a ZIP archive or an ADFS floppy")
    }

    /// The files in a ZIP archive. Acorn extra fields give filetypes and
    /// dates; other members are typed from their names (see `hostItem`).
    /// A top-level folder of the archive's own name is kept, so an archive
    /// of "!App" gives "$.!App".
    public static func items(fromZip bytes: [UInt8]) throws -> [Item] {
        try ZipArchive.read(bytes).filter { !$0.isDirectory }.map { m in
            let comps = m.path.split(separator: "/").map(String.init)
            if let load = m.load, let exec = m.exec {
                let attr = UInt8((m.attributes ?? 3) & 0x37)
                return Item(path: comps.map(riscOSName), data: m.data, load: load, exec: exec, attributes: attr == 0 ? 3 : attr)
            }
            return hostItem(comps, data: m.data, date: m.modified ?? Date(timeIntervalSince1970: 0))
        }
    }

    /// The files under a folder on the Mac. A ",xxx" suffix on a name gives
    /// the filetype (the convention RISC OS emulators and NFS servers use).
    public static func items(fromFolder url: URL) throws -> [Item] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            throw MediaError.unreadable(url.path)
        }
        let base = url.standardizedFileURL.pathComponents.count
        var out: [Item] = []
        for case let f as URL in e {
            let v = try f.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            if v.isDirectory == true { continue }
            let comps = Array(f.standardizedFileURL.pathComponents.dropFirst(base))
            out.append(hostItem(comps, data: [UInt8](try Data(contentsOf: f)), date: v.contentModificationDate ?? Date()))
        }
        return out.sorted { $0.path.joined(separator: ".") < $1.path.joined(separator: ".") }
    }

    /// A file from the host: its type from a ",xxx" suffix, else from the
    /// usual names (!Run and !Boot are Obey, !Sprites a sprite file, !Help
    /// text), else Data.
    static func hostItem(_ comps: [String], data: [UInt8], date: Date) -> Item {
        var path = comps
        var type: UInt16?
        if let last = path.last, let comma = last.lastIndex(of: ","), let t = UInt16(last[last.index(after: comma)...], radix: 16),
           last.distance(from: comma, to: last.endIndex) == 4 {
            type = t
            path[path.count - 1] = String(last[..<comma])
        }
        if type == nil {
            switch path.last?.lowercased() {
            case "!run", "!boot": type = 0xFEB
            case "!sprites", "!sprites22", "!sprites23": type = 0xFF9
            case "!help": type = 0xFFF
            default: type = 0xFFD
            }
        }
        return Item(path: path.map(riscOSName), data: data, type: type!, date: date)
    }

    /// Host names to RISC OS: "." becomes "/" (as RISC OS file systems
    /// write a "." in a name) and spaces become hard spaces.
    static func riscOSName(_ s: String) -> String {
        String(s.map { $0 == "." ? "/" : $0 == " " ? "\u{A0}" : $0 })
    }
}
