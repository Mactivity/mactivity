import Core
import Foundation
import Grouping
import Projects
import Sampling

/// One-shot sampling for the command: `SnapshotSampler.oneShot()`, shared with Shortcuts.
enum LiveSampling {
    static let window: Duration = .seconds(1)

    static func snapshot(window: Duration = window) async -> Snapshot {
        await SnapshotSampler.oneShot(window: window)
    }

    /// Dev servers among the snapshot's processes. A fresh monitor has watched for one tick, so
    /// nothing reads as idle (see `mactivity help projects`).
    static func projects(in snapshot: Snapshot) async throws -> [Project] {
        let monitor = ProjectMonitor()
        await monitor.observe(snapshot)
        return try await monitor.projects()
    }
}
