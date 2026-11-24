import Core
import Foundation
import Projects
import Readouts

/// `mactivity mcp` (D-152): a Model Context Protocol server on stdin and stdout, so a coding
/// agent (Claude Code, Codex, Cursor…) can ask what the Mac is doing. One JSON-RPC message per
/// line, as MCP's stdio transport has it.
///
/// Read-only, like the rest of this tool: there's no tool that stops, quits or changes anything
/// (CLAUDE.md rule 4). It opens no socket and sends nothing anywhere itself (rule 3); what the
/// agent does with the answers is up to the agent the person connected.
enum MCPServer {
    /// Newest first; the client's is used when it's one of these.
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    /// What a tool call does, injectable for tests.
    struct Tools {
        var call: (_ name: String, _ arguments: [String: Any]) async throws -> String

        static var live: Tools {
            Tools { name, arguments in try await LiveTools.call(name, arguments) }
        }
    }

    enum ToolError: Error, CustomStringConvertible {
        case unknownTool(String)
        case invalidArgument(String)

        var description: String {
            switch self {
            case let .unknownTool(name): "Unknown tool '\(name)'."
            case let .invalidArgument(text): text
            }
        }
    }

    static func run() async -> Int32 {
        while let line = readLine(strippingNewline: true) {
            if let reply = await handle(line, tools: .live) {
                guard (try? FileHandle.standardOutput.write(contentsOf: Data((reply + "\n").utf8))) != nil else {
                    return CLI.ExitCode.failure
                }
            }
        }
        return CLI.ExitCode.success
    }

