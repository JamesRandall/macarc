import ArchimedesCore
import Foundation
import MacArchAgent
import Observation

/// Lets `macarch-mcp --attach` drive this window's machine: tools run on
/// the emulation thread, between slices, so the agent sees exactly what the
/// user does. A tool that runs the machine advances it faster than real
/// time; the window catches up afterwards.
final class AppAgentContext: DebugAdapterHost, @unchecked Sendable {
    let host: EmulatorHost
    /// The window's controller, told when an agent changes the hardware.
    nonisolated(unsafe) weak var controller: MachineController?

    init(host: EmulatorHost, controller: MachineController) {
        self.host = host
        self.controller = controller
    }

    final class Session: AgentSession {
        let s: EmulatorHost.Session
        unowned let context: AppAgentContext
        init(_ s: EmulatorHost.Session, context: AppAgentContext) { self.s = s; self.context = context }

        var machine: Machine? { s.machine }
        let isAttached = true
        var rewinder: Rewinder { s.rewinder }
        var heldBetweenCalls: Bool {
            get { s.host.heldForAgent }
            set { s.host.heldForAgent = newValue }
        }
        let runsBetweenCalls = true

        func advance(ticks: UInt64) {
            // A network's machine runs with the rest of its network, in step.
            if s.host.isStation, let network = s.host.network {
                network.runInline(ticks: ticks, including: s.host)
            } else {
                s.machine.run(ticks: ticks)
            }
            s.rewinder.captureIfDue(s.machine)
        }

        func replace(with m: Machine) {
            s.replace(with: m, keepHistory: true)
            s.rewinder.keyframe(m)
            context.hardwareChanged(m.configuration)
        }

        func powerCycle(_ change: HardwareChange?) throws {
            let old = s.machine
            if s.host.isStation && change != nil {
                throw ToolError(message: "a network's machine has its hardware set in the Network Studio's inspector; power_cycle without changes switches it off and on")
            }
            guard let change else {
                s.host.restoreProfileCMOS(into: old)
                old.powerOn()
                s.rewinder.reset()
                s.rewinder.keyframe(old)
                return
            }
            var c = old.configuration
            if let model = change.model, model != c.model {
                c = MachineConfiguration(model: model)
                c.romPaths = old.configuration.romPaths
            }
            if let cpu = change.cpu { c.cpu = cpu }
            if let ram = change.ramKB { c.ramKB = ram }
            if let rom = change.romPath { c.romPaths = [rom] }
            if let discs = change.hardDiscs { c.hardDiscs = discs }
            if let mon = change.monitor { c.monitorType = mon }
            let rom = change.romPath == nil ? old.rom : try ROMImage.load(paths: c.romPaths)
            let cmos = AppSettings.cmosPath(for: rom, model: c.model)
            if change.cmosReset || !FileManager.default.fileExists(atPath: cmos) {
                c.cmosPath = nil
                c.powerOnKeys = [0x34]
            } else {
                c.cmosPath = cmos
                c.powerOnKeys = []
            }
            let m = try Machine(configuration: c, rom: rom)
            for (i, d) in old.fdc.drives.enumerated() { m.fdc.drives[i].disc = d.disc }
            if let d = old.debuggerIfCreated { m.debugger.adopt(d) }
            s.host.changeProfile(.init(cmosPath: cmos))
            s.replace(with: m)
            m.powerOn()
            s.host.setPersistCMOS(true, session: s)
            s.rewinder.keyframe(m)
            context.hardwareChanged(c)
        }

        func startRecording(to url: URL) throws {
            guard let hooks = s.host.agentRecording else { throw ToolError(message: "recording isn't available") }
            try hooks.start(url)
        }

        func stopRecording() -> Bool { s.host.agentRecording?.stop() ?? false }
        var isRecording: Bool { s.host.agentRecording?.isRecording() ?? false }
    }

    func hardwareChanged(_ c: MachineConfiguration) {
        Task { @MainActor [weak controller] in controller?.adoptAgentHardware(c) }
    }

    func perform<T>(_ body: @escaping (AgentSession) throws -> T) throws -> T {
        let result: Result<T, Error> = host.sendAndWait { s in
            defer { s.host.agentTouched(s) }
            return Result { try body(Session(s, context: self)) }
        }
        return try result.get()
    }

    func inspect<T>(_ body: @escaping (Machine) -> T) -> T? {
        host.sendAndWait { s in body(s.machine) }
    }

    /// Paths an attached agent may use: Application Support, the usual user
    /// folders, and where the user's ROMs and recent discs are.
    @MainActor
    static func configurePaths() {
        if let env = ProcessInfo.processInfo.environment["MACARCH_ALLOWED_DIRS"], !env.isEmpty { return }
        let home = NSHomeDirectory() as NSString
        var roots = [AgentPaths.supportDirectory] + ["Desktop", "Documents", "Downloads"].map { home.appendingPathComponent($0) }
        roots += AppSettings.shared.romLibrary.map { ($0.path as NSString).deletingLastPathComponent }
        roots += AppSettings.shared.recentDiscs.map { ($0 as NSString).deletingLastPathComponent }
        roots.append(AppSettings.hardDiscDirectory)
        AgentPaths.allowedRoots = Array(Set(roots.map { ($0 as NSString).standardizingPath })).sorted()
    }

    /// The first window's machine is the one the socket drives.
    @MainActor static var server: AgentSocketServer?

    @MainActor
    static func startServer(for host: EmulatorHost, controller: MachineController) {
        startDebugAdapter(for: host, controller: controller)
        if AppMachineDirectory.shared.standalone == nil {
            AppMachineDirectory.shared.standalone = AppAgentContext(host: host, controller: controller)
        }
        startServer()
        if server != nil && AppMachineDirectory.shared.standalone?.host === host { controller.servesAgents = true }
    }

