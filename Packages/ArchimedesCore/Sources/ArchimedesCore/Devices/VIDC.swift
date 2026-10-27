import Foundation

/// A completed guest video frame (the border/display area as programmed in VIDC).
public struct VideoFrame: Sendable {
    public var width: Int
    public var height: Int
    /// 0xAARRGGBB pixels, row-major.
    public var pixels: [UInt32]
    public var frameNumber: UInt64
    /// Suggested host pixel scaling to approximate the monitor's aspect ratio.
    public var scaleX: Int
    public var scaleY: Int
    public var pixelClockMHz: Int
    public var bitsPerPixel: Int
    /// Where the display area (the screen memory's pixels) sits in the
    /// frame, inside the border; nil when there isn't one.
    public var displayArea: Area?

    /// A rectangle of frame pixels.
    public struct Area: Sendable, Equatable {
        public var x, y, width, height: Int
        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
    }

    public static let blank = VideoFrame(width: 640, height: 256, pixels: [UInt32](repeating: 0xFF00_0000, count: 640 * 256),
                                         frameNumber: 0, scaleX: 1, scaleY: 2, pixelClockMHz: 16, bitsPerPixel: 4)

    /// FNV-1a hash of the pixel data, stable across runs.
    public var checksum: UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        h = (h ^ UInt64(width)) &* 0x100_0000_01B3
        h = (h ^ UInt64(height)) &* 0x100_0000_01B3
        for p in pixels { h = (h ^ UInt64(p)) &* 0x100_0000_01B3 }
        return h
    }
}

/// Receives VIDC sound bytes (already converted to linear stereo).
public protocol AudioSink: AnyObject {
    func audioSamples(left: Float, right: Float, count: Int, sampleRate: Double)
}

/// Acorn VIDC1 (VL86C310): video timing, palette, cursor and sound output.
///
/// Video is generated a raster line at a time from the MEMC video DMA
/// pointer, so palette/register changes take effect at line granularity.
public final class VIDC {
    // Registers (raw values as written)
    public private(set) var palette = [UInt32](repeating: 0, count: 16)
    public private(set) var border: UInt32 = 0
    public private(set) var cursorPalette = [UInt32](repeating: 0, count: 4)
    public private(set) var stereo = [UInt8](repeating: 4, count: 8)
    public private(set) var hcr: UInt32 = 0, hswr: UInt32 = 0, hbsr: UInt32 = 0, hdsr: UInt32 = 0
    public private(set) var hder: UInt32 = 0, hber: UInt32 = 0, hcsr: UInt32 = 0, hir: UInt32 = 0
    public private(set) var vcr: UInt32 = 0, vswr: UInt32 = 0, vbsr: UInt32 = 0, vdsr: UInt32 = 0
    public private(set) var vder: UInt32 = 0, vber: UInt32 = 0, vcsr: UInt32 = 0, vcer: UInt32 = 0
    public private(set) var sfr: UInt32 = 0
    public private(set) var controlRegister: UInt32 = 0

    // Derived colour tables (0xAARRGGBB)
    var displayColours = [UInt32](repeating: 0xFF00_0000, count: 256)
    var borderColour: UInt32 = 0xFF00_0000
    var cursorColours = [UInt32](repeating: 0xFF00_0000, count: 4)

    public private(set) var raster = 0
    var lineTickFraction: UInt64 = 0

    // Frame being built
    var frameWidth = 0
    var frameHeight = 0
    var frameBuffer = [UInt32]()
    var frameLeft = 0
    var frameTop = 0
    /// Where the frame starts, in VIDC's horizontal pixels and raster lines.
    var frameOrigin: (Int, Int) { (frameLeft, frameTop) }
    public private(set) var frameCount: UInt64 = 0
    public private(set) var lastFrame = VideoFrame.blank
    public var frameCompleted: ((VideoFrame) -> Void)?
    /// The debugger's view of the raster: called at the start of each line
    /// (0 is the start of the frame) while it needs it.
    var debugLineHook: ((Int) -> Void)?

    var lineBytes = [UInt8](repeating: 0, count: 4096)

