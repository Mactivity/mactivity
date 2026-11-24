import Foundation

/// Activity Monitor's Energy Impact (expansion E13), computed with the coefficients macOS
/// itself ships in `/usr/share/pmenergy` (`default.plist` on Apple silicon): CPU time, wakeups,
/// disk I/O, and GPU time, each weighted, per second of wall time, × 100.
public struct EnergyCoefficients: Hashable, Sendable, Codable {
    public var cpuTime: Double
    public var cpuWakeups: Double
    public var diskBytesRead: Double
    public var diskBytesWritten: Double
    public var gpuTime: Double

    public init(cpuTime: Double, cpuWakeups: Double, diskBytesRead: Double, diskBytesWritten: Double, gpuTime: Double) {
        self.cpuTime = cpuTime
        self.cpuWakeups = cpuWakeups
        self.diskBytesRead = diskBytesRead
        self.diskBytesWritten = diskBytesWritten
        self.gpuTime = gpuTime
    }

    /// The values in macOS 27's `/usr/share/pmenergy/default.plist`, for when the file can't be read.
    public static let builtIn = EnergyCoefficients(
        cpuTime: 1, cpuWakeups: 0.0002, diskBytesRead: 4.5e-10, diskBytesWritten: 2.4e-10, gpuTime: 0
    )

    /// Parses a pmenergy plist's `energy_constants` dictionary.
    public init?(plist: [String: Any]) {
        guard let constants = plist["energy_constants"] as? [String: Any] else {
            return nil
        }
        func value(_ key: String) -> Double {
            (constants[key] as? NSNumber)?.doubleValue ?? 0
        }
        self.init(
            cpuTime: value("kcpu_time"), cpuWakeups: value("kcpu_wakeups"),
            diskBytesRead: value("kdiskio_bytesread"), diskBytesWritten: value("kdiskio_byteswritten"),
            gpuTime: value("kgpu_time")
        )
    }

    /// Energy Impact for one interval. Inputs are deltas over `seconds` of wall time.
    public func impact(
        cpuSeconds: Double,
        wakeups: Double,
        bytesRead: Double,
        bytesWritten: Double,
        gpuSeconds: Double,
        seconds: Double
    ) -> Double {
        guard seconds > 0 else {
            return 0
        }
        let weighted = cpuTime * cpuSeconds + cpuWakeups * wakeups + diskBytesRead * bytesRead
            + diskBytesWritten * bytesWritten + gpuTime * gpuSeconds
        return max(0, weighted / seconds * 100)
    }
}
