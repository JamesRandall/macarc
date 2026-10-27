import Foundation

/// Where an ADFS filing system lives: bytes by disc address, as FileCore
/// sees them (a floppy's sectors side by side for each track, a hard disc's
/// from its first sector).
public protocol ADFSStore: AnyObject {
    var size: Int { get }
    /// Objects start on sector boundaries and are read and written in whole sectors.
    var sectorSize: Int { get }
    func read(_ address: Int, _ count: Int) throws -> [UInt8]
    func write(_ address: Int, _ bytes: [UInt8]) throws
}

/// A disc held in memory, such as a whole floppy image.
public final class ADFSMemoryStore: ADFSStore {
    public private(set) var bytes: [UInt8]
    public let sectorSize: Int
    public var size: Int { bytes.count }

    public init(bytes: [UInt8], sectorSize: Int = 1024) {
        self.bytes = bytes
        self.sectorSize = sectorSize
    }

    public func read(_ address: Int, _ count: Int) throws -> [UInt8] {
        guard address >= 0, count >= 0, address + count <= bytes.count else { throw ADFSError.damaged("an address lies beyond the disc") }
        return Array(bytes[address..<(address + count)])
    }

    public func write(_ address: Int, _ data: [UInt8]) throws {
        guard address >= 0, address + data.count <= bytes.count else { throw ADFSError.damaged("an address lies beyond the disc") }
        bytes.replaceSubrange(address..<(address + data.count), with: data)
    }
}

/// A floppy in a drive, through its sectors: writes go into the image's
/// changes, as the machine's own do, so they're kept or discarded with them.
public final class ADFSFloppyStore: ADFSStore {
    public let image: FloppyImage
    let g: DiscGeometry
    public var sectorSize: Int { g.sectorSize }
    public var size: Int { g.sides * g.tracks * g.sectorsPerTrack * g.sectorSize }

    public init(image: FloppyImage) {
        self.image = image
        g = image.geometry
    }

    /// Logical sector `n`'s place. D, E and F formats alternate sides track
    /// by track; L format (256-byte sectors) has all of side 0, then side 1,
    /// as RISC OS's *Format and *Save lay it out.
    func place(_ n: Int) -> (side: Int, track: Int, id: Int) {
        let s = n % g.sectorsPerTrack, t = n / g.sectorsPerTrack
        if g.sectorSize == 256 { return (t / g.tracks, t % g.tracks, g.firstSectorID + s) }
        return (t % g.sides, t / g.sides, g.firstSectorID + s)
    }

    func sector(_ n: Int) throws -> [UInt8] {
        let p = place(n)
        guard let data = image.readSector(side: p.side, track: p.track, sectorID: p.id), data.count == g.sectorSize else {
            throw ADFSError.unreadable("track \(p.track), side \(p.side), sector \(p.id) isn't a standard sector (the disc may be copy protected)")
        }
        return data
    }

    public func read(_ address: Int, _ count: Int) throws -> [UInt8] {
        guard address >= 0, count >= 0, address + count <= size else { throw ADFSError.damaged("an address lies beyond the disc") }
        var out: [UInt8] = []
        out.reserveCapacity(count)
        var a = address
        while out.count < count {
            let n = a / g.sectorSize, o = a % g.sectorSize
            let take = min(g.sectorSize - o, count - out.count)
            out += try sector(n)[o..<(o + take)]
            a += take
        }
        return out
    }

    public func write(_ address: Int, _ data: [UInt8]) throws {
        guard address >= 0, address + data.count <= size else { throw ADFSError.damaged("an address lies beyond the disc") }
        guard !image.writeProtected else { throw ADFSError.writeProtected }
        var a = address, i = 0
        while i < data.count {
            let n = a / g.sectorSize, o = a % g.sectorSize
            let take = min(g.sectorSize - o, data.count - i)
            var s = try sector(n)
            s.replaceSubrange(o..<(o + take), with: data[i..<(i + take)])
            let p = place(n)
            guard image.writeSector(side: p.side, track: p.track, sectorID: p.id, data: s) else { throw ADFSError.writeProtected }
            a += take
            i += take
        }
    }
}

/// A hard disc image file. Its own descriptor: the machine's is left alone.
public final class ADFSFileStore: ADFSStore {
    let fd: Int32
    public let size: Int
    public let sectorSize: Int

    public init(path: String, sectorSize: Int, writable: Bool) throws {
        fd = Darwin.open(path, writable ? O_RDWR : O_RDONLY)
        guard fd >= 0 else { throw HardDiscError.cannotOpen(path) }
        var st = stat()
        fstat(fd, &st)
        size = Int(st.st_size)
        self.sectorSize = sectorSize
    }