    unowned(unsafe) let memc: MEMC
    unowned(unsafe) let ioc: IOC
    unowned(unsafe) let scheduler: Scheduler
    public weak var audioSink: AudioSink?
    public var unknownWrite: ((String) -> Void)?
    /// Most recent sound bytes (ring) for tests / sample hashing.
    public private(set) var soundBytesOutput: UInt64 = 0
    public private(set) var soundBytesNonSilent: UInt64 = 0
    public private(set) var soundHash: UInt64 = 0xCBF2_9CE4_8422_2325
    static let logTable: [Float] = VIDC.makeLogTable()

    init(memc: MEMC, ioc: IOC, scheduler: Scheduler) {
        self.memc = memc
        self.ioc = ioc
        self.scheduler = scheduler
        scheduler.setHandler(.videoLine) { [unowned self] in self.lineEvent() }
        scheduler.setHandler(.sound) { [unowned self] in self.soundEvent() }
    }

    func powerOn() {
        raster = 0
        lineTickFraction = 0
        scheduler.schedule(.videoLine, after: lineTicks)
    }

    // MARK: Register writes

    /// When set, every register write is recorded with the frame and raster
    /// line it landed on (diagnostics; off by default).
    public var registerLog: RingBuffer<String>?

    func writeRegister(_ v: UInt32) {
        let reg = (v >> 24) & 0xFC
        let data = v & 0x00FF_FFFF
        if registerLog != nil {
            registerLog!.append(String(format: "frame %llu line %d reg %02X = %06X", frameCount, raster, reg, data))
        }
        switch reg {
        case 0x00...0x3C:
            palette[Int(reg >> 2)] = data & 0x1FFF
            rebuildDisplayColour(Int(reg >> 2))
        case 0x40:
            border = data & 0x1FFF
            borderColour = Self.rgb(border)
        case 0x44, 0x48, 0x4C:
            let i = Int((reg - 0x40) >> 2)
            cursorPalette[i] = data & 0x1FFF
            cursorColours[i] = Self.rgb(cursorPalette[i])
        case 0x60...0x7C:
            // 0x60 is channel 7; 0x64-0x7C are channels 0-6.
            let i = reg == 0x60 ? 7 : Int((reg - 0x64) >> 2)
            stereo[i] = UInt8(data & 7)
        case 0x80: hcr = data
        case 0x84: hswr = data
        case 0x88: hbsr = data
        case 0x8C: hdsr = data
        case 0x90: hder = data
        case 0x94: hber = data
        case 0x98: hcsr = data
        case 0x9C: hir = data
        case 0xA0: vcr = data
        case 0xA4: vswr = data
        case 0xA8: vbsr = data
        case 0xAC: vdsr = data
        case 0xB0: vder = data
        case 0xB4: vber = data
        case 0xB8: vcsr = data
        case 0xBC: vcer = data
        case 0xC0:
            memc.soundRegisterLog.append(String(format: "t=%.4f SFR=%03X", Double(memc.ticks) / 24e6, data))
            sfr = data
            soundDMAEnableChanged()
        case 0xE0:
            let oldBpp = bppCode
            controlRegister = data
            if bppCode != oldBpp { for i in 0..<16 { rebuildDisplayColour(i) } }
        default:
            unknownWrite?(String(format: "VIDC write reg %02X = %06X", reg, data))
        }
    }

    static func rgb(_ v: UInt32) -> UInt32 {
        let r = v & 0xF, g = (v >> 4) & 0xF, b = (v >> 8) & 0xF
        return 0xFF00_0000 | (r * 17) << 16 | (g * 17) << 8 | (b * 17)
    }

    func rebuildDisplayColour(_ i: Int) {
        let d = palette[i]
        if bppCode == 3 {
            // 8 bpp: low nibble selects the palette entry, high nibble
            // directly drives R3, G2, G3 and B3.
            for hi in 0..<16 {
                let l = UInt32(hi << 4)
                let t = ((l >> 7) & 1) << 11 | ((l >> 5) & 3) << 6 | ((l >> 4) & 1) << 3
                displayColours[(hi << 4) | i] = Self.rgb(t | (d & 0x737))
            }
        } else {
            displayColours[i] = Self.rgb(d)
        }
    }

    // MARK: Derived timing

