import AppIntents
import Core
import Foundation
import Grouping
import History
import Projects
import Sampling

/// Where the intents get their figures: the running pipeline's latest snapshot when there is
/// one, else a one-shot tick pair. App Intents run in the app's process, so "not running" means
/// macOS just launched Mactivity for this intent and the pipeline hasn't published yet. Simulated
/// data is never handed to Shortcuts; it samples for real instead.
@MainActor
enum IntentData {
    static func snapshot() async throws -> Snapshot {
        let metrics = AppModel.shared.services.metrics
        if !metrics.isSimulated, let snapshot = metrics.snapshot {
            return snapshot
        }
        return await oneShot()
    }

    /// Uses the app's own `ProjectMonitor`, which has been watching CPU use and so knows what's
    /// idle. A fresh monitor (simulated mode) has watched for one tick and reports nothing idle.
    static func projects() async throws -> [Project] {
        let model = AppModel.shared
        // Only once the pipeline runs: until then (macOS just launched Mactivity for this
        // Shortcut) the projects model still holds the simulated placeholder (D-145).
        if !model.isSimulated, model.pipeline != nil {
            await model.services.projects.refresh()
            return model.services.projects.projects
        }
        let snapshot = await oneShot()
        let monitor = ProjectMonitor()
        await monitor.observe(snapshot)
        return await (try? monitor.projects()) ?? []
    }

    /// The history file, read-only, as the `mactivity` command reads it (1.6): never the simulated
    /// store, whatever the app shows.
    struct NoHistory: Error, CustomLocalizedStringResourceConvertible {
        var localizedStringResource: LocalizedStringResource {
            "Mactivity hasn't recorded any history yet."
        }
    }

    static func history() async throws -> SQLiteHistoryStore {
        guard let url = try? SQLiteHistoryStore.defaultURL(), FileManager.default.fileExists(atPath: url.path),
              let store = try? SQLiteHistoryStore.openReadOnly(url: url) else {
            throw NoHistory()
        }
        return store
    }

    /// Two ticks a second apart, shared with the `mactivity` command. No helper: local reads only.
    private static func oneShot() async -> Snapshot {
        await SnapshotSampler.oneShot()
    }
}
