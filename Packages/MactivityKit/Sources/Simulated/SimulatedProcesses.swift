import Core
import Foundation

/// Fake processes for the apps in `SimulatedCatalog`, with counters that grow each tick as if
/// one second had passed.
public actor SimulatedProcessSource: ProcessSource {
    private let loads: [Wander]
    private var tick = 0
    private var cpuTime: [Int32: Duration] = [:]
    private var written: [Int32: UInt64] = [:]
    private let bootedAt: Date

    public init(seed: UInt64 = 0x9A0C, bootedAt: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        loads = SimulatedCatalog.apps.indices.map { Wander(seed: seed &+ UInt64($0), base: 0.5, amplitude: 0.4) }
        self.bootedAt = bootedAt
    }

    public func sample() async throws -> [ProcessReading] {
        defer { tick += 1 }
        let cores = Double(SimulatedCatalog.topology.coreCount)
        var readings: [ProcessReading] = []
        for (appIndex, app) in SimulatedCatalog.apps.enumerated() {
            let load = loads[appIndex].value(at: tick)
            let share = 1 / Double(app.processNames.count)
            for (processIndex, name) in app.processNames.enumerated() {
                let pid = SimulatedCatalog.pid(app: appIndex, process: processIndex)
                let cpuSeconds = app.cpuWeight * load * share * cores
                cpuTime[pid, default: .zero] += .milliseconds(Int(cpuSeconds * 1000))
                written[pid, default: 0] += UInt64(app.diskWriteBPS * load * share)
                readings.append(ProcessReading(
                    pid: pid,
                    parentPID: processIndex == 0 ? 1 : SimulatedCatalog.pid(app: appIndex, process: 0),
                    uid: app.identity.kind == .system ? 0 : 501,
                    name: name,
                    executablePath: "\(app.identity.iconKey)/Contents/MacOS/\(name)",
                    startTime: bootedAt,
                    cpuTime: cpuTime[pid, default: .zero],
                    footprintBytes: UInt64(Double(app.memoryBytes) * share * (0.9 + load * 0.2)),
                    diskReadBytes: written[pid, default: 0] / 2,
                    diskWriteBytes: written[pid, default: 0],
                    energyNJ: UInt64(cpuSeconds * 2_000_000_000) * UInt64(tick + 1),
                    isComplete: app.identity.kind != .system
                ))
            }
        }
        return readings
    }
}

/// Resolves simulated PIDs back to the catalog app they came from.
public struct SimulatedAppResolver: AppResolver {
    public init() {}

    public func resolve(_ processes: [ProcessReading]) async -> [Int32: AppIdentity] {
        var result: [Int32: AppIdentity] = [:]
        for process in processes {
            let appIndex = (Int(process.pid) - 400) / 100
            result[process.pid] = SimulatedCatalog.apps.indices.contains(appIndex)
                ? SimulatedCatalog.apps[appIndex].identity
                : .other(executableName: process.name)
        }
        return result
    }
}
