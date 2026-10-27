import Foundation

/// The old free space map, of D format floppies and old-map hard discs:
/// up to 82 free areas, three-byte start addresses from &000 and lengths
/// from &100, in 256-byte units, with the list's end (three bytes an entry)
/// at &1FE. The disc's size is at &FC, its name interleaved at &F7 and
/// &1F6, its ID at &1FB and its boot option at &1FD; each half ends with a
/// check byte. The root directory is at &400. Objects are contiguous, and
/// start on sector boundaries.
final class ADFSOldMap: ADFSMapping {
    static let maxFreeEntries = 82
    var map: [UInt8]
    var free: [(start: Int, length: Int)] // 256-byte units, by address
    let unit: Int // the sector size in 256-byte units
    let discSize: Int
    let formatName: String
    let rootAddress: UInt32 = 0x400 >> 8
    let directorySignature = "Hugo"
    var changed = false

    init?(store: ADFSStore) throws {
        guard store.size >= 0xC00 else { return nil }
        let map = try store.read(0, 0x200)
        let root = try store.read(0x400, 8)
        let lRoot = try store.read(0x200, 8)
        guard Array(root[1...4]) == Array("Hugo".utf8) else {
            if Array(lRoot[1...4]) == Array("Hugo".utf8) { throw ADFSError.unsupported("ADFS L, M and S format discs") }
            return nil
        }
        guard ADFSFormatter.checksum(map, 0, 0x100) == map[0xFF], ADFSFormatter.checksum(map, 0x100, 0x100) == map[0x1FF] else {
            throw ADFSError.damaged("the free space map's check bytes are wrong")
        }
        let end = Int(map[0x1FE])
        guard end % 3 == 0, end / 3 <= Self.maxFreeEntries else { throw ADFSError.damaged("the free space map's length is wrong") }
        func get24(_ o: Int) -> Int { Int(map[o]) | Int(map[o + 1]) << 8 | Int(map[o + 2]) << 16 }
        let sectors = get24(0x0FC)
        discSize = sectors > 0 ? min(sectors * 256, store.size) : store.size
        var free: [(start: Int, length: Int)] = []
        for i in 0..<(end / 3) {
            let s = get24(3 * i), l = get24(0x100 + 3 * i)
            guard l > 0, (s + l) * 256 <= discSize else { throw ADFSError.damaged("a free area lies beyond the disc") }
            free.append((s, l))
        }
        self.map = map
        self.free = free.sorted { $0.start < $1.start }
        unit = max(1, store.sectorSize / 256)
        formatName = store.size <= 1 << 20 ? "ADFS D" : "Old-map hard disc"
    }

    var freeBytes: Int { free.reduce(0) { $0 + $1.length } * 256 }
    var freeAreas: [(start: Int, end: Int)] { free.map { ($0.start * 256, ($0.start + $0.length) * 256) } }
    var problems: [String] { [] }

    var discName: [UInt8] {
        get { (0..<5).flatMap { [map[0xF7 + $0], map[0x1F6 + $0]] } }
        set {
            let padded = Array(newValue.prefix(10)) + [UInt8](repeating: 0x20, count: max(0, 10 - newValue.count))
            for k in 0..<5 { map[0xF7 + k] = padded[2 * k]; map[0x1F6 + k] = padded[2 * k + 1] }
            changed = true
        }
    }

    var bootOption: UInt8 {
        get { map[0x1FD] }
        set { map[0x1FD] = newValue; changed = true }
    }

    func changeDiscID() {
        let id = UInt16.random(in: 1...0xFFFE)
        map[0x1FB] = UInt8(id & 0xFF); map[0x1FC] = UInt8(id >> 8)
        changed = true
    }

    func extents(_ address: UInt32, length: Int) throws -> [(start: Int, count: Int)] {
        let start = Int(address) * 256
        guard start + length <= discSize else { throw ADFSError.damaged("an object lies beyond the disc") }
        return [(start, length)]
    }

    func roundUp(_ n: Int) -> Int { let u = unit * 256; return (max(n, 1) + u - 1) / u * u }

    /// First fit, on a sector boundary.
    func allocate(_ length: Int) throws -> UInt32 {
        let need = roundUp(length) / 256
        for (i, f) in free.enumerated() {
            let start = (f.start + unit - 1) / unit * unit
            guard start + need <= f.start + f.length else { continue }
            var pieces: [(start: Int, length: Int)] = []
            if start > f.start { pieces.append((f.start, start - f.start)) }
            if start + need < f.start + f.length { pieces.append((start + need, f.start + f.length - start - need)) }
            free.replaceSubrange(i...i, with: pieces)
            guard free.count <= Self.maxFreeEntries else { throw ADFSError.mapFull }
            changed = true
            return UInt32(start)
        }
        throw ADFSError.discFull(needed: need * 256, free: freeBytes)
    }

