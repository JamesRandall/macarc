import Foundation

public enum ADFSError: Error, Equatable, LocalizedError, CustomStringConvertible {
    case notADFS
    case unsupported(String)
    case damaged(String)
    case unreadable(String)
    case writeProtected
    case badName(String)
    case exists(String)
    case locked(String)
    case notFound(String)
    case notEmpty(String)
    case directoryFull(String)
    case discFull(needed: Int, free: Int)
    case mapFull
    case changedSince

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .notADFS: return "The disc isn't an ADFS disc this can read (D, E or F format, or an ADFS hard disc)."
        case .unsupported(let s): return "\(s) can't be changed here yet."
        case .damaged(let s): return "The disc looks damaged: \(s)."
        case .unreadable(let s): return "Part of the disc can't be read: \(s)."
        case .writeProtected: return "The disc is write protected."
        case .badName(let s): return "\u{201C}\(s)\u{201D} isn't a name the disc can hold: up to 10 characters, without spaces or $ & @ ^ % \\ : . # * \" |."
        case .exists(let s): return "There's already a directory called \u{201C}\(s)\u{201D}."
        case .locked(let s): return "\u{201C}\(s)\u{201D} is locked."
        case .notFound(let s): return "There's no \u{201C}\(s)\u{201D} on the disc."
        case .notEmpty(let s): return "The directory \u{201C}\(s)\u{201D} isn't empty."
        case .directoryFull(let s): return "The directory \u{201C}\(s)\u{201D} is full: a directory holds at most 77 entries."
        case .discFull(let n, let f):
            return "There isn't room on the disc: that needs \(ADFSError.kb(n)), and \(ADFSError.kb(f)) is free."
        case .mapFull: return "The disc's free space is too broken up to record. Compact it in RISC OS (*Compact), then try again."
        case .changedSince: return "The disc has been written to since, so that can't be undone."
        }
    }

    static func kb(_ n: Int) -> String { n >= 10 << 20 ? "\(n >> 20) MB" : "\((n + 1023) / 1024) KB" }
}

/// An ADFS filing system to read and change: files and directories, their
/// names, addresses, types and access, the disc's name and boot option.
///
/// Old-map discs (D format floppies and old-map hard discs: a free space
/// list at &000, and 2048-byte "Hugo" directories at sector addresses),
/// L, M and S format floppies (the same map, with the old 1280-byte
/// directories) and new-map discs (E and F format floppies and new-map hard
/// discs: a zoned allocation map, "Nick" directories at fragment addresses)
/// are all handled; see `ADFSOldMap` and `ADFSNewMap`. Big directories (E+
/// and F+ formats) aren't.
///
/// Changes are made in memory and written by `flush`; give the volume an
/// `ADFSBufferedStore` (as `edit` does) to make a change all or nothing.
public final class ADFSVolume {
    public struct Entry: Sendable, Hashable, Identifiable {
        public var name: String
        public var load: UInt32
        public var exec: UInt32
        public var length: Int
        /// Bit 0 owner read, 1 owner write, 2 locked, 3 directory, 4 public read, 5 public write.
        public var attributes: UInt8
        /// Where it is: a sector address (old map) or an indirect one (new map).
        public var address: UInt32

        public var id: String { ADFSVolume.key(name) }
        public var isDirectory: Bool { attributes & 0x08 != 0 }
        public var isLocked: Bool { attributes & 0x04 != 0 }
        public var isApplication: Bool { isDirectory && name.hasPrefix("!") }
        /// The 12-bit RISC OS filetype, when the load address holds one.
        public var fileType: UInt16? { load & 0xFFF0_0000 == 0xFFF0_0000 && !isDirectory ? UInt16((load >> 8) & 0xFFF) : nil }
        public var isTyped: Bool { load & 0xFFF0_0000 == 0xFFF0_0000 }
        /// The date stamp of a typed file or directory.
        public var date: Date? {
            guard isTyped else { return nil }
            return ADFSVolume.date(load: load, exec: exec)
        }
        /// "WR/r", as *Info and the Filer show access.
        public var access: String {
            var s = ""
            if isDirectory { s += "D" }
            if isLocked { s += "L" }
            if attributes & 0x02 != 0 { s += "W" }
            if attributes & 0x01 != 0 { s += "R" }
            s += "/"
            if attributes & 0x20 != 0 { s += "w" }
            if attributes & 0x10 != 0 { s += "r" }
            return s
        }
    }

    public let store: ADFSStore
    let map: ADFSMapping
    var directories: [UInt32: Directory] = [:]