    /// Serves agents (a network opening starts it too, with or without a
    /// standalone machine).
    @MainActor
    static func startServer() {
        // Self-tests serve agents only when asked (on their own socket).
        guard server == nil, !AppSettings.isSelfTest || ProcessInfo.processInfo.environment["MACARCH_AGENT_SOCKET"] != nil else { return }
        configurePaths()
        let tools = AgentTools(context: StandaloneContext(), directory: AppMachineDirectory.shared)
        let s = AgentSocketServer(tools: LoggedTools(tools: tools))
        s.onConnection = { connected in
            Task { @MainActor in
                AgentLog.shared.add(connected ? .connected : .disconnected)
                // The last agent leaving lets go of any holds.
                if AgentLog.shared.connections == 0 { AppMachineDirectory.shared.releaseHolds() }
            }
        }
        do {
            try s.start()
            server = s
            AgentLog.shared.serverState = .serving
        } catch AgentSocketServer.StartError.inUse {
            AgentLog.shared.serverState = .inUse
        } catch {
            AgentLog.shared.serverState = .failed("\(error)")
        }
    }

    /// The first window's machine is the one editors debug (VS Code's
    /// MacArch extension), over DAP on a localhost port.
    @MainActor static var debugAdapter: DAPServer?

    @MainActor
    static func startDebugAdapter(for host: EmulatorHost, controller: MachineController) {
        let env = ProcessInfo.processInfo.environment["MACARCH_DAP_PORT"].flatMap(UInt16.init)
        // Self-tests serve editors only when given a port of their own.
        guard debugAdapter == nil, AppSettings.isSelfTest ? env != nil : AppSettings.shared.debugAdapterEnabled else { return }
        let port = env ?? UInt16(clamping: AppSettings.shared.debugAdapterPort)
        let server = DAPServer(host: AppAgentContext(host: host, controller: controller), port: port)
        do {
            try server.start(ready: { p in
                Task { @MainActor in AgentLog.shared.debugAdapterState = "Listening on localhost port \(p)" }
            }, failed: { error in
                Task { @MainActor in AgentLog.shared.debugAdapterState = "Not available on port \(port): \(error.localizedDescription)" }
            })
            debugAdapter = server
        } catch {
            AgentLog.shared.debugAdapterState = "Not available on port \(port): \(error.localizedDescription)"
        }
    }
}

/// The machine tools drive when they don't name one: the standalone
/// window's, if there is one.
final class StandaloneContext: AgentContext {
    func perform<T>(_ body: @escaping (AgentSession) throws -> T) throws -> T {
        guard let standalone = AppMachineDirectory.shared.standalone else {
            throw ToolError(message: "no standalone machine window: name a network's machine with `machine` (list_machines shows them)")
        }
        return try standalone.perform(body)
    }
}

/// Starts and stops recordings for agents, from the emulation thread.
final class AgentRecordingHooks: @unchecked Sendable {
    let start: (URL) throws -> Void
    let stop: () -> Bool
    let isRecording: () -> Bool
    init(start: @escaping (URL) throws -> Void, stop: @escaping () -> Bool, isRecording: @escaping () -> Bool) {
        self.start = start; self.stop = stop; self.isRecording = isRecording
    }
}

// MARK: Activity log

/// Everything agents do here, for MCP > Activity Log.
@MainActor
@Observable
final class AgentLog {
    static let shared = AgentLog()

    struct Entry: Identifiable {
        enum Kind {
            case call(tool: String, arguments: String, result: String, images: [Data], isError: Bool, duration: Duration)
            case connected, disconnected
        }
        let id = UUID()
        let time: Date
        let kind: Kind
    }

    enum ServerState: Equatable { case notStarted, serving, inUse, failed(String) }

    private(set) var entries: [Entry] = []
    var serverState = ServerState.notStarted
    /// The debug adapter (for VS Code), for Settings > Debugging.
    var debugAdapterState = "Off"
    private(set) var connections = 0
    private(set) var callsRunning = 0

    func callStarted() { callsRunning += 1 }

    func add(_ kind: Entry.Kind, at time: Date = Date()) {
        switch kind {
        case .call: callsRunning = max(0, callsRunning - 1)
        case .connected: connections += 1
        case .disconnected: connections = max(0, connections - 1)
        }
        entries.append(Entry(time: time, kind: kind))
        if entries.count > 1000 { entries.removeFirst(entries.count - 1000) }
    }

    func clear() { entries.removeAll() }
}

/// Times and logs every call the wrapped tools answer.
final class LoggedTools: ToolProvider, @unchecked Sendable {
    let tools: ToolProvider
    init(tools: ToolProvider) { self.tools = tools }

    var toolList: [[String: Any]] { tools.toolList }

    func call(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        let started = Date()
        Task { @MainActor in AgentLog.shared.callStarted() }
        let clock = ContinuousClock()
        let t0 = clock.now
        let result = tools.call(name, arguments)
        let duration = clock.now - t0
        let content = result["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        let images = content.compactMap { ($0["data"] as? String).flatMap { Data(base64Encoded: $0) } }
        let isError = result["isError"] as? Bool ?? false
        var args = ""
        if !arguments.isEmpty, let d = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys, .withoutEscapingSlashes]) {
            args = String(data: d, encoding: .utf8) ?? ""
        }
        Task { @MainActor in
            AgentLog.shared.add(.call(tool: name, arguments: args, result: text, images: images, isError: isError, duration: duration), at: started)
        }
        return result
    }
}
