import Core
import Foundation

/// Where a process runs, for the runaway alert (D-156): its project folder, and the AI agent it
/// descends from, if any. Read once per finding, never on the sampling path.
public enum ProcessContext {
    public static func describe(_ pid: Int32) -> (project: String?, agent: String?) {
        let project = ProcessInspector.workingDirectory(pid).flatMap { directory in
            directory == NSHomeDirectory() || directory == "/" ? nil : LiveAgentSource.projectName(directory)
        }
        return (project, agent(of: pid, table: LiveAgentSource.table()))
    }

    /// Pure: the nearest ancestor that's an agent.
    static func agent(of pid: Int32, table: [AgentDetection.Entry]) -> String? {
        let byPID = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var current = byPID[pid]?.parentPID
        for _ in 0 ..< 64 {
            guard let id = current, id > 1, let entry = byPID[id] else {
                return nil
            }
            if let agent = AgentDetection.agent(entry) {
                return agent
            }
            current = entry.parentPID
        }
        return nil
    }
}
