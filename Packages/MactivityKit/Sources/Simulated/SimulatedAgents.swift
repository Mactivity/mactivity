import Core
import Foundation

/// Sample AI agent sessions (D-148), for previews, tests and simulated data.
public struct SimulatedAgentSource: AgentSource {
    public init() {}

    public func sessions() async throws -> [AgentSession] {
        let now = Date()
        return [
            AgentSession(
                pid: 5101, agent: "Claude Code", project: "storefront-web", directory: "/Users/demo/Developer/storefront-web",
                host: "Terminal", startedAt: now.addingTimeInterval(-42 * 60), processCount: 9, cpuPercent: 7.8,
                memoryBytes: 1_240_000_000, busiestChildren: ["node", "vitest"], stopTargets: [.processGroup(5101)]
            ),
            AgentSession(
                pid: 5201, agent: "Codex", project: "api", directory: "/Users/demo/Developer/api", host: "iTerm",
                startedAt: now.addingTimeInterval(-3 * 3600), processCount: 4, cpuPercent: 1.2, memoryBytes: 410_000_000,
                busiestChildren: ["python3.13"], stopTargets: [.processGroup(5201)]
            ),
            AgentSession(
                pid: 5301, agent: "Claude Code", project: "docs-site", directory: "/Users/demo/Developer/docs-site", host: "Claude",
                startedAt: now.addingTimeInterval(-15 * 60), processCount: 2, cpuPercent: 0.3, memoryBytes: 286_000_000,
                busiestChildren: [], stopTargets: [.process(5301), .process(5302)]
            ),
        ]
    }
}
