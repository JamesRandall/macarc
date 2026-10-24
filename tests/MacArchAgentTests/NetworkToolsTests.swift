import ArchimedesCore
import Foundation
import MacArchAgent
import XCTest

/// The network tools' plumbing: `machine` picks a directory's machine, and
/// the network tools go to the directory. (No ROM needed: the machines here
/// are empty.)
final class NetworkToolsTests: XCTestCase {
    final class Directory: MachineDirectory {
        var asked: [String] = []
        var networkCalls: [String] = []
        let station = try! HeadlessSession(configuration: nil)

        func context(for machine: String) throws -> AgentContext {
            asked.append(machine)
            guard machine == "Station 1" else { throw ToolError(message: "not_found: no machine \"\(machine)\"") }
            return station
        }

        func networkTool(_ name: String, _ arguments: [String: Any]) throws -> ToolOutput {
            networkCalls.append(name)
            return ToolOutput("network: \(name)")
        }
    }

    func text(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
    }

    func testToolsNameTheirMachine() throws {
        let directory = Directory()
        let tools = AgentTools(context: try HeadlessSession(configuration: nil), directory: directory)
        let names = tools.toolList.compactMap { $0["name"] as? String }
        for tool in ["list_machines", "network_status", "network_power", "network_trace", "network_set_up_level4", "econet_status"] {
            XCTAssertTrue(names.contains(tool), tool)
        }
        let status = tools.toolList.first { $0["name"] as? String == "get_status" }
        let props = (status?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
        XCTAssertNotNil(props?["machine"])

        _ = tools.call("get_status", ["machine": "Station 1"])
        XCTAssertEqual(directory.asked, ["Station 1"])
        let missing = tools.call("get_status", ["machine": "Station 9"])
        XCTAssertEqual(missing["isError"] as? Bool, true)
        XCTAssertTrue(text(missing).hasPrefix("not_found"), text(missing))

        XCTAssertEqual(text(tools.call("network_status", [:])), "network: network_status")
        XCTAssertEqual(directory.networkCalls, ["network_status"])
    }

    func testHeadlessHasNoNetworks() throws {
        let tools = AgentTools(context: try HeadlessSession(configuration: nil))
        let names = tools.toolList.compactMap { $0["name"] as? String }
        XCTAssertFalse(names.contains("list_machines"))
        XCTAssertTrue(names.contains("econet_status"))
        let result = tools.call("get_status", ["machine": "Station 1"])
        XCTAssertEqual(result["isError"] as? Bool, true)
    }
}
