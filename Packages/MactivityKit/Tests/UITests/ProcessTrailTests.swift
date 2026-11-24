import Core
import Foundation
import Testing
@testable import UI

struct ProcessTrailTests {
    private func snapshot(at seconds: Double, pid: Int32?, cpu: Double = 10, memory: UInt64 = 1000) -> Snapshot {
        let processes = pid.map {
            [ProcessSample(
                pid: $0, app: "app", name: "p", cpuPercent: cpu, footprintBytes: memory,
                diskReadBPS: 0, diskWriteBPS: 0, energyMW: nil, netInBPS: nil, netOutBPS: nil, gpuPercent: nil
            )]
        } ?? []
        let system = SystemSample(
            cpu: CPUStats(totalPercent: 0, userPercent: 0, systemPercent: 0, perCorePercent: [0], clusters: [], loadAverage: .zero),
            memory: MemoryStats(
                totalBytes: 1, usedBytes: 0, appBytes: 0, wiredBytes: 0, compressedBytes: 0, cachedFilesBytes: 0,
                swapUsedBytes: 0, pressure: .normal, availableLevel: 100
            ),
            disk: DiskStats(volumes: [], readBPS: 0, writeBPS: 0), network: NetworkStats(inBPS: 0, outBPS: 0, primaryInterface: nil),
            gpu: nil, battery: nil, sensors: nil, thermal: .nominal, uptime: .zero
        )
        return Snapshot(at: Date(timeIntervalSince1970: seconds), interval: .seconds(1), system: system, apps: [], processes: processes)
    }

    @Test("Collects one point per snapshot for the pid, skips repeats and snapshots without it, caps its length")
    func collects() {
        var trail = ProcessTrail()
        trail.add(snapshot(at: 1, pid: 7, cpu: 5, memory: 100), pid: 7)
        trail.add(snapshot(at: 1, pid: 7, cpu: 9, memory: 900), pid: 7) // same snapshot again
        trail.add(snapshot(at: 2, pid: 8), pid: 7) // another process only
        trail.add(snapshot(at: 3, pid: 7, cpu: 6, memory: 200), pid: 7)
        #expect(trail.cpu.map(\.value) == [5, 6])
        #expect(trail.memory.map(\.value) == [100, 200])

        for second in 4 ..< 200 {
            trail.add(snapshot(at: Double(second), pid: 7), pid: 7)
        }
        #expect(trail.cpu.count == ProcessTrail.capacity)
        #expect(trail.memory.count == ProcessTrail.capacity)
    }

    @Test("Says Not sampled after two snapshots in a row without the pid, and not once it has a line")
    func unsampled() {
        var trail = ProcessTrail()
        #expect(!trail.isUnsampled)
        trail.add(snapshot(at: 1, pid: nil), pid: 7)
        #expect(!trail.isUnsampled, "one miss is still measuring")
        trail.add(snapshot(at: 1, pid: nil), pid: 7) // the same snapshot again isn't a second miss
        #expect(!trail.isUnsampled)
        trail.add(snapshot(at: 2, pid: 8), pid: 7)
        #expect(trail.isUnsampled)
        trail.add(snapshot(at: 3, pid: 7), pid: 7)
        #expect(!trail.isUnsampled, "the process turned up")
        #expect(trail.missedSnapshots == 0)
        trail.add(snapshot(at: 4, pid: 7), pid: 7)
        trail.add(snapshot(at: 5, pid: nil), pid: 7)
        trail.add(snapshot(at: 6, pid: nil), pid: 7)
        #expect(!trail.isUnsampled, "a line already drawn stays")
    }
}