    public var bppCode: Int { Int((controlRegister >> 2) & 3) }
    public var bitsPerPixel: Int { 1 << bppCode }
    public var pixelClockMHz: Int { [8, 12, 16, 24][Int(controlRegister & 3)] }
    var hCyclePixels: Int { 2 * (Int((hcr >> 14) & 0x3FF) + 1) }
    var hBorderStart: Int { 2 * Int((hbsr >> 14) & 0x3FF) + 1 }
    var hBorderEnd: Int { 2 * Int((hber >> 14) & 0x3FF) + 1 }
    var displayOffset: Int { [19, 11, 7, 5][bppCode] }
    var hDisplayStart: Int { 2 * Int((hdsr >> 14) & 0x3FF) + displayOffset }
    var hDisplayEnd: Int { 2 * Int((hder >> 14) & 0x3FF) + displayOffset }
    var hCursorStart: Int { Int((hcsr >> 13) & 0x7FF) + 6 }
    var vCycle: Int { Int((vcr >> 14) & 0x3FF) + 1 }
    var vBorderStart: Int { Int((vbsr >> 14) & 0x3FF) + 1 }
    var vBorderEnd: Int { Int((vber >> 14) & 0x3FF) + 1 }
    var vDisplayStart: Int { Int((vdsr >> 14) & 0x3FF) + 1 }
    var vDisplayEnd: Int { Int((vder >> 14) & 0x3FF) + 1 }
    var vCursorStart: Int { Int((vcsr >> 14) & 0x3FF) + 1 }
    var vCursorEnd: Int { Int((vcer >> 14) & 0x3FF) + 1 }

    /// The clock VIDC divides for pixels: 24 MHz, or on IOEB machines
    /// 25.175 or 36 MHz as selected for VGA and SVGA monitors.
    public var baseClockHz = 24_000_000

    /// Line duration in 24 MHz ticks.
    var lineTicks: UInt64 {
        let halfTicksPerPixel: UInt64 = [6, 4, 3, 2][Int(controlRegister & 3)]
        var cycle = UInt64(hCyclePixels)
        if hcr == 0 { cycle = 1024 }
        return max(64, (cycle * halfTicksPerPixel * 12_000_000) / UInt64(baseClockHz))
    }

    /// Whether horizontal sync is being output (the line's first HSWR pixels).
    public var horizontalSyncActive: Bool {
        let next = scheduler.dueTime(.videoLine)
        guard next != .max else { return false }
        let line = lineTicks
        let pos = scheduler.now &+ line &- next
        let syncPixels = UInt64(2 * ((hswr >> 14) & 0x3FF) + 1)
        let halfTicksPerPixel: UInt64 = [6, 4, 3, 2][Int(controlRegister & 3)]
        return pos < syncPixels * halfTicksPerPixel * 12_000_000 / UInt64(baseClockHz)
    }

    // MARK: Line generation

    func lineEvent() {
        debugLineHook?(raster)
        var total = vCycle
        if vcr == 0 || total < 8 { total = 313 }

        if raster == vDisplayStart {
            memc.vptr = memc.vinit
            memc.cptr = memc.cinit
            ioc.setFlyback(false)
        }
        if raster == vDisplayEnd {
            ioc.setFlyback(true)
        }

        if raster == 0 { beginFrame() }
        renderLine(raster)

        raster += 1
        if raster >= total {
            endFrame()
            raster = 0
        }
        scheduler.schedule(.videoLine, at: scheduler.firingTime &+ lineTicks)
    }

    func beginFrame() {
        let left = hBorderStart, right = hBorderEnd
        let top = vBorderStart, bottom = vBorderEnd
        var w = right - left, h = bottom - top
        if w <= 0 || h <= 0 || w > 2048 || h > 1024 { w = 0; h = 0 }
        frameLeft = left; frameTop = top
        if w != frameWidth || h != frameHeight {
            frameWidth = w; frameHeight = h
            frameBuffer = [UInt32](repeating: 0xFF00_0000, count: w * h)
        }
    }

