@testable import Alerts
import Core
import Foundation

/// Builders for synthetic activity. Every test runs against a fixed clock and a fixed UTC calendar.
enum Fixture {
    /// 2026-09-25 12:00:00 UTC. A multiple of 5 s, so snapshots line up with buckets.
    static let now = Date(timeIntervalSince1970: 1_790_337_600)

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    static let app = AppIdentity(
        id: "com.example.hog", name: "Hog", bundleID: "com.example.hog", iconKey: "hog", kind: .app
    )
    static let other = AppIdentity(
        id: "com.example.other", name: "Other", bundleID: "com.example.other", iconKey: "other", kind: .app
    )

    static func context(now: Date = now, frontmost: AppIdentity.ID? = nil, peaks: [AppIdentity.ID: Double] = [:]) -> AlertContext {
        AlertContext(now: now, frontmostAppID: frontmost, calendar: calendar, usualPeakMemory: peaks)
    }

    /// The figures for one point.
    struct Values {
        var cpu = 0.0
        var memory: UInt64 = 0
        var disk = 0.0
        var netIn: Double?
        var netOut: Double?
    }

    /// One point every `step` seconds from `now − minutes` up to and including `now`.
    /// `values` receives the point's index and its age in seconds.
    static func points(
        minutes: Double,
        step: TimeInterval = 5,
        now: Date = now,
        _ values: (_ index: Int, _ secondsAgo: TimeInterval) -> Values
    ) -> [AppActivityPoint] {
        let count = Int((minutes * 60 / step).rounded(.down))
        return (0 ... count).map { index in
            let secondsAgo = Double(count - index) * step
            let value = values(index, secondsAgo)
            return AppActivityPoint(
                at: now.addingTimeInterval(-secondsAgo),
                cpuPercent: value.cpu,
                memoryBytes: value.memory,
                diskWriteBPS: value.disk,
                netInBPS: value.netIn,
                netOutBPS: value.netOut
            )
        }
    }

    static func history(_ points: [AppActivityPoint], app: AppIdentity = app) -> [AppActivityHistory] {
        [AppActivityHistory(app: app, points: points)]
    }

    /// Settings with only `rule` enabled, at the defaults unless overridden.
    static func only(
        _ rule: AlertRule,
        threshold: Double? = nil,
        window: Duration? = nil,
        exemptsFrontmostApp: Bool = true
    ) -> AlertSettings {
        var settings = AlertSettings.defaults
        for other in AlertRule.allCases {
            var ruleSettings = settings.settings(for: other)
            ruleSettings.isEnabled = other == rule
            if other == rule {
                ruleSettings.threshold = threshold ?? ruleSettings.threshold
                ruleSettings.window = window ?? ruleSettings.window
            }
            settings.rules[other] = ruleSettings
        }
        settings.exemptsFrontmostApp = exemptsFrontmostApp
        return settings
    }

    // MARK: Snapshots

    static let system = SystemSample(
        cpu: .aggregate(perCore: [], topology: CPUTopology(levels: []), loadAverage: .zero),
        memory: MemoryStats(
            totalBytes: 0, usedBytes: 0, appBytes: 0, wiredBytes: 0, compressedBytes: 0,
            cachedFilesBytes: 0, swapUsedBytes: 0, pressure: .normal, availableLevel: 100
        ),
        disk: DiskStats(volumes: [], readBPS: 0, writeBPS: 0),
        network: NetworkStats(inBPS: 0, outBPS: 0, primaryInterface: nil),
        gpu: nil,
        battery: nil,
        sensors: nil,
        thermal: .nominal,
        uptime: .zero
    )

    static func aggregate(
        _ app: AppIdentity = app,
        cpu: Double = 0,
        memory: UInt64 = 0,
        disk: Double = 0,
        netIn: Double? = nil,
        netOut: Double? = nil
    ) -> AppAggregate {
        AppAggregate(
            app: app, processCount: 1, cpuPercent: cpu, memoryBytes: memory, energyMW: nil,
            diskReadBPS: 0, diskWriteBPS: disk, netInBPS: netIn, netOutBPS: netOut, gpuPercent: nil
        )
    }

    static func snapshot(at date: Date, interval: Duration = .seconds(5), apps: [AppAggregate]) -> Snapshot {
        Snapshot(at: date, interval: interval, system: system, apps: apps, processes: [])
    }
}
