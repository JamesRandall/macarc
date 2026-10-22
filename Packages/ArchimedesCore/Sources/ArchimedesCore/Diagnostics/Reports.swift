import Foundation

public struct MachineStatus: Codable, Sendable {
    public var model: String
    public var cpu: String
    public var ramKB: Int
    public var romVersion: String
    public var romSHA256: String
    public var poweredOn: Bool
    public var guestTicks: UInt64
    public var guestSeconds: Double
    public var instructions: UInt64
    public var pc: String
    public var mode: String
    public var irqDisabled: Bool
    public var fiqDisabled: Bool
    public var frameCount: UInt64
    public var display: [String: Int]
    public var floppies: [FloppyStatus]
    public var lastException: String?
    public var recentDeviceLog: [String]
}

public struct FloppyStatus: Codable, Sendable {
    public var drive: Int
    public var path: String?
    public var format: String?
    public var sha256: String?
    public var modified: Bool
    public var writeProtected: Bool
    public var headTrack: Int
}

public struct RegisterDump: Codable, Sendable {
    public var registers: [String: String]
    public var r15: String
    public var pc: String
    public var flags: String
    public var mode: String
    public var irqDisabled: Bool
    public var fiqDisabled: Bool
    public var banked: [String: [String]]?
    public var disassembly: String
}

public struct DiagnosticsSummary: Codable, Sendable {
    public var exceptionCounts: [String: UInt64]
    public var lastException: String?
    public var interruptCounts: [String: UInt64]
    public var iocIRQA: String
    public var iocIRQB: String
    public var iocFIQ: String
    public var memc: [String: String]
    public var floppyCommands: UInt64
    public var recentFloppyTrace: [String]
    public var topSWIs: [String: UInt64]
    public var recentText: String
    public var deviceLog: [String]
    public var keyboard: String
    public var sound: [String: String]
}

public func hex32(_ v: UInt32) -> String { String(format: "0x%08X", v) }

extension Machine {
    public func status() -> MachineStatus {
        let le = cpu.lastException.map { "\($0.vector) at \(hex32($0.address)) (instruction #\($0.instructionCount))" }
        return MachineStatus(
            model: configuration.model.rawValue, cpu: configuration.cpu.rawValue, ramKB: configuration.ramKB,
            romVersion: rom.versionString, romSHA256: rom.sha256, poweredOn: poweredOn,
            guestTicks: ticks, guestSeconds: seconds, instructions: cpu.instructionCount,
            pc: hex32(cpu.pc), mode: cpu.mode.description,
            irqDisabled: cpu.psr & ARM2<MEMC>.flagI != 0, fiqDisabled: cpu.psr & ARM2<MEMC>.flagF != 0,
            frameCount: vidc.frameCount, display: vidc.timingSummary,
            floppies: floppyStatus(), lastException: le, recentDeviceLog: deviceLog.last(10))
    }

    public func floppyStatus() -> [FloppyStatus] {
        fdc.drives.enumerated().compactMap { (i, d) in
            guard let disc = d.disc else { return i == 0 ? FloppyStatus(drive: 0, path: nil, format: nil, sha256: nil, modified: false, writeProtected: false, headTrack: d.headTrack) : nil }
            return FloppyStatus(drive: i, path: disc.sourcePath, format: disc.geometry.formatName, sha256: disc.sha256,
                                modified: disc.isModified, writeProtected: disc.writeProtected, headTrack: d.headTrack)
        }
    }

    public func registerDump(banked: Bool = false) -> RegisterDump {
        var regs: [String: String] = [:]
        for i in 0..<15 { regs["r\(i)"] = hex32(cpu.r[i]) }
        let p = cpu.psr
        let flags = (p & 0x8000_0000 != 0 ? "N" : "n") + (p & 0x4000_0000 != 0 ? "Z" : "z") + (p & 0x2000_0000 != 0 ? "C" : "c") + (p & 0x1000_0000 != 0 ? "V" : "v")
        var b: [String: [String]]? = nil
        if banked {
            b = [:]
            for m in [ARM2<MEMC>.Mode.user, .fiq, .irq, .supervisor] {
                b![m.description] = cpu.bankedRegisters(m).enumerated().map { "r\($0.offset + 8)=\(hex32($0.element))" }
            }
        }
        let instr = memc.debugReadWord(cpu.pc, space: .logical) ?? 0
        return RegisterDump(registers: regs, r15: hex32(cpu.r15), pc: hex32(cpu.pc), flags: flags,
                            mode: cpu.mode.description, irqDisabled: p & 0x0800_0000 != 0, fiqDisabled: p & 0x0400_0000 != 0,
                            banked: b, disassembly: "\(hex32(cpu.pc)): \(Disassembler.disassemble(instr, at: cpu.pc))")
    }

