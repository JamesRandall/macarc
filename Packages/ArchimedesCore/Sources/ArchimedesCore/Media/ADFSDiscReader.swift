import Foundation

/// Reads the files off an ADFS floppy image (ADF, or JFD or HFE), D format (old map, "Hugo"
/// directories, disc addresses in 256-byte units) or E format (new map,
/// "Nick" directories, fragment addresses), for copying onto a hard disc.
///
/// The E format's map (from the PRM's FileCore chapter): one zone per
/// sector, each starting with a four-byte header; zone 0 also holds the
/// disc record in the 60 bytes after it, and its map bits start after that.
/// Each map bit stands for 2^log2bpmb bytes of disc. A fragment is `idlen`
/// bits of fragment id, then zero bits, ended by a set bit. A directory
/// entry's indirect address is the fragment id above bits 0-7, and in bits
/// 0-7 one more than the sector offset into the fragment (0 for none).
/// Free fragments are chained from the zone header's free link, each id
/// field holding the distance to the next.
public enum ADFSDiscReader {
    public enum ReadError: Error, CustomStringConvertible {
        case notADFS
        case badAddress(String)

        public var description: String {
            switch self {
            case .notADFS: return "not an ADFS D or E format disc"
            case .badAddress(let p): return "\(p) is not where the disc's map says"
            }
        }
    }

    /// The disc's files, as items for `ADFSHardDiscBuilder` and
    /// `ADFSHardDiscWriter`, and its directories (which may be empty).
    public static func read(bytes raw: [UInt8]) throws -> (items: [ADFSHardDiscBuilder.Item], directories: [[String]]) {
        // JFD and HFE images: their standard sectors, in ADF order.
        var d = raw
        switch MediaDetector.detect(raw).format {
        case "JFD": d = Array(try JFDImage.load(raw, sourcePath: nil, writeProtected: true).mergedImage().prefix(819_200))
        case "HFE": d = Array(try HFEImage.load(raw, sourcePath: nil, writeProtected: true).mergedImage().prefix(819_200))
        default: break
        }
        var items: [ADFSHardDiscBuilder.Item] = [], dirs: [[String]] = []
        if d.count >= 0x400 + 2048, Array(d[0x401...0x404]) == Array("Hugo".utf8) {
            try walk(d, at: 0x400, length: 2048, path: [], depth: 0, items: &items, dirs: &dirs) { ind, length, _ in
                let start = Int(ind) * 256
                guard start + length <= d.count else { return nil }
                return Array(d[start..<(start + length)])
            }
        } else if let map = NewMap(d) {
            let root = map.root
            guard let rootBytes = map.read(root, length: 2048), Array(rootBytes[1...4]) == Array("Nick".utf8) else { throw ReadError.notADFS }
            try walk(d, at: nil, length: 2048, path: [], depth: 0, items: &items, dirs: &dirs, rootBytes: rootBytes) { ind, length, _ in
                map.read(ind, length: length)
            }
        } else {
            throw ReadError.notADFS
        }
        return (items, dirs)
    }

    public static func read(path: String) throws -> (items: [ADFSHardDiscBuilder.Item], directories: [[String]]) {
        guard let d = FileManager.default.contents(atPath: path) else { throw MediaError.unreadable(path) }
        return try read(bytes: [UInt8](d))
    }

    private static func walk(_ d: [UInt8], at start: Int?, length: Int, path: [String], depth: Int,
                             items: inout [ADFSHardDiscBuilder.Item], dirs: inout [[String]], rootBytes: [UInt8]? = nil,
                             fetch: (UInt32, Int, [String]) -> [UInt8]?) throws {
        let dir: [UInt8]
        if let rootBytes { dir = rootBytes } else if let start { dir = Array(d[start..<(start + length)]) } else { return }
        var p = 5
        for _ in 0..<77 {
            guard p + 26 <= dir.count - 41, dir[p] != 0 else { break }
            let name = ADFSInspector.string(dir, p, 10)
            let load = ADFSInspector.le32(dir, p + 10), exec = ADFSInspector.le32(dir, p + 14), size = Int(ADFSInspector.le32(dir, p + 18))
            let ind = UInt32(dir[p + 22]) | UInt32(dir[p + 23]) << 8 | UInt32(dir[p + 24]) << 16
            let attr = dir[p + 25]
            let here = path + [name]
            p += 26
            if attr & 0x08 != 0 {
                guard depth < 16, let sub = fetch(ind, 2048, here) else { throw ReadError.badAddress(here.joined(separator: ".")) }
                dirs.append(here)
                try walk(d, at: nil, length: 2048, path: here, depth: depth + 1, items: &items, dirs: &dirs, rootBytes: sub, fetch: fetch)
            } else {
                guard let data = fetch(ind, size, here) else { throw ReadError.badAddress(here.joined(separator: ".")) }
                let a = attr & 0x37
                items.append(ADFSHardDiscBuilder.Item(path: here, data: data, load: load, exec: exec, attributes: a == 0 ? 3 : a))
            }
        }
    }

