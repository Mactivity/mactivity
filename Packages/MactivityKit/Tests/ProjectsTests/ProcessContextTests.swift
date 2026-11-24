import Core
import Foundation
@testable import Projects
import Testing

@Suite("Where a runaway process runs (D-156)")
struct ProcessContextTests {
    @Test("The nearest agent above a process, through shells; none for a terminal's own")
    func agent() {
        let table = [
            AgentDetection.Entry(
                pid: 100,
                parentPID: 1,
                name: "Terminal",
                path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
            ),
            AgentDetection.Entry(pid: 200, parentPID: 100, name: "zsh", path: "/bin/zsh"),
            AgentDetection.Entry(pid: 300, parentPID: 200, name: "claude", path: "/usr/local/bin/claude"),
            AgentDetection.Entry(pid: 400, parentPID: 300, name: "zsh", path: "/bin/zsh"),
            AgentDetection.Entry(pid: 500, parentPID: 400, name: "node", path: "/opt/homebrew/bin/node"),
            AgentDetection.Entry(pid: 600, parentPID: 200, name: "node", path: "/opt/homebrew/bin/node"),
        ]
        #expect(ProcessContext.agent(of: 500, table: table) == "Claude Code")
        #expect(ProcessContext.agent(of: 600, table: table) == nil)
    }
}

/// A coding agent's worktree counts as its project's (agent history, build times).
struct AgentWorktreeTests {
    @Test("…/api/.claude/worktrees/agent-a1b2 is the api project")
    func worktree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)/api")
        let worktree = root.appendingPathComponent(".claude/worktrees/agent-a1b2c3")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Data().write(to: root.appendingPathComponent("Package.swift"))
        try Data().write(to: worktree.appendingPathComponent(".git"))
        #expect(LiveAgentSource.projectName(worktree.path) == "api")
        #expect(LiveAgentSource.projectName(root.path) == "api")
    }
}