    func release(_ address: UInt32, length: Int, stillUsed: () throws -> Bool) throws {
        guard length > 0 else { return }
        free.append((Int(address), roundUp(length) / 256))
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
        guard free.count <= Self.maxFreeEntries else { throw ADFSError.mapFull }
        changed = true
    }

    func flush(to store: ADFSStore) throws {
        guard changed else { return }
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
        try store.write(0, m)
        map = m
        changed = false
    }
}

/// The new map, of E and F format floppies and new-map hard discs (from
/// the PRM's FileCore chapter). The disc record (in the boot block at &DC0
/// when there is one, and always in zone 0 after its header) gives the
/// shape. The map is a sector per zone, and a copy straight after; each
/// zone has a four-byte header (a check byte, the free link, a cross
/// check), and zone 0 the disc record's 60 bytes after it. Each map bit
/// after those stands for 2^log2bpmb bytes of disc.
///
/// The bits are runs: a fragment is `idlen` bits of id, then zeros, ended
/// by a set bit. An object is the fragments with its id, in order from the
/// zone its id belongs to (ids are shared out among the zones), and is
/// addressed by its id above bits 0-7, which hold one more than a sector
/// offset when small objects share a fragment. Free runs are chained from
/// the free link at bit 8 of the zone, each holding the distance to the
/// next instead of an id. The map's own fragment and the root directory
/// have id 2.
final class ADFSNewMap: ADFSMapping {
    struct Run {
        var start: Int
        var length: Int
        /// nil for free space.
        var id: Int?
    }

    let secSize: Int, idlen: Int, log2bpmb: Int, nzones: Int, zoneSpare: Int, log2share: Int
    let rootAddress: UInt32
    let discSize: Int
    let mapAddress: Int
    let zoneBits: Int
    let formatName: String
    let directorySignature = "Nick"
    var zones: [[UInt8]]
    var runs: [[Run]]
    var dirty: Set<Int> = []
    /// The boot block (hard discs and F format), to keep its disc record in step.
    var boot: [UInt8]?
    var bootChanged = false
    private(set) var problems: [String] = []

    var idsPerZone: Int { zoneBits / (idlen + 1) }
    /// Map bits to a sector, so objects start and end on sector boundaries.
    var sectorBits: Int { max(1, secSize >> log2bpmb) }

    init?(store: ADFSStore) throws {
        // A boot block whose disc record matches the one in the map it
        // points to; or, without one (E format), the map at the start.
        var found: (record: [UInt8], mapAddress: Int, boot: [UInt8]?)?
        if store.size >= 0xE00 {
            let b = try store.read(0xC00, 0x200)
            if ADFSFormatter.checksum(b, 0, 0x200) == b[0x1FF], let at = Self.mapAddress(Array(b[0x1C0..<0x1FC])), at > 0,
               at + (1 << Int(b[0x1C0])) <= store.size {
                let z = try store.read(at, 64)
                if Array(z[4..<16]) == Array(b[0x1C0..<0x1CC]) { found = (Array(b[0x1C0..<0x1FC]), at, b) }
            }
        }
        if found == nil, store.size >= 1024 {
            let z = try store.read(0, 64)
            if Self.mapAddress(Array(z[4..<64])) == 0 { found = (Array(z[4..<64]), 0, nil) }
        }
        guard let (r, at, boot) = found else { return nil }
        func le32(_ o: Int) -> Int { Int(r[o]) | Int(r[o + 1]) << 8 | Int(r[o + 2]) << 16 | Int(r[o + 3]) << 24 }
        secSize = 1 << Int(r[0])
        idlen = Int(r[4])
        log2bpmb = Int(r[5])
        nzones = Int(r[9]) + Int(r[42]) << 8
        zoneSpare = Int(r[10]) | Int(r[11]) << 8
        rootAddress = UInt32(le32(12))
        discSize = min(le32(16), store.size)
        log2share = Int(r[40])
        mapAddress = at
        zoneBits = secSize * 8 - zoneSpare
        self.boot = boot
        guard r[41] == 0, le32(36) == 0 else { throw ADFSError.unsupported("Discs over 512 MB") }
        guard at + 2 * nzones * secSize <= store.size else { throw ADFSError.damaged("the map lies beyond the disc") }
        switch (nzones, discSize) {
        case (1, ...819_200): formatName = "ADFS E"
        case (_, ...1_638_400): formatName = "ADFS F"
        default: formatName = "New-map hard disc"
        }
        zones = []
        runs = []
        var crossCheck: UInt8 = 0
        for z in 0..<nzones {
            let bytes = try store.read(at + z * secSize, secSize)
            guard Self.zoneCheck(bytes) == bytes[0] else { throw ADFSError.damaged("the map's check bytes are wrong (zone \(z))") }
            crossCheck ^= bytes[3]
            zones.append(bytes)
        }
        guard crossCheck == 0xFF else { throw ADFSError.damaged("the map's zones don't agree with each other") }
        for z in 0..<nzones { runs.append(try parse(z)) }
    }

