#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

public enum SHA256 {
    public static func hex(_ data: [UInt8]) -> String {
        #if canImport(CryptoKit)
        CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        PortableSHA256.hash(data).map { String(format: "%02x", $0) }.joined()
        #endif
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
    /// tools often write a JFD as several members).
    public static func inflate(_ d: [UInt8], limit: Int = 64 << 20) -> [UInt8]? {
        guard deflateOffset(d) != nil else { return nil }
        return Zlib.gunzip(d, limit: limit)
    }

    static func inflateHeaderPeek(_ d: [UInt8]) -> [UInt8]? {
        inflate(d).map { Array($0.prefix(64)) }
    }
}
