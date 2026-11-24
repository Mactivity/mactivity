import Core
import Foundation
@testable import Grouping
import Sampling
import Simulated
import Testing

@Suite("Process partition: macOS's unread processes are counted, not sampled (D-086)")
struct ProcessPartitionTests {
    static let start = Date(timeIntervalSince1970: 1_790_000_000)
    static let now = start.addingTimeInterval(3600)
    static let app = AppIdentity(id: "com.example.a", name: "A", bundleID: "com.example.a", iconKey: "/A.app", kind: .app)

    static func reading(
        _ pid: Int32, complete: Bool, cpu: Duration = .zero, memory: UInt64 = 0, disk: UInt64 = 0, energy: UInt64 = 0
    ) -> ProcessReading {
        ProcessReading(
            pid: pid, parentPID: 1, uid: complete ? 501 : 0, name: "p\(pid)", executablePath: nil, startTime: start,
            cpuTime: cpu, footprintBytes: memory, diskReadBytes: disk, diskWriteBytes: disk * 2,
            energyNJ: energy, isComplete: complete, wakeups: complete ? 10 : 0
        )
    }

    /// Two apps' processes, and macOS processes of every kind: unread (omitted), unread with GPU
    /// time, unread with a network rate, and read (a process seen for the first time).
    static func pass(later: Bool) -> [ProcessReading] {
        let step: Int64 = later ? 2 : 1
        return [
            reading(
                100, complete: true, cpu: .milliseconds(400 * step), memory: 50_000_000,
                disk: 1000 * UInt64(step), energy: 9_000_000 * UInt64(step)
            ),
            reading(101, complete: true, cpu: .milliseconds(100 * step), memory: 20_000_000),
            reading(10, complete: false),
            reading(11, complete: false),
            reading(12, complete: false),
            reading(13, complete: true, cpu: .milliseconds(300 * step), memory: 8_000_000, disk: 10, energy: 1_000_000 * UInt64(step)),
            reading(14, complete: false),
            reading(15, complete: false),
        ]
    }

    static let identities: [Int32: AppIdentity] = [
        100: app, 101: app, 10: .system, 11: .system, 12: .system, 13: .system, 14: .system, 15: .system,
    ]
    static let rates: [Int32: ProcessNetworkMath.Rate] = [
        100: .init(inBPS: 500, outBPS: 50), 12: .init(inBPS: 7000, outBPS: 300),
    ]

