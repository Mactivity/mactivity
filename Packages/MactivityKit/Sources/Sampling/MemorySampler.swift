import Core
import Darwin
import Foundation

/// System-wide memory from `host_statistics64(HOST_VM_INFO64)` and the `vm.swapusage`,
/// `kern.memorystatus_level`, and `kern.memorystatus_vm_pressure_level` sysctls (spec 6.3).
/// Public API only.
public actor MemorySampler: MemorySource {
    /// Runs on the shared sampling thread (D-022).
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        SamplingExecutor.shared.asUnownedSerialExecutor()
    }

    private let host: mach_port_t
    private let pageSize: UInt64
    private let totalBytes: UInt64

    public init() {
        // One send right for the sampler's lifetime; `mach_host_self()` adds a reference per call.
        host = mach_host_self()
        pageSize = Self.kernelPageSize(host: host)
        do {
            totalBytes = try SystemInfo.value("hw.memsize", initial: UInt64(0))
        } catch {
            Log.sampling.error("hw.memsize unavailable, using ProcessInfo: \(String(describing: error))")
            totalBytes = ProcessInfo.processInfo.physicalMemory
        }
    }

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    /// The kernel's page size (16 KB on Apple silicon), which the VM counts are in. This is
    /// `vm_kernel_page_size`, read through `host_page_size` because the global is a mutable C var.
    private static func kernelPageSize(host: mach_port_t) -> UInt64 {
        var size: vm_size_t = 0
        if host_page_size(host, &size) == KERN_SUCCESS, size > 0 {
            return UInt64(size)
        }
        return UInt64((try? SystemInfo.int("hw.pagesize")) ?? Int(getpagesize()))
    }

    public func sample() async throws -> MemoryStats {
        let counts = try readPageCounts()
        return MemoryMath.stats(
            counts: counts,
            pageSize: pageSize,
            totalBytes: totalBytes,
            swapUsedBytes: swapUsed(),
            pressureLevel: (try? SystemInfo.int("kern.memorystatus_vm_pressure_level")) ?? 1,
            availableLevel: (try? SystemInfo.int("kern.memorystatus_level")) ?? 100
        )
    }

    private func readPageCounts() throws -> VMPageCounts {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw SamplingError.kernel(result)
        }
        return VMPageCounts(
            internalPages: UInt64(info.internal_page_count),
            wiredPages: UInt64(info.wire_count),
            compressorPages: UInt64(info.compressor_page_count),
            externalPages: UInt64(info.external_page_count),
            purgeablePages: UInt64(info.purgeable_count)
        )
    }

    /// Swap in use, or 0 if the sysctl fails (no swap file yet reads as zeros, not an error).
    private func swapUsed() -> UInt64 {
        do {
            return try SystemInfo.value("vm.swapusage", initial: xsw_usage()).xsu_used
        } catch {
            Log.sampling.error("vm.swapusage unavailable: \(String(describing: error))")
            return 0
        }
    }
}
