import ArchimedesCore
import Foundation
import MacArchAgent

// macarch-mcp: Model Context Protocol server (JSON-RPC 2.0 over stdio).
// Add to Claude Code with: claude mcp add macarch -- /path/to/macarch-mcp
//
//   macarch-mcp [--rom PATH] [--model A3000]   a headless Archimedes of its own
//   macarch-mcp --attach                       drive the machine in the running MacArch app
//
// The headless machine's ROM comes from --rom, MACARCH_ROM, or the one chosen
// in the MacArch app. File access is restricted to MACARCH_ALLOWED_DIRS
// (colon separated); by default the current directory and
// ~/Library/Application Support/MacArch.

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

let tools: ToolProvider
if args.contains("--attach") {
    tools = AppConnection()
} else {
    let rom = option("--rom") ?? ProcessInfo.processInfo.environment["MACARCH_ROM"]
        ?? UserDefaults(suiteName: "com.accidentalfish.macarch")?.string(forKey: "romPath")
    var config: MachineConfiguration?
    if let rom {
        var c = MachineConfiguration(model: option("--model").flatMap { n in MachineModel.allCases.first { $0.rawValue.lowercased() == n.lowercased() } } ?? .a3000)
        c.romPaths = [rom]
        config = c
    }
    do {
        tools = AgentTools(context: try HeadlessSession(configuration: config))
    } catch {
        FileHandle.standardError.write("macarch-mcp: \(error)\n".data(using: .utf8)!)
        tools = AgentTools(context: try! HeadlessSession(configuration: nil))
    }
}
MCPServer(tools: tools, instructions: mcpInstructions).run()
