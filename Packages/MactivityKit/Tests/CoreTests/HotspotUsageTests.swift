import Core
import Foundation
import Testing

@Suite("Data on an iPhone's hotspot (D-136)")
struct HotspotUsageTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(interval: Duration = .seconds(10), total: Double, apps: [(String, Double?)]) -> Snapshot {
        let aggregates = apps.map { id, rate in
            AppAggregate(
                app: AppIdentity(id: id, name: id, bundleID: id, iconKey: "", kind: .app),
                processCount: 1, cpuPercent: 0, memoryBytes: 0, energyMW: nil, diskReadBPS: 0, diskWriteBPS: 0,
                netInBPS: rate, netOutBPS: rate.map { $0 / 10 }, gpuPercent: nil
            )
        }
        return Snapshot(
            at: start, interval: interval,
            system: SystemSample(
                cpu: CPUStats(totalPercent: 0, userPercent: 0, systemPercent: 0, perCorePercent: [], clusters: [], loadAverage: .zero),
                memory: MemoryStats(
                    totalBytes: 1, usedBytes: 0, appBytes: 0, wiredBytes: 0, compressedBytes: 0, cachedFilesBytes: 0,
                    swapUsedBytes: 0, pressure: .normal, availableLevel: 100
                ),
                disk: DiskStats(volumes: [], readBPS: 0, writeBPS: 0),
                network: NetworkStats(inBPS: total, outBPS: 0, primaryInterface: "en0"),
                gpu: nil, battery: nil, sensors: nil, thermal: .nominal, uptime: .seconds(1)
            ),
            apps: aggregates, processes: []
        )
    }

    @Test("Each snapshot adds rate × interval, per app and for the whole Mac; most first")
    func adds() {
        var session = HotspotSession(start: start)
        session.add(snapshot(total: 2_000_000, apps: [("Dropbox", 1_000_000), ("Safari", 100_000), ("Mail", nil)]))
        session.add(snapshot(total: 2_000_000, apps: [("Dropbox", 1_000_000)]))
        #expect(session.totalBytes == 40_000_000)
        // 1 MB/s in and 0.1 MB/s out, for 20 s.
        #expect(session.top.map(\.app.id) == ["Dropbox", "Safari"])
        #expect(session.top.first?.bytes == 22_000_000)
    }

    @Test("A sleep gap counts at most a minute (D-133)")
    func sleepGap() {
        var session = HotspotSession(start: start)
        session.add(snapshot(interval: .seconds(3600), total: 1000, apps: [("Dropbox", 1000)]))
        #expect(session.totalBytes == 60000)
    }

    @Test("Recent usage is handed out once, for the 10-minute alert check")
    func recent() {
        var session = HotspotSession(start: start)
        session.add(snapshot(total: 0, apps: [("Dropbox", 1_000_000)]))
        #expect(session.takeRecent().map(\.app.id) == ["Dropbox"])
        #expect(session.takeRecent().isEmpty)
        #expect(session.top.count == 1, "the session keeps its totals")
    }
}
