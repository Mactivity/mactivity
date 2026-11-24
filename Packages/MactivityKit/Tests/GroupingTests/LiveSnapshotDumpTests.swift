import Core
import Foundation
@testable import Grouping
import Sampling
import Testing

/// Writes a live snapshot summary to `MACTIVITY_DUMP` for comparing against Activity Monitor.
/// Skipped unless that variable is set.
@Suite("Live snapshot dump", .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_DUMP"] != nil))
struct LiveSnapshotDumpTests {
    @Test("Two real ticks, five seconds apart")
    func dump() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MACTIVITY_DUMP"])
        let sampler = SnapshotSampler(sources: .init(
            cpu: CPUSampler(), memory: MemorySampler(), disk: DiskSampler(), network: NetworkSampler(), gpu: GPUSampler(),
            battery: BatterySampler(), processes: ProcessSampler(), resolver: LiveAppResolver(), thermal: { ThermalReader.current() }
        ))
        await sampler.setCadence(.visible)
        _ = await sampler.tick()
        try await Task.sleep(for: .seconds(5))
        let snapshot = await sampler.tick()
        let duration = await sampler.lastTickDuration
        var lines = [
            "tick: \(duration)",
            "cpu total \(snapshot.system.cpu.totalPercent), apps sum \(snapshot.apps.reduce(0) { $0 + $1.cpuPercent })",
            "memory used \(Formatters.bytes(snapshot.system.memory.usedBytes)) of \(Formatters.bytes(snapshot.system.memory.totalBytes))",
            "apps \(snapshot.apps.count), processes \(snapshot.processes.count), incomplete-to-system",
            "disk r/w \(Formatters.rate(snapshot.system.disk.readBPS)) / \(Formatters.rate(snapshot.system.disk.writeBPS))",
            "net in/out \(Formatters.rate(snapshot.system.network.inBPS)) / \(Formatters.rate(snapshot.system.network.outBPS))",
            "interface \(snapshot.system.network.primaryInterface ?? "-")",
            "gpu \(snapshot.system.gpu.map { "\($0.name) \($0.utilizationPercent)%" } ?? "-")",
            "battery \(snapshot.system.battery.map { "\($0.percent)% \($0.source)" } ?? "-")",
            "",
        ]
        for app in snapshot.apps.prefix(40) {
            let figures = [
                Formatters.percent(app.cpuPercent), Formatters.bytes(app.memoryBytes),
                app.energyMW.map { Formatters.power(milliwatts: $0) } ?? "-", app.gpuPercent.map { Formatters.percent($0) } ?? "-",
            ]
            lines.append("\(app.app.name) [\(app.app.kind.rawValue)] ×\(app.processCount): " + figures.joined(separator: "  "))
        }
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
