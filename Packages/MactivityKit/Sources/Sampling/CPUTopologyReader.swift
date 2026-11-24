import Core
import Foundation
import IOKit

/// Reads which logical CPU belongs to which performance level (D-005).
enum CPUTopologyReader {
    /// IORegistry `IODeviceTree:/cpus/*` → `cluster-type` per `logical-cpu-id`, matched against
    /// the `hw.perflevelN` counts. Falls back to the kernel-ordering assumption.
    static func current() -> CPUTopology {
        let levels = SystemInfo.perfLevels()
        if let types = clusterTypes(),
           let topology = CPUTopology.fromClusterTypes(perfLevels: levels, clusterTypeByCPU: types) {
            return topology
        }
        Log.sampling.notice("IORegistry cluster types unavailable; assuming kernel core order")
        return CPUTopology.fromPerfLevels(levels)
    }

    private static func clusterTypes() -> [Int: String]? {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != IO_OBJECT_NULL else {
            return nil
        }
        defer { IOObjectRelease(cpus) }
        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var result: [Int: String] = [:]
        var child = IOIteratorNext(iterator)
        while child != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(child)
                child = IOIteratorNext(iterator)
            }
            guard let id = property(child, "logical-cpu-id") as? NSNumber,
                  let type = property(child, "cluster-type") as? Data
            else {
                continue
            }
            result[id.intValue] = String(bytes: type.prefix { $0 != 0 }, encoding: .utf8) ?? ""
        }
        return result.isEmpty ? nil : result
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
