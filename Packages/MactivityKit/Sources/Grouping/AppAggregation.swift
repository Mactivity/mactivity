import Core
import Foundation

/// Sums a tick's per-process samples into one aggregate per app (spec 5.1). Every process is
/// counted in exactly one app, so totals are never double counted. Pure.
public enum AppAggregation {
    /// One aggregate per app that has at least one process, sorted by `cpuPercent` descending,
    /// then by name (case-insensitive) for ties.
    /// - Parameters:
    ///   - omittedSystemProcesses: macOS processes left out of `processes` because they carry
    ///     nothing but their count (`ProcessPartition`, D-086). They're counted in the macOS row,
    ///     and add a 0 to its GPU when `gpuAvailable`, exactly as their zero samples would.
    public static func aggregate(
        processes: [ProcessSample],
        identities: [AppIdentity.ID: AppIdentity],
        omittedSystemProcesses: Int = 0,
        gpuAvailable: Bool = false
    ) -> [AppAggregate] {
        var sums: [AppIdentity.ID: Sum] = [:]
        sums.reserveCapacity(identities.count)
        for sample in processes {
            // One hashed, in-place update per process (no copy out and back of the Sum and its
            // identity's strings).
            if let identity = identities[sample.app] {
                sums[identity.id, default: Sum(identity: identity)].add(sample)
            } else {
                let identity = AppIdentity.other(executableName: sample.name)
                sums[identity.id, default: Sum(identity: identity)].add(sample)
            }
        }
        if omittedSystemProcesses > 0 {
            let system = identities[AppIdentity.system.id] ?? .system
            sums[system.id, default: Sum(identity: system)].addOmitted(omittedSystemProcesses, gpuAvailable: gpuAvailable)
        }
        // Ties (most apps sit at 0% while idle) sort by name without the localized collator,
        // which cost more than the rest of the aggregation; the lists re-sort for display anyway.
        let aggregates = sums.values.map { sum in
            AppAggregate(
                app: sum.identity, processCount: sum.count, cpuPercent: sum.cpu, memoryBytes: sum.memory,
                energyMW: sum.energy, diskReadBPS: sum.diskRead, diskWriteBPS: sum.diskWrite,
                netInBPS: sum.netIn, netOutBPS: sum.netOut, gpuPercent: sum.gpu, energyImpact: sum.impact
            )
        }
        return aggregates.sorted { lhs, rhs in
            if lhs.cpuPercent != rhs.cpuPercent {
                return lhs.cpuPercent > rhs.cpuPercent
            }
            return lhs.app.name.compare(rhs.app.name, options: .caseInsensitive) == .orderedAscending
        }
    }

    /// Adds what the system reports beyond what we could attribute (other users' and root
    /// processes without the helper) to the macOS row, so the rows add up to the system figures
    /// (spec 6.1). Creates the row if needed.
    public static func addingSystemRemainder(
        to apps: [AppAggregate],
        systemCPUPercent: Double,
        systemMemoryBytes: UInt64,
        unreadableProcessCount: Int
    ) -> [AppAggregate] {
        let attributedCPU = apps.reduce(0) { $0 + $1.cpuPercent }
        let attributedMemory = apps.reduce(UInt64(0)) { $0 &+ $1.memoryBytes }
        let cpuRemainder = max(0, systemCPUPercent - attributedCPU)
        let memoryRemainder = systemMemoryBytes > attributedMemory ? systemMemoryBytes - attributedMemory : 0
        var result = apps
        if let index = result.firstIndex(where: { $0.app.id == AppIdentity.system.id }) {
            let row = result[index]
            result[index] = AppAggregate(
                app: row.app, processCount: row.processCount, cpuPercent: row.cpuPercent + cpuRemainder,
                memoryBytes: row.memoryBytes &+ memoryRemainder, energyMW: row.energyMW, diskReadBPS: row.diskReadBPS,
                diskWriteBPS: row.diskWriteBPS, netInBPS: row.netInBPS, netOutBPS: row.netOutBPS, gpuPercent: row.gpuPercent,
                energyImpact: row.energyImpact
            )
        } else if cpuRemainder > 0 || memoryRemainder > 0 || unreadableProcessCount > 0 {
            result.append(AppAggregate(
                app: .system, processCount: unreadableProcessCount, cpuPercent: cpuRemainder, memoryBytes: memoryRemainder,
                energyMW: nil, diskReadBPS: 0, diskWriteBPS: 0, netInBPS: nil, netOutBPS: nil, gpuPercent: nil
            ))
        }
        return result.sorted { $0.cpuPercent > $1.cpuPercent }
    }
}

/// One app's running totals while aggregating.
private struct Sum {
    var identity: AppIdentity
    var count = 0
    var cpu = 0.0
    var memory: UInt64 = 0
    var diskRead = 0.0
    var diskWrite = 0.0
    var energy: Double?
    var netIn: Double?
    var netOut: Double?
    var gpu: Double?
    var impact: Double?

    mutating func add(_ sample: ProcessSample) {
        count += 1
        cpu += sample.cpuPercent
        memory &+= sample.footprintBytes
        diskRead += sample.diskReadBPS
        diskWrite += sample.diskWriteBPS
        energy = Self.add(sample.energyMW, to: energy)
        netIn = Self.add(sample.netInBPS, to: netIn)
        netOut = Self.add(sample.netOutBPS, to: netOut)
        gpu = Self.add(sample.gpuPercent, to: gpu)
        impact = Self.add(sample.energyImpact, to: impact)
    }

    /// Processes whose sample would be all zeros: CPU, memory and disk 0; energy, network
    /// and Energy Impact nil; GPU 0 while per-app GPU is read.
    mutating func addOmitted(_ processes: Int, gpuAvailable: Bool) {
        count += processes
        if gpuAvailable {
            gpu = gpu ?? 0
        }
    }

    static func add(_ value: Double?, to total: Double?) -> Double? {
        guard let value else {
            return total
        }
        return (total ?? 0) + value
    }
}
