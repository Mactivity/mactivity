import Core
import Darwin
import Foundation
import os

enum Log {
    static let sampling = Logger(subsystem: "app.mactivity.sampling", category: "sampling")
}

public enum SamplingError: Error, Equatable {
    /// A Mach call failed with this `kern_return_t`.
    case kernel(Int32)
    /// A sysctl failed with this `errno`.
    case sysctl(name: String, errno: Int32)
}

/// Thin wrappers over public sysctl and libc calls.
enum SystemInfo {
    static func int(_ name: String) throws -> Int {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            throw SamplingError.sysctl(name: name, errno: errno)
        }
        // Some keys are 32-bit; sysctl writes only `size` bytes into the low end.
        return size == MemoryLayout<Int32>.size ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
    }

    static func string(_ name: String) throws -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else {
            throw SamplingError.sysctl(name: name, errno: errno)
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            throw SamplingError.sysctl(name: name, errno: errno)
        }
        return String(bytes: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
    }

    /// `hw.nperflevels` / `hw.perflevelN.{name,logicalcpu}`, most performant first. Falls back
    /// to one level of `hw.logicalcpu` cores if the per-level keys are missing.
    static func perfLevels() -> [(name: String, count: Int)] {
        do {
            let count = try int("hw.nperflevels")
            return try (0 ..< count).map { index in
                try (name: string("hw.perflevel\(index).name"), count: int("hw.perflevel\(index).logicalcpu"))
            }
        } catch {
            Log.sampling.error("perflevel sysctls unavailable, using one level: \(String(describing: error))")
            let cores = (try? int("hw.logicalcpu")) ?? ProcessInfo.processInfo.activeProcessorCount
            return [(name: "CPU", count: cores)]
        }
    }

    static func loadAverage() -> LoadAverage {
        var values = [Double](repeating: 0, count: 3)
        guard getloadavg(&values, 3) == 3 else {
            return .zero
        }
        return LoadAverage(one: values[0], five: values[1], fifteen: values[2])
    }

    /// Reads a fixed-size value (an `Int32`, a `UInt64`, a C struct such as `xsw_usage`) by name.
    /// Fails if the kernel reports a size other than `T`'s, so a wrong type can't read garbage.
    static func value<T: BitwiseCopyable>(_ name: String, as _: T.Type = T.self, initial: T) throws -> T {
        var value = initial
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            throw SamplingError.sysctl(name: name, errno: errno)
        }
        guard size == MemoryLayout<T>.size else {
            throw SamplingError.sysctl(name: name, errno: EINVAL)
        }
        return value
    }
}
