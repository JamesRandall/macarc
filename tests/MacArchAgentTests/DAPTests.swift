import ArchimedesCore
import Foundation
import MacArchAgent
import XCTest

/// A headless machine that runs all the time, as the app's does, so the
/// debug adapter has something to poll.
final class RunningHost: DebugAdapterHost, @unchecked Sendable {
    let session: HeadlessSession
    private var thread: Thread?
    private let stopping = NSLock()
    private var stopped = false

    init(rom: String) throws {
        var c = MachineConfiguration()
        c.romPaths = [rom]
        session = try HeadlessSession(configuration: c)
        let t = Thread { [unowned self] in
            while !self.isStopping {
                let idle = (try? self.session.perform { s -> Bool in
                    guard let m = s.machine, !m.isStoppedByDebugger else { return true }
                    s.advance(ticks: 24_000)
                    return false
                }) ?? true
                if idle { Thread.sleep(forTimeInterval: 0.002) }
            }
        }
        thread = t
        t.start()
    }

    var isStopping: Bool { stopping.lock(); defer { stopping.unlock() }; return stopped }

    func stop() { stopping.lock(); stopped = true; stopping.unlock() }

    func perform<T>(_ body: @escaping (AgentSession) throws -> T) throws -> T { try session.perform(body) }

    func inspect<T>(_ body: @escaping (Machine) -> T) -> T? {
        try? session.perform { s in s.machine.map(body) } ?? nil
    }
}

/// A scripted DAP client talking to a session.
final class DAPClient: @unchecked Sendable {
    let session: DAPSession
    private let lock = NSLock()
    private var messages: [[String: Any]] = []
    private var seq = 1

    init(host: DebugAdapterHost) {
        var box: DAPClient?
        session = DAPSession(host: host, send: { m in box?.received(m) })
        box = self
    }

    private func received(_ m: [String: Any]) { lock.lock(); messages.append(m); lock.unlock() }

    private func take(_ match: ([String: Any]) -> Bool) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        guard let i = messages.firstIndex(where: match) else { return nil }
        return messages.remove(at: i)
    }

    private func wait(_ timeout: Double, _ what: String, _ match: @escaping ([String: Any]) -> Bool) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let m = take(match) { return m }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTFail("no \(what)")
        throw CancellationError()
    }

    /// Sends a request and waits for its response.
    @discardableResult
    func request(_ command: String, _ arguments: [String: Any] = [:], timeout: Double = 60) throws -> [String: Any] {
        let n = seq
        seq += 1
        session.handle(["type": "request", "seq": n, "command": command, "arguments": arguments])
        return try wait(timeout, "response to \(command)") { $0["type"] as? String == "response" && $0["request_seq"] as? Int == n }
    }

    /// Waits for (and removes) the next event called `name`.
    func event(_ name: String, timeout: Double = 30) throws -> [String: Any] {
        try wait(timeout, "\(name) event") { $0["type"] as? String == "event" && $0["event"] as? String == name }
    }

    /// Everything the program printed so far.
    func stdout() -> String {
        lock.lock(); defer { lock.unlock() }
        return messages.compactMap { m -> String? in
            guard m["event"] as? String == "output", let b = m["body"] as? [String: Any], b["category"] as? String == "stdout" else { return nil }
            return b["output"] as? String
        }.joined()
    }
}