    deinit { close(fd) }

    public func read(_ address: Int, _ count: Int) throws -> [UInt8] {
        guard address >= 0, count >= 0, address + count <= size else { throw ADFSError.damaged("an address lies beyond the disc") }
        var b = [UInt8](repeating: 0, count: count)
        guard pread(fd, &b, count, off_t(address)) == count else { throw ADFSError.unreadable(String(cString: strerror(errno))) }
        return b
    }

    public func write(_ address: Int, _ bytes: [UInt8]) throws {
        guard address >= 0, address + bytes.count <= size else { throw ADFSError.damaged("an address lies beyond the disc") }
        guard pwrite(fd, bytes, bytes.count, off_t(address)) == bytes.count else { throw ADFSError.unreadable(String(cString: strerror(errno))) }
    }

    public func synchronize() { fsync(fd) }
}

/// Holds a change's writes back until `commit`, so one that fails part way
/// leaves the disc as it was, and records what each changed block held
/// before (for undo).
public final class ADFSBufferedStore: ADFSStore {
    public let base: ADFSStore
    static let block = 256
    private var pending: [Int: [UInt8]] = [:]
    public var size: Int { base.size }
    public var sectorSize: Int { base.sectorSize }

    public init(_ base: ADFSStore) { self.base = base }

    public func read(_ address: Int, _ count: Int) throws -> [UInt8] {
        var out = try base.read(address, count)
        guard !pending.isEmpty, count > 0 else { return out }
        let b = Self.block
        for n in (address / b)...((address + count - 1) / b) {
            guard let p = pending[n] else { continue }
            let from = max(address, n * b), to = min(address + count, n * b + b)
            out.replaceSubrange((from - address)..<(to - address), with: p[(from - n * b)..<(to - n * b)])
        }
        return out
    }

    public func write(_ address: Int, _ data: [UInt8]) throws {
        guard address >= 0, address + data.count <= size else { throw ADFSError.damaged("an address lies beyond the disc") }
        guard !data.isEmpty else { return }
        let b = Self.block
        let first = address / b, last = (address + data.count - 1) / b
        // Whole blocks are taken as they come; partial ones are read first.
        for n in first...last {
            let from = max(address, n * b), to = min(address + data.count, n * b + b)
            var block: [UInt8]
            if to - from == b {
                block = Array(data[(from - address)..<(to - address)])
            } else {
                block = try pending[n] ?? base.read(n * b, min(b, size - n * b))
                block.replaceSubrange((from - n * b)..<(to - n * b), with: data[(from - address)..<(to - address)])
            }
            pending[n] = block
        }
    }

    /// Writes the held changes to the store underneath.
    @discardableResult
    public func commit() throws -> ADFSChange {
        var blocks: [ADFSChange.Block] = []
        let b = Self.block
        for n in pending.keys.sorted() {
            let after = pending[n]!
            let before = try base.read(n * b, after.count)
            if before != after { blocks.append(.init(address: n * b, before: before, after: after)) }
        }
        // Runs of neighbouring blocks go in one write.
        var i = 0
        while i < blocks.count {
            var j = i, bytes = blocks[i].after
            while j + 1 < blocks.count, blocks[j + 1].address == blocks[j].address + blocks[j].after.count {
                j += 1
                bytes += blocks[j].after
            }
            try base.write(blocks[i].address, bytes)
            i = j + 1
        }
        pending.removeAll()
        return ADFSChange(blocks: blocks)
    }
}

/// What a change to a disc replaced, block by block, so it can be undone.
public struct ADFSChange: Sendable {
    public struct Block: Sendable {
        public var address: Int
        public var before: [UInt8]
        public var after: [UInt8]
    }
    public var blocks: [Block]
    public var isEmpty: Bool { blocks.isEmpty }

    /// Puts back what the change replaced, provided nothing has written
    /// over it since, with a new disc ID (as any change gets). Returns the
    /// change that undoes this one.
    public func revert(on store: ADFSStore) throws -> ADFSChange {
        for b in blocks where try store.read(b.address, b.after.count) != b.after { throw ADFSError.changedSince }
        let buffered = ADFSBufferedStore(store)
        for b in blocks { try buffered.write(b.address, b.before) }
        let v = try ADFSVolume(store: buffered)
        v.changeDiscID()
        try v.flush()
        return try buffered.commit()
    }
}
