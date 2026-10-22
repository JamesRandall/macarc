import Foundation

/// MCP over stdio: JSON-RPC 2.0, one message per line.
public final class MCPServer {
    let tools: ToolProvider
    let instructions: String
    static let protocolVersion = "2024-11-05"

    public init(tools: ToolProvider, instructions: String) {
        self.tools = tools
        self.instructions = instructions
    }

    func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), let s = String(data: d, encoding: .utf8) else { return }
        print(s)
        fflush(stdout)
    }

    func respond(_ id: Any, _ result: Any) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
    func respondError(_ id: Any, _ code: Int, _ message: String) { send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]) }

    public func run() {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let d = line.data(using: .utf8), let msg = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                if !line.isEmpty { respondError(NSNull(), -32700, "parse error") }
                continue
            }
            guard let id = msg["id"] else { continue } // notification
            let params = msg["params"] as? [String: Any] ?? [:]
            switch msg["method"] as? String ?? "" {
            case "initialize":
                respond(id, ["protocolVersion": (params["protocolVersion"] as? String) ?? Self.protocolVersion,
                             "capabilities": ["tools": ["listChanged": false]],
                             "serverInfo": ["name": "macarch-mcp", "version": "0.2.0"],
                             "instructions": instructions])
            case "ping": respond(id, [String: Any]())
            case "tools/list": respond(id, ["tools": tools.toolList])
            case "tools/call":
                respond(id, tools.call(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:]))
            default:
                respondError(id, -32601, "method not found: \(msg["method"] ?? "")")
            }
        }
    }
}
