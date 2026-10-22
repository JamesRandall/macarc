import Foundation

/// Expands ZIP method 6 ("imploded"), which PKZIP 1 and some early RISC OS
/// archives use. From the PKWARE APPNOTE's description:
///
/// The member starts with two or three Shannon-Fano trees: a literal tree
/// (256 codes, only when general purpose flag bit 2 is set), then length
/// and distance trees (64 codes each). A tree is a byte giving the count
/// less one of the bytes that follow; each of those holds a bit length
/// less one (low four bits) and how many codes in a row have it, less one
/// (high four). Codes are assigned longest first, counting up from zero;
/// stored, they come out of the LSB-first bit stream inverted, so reading
/// a complemented bit at a time against canonical (shortest first) codes
/// of the same lengths decodes them.
///
/// Then: a 1 bit is a literal (a literal-tree code, or 8 plain bits with
/// two trees). A 0 bit is a match: the distance's low 6 bits (7 with the
/// 8 KB window of flag bit 1) plain, its high 6 bits from the distance
/// tree, plus one; the length from the length tree plus 2 (3 with a
/// literal tree), and when the code is 63, plus 8 more plain bits. Bytes
/// before the start of the output read as zero.
enum ZipImplode {
    struct Tree {
        var counts = [Int](repeating: 0, count: 17)
        var symbols: [Int] = []

        init?(lengths: [Int]) {
            for l in lengths { counts[l] += 1 }
            var offsets = [Int](repeating: 0, count: 17)
            for l in 1..<16 { offsets[l + 1] = offsets[l] + counts[l] }
            symbols = [Int](repeating: 0, count: lengths.count)
            for (s, l) in lengths.enumerated() where l > 0 { symbols[offsets[l]] = s; offsets[l] += 1 }
        }
    }

    struct Bits {
        let d: [UInt8]
        var p = 0, buffer = 0, count = 0
        mutating func bit() throws -> Int {
            if count == 0 {
                guard p < d.count else { throw MediaError.unsupportedFormat("zip: imploded data ends early") }
                buffer = Int(d[p]); p += 1; count = 8
            }
            let b = buffer & 1
            buffer >>= 1; count -= 1
            return b
        }
        mutating func bits(_ n: Int) throws -> Int {
            var v = 0
            for i in 0..<n { v |= try bit() << i }
            return v
        }
        mutating func byte() throws -> Int {
            guard p < d.count else { throw MediaError.unsupportedFormat("zip: imploded data ends early") }
            defer { p += 1 }
            return Int(d[p])
        }
        mutating func decode(_ t: Tree) throws -> Int {
            var code = 0, first = 0, index = 0
            for l in 1...16 {
                code |= try bit() ^ 1
                let n = t.counts[l]
                if code - first < n { return t.symbols[index + code - first] }
                index += n; first += n
                first <<= 1; code <<= 1
            }
            throw MediaError.unsupportedFormat("zip: bad imploded code")
        }
    }

    static func tree(_ s: inout Bits, count: Int) throws -> Tree {
        var lengths: [Int] = []
        for _ in 0..<(try s.byte() + 1) {
            let b = try s.byte()
            lengths += [Int](repeating: (b & 15) + 1, count: (b >> 4) + 1)
        }
        guard lengths.count == count, let t = Tree(lengths: lengths) else { throw MediaError.unsupportedFormat("zip: bad imploded tree") }
        return t
    }

    static func explode(_ input: [UInt8], size: Int, flags: Int) throws -> [UInt8] {
        let bigWindow = flags & 2 != 0, literalTree = flags & 4 != 0
        var s = Bits(d: input)
        let literals = literalTree ? try tree(&s, count: 256) : nil
        let lengths = try tree(&s, count: 64), distances = try tree(&s, count: 64)
        let lowBits = bigWindow ? 7 : 6, minimum = literalTree ? 3 : 2
        var out: [UInt8] = []
        out.reserveCapacity(size)
        while out.count < size {
            if try s.bit() == 1 {
                out.append(UInt8(try literals.map { try s.decode($0) } ?? s.bits(8)))
            } else {
                let low = try s.bits(lowBits)
                let distance = (try s.decode(distances) << lowBits | low) + 1
                var length = try s.decode(lengths)
                if length == 63 { length += try s.bits(8) }
                length += minimum
                for _ in 0..<min(length, size - out.count) {
                    out.append(out.count >= distance ? out[out.count - distance] : 0)
                }
            }
        }
        return out
    }
}
