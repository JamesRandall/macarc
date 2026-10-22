import Foundation

/// The "new I/O" of the A5000, A4000, A3010 and A3020: an 82C711 combined
/// I/O controller in IOC bank 1, addressed by PC port number
/// ((address >> 2) & &3FF), and the IOEB in bank 5.
///
///   &1F0-&1F7, &3F6  IDE task file (data port word-wide at bank 1 +&7C0)
///   &3F2-&3F7        floppy controller (765 core)
///   &278, &279       printer data and status
///   &3F0, &3F1       configuration mode (&55 &55 to enter, &AA to leave)
///
/// Serial ports are not modelled beyond answering the 82C711's presence
/// check (&3FF reads &55).
public final class SuperIO {
    public let fdc: FDC765
    public let ide: IDEController?
    unowned(unsafe) let vidc: VIDC

    var configKeys = 0
    var configIndex: UInt8 = 0
    var configRegisters = [UInt8](repeating: 0, count: 16)
    var printerData: UInt8 = 0

    /// IOEB video clock select (0: 24 MHz, 1: 25.175 MHz, 2: 36 MHz).
    public private(set) var clockSelect: UInt8 = 0
    var syncInvert = false
    /// The A3010's joystick ports, read through the IOEB.
    let joystickPorts: Bool
    /// The monitor plugged in, which RISC OS 3.1 reads from the ID lines
    /// to pick a screen mode when MonitorType is Auto.
    let monitor: MonitorType

    init(fdc: FDC765, ide: IDEController?, vidc: VIDC, joystickPorts: Bool, monitor: MonitorType = .standard) {
        self.fdc = fdc; self.ide = ide; self.vidc = vidc; self.joystickPorts = joystickPorts; self.monitor = monitor
    }

    func reset() {
        configKeys = 0
        setClock(0)
        fdc.reset()
        ide?.reset()
    }

    // MARK: 82C711 (bank 1)

    static func port(_ a: UInt32) -> Int { Int((a >> 2) & 0x3FF) }

    static let trace = ProcessInfo.processInfo.environment["MACARCH_SIO_TRACE"] != nil
    /// MACARCH_SIO_TRACE=1: every 82C711 and IOEB access to stderr.
    func t(_ s: @autoclosure () -> String) { if Self.trace { FileHandle.standardError.write((s() + "\n").data(using: .utf8)!) } }

    func read(_ a: UInt32) -> UInt32 {
        let r = readPort(a)
        t(String(format: "SIO read %07X port %03X -> %02X", a, Self.port(a), r))
        return r
    }

    func readPort(_ a: UInt32) -> UInt32 {
        let p = Self.port(a)
        if a & 0xFFF == 0x7C0, let ide { return UInt32(ide.readData()) }
        if configKeys == 2 && p == 0x3F1 { return UInt32(configRegisters[Int(configIndex & 15)]) }
        switch p {
        case 0x1F0...0x1F7, 0x3F6: return UInt32(ide?.read(port: p) ?? 0xFF)
        case 0x3F0...0x3F7: return UInt32(fdc.read(port: p))
        case 0x3FF: return 0x55 // serial scratch register: the chip is present
        case 0x279: return 0xDF // printer: not busy, selected, no error
        default: return 0xFF
        }
    }

    func write(_ a: UInt32, _ busValue: UInt32) {
        t(String(format: "SIO write %07X port %03X = %08X", a, Self.port(a), busValue))
        let p = Self.port(a)
        let v = UInt8(truncatingIfNeeded: busValue >> 16)
        if a & 0xFFF == 0x7C0, let ide { ide.writeData(UInt16(truncatingIfNeeded: busValue >> 16)); return }
        if p == 0x3F0 {
            if configKeys < 2 {
                configKeys = v == 0x55 ? configKeys + 1 : 0
                if configKeys > 0 { return }
            } else {
                if v == 0xAA { configKeys = 0 } else { configIndex = v }
                return
            }
        } else if configKeys < 2 {
            configKeys = 0
        }
        if configKeys == 2 && p == 0x3F1 { configRegisters[Int(configIndex & 15)] = v; return }
        switch p {
        case 0x1F0...0x1F7, 0x3F6: ide?.write(port: p, v)
        case 0x3F0...0x3F7: fdc.write(port: p, v)
        case 0x278: printerData = v
        default: break
        }
    }

    // MARK: Floppy DMA (DACK range &3012000-&302A000)

    static func isDACK(_ a: UInt32) -> Bool { a >= 0x0301_2000 && a <= 0x0302_A000 }

    func dmaRead(_ a: UInt32) -> UInt32 { UInt32(fdc.dmaRead(terminal: a == 0x0302_A000, address: a)) }
    func dmaWrite(_ a: UInt32, _ busValue: UInt32) { fdc.dmaWrite(UInt8(truncatingIfNeeded: busValue >> 16), terminal: a == 0x0302_A000) }

    // MARK: IOEB (bank 5)

    func readIOEB(_ a: UInt32) -> UInt32 {
        t(String(format: "IOEB read %07X", a))
        switch a & 0xF8 {
        case 0x50: return 0x05 // device ID: IOEB
        case 0x70:
            // Monitor ID lines. A standard 15 kHz monitor reads &E with bit 0
            // following horizontal sync; a multisync &B with bit 2 following
            // it; a colour VGA monitor &E with no sync on the lines.
            let hs = vidc.horizontalSyncActive != syncInvert
            switch monitor {
            case .standard: return 0x0E | (hs ? 1 : 0)
            case .multisync: return 0x0B | (hs ? 4 : 0)
            case .vga: return 0x0E
            }
        case 0x78: return joystickPorts ? 0x7F : 0xFF // A3010 joysticks: nothing pressed
        default: return 0xFF
        }
    }

    func writeIOEB(_ a: UInt32, _ busValue: UInt32) {
        t(String(format: "IOEB write %07X = %08X", a, busValue))
        guard a & 0xF8 == 0x48 else { return }
        let v = UInt8(truncatingIfNeeded: busValue >> 16)
        setClock(v & 3)
        syncInvert = v & 4 != 0
    }

    func setClock(_ c: UInt8) {
        clockSelect = c
        vidc.baseClockHz = [24_000_000, 25_175_000, 36_000_000, 24_000_000][Int(c & 3)]
    }

    // MARK: Snapshot

    func saveState(_ w: inout StateWriter) {
        w.u32(UInt32(configKeys)); w.u8(configIndex); w.raw(configRegisters); w.u8(printerData)
        w.u8(clockSelect); w.bool(syncInvert)
        fdc.saveState(&w)
        if let ide { ide.saveState(&w) }
    }

    func loadState(_ r: inout StateReader) throws {
        configKeys = Int(try r.u32()); configIndex = try r.u8(); configRegisters = try r.raw(16); printerData = try r.u8()
        setClock(try r.u8()); syncInvert = try r.bool()
        try fdc.loadState(&r)
        if let ide { try ide.loadState(&r) }
    }
}
