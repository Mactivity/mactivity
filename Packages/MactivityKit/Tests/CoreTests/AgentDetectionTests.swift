import Core
import Foundation
import Testing

@Suite("AI agent sessions (D-148)")
struct AgentDetectionTests {
    private func entry(_ pid: Int32, _ parent: Int32, _ name: String, path: String? = nil, args: [String] = []) -> AgentDetection.Entry {
        AgentDetection.Entry(pid: pid, parentPID: parent, name: name, path: path, arguments: args)
    }

    @Test("Agents by name and by package; the Claude app itself isn't one")
    func agents() {
        #expect(AgentDetection.agent(entry(1, 0, "claude")) == "Claude Code")
        #expect(AgentDetection.agent(entry(1, 0, "Claude", path: "/Applications/Claude.app/Contents/MacOS/Claude")) == nil)
        #expect(AgentDetection.agent(entry(1, 0, "codex")) == "Codex")
        #expect(AgentDetection.agent(entry(1, 0, "node", args: ["node", "/opt/homebrew/lib/node_modules/@google/gemini-cli/dist/index.js"]))
            == "Gemini CLI")
        #expect(AgentDetection.agent(entry(1, 0, "node", args: ["node", "server.js"])) == nil)
    }

    @Test("One session per agent, with every descendant; a re-exec'd agent counts once")
    func sessions() {
        let table = [
            entry(10, 1, "Terminal", path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
            entry(11, 10, "zsh"),
            entry(12, 11, "claude"),
            entry(13, 12, "claude"),
            entry(14, 13, "zsh"),
            entry(15, 14, "node"),
            entry(20, 11, "vim"),
        ]
        let found = AgentDetection.sessions(table)
        #expect(found.count == 1)
        #expect(found.first?.root.pid == 12)
        #expect(Set(found.first?.descendants.map(\.pid) ?? []) == [13, 14, 15])
        #expect(AgentDetection.host(of: 12, table: table) == "Terminal")
    }
}
