import Foundation

/// Adds files to an existing old-map hard disc (the layout `ADFSFormatter`
/// and `ADFSHardDiscBuilder` make, and !HForm's old-map option), so
/// software that came as archives can join what is already on the drive.
///
/// The old free space map lists up to 82 free areas: three-byte start
/// addresses from &000 and lengths from &100, both in 256-byte units, with
/// the list's end (three bytes per entry) at &1FE. Files are contiguous, so
/// each one takes the first free area big enough. Missing directories are
/// made, and a file of the same name is replaced (its space freed first).
/// A changed directory's master sequence number, at its start and at
/// &7FA, goes up by one as FileCore's own writes do.
///
/// Changes are made to a clone of the image that then takes its place, so
/// a failure part way leaves the drive as it was. The machine must not
/// have the drive open while this runs: RISC OS keeps the map and
/// directories in memory.
public enum ADFSHardDiscWriter {
    public struct Summary: Sendable, Equatable {
        /// RISC OS paths below "$", e.g. "!NetUtils.!Run".
        public var added: [String] = []
        public var replaced: [String] = []
        public var directoriesMade: [String] = []
        public var bytesFree = 0
    }

    public enum WriteError: Error, CustomStringConvertible {
        case notOldMap(String)
        case damaged(String)
        case mapFull
        case noRoom(path: String, needed: Int, largestFree: Int, totalFree: Int)

        public var description: String {
            switch self {
            case .notOldMap(let s): return "Only old-map (\"D\" format) hard discs can be added to: \(s)"
            case .damaged(let s): return "The hard disc looks damaged (\(s)); nothing was changed."
            case .mapFull: return "The free space map is too fragmented to record any more free areas. Run *Compact on the drive in RISC OS, then try again."
            case .noRoom(let p, let n, let l, let t):
                if n <= t { return "\(p) needs \(n / 1024) KB in one piece, but the largest free area is \(l / 1024) KB (\(t / 1024) KB free in all). Run *Compact on the drive in RISC OS, then try again." }
                return "There isn't room: \(p) needs \(n / 1024) KB but only \(t / 1024) KB is free."
            }
        }
    }

    /// What `add` would do, without changing the image.
    public static func plan(path: String, items: [ADFSHardDiscBuilder.Item]) throws -> Summary {
        let v = try Volume(path: path)
        return try v.add(items)
    }

