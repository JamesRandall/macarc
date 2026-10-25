import ArchimedesCore
import Foundation
import MacArchAgent
import XCTest

/// The BASIC tools, as an agent uses them: load a program, stop in it,
/// look around, step and finish.
final class BasicToolsTests: XCTestCase {
    func text(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
    }

    func testDebuggingAProgram() throws {
        let rom = DAPTests.root + "/roms/riscos3_11"
        guard FileManager.default.fileExists(atPath: rom) else { throw XCTSkip("needs roms/riscos3_11") }
        var c = MachineConfiguration()
        c.romPaths = [rom]
        let session = try HeadlessSession(configuration: c)
        let tools = AgentTools(context: session)
        try session.perform { s in s.advance(ticks: 20 * 24_000_000) }

        XCTAssertTrue(text(tools.call("basic_set_breakpoint", ["line": 220, "condition": "count%=2"])).hasPrefix("BASIC breakpoint 1: line 220 if count%=2"))
        let loaded = text(tools.call("basic_load", ["path": DAPTests.root + "/Examples/hello-basic/primes.bas", "max_seconds": 10]))
        XCTAssertTrue(loaded.contains("BASIC stopped at line 220"), loaded)
        XCTAssertTrue(loaded.contains("PROCshow at line 220"), loaded)
        XCTAssertTrue(loaded.contains("locals: p% = 5"), loaded)
        XCTAssertEqual(text(tools.call("basic_evaluate", ["expression": "count%*10+p%"])), "25")
        let listed = text(tools.call("basic_list", ["from": 210, "to": 230]))
        XCTAssertTrue(listed.contains(">*220count%=count%+1"), listed)
        XCTAssertTrue(text(tools.call("basic_variables", ["filter": "count"])).contains("count% = 2"))
        let stepped = text(tools.call("basic_step", ["kind": "out"]))
        XCTAssertTrue(stepped.hasPrefix("BASIC stopped at line 70"), stepped)
        _ = tools.call("basic_delete_breakpoint", ["all": true])
        XCTAssertEqual(text(tools.call("basic_list_breakpoints", [:])), "no BASIC breakpoints\nstop on errors: off")
    }
}
