import AppKit
import ArchimedesCore
import Foundation
import MacArchAgent

/// What agents see of the Network Studio: its machines, by name, and the
/// network tools. Calls come from the agent socket's thread; the studio's
/// state is the main thread's, so each is answered there. (After MacBeeb's.)
final class AppMachineDirectory: MachineDirectory, @unchecked Sendable {
    static let shared = AppMachineDirectory()

    /// The standalone window's machine (the one `machine` left out means).
    nonisolated(unsafe) var standalone: AppAgentContext?

    private func onMain<T>(_ body: @MainActor () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try MainActor.assumeIsolated(body) }
        return try DispatchQueue.main.sync { try MainActor.assumeIsolated(body) }
    }

    /// Lets every machine an agent held still run again.
    @MainActor
    func releaseHolds() {
        standalone?.host.heldForAgent = false
        for session in NetworkSession.open.values {
            for controller in session.controllers.values { controller.host?.heldForAgent = false }
        }
    }

    func context(for machine: String) throws -> AgentContext {
        if machine.lowercased() == "standalone" {
            guard let standalone else { throw ToolError(message: "not_found: there's no standalone machine window") }
            return standalone
        }
        return try onMain {
            let (session, node) = try find(machine)
            guard let controller = session.controllers[node.id], let host = controller.host else {
                throw ToolError(message: "powered_off: \(node.name) is switched off (network_power with action on)")
            }
            return AppAgentContext(host: host, controller: controller)
        }
    }

    func networkTool(_ name: String, _ arguments: [String: Any]) throws -> ToolOutput {
        try onMain { try run(name, arguments) }
    }

    // MARK: Main thread

    /// The station `name` names: its id, its name, "station N" or N, in
    /// any open network ("Network/name" picks the network).
    @MainActor
    private func find(_ name: String) throws -> (NetworkSession, NetworkNode) {
        var networkName: String?
        var key = name.trimmingCharacters(in: .whitespaces)
        if let slash = key.firstIndex(of: "/") {
            networkName = String(key[..<slash])
            key = String(key[key.index(after: slash)...])
        }
        let sessions = networks(networkName)
        let number = Int(key.lowercased().replacingOccurrences(of: "station", with: "").trimmingCharacters(in: .whitespaces))
        var found: [(NetworkSession, NetworkNode)] = []
        for session in sessions {
            for node in session.project.stations where node.id.uuidString.caseInsensitiveCompare(key) == .orderedSame
                || node.name.caseInsensitiveCompare(key) == .orderedSame || (number != nil && node.stationNumber == number) {
                found.append((session, node))
            }
        }
        if found.isEmpty {
            throw ToolError(message: NetworkSession.open.isEmpty
                ? "not_found: no network is open (network_create or network_open)"
                : "not_found: no machine \"\(name)\" (list_machines shows them)")
        }
        if found.count > 1 {
            throw ToolError(message: "ambiguous_machine: \"\(name)\" could be " + found.map { "\($0.1.name) in \($0.0.project.name)" }.joined(separator: ", ")
                + "; use its id or \"Network/name\"")
        }
        return found[0]
    }

    @MainActor
    private func networks(_ name: String?) -> [NetworkSession] {
        NetworkSession.open.values.filter { name == nil || $0.project.name.caseInsensitiveCompare(name!) == .orderedSame }
            .sorted { $0.project.name < $1.project.name }
    }

    @MainActor
    private func run(_ name: String, _ a: [String: Any]) throws -> ToolOutput {
        switch name {
        case "list_machines":
            var lines: [String] = []
            if standalone != nil { lines.append("Standalone window: the default when `machine` is left out (machine: \"standalone\")") }
            for session in networks(nil) {
                for node in session.project.stations {
                    var line = "\(node.name): \(node.setup?.summary ?? ""), \(node.kind.displayName), network \"\(session.project.name)\""
                    if let n = node.stationNumber { line += ", station \(n)" }
                    line += session.isOn(node.id) ? ", on" : ", off"
                    lines.append(line + " (machine: \"\(node.id.uuidString)\")")
                }
            }
            return ToolOutput(lines.isEmpty ? "No machines: open a machine window or a network." : lines.joined(separator: "\n"))
        case "network_status":
            let sessions = networks(a["network"] as? String)
            guard !sessions.isEmpty else { throw ToolError(message: "not_found: no network is open") }
            return ToolOutput(sessions.map(status).joined(separator: "\n\n"))
        case "network_power":
            guard let machine = a["machine"] as? String, let action = a["action"] as? String else {
                throw ToolError(message: "missing_argument: machine and action")
            }
            let (session, node) = try find(machine)
            switch action {
            case "on": session.powerOn(node.id)
            case "off": session.powerOff(node.id)
            case "power_cycle": session.coldBoot(node.id)
            case "reset": session.reset(node.id)
            case "suspend": session.setSuspended(node.id, true)
            case "resume": session.setSuspended(node.id, false)
            default: throw ToolError(message: "invalid_value: action \(action)")
            }
            let state = session.isOn(node.id) ? (session.isSuspended(node.id) ? "suspended" : "on") : "off"
            return ToolOutput("\(node.name): \(action) done. It's \(state).")
        case "network_pause":
            let sessions = networks(a["network"] as? String)
            guard !sessions.isEmpty else { throw ToolError(message: "not_found: no network is open") }
            let paused = a["paused"] as? Bool ?? true
            for session in sessions { session.setPaused(paused) }
            return ToolOutput("\(sessions.map(\.project.name).joined(separator: ", ")): \(paused ? "paused" : "running")")
        case "network_trace":
            let sessions = networks(a["network"] as? String)
            guard sessions.count == 1, let session = sessions.first else {
                throw ToolError(message: sessions.isEmpty ? "not_found: no network is open" : "ambiguous_network: name the network")
            }
            return ToolOutput(trace(session, a))
        case "network_create", "network_open":
            return try open(name, a)
        case "network_set_up_level4":
            guard let machine = a["machine"] as? String, let disc = a["disc"] as? String else {
                throw ToolError(message: "missing_argument: machine and disc")
            }
            let (session, node) = try find(machine)
            let path = (disc as NSString).expandingTildeInPath
            do { try session.setUpLevel4(node.id, disc: URL(fileURLWithPath: path)) } catch {
                throw ToolError(message: "set_up_failed: \(error.localizedDescription)")
            }
            return ToolOutput("\(node.name) is set up with the Level 4 File Server, and restarting if it was on. It takes about 30 s to start; then on another machine, *I AM SYST logs on.\n" + status(session))
        default:
            throw ToolError(message: "unknown tool \(name)")
        }
    }

    @MainActor
    private func status(_ session: NetworkSession) -> String {
        let project = session.project
        var lines = ["network \"\(project.name)\" (\(session.url.path))",
                     "clock: " + (project.clockRate.map { "\($0 / 1000) kbit/s" } ?? "none"),
                     "state: " + (session.paused ? "paused" : String(format: "running at %.0f%% of real time", session.status.speed * 100)
                                + " on \(session.status.threads) thread\(session.status.threads == 1 ? "" : "s")")]
        if !session.status.stoppedStations.isEmpty { lines.append("stopped in the debugger: \(session.status.stoppedStations.count)") }
        for problem in project.problems { lines.append("problem: " + problem.message) }
        for node in project.stations {
            var line = "  \(node.stationNumber.map { String($0) } ?? "-") \(node.name): \(node.kind.displayName), \(node.setup?.summary ?? ""), "
            line += session.isOn(node.id) ? (session.isSuspended(node.id) ? "suspended" : "on") : "off"
            if node.runsLevel4 == true { line += ", Level 4 set up" }
            if let number = node.stationNumber, let traffic = session.status.traffic[UInt8(clamping: number)] {
                line += "; sent \(traffic.frames) frames, \(traffic.bytes) bytes" + (traffic.collisions > 0 ? ", \(traffic.collisions) collided" : "")
            }
            if node.kind == .fileServer, let console = session.controllers[node.id]?.consoleLine {
                line += "; console: \"\(console)\""
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    @MainActor
    private func trace(_ session: NetworkSession, _ a: [String: Any]) -> String {
        var frames = session.network.frames(after: a["after"] as? Int)
        if let station = a["station"] as? Int {
            frames = frames.filter { Int($0.transmitter) == station || $0.destinationStation.map(Int.init) == station }
        }
        if a["problems_only"] as? Bool == true { frames = frames.filter { $0.status != .valid } }
        let limit = min(1000, max(1, a["limit"] as? Int ?? 100))
        frames = Array(frames.suffix(limit))
        guard !frames.isEmpty else { return "No frames" + (a["after"] != nil ? " since then." : ".") }
        return frames.map { frame in
            var line = String(format: "#%d %.4fs", frame.id, Double(frame.start) / Double(EconetTime.ticksPerSecond))
            line += " \(frame.transmitter)->\(frame.destinationStation.map { String($0) } ?? "?") \(frame.kind.rawValue)"
            if let control = frame.control { line += String(format: " ctrl &%02X", control) }
            if let port = frame.port {
                line += String(format: " port &%02X", port) + (EconetFrame.portName(port).map { " (\($0))" } ?? "")
            }
            line += " \(frame.status.rawValue) [\(frame.bytes.map { String(format: "%02X", $0) }.joined(separator: " "))]"
            return line
        }.joined(separator: "\n")
    }

    @MainActor
    private func open(_ name: String, _ a: [String: Any]) throws -> ToolOutput {
        let url: URL
        if name == "network_create" {
            let templates: [String: NetworkTemplate] = ["two_archimedes": .twoArchimedes, "school_classroom": .schoolClassroom,
                                                        "family": .family, "distributed_mandelbrot": .distributedMandelbrot, "empty": .empty]
            guard let template = (a["template"] as? String).flatMap({ templates[$0] }) else {
                throw ToolError(message: "invalid_value: template must be one of \(templates.keys.sorted().joined(separator: ", "))")
            }
            let given = (a["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            url = RecentNetworks.newURL(named: given ?? template.title)
            do { _ = try NetworkPackage.create(template, named: given, at: url) } catch {
                throw ToolError(message: "write_failed: \(error.localizedDescription)")
            }
        } else {
            guard let path = a["path"] as? String else { throw ToolError(message: "missing_argument: path") }
            url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        do {
            let session = try NetworkSession.session(for: url)
            RecentNetworks.shared.add(url)
            // And its window, for the person watching.
            NotificationCenter.default.post(name: NetworkStudioCommands.openRequest, object: url)
            return ToolOutput("Opened \"\(session.project.name)\" (\(url.path)):\n" + status(session))
        } catch {
            throw ToolError(message: "open_failed: \(error)")
        }
    }
}
