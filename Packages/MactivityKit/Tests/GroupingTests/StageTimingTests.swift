import Core
import Foundation
@testable import Grouping
import Projects
import Sampling
import Testing

/// Times each stage of a real tick. Writes to `MACTIVITY_DUMP`; skipped unless it's set.
@Suite("Stage timing", .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_DUMP"] != nil))
struct StageTimingTests {
    @Test("Per-stage cost of a tick")
    func stages() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MACTIVITY_DUMP"])
        let clock = ContinuousClock()
        let processes = ProcessSampler()
        let resolver = LiveAppResolver()
        var lines: [String] = []
        func time(_ name: String, _ body: () async throws -> Void) async rethrows {
            try await body()
            let elapsed = try await clock.measure { for _ in 0 ..< 10 {
                try await body()
            } }
            lines.append("\(name): \((elapsed / 10).formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 2))))")
        }
        try await time("process sample") { _ = try await processes.sample() }
        let readings = try await processes.sample()
        await time("resolve (cached)") { _ = await resolver.resolve(readings) }
        let identities = await resolver.resolve(readings)
        let byPID = Dictionary(readings.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        await time("process math") {
            _ = ProcessMath.samples(
                previous: byPID,
                current: readings,
                identities: identities,
                previousGPU: [:],
                currentGPU: [:],
                elapsed: .seconds(5),
                now: Date(),
                coreCount: 15
            )
        }
        let samples = ProcessMath.samples(
            previous: byPID,
            current: readings,
            identities: identities,
            previousGPU: [:],
            currentGPU: [:],
            elapsed: .seconds(5),
            now: Date(),
            coreCount: 15
        )
        let byID = Dictionary(identities.values.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        await time("aggregate") { _ = AppAggregation.aggregate(processes: samples, identities: byID) }
        let cpu = CPUSampler(), memory = MemorySampler(), disk = DiskSampler(), network = NetworkSampler()
        let gpu = GPUSampler(), battery = BatterySampler()
        try await time("cpu") { _ = try await cpu.sample() }
        try await time("memory") { _ = try await memory.sample() }
        try await time("disk") { _ = try await disk.sample() }
        try await time("network") { _ = try await network.sample() }
        try await time("gpu") { _ = try await gpu.sample() }
        try await time("battery") { _ = try await battery.sample() }
        lines.append("processes: \(readings.count), incomplete: \(readings.count { !$0.isComplete })")
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test("Cost of a projects scan")
    func projectsScan() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MACTIVITY_DUMP"])
        let sampler = SnapshotSampler(sources: .init(
            cpu: CPUSampler(), memory: MemorySampler(), disk: DiskSampler(), network: NetworkSampler(), gpu: GPUSampler(),
            battery: BatterySampler(), processes: ProcessSampler(), resolver: LiveAppResolver(), thermal: { .nominal }
        ))
        let projects = ProjectMonitor()
        await projects.observe(sampler.tick())
        _ = try await projects.projects()
        var found: [Project] = []
        let elapsed = try await ContinuousClock().measure {
            for _ in 0 ..< 10 {
                found = try await projects.projects()
            }
        }
        let summary = found.map { "\($0.name) \($0.ports) \($0.runtime) \($0.activity.title)" }.joined(separator: "; ")
        let perScan = (elapsed / 10).formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 2)))
        let text = "projects scan: \(perScan)\n\(summary)"
        try text.write(toFile: path + ".projects", atomically: true, encoding: .utf8)
    }
}