final class DAPTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
    let hello = root + "/Examples/hello-arm/hello.s"

    func testFraming() throws {
        var buffer = try DAPServer.frame(["a": 1]) + DAPServer.frame(["b": "two"])
        let partial = try DAPServer.frame(["c": true])
        buffer += partial.prefix(10)
        let messages = DAPServer.messages(from: &buffer)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["a"] as? Int, 1)
        XCTAssertEqual(messages[1]["b"] as? String, "two")
        buffer += partial.dropFirst(10)
        XCTAssertEqual(DAPServer.messages(from: &buffer).first?["c"] as? Bool, true)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDebuggingAnAssembledProgram() throws {
        let rom = Self.root + "/roms/riscos3_11"
        guard FileManager.default.fileExists(atPath: rom) else { throw XCTSkip("needs roms/riscos3_11") }
        let host = try RunningHost(rom: rom)
        defer { host.stop() }
        let client = DAPClient(host: host)

        let initialize = try client.request("initialize", ["adapterID": "macarch"])
        XCTAssertEqual((initialize["body"] as? [String: Any])?["supportsStepBack"] as? Bool, true)
        _ = try client.event("initialized")

        let launch = try client.request("launch", ["source": hello, "stopOnEntry": true])
        XCTAssertEqual(launch["success"] as? Bool, true, "\(launch)")
        let assembled = try client.event("output")
        XCTAssertTrue(((assembled["body"] as? [String: Any])?["output"] as? String ?? "").hasPrefix("Assembled hello.s"))

        // Line 16 is the label .loop: the breakpoint moves to line 17's code.
        let set = try client.request("setBreakpoints", ["source": ["path": hello], "breakpoints": [["line": 16], ["line": 2]]])
        let bps = (set["body"] as? [String: Any])?["breakpoints"] as? [[String: Any]] ?? []
        XCTAssertEqual(bps.first?["verified"] as? Bool, true)
        XCTAssertEqual(bps.first?["line"] as? Int, 17)
        XCTAssertEqual(bps.last?["line"] as? Int, 10, "the comment at the top moves to the first instruction")
        try client.request("configurationDone")

        // Stops at the entry point (line 10 also has a breakpoint, but entry wins).
        let entry = try client.event("stopped")
        XCTAssertEqual((entry["body"] as? [String: Any])?["reason"] as? String, "entry")
        func top() throws -> [String: Any] {
            let trace = try client.request("stackTrace", ["threadId": 1])
            return ((trace["body"] as? [String: Any])?["stackFrames"] as? [[String: Any]])?.first ?? [:]
        }
        XCTAssertEqual(try top()["line"] as? Int, 10)
        XCTAssertEqual(try top()["name"] as? String, "start")

        // The line 10 breakpoint is at the entry too: continue past it to line 17.
        try client.request("continue", ["threadId": 1])
        var stop = try client.event("stopped")
        if try top()["line"] as? Int == 10 {
            try client.request("continue", ["threadId": 1])
            stop = try client.event("stopped")
        }
        XCTAssertEqual((stop["body"] as? [String: Any])?["reason"] as? String, "breakpoint")
        XCTAssertEqual(try top()["line"] as? Int, 17)
        XCTAssertTrue(client.stdout().hasPrefix("*Go 8000\nHello from the Archimedes!\n"), client.stdout())

        let r4 = try client.request("evaluate", ["expression": "R4", "context": "watch"])
        XCTAssertEqual((r4["body"] as? [String: Any])?["result"] as? String, "&00000005 (5)")
        let greeting = try client.request("evaluate", ["expression": "greeting", "context": "hover"])
        XCTAssertTrue(((greeting["body"] as? [String: Any])?["result"] as? String ?? "").contains("48 65 6C 6C"), "\(greeting)")

        // Step into the BL, then out of it, then over the SUBS.
        try client.request("next", ["threadId": 1]); _ = try client.event("stopped")
        XCTAssertEqual(try top()["line"] as? Int, 18)
        try client.request("stepIn", ["threadId": 1]); _ = try client.event("stopped")
        XCTAssertEqual(try top()["name"] as? String, "print_digit")
        let frames = try client.request("stackTrace", ["threadId": 1])
        let callers = (frames["body"] as? [String: Any])?["stackFrames"] as? [[String: Any]] ?? []
        XCTAssertEqual(callers.count, 2)
        XCTAssertEqual(callers.last?["line"] as? Int, 18, "the caller is the BL")
        try client.request("stepOut", ["threadId": 1]); _ = try client.event("stopped")
        XCTAssertEqual(try top()["line"] as? Int, 19)

        // And back.
        try client.request("stepBack", ["threadId": 1]); _ = try client.event("stopped")
        XCTAssertEqual(try top()["name"] as? String, "print_digit+&10", "back to the last instruction of print_digit")

        // Registers can be set.
        let set5 = try client.request("setVariable", ["variablesReference": 1, "name": "R4", "value": "&20"])
        XCTAssertEqual((set5["body"] as? [String: Any])?["value"] as? String, "&00000020 (32)")
        let regs = try client.request("variables", ["variablesReference": 1])
        let r4row = ((regs["body"] as? [String: Any])?["variables"] as? [[String: Any]])?.first { $0["name"] as? String == "R4" }
        XCTAssertEqual(r4row?["value"] as? String, "&00000020 (32)")

        // Memory and disassembly.
        let mem = try client.request("readMemory", ["memoryReference": "0x8000", "count": 4])
        XCTAssertEqual((mem["body"] as? [String: Any])?["data"] as? String, Data([0x10, 0, 0, 0xEF]).base64EncodedString())
        let dis = try client.request("disassemble", ["memoryReference": "0x8000", "instructionCount": 2])
        let rows = (dis["body"] as? [String: Any])?["instructions"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.first?["instruction"] as? String, "SWI OS_GetEnv")
        XCTAssertEqual(rows.first?["line"] as? Int, 10)

        try client.request("disconnect")
    }

    func testDebuggingABASICProgram() throws {
        let rom = Self.root + "/roms/riscos3_11"
        guard FileManager.default.fileExists(atPath: rom) else { throw XCTSkip("needs roms/riscos3_11") }
        let primes = Self.root + "/Examples/hello-basic/primes.bas"
        let host = try RunningHost(rom: rom)
        defer { host.stop() }
        let client = DAPClient(host: host)
        let initialize = try client.request("initialize", ["adapterID": "macarch"])
        let filters = (initialize["body"] as? [String: Any])?["exceptionBreakpointFilters"] as? [[String: Any]] ?? []
        XCTAssertEqual(filters.map { $0["filter"] as? String }, ["basicUntrapped", "basicAll"])
        _ = try client.event("initialized")

        let launch = try client.request("launch", ["basic": primes], timeout: 120)
        XCTAssertEqual(launch["success"] as? Bool, true, "\(launch)")
        // Text line 24 is PROCshow's count%=count%+1 (BASIC line 220): stop
        // there the third time (count% is 2: 2 and 3 found).
        let set = try client.request("setBreakpoints", ["source": ["path": primes], "breakpoints": [["line": 24, "condition": "count%=2"]]])
        let bps = (set["body"] as? [String: Any])?["breakpoints"] as? [[String: Any]] ?? []
        XCTAssertEqual(bps.first?["verified"] as? Bool, true, "\(set)")
        XCTAssertEqual(bps.first?["line"] as? Int, 24)
        try client.request("setExceptionBreakpoints", ["filters": ["basicUntrapped"]])
        try client.request("configurationDone")

        guard let stop = try? client.event("stopped", timeout: 60) else {
            let screen = host.inspect { $0.screenText.joined(separator: "\n") } ?? ""
            let state = host.inspect { m in "prompt=\(m.debugger.basic.isAtPrompt) bps=\(m.debugger.basic.breakpoints) listing=\(m.debugger.basic.listing().prefix(3))" } ?? ""
            XCTFail("stdout: \(client.stdout())\nscreen:\n\(screen)\n\(state)")
            return
        }
        XCTAssertEqual((stop["body"] as? [String: Any])?["reason"] as? String, "breakpoint", "\(stop)")
        func frames() throws -> [[String: Any]] {
            let trace = try client.request("stackTrace", ["threadId": 1])
            return (trace["body"] as? [String: Any])?["stackFrames"] as? [[String: Any]] ?? []
        }
        var stack = try frames()
        XCTAssertEqual(stack.map { $0["name"] as? String }, ["PROCshow", "main program"])
        XCTAssertEqual(stack.map { $0["line"] as? Int }, [24, 6])
        XCTAssertEqual((stack.first?["source"] as? [String: Any])?["path"] as? String, primes)
        // The call's statement (the whole IF: THEN doesn't start another).
        XCTAssertEqual(stack.last?["column"] as? Int, 3)

        let scopes = try client.request("scopes", ["frameId": stack[0]["id"] as? Int ?? 0])
        XCTAssertEqual(((scopes["body"] as? [String: Any])?["scopes"] as? [[String: Any]])?.first?["name"] as? String, "Locals")
        let locals = try client.request("variables", ["variablesReference": 100])
        let rows = (locals["body"] as? [String: Any])?["variables"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.map { $0["name"] as? String }, ["p%"])
        XCTAssertEqual(rows.first?["value"] as? String, "5")
        let sum = try client.request("evaluate", ["expression": "count%*10+p%", "frameId": stack[0]["id"] as? Int ?? 0])
        XCTAssertEqual((sum["body"] as? [String: Any])?["result"] as? String, "25")
        let changed = try client.request("setVariable", ["variablesReference": 100, "name": "p%", "value": "7"])
        XCTAssertEqual((changed["body"] as? [String: Any])?["value"] as? String, "7")

        // Out to the main program, then over a statement.
        try client.request("stepOut", ["threadId": 1]); _ = try client.event("stopped")
        stack = try frames()
        XCTAssertEqual(stack.map { $0["name"] as? String }, ["main program"])
        XCTAssertEqual(stack.first?["line"] as? Int, 7, "NEXT")
        try client.request("next", ["threadId": 1]); _ = try client.event("stopped")
        XCTAssertEqual(try frames().first?["line"] as? Int, 6)

        // Into FNprime.
        try client.request("stepIn", ["threadId": 1]); _ = try client.event("stopped")
        XCTAssertEqual(try frames().first?["name"] as? String, "FNprime")

        try client.request("setBreakpoints", ["source": ["path": primes], "breakpoints": []])
        try client.request("continue", ["threadId": 1])
        let deadline = Date().addingTimeInterval(20)
        while !client.stdout().contains("primes") && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertTrue(client.stdout().contains("2 3 7 7 11 13"), client.stdout())
        XCTAssertTrue(client.stdout().contains("Found 25 primes"), client.stdout())
        try client.request("disconnect")
    }

    func testAssemblyErrorsFailTheLaunch() throws {
        let dir = NSTemporaryDirectory() + "dap-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try " MOV R0, #&101\n".write(toFile: dir + "/bad.s", atomically: true, encoding: .utf8)
        let host = HeadlessSessionHost()
        let client = DAPClient(host: host)
        try client.request("initialize")
        let launch = try client.request("launch", ["source": dir + "/bad.s"])
        XCTAssertEqual(launch["success"] as? Bool, false)
        XCTAssertTrue((launch["message"] as? String ?? "").contains("bad.s:1: can't make &101"), "\(launch)")
        try client.request("disconnect")
    }
}

/// No machine at all: enough for requests that fail before using it.
final class HeadlessSessionHost: DebugAdapterHost, @unchecked Sendable {
    let session = try! HeadlessSession(configuration: nil)
    func perform<T>(_ body: @escaping (AgentSession) throws -> T) throws -> T { try session.perform(body) }
    func inspect<T>(_ body: @escaping (Machine) -> T) -> T? { nil }
}
