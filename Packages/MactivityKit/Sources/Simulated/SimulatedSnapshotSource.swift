import Core
import Foundation

/// A complete simulated Mac, published as a snapshot stream at the requested cadence.
public actor SimulatedSnapshotSource: SnapshotSource {
    private let cpu = SimulatedCPUSource()
    private let memory = SimulatedMemorySource()
    private let disk = SimulatedDiskSource()
    private let network = SimulatedNetworkSource()
    private let gpu = SimulatedGPUSource()
    private let battery = SimulatedBatterySource()
    private let sensors = SimulatedSensorSource()
    private let appLoads: [Wander]
    /// False: a desktop Mac (Mac mini, Studio, Pro), with no battery.
    private let hasBattery: Bool

    private var tick = 0
    private var cadence: SamplingCadence = .idle
    private var latest: Snapshot?
    private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    private var loop: Task<Void, Never>?

    public init(seed: UInt64 = 0x5A9, hasBattery: Bool = true) {
        self.hasBattery = hasBattery
        appLoads = SimulatedCatalog.apps.indices.map { Wander(seed: seed &+ UInt64($0), base: 0.5, amplitude: 0.4) }
    }

    public func snapshots() async -> AsyncStream<Snapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        continuations[id] = continuation
        if let latest {
            continuation.yield(latest)
        }
        startIfNeeded()
        return stream
    }

    public func setCadence(_ cadence: SamplingCadence) async {
        self.cadence = cadence
    }

    /// Produces the next snapshot immediately. Tests call this instead of waiting on the loop.
    public func next() async -> Snapshot {
        defer { tick += 1 }
        let interval = cadence.interval
        let system = await SystemSample(
            cpu: (try? cpu.sample()) ?? .aggregate(perCore: [], topology: SimulatedCatalog.topology, loadAverage: .zero),
            memory: memoryOrEmpty(),
            disk: (try? disk.sample()) ?? DiskStats(volumes: [], readBPS: 0, writeBPS: 0),
            network: (try? network.sample()) ?? NetworkStats(inBPS: 0, outBPS: 0, primaryInterface: nil),
            gpu: try? gpu.sample(),
            battery: hasBattery ? (try? battery.sample()) : nil,
            sensors: try? sensors.sample(),
            thermal: .nominal,
            uptime: .seconds(9 * 86400 + 4 * 3600) + interval * tick
        )
        let (apps, processes) = makeApps(cpuTotal: system.cpu.totalPercent, gpuTotal: system.gpu?.utilizationPercent)
        let snapshot = Snapshot(
            at: Date(timeIntervalSince1970: 1_790_000_000) + Double(tick) * Double(interval.components.seconds),
            interval: interval,
            system: system,
            apps: apps,
            processes: processes
        )
        latest = snapshot
        return snapshot
    }

    private func memoryOrEmpty() async -> MemoryStats {
        if let stats = try? await memory.sample() {
            return stats
        }
        return MemoryStats(
            totalBytes: 0, usedBytes: 0, appBytes: 0, wiredBytes: 0, compressedBytes: 0,
            cachedFilesBytes: 0, swapUsedBytes: 0, pressure: .normal, availableLevel: 100
        )
    }

    /// Splits the system CPU total across the catalog by weight, so per-app figures add up. The
    /// GPU too, unevenly (every third app draws a lot, the rest little) and to 85% of the total,
    /// the rest being macOS's own drawing: without it every GPU list read "–".
    private func makeApps(cpuTotal: Double, gpuTotal: Double?) -> ([AppAggregate], [ProcessSample]) {
        let weights = SimulatedCatalog.apps.enumerated().map { $1.cpuWeight * appLoads[$0].value(at: tick) }
        let weightSum = max(0.0001, weights.reduce(0, +))
        let gpuWeights = weights.enumerated().map { $1 * [1.6, 0.6, 0.25][$0 % 3] }
        let gpuWeightSum = max(0.0001, gpuWeights.reduce(0, +))
        var apps: [AppAggregate] = []
        var processes: [ProcessSample] = []
        for (index, app) in SimulatedCatalog.apps.enumerated() {
            let cpu = cpuTotal * weights[index] / weightSum
            let load = appLoads[index].value(at: tick)
            let count = app.processNames.count
            let memory = UInt64(Double(app.memoryBytes) * (0.9 + load * 0.2))
            let gpu = gpuTotal.map { $0 * 0.85 * gpuWeights[index] / gpuWeightSum }
            apps.append(AppAggregate(
                app: app.identity, processCount: count, cpuPercent: cpu, memoryBytes: memory,
                energyMW: cpu * 45, diskReadBPS: app.diskWriteBPS * load * 0.5, diskWriteBPS: app.diskWriteBPS * load,
                netInBPS: app.netInBPS * load, netOutBPS: app.netInBPS * load * 0.2, gpuPercent: gpu,
                energyImpact: cpu * Double(SimulatedCatalog.topology.coreCount) * 1.1
            ))
            for (processIndex, name) in app.processNames.enumerated() {
                processes.append(ProcessSample(
                    pid: SimulatedCatalog.pid(app: index, process: processIndex), app: app.identity.id, name: name,
                    cpuPercent: cpu / Double(count), footprintBytes: memory / UInt64(count),
                    diskReadBPS: app.diskWriteBPS * load * 0.5 / Double(count),
                    diskWriteBPS: app.diskWriteBPS * load / Double(count),
                    energyMW: cpu * 45 / Double(count), netInBPS: app.netInBPS * load / Double(count),
                    netOutBPS: app.netInBPS * load * 0.2 / Double(count), gpuPercent: gpu.map { $0 / Double(count) },
                    energyImpact: cpu * Double(SimulatedCatalog.topology.coreCount) * 1.1 / Double(count)
                ))
            }
        }
        return (apps, processes)
    }

    private func startIfNeeded() {
        guard loop == nil else {
            return
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                let snapshot = await next()
                await broadcast(snapshot)
                try? await Task.sleep(for: cadence.interval)
            }
        }
    }

    private func broadcast(_ snapshot: Snapshot) {
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
        if continuations.isEmpty {
            loop?.cancel()
            loop = nil
        }
    }
}