    /// One message in, at most one reply out (none for a notification). Pure apart from `tools`.
    static func handle(_ line: String, tools: Tools) async -> String? {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let method = message["method"] as? String else {
            // A response to a request (this server sends none) gets no reply; anything else is invalid.
            if message["result"] != nil || message["error"] != nil {
                return nil
            }
            return error(message["id"] ?? NSNull(), code: -32600, "Invalid request")
        }
        // A notification (no id) gets no reply, whatever it is.
        guard let id = message["id"] else {
            return nil
        }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            let version = asked.flatMap { protocolVersions.contains($0) ? $0 : nil } ?? protocolVersions[0]
            return reply(id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "mactivity", "title": "Mactivity", "version": Version.string],
                "instructions": instructions,
            ])
        case "ping":
            return reply(id, [:])
        case "tools/list":
            return reply(id, ["tools": toolList])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return error(id, code: -32602, "tools/call needs a tool name.")
            }
            do {
                let text = try await tools.call(name, params["arguments"] as? [String: Any] ?? [:])
                return reply(id, toolResult(text, isError: false))
            } catch let failure as ToolError {
                if case .unknownTool = failure {
                    return error(id, code: -32602, failure.description)
                }
                return reply(id, toolResult(failure.description, isError: true))
            } catch {
                return reply(id, toolResult("Couldn't read the Mac: \(error.localizedDescription)", isError: true))
            }
        default:
            return error(id, code: -32601, "Method not found: \(method)")
        }
    }

    static let instructions = """
    Mactivity reads what this Mac is doing, grouped by app. The live tools sample for about a \
    second; agent_history, day, unusual_today and build_history read the history Mactivity keeps. None changes anything. \
    Figures are percent of the whole Mac for CPU, bytes for memory, bytes per second for disk \
    and network, milliwatts for energy.
    """

    static var toolList: [[String: Any]] {
        [
            tool(
                "system", title: "The whole Mac now",
                "CPU (with load average), memory and memory pressure, swap, disks and free space, network, GPU, battery, "
                    + "temperatures, fans and thermal pressure."
            ),
            tool(
                "top_apps", title: "Busiest apps",
                "Apps sorted by one figure, highest first, each app's processes summed (Chrome's helpers count as Chrome).",
                properties: [
                    "by": ["type": "string", "enum": AppRanking.allCases.map(\.rawValue), "description": "What to sort by. Default cpu."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 50, "description": "How many apps. Default 10."],
                ]
            ),
            tool(
                "why_slow", title: "Why is my Mac slow?",
                "What's slowing the Mac down right now, worst first: heat, memory pressure, a busy app, Spotlight or another "
                    + "background job, a full disk. An empty list means nothing stands out."
            ),
            tool(
                "dev_servers", title: "Dev servers",
                "Your processes listening on a TCP port, outside app bundles, grouped by project folder, with CPU and memory."
            ),
            tool(
                "agents", title: "AI agent sessions",
                "Running AI coding agents (Claude Code, Codex, Gemini CLI, Aider and others): project, the app they run in, "
                    + "and what each session and everything it started uses."
            ),
            tool(
                "agent_history", title: "Agent history",
                "Coding agents over the last days, from history: each agent's time per project, its average CPU and peak "
                    + "memory, and agent time by day. Times are seconds.",
                properties: ["days": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 90,
                    "description": "How many days, today included. Default 7.",
                ]]
            ),
            tool(
                "day", title: "A day on this Mac",
                "One day from history, in order: wakes and sleep, busy stretches and slowdowns with the apps behind them, "
                    + "charging, big downloads, alerts, crashes and agent sessions, with time in use.",
                properties: ["date": ["type": "string", "description": "today, yesterday or YYYY-MM-DD. Default today."]]
            ),
            tool(
                "unusual_today", title: "Out of the ordinary today",
                "Apps doing far more today than their usual day on this Mac (the median of the last two weeks): processor, "
                    + "memory or power at 2.5 times usual or more, or busy when usually idle. Empty while still learning."
            ),
            tool(
                "build_history", title: "Build times",
                "Builds by project, timed from the compiler processes Mactivity saw: each project's build count, last build, "
                    + "and its median build this week beside the three weeks before, flagged when slower. Seconds. "
                    + "Processor and memory are only what samples caught, so lower bounds.",
                properties: ["days": [
                    "type": "integer", "minimum": 1, "maximum": 90, "description": "How many days of builds to list. Default 7.",
                ]]
            ),
        ]
    }

    private static func tool(_ name: String, title: String, _ description: String, properties: [String: Any] = [:]) -> [String: Any] {
        [
            "name": name, "title": title, "description": description,
            "inputSchema": ["type": "object", "properties": properties, "additionalProperties": false],
            "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false],
        ]
    }

    private static func toolResult(_ text: String, isError: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private static func reply(_ id: Any, _ result: [String: Any]) -> String? {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func error(_ id: Any, code: Int, _ message: String) -> String? {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func encode(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

/// The tools' live answers, as the `--json` output's schemas where there is one.
enum LiveTools {
    static func call(_ name: String, _ arguments: [String: Any]) async throws -> String {
        switch name {
        case "system":
            return try await JSONOutput.encode(SystemJSON(LiveSampling.snapshot()), pretty: false)
        case "top_apps":
            var options = Command.TopOptions()
            options.limit = 10
            if let by = arguments["by"] {
                guard let raw = by as? String, let ranking = AppRanking(rawValue: raw) else {
                    throw MCPServer.ToolError
                        .invalidArgument("'by' is one of: \(AppRanking.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                options.ranking = ranking
            }
            if let limit = arguments["limit"] {
                // JSON true bridges to 1 through NSNumber: only real numbers count.
                guard let value = limit as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                      let number = limit as? Int, (1 ... 50).contains(number) else {
                    throw MCPServer.ToolError.invalidArgument("'limit' is a whole number from 1 to 50.")
                }
                options.limit = number
            }
            return try await JSONOutput.encode(TopJSON(LiveSampling.snapshot(), options: options), pretty: false)
        case "why_slow":
            // Two seconds: the diagnosis averages, and one second of a spike reads as more than it is.
            let snapshot = await LiveSampling.snapshot(window: .seconds(2))
            let causes = Slowdown.diagnose([snapshot], lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
            return try JSONOutput.encode(SlowdownJSON(causes), pretty: false)
        case "dev_servers":
            let snapshot = await LiveSampling.snapshot()
            let projects = try await LiveSampling.projects(in: snapshot)
            return try JSONOutput.encode(ProjectsJSON(projects, scannedAt: Date(), activityWindow: LiveSampling.window), pretty: false)
        case "agents":
            // CPU is the change between two reads.
            let source = LiveAgentSource()
            _ = try await source.sessions()
            try? await Task.sleep(for: LiveSampling.window)
            return try await JSONOutput.encode(AgentsJSON(source.sessions(), now: Date()), pretty: false)
        case "agent_history", "day", "unusual_today", "build_history":
            return try await history(name, arguments)
        default:
            throw MCPServer.ToolError.unknownTool(name)
        }
    }
}

extension LiveTools {
    /// The tools that read Mactivity's history rather than sampling.
    static func history(_ name: String, _ arguments: [String: Any]) async throws -> String {
        switch name {
        case "agent_history":
            return try await JSONOutput.encode(HistoryReading.agents(days: days(arguments)), pretty: false)
        case "build_history":
            return try await JSONOutput.encode(HistoryReading.builds(days: days(arguments)), pretty: false)
        case "unusual_today":
            return try await JSONOutput.encode(HistoryReading.unusual(), pretty: false)
        default:
            var spec = DaySpec.today
            if let value = arguments["date"] {
                guard let text = value as? String, let parsed = DaySpec(text) else {
                    throw MCPServer.ToolError.invalidArgument("'date' is today, yesterday or YYYY-MM-DD.")
                }
                spec = parsed
            }
            return try await JSONOutput.encode(HistoryReading.day(spec), pretty: false)
        }
    }

    /// `days`, 1 to 90, default 7. JSON true bridges to 1 through NSNumber: only real numbers count.
    static func days(_ arguments: [String: Any]) throws -> Int {
        guard let value = arguments["days"] else {
            return 7
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let whole = value as? Int, (1 ... 90).contains(whole) else {
            throw MCPServer.ToolError.invalidArgument("'days' is a whole number from 1 to 90.")
        }
        return whole
    }
}

struct SlowdownJSON: Encodable {
    struct Cause: Encodable {
        let kind: String
        let severity: String
        let title: String
        let detail: String
        @NullEncoded var app: String?
    }

    let schemaVersion = JSONOutput.schemaVersion
    let causes: [Cause]

    init(_ causes: [SlowdownCause]) {
        self.causes = causes.map { cause in
            Cause(
                kind: cause.kind.rawValue,
                severity: cause.severity == .major ? "major" : "minor",
                title: cause.title,
                detail: cause.detail,
                app: cause.app?.name
            )
        }
    }
}

struct AgentsJSON: Encodable {
    struct Session: Encodable {
        let pid: Int32
        let agent: String
        @NullEncoded var project: String?
        @NullEncoded var directory: String?
        @NullEncoded var host: String?
        let processCount: Int
        let cpuPercent: Double
        let memoryBytes: UInt64
        let runningSeconds: Double
        let busiestChildren: [String]
    }

    let schemaVersion = JSONOutput.schemaVersion
    let sessions: [Session]

    init(_ sessions: [AgentSession], now: Date) {
        self.sessions = sessions.map { session in
            Session(
                pid: session.pid, agent: session.agent, project: session.project, directory: session.directory, host: session.host,
                processCount: session.processCount, cpuPercent: JSONOutput.round(session.cpuPercent), memoryBytes: session.memoryBytes,
                runningSeconds: JSONOutput.round(max(0, now.timeIntervalSince(session.startedAt))),
                busiestChildren: session.busiestChildren
            )
        }
    }
}
