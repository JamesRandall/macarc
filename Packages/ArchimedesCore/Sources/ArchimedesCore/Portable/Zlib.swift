#if canImport(zlib)
import zlib
#endif

/// The deflate/CRC operations the core needs (snapshots, zip and gzip media).
/// Native builds use the system zlib; hosts without one (WebAssembly/WASI) use
/// the pure-Swift codec below, which reads any deflate stream and writes
/// valid (stored-block) zlib streams.
public enum Zlib {
    #if canImport(zlib)

    public static func crc32(_ b: [UInt8]) -> UInt32 {
        b.withUnsafeBufferPointer { UInt32(zlib.crc32(0, $0.baseAddress, uInt($0.count))) }
    }

    /// A zlib-wrapped deflate stream.
    public static func compress(_ b: [UInt8], level: Int32 = 6) -> [UInt8] {
        var len = compressBound(uLong(b.count))
        var out = [UInt8](repeating: 0, count: Int(len))
        let r = out.withUnsafeMutableBufferPointer { dst in
            b.withUnsafeBufferPointer { src in compress2(dst.baseAddress, &len, src.baseAddress, uLong(b.count), level) }
        }
        precondition(r == Z_OK, "zlib compress failed")
        return Array(out.prefix(Int(len)))
    }

    /// Decompress a zlib-wrapped stream whose decompressed size is known.
    public static func uncompress(_ b: [UInt8], size: Int) -> [UInt8]? {
        var len = uLong(size)
        var out = [UInt8](repeating: 0, count: max(size, 1))
        let r = out.withUnsafeMutableBufferPointer { dst in
            b.withUnsafeBufferPointer { src in zlib.uncompress(dst.baseAddress, &len, src.baseAddress, uLong(b.count)) }
        }
        return r == Z_OK ? Array(out.prefix(Int(len))) : nil
    }

    /// Decompress a raw (headerless) deflate stream.
    public static func inflateRaw(_ input: [UInt8], expected: Int) -> [UInt8]? {
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

    /// Fully decompress a gzip file, concatenating all members.
    static func gunzip(_ d: [UInt8], limit: Int) -> [UInt8]? {
        var z = z_stream()
        guard inflateInit2_(&z, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&z) }
        var out: [UInt8] = []
        let chunk = 1 << 16
        var buf = [UInt8](repeating: 0, count: chunk)
        var input = d
        return input.withUnsafeMutableBufferPointer { src -> [UInt8]? in
            z.next_in = src.baseAddress
            z.avail_in = uInt(src.count)
            while true {
                let r: Int32 = buf.withUnsafeMutableBufferPointer { dst in
                    z.next_out = dst.baseAddress
                    z.avail_out = uInt(chunk)
                    return zlib.inflate(&z, Z_NO_FLUSH)
                }
                out += buf[0..<(chunk - Int(z.avail_out))]
                if out.count > limit { return nil }
                switch r {
                case Z_STREAM_END:
                    // Another member follows only if a gzip magic does.
                    guard z.avail_in >= 2, z.next_in[0] == 0x1F, z.next_in[1] == 0x8B else { return out }
                    guard inflateReset(&z) == Z_OK else { return out }
                case Z_OK: continue
                case Z_BUF_ERROR where z.avail_in == 0: return out // truncated: keep what decoded
                default: return out.isEmpty ? nil : out
                }
            }
        }
    }

    #else