    /// An E (or F) format disc's map.
    struct NewMap {
        let d: [UInt8]
        let secSize: Int, idlen: Int, bpmb: Int, zones: Int, zoneSpare: Int, root: UInt32, discSize: Int
        /// Each fragment: id, map-bit address, length in bits.
        var fragments: [(id: Int, address: Int, bits: Int)] = []

        init?(_ bytes: [UInt8]) {
            let d = bytes
            guard d.count >= 1024 else { return nil }
            let dr = 4
            let log2sec = Int(d[dr])
            guard log2sec >= 8 && log2sec <= 12 else { return nil }
            secSize = 1 << log2sec
            idlen = Int(d[dr + 4])
            bpmb = 1 << Int(d[dr + 5])
            zones = Int(d[dr + 9])
            zoneSpare = Int(d[dr + 10]) | Int(d[dr + 11]) << 8
            root = ADFSInspector.le32(d, dr + 12)
            discSize = Int(ADFSInspector.le32(d, dr + 16))
            guard idlen >= 8 && idlen <= 21, zones >= 1, zones * secSize <= d.count, discSize > 0, discSize <= d.count + secSize * 2 else { return nil }
            self.d = bytes
            var fragments: [(id: Int, address: Int, bits: Int)] = []
            let secSize = self.secSize, idlen = self.idlen
            let zoneBits = secSize * 8 - zoneSpare
            let headerBits = 32, recordBits = 480
            func bit(_ zone: Int, _ b: Int) -> Bool { bytes[zone * secSize + b / 8] >> UInt8(b % 8) & 1 != 0 }
            func bits(_ zone: Int, _ b: Int, _ n: Int) -> Int {
                var v = 0
                for i in 0..<n where bit(zone, b + i) { v |= 1 << i }
                return v
            }
            for z in 0..<zones {
                let base = z * secSize
                // The free chain: from bit 8 (the free link's own place).
                var free: Set<Int> = []
                var link = (Int(d[base + 1]) | Int(d[base + 2]) << 8) & 0x7FFF
                var at = 8
                while link != 0 && free.count < 10_000 {
                    at += link
                    guard at < secSize * 8 else { break }
                    free.insert(at)
                    link = bits(z, at, idlen)
                }
                var b = z == 0 ? headerBits + recordBits : headerBits
                let end = min(secSize * 8, headerBits + zoneBits)
                while b + idlen < end {
                    let id = bits(z, b, idlen)
                    var e = b + idlen
                    while e < end && !bit(z, e) { e += 1 }
                    let length = e + 1 - b
                    let address = z * zoneBits + (b - headerBits) - recordBits
                    if !free.contains(b) { fragments.append((id, address, length)) }
                    b = e + 1
                }
            }
            self.fragments = fragments
        }

        /// `length` bytes from the object at indirect address `ind`.
        func read(_ ind: UInt32, length: Int) -> [UInt8]? {
            let id = Int(ind >> 8)
            let shared = Int(ind & 0xFF)
            var skip = shared > 0 ? (shared - 1) * secSize : 0
            var out: [UInt8] = []
            out.reserveCapacity(length)
            for f in fragments where f.id == id {
                let start = f.address * bpmb, size = f.bits * bpmb
                if skip >= size { skip -= size; continue }
                let from = start + skip
                let take = min(size - skip, length - out.count)
                skip = 0
                guard from >= 0, from + take <= d.count else { return nil }
                out += d[from..<(from + take)]
                if out.count == length { return out }
            }
            return out.count == length ? out : nil
        }
    }
}
