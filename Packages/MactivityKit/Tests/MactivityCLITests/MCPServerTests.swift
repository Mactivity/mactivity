import Foundation
@testable import MactivityCLI
import Testing

@Suite("mactivity mcp (D-152)")
struct MCPServerTests {
    private let echo = MCPServer.Tools { name, arguments in "\(name) \(arguments.keys.sorted())" }

    private func send(_ message: String) async -> [String: Any]? {
        guard let reply = await MCPServer.handle(message, tools: echo),
              let data = reply.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    @Test("initialize answers with the client's version when supported, else the newest")
    func initialize() async {
        let known = await send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#)
        let result = known?["result"] as? [String: Any]
        #expect(result?["protocolVersion"] as? String == "2025-03-26")
        #expect((result?["serverInfo"] as? [String: Any])?["name"] as? String == "mactivity")
        #expect(known?["id"] as? Int == 1)
        let unknown = await send(#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        #expect((unknown?["result"] as? [String: Any])?["protocolVersion"] as? String == MCPServer.protocolVersions[0])
        #expect(unknown?["id"] as? String == "a")
    }

    @Test("Notifications get no reply; unknown methods and bad JSON get errors")
    func protocolErrors() async {
        #expect(await MCPServer
            .handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, tools: echo) == nil)
        #expect(await MCPServer.handle("   ", tools: echo) == nil)
        let unknown = await send(#"{"jsonrpc":"2.0","id":2,"method":"resources/list"}"#)
        #expect((unknown?["error"] as? [String: Any])?["code"] as? Int == -32601)
        let garbage = await send("{not json")
        #expect((garbage?["error"] as? [String: Any])?["code"] as? Int == -32700)
        let noMethod = await send(#"{"jsonrpc":"2.0","id":9}"#)
        #expect((noMethod?["error"] as? [String: Any])?["code"] as? Int == -32600)
        #expect(await MCPServer.handle(#"{"jsonrpc":"2.0","id":9,"result":{}}"#, tools: echo) == nil)
    }

    @Test("Nine read-only tools, each marked read-only")
    func list() async {
        let reply = await send(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)
        let tools = (reply?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        #expect(tools.compactMap { $0["name"] as? String } == [
            "system",
            "top_apps",
            "why_slow",
            "dev_servers",
            "agents",
            "agent_history",
            "day",
            "unusual_today",
            "build_history",
        ])
        for tool in tools {
            let annotations = tool["annotations"] as? [String: Any]
            #expect(annotations?["readOnlyHint"] as? Bool == true)
            #expect(annotations?["destructiveHint"] as? Bool == false)
        }
    }

    @Test("A call runs the tool with its arguments")
    func call() async {
        let message = #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"top_apps","arguments":{"by":"memory","limit":3}}}"#
        let reply = await send(message)
        let result = reply?["result"] as? [String: Any]
        let text = (result?["content"] as? [[String: Any]])?.first?["text"] as? String
        #expect(text == "top_apps [\"by\", \"limit\"]")
        #expect(result?["isError"] as? Bool == false)
    }

    @Test("Bad arguments are a tool error the agent can read; an unknown tool is a protocol error")
    func badArguments() async throws {
        await #expect(throws: MCPServer.ToolError.self) { _ = try await LiveTools.call("top_apps", ["by": "colour"]) }
        await #expect(throws: MCPServer.ToolError.self) { _ = try await LiveTools.call("top_apps", ["limit": 500]) }
        await #expect(throws: MCPServer.ToolError.self) { _ = try await LiveTools.call("top_apps", ["limit": true]) }
        let unknown = MCPServer.Tools { name, _ in throw MCPServer.ToolError.unknownTool(name) }
        let reply = await MCPServer.handle(
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nope"}}"#, tools: unknown
        )
        #expect(reply?.contains("-32602") == true)
    }

    @Test("mcp takes no arguments")
    func parse() throws {
        #expect(try ArgumentParser.parse(["mcp"]) == .mcp)
        #expect(try ArgumentParser.parse(["mcp", "--help"]) == .help(topic: "mcp"))
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["mcp", "--port"]) }
    }
}