    public init(store: ADFSStore) throws {
        self.store = store
        if let m = try ADFSOldMap(store: store) {
            map = m
        } else if let m = try ADFSNewMap(store: store) {
            map = m
        } else {
            throw ADFSError.notADFS
        }
        _ = try directory(at: map.rootAddress, path: "$")
    }

    /// Makes a change, all or nothing, with a new disc ID so RISC OS reads
    /// the disc afresh rather than trusting what it remembers of it.
    @discardableResult
    public static func edit(_ store: ADFSStore, _ change: (ADFSVolume) throws -> Void) throws -> ADFSChange {
        let buffered = ADFSBufferedStore(store)
        let v = try ADFSVolume(store: buffered)
        try change(v)
        v.changeDiscID()
        try v.flush()
        return try buffered.commit()
    }

    // MARK: The disc

    /// "ADFS E", "Old-map hard disc" and so on.
    public var formatName: String { map.formatName }
    public var isNewMap: Bool { map is ADFSNewMap }
    /// L, M and S format: names are plain ASCII, and only R, W, L and D are kept.
    public var hasOldDirectories: Bool { map.directorySize == Directory.oldSize }
    public var size: Int { map.discSize }
    public var freeBytes: Int { map.freeBytes }

    public var discName: String {
        String(String.UnicodeScalarView(map.discName.prefix { $0 > 0x20 && $0 != 0x7F }.map { Unicode.Scalar($0) }))
    }

