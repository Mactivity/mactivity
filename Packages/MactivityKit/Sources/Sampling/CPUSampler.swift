import Core
import Darwin
import Foundation

/// System-wide CPU load from `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` (spec 6.3).
/// Public API only.
public actor CPUSampler: CPUSource {
    /// Runs on the shared sampling thread (D-022).
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        SamplingExecutor.shared.asUnownedSerialExecutor()
    }

    private let host: mach_port_t
    private let topology: CPUTopology
    private var previous: [CPUTicks]?

    public init() {
        // One send right for the sampler's lifetime; `mach_host_self()` adds a reference per call.
        host = mach_host_self()
        topology = CPUTopologyReader.current()
    }

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    public func sample() async throws -> CPUStats {
        let current = try readTicks()
        defer { previous = current }
        return CPULoadMath.stats(
            previous: previous,
            current: current,
            topology: topology,
            loadAverage: SystemInfo.loadAverage()
        )
    }

    private func readTicks() throws -> [CPUTicks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else {
            throw SamplingError.kernel(result)
        }
        defer {
            let size = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), size)
        }
        let stride = Int(CPU_STATE_MAX)
        return (0 ..< Int(cpuCount)).map { cpu in
            // Counters are 32-bit unsigned in the kernel, stored in signed `integer_t`.
            func ticks(_ state: Int32) -> UInt64 {
                UInt64(UInt32(bitPattern: info[cpu * stride + Int(state)]))
            }
            return CPUTicks(
                user: ticks(CPU_STATE_USER),
                system: ticks(CPU_STATE_SYSTEM),
                idle: ticks(CPU_STATE_IDLE),
                nice: ticks(CPU_STATE_NICE)
            )
        }
    }
}
