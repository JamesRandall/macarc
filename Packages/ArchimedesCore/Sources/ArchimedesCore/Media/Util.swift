import Compression
import zlib
import CryptoKit
import Foundation

public enum SHA256 {
    public static func hex(_ data: [UInt8]) -> String {
        CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum Gzip {
    /// Offset of the raw deflate stream inside a gzip member.
    static func deflateOffset(_ d: [UInt8]) -> Int? {
        guard d.count > 18, d[0] == 0x1F, d[1] == 0x8B, d[2] == 8 else { return nil }
        let flags = d[3]
        var p = 10
        if flags & 4 != 0 { guard p + 2 <= d.count else { return nil }; p += 2 + Int(d[p]) | Int(d[p + 1]) << 8 }
        if flags & 8 != 0 { while p < d.count && d[p] != 0 { p += 1 }; p += 1 }
        if flags & 16 != 0 { while p < d.count && d[p] != 0 { p += 1 }; p += 1 }
        if flags & 2 != 0 { p += 2 }
        return p < d.count ? p : nil
    }

    /// Fully decompress a gzip file, concatenating all members (RISC OS
    /// tools often write a JFD as several members). Uses the system zlib.
    public static func inflate(_ d: [UInt8], limit: Int = 64 << 20) -> [UInt8]? {
        guard deflateOffset(d) != nil else { return nil }
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

    static func inflateHeaderPeek(_ d: [UInt8]) -> [UInt8]? {
        inflate(d).map { Array($0.prefix(64)) }
    }
}