    /// Letters, digits and a few others, at most ten (as *NameDisc takes).
    public static func isValidDiscName(_ s: String) -> Bool {
        s.utf8.count <= 10 && s.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7F && !"$&@^%\\:.#*\"|".utf8.contains($0) }
    }

    public func setDiscName(_ s: String) throws {
        guard Self.isValidDiscName(s) else { throw ADFSError.badName(s) }
        map.discName = Array(s.utf8)
    }

    /// 0 none, 1 *Load, 2 *Run, 3 *Exec the root's !Boot.
    public var bootOption: Int { Int(map.bootOption & 3) }
    public func setBootOption(_ n: Int) { map.bootOption = UInt8(n & 3) }

    public func changeDiscID() { map.changeDiscID() }

    // MARK: Reading

    public func entries(at path: [String]) throws -> [Entry] {
        try resolve(path).entries.map(\.public)
    }

    public func entry(_ name: String, at path: [String]) throws -> Entry {
        let d = try resolve(path)
        guard let e = d.entries.first(where: { Self.key($0.name) == Self.key(Self.latin1(name)) }) else { throw ADFSError.notFound(name) }
        return e.public
    }

    /// The title of the directory at `path` (the root's is the disc's title).
    public func title(at path: [String]) throws -> String {
        let d = try resolve(path)
        return String(String.UnicodeScalarView(d.bytes[d.titleOffset..<(d.titleOffset + 19)].prefix { $0 >= 0x20 && $0 != 0x7F }.map { Unicode.Scalar($0) }))
    }

    public func contents(of name: String, at path: [String]) throws -> [UInt8] {
        let e = try entry(name, at: path)
        guard !e.isDirectory else { throw ADFSError.notFound(name) }
        return try read(e.address, length: e.length)
    }

    func read(_ address: UInt32, length: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(length)
        for x in try map.extents(address, length: length) { out += try store.read(x.start, x.count) }
        return out
    }

    func write(_ address: UInt32, _ bytes: [UInt8]) throws {
        var i = 0
        for x in try map.extents(address, length: bytes.count) {
            try store.write(x.start, Array(bytes[i..<(i + x.count)]))
            i += x.count
        }
    }

    // MARK: Changing

    /// Saves a file, replacing an unlocked file of the same name.
    public func save(_ data: [UInt8], name: String, at path: [String], load: UInt32, exec: UInt32, attributes: UInt8 = 0x03) throws {
        let d = try resolve(path)
        let raw = try validName(name)
        var replaced: RawEntry?
        if let i = d.index(of: raw) {
            let e = d.entries[i]
            guard !e.isDirectory else { throw ADFSError.exists(name) }
            guard !e.isLocked else { throw ADFSError.locked(name) }
            d.entries.remove(at: i)
            d.changed = true
            replaced = e
        } else if d.entries.count >= d.maxEntries {
            throw ADFSError.directoryFull(d.path)
        }
        if let r = replaced { try release(r) }
        let address = try map.allocate(data.count)
        try write(address, data)
        d.insert(RawEntry(name: raw, load: load, exec: exec, length: UInt32(data.count), address: address, attributes: attributes & 0x37 & ~0x08))
    }

    /// Makes an empty directory, or does nothing if there is one of that name.
    public func makeDirectory(_ name: String, at path: [String], date: Date = Date()) throws {
        let d = try resolve(path)
        let raw = try validName(name)
        if let i = d.index(of: raw) {
            guard d.entries[i].isDirectory else { throw ADFSError.exists(name) }
            return
        }
        guard d.entries.count < d.maxEntries else { throw ADFSError.directoryFull(d.path) }
        let address = try map.allocate(map.directorySize)
        let child = Directory.empty(address: address, size: map.directorySize, parent: d.address, name: raw,
                                    signature: map.directorySignature, path: d.path + "." + name)
        directories[address] = child
        // Directories are stamped as type &FFD would be (load &FFFFFDxx).
        let (load, exec) = Self.stamp(type: 0xFFD, date: date)
        d.insert(RawEntry(name: raw, load: load, exec: exec, length: UInt32(map.directorySize),
                          address: address, attributes: 0x08))
    }

    /// Deletes a file, or a directory (with everything in it when `recursive`).
    public func delete(_ name: String, at path: [String], recursive: Bool = false) throws {
        let d = try resolve(path)
        guard let i = d.index(of: Self.latin1(name)) else { throw ADFSError.notFound(name) }
        let e = d.entries[i]
        try checkDeletable(e, in: d, recursive: recursive)
        d.entries.remove(at: i)
        d.changed = true
        try release(e, recursive: true)
    }

    private func checkDeletable(_ e: RawEntry, in d: Directory, recursive: Bool) throws {
        guard !e.isLocked else { throw ADFSError.locked(e.string) }
        guard e.isDirectory else { return }
        let child = try directory(at: e.address, path: d.path + "." + e.string)
        guard child.entries.isEmpty || recursive else { throw ADFSError.notEmpty(e.string) }
        for c in child.entries { try checkDeletable(c, in: child, recursive: true) }
    }

    /// Frees an object's space (and, for a directory, everything in it),
    /// once nothing else on the disc refers to it.
    private func release(_ e: RawEntry, recursive: Bool = false) throws {
        if e.isDirectory {
            let child = try directory(at: e.address, path: e.string)
            if recursive { for c in child.entries { try release(c, recursive: true) } }
            directories[e.address] = nil
        }
        try map.release(e.address, length: e.isDirectory ? map.directorySize : Int(e.length)) { [unowned self] in
            try self.isReferenced(e.address)
        }
    }

    /// Whether any entry on the disc uses the fragment `address` is in
    /// (new-map objects can share one).
    private func isReferenced(_ address: UInt32) throws -> Bool {
        let id = address >> 8
        var seen: Set<UInt32> = []
        func walk(_ d: Directory, depth: Int) throws -> Bool {
            guard depth < 32, seen.insert(d.address).inserted else { return false }
            for e in d.entries {
                if e.address >> 8 == id { return true }
                if e.isDirectory, try walk(try directory(at: e.address, path: d.path + "." + e.string), depth: depth + 1) { return true }
            }
            return false
        }
        return try walk(try directory(at: map.rootAddress, path: "$"), depth: 0)
    }

    public func rename(_ name: String, at path: [String], to newName: String) throws {
        let d = try resolve(path)
        guard let i = d.index(of: Self.latin1(name)) else { throw ADFSError.notFound(name) }
        let raw = try validName(newName)
        if let j = d.index(of: raw), j != i { throw ADFSError.exists(newName) }
        var e = d.entries.remove(at: i)
        e.name = raw
        d.insert(e)
        if e.isDirectory {
            let child = try directory(at: e.address, path: d.path + "." + newName)
            child.setName(raw)
        }
    }

    /// Changes a file's load and execution addresses (so its type and date)
    /// and an object's access (a directory keeps its D).
    public func setInfo(_ name: String, at path: [String], load: UInt32? = nil, exec: UInt32? = nil, attributes: UInt8? = nil) throws {
        let d = try resolve(path)
        guard let i = d.index(of: Self.latin1(name)) else { throw ADFSError.notFound(name) }
        var e = d.entries[i]
        if let load { e.load = load }
        if let exec { e.exec = exec }
        if let attributes { e.attributes = (attributes & 0x37 & ~0x08) | (e.attributes & 0x08) }
        d.replace(at: i, with: e)
    }

    /// Writes the changed directories and the map.
    public func flush() throws {
        for d in directories.values where d.changed {
            try write(d.address, d.encoded())
            d.changed = false
        }
        try map.flush(to: store)
    }

    // MARK: Checking

    /// Problems with the disc's structure: objects outside it, overlapping
    /// each other or free space. Empty when all is well.
    public func check() throws -> [String] {
        var problems: [String] = []
        var used: [(start: Int, end: Int, what: String)] = []
        var seenIDs: [UInt32: String] = [:]
        func walk(_ d: Directory, depth: Int) throws {
            guard depth < 32 else { problems.append("\(d.path) nests too deeply"); return }
            for e in d.entries {
                let what = d.path + "." + e.string
                let length = e.isDirectory ? map.directorySize : Int(e.length)
                if isNewMap && e.address & 0xFF == 0 && length > 0 {
                    if let other = seenIDs[e.address >> 8] { problems.append("\(what) and \(other) share fragment \(e.address >> 8)") }
                    seenIDs[e.address >> 8] = what
                }
                do {
                    for x in try map.extents(e.address, length: length) where x.count > 0 {
                        guard x.start + x.count <= size else { problems.append("\(what) lies beyond the disc"); continue }
                        used.append((x.start, x.start + x.count, what))
                    }
                } catch { problems.append("\(what): \(error)") }
                if e.isDirectory {
                    do { try walk(try directory(at: e.address, path: what), depth: depth + 1) } catch { problems.append("\(what): \(error)") }
                }
            }
        }
        try walk(try directory(at: map.rootAddress, path: "$"), depth: 0)
        let free = map.freeAreas
        if !isNewMap {
            // Old map: objects (whole sectors) and free areas mustn't overlap.
            let unit = store.sectorSize
            let objects = used.map { (start: $0.start, end: ($0.end + unit - 1) / unit * unit, what: $0.what) }.sorted { $0.start < $1.start }
            for (a, b) in zip(objects, objects.dropFirst()) where b.start < a.end && !(a.start == b.start && a.what == b.what) {
                problems.append("\(a.what) overlaps \(b.what)")
            }
            for f in free {
                for o in objects where o.start < f.end && f.start < o.end { problems.append("free space at &\(String(f.start, radix: 16, uppercase: true)) overlaps \(o.what)") }
            }
        } else {
            for x in used {
                for f in free where x.start < f.end && f.start < x.end {
                    problems.append("free space at &\(String(f.start, radix: 16, uppercase: true)) overlaps \(x.what)")
                }
            }
        }
        return problems + map.problems
    }

    // MARK: Names and stamps

    static func latin1(_ s: String) -> [UInt8] { ADFSHardDiscBuilder.latin1(s) }

    static func key(_ name: [UInt8]) -> [UInt8] {
        name.map { $0 >= 0x61 && $0 <= 0x7A ? $0 - 0x20 : $0 }
    }

    static func key(_ s: String) -> String { String(decoding: key(latin1(s)), as: UTF8.self) }

    public static func isValidName(_ s: String) -> Bool { ADFSHardDiscBuilder.isValidName(s) }

    /// A name for this disc, as its bytes: old directories keep access in
    /// the names' top bits, so their names are ASCII.
    func validName(_ s: String) throws -> [UInt8] {
        guard Self.isValidName(s) else { throw ADFSError.badName(s) }
        let raw = Self.latin1(s)
        guard !hasOldDirectories || raw.allSatisfy({ $0 < 0x80 }) else { throw ADFSError.badName(s) }
        return raw
    }

    /// `s` made storable here: on an L, M or S disc, hard spaces and other
    /// characters beyond ASCII become "_".
    public func storableName(_ s: String) -> String {
        guard hasOldDirectories else { return s }
        return String(s.unicodeScalars.map { $0.value < 0x80 ? Character($0) : "_" })
    }

    /// The load and execution addresses of a file of `type` stamped `date`.
    public static func stamp(type: UInt16, date: Date) -> (load: UInt32, exec: UInt32) {
        let cs = UInt64(max(0, (date.timeIntervalSince1970 + 2_208_988_800) * 100))
        return (0xFFF0_0000 | UInt32(type & 0xFFF) << 8 | UInt32((cs >> 32) & 0xFF), UInt32(cs & 0xFFFF_FFFF))
    }

    public static func date(load: UInt32, exec: UInt32) -> Date {
        let cs = UInt64(load & 0xFF) << 32 | UInt64(exec)
        return Date(timeIntervalSince1970: Double(cs) / 100 - 2_208_988_800)
    }

    // MARK: Directories

    struct RawEntry {
        var name: [UInt8]
        var load: UInt32, exec: UInt32, length: UInt32
        var address: UInt32
        var attributes: UInt8
        /// An old directory's: the directory's sequence number when the entry last changed.
        var sequence: UInt8 = 0
        var isDirectory: Bool { attributes & 0x08 != 0 }
        var isLocked: Bool { attributes & 0x04 != 0 }
        var string: String { String(String.UnicodeScalarView(name.map { Unicode.Scalar($0) })) }
        var `public`: Entry {
            Entry(name: string, load: load, exec: exec, length: Int(length), attributes: attributes, address: address)
        }
    }

    /// A directory: entries of 26 bytes from offset 5, sorted by name
    /// without regard to case, and a tail with the parent's address, the
    /// title and the name. The master sequence number at 0 and six bytes from
    /// the end, and the "Hugo" or "Nick" at 1 and five from the end, must
    /// agree, and the last byte is a check over the entries and tail.
    ///
    /// D, E and F format directories are 2048 bytes (77 entries, access in
    /// each entry's last byte). The old ones of L, M and S format are 1280
    /// (47 entries); they keep R, W, L and D in the top bits of the name's
    /// first four characters, and in the last byte the directory's sequence
    /// number when the entry last changed.
    final class Directory {
        static let oldSize = 1280

        let address: UInt32
        var bytes: [UInt8]
        var entries: [RawEntry]
        let path: String
        var changed = false

        var size: Int { bytes.count }
        var isOld: Bool { size == Self.oldSize }
        /// Where the entries end and the tail starts.
        var tail: Int { isOld ? 1227 : 2007 }
        var maxEntries: Int { (tail - 5) / 26 }
        var parentOffset: Int { isOld ? 1238 : 2010 }
        var titleOffset: Int { isOld ? 1241 : 2013 }
        var nameOffset: Int { isOld ? 1228 : 2032 }

        init(address: UInt32, bytes: [UInt8], path: String) throws {
            self.address = address
            self.bytes = bytes
            self.path = path
            let size = bytes.count, isOld = size == Self.oldSize
            let sig = Array(bytes[1...4])
            if sig == Array("SBPr".utf8) { throw ADFSError.unsupported("Discs with big directories (E+ and F+ formats)") }
            guard sig == Array("Hugo".utf8) || sig == Array("Nick".utf8), Array(bytes[(size - 5)...(size - 2)]) == sig, bytes[0] == bytes[size - 6] else {
                throw ADFSError.damaged("\(path) isn't a valid directory")
            }
            guard ADFSFormatter.directoryCheckByte(bytes) == bytes[size - 1] else {
                throw ADFSError.damaged("\(path)'s check byte is wrong (RISC OS would call it a broken directory)")
            }
            var entries: [RawEntry] = []
            var p = 5
            while p + 26 <= (isOld ? 1227 : 2007), bytes[p] != 0 {
                let field = bytes[p..<(p + 10)]
                let name = Array(field.map { isOld ? $0 & 0x7F : $0 }.prefix { $0 > 0x20 })
                func le32(_ o: Int) -> UInt32 { UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24 }
                let a = UInt32(bytes[p + 22]) | UInt32(bytes[p + 23]) << 8 | UInt32(bytes[p + 24]) << 16
                var e = RawEntry(name: name, load: le32(p + 10), exec: le32(p + 14), length: le32(p + 18), address: a, attributes: bytes[p + 25])
                if isOld {
                    e.attributes = (0..<4).reduce(0) { $0 | (bytes[p + $1] >> 7) << UInt8($1) }
                    e.sequence = bytes[p + 25]
                }
                entries.append(e)
                p += 26
            }
            self.entries = entries
        }

        static func empty(address: UInt32, size: Int, parent: UInt32, name: [UInt8], signature: String, path: String) -> Directory {
            var b = [UInt8](repeating: 0, count: size)
            for (i, c) in signature.utf8.enumerated() { b[1 + i] = c; b[size - 5 + i] = c }
            let parentOffset = size == oldSize ? 1238 : 2010
            for i in 0..<3 { b[parentOffset + i] = UInt8((parent >> (8 * UInt32(i))) & 0xFF) }
            b[size - 1] = ADFSFormatter.directoryCheckByte(b)
            let d = try! Directory(address: address, bytes: b, path: path)
            d.setName(name)
            return d
        }

        /// The name in the tail, and the title too (as *CDir sets it).
        func setName(_ name: [UInt8]) {
            for (o, n) in [(titleOffset, 19), (nameOffset, 10)] {
                for i in 0..<n { bytes[o + i] = 0 }
                let part = Array(name.prefix(n))
                for (i, c) in part.enumerated() { bytes[o + i] = c }
                if part.count < n { bytes[o + part.count] = 0x0D }
            }
            changed = true
        }

        /// What an entry's last change gets: the sequence number the
        /// directory will have when next written.
        var nextSequence: UInt8 { bytes[0] &+ 1 }

        /// What an entry can hold here: an old directory keeps only R, W, L and D.
        func stored(_ e: RawEntry) -> RawEntry {
            guard isOld else { return e }
            var e = e
            e.attributes &= 0x0F
            e.sequence = nextSequence
            return e
        }

        func replace(at i: Int, with e: RawEntry) {
            entries[i] = stored(e)
            changed = true
        }

        func index(of name: [UInt8]) -> Int? {
            let k = ADFSVolume.key(name)
            return entries.firstIndex { ADFSVolume.key($0.name) == k }
        }

        func insert(_ e: RawEntry) {
            let e = stored(e)
            let k = ADFSVolume.key(e.name)
            entries.removeAll { ADFSVolume.key($0.name) == k }
            let at = entries.firstIndex { k.lexicographicallyPrecedes(ADFSVolume.key($0.name)) } ?? entries.count
            entries.insert(e, at: at)
            changed = true
        }

        func encoded() -> [UInt8] {
            var b = bytes
            for i in 5..<tail { b[i] = 0 }
            var p = 5
            for e in entries {
                for (i, c) in e.name.prefix(10).enumerated() { b[p + i] = c }
                if e.name.count < 10 { b[p + e.name.count] = 0x0D }
                if isOld {
                    for k in 0..<4 where e.attributes >> UInt8(k) & 1 != 0 { b[p + k] |= 0x80 }
                }
                for i in 0..<4 {
                    b[p + 10 + i] = UInt8((e.load >> (8 * i)) & 0xFF)
                    b[p + 14 + i] = UInt8((e.exec >> (8 * i)) & 0xFF)
                    b[p + 18 + i] = UInt8((e.length >> (8 * i)) & 0xFF)
                }
                b[p + 22] = UInt8(e.address & 0xFF); b[p + 23] = UInt8((e.address >> 8) & 0xFF); b[p + 24] = UInt8((e.address >> 16) & 0xFF)
                b[p + 25] = isOld ? e.sequence : e.attributes
                p += 26
            }
            b[0] &+= 1
            b[size - 6] = b[0]
            b[size - 1] = ADFSFormatter.directoryCheckByte(b)
            bytes = b
            return b
        }
    }

    func directory(at address: UInt32, path: String) throws -> Directory {
        if let d = directories[address] { return d }
        let d = try Directory(address: address, bytes: read(address, length: map.directorySize), path: path)
        directories[address] = d
        return d
    }

    func resolve(_ path: [String]) throws -> Directory {
        var d = try directory(at: map.rootAddress, path: "$")
        for name in path {
            guard let i = d.index(of: Self.latin1(name)), d.entries[i].isDirectory else { throw ADFSError.notFound(name) }
            d = try directory(at: d.entries[i].address, path: d.path + "." + name)
        }
        return d
    }
}

/// How a disc's space is mapped: where objects are, and what's free.
protocol ADFSMapping: AnyObject {
    var formatName: String { get }
    var rootAddress: UInt32 { get }
    var discSize: Int { get }
    var freeBytes: Int { get }
    var freeAreas: [(start: Int, end: Int)] { get }
    var directorySignature: String { get }
    /// 2048, or 1280 for the old directories of L, M and S format.
    var directorySize: Int { get }
    var discName: [UInt8] { get set }
    var bootOption: UInt8 { get set }
    /// Problems with the map itself, for `check`.
    var problems: [String] { get }
    func changeDiscID()
    /// The disc's byte ranges holding `length` bytes of the object at `address`.
    func extents(_ address: UInt32, length: Int) throws -> [(start: Int, count: Int)]
    /// Room for `length` bytes; returns the new object's address.
    func allocate(_ length: Int) throws -> UInt32
    /// Frees an object's space, unless `stillUsed` says something else shares it.
    func release(_ address: UInt32, length: Int, stillUsed: () throws -> Bool) throws
    func flush(to store: ADFSStore) throws
}
