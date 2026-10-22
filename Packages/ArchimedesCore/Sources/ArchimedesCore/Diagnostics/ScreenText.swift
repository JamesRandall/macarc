import Foundation

/// Reads the text on the screen by matching 8×8 cells of the display
/// against RISC OS's system font, which is found in the ROM (it is the
/// BBC Micro's). Works in any screen mode where text is on the character
/// grid (the command line, BASIC, the F12 prompt); text the desktop draws
/// at other positions shows as `?`.
public enum ScreenText {
    /// Glyph bitmap (8 rows, 1 bit per pixel, top row in the low byte) to
    /// character, for characters 32-126.
    public static func font(in rom: [UInt8]) -> [UInt64: Character]? {
        let a: [UInt8] = [0x3C, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00]
        let zero: [UInt8] = [0x3C, 0x66, 0x6E, 0x7E, 0x76, 0x66, 0x3C, 0x00]
        var i = 0
        while i + 8 <= rom.count {
            if rom[i] == a[0] && Array(rom[i..<(i + 8)]) == a {
                let base = i - (0x41 - 0x20) * 8
                // The digit 0 confirms it is the font table, not a stray match.
                if base >= 0, base + 95 * 8 <= rom.count, Array(rom[(base + 16 * 8)..<(base + 17 * 8)]) == zero {
                    var table: [UInt64: Character] = [:]
                    for c in 0..<95 {
                        var g: UInt64 = 0
                        for row in 0..<8 { g |= UInt64(rom[base + c * 8 + row]) << (8 * row) }
                        if table[g] == nil { table[g] = Character(UnicodeScalar(UInt8(c + 32))) }
                    }
                    return table
                }
            }
            i += 1
        }
        return nil
    }

    /// The display's text, row by row (trailing spaces and blank rows at the
    /// end removed). `display` is the display area within the frame.
    public static func read(_ frame: VideoFrame, display: (x: Int, y: Int, width: Int, height: Int), font: [UInt64: Character]) -> [String] {
        let x0 = max(0, display.x), y0 = max(0, display.y)
        let w = min(display.width, frame.width - x0), h = min(display.height, frame.height - y0)
        guard w >= 8, h >= 8 else { return [] }
        var lines: [String] = []
        for cy in 0..<(h / 8) {
            var line = ""
            for cx in 0..<(w / 8) {
                // The commonest colour in the cell is the background.
                var counts: [UInt32: Int] = [:]
                for r in 0..<8 {
                    let row = (y0 + cy * 8 + r) * frame.width + x0 + cx * 8
                    for p in 0..<8 { counts[frame.pixels[row + p], default: 0] += 1 }
                }
                guard let bg = counts.max(by: { $0.value < $1.value })?.key else { line += " "; continue }
                if counts.count == 1 { line += " "; continue }
                var g: UInt64 = 0
                for r in 0..<8 {
                    let row = (y0 + cy * 8 + r) * frame.width + x0 + cx * 8
                    var bits: UInt64 = 0
                    for p in 0..<8 where frame.pixels[row + p] != bg { bits |= 0x80 >> UInt64(p) }
                    g |= bits << UInt64(8 * r)
                }
                // Inverted cells (the cursor, highlights) match the complement.
                line.append(font[g] ?? font[~g] ?? "?")
            }
            lines.append(String(line.reversed().drop { $0 == " " }.reversed()))
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }
}

extension Machine {
    /// The text on the screen now (see `ScreenText`).
    public var screenText: [String] {
        if systemFont == nil { systemFont = ScreenText.font(in: rom.data) ?? [:] }
        let v = vidc
        let (left, top) = v.frameOrigin
        let display = (x: v.hDisplayStart - left, y: v.vDisplayStart - top,
                       width: v.hDisplayEnd - v.hDisplayStart, height: v.vDisplayEnd - v.vDisplayStart)
        return ScreenText.read(currentFrame, display: display, font: systemFont ?? [:])
    }
}

extension Machine {
    /// What's at a pixel of the current frame: the video memory address
    /// (physical, as video DMA reads it) and the colour number there, or
    /// "border". For the debugger's screen inspection.
    public func screenAddress(x: Int, y: Int) -> String {
        let v = vidc
        let (left, top) = v.frameOrigin
        let dx = x - (v.hDisplayStart - left), dy = y - (v.vDisplayStart - top)
        let width = v.hDisplayEnd - v.hDisplayStart, height = v.vDisplayEnd - v.vDisplayStart
        guard x >= 0, y >= 0, x < currentFrame.width, y < currentFrame.height else { return "" }
        guard dx >= 0, dy >= 0, dx < width, dy < height else { return "x \(x), line \(y): border" }
        let bpp = v.bitsPerPixel
        let bytesPerLine = width * bpp / 8
        let span = Int(memc.vend) + 16 - Int(memc.vstart)
        var offset = Int(memc.vinit) - Int(memc.vstart) + dy * bytesPerLine + dx * bpp / 8
        if span > 0 { offset %= span }
        let address = UInt32(Int(memc.vstart) + offset)
        let byte = memc.debugRead(address, space: .physical) ?? 0
        let shift = (dx * bpp) % 8
        let colour = (Int(byte) >> shift) & ((1 << bpp) - 1)
        return String(format: "x %d, line %d: &%07X (colour %d)", dx, dy, 0x0200_0000 + address, colour)
    }
}
