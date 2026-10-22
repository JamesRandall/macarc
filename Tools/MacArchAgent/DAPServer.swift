import Foundation
import Network

// Serves the Debug Adapter Protocol on a localhost TCP port (VS Code
// connects with a DebugAdapterServer). One client at a time; a new one
// replaces the old.

public final class DAPServer: @unchecked Sendable {
    /// After the IOC's address, &3200000.
    public static let defaultPort: UInt16 = 3200

    private let host: DebugAdapterHost
    private let queue = DispatchQueue(label: "MacArch DAP")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var session: DAPSession?
    private var buffer = Data()
    public private(set) var port: UInt16

    public init(host: DebugAdapterHost, port: UInt16 = defaultPort) {
        self.host = host
        self.port = port
    }

    /// Starts listening on 127.0.0.1. With port 0, picks a free one
    /// (`port` says which, once `ready` is called). `failed` is called if
    /// the port can't be had.
    public func start(ready: @escaping @Sendable (UInt16) -> Void = { _ in }, failed: @escaping @Sendable (Error) -> Void = { _ in }) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let self, let p = listener.port?.rawValue { self.port = p; ready(p) }
            case .failed(let error):
                failed(error)
            default: break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        connection?.cancel()
        session?.close()
    }

    private func accept(_ connection: NWConnection) {
        self.connection?.cancel()
        session?.close()
        self.connection = connection
        buffer = Data()
        let session = DAPSession(host: host, send: { [weak self, weak connection] message in
            guard let connection, let data = try? Self.frame(message) else { return }
            self?.queue.async { connection.send(content: data, completion: .contentProcessed { _ in }) }
        })
        self.session = session
        connection.start(queue: queue)
        receive(connection, session)
    }

    private func receive(_ connection: NWConnection, _ session: DAPSession) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data {
                self.buffer.append(data)
                for message in Self.messages(from: &self.buffer) { session.handle(message) }
            }
            if complete || error != nil {
                session.close()
                connection.cancel()
                return
            }
            self.receive(connection, session)
        }
    }

    // MARK: Framing

    /// `Content-Length: n\r\n\r\n` then n bytes of JSON.
    public static func frame(_ message: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
        return Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }

    /// The complete messages at the start of `buffer`, removed from it.
    public static func messages(from buffer: inout Data) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        let separator = Data("\r\n\r\n".utf8)
        while let end = buffer.range(of: separator) {
            let header = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            guard let line = header.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                  let length = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) else {
                // Not a header we understand: drop it.
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                continue
            }
            let bodyStart = end.upperBound
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { break }
            let bodyEnd = buffer.index(bodyStart, offsetBy: length)
            if let m = try? JSONSerialization.jsonObject(with: buffer[bodyStart..<bodyEnd]) as? [String: Any] {
                messages.append(m)
            }
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)
            buffer = Data(buffer)
        }
        return messages
    }
}