    public func disassemble(at address: UInt32, count: Int) -> [String] {
        (0..<count).map { i in
            let a = address &+ UInt32(i * 4)
            guard let w = memc.debugReadWord(a, space: .logical) else { return "\(hex32(a)): <unmapped>" }
            return "\(hex32(a)): \(String(format: "%08X", w))  \(Disassembler.disassemble(w, at: a))"
        }
    }

    public func diagnostics() -> DiagnosticsSummary {
        let names = ["reset", "undefined", "swi", "prefetchAbort", "dataAbort", "addressException", "irq", "fiq"]
        var ex: [String: UInt64] = [:]
        for (i, n) in names.enumerated() { ex[n] = cpu.exceptionCounts[i] }
        let irqNames = ["A0 printerBusy", "A1 ring", "A2 printerAck", "A3 vsync", "A4 powerOn", "A5 timer0", "A6 timer1", "A7 force",
                        "B0 poduleFIQ", "B1 sound", "B2 serial", "B3 hd", "B4 discChanged", "B5 podule", "B6 kbdTx", "B7 kbdRx",
                        "F0 floppyDRQ", "F1 floppyIRQ", "F2 econet", "F3", "F4", "F5", "F6", "F7 force"]
        var ic: [String: UInt64] = [:]
        for (i, n) in irqNames.enumerated() where ioc.irqCounts[i] > 0 { ic[n] = ioc.irqCounts[i] }
        let top = swiCounts.sorted { $0.value > $1.value }.prefix(200)
        var swis: [String: UInt64] = [:]
        for (k, v) in top { swis[String(format: "&%X", k)] = v }
        let m: [String: String] = [
            "pageSize": "\(4 << memc.pageSizeCode)KB", "osMode": "\(memc.osMode)", "videoDMA": "\(memc.videoDMAEnabled)",
            "soundDMA": "\(memc.soundDMAEnabled)", "romOverlay": "\(memc.romOverlay)", "vinit": hex32(memc.vinit),
            "vstart": hex32(memc.vstart), "vend": hex32(memc.vend), "cinit": hex32(memc.cinit), "highROMSpeed": "\(memc.highROMSpeed)",
            "iocTimerLatches": ioc.timerLatches.map { String($0) }.joined(separator: ","),
        ]
        let le = cpu.lastException.map { "\($0.vector) at \(hex32($0.address)) (instruction #\($0.instructionCount))" }
        let kb = "state=\(keyboard.state) keyScan=\(keyboard.keyScan) mouseScan=\(keyboard.mouseScan) queued=\(keyboard.queue.count) held=\(keyboard.held.sorted().map { String(format: "%02X", $0) })"
        return DiagnosticsSummary(
            exceptionCounts: ex, lastException: le, interruptCounts: ic,
            iocIRQA: String(format: "status=%02X mask=%02X", ioc.irqAStatus, ioc.irqAMask),
            iocIRQB: String(format: "status=%02X mask=%02X", ioc.irqBStatus, ioc.irqBMask),
            iocFIQ: String(format: "status=%02X mask=%02X", ioc.fiqStatus, ioc.fiqMask),
            memc: m, floppyCommands: fdc.commandCount, recentFloppyTrace: fdc.trace.last(16).map { $0.description },
            topSWIs: swis, recentText: String(recentText.suffix(1500)), deviceLog: deviceLog.last(20), keyboard: kb,
            sound: vidc.soundSummary)
    }
}

public enum JSON {
    public static func encode<T: Encodable>(_ v: T, pretty: Bool = true) -> String {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return (try? String(data: e.encode(v), encoding: .utf8)) ?? "{}"
    }
}