    /// Where the map is, if `r` is a sensible new-map disc record.
    static func mapAddress(_ r: [UInt8]) -> Int? {
        let log2sec = Int(r[0]), idlen = Int(r[4]), log2bpmb = Int(r[5])
        let nzones = Int(r[9]) + Int(r[42]) << 8, spare = Int(r[10]) | Int(r[11]) << 8
        guard (8...12).contains(log2sec), (8...21).contains(idlen), log2bpmb <= 16, nzones >= 1, nzones <= 256,
              spare < (8 << log2sec) - 512 else { return nil }
        let zoneBits = (8 << log2sec) - spare
        return ((nzones >> 1) * zoneBits - (nzones > 1 ? 480 : 0)) << log2bpmb
    }

    /// FileCore's zone check byte: the zone summed a word at a time from
    /// the end with carries between the bytes, the header's own bytes
    /// (but the check itself) last, folded to a byte.
    static func zoneCheck(_ m: [UInt8]) -> UInt8 {
        var v0 = 0, v1 = 0, v2 = 0, v3 = 0
        var i = m.count - 4
        while i > 0 {
            v0 += Int(m[i]) + (v3 >> 8); v3 &= 0xFF
            v1 += Int(m[i + 1]) + (v0 >> 8); v0 &= 0xFF
            v2 += Int(m[i + 2]) + (v1 >> 8); v1 &= 0xFF
            v3 += Int(m[i + 3]) + (v2 >> 8); v2 &= 0xFF
            i -= 4
        }
        v0 += v3 >> 8
        v1 += Int(m[1]) + (v0 >> 8)
        v2 += Int(m[2]) + (v1 >> 8)
        v3 += Int(m[3]) + (v2 >> 8)
        return UInt8((v0 ^ v1 ^ v2 ^ v3) & 0xFF)
    }

    // MARK: Bits

    func firstBit(_ z: Int) -> Int { z == 0 ? 32 + 480 : 32 }
    func endBit(_ z: Int) -> Int { 32 + zoneBits }
    /// The map block (2^log2bpmb bytes of disc) of zone `z`'s first bit.
    func firstBlock(_ z: Int) -> Int { z == 0 ? 0 : z * zoneBits - 480 }
    func address(zone z: Int, bit b: Int) -> Int { (b - firstBit(z) + firstBlock(z)) << log2bpmb }

    func bit(_ z: Int, _ i: Int) -> Bool { zones[z][i >> 3] >> UInt8(i & 7) & 1 != 0 }

    func bits(_ z: Int, _ i: Int, _ n: Int) -> Int {
        var v = 0
        for k in 0..<n where bit(z, i + k) { v |= 1 << k }
        return v
    }

    func setBit(_ z: Int, _ i: Int, _ on: Bool) {
        if on { zones[z][i >> 3] |= 1 << UInt8(i & 7) } else { zones[z][i >> 3] &= ~(1 << UInt8(i & 7)) }
    }

    func parse(_ z: Int) throws -> [Run] {
        var free: Set<Int> = []
        var link = (Int(zones[z][1]) | Int(zones[z][2]) << 8) & 0x7FFF
        var at = 8
        while link != 0 {
            at += link
            guard at >= firstBit(z), at < endBit(z), free.insert(at).inserted else { throw ADFSError.damaged("the map's free chain is broken (zone \(z))") }
            link = bits(z, at, idlen)
        }
        var out: [Run] = []
        var b = firstBit(z)
        while b < endBit(z) {
            let id = bits(z, b, idlen)
            var e = b + idlen
            while e < endBit(z) && !bit(z, e) { e += 1 }
            guard e < endBit(z) else { throw ADFSError.damaged("a fragment runs past the end of zone \(z)") }
            out.append(Run(start: b, length: e + 1 - b, id: free.contains(b) ? nil : id))
            b = e + 1
        }
        let starts = Set(out.map(\.start))
        guard free.isSubset(of: starts) else { throw ADFSError.damaged("the map's free chain is broken (zone \(z))") }
        return out
    }