    /// What the sampler did before: every reading becomes a sample.
    static func everySample(gpu: (previous: [Int32: UInt64], current: [Int32: UInt64])) -> [AppAggregate] {
        let previous = Dictionary(uniqueKeysWithValues: pass(later: false).map { ($0.pid, $0) })
        var samples = ProcessMath.samples(
            previous: previous, current: pass(later: true), identities: identities,
            previousGPU: gpu.previous, currentGPU: gpu.current, elapsed: .seconds(1), now: now, coreCount: 10
        )
        samples = ProcessNetworkMath.applying(rates, to: samples)
        let byID = Dictionary(identities.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return AppAggregation.aggregate(processes: samples, identities: byID)
    }

    /// The partitioned path.
    static func partitioned(gpu: (previous: [Int32: UInt64], current: [Int32: UInt64])) -> (ProcessPartition, [AppAggregate]) {
        let current = pass(later: true)
        let partition = ProcessPartition(
            readings: current, identities: identities, detailed: false, gpuPIDs: gpu.current, networkPIDs: rates
        )
        // As the sampler keeps them: only last pass's kept readings.
        let earlier = ProcessPartition(
            readings: pass(later: false), identities: identities, detailed: false, gpuPIDs: gpu.previous, networkPIDs: rates
        )
        let previous = Dictionary(uniqueKeysWithValues: earlier.kept.map { ($0.pid, $0) })
        var samples = ProcessMath.samples(
            previous: previous, current: partition.kept, identities: identities,
            previousGPU: gpu.previous, currentGPU: gpu.current, elapsed: .seconds(1), now: now, coreCount: 10
        )
        samples = ProcessNetworkMath.applying(rates, to: samples)
        let aggregates = AppAggregation.aggregate(
            processes: samples, identities: partition.identitiesByID(identities),
            omittedSystemProcesses: partition.omittedSystemCount, gpuAvailable: !gpu.current.isEmpty
        )
        return (partition, aggregates)
    }

    @Test("Only macOS readings without counters, GPU time or a network rate are left out")
    func partition() {
        let (partition, _) = Self.partitioned(gpu: ([11: 1_000_000], [11: 300_000_000]))
        #expect(partition.kept.map(\.pid) == [100, 101, 11, 12, 13])
        #expect(partition.omittedSystemCount == 3)
        #expect(partition.systemPIDs == [10, 11, 12, 13, 14, 15])
        #expect(partition.unreadableCount == 5)
        #expect(Set(partition.identitiesByID(Self.identities).keys) == [Self.app.id, AppIdentity.system.id])
    }

    @Test("Every app's figures and counts are unchanged, with and without per-app GPU")
    func sameAggregates() {
        let gpuCases: [([Int32: UInt64], [Int32: UInt64])] = [
            ([:], [:]),
            ([11: 1_000_000, 100: 5_000_000], [11: 301_000_000, 100: 55_000_000]),
        ]
        for gpu in gpuCases {
            let before = Self.everySample(gpu: gpu)
            let after = Self.partitioned(gpu: gpu).1
            #expect(after == before)
            let system = after.first { $0.app.kind == .system }
            #expect(system?.processCount == 6)
            #expect(system?.netInBPS == 7000)
            #expect((system?.gpuPercent != nil) == !gpu.1.isEmpty)
            // And after the system remainder.
            func withRemainder(_ apps: [AppAggregate]) -> [AppAggregate] {
                AppAggregation.addingSystemRemainder(
                    to: apps, systemCPUPercent: 40, systemMemoryBytes: 900_000_000, unreadableProcessCount: 5
                )
            }
            #expect(withRemainder(after) == withRemainder(before))
        }
    }

    @Test("A macOS row made only of omitted processes still counts them")
    func onlyOmitted() {
        let aggregates = AppAggregation.aggregate(processes: [], identities: [:], omittedSystemProcesses: 4, gpuAvailable: true)
        #expect(aggregates.count == 1)
        #expect(aggregates.first?.app == .system)
        #expect(aggregates.first?.processCount == 4)
        #expect(aggregates.first?.gpuPercent == 0)
        #expect(aggregates.first?.energyMW == nil)
    }

    @Test("With the macOS row expanded, nothing is left out")
    func detailed() {
        let partition = ProcessPartition(
            readings: Self.pass(later: true), identities: Self.identities, detailed: true,
            gpuPIDs: [Int32: Double](), networkPIDs: [Int32: Double]()
        )
        #expect(partition.kept.count == 8)
        #expect(partition.omittedSystemCount == 0)
        #expect(partition.systemPIDs.count == 6)
    }

    @Test("Readings with any counter are kept, even unread ones (simulated data, the helper)")
    func carriesNothing() {
        #expect(ProcessPartition.carriesNothing(Self.reading(1, complete: false)))
        #expect(!ProcessPartition.carriesNothing(Self.reading(1, complete: true)))
        #expect(!ProcessPartition.carriesNothing(Self.reading(1, complete: false, memory: 1)))
        #expect(!ProcessPartition.carriesNothing(Self.reading(1, complete: false, cpu: .milliseconds(1))))
    }

    @Test("The sampler leaves unread macOS processes out of the snapshot but counts them, and reads them when expanded")
    func sampler() async throws {
        let sampler = SnapshotSampler(sources: .init(
            cpu: SimulatedCPUSource(), memory: SimulatedMemorySource(), disk: SimulatedDiskSource(),
            network: SimulatedNetworkSource(), gpu: SimulatedGPUSource(), battery: SimulatedBatterySource(),
            processes: SkippingProcessSource(), resolver: SimulatedAppResolver(), thermal: { .nominal }
        ))
        await sampler.setCadence(.visible)
        let total = try await SimulatedProcessSource().sample().count
        let first = await sampler.tick() // learns which pids are macOS's
        #expect(first.processes.count == total)
        let collapsed = await sampler.tick()
        let system = try #require(collapsed.apps.first { $0.app.kind == .system })
        #expect(collapsed.processCount == total)
        #expect(collapsed.processes.count == total - system.processCount)
        #expect(!collapsed.processes.contains { collapsed.systemPIDs.contains($0.pid) })
        #expect(collapsed.systemPIDs.count == system.processCount)

        await sampler.setSystemDetail(true)
        let expanded = await sampler.tick()
        #expect(expanded.processes.count == total)
        #expect(expanded.processCount == total)
    }
}

/// `SimulatedProcessSource`, but skipped processes come back as `ProcessSampler` returns them:
/// incomplete, every counter zero.
actor SkippingProcessSource: ProcessSource {
    private let inner = SimulatedProcessSource()

    func sample() async throws -> [ProcessReading] {
        try await sample(skippingUsageFor: [])
    }

    func sample(skippingUsageFor pids: Set<Int32>) async throws -> [ProcessReading] {
        try await inner.sample().map { reading in
            guard pids.contains(reading.pid) else {
                return reading
            }
            return ProcessReading(
                pid: reading.pid, parentPID: reading.parentPID, uid: reading.uid, name: reading.name,
                executablePath: reading.executablePath, startTime: reading.startTime, cpuTime: .zero,
                footprintBytes: 0, diskReadBytes: 0, diskWriteBytes: 0, energyNJ: 0, isComplete: false
            )
        }
    }
}
