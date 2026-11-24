import Core
import Foundation
@testable import Mactivity
import Readouts
import Testing

/// The Shortcuts results carry the same figures the app shows (E6).
@Suite("Intent results")
struct IntentResultTests {
    private func snapshot() throws -> Snapshot {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Packages/MactivityKit/Tests/Fixtures/snapshot-readouts.json")
        return try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
    }

    @Test("System stats entity")
    func systemStats() throws {
        let entity = try SystemStatsEntity(snapshot())
        #expect(entity.cpuPercent == 23.4)
        #expect(entity.memoryUsedBytes == 19_327_352_832)
        #expect(entity.memoryTotalBytes == 51_539_607_552)
        #expect(entity.memoryPressure == "normal")
        #expect(entity.batteryPercent == 87)
        #expect(entity.isCharging)
        #expect(entity.summary.hasPrefix("CPU is at 23%."))
    }

    @Test("Every Shortcuts metric maps to the same-named ranking")
    func metrics() {
        for metric in [AppMetric.cpu, .memory, .energy, .disk, .network] {
            #expect(metric.ranking.rawValue == metric.rawValue)
        }
    }

    @Test("App usage entity carries the ranked figure")
    func appUsage() throws {
        let apps = try AppRanking.memory.rank(snapshot().apps, limit: 1, includingSystem: false)
        let xcode = try #require(apps.first)
        let entity = AppUsageEntity(xcode, ranking: .memory)
        #expect(entity.name == "Xcode")
        #expect(entity.bundleID == "com.apple.dt.Xcode")
        #expect(entity.processCount == 14)
        #expect(entity.memoryBytes == 6_657_199_308)
        #expect(entity.value == AppRanking.memory.formatted(xcode))
    }

    @Test("Dev server entity")
    func devServer() {
        let server = DevServer(
            pid: 5120, name: "python3", command: "python3 -m uvicorn app:api", runtime: .python, ports: [8080, 8081],
            memoryBytes: 96_468_992, startedAt: Date(), cpuTime: .seconds(70), activity: .idle(minutes: 125),
            stopTarget: .process(5120)
        )
        let project = Project(rootPath: "/Users/demo/Developer/api", name: "api", servers: [server])
        let entity = DevServerEntity(server, project: project)
        #expect(entity.project == "api")
        #expect(entity.projectPath == "/Users/demo/Developer/api")
        #expect(entity.ports == [8080, 8081])
        #expect(entity.pid == 5120)
        #expect(entity.isIdle)
        #expect(entity.activity == "Idle 2h 5m")
        #expect(entity.runtime == "Python")
    }
}
