import Foundation
#if canImport(Network)
import Network
#elseif canImport(Glibc)
import Glibc
#endif

// Serves the Debug Adapter Protocol on a localhost TCP port (VS Code
// connects with a DebugAdapterServer). One client at a time; a new one
// replaces the old.

public final class DAPServer: @unchecked Sendable {
    /// After the IOC's address, &3200000.
    public static let defaultPort: UInt16 = 3200

    private let host: DebugAdapterHost
    private let queue = DispatchQueue(label: "MacArch DAP")
    #if canImport(Network)
    private var listener: NWListener?
    private var connection: NWConnection?
    #endif
    private var session: DAPSession?
    private var buffer = Data()
    public private(set) var port: UInt16

    public init(host: DebugAdapterHost, port: UInt16 = defaultPort) {
        self.host = host
        self.port = port
    }

    #if canImport(Network)
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
    #else
    // Without Apple's Network framework (Linux): POSIX sockets, a thread
    // accepting and one reading the client; the session's messages are
    // handled on `queue`, as with NWConnection.
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1

    /// Starts listening on 127.0.0.1. With port 0, picks a free one
    /// (`port` says which, once `ready` is called). `failed` is called if
    /// the port can't be had.
    public func start(ready: @escaping @Sendable (UInt16) -> Void = { _ in }, failed: @escaping @Sendable (Error) -> Void = { _ in }) throws {
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE)
            close(fd)
            queue.async { failed(error) }
            return
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
        listenFD = fd
        let t = Thread { [weak self] in self?.acceptLoop(fd) }
        t.name = "MacArch DAP"
        t.start()
        let p = port
        queue.async { ready(p) }
    }

    public func stop() {
        queue.sync {
            if listenFD >= 0 { shutdown(listenFD, Int32(SHUT_RDWR)); close(listenFD); listenFD = -1 }
            if clientFD >= 0 { shutdown(clientFD, Int32(SHUT_RDWR)) }
            session?.close()
        }
    }

    private func acceptLoop(_ listener: Int32) {
        while true {
            let client = Glibc.accept(listener, nil, nil)
            guard client >= 0 else { return }
            queue.sync { accept(client) }
        }
    }

    /// (On `queue`.)
    private func accept(_ client: Int32) {
        if clientFD >= 0 { shutdown(clientFD, Int32(SHUT_RDWR)) }
        session?.close()
        clientFD = client
        buffer = Data()
        let session = DAPSession(host: host, send: { [weak self] message in
            guard let self, let data = try? Self.frame(message) else { return }
            self.queue.async { Self.write(data, to: client) }
        })
        self.session = session
        let t = Thread { [weak self] in self?.receive(client, session) }
        t.name = "MacArch DAP client"
        t.start()
    }

    private func receive(_ client: Int32, _ session: DAPSession) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(client, &chunk, chunk.count)
            if n <= 0 { break }
            let data = Data(chunk[0..<n])
            queue.sync {
                buffer.append(data)
                for message in Self.messages(from: &buffer) { session.handle(message) }
            }
        }
        queue.sync {
            session.close()
            if clientFD == client { clientFD = -1 }
        }
        close(client)
    }

    private static func write(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = Glibc.write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }
    #endif

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
