import Darwin
import Foundation

/// The local socket the app serves agent tools on, so `macarch-mcp --attach`
/// can drive the machine you are watching. One JSON object per line each
/// way: {"tool": name, "arguments": {...}} (or {"list": true}) in, a result
/// out. The socket lives in the user's Application Support folder and is
/// only accessible to the user.
public enum AgentSocket {
    public static var defaultPath: String {
        if let p = ProcessInfo.processInfo.environment["MACARCH_AGENT_SOCKET"], !p.isEmpty { return p }
        try? FileManager.default.createDirectory(atPath: AgentPaths.supportDirectory, withIntermediateDirectories: true)
        return (AgentPaths.supportDirectory as NSString).appendingPathComponent("agent.sock")
    }

    static func address(_ path: String) -> sockaddr_un {
        var a = sockaddr_un()
        a.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &a.sun_path) { buf in
            let bytes = Array(path.utf8.prefix(buf.count - 1))
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        return a
    }

    static func connect(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var a = address(path)
        let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if r != 0 { close(fd); return nil }
        return fd
    }

    final class LineReader {
        let fd: Int32
        var buffer = Data()
        init(fd: Int32) { self.fd = fd }
        func readLine() -> String? {
            while true {
                if let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    return String(decoding: line, as: UTF8.self)
                }
                var chunk = [UInt8](repeating: 0, count: 65536)
                let n = Darwin.read(fd, &chunk, chunk.count)
                guard n > 0 else { return nil }
                buffer.append(contentsOf: chunk[0..<n])
            }
        }
    }

    static func writeLine(_ fd: Int32, _ obj: Any) -> Bool {
        guard var d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return false }
        d.append(0x0A)
        return d.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }
}

/// Serves tools on the agent socket (in the app), a thread per client.
public final class AgentSocketServer: @unchecked Sendable {
    let tools: ToolProvider
    let path: String
    private var listener: Int32 = -1
    /// Called with true when an agent connects and false when it goes.
    public var onConnection: ((Bool) -> Void)?

    public enum StartError: Error { case inUse }

    public init(tools: ToolProvider, path: String = AgentSocket.defaultPath) {
        self.tools = tools
        self.path = path
    }

    public func start() throws {
        // A stale socket from a crashed run is replaced; a live one is not.
        if let fd = AgentSocket.connect(path) {
            close(fd)
            throw StartError.inUse
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var a = AgentSocket.address(path)
        let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard r == 0, listen(fd, 4) == 0 else { close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        chmod(path, 0o600)
        listener = fd
        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "MacArch agent socket"
        t.start()
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            let t = Thread { [weak self] in self?.serve(client) }
            t.name = "MacArch agent"
            t.start()
        }
    }

    private func serve(_ client: Int32) {
        onConnection?(true)
        defer { close(client); onConnection?(false) }
        let reader = AgentSocket.LineReader(fd: client)
        while let line = reader.readLine() {
            let reply: Any
            if let d = line.data(using: .utf8), let msg = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                if msg["list"] as? Bool == true {
                    reply = ["tools": tools.toolList]
                } else if let tool = msg["tool"] as? String {
                    reply = tools.call(tool, msg["arguments"] as? [String: Any] ?? [:])
                } else {
                    reply = errorResult("bad request")
                }
            } else {
                reply = errorResult("bad request")
            }
            if !AgentSocket.writeLine(client, reply) { break }
        }
    }
}

/// `macarch-mcp --attach`: forwards tool calls to the running app. Path
/// arguments are made absolute here, since the app has a different
/// working directory.
public final class AppConnection: ToolProvider {
    let path: String
    private var fd: Int32?
    private var reader: AgentSocket.LineReader?
    static let pathKeys: Set<String> = ["path", "rom", "disc", "cmos_path"]
    static func absolute(_ p: String) -> String {
        let e = (p as NSString).expandingTildeInPath
        return e.hasPrefix("/") || e.isEmpty ? e : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(e)
    }

    public init(path: String = AgentSocket.defaultPath) { self.path = path }

    private func request(_ msg: [String: Any]) -> [String: Any]? {
        for _ in 0..<2 {
            if fd == nil, let c = AgentSocket.connect(path) { fd = c; reader = AgentSocket.LineReader(fd: c) }
            guard let fd, let reader else { return nil }
            if AgentSocket.writeLine(fd, msg), let line = reader.readLine(), let d = line.data(using: .utf8),
               let reply = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                return reply
            }
            close(fd); self.fd = nil; self.reader = nil // reconnect once (app restarted)
        }
        return nil
    }

    public var toolList: [[String: Any]] {
        (request(["list": true])?["tools"] as? [[String: Any]]) ?? []
    }

    public func call(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        var args = arguments
        for k in Self.pathKeys { if let p = args[k] as? String { args[k] = Self.absolute(p) } }
        if let discs = args["hard_discs"] as? [String] { args["hard_discs"] = discs.map(Self.absolute) }
        return request(["tool": name, "arguments": args])
            ?? errorResult("MacArch isn't running (no agent socket at \(path)). Open the app, or run macarch-mcp without --attach for a headless machine.")
    }
}
