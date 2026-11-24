import Core
import Foundation
import Testing

@Suite("Apps open but unused (D-135)")
struct UnusedAppsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86400

    private func app(_ id: String, memory: UInt64, kind: AppIdentity.Kind = .app, cpu: Double = 0) -> AppAggregate {
        AppAggregate(
            app: AppIdentity(id: id, name: id, bundleID: id, iconKey: "", kind: kind),
            processCount: 1, cpuPercent: cpu, memoryBytes: memory, energyMW: nil, diskReadBPS: 0, diskWriteBPS: 0,
            netInBPS: nil, netOutBPS: nil, gpuPercent: nil
        )
    }

    private func find(
        _ apps: [AppAggregate], running: [UnusedApps.Running], lastFront: [String: Date] = [:], since: Date? = nil
    ) -> [String] {
        UnusedApps.find(
            apps: apps, running: running, lastFront: lastFront,
            recordingSince: since ?? now - 30 * day, own: "app.mactivity.Mactivity", now: now
        ).map(\.id)
    }

    @Test("Last in front 4 days ago and holding memory: listed, largest first")
    func listed() {
        let apps = [app("Xcode", memory: 4_000_000_000), app("Docker", memory: 6_000_000_000), app("Mail", memory: 500_000_000)]
        let running = apps.map { UnusedApps.Running(id: $0.id, launchedAt: now - 20 * day) }
        let lastFront = ["Xcode": now - 4 * day, "Docker": now - 10 * day, "Mail": now - 3600]
        #expect(find(apps, running: running, lastFront: lastFront) == ["Docker", "Xcode"])
    }

    @Test("Never in front: unused since it opened, or since recording began")
    func neverInFront() {
        let apps = [app("Opened recently", memory: 1_000_000_000), app("Opened long ago", memory: 1_000_000_000)]
        let running = [
            UnusedApps.Running(id: "Opened recently", launchedAt: now - day),
            UnusedApps.Running(id: "Opened long ago", launchedAt: now - 60 * day),
        ]
        #expect(find(apps, running: running) == ["Opened long ago"])
        // Recording began two days ago: nothing is known to be unused for three.
        #expect(find(apps, running: running, since: now - 2 * day).isEmpty)
    }

    @Test("Relaunched since it was last used: counts from the relaunch")
    func relaunched() {
        let apps = [app("Slack", memory: 800_000_000)]
        let running = [UnusedApps.Running(id: "Slack", launchedAt: now - day)]
        #expect(find(apps, running: running, lastFront: ["Slack": now - 9 * day]).isEmpty)
    }

    @Test("An app working in the background now isn't unused")
    func busy() {
        let apps = [app("Docker", memory: 3_000_000_000, cpu: 2.5)]
        let running = [UnusedApps.Running(id: "Docker", launchedAt: now - 20 * day)]
        #expect(find(apps, running: running).isEmpty)
    }

    @Test("Apps kept open for their notifications or playback aren't listed")
    func keptOpen() {
        let apps = [app("com.apple.mail", memory: 900_000_000), app("com.tinyspeck.slackmacgap", memory: 1_200_000_000)]
        let running = apps.map { UnusedApps.Running(id: $0.id, launchedAt: now - 20 * day) }
        #expect(find(apps, running: running).isEmpty)
    }

    @Test("Small apps, menu bar helpers, macOS and Mactivity itself aren't listed")
    func excluded() {
        let apps = [
            app("Tiny", memory: 100_000_000),
            app("Helper", memory: 2_000_000_000),
            app("macOS", memory: 9_000_000_000, kind: .system),
            app("app.mactivity.Mactivity", memory: 400_000_000),
        ]
        // "Helper" isn't a regular app, so it isn't in `running`.
        let running = ["Tiny", "macOS", "app.mactivity.Mactivity"].map { UnusedApps.Running(id: $0, launchedAt: now - 20 * day) }
        #expect(find(apps, running: running).isEmpty)
        #expect(UnusedApps.find(apps: apps, running: running, lastFront: [:], recordingSince: nil, own: nil, now: now).isEmpty)
    }
}