    /// Adds `items` to the image at `path`.
    @discardableResult
    public static func add(path: String, items: [ADFSHardDiscBuilder.Item]) throws -> Summary {
        let url = URL(fileURLWithPath: path)
        let work = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".adding")
        let fm = FileManager.default
        try? fm.removeItem(at: work)
        try fm.copyItem(at: url, to: work) // a clone on APFS
        do {
            let v = try Volume(path: work.path)
            let summary = try v.add(items)
            try v.commit()
            guard rename(work.path, url.path) == 0 else { throw HardDiscError.create(String(cString: strerror(errno))) }
            return summary
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    // MARK: -

    struct Entry {
        var name: [UInt8]
        var load: UInt32, exec: UInt32, length: UInt32
        var sector: Int
        var attributes: UInt8
        var isDirectory: Bool { attributes & 0x08 != 0 }
    }

    final class Directory {
        let address: Int
        var bytes: [UInt8]
        var entries: [Entry]
        var path: String
        init(address: Int, bytes: [UInt8], entries: [Entry], path: String) {
            self.address = address; self.bytes = bytes; self.entries = entries; self.path = path
        }
    }

    final class Volume {
        let fd: Int32
        let size: Int
        let unit: Int // allocation unit in 256-byte map units
        var map: [UInt8]
        var free: [(start: Int, length: Int)] // 256-byte units, by address
        var directories: [Int: Directory] = [:]
        var changed: Set<Int> = []
        var data: [(offset: Int, bytes: [UInt8])] = []

        init(path: String) throws {
            let fd = Darwin.open(path, O_RDWR)
            guard fd >= 0 else { throw HardDiscError.cannotOpen(path) }
            var st = stat()
            fstat(fd, &st)
            let size = Int(st.st_size)
            func read(_ offset: Int, _ count: Int) -> [UInt8] {
                var b = [UInt8](repeating: 0, count: count)
                _ = pread(fd, &b, count, off_t(offset))
                return b
            }
            func fail(_ e: WriteError) -> WriteError { close(fd); return e }
            guard size >= 0xE00 else { throw fail(.notOldMap("the image is too small")) }
            let map = read(0, 0x200), boot = read(0xC00, 0x200), root = read(0x400, ADFSHardDiscBuilder.directorySize)
            guard Array(root[1...4]) == Array("Hugo".utf8), Array(root[2043...2046]) == Array("Hugo".utf8) else {
                throw fail(.notOldMap("there is no 2048-byte \"Hugo\" root directory at &400 (a new-map \"E\" disc, perhaps)"))
            }
            guard ADFSFormatter.checksum(map, 0, 0x100) == map[0xFF], ADFSFormatter.checksum(map, 0x100, 0x100) == map[0x1FF] else {
                throw fail(.damaged("the free space map's check bytes are wrong"))
            }
            let end = Int(map[0x1FE])
            guard end % 3 == 0, end / 3 <= Volume.maxFreeEntries else { throw fail(.damaged("the free space map's length is wrong")) }
            func get24(_ o: Int) -> Int { Int(map[o]) | Int(map[o + 1]) << 8 | Int(map[o + 2]) << 16 }
            var free: [(start: Int, length: Int)] = []
            for i in 0..<(end / 3) {
                let s = get24(3 * i), l = get24(0x100 + 3 * i)
                guard l > 0, (s + l) * 256 <= size else { throw fail(.damaged("a free area lies beyond the drive")) }
                free.append((s, l))
            }
            // The disc record's log2 sector size: IDE drives allocate in 512-byte sectors.
            let log2 = Int(boot[0x1C0])
            self.fd = fd
            self.size = size
            self.unit = (8...12).contains(log2) ? (1 << log2) / 256 : 1
            self.map = map
            self.free = free.sorted { $0.start < $1.start }
        }

        deinit { close(fd) }

        static let maxFreeEntries = 82

        func read(_ offset: Int, _ count: Int) -> [UInt8] {
            var b = [UInt8](repeating: 0, count: count)
            _ = pread(fd, &b, count, off_t(offset))
            return b
        }

        func get24(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 }

        func directory(at address: Int, path: String) throws -> Directory {
            if let d = directories[address] { return d }
            let n = ADFSHardDiscBuilder.directorySize
            guard address + n <= size else { throw WriteError.damaged("\(path) lies beyond the drive") }
            let b = read(address, n)
            guard Array(b[1...4]) == Array("Hugo".utf8), Array(b[2043...2046]) == Array("Hugo".utf8), b[0] == b[2042],
                  ADFSFormatter.directoryCheckByte(b) == b[2047] else {
                throw WriteError.damaged("\(path) is not a valid directory")
            }
            var entries: [Entry] = []
            var p = 5
            while entries.count < ADFSHardDiscBuilder.maxEntries, b[p] != 0 {
                let name = Array(b[p..<(p + 10)].prefix { $0 > 0x20 })
                func le32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
                entries.append(Entry(name: name, load: le32(p + 10), exec: le32(p + 14), length: le32(p + 18),
                                     sector: get24(b, p + 22), attributes: b[p + 25]))
                p += 26
            }
            let d = Directory(address: address, bytes: b, entries: entries, path: path)
            directories[address] = d
            return d
        }

        /// A new, empty directory (written with the others at the end).
        func makeDirectory(name: [UInt8], parent: Int, path: String) throws -> Directory {
            let address = try allocate(ADFSHardDiscBuilder.directorySize, for: path)
            var b = [UInt8](repeating: 0, count: ADFSHardDiscBuilder.directorySize)
            for (i, c) in "Hugo".utf8.enumerated() { b[1 + i] = c; b[2043 + i] = c }
            let title = Array(name.prefix(19)), short = Array(name.prefix(10))
            for (i, c) in title.enumerated() { b[2013 + i] = c }
            if title.count < 19 { b[2013 + title.count] = 0x0D }
            for (i, c) in short.enumerated() { b[2032 + i] = c }
            if short.count < 10 { b[2032 + short.count] = 0x0D }
            let ps = parent >> 8
            b[2010] = UInt8(ps & 0xFF); b[2011] = UInt8((ps >> 8) & 0xFF); b[2012] = UInt8((ps >> 16) & 0xFF)
            b[0] = 0xFF; b[2042] = 0xFF // the first write makes them 0
            let d = Directory(address: address, bytes: b, entries: [], path: path)
            directories[address] = d
            changed.insert(address)
            return d
        }

        func roundUp(_ n: Int) -> Int { let u = unit * 256; return (max(n, 1) + u - 1) / u * u }

        /// First fit, aligned to the sector size. Returns a byte address.
        func allocate(_ bytes: Int, for path: String) throws -> Int {
            let need = roundUp(bytes) / 256
            for (i, f) in free.enumerated() {
                let start = (f.start + unit - 1) / unit * unit
                guard start + need <= f.start + f.length else { continue }
                var pieces: [(start: Int, length: Int)] = []
                if start > f.start { pieces.append((f.start, start - f.start)) }
                if start + need < f.start + f.length { pieces.append((start + need, f.start + f.length - start - need)) }
                free.replaceSubrange(i...i, with: pieces)
                guard free.count <= Volume.maxFreeEntries else { throw WriteError.mapFull }
                return start * 256
            }
            throw WriteError.noRoom(path: path, needed: need * 256, largestFree: (free.map(\.length).max() ?? 0) * 256,
                                    totalFree: free.reduce(0) { $0 + $1.length } * 256)
        }

        func release(address: Int, length: Int) throws {
            let s = address / 256, l = roundUp(length) / 256
            free.append((s, l))
            free.sort { $0.start < $1.start }
            var merged: [(start: Int, length: Int)] = []
            for f in free {
                if let last = merged.last, last.start + last.length >= f.start {
                    merged[merged.count - 1].length = max(last.length, f.start + f.length - last.start)
                } else {
                    merged.append(f)
                }
            }
            free = merged
            guard free.count <= Volume.maxFreeEntries else { throw WriteError.mapFull }
        }

        static func key(_ name: [UInt8]) -> [UInt8] {
            ADFSHardDiscBuilder.latin1(String(String.UnicodeScalarView(name.map { Unicode.Scalar($0) })).uppercased())
        }

        func insert(_ e: Entry, into d: Directory) {
            let k = Volume.key(e.name)
            d.entries.removeAll { Volume.key($0.name) == k }
            let at = d.entries.firstIndex { k.lexicographicallyPrecedes(Volume.key($0.name)) } ?? d.entries.count
            d.entries.insert(e, at: at)
            changed.insert(d.address)
        }

        func add(_ items: [ADFSHardDiscBuilder.Item]) throws -> Summary {
            var s = Summary()
            var addedHere: Set<String> = []
            for item in items {
                var dir = try directory(at: 0x400, path: "$")
                for (i, component) in item.path.enumerated() {
                    guard ADFSHardDiscBuilder.isValidName(component) else { throw ADFSHardDiscBuilder.BuildError.badName(component) }
                    let name = ADFSHardDiscBuilder.latin1(component)
                    let path = item.path.prefix(i + 1).joined(separator: ".")
                    let existing = dir.entries.first { Volume.key($0.name) == Volume.key(name) }
                    let last = i == item.path.count - 1
                    if !last {
                        if let e = existing {
                            guard e.isDirectory else { throw ADFSHardDiscBuilder.BuildError.conflict(path) }
                            dir = try directory(at: e.sector * 256, path: path)
                            continue
                        }
                        guard dir.entries.count < ADFSHardDiscBuilder.maxEntries else {
                            throw ADFSHardDiscBuilder.BuildError.tooManyEntries(dir.path, dir.entries.count + 1)
                        }
                        let new = try makeDirectory(name: name, parent: dir.address, path: path)
                        let stamp = item.load & 0xFFF0_0000 == 0xFFF0_0000 ? (item.load & 0xFF, item.exec) : (0, 0)
                        insert(Entry(name: name, load: 0xFFFF_FD00 | stamp.0, exec: stamp.1, length: UInt32(ADFSHardDiscBuilder.directorySize),
                                     sector: new.address >> 8, attributes: 0x08), into: dir)
                        s.directoriesMade.append(path)
                        dir = new
                        continue
                    }
                    if let e = existing {
                        guard !e.isDirectory else { throw ADFSHardDiscBuilder.BuildError.conflict(path) }
                        try release(address: e.sector * 256, length: Int(e.length))
                        data.removeAll { $0.offset == e.sector * 256 }
                        if !addedHere.contains(path) { s.replaced.append(path) }
                    } else {
                        guard dir.entries.count < ADFSHardDiscBuilder.maxEntries else {
                            throw ADFSHardDiscBuilder.BuildError.tooManyEntries(dir.path, dir.entries.count + 1)
                        }
                    }
                    let address = try allocate(item.data.count, for: path)
                    data.append((address, item.data))
                    insert(Entry(name: name, load: item.load, exec: item.exec, length: UInt32(item.data.count),
                                 sector: address >> 8, attributes: item.attributes & 0x37), into: dir)
                    if !addedHere.contains(path) && existing == nil { s.added.append(path) }
                    addedHere.insert(path)
                }
            }
            s.bytesFree = free.reduce(0) { $0 + $1.length } * 256
            return s
        }

        func write(_ offset: Int, _ bytes: [UInt8]) throws {
            guard pwrite(fd, bytes, bytes.count, off_t(offset)) == bytes.count else {
                throw HardDiscError.create(String(cString: strerror(errno)))
            }
        }

        /// Writes the files, then the directories, then the map.
        func commit() throws {
            for d in data { try write(d.offset, d.bytes) }
            for address in changed.sorted() {
                let d = directories[address]!
                var b = d.bytes
                for i in 5..<2007 { b[i] = 0 }
                var p = 5
                for e in d.entries {
                    for (i, c) in e.name.prefix(10).enumerated() { b[p + i] = c }
                    if e.name.count < 10 { b[p + e.name.count] = 0x0D }
                    for i in 0..<4 {
                        b[p + 10 + i] = UInt8((e.load >> (8 * i)) & 0xFF)
                        b[p + 14 + i] = UInt8((e.exec >> (8 * i)) & 0xFF)
                        b[p + 18 + i] = UInt8((e.length >> (8 * i)) & 0xFF)
                    }
                    b[p + 22] = UInt8(e.sector & 0xFF); b[p + 23] = UInt8((e.sector >> 8) & 0xFF); b[p + 24] = UInt8((e.sector >> 16) & 0xFF)
                    b[p + 25] = e.attributes
                    p += 26
                }
                b[0] &+= 1
                b[2042] = b[0]
                b[2047] = ADFSFormatter.directoryCheckByte(b)
                try write(address, b)
            }
            var m = map
            for i in 0..<0xF6 { m[i] = 0; m[0x100 + i] = 0 }
            for (i, f) in free.enumerated() {
                for k in 0..<3 {
                    m[3 * i + k] = UInt8((f.start >> (8 * k)) & 0xFF)
                    m[0x100 + 3 * i + k] = UInt8((f.length >> (8 * k)) & 0xFF)
                }
            }
            m[0x1FE] = UInt8(3 * free.count)
            m[0xFF] = ADFSFormatter.checksum(m, 0, 0x100)
            m[0x1FF] = ADFSFormatter.checksum(m, 0x100, 0x100)
            try write(0, m)
            fsync(fd)
        }
    }
}