    public static func crc32(_ b: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for x in b { c = crcTable[Int((c ^ UInt32(x)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    /// A zlib-wrapped stream of stored deflate blocks (no compression).
    public static func compress(_ b: [UInt8], level: Int32 = 6) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        out.reserveCapacity(b.count + b.count / 65535 * 5 + 16)
        var p = 0
        repeat {
            let n = min(65535, b.count - p)
            let last: UInt8 = p + n == b.count ? 1 : 0
            out += [last, UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)]
            out += b[p..<(p + n)]
            p += n
        } while p < b.count
        let a = adler32(b)
        out += [UInt8(a >> 24), UInt8((a >> 16) & 0xFF), UInt8((a >> 8) & 0xFF), UInt8(a & 0xFF)]
        return out
    }

    public static func uncompress(_ b: [UInt8], size: Int) -> [UInt8]? {
        guard b.count >= 6, b[0] & 0x0F == 8, (UInt16(b[0]) << 8 | UInt16(b[1])) % 31 == 0, b[1] & 0x20 == 0 else { return nil }
        var s = InflateStream(b, start: 2, limit: size)
        guard let out = s.run(), out.count == size, s.byteAlignedOffset + 4 <= b.count else { return nil }
        let q = s.byteAlignedOffset
        let a = UInt32(b[q]) << 24 | UInt32(b[q + 1]) << 16 | UInt32(b[q + 2]) << 8 | UInt32(b[q + 3])
        return a == adler32(out) ? out : nil
    }

    public static func inflateRaw(_ input: [UInt8], expected: Int) -> [UInt8]? {
        var s = InflateStream(input, start: 0, limit: max(expected, 1 << 20))
        guard let out = s.run(), expected == 0 || out.count == expected else { return nil }
        return out
    }

    static func gunzip(_ d: [UInt8], limit: Int) -> [UInt8]? {
        var out: [UInt8] = []
        var p = 0
        while let off = Gzip.deflateOffset(Array(d[p...])) {
            var s = InflateStream(d, start: p + off, limit: limit - out.count)
            guard let member = s.run() else { return out.isEmpty ? nil : out }
            out += member
            p = s.byteAlignedOffset + 8 // CRC-32 and ISIZE trailer
            guard p + 2 <= d.count, d[p] == 0x1F, d[p + 1] == 0x8B else { return out }
        }
        return out
    }

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func adler32(_ d: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        var i = 0
        while i < d.count {
            let end = min(i + 5552, d.count)
            while i < end { a += UInt32(d[i]); b += a; i += 1 }
            a %= 65521; b %= 65521
        }
        return b << 16 | a
    }

    #endif
}

#if !canImport(zlib)
/// A straightforward RFC 1951 decoder (canonical Huffman, table per block).
struct InflateStream {
    let src: [UInt8]
    var pos: Int
    var bitBuf: UInt32 = 0
    var bitCount = 0
    let limit: Int
    var out: [UInt8] = []

    init(_ src: [UInt8], start: Int, limit: Int) {
        self.src = src; self.pos = start; self.limit = limit
    }

    /// Offset of the first byte after the stream (valid once `run` returns).
    var byteAlignedOffset: Int { pos - bitCount / 8 }

    struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int]

        init?(_ lengths: [Int]) {
            symbols = [Int](repeating: 0, count: lengths.count)
            for l in lengths { counts[l] += 1 }
            counts[0] = 0
            var left = 1
            for l in 1..<16 { left <<= 1; left -= counts[l]; if left < 0 { return nil } }
            var offs = [Int](repeating: 0, count: 16)
            for l in 1..<15 { offs[l + 1] = offs[l] + counts[l] }
            for (s, l) in lengths.enumerated() where l != 0 { symbols[offs[l]] = s; offs[l] += 1 }
        }
    }

    mutating func bits(_ n: Int) -> Int? {
        while bitCount < n {
            guard pos < src.count else { return nil }
            bitBuf |= UInt32(src[pos]) << UInt32(bitCount)
            pos += 1; bitCount += 8
        }
        let v = Int(bitBuf & ((1 << UInt32(n)) - 1))
        bitBuf >>= UInt32(n); bitCount -= n
        return v
    }

    mutating func decode(_ h: Huffman) -> Int? {
        var code = 0, first = 0, index = 0
        for l in 1..<16 {
            guard let b = bits(1) else { return nil }
            code |= b
            let count = h.counts[l]
            if code - count < first { return h.symbols[index + (code - first)] }
            index += count; first += count
            first <<= 1; code <<= 1
        }
        return nil
    }

    static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
                           4097, 6145, 8193, 12289, 16385, 24577]
    static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    static let fixedLit = Huffman((0..<288).map { $0 < 144 ? 8 : $0 < 256 ? 9 : $0 < 280 ? 7 : 8 })!
    static let fixedDist = Huffman([Int](repeating: 5, count: 30))!

    mutating func run() -> [UInt8]? {
        var final = 0
        repeat {
            guard let f = bits(1), let type = bits(2) else { return nil }
            final = f
            switch type {
            case 0:
                bitBuf = 0; bitCount = 0 // discard to the byte boundary (whole bytes were never buffered past it)
                guard pos + 4 <= src.count else { return nil }
                let n = Int(src[pos]) | Int(src[pos + 1]) << 8
                let nn = Int(src[pos + 2]) | Int(src[pos + 3]) << 8
                guard n == ~nn & 0xFFFF, pos + 4 + n <= src.count, out.count + n <= limit else { return nil }
                out += src[(pos + 4)..<(pos + 4 + n)]
                pos += 4 + n
            case 1:
                guard codes(Self.fixedLit, Self.fixedDist) else { return nil }
            case 2:
                guard let (lit, dist) = dynamicTables(), codes(lit, dist) else { return nil }
            default:
                return nil
            }
        } while final == 0
        return out
    }

    mutating func dynamicTables() -> (Huffman, Huffman)? {
        guard let hlit = bits(5), let hdist = bits(5), let hclen = bits(4) else { return nil }
        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var cl = [Int](repeating: 0, count: 19)
        for i in 0..<(hclen + 4) { guard let v = bits(3) else { return nil }; cl[order[i]] = v }
        guard let clh = Huffman(cl) else { return nil }
        let total = hlit + 257 + hdist + 1
        var lengths: [Int] = []
        while lengths.count < total {
            guard let sym = decode(clh) else { return nil }
            switch sym {
            case 0..<16: lengths.append(sym)
            case 16:
                guard let prev = lengths.last, let r = bits(2) else { return nil }
                lengths += [Int](repeating: prev, count: 3 + r)
            case 17:
                guard let r = bits(3) else { return nil }
                lengths += [Int](repeating: 0, count: 3 + r)
            default:
                guard let r = bits(7) else { return nil }
                lengths += [Int](repeating: 0, count: 11 + r)
            }
        }
        guard lengths.count == total, lengths[256] != 0,
              let lit = Huffman(Array(lengths[0..<(hlit + 257)])),
              let dist = Huffman(Array(lengths[(hlit + 257)...])) else { return nil }
        return (lit, dist)
    }

    mutating func codes(_ lit: Huffman, _ dist: Huffman) -> Bool {
        while true {
            guard let sym = decode(lit) else { return false }
            if sym < 256 {
                guard out.count < limit else { return false }
                out.append(UInt8(sym))
            } else if sym == 256 {
                return true
            } else {
                let i = sym - 257
                guard i < 29, let le = bits(Self.lengthExtra[i]), let ds = decode(dist), ds < 30,
                      let de = bits(Self.distExtra[ds]) else { return false }
                let len = Self.lengthBase[i] + le, d = Self.distBase[ds] + de
                guard d <= out.count, out.count + len <= limit else { return false }
                let start = out.count - d
                for k in 0..<len { out.append(out[start + k]) }
            }
        }
    }
}
#endif
