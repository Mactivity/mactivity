import Core
import Foundation
import Testing

@Suite("Runaway dev processes (D-156)")
struct RunawayWatchTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let cores = 10

    private struct Proc {
        let pid: Int32
        let name: String
        /// CPU as a share of one core.
        let core: Double
        let bytes: UInt64

        init(_ pid: Int32, _ name: String, _ core: Double, _ bytes: UInt64) {
            self.pid = pid
            self.name = name
            self.core = core
            self.bytes = bytes
        }
    }

    private func snapshot(at seconds: TimeInterval, _ processes: [Proc]) -> Snapshot {
        Snapshot(
            at: start.addingTimeInterval(seconds), interval: .seconds(10),
            system: SystemSample(
                cpu: CPUStats(
                    totalPercent: 0, userPercent: 0, systemPercent: 0, perCorePercent: Array(repeating: 0, count: cores),
                    clusters: [], loadAverage: .zero
                ),
                memory: MemoryStats(
                    totalBytes: 1, usedBytes: 0, appBytes: 0, wiredBytes: 0, compressedBytes: 0, cachedFilesBytes: 0,
                    swapUsedBytes: 0, pressure: .normal, availableLevel: 100
                ),
                disk: DiskStats(volumes: [], readBPS: 0, writeBPS: 0),
                network: NetworkStats(inBPS: 0, outBPS: 0, primaryInterface: "en0"),
                gpu: nil, battery: nil, sensors: nil, thermal: .nominal, uptime: .seconds(1)
            ),
            apps: [],
            processes: processes.map { proc in
                ProcessSample(
                    pid: proc.pid, app: "com.apple.Terminal", name: proc.name, cpuPercent: proc.core * 100 / Double(cores),
                    footprintBytes: proc.bytes,
                    diskReadBPS: 0, diskWriteBPS: 0, energyMW: nil, netInBPS: nil, netOutBPS: nil, gpuPercent: nil
                )
            }
        )
    }

    @Test("A node at a full core for 10 minutes is reported once; a busy compiler never")
    func stuck() {
        var watch = RunawayWatch()
        var found: [RunawayWatch.Finding] = []
        for step in 0 ... 70 {
            found += watch.observe(
                snapshot(at: Double(step * 10), [Proc(1, "node", 1.0, 1), Proc(2, "swift-frontend", 1.0, 1)]),
                stuckAfter: 600
            )
        }
        #expect(found.count == 1)
        #expect(found.first?.name == "node")
        if case let .stuck(seconds) = found.first?.kind {
            #expect(seconds >= 600)
        } else {
            Issue.record("Expected a stuck finding")
        }
    }

    @Test("A dip below a full core, or a sleep, starts the clock again")
    func resets() {
        var watch = RunawayWatch()
        var found: [RunawayWatch.Finding] = []
        for step in 0 ... 70 {
            let core = step == 40 ? 0.2 : 1.0
            found += watch.observe(snapshot(at: Double(step * 10), [Proc(1, "python3.13", core, 1)]), stuckAfter: 600)
        }
        #expect(found.isEmpty)
        var slept = RunawayWatch()
        _ = slept.observe(snapshot(at: 0, [Proc(1, "node", 1.0, 1)]), stuckAfter: 600)
        // Eight hours asleep between two busy readings isn't eight hours at full speed.
        #expect(slept.observe(snapshot(at: 8 * 3600, [Proc(1, "node", 1.0, 1)]), stuckAfter: 600).isEmpty)
    }

    @Test("Memory growing 1 GB over 30 minutes to over 2 GB is a leak; a spike that came back isn't")
    func leaks() {
        var watch = RunawayWatch()
        var found: [RunawayWatch.Finding] = []
        for minute in 0 ... 31 {
            let bytes = UInt64(1_500_000_000 + minute * 50_000_000)
            found += watch.observe(snapshot(at: Double(minute * 60), [Proc(7, "node", 0.1, bytes)]), stuckAfter: 600)
        }
        #expect(found.count == 1)
        if case let .leaking(bytes, grewBy) = found.first?.kind {
            #expect(bytes >= 2_000_000_000)
            #expect(grewBy >= 1_000_000_000)
        } else {
            Issue.record("Expected a leak finding")
        }
        var spiky = RunawayWatch()
        var spikes: [RunawayWatch.Finding] = []
        for minute in 0 ... 31 {
            let bytes: UInt64 = minute == 15 ? 4_000_000_000 : UInt64(1_000_000_000 + minute * 40_000_000)
            spikes += spiky.observe(snapshot(at: Double(minute * 60), [Proc(7, "node", 0.1, bytes)]), stuckAfter: 600)
        }
        #expect(spikes.isEmpty)
    }

    @Test("Dev runtimes are watched, other processes aren't")
    func names() {
        #expect(RunawayWatch.watches("node"))
        #expect(RunawayWatch.watches("python3.12"))
        #expect(RunawayWatch.watches("Python"))
        #expect(!RunawayWatch.watches("clang"))
        #expect(!RunawayWatch.watches("Xcode"))
    }
}
