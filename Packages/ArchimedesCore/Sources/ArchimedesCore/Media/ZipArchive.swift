import Foundation
import zlib

/// Reads ZIP archives (stored, deflated and imploded members), including the Acorn
/// extra field ("AC", 0x4341) that RISC OS archivers such as SparkFS use to
/// keep a file's load and execution addresses and attributes:
///
///   +0 "ARC0"  +4 load address  +8 execution address  +12 attributes
///
/// Written from the PKWARE APPNOTE layout: the end of central directory
/// record, then one central directory header per member, each pointing at
/// a local header followed by the member's data.
public enum ZipArchive {
    public struct Member: Sendable {
        public var path: String
        public var data: [UInt8]
        public var isDirectory: Bool
        /// From the Acorn extra field, when present.
        public var load: UInt32?
        public var exec: UInt32?
        public var attributes: UInt32?
        public var modified: Date?
    }

    public static func isZip(_ d: [UInt8]) -> Bool { d.count >= 4 && d[0] == 0x50 && d[1] == 0x4B && d[2] == 3 && d[3] == 4 }

    public static func read(_ d: [UInt8]) throws -> [Member] {
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 { UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24 }
        // The end record sits in the last 64 KB + 22 bytes (after any comment).
        var eocd = -1
        var p = d.count - 22
        while p >= max(0, d.count - 22 - 65535) {
            if u32(p) == 0x0605_4B50 { eocd = p; break }
            p -= 1
        }
        guard eocd >= 0 else { throw MediaError.unsupportedFormat("zip: no end of central directory record") }
        let count = u16(eocd + 10)
        var c = Int(u32(eocd + 16))
        var out: [Member] = []
        for _ in 0..<count {
            guard c + 46 <= d.count, u32(c) == 0x0201_4B50 else { throw MediaError.unsupportedFormat("zip: bad central directory") }
            let flags = u16(c + 8), method = u16(c + 10), time = u16(c + 12), date = u16(c + 14)
            let crc = u32(c + 16), csize = Int(u32(c + 20)), usize = Int(u32(c + 24))
            let nameLen = u16(c + 28), extraLen = u16(c + 30), commentLen = u16(c + 32)
            let local = Int(u32(c + 42))
            guard c + 46 + nameLen + extraLen <= d.count else { throw MediaError.unsupportedFormat("zip: truncated header") }
            // Names are CP437 unless flagged UTF-8; RISC OS archivers write Latin-1.
            let nameBytes = Array(d[(c + 46)..<(c + 46 + nameLen)])
            let path = flags & 0x800 != 0 ? String(decoding: nameBytes, as: UTF8.self) : String(nameBytes.map { Character(Unicode.Scalar($0)) })
            var m = Member(path: path, data: [], isDirectory: path.hasSuffix("/"))
            acornExtra(Array(d[(c + 46 + nameLen)..<(c + 46 + nameLen + extraLen)]), into: &m)
            m.modified = dosDate(date: date, time: time)
            c += 46 + nameLen + extraLen + commentLen

            guard local + 30 <= d.count, u32(local) == 0x0403_4B50 else { throw MediaError.unsupportedFormat("zip: bad local header for \(path)") }
            let lName = u16(local + 26), lExtra = u16(local + 28)
            if m.load == nil, local + 30 + lName + lExtra <= d.count {
                acornExtra(Array(d[(local + 30 + lName)..<(local + 30 + lName + lExtra)]), into: &m)
            }
            let start = local + 30 + lName + lExtra
            guard start + csize <= d.count else { throw MediaError.unsupportedFormat("zip: \(path) runs past the end") }
            let raw = Array(d[start..<(start + csize)])
            switch method {
            case 0: m.data = raw
            case 8:
                guard let x = inflateRaw(raw, expected: usize) else { throw MediaError.unsupportedFormat("zip: \(path) is corrupt") }
                m.data = x
            case 6: m.data = try ZipImplode.explode(raw, size: usize, flags: flags)
            default:
                throw MediaError.unsupportedFormat("zip: \(path) uses compression method \(method) (only stored, deflate and implode are supported)")
            }
            guard flags & 1 == 0 else { throw MediaError.unsupportedFormat("zip: \(path) is encrypted") }
            let check = m.data.withUnsafeBufferPointer { UInt32(zlib.crc32(0, $0.baseAddress, uInt($0.count))) }
            guard check == crc else { throw MediaError.unsupportedFormat("zip: \(path) is corrupt (its CRC doesn't match)") }
            out.append(m)
        }
        return out
    }

    /// Picks out the Acorn ("AC") block from an extra field.
    static func acornExtra(_ e: [UInt8], into m: inout Member) {
        var p = 0
        while p + 4 <= e.count {
            let id = Int(e[p]) | Int(e[p + 1]) << 8, len = Int(e[p + 2]) | Int(e[p + 3]) << 8
            let body = Array(e[(p + 4)..<min(e.count, p + 4 + len)])
            if id == 0x4341, body.count >= 12, Array(body[0..<4]) == Array("ARC0".utf8) {
                func w(_ o: Int) -> UInt32 { UInt32(body[o]) | UInt32(body[o + 1]) << 8 | UInt32(body[o + 2]) << 16 | UInt32(body[o + 3]) << 24 }
                m.load = w(4); m.exec = w(8)
                if body.count >= 16 { m.attributes = w(12) }
                return
            }
            p += 4 + len
        }
    }

    static func dosDate(date: Int, time: Int) -> Date? {
        var c = DateComponents()
        c.year = 1980 + (date >> 9); c.month = (date >> 5) & 15; c.day = date & 31
        c.hour = time >> 11; c.minute = (time >> 5) & 63; c.second = (time & 31) * 2
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)
    }

    static func inflateRaw(_ input: [UInt8], expected: Int) -> [UInt8]? {
        var z = z_stream()
        guard inflateInit2_(&z, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&z) }
        var out = [UInt8](repeating: 0, count: max(expected, 1))
        var src = input
        let r: Int32 = src.withUnsafeMutableBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                z.next_in = s.baseAddress; z.avail_in = uInt(s.count)
                z.next_out = o.baseAddress; z.avail_out = uInt(o.count)
                return zlib.inflate(&z, Z_FINISH)
            }
        }
        guard r == Z_STREAM_END || (expected == 0 && r == Z_BUF_ERROR) else { return nil }
        return Array(out.prefix(Int(z.total_out)))
    }
}
