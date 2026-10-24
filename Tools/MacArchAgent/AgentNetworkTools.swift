import ArchimedesCore
import Foundation

// The Network Studio's tools (after MacBeeb's): any tool can name a
// network's machine with `machine`, and a few tools work on whole
// networks. The app supplies a directory of its networks; headless there's
// none, and only the standalone machine is there.

/// What the app knows of its machines besides the one an attached agent
/// drives: the Network Studio's stations, and its network tools.
public protocol MachineDirectory: AnyObject {
    /// Where `machine` (a station's name, number or id, or "standalone")
    /// lives, or why there's no such machine.
    func context(for machine: String) throws -> AgentContext
    /// Runs one of the network tools (`AgentTools.networkToolNames`).
    func networkTool(_ name: String, _ arguments: [String: Any]) throws -> ToolOutput
}

let machineProp = prop("string", "Which machine: a Network Studio station's name, station number or id (list_machines shows them; \"Network/name\" picks the network). Leave it out for the standalone machine.")

public extension AgentTools {
    static let networkToolNames: Set<String> = Set(networkToolDefinitions.map { $0["name"] as! String })

    static let networkToolDefinitions: [[String: Any]] = [
        ["name": "list_machines",
         "description": "Every machine: the standalone one, and each open Network Studio network's stations (name, model, role, station number, on or off), with the id to pass as `machine` to the other tools.",
         "inputSchema": schema([:])],
        ["name": "network_status",
         "description": "The open networks: their machines (station numbers, roles, on/off/suspended), clock, problems, speed, whether paused, the traffic each station has sent (frames, bytes, collisions), and what each file server's console says.",
         "inputSchema": schema(["network": prop("string", "Which network, by name (default: every open one)")])],
        ["name": "network_power",
         "description": "Switches a network's machine on or off, power-cycles it, presses its reset button, or suspends or resumes it (a suspended machine stops while the rest run on, so others waiting for it time out).",
         "inputSchema": schema(["machine": machineProp,
                                "action": ["type": "string", "enum": ["on", "off", "power_cycle", "reset", "suspend", "resume"]]],
                               required: ["machine", "action"])],
        ["name": "network_pause",
         "description": "Pauses or resumes a whole network: no emulated time passes on any of its machines, so nothing times out.",
         "inputSchema": schema(["network": prop("string", "Which network (default: every open one)"), "paused": prop("boolean", "true pauses, false resumes")],
                               required: ["paused"])],
        ["name": "network_trace",
         "description": "Frames on a network's Econet, newest last, as the four-way handshake reads them: number, time (s), from, to, kind (scout/acknowledgement/data/broadcast), control byte, port (and its use), status (valid, collided, aborted) and bytes (hex). `after` gives only frames after that frame number, for polling.",
         "inputSchema": schema(["network": prop("string", "Which network (needed when more than one is open)"),
                                "after": prop("integer", "Only frames after this one"),
                                "limit": prop("integer", "Most frames to return (default 100, at most 1000)"),
                                "station": prop("integer", "Only frames to or from this station"),
                                "problems_only": prop("boolean", "Only collided or aborted frames")])],
        ["name": "network_create",
         "description": "Makes a new network from a template (two_archimedes; school_classroom: four A3000s, a file server and a clock; family: an A310, A440/1, A3000 and A5000; empty), saves it in Documents/MacArch Networks and opens it, its machines switched on. Returns its machines. A file server is set up with Level 4 by network_set_up_level4.",
         "inputSchema": schema(["template": ["type": "string", "enum": ["two_archimedes", "school_classroom", "family", "empty"]],
                                "name": prop("string", "The network's name (default: the template's)")], required: ["template"])],
        ["name": "network_open",
         "description": "Opens a saved network (a .macarchnet package) and switches on its machines.",
         "inputSchema": schema(["path": prop("string", "The .macarchnet package")], required: ["path"])],
        ["name": "network_set_up_level4",
         "description": "Sets a network's file server up with Acorn's Level 4 File Server from the user's Level 4 disc image (Release 3's \"Level 4\" disc or Issue 2's \"FileServer\" disc): a new hard disc that starts the server when the machine does. Other machines then log on with *I AM SYST.",
         "inputSchema": schema(["machine": machineProp, "disc": prop("string", "Path of the Level 4 disc image")], required: ["machine", "disc"])],
    ]
}

let econetTools: [Tool] = [
    Tool(name: "econet_status",
         description: "The machine's Econet module: station number, the MC6854's registers (CR1-CR4, SR1, SR2), FIFOs, transmitter and receiver state, the clock (DCD) and the interrupts it has raised (FIQ).",
         schema: schema([:]), run: { s, _ in
             let m = try s.require()
             guard let econet = m.econet else {
                 return ToolOutput("No Econet module: this machine isn't on a network (the Network Studio fits one to every machine).")
             }
             return ToolOutput(econet.statusReport())
         }),
]
