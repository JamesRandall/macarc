import Foundation

/// Every device's state, for the debugger's Hardware view.
public struct HardwareSection: Sendable, Identifiable {
    public struct Row: Sendable, Identifiable {
        public var label: String
        public var value: String
        public var id: String { label }
    }

    public var name: String
    public var rows: [Row]
    public var id: String { name }
}

extension Machine {
    static func hex(_ v: UInt32, _ digits: Int = 2) -> String { "&" + String(format: "%0\(digits)X", v) }
    static func bits(_ v: UInt8, _ names: [String]) -> String {
        let set = (0..<8).filter { v & (1 << $0) != 0 }.map { names[$0] }
        return hex(UInt32(v)) + (set.isEmpty ? "" : "  " + set.joined(separator: " "))
    }

    public var hardwareState: [HardwareSection] {
        typealias Row = HardwareSection.Row
        var out: [HardwareSection] = []

        let irqA = ["printer", "serial ring", "index/ack", "vsync", "power on", "timer 0", "timer 1", "force"]
        let irqB = ["podule FIQ", "sound", "serial", "hard disc", "floppy/disc changed", "podule", "keyboard tx", "keyboard rx"]
        let fiq = ["floppy data", "floppy IRQ", "Econet", "-", "serial", "-", "podule", "force"]
        let chip = ioc
        var iocRows = [
            Row(label: "IRQ A status", value: Self.bits(ioc.irqAStatus, irqA)),
            Row(label: "IRQ A mask", value: Self.bits(ioc.irqAMask, irqA)),
            Row(label: "IRQ B status", value: Self.bits(ioc.irqBStatus, irqB)),
            Row(label: "IRQ B mask", value: Self.bits(ioc.irqBMask, irqB)),
            Row(label: "FIQ status", value: Self.bits(ioc.fiqStatus, fiq)),
            Row(label: "FIQ mask", value: Self.bits(ioc.fiqMask, fiq)),
            Row(label: "Control", value: Self.hex(UInt32(ioc.control))),
        ]
        for t in 0..<4 {
            let name = ["timer 0", "timer 1", "timer 2 (baud)", "timer 3 (keyboard)"][t]
            iocRows.append(Row(label: name, value: "count \(chip.timerCount(t)), latch \(chip.timerLatches[t])"))
        }
        if configuration.model.hasNewIO == false {
            iocRows.append(Row(label: "Latch A", value: Self.hex(UInt32(chip.latchA))))
            iocRows.append(Row(label: "Latch B", value: Self.hex(UInt32(chip.latchB))))
        }
        out.append(HardwareSection(name: "IOC", rows: iocRows))

        let m = memc
        out.append(HardwareSection(name: "MEMC", rows: [
            Row(label: "Page size", value: "\(4 << Int(m.pageSizeCode)) KB"),
            Row(label: "RAM", value: "\(m.ramSize / 1024) KB, \(24 / Int(m.sCycle)) MHz"),
            Row(label: "Mode", value: m.osMode ? "OS mode" : "-"),
            Row(label: "Video DMA", value: m.videoDMAEnabled ? "on" : "off"),
            Row(label: "Sound DMA", value: m.soundDMAEnabled ? "on" : "off"),
            Row(label: "ROM speed", value: "high \(m.highROMSpeed), low \(m.lowROMSpeed)"),
            Row(label: "Vinit / Vstart / Vend", value: "\(Self.hex(m.vinit, 6)) / \(Self.hex(m.vstart, 6)) / \(Self.hex(m.vend, 6))"),
            Row(label: "Vptr", value: Self.hex(m.vptr, 6)),
            Row(label: "Cinit", value: Self.hex(m.cinit, 6)),
            Row(label: "Sstart / SendN / Sptr", value: "\(Self.hex(m.sstart, 6)) / \(Self.hex(m.sendNext, 6)) / \(Self.hex(m.sptr, 6))"),
            Row(label: "ROM overlay", value: m.romOverlay ? "on (reset)" : "off"),
            Row(label: "Mapped pages", value: "\(m.camEntries.filter { $0 != .max }.count) of \(m.camEntries.count)"),
        ] + (m.cache.map { c in [
            Row(label: "ARM3 cache", value: c.enabled ? "on" : "off"),
            Row(label: "Cacheable / updateable / disruptive", value: "\(Self.hex(c.cacheable, 8)) / \(Self.hex(c.updateable, 8)) / \(Self.hex(c.disruptive, 8))"),
        ] } ?? [])))

        let v = vidc
        var video = [
            Row(label: "Beam", value: "line \(v.raster), frame \(v.frameCount)"),
            Row(label: "Control", value: "\(Self.hex(v.controlRegister, 3)): \(v.bitsPerPixel) bpp, \(v.pixelClockMHz) MHz pixels"),
            Row(label: "Horizontal", value: String(format: "cycle %d, sync %d, border %d-%d, display %d-%d", v.hCyclePixels, 2 * ((v.hswr >> 14) & 0x3FF) + 1, v.hBorderStart, v.hBorderEnd, v.hDisplayStart, v.hDisplayEnd)),
            Row(label: "Vertical", value: String(format: "cycle %d, sync %d, border %d-%d, display %d-%d", v.vCycle, (v.vswr >> 14) & 0x3FF, v.vBorderStart, v.vBorderEnd, v.vDisplayStart, v.vDisplayEnd)),
            Row(label: "Cursor", value: "x \(v.hCursorStart), lines \(v.vCursorStart)-\(v.vCursorEnd)"),
            Row(label: "Base clock", value: String(format: "%.3f MHz", Double(v.baseClockHz) / 1e6)),
            Row(label: "Border", value: Self.hex(v.border & 0x1FFF, 4)),
        ]
        for i in 0..<16 { video.append(Row(label: "Palette \(i)", value: Self.hex(v.palette[i] & 0x1FFF, 4))) }
        for i in 1..<4 { video.append(Row(label: "Cursor colour \(i)", value: Self.hex(v.cursorPalette[i] & 0x1FFF, 4))) }
        out.append(HardwareSection(name: "VIDC", rows: video))

        out.append(HardwareSection(name: "Sound", rows: [
            Row(label: "Sample period", value: "\((v.sfr & 0xFF) + 2) µs per byte"),
            Row(label: "Stereo positions", value: v.stereo.map(String.init).joined(separator: " ")),
            Row(label: "DMA", value: m.soundDMAEnabled ? "on" : "off"),
        ]))

        if let sio = superIO {
            let f = sio.fdc
            out.append(HardwareSection(name: "Floppy (82C711, 765 core)", rows: [
                Row(label: "DOR", value: Self.hex(UInt32(f.dor))),
                Row(label: "Data rate", value: ["500 kbit/s", "300 kbit/s", "250 kbit/s", "1 Mbit/s"][Int(f.dataRate & 3)]),
                Row(label: "Phase", value: "\(f.phase)" + (f.job != .none ? " (\(f.job))" : "")),
                Row(label: "C H R N EOT", value: "\(f.c) \(f.h) \(f.r) \(f.n) \(f.eot)"),
                Row(label: "Interrupt / DRQ", value: "\(f.interrupt ? "INT" : "-") \(f.dataRequest ? "DRQ" : "-")"),
            ] + (0..<2).map { Row(label: "Drive \($0)", value: "track \(f.drives[$0].headTrack)" + (f.drives[$0].disc.map { ", " + (($0.sourcePath ?? "disc") as NSString).lastPathComponent } ?? ", empty")) }))
            out.append(HardwareSection(name: "IOEB", rows: [
                Row(label: "Video clock", value: ["24 MHz", "25.175 MHz", "36 MHz", "24 MHz"][Int(sio.clockSelect & 3)]),
            ]))
            if let ide = sio.ide {
                out.append(HardwareSection(name: "IDE", rows: [
                    Row(label: "Status / error", value: "\(Self.hex(UInt32(ide.status))) / \(Self.hex(UInt32(ide.errorReg)))"),
                    Row(label: "Drive / C H S", value: "\(ide.unit) / \(ide.cylinder) \(ide.driveHead & 15) \(ide.sectorNumber)"),
                    Row(label: "Command", value: Self.hex(UInt32(ide.command))),
                ] + (0..<2).map { u in Row(label: "Drive \(u + 4)", value: ide.drives[u].map { "\(($0.path as NSString).lastPathComponent), \($0.geometry.cylinders)×\($0.geometry.heads)×\($0.geometry.sectorsPerTrack)" } ?? "none") }))
            }
        } else {
            let f = fdc
            out.append(HardwareSection(name: "Floppy (WD1772)", rows: [
                Row(label: "Status", value: Self.hex(UInt32(f.status))),
                Row(label: "Track / sector / data", value: "\(f.trackRegister) / \(f.sectorRegister) / \(Self.hex(UInt32(f.dataRegister)))"),
                Row(label: "Command", value: f.command.rawValue + (f.command == .idle ? "" : ", phase \(f.phase)")),
                Row(label: "Next event", value: scheduler.isScheduled(.floppy) ? "in \(scheduler.dueTime(.floppy) &- scheduler.now) ticks" : "none"),
                Row(label: "Selected", value: f.selectedDrive.map { "drive \($0), side \(f.side), " + (f.doubleDensity ? "double density" : "single density") } ?? "none"),
            ] + (0..<2).map { Row(label: "Drive \($0)", value: "track \(f.drives[$0].headTrack)" + (f.drives[$0].disc.map { ", " + (($0.sourcePath ?? "disc") as NSString).lastPathComponent } ?? ", empty")) }))
        }
        if let h = hdc {
            out.append(HardwareSection(name: "Hard disc (HD63463)", rows: [
                Row(label: "Status / SSB", value: "\(Self.hex(UInt32(h.status))) / \(Self.hex(UInt32(h.ssb)))"),
                Row(label: "Command", value: Self.hex(UInt32(h.command))),
                Row(label: "Specified", value: h.specified ? "\(h.nc + 1) cylinders, \(h.nh + 1) heads, \(h.ns + 1) sectors" : "no"),
                Row(label: "Data request", value: h.dataRequest ? "yes" : "no"),
            ] + (0..<2).map { u in Row(label: "Drive \(u + 4)", value: h.drives[u].map { "\(($0.path as NSString).lastPathComponent), cylinder \(h.cylinder[u + 1])" } ?? "none") }))
        }

        out.append(HardwareSection(name: "Keyboard", rows: [
            Row(label: "LEDs", value: Self.bits(keyboard.leds, ["Caps Lock", "Num Lock", "Scroll Lock", "-", "-", "-", "-", "-"])),
        ]))
        let (secs, _) = rtc.nowSeconds
        out.append(HardwareSection(name: "Clock and CMOS (PCF8583)", rows: [
            Row(label: "Time", value: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(secs)))),
            Row(label: "Floppies / hard discs / IDE", value: "\(rtc.ram[Self.cmosDrives] & 7) / \((rtc.ram[Self.cmosDrives] >> 3) & 7) / \(rtc.ram[Self.cmosDrives] >> 6)"),
        ]))
        return out
    }
}