    // MARK: The disc record

    func record(_ o: Int) -> UInt8 { zones[0][4 + o] }

    func setRecord(_ o: Int, _ bytes: [UInt8]) {
        for (i, v) in bytes.enumerated() {
            zones[0][4 + o + i] = v
            boot?[0x1C0 + o + i] = v
        }
        dirty.insert(0)
        bootChanged = boot != nil
    }

    var discName: [UInt8] {
        get { (22..<32).map(record) }
        set { setRecord(22, Array(newValue.prefix(10)) + [UInt8](repeating: 0x20, count: max(0, 10 - newValue.count))) }
    }

    var bootOption: UInt8 {
        get { record(7) }
        set { setRecord(7, [newValue]) }
    }

    func changeDiscID() {
        let id = UInt16.random(in: 1...0xFFFE)
        setRecord(20, [UInt8(id & 0xFF), UInt8(id >> 8)])
    }

    // MARK: Space

    var freeBytes: Int { runs.joined().filter { $0.id == nil }.reduce(0) { $0 + $1.length } << log2bpmb }

    var freeAreas: [(start: Int, end: Int)] {
        var out: [(start: Int, end: Int)] = []
        for z in 0..<nzones {
            for r in runs[z] where r.id == nil {
                let a = address(zone: z, bit: r.start)
                out.append((a, a + (r.length << log2bpmb)))
            }
        }
        return out
    }

    /// The zone an id belongs to; the map and root's fragment starts in the
    /// middle one, with the map.
    func zone(of id: Int) -> Int { id == 2 ? nzones / 2 : min(id / max(1, idsPerZone), nzones - 1) }

    /// The zones in the order an object with this id is looked for.
    func zoneOrder(from z: Int) -> [Int] { (0..<nzones).map { (z + $0) % nzones } }

    func extents(_ object: UInt32, length: Int) throws -> [(start: Int, count: Int)] {
        let id = Int(object >> 8), offset = Int(object & 0xFF)
        var skip = offset > 0 ? (offset - 1) * (secSize << log2share) : 0
        var out: [(start: Int, count: Int)] = []
        var remaining = length
        guard remaining > 0 else { return [] }
        for z in zoneOrder(from: zone(of: id)) {
            for r in runs[z] where r.id == id {
                let start = address(zone: z, bit: r.start), size = r.length << log2bpmb
                if skip >= size { skip -= size; continue }
                let take = min(size - skip, remaining)
                out.append((start + skip, take))
                skip = 0
                remaining -= take
                if remaining == 0 { return out }
            }
        }
        throw ADFSError.damaged("an object's fragments are missing from the map (id \(id))")
    }

    /// Ids in use anywhere on the disc.
    var usedIDs: Set<Int> { Set(runs.joined().compactMap(\.id)) }

    /// An unused id belonging to zone `z` (0 to 2 are FileCore's own).
    func freeID(in z: Int, used: Set<Int>) -> Int? {
        let lo = max(3, z * idsPerZone), hi = min((z + 1) * idsPerZone, 1 << idlen) - 1
        guard lo <= hi else { return nil }
        return (lo...hi).first { !used.contains($0) }
    }

    /// Bits before a run's first usable bit: none if it starts on a sector,
    /// else enough to reach one and leave a free run of its own.
    func front(_ z: Int, _ r: Run) -> Int {
        let block = (r.start - firstBit(z) + firstBlock(z))
        var k = (sectorBits - block % sectorBits) % sectorBits
        while k > 0 && k < idlen + 1 { k += sectorBits }
        return k
    }

    func roundUp(_ bits: Int) -> Int { (bits + sectorBits - 1) / sectorBits * sectorBits }

