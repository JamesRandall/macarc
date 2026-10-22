import Foundation

/// Lays out an empty ADFS filing system on a new hard disc image, as
/// !HForm's old-map option does, so RISC OS 2 and 3.1 can use the drive
/// without the Apps disc. The layout ("D" format, from the PRM's FileCore
/// chapter and RISC OS Open's documentation):
///
///   &000  old free space map (two 256-byte halves, each with a check byte)
///   &400  root directory "$" (new 2048-byte directory, "Hugo")
///   &C00  boot block: defect list, ST506 parameters, disc record, checksum
///   &E00  free space to the end of the drive
public enum ADFSFormatter {
    public static func createFormattedImage(path: String, geometry: HardDiscGeometry, name: String) throws {
        let img = try HardDiscImage.create(path: path, geometry: geometry)
        let bytes = layout(geometry: geometry, name: name, id: discID(for: name))
        let size = geometry.sectorSize
        for start in stride(from: 0, to: bytes.count, by: size) {
            let lba = start / size
            let g = geometry
            img.write(cylinder: lba / (g.heads * g.sectorsPerTrack), head: (lba / g.sectorsPerTrack) % g.heads,
                      sector: lba % g.sectorsPerTrack, Array(bytes[start..<min(start + size, bytes.count)]))
        }
        img.synchronize()
    }

    /// A stable disc id from the name (HForm picks one at random; any value will do).
    static func discID(for name: String) -> UInt16 {
        var h: UInt16 = 0x4D41
        for b in name.utf8 { h = h &* 31 &+ UInt16(b) }
        return h
    }

    /// Letters, digits and underscores only (a disc name cannot hold spaces
    /// or path characters), at most ten.
    static func discName(_ s: String) -> [UInt8] {
        Array(s.utf8.filter { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F }.prefix(10))
    }

    /// The first &E00 bytes of the disc.
    public static func layout(geometry g: HardDiscGeometry, name: String, id: UInt16) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: 0xE00)
        // The old map counts in 256-byte units whatever the sector size.
        let sectors = g.byteCount / 256
        func put24(_ v: Int, at o: Int) { d[o] = UInt8(v & 0xFF); d[o + 1] = UInt8((v >> 8) & 0xFF); d[o + 2] = UInt8((v >> 16) & 0xFF) }
        func put32(_ v: Int, at o: Int) { put24(v, at: o); d[o + 3] = UInt8((v >> 24) & 0xFF) }

        // Free space map: one free area from &E00 to the end.
        put24(0xE00 >> 8, at: 0x000)
        put24(sectors - (0xE00 >> 8), at: 0x100)
        put24(sectors, at: 0x0FC)
        // The name is interleaved: even characters in the first half, odd in the second.
        let n = discName(name)
        if !n.isEmpty {
            let padded = n + [UInt8](repeating: 0x20, count: 10 - n.count)
            for k in 0..<5 { d[0x0F7 + k] = padded[2 * k]; d[0x1F6 + k] = padded[2 * k + 1] }
        }
        d[0x1FB] = UInt8(id & 0xFF); d[0x1FC] = UInt8(id >> 8)
        d[0x1FD] = 0 // boot option
        d[0x1FE] = 3 // one free-list entry
        d[0x0FF] = checksum(d, 0x000, 0x100)
        d[0x1FF] = checksum(d, 0x100, 0x100)

        // Root directory at &400 (its own parent).
        let dir = 0x400
        for (i, c) in "Hugo".utf8.enumerated() { d[dir + 1 + i] = c; d[dir + 2043 + i] = c }
        put24(dir >> 8, at: dir + 2010)
        d[dir + 2013] = 0x24 // title "$"
        d[dir + 2032] = 0x24 // name "$"
        d[dir + 2047] = directoryCheckByte(Array(d[dir..<(dir + 2048)]))

        // Boot block at &C00.
        let bb = 0xC00
        put32(0x2000_0000, at: bb) // empty defect list
        put32(-1, at: bb + 0x1AC)  // end of defect space
        if g.sectorSize == 256 {
            // HD63463 parameters: step rate, gaps, step-pulse width, low-current
            // and precompensation cylinders, then the park address. (IDE
            // drives need none.)
            d[bb + 0x1B3] = 0x00
            d[bb + 0x1B4] = 0x0A; d[bb + 0x1B5] = 0x20; d[bb + 0x1B6] = 0x0C; d[bb + 0x1B7] = 0x0D
            put24(0x3FF, at: bb + 0x1B8); d[bb + 0x1BA] = 128; d[bb + 0x1BB] = 0
            put32((g.cylinders - 1) * g.heads * g.sectorsPerTrack * 256, at: bb + 0x1BC)
        }
        // Disc record (old map: zones 0, root &400, whole-drive size).
        d[bb + 0x1C0] = UInt8(g.sectorSize.trailingZeroBitCount)
        d[bb + 0x1C1] = UInt8(g.sectorsPerTrack)
        d[bb + 0x1C2] = UInt8(g.heads)
        put32(dir, at: bb + 0x1CC)
        put32(g.byteCount, at: bb + 0x1D0)
        d[bb + 0x1FF] = checksum(d, bb, 0x200)
        return d
    }

    /// FileCore's check byte for a map half or boot block: an 8-bit add
    /// with carry over every byte but the last, from the top down.
    static func checksum(_ d: [UInt8], _ start: Int, _ length: Int) -> UInt8 {
        var sum = 0, carry = 0
        for i in stride(from: start + length - 2, through: start, by: -1) {
            let t = sum + Int(d[i]) + carry
            carry = t >> 8
            sum = t & 0xFF
        }
        return UInt8(sum)
    }

    /// The directory check byte: words and bytes of the used entries and of
    /// the tail (from the parent pointer, before the closing name),
    /// accumulated with a 13-bit rotate, then folded to a byte.
    static func directoryCheckByte(_ dir: [UInt8]) -> UInt8 {
        var acc: UInt32 = 0
        func step(_ v: UInt32) { acc = v ^ ((acc >> 13) | (acc << 19)) }
        func word(_ o: Int) -> UInt32 { UInt32(dir[o]) | UInt32(dir[o + 1]) << 8 | UInt32(dir[o + 2]) << 16 | UInt32(dir[o + 3]) << 24 }
        var entries = 5
        while entries + 26 <= 2007 && dir[entries] != 0 { entries += 26 }
        var o = 0
        while o < entries & ~3 { step(word(o)); o += 4 }
        while o < entries { step(UInt32(dir[o])); o += 1 }
        o = 2008
        while o < 2044 { step(word(o)); o += 4 }
        acc ^= acc >> 16
        acc ^= acc >> 8
        return UInt8(acc & 0xFF)
    }
}