    func endFrame() {
        frameCount &+= 1
        let w = frameWidth, h = frameHeight
        if w > 0 && h > 0 {
            let sx = pixelClockMHz <= 8 ? 2 : 1
            let sy = vCycle < 400 ? 2 : 1
            lastFrame = VideoFrame(width: w, height: h, pixels: frameBuffer, frameNumber: frameCount,
                                   scaleX: sx, scaleY: sy, pixelClockMHz: pixelClockMHz, bitsPerPixel: bitsPerPixel)
            lastFrame.displayArea = displayArea
        } else {
            lastFrame = VideoFrame(width: 1, height: 1, pixels: [0xFF00_0000], frameNumber: frameCount,
                                   scaleX: 1, scaleY: 1, pixelClockMHz: pixelClockMHz, bitsPerPixel: bitsPerPixel)
        }
        frameCompleted?(lastFrame)
    }

    /// The display area within the frame, clipped to it.
    var displayArea: VideoFrame.Area? {
        let x0 = max(hDisplayStart - frameLeft, 0), x1 = min(hDisplayEnd - frameLeft, frameWidth)
        let y0 = max(vDisplayStart - frameTop, 0), y1 = min(vDisplayEnd - frameTop, frameHeight)
        guard x1 > x0, y1 > y0 else { return nil }
        return VideoFrame.Area(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    func renderLine(_ y: Int) {
        let inDisplayV = y >= vDisplayStart && y < vDisplayEnd
        let fy = y - frameTop
        let haveRow = frameWidth > 0 && fy >= 0 && fy < frameHeight
        let dStart = hDisplayStart, dEnd = hDisplayEnd
        let displayPixels = max(0, dEnd - dStart)

        // Video DMA for this line (consumes RAM bandwidth even if not visible).
        var fetched = 0
        if inDisplayV && memc.videoDMAEnabled && displayPixels > 0 {
            let bytes = min(4096, (displayPixels * bitsPerPixel + 7) / 8)
            let blocks = (bytes + 15) / 16
            lineBytes.withUnsafeMutableBufferPointer { dst in
                var p = memc.vptr
                for blk in 0..<blocks {
                    for w in 0..<4 {
                        let word = memc.dmaWord(p &+ UInt32(w * 4))
                        let o = blk * 16 + w * 4
                        if o + 3 < dst.count {
                            dst[o] = UInt8(truncatingIfNeeded: word); dst[o + 1] = UInt8(truncatingIfNeeded: word >> 8)
                            dst[o + 2] = UInt8(truncatingIfNeeded: word >> 16); dst[o + 3] = UInt8(truncatingIfNeeded: word >> 24)
                        }
                    }
                    p = p == memc.vend ? memc.vstart : p &+ 16
                }
                memc.vptr = p
            }
            fetched = blocks
            // DMA steals memory cycles from the CPU: 1N + 3S per 16 bytes.
            memc.ticks &+= UInt64(blocks) * (MasterClock.nCycle + 3 * MasterClock.sCycle)
        }

        // Cursor DMA: 8 bytes (32 pixels, 2 bpp) per cursor line.
        var cursorWord0: UInt32 = 0, cursorWord1: UInt32 = 0
        let inCursorV = y >= vCursorStart && y < vCursorEnd && inDisplayV
        if inCursorV && memc.videoDMAEnabled {
            cursorWord0 = memc.dmaWord(memc.cptr)
            cursorWord1 = memc.dmaWord(memc.cptr &+ 4)
            memc.cptr &+= 8
        }

        guard haveRow else { return }
        let rowBase = fy * frameWidth
        let left = frameLeft
        let bpp = bitsPerPixel
        let mask = (1 << bpp) - 1
        frameBuffer.withUnsafeMutableBufferPointer { fb in
            displayColours.withUnsafeBufferPointer { colours in
                lineBytes.withUnsafeBufferPointer { src in
                    for x in 0..<frameWidth {
                        let px = x + left
                        var c = borderColour
                        if inDisplayV && px >= dStart && px < dEnd {
                            let i = px - dStart
                            if fetched > 0 {
                                let bit = i * bpp
                                let byte = Int(src[bit >> 3])
                                c = colours[(byte >> (bit & 7)) & mask]
                            } else {
                                c = colours[0]
                            }
                        }
                        fb[rowBase + x] = c
                    }
                }
            }
            if inCursorV {
                let cx = hCursorStart
                for i in 0..<32 {
                    let w = i < 16 ? cursorWord0 : cursorWord1
                    let v = Int((w >> UInt32((i & 15) * 2)) & 3)
                    if v == 0 { continue }
                    let x = cx + i - left
                    if x >= 0 && x < frameWidth { fb[rowBase + x] = cursorColours[v] }
                }
            }
        }
    }

    // MARK: Sound

    /// Byte period in ticks (VIDC: SFR+2 µs per byte, 24 MHz clock).
    var soundByteTicks: UInt64 { MasterClock.ticks(microseconds: UInt64(sfr & 0xFF) + 2) }

    func soundDMAEnableChanged() {
        if memc.soundDMAEnabled && (sfr & 0x100) != 0 {
            if !scheduler.isScheduled(.sound) { scheduler.schedule(.sound, after: soundByteTicks * 16) }
        } else {
            scheduler.cancel(.sound)
        }
    }

    func soundEvent() {
        guard memc.soundDMAEnabled else { return }
        let base = memc.sptr
        let rate = 1_000_000.0 / Double((sfr & 0xFF) + 2)
        for w in 0..<4 {
            let word = memc.dmaWord(base &+ UInt32(w * 4))
            for b in 0..<4 {
                let byte = UInt8(truncatingIfNeeded: word >> UInt32(b * 8))
                soundHash = (soundHash ^ UInt64(byte)) &* 0x100_0000_01B3
                if byte > 1 { soundBytesNonSilent &+= 1 }
                if let sink = audioSink {
                    let ch = (w * 4 + b) & 7
                    let s = Self.logTable[Int(byte)]
                    let pos = Float(stereo[ch])
                    let rightGain: Float = pos == 0 ? 0.5 : (pos - 1) / 6
                    sink.audioSamples(left: s * (1 - rightGain), right: s * rightGain, count: 1, sampleRate: rate)
                }
            }
        }
        soundBytesOutput &+= 16
        memc.ticks &+= MasterClock.nCycle + 3 * MasterClock.sCycle
        memc.advanceSoundPointer()
        scheduler.schedule(.sound, at: scheduler.firingTime &+ soundByteTicks * 16)
    }

    static func makeLogTable() -> [Float] {
        // VIDC 8-bit logarithmic format: bit 0 sign (1 = negative),
        // bits 7-5 chord, bits 4-1 step.
        var t = [Float](repeating: 0, count: 256)
        for b in 0..<256 {
            let mag = b >> 1
            let chord = mag >> 4
            let step = mag & 15
            let linear = Float(((16 + step) << chord) - 16) / 4032.0
            t[b] = (b & 1) != 0 ? -linear : linear
        }
        return t
    }

    // MARK: Diagnostics

    /// The pointer's hotspot in frame pixels (top left of the hardware
    /// cursor, relative to the published frame), for scripted input.
    public var pointerPosition: (x: Int, y: Int) {
        (hCursorStart - frameLeft, vCursorStart - frameTop)
    }

    /// Where the pointer points, in frame pixels: the leftmost visible pixel
    /// of its top visible row (an arrow's tip, a hand's fingertip). RISC OS
    /// pads its pointer images, so this is often well inside
    /// `pointerPosition`, which is the image's top-left corner.
    public var pointerHotspot: (x: Int, y: Int) {
        let rows = max(0, min(64, vCursorEnd - vCursorStart))
        for row in 0..<rows {
            let w0 = memc.dmaWord(memc.cinit &+ UInt32(row * 8)), w1 = memc.dmaWord(memc.cinit &+ UInt32(row * 8 + 4))
            for i in 0..<32 where ((i < 16 ? w0 : w1) >> UInt32((i & 15) * 2)) & 3 != 0 {
                return (hCursorStart - frameLeft + i, vCursorStart - frameTop + row)
            }
        }
        return pointerPosition
    }

    public var soundSummary: [String: String] {
        ["sfr": String(format: "%03X", sfr), "bytesOutput": "\(soundBytesOutput)", "nonSilent": "\(soundBytesNonSilent)", "hash": String(format: "%016llX", soundHash),
         "stereo": stereo.map { String($0) }.joined(separator: ","), "scheduled": "\(scheduler.isScheduled(.sound))",
         "sptr": hex32(memc.sptr), "sendCurrent": hex32(memc.sendCurrent), "sstart": hex32(memc.sstart), "registerLog": memc.soundRegisterLog.elements.suffix(24).joined(separator: " | ")]
    }

    public var timingSummary: [String: Int] {
        ["hCycle": hCyclePixels, "hBorderStart": hBorderStart, "hBorderEnd": hBorderEnd,
         "hDisplayStart": hDisplayStart, "hDisplayEnd": hDisplayEnd, "vCycle": vCycle,
         "vBorderStart": vBorderStart, "vBorderEnd": vBorderEnd, "vDisplayStart": vDisplayStart,
         "vDisplayEnd": vDisplayEnd, "bpp": bitsPerPixel, "pixelClockMHz": pixelClockMHz,
         "cursorX": hCursorStart, "cursorYStart": vCursorStart, "cursorYEnd": vCursorEnd]
    }
}

// MARK: - Snapshot state

extension VIDC {
    func saveState(_ w: inout StateWriter) {
        w.u32s(palette); w.u32(border); w.u32s(cursorPalette); w.data(stereo)
        for v in [hcr, hswr, hbsr, hdsr, hder, hber, hcsr, hir, vcr, vswr, vbsr, vdsr, vder, vber, vcsr, vcer, sfr, controlRegister] { w.u32(v) }
        w.i64(raster); w.u64(lineTickFraction)
        w.i64(frameWidth); w.i64(frameHeight); w.i64(frameLeft); w.i64(frameTop); w.u32s(frameBuffer)
        w.u64(frameCount)
        let f = lastFrame
        w.i64(f.width); w.i64(f.height); w.u32s(f.pixels); w.u64(f.frameNumber)
        w.i64(f.scaleX); w.i64(f.scaleY); w.i64(f.pixelClockMHz); w.i64(f.bitsPerPixel)
        w.u64(soundBytesOutput); w.u64(soundBytesNonSilent); w.u64(soundHash)
    }

    func loadState(_ r: inout StateReader) throws {
        palette = try r.u32s(count: 16); border = try r.u32(); cursorPalette = try r.u32s(count: 4)
        stereo = try r.data(max: 8)
        guard stereo.count == 8 else { throw SnapshotError.corrupt("stereo image registers") }
        hcr = try r.u32(); hswr = try r.u32(); hbsr = try r.u32(); hdsr = try r.u32()
        hder = try r.u32(); hber = try r.u32(); hcsr = try r.u32(); hir = try r.u32()
        vcr = try r.u32(); vswr = try r.u32(); vbsr = try r.u32(); vdsr = try r.u32()
        vder = try r.u32(); vber = try r.u32(); vcsr = try r.u32(); vcer = try r.u32()
        sfr = try r.u32(); controlRegister = try r.u32()
        raster = try r.i64(); lineTickFraction = try r.u64()
        frameWidth = try r.i64(); frameHeight = try r.i64(); frameLeft = try r.i64(); frameTop = try r.i64()
        frameBuffer = try r.u32s()
        guard frameBuffer.count == frameWidth * frameHeight else { throw SnapshotError.corrupt("frame buffer size") }
        frameCount = try r.u64()
        let w = try r.i64(), h = try r.i64(), px = try r.u32s(), n = try r.u64()
        let sx = try r.i64(), sy = try r.i64(), clk = try r.i64(), bpp = try r.i64()
        guard px.count == w * h else { throw SnapshotError.corrupt("last frame size") }
        lastFrame = VideoFrame(width: w, height: h, pixels: px, frameNumber: n, scaleX: sx, scaleY: sy, pixelClockMHz: clk, bitsPerPixel: bpp)
        if w == frameWidth && h == frameHeight { lastFrame.displayArea = displayArea }
        soundBytesOutput = try r.u64(); soundBytesNonSilent = try r.u64(); soundHash = try r.u64()
        // Derived lookup tables.
        for i in 0..<16 { rebuildDisplayColour(i) }
        borderColour = Self.rgb(border)
        for i in 0..<4 { cursorColours[i] = Self.rgb(cursorPalette[i]) }
    }
}
