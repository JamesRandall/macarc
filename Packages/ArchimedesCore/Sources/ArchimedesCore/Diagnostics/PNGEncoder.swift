#if canImport(Compression)
import Compression
#endif
import Foundation

/// Minimal PNG writer (8-bit RGB) so captures work without UI frameworks.
public enum PNGEncoder {
    public static func encode(_ frame: VideoFrame, scaleX: Int = 1, scaleY: Int = 1) -> Data {
        let w = frame.width * scaleX, h = frame.height * scaleY
        var raw = [UInt8]()
        raw.reserveCapacity((w * 3 + 1) * h)
        for y in 0..<h {
            raw.append(0)
            let sy = y / scaleY
            for x in 0..<w {
                let p = frame.pixels[sy * frame.width + x / scaleX]
                raw.append(UInt8((p >> 16) & 0xFF)); raw.append(UInt8((p >> 8) & 0xFF)); raw.append(UInt8(p & 0xFF))
            }
        }
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = [UInt8]()
        ihdr += be32(UInt32(w)); ihdr += be32(UInt32(h)); ihdr += [8, 2, 0, 0, 0]
        png.append(chunk("IHDR", ihdr))
        png.append(chunk("IDAT", zlib(raw)))
        png.append(chunk("IEND", []))
        return png
    }

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

    static func chunk(_ type: String, _ data: [UInt8]) -> Data {
        var d = Data(be32(UInt32(data.count)))
        let t = Array(type.utf8)
        d.append(contentsOf: t); d.append(contentsOf: data)
        d.append(contentsOf: be32(crc32(t + data)))
        return d
    }

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ d: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in d { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func zlib(_ d: [UInt8]) -> [UInt8] {
        #if !canImport(Compression)
        return Zlib.compress(d)
        #else
        var out = [UInt8](repeating: 0, count: d.count + 1024)
        let n = d.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                compression_encode_buffer(dst.baseAddress!, dst.count, src.baseAddress!, d.count, nil, COMPRESSION_ZLIB)
            }
        }
        var a: UInt32 = 1, b: UInt32 = 0
        for x in d { a = (a + UInt32(x)) % 65521; b = (b + a) % 65521 }
        return [0x78, 0x01] + out.prefix(n) + be32((b << 16) | a)
        #endif
    }
}