    func allocate(_ length: Int) throws -> UInt32 {
        let need = roundUp(max(idlen + 1, (length + (1 << log2bpmb) - 1) >> log2bpmb))
        let used = usedIDs
        // One fragment, first fit.
        for z in 0..<nzones {
            for (i, r) in runs[z].enumerated() where r.id == nil {
                let f = front(z, r)
                guard f + need <= r.length, let id = freeID(in: z, used: used) else { continue }
                take([(z, i, f, need)], id: id)
                return UInt32(id << 8)
            }
        }
        // Several, all with one id, in the order they'll be looked for.
        guard let first = (0..<nzones).first(where: { z in runs[z].contains { $0.id == nil && $0.length - front(z, $0) >= idlen + 1 } }),
              let id = freeID(in: first, used: used) else {
            throw ADFSError.discFull(needed: need << log2bpmb, free: freeBytes)
        }
        var picks: [(zone: Int, index: Int, front: Int, bits: Int)] = []
        var remaining = need
        outer: for z in zoneOrder(from: first) {
            for (i, r) in runs[z].enumerated() where r.id == nil {
                let f = front(z, r), avail = r.length - f
                guard avail >= idlen + 1 else { continue }
                var bits = min(avail, roundUp(max(remaining, idlen + 1)))
                if avail - bits < idlen + 1 { bits = avail }
                picks.append((z, i, f, bits))
                remaining -= bits
                if remaining <= 0 { break outer }
            }
        }
        guard remaining <= 0 else { throw ADFSError.discFull(needed: need << log2bpmb, free: freeBytes) }
        take(picks, id: id)
        return UInt32(id << 8)
    }

    /// Marks the picked parts of free runs as fragments of `id`.
    func take(_ picks: [(zone: Int, index: Int, front: Int, bits: Int)], id: Int) {
        // From the last, so earlier indices stay put.
        for p in picks.sorted(by: { ($0.zone, $0.index) > ($1.zone, $1.index) }) {
            let r = runs[p.zone][p.index]
            var pieces: [Run] = []
            if p.front > 0 { pieces.append(Run(start: r.start, length: p.front, id: nil)) }
            var bits = p.bits
            let rest = r.length - p.front - bits
            if rest > 0 && rest < idlen + 1 { bits += rest }
            pieces.append(Run(start: r.start + p.front, length: bits, id: id))
            if r.length - p.front - bits > 0 { pieces.append(Run(start: r.start + p.front + bits, length: r.length - p.front - bits, id: nil)) }
            runs[p.zone].replaceSubrange(p.index...p.index, with: pieces)
            dirty.insert(p.zone)
        }
    }

    func release(_ address: UInt32, length: Int, stillUsed: () throws -> Bool) throws {
        let id = Int(address >> 8)
        // Id 2 is the map's own fragment, which small objects in the root can share.
        guard id > 2, try !stillUsed() else { return }
        for z in 0..<nzones where runs[z].contains(where: { $0.id == id }) {
            var merged: [Run] = []
            for var r in runs[z] {
                if r.id == id { r.id = nil }
                if r.id == nil, let last = merged.last, last.id == nil, last.start + last.length == r.start {
                    merged[merged.count - 1].length += r.length
                } else {
                    merged.append(r)
                }
            }
            runs[z] = merged
            dirty.insert(z)
        }
    }

    func encode(_ z: Int) throws {
        let rs = runs[z]
        let free = rs.filter { $0.id == nil }.map(\.start)
        for r in rs {
            let value: Int
            if r.id == nil {
                let k = free.firstIndex(of: r.start)!
                value = k + 1 < free.count ? free[k + 1] - r.start : 0
            } else {
                value = r.id!
            }
            guard value < 1 << idlen else { throw ADFSError.mapFull }
            for i in 0..<r.length { setBit(z, r.start + i, false) }
            for i in 0..<idlen where value >> i & 1 != 0 { setBit(z, r.start + i, true) }
            setBit(z, r.start + r.length - 1, true)
        }
        let link = free.first.map { $0 - 8 } ?? 0
        let top = Int(zones[z][2]) & 0x80
        zones[z][1] = UInt8(link & 0xFF)
        zones[z][2] = UInt8((link >> 8) & 0x7F) | UInt8(top)
        zones[z][0] = Self.zoneCheck(zones[z])
    }

    func flush(to store: ADFSStore) throws {
        for z in dirty.sorted() {
            try encode(z)
            try store.write(mapAddress + z * secSize, zones[z])
            try store.write(mapAddress + (nzones + z) * secSize, zones[z])
        }
        dirty.removeAll()
        if bootChanged, var b = boot {
            b[0x1FF] = ADFSFormatter.checksum(b, 0, 0x200)
            try store.write(0xC00, b)
            boot = b
            bootChanged = false
        }
    }
}
