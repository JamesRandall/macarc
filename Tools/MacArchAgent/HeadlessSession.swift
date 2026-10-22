import ArchimedesCore
import Foundation

/// The headless server's own machine: it only runs during tool calls.
public final class HeadlessSession: AgentSession, AgentContext {
    public private(set) var machine: Machine?
    public let isAttached = false
    public let rewinder = Rewinder()
    public var heldBetweenCalls: Bool { get { true } set {} }
    public let runsBetweenCalls = false
    public var isRecording: Bool { false }
    let lock = NSLock()

    /// A machine for `configuration`, booted to the desktop (from a CMOS
    /// reset); none if there's no ROM yet.
    public init(configuration: MachineConfiguration?) throws {
        guard var c = configuration, !c.romPaths.isEmpty else { return }
        c.powerOnKeys = [0x34]
        let m = try Machine(configuration: c)
        m.powerOn()
        replace(with: m)
        _ = runUntilIdle(self, maxSeconds: 60)
    }

    public func perform<T>(_ body: @escaping (AgentSession) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(self)
    }

    public func advance(ticks: UInt64) {
        guard let m = machine else { return }
        m.run(ticks: ticks)
        rewinder.captureIfDue(m)
    }

    public func replace(with m: Machine) {
        machine = m
        rewinder.keyframe(m)
    }

    public func powerCycle(_ change: HardwareChange?) throws {
        let old = machine
        var c = old?.configuration ?? MachineConfiguration()
        if let change {
            if let model = change.model {
                let rom = c.romPaths
                c = MachineConfiguration(model: model)
                c.romPaths = rom
            }
            if let cpu = change.cpu { c.cpu = cpu }
            if let ram = change.ramKB { c.ramKB = ram }
            if let rom = change.romPath { c.romPaths = [rom] }
            if let discs = change.hardDiscs { c.hardDiscs = discs }
            if let mon = change.monitor { c.monitorType = mon }
        }
        c.powerOnKeys = change?.cmosReset == true || old == nil ? [0x34] : []
        guard !c.romPaths.isEmpty else { throw ToolError(message: "no ROM: pass rom") }
        let reuse = change == nil || (change?.model == nil && change?.romPath == nil && change?.hardDiscs == nil && change?.cpu == nil && change?.ramKB == nil && change?.monitor == nil)
        let m: Machine
        if reuse, let old {
            m = old
            if change?.cmosReset == true {
                // A fresh machine with the same parts, so Delete is held at power-on.
                let n = try Machine(configuration: c, rom: old.rom, hardDiscs: old.hardDiscImages)
                for (i, d) in old.fdc.drives.enumerated() { n.fdc.drives[i].disc = d.disc }
                n.debugger.adopt(old.debugger)
                n.powerOn()
                rewinder.reset()
                replace(with: n)
                return
            }
            m.powerOn()
        } else {
            m = try Machine(configuration: c)
            if let old {
                for (i, d) in old.fdc.drives.enumerated() { m.fdc.drives[i].disc = d.disc }
                if let d = old.debuggerIfCreated { m.debugger.adopt(d) }
            }
            m.powerOn()
        }
        rewinder.reset()
        replace(with: m)
    }

    public func startRecording(to url: URL) throws {
        throw ToolError(message: "recording needs the MacArch app (macarch-mcp --attach)")
    }

    public func stopRecording() -> Bool { false }
}
