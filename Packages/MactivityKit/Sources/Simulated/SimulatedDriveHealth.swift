import Core
import Foundation

/// A healthy internal SSD a year in (D-157), for previews, tests and simulated data.
public struct SimulatedDriveHealth: DriveHealthSource {
    public init() {}

    public func drives() async -> [DriveHealth] {
        [DriveHealth(
            index: 0, model: "APPLE SSD AP1024Z", isInternal: true, percentUsed: 2, availableSpare: 100, spareThreshold: 99,
            criticalWarning: 0, temperatureCelsius: 38, bytesRead: 31_000_000_000_000, bytesWritten: 18_400_000_000_000,
            powerOnHours: 2140, unsafeShutdowns: 3, mediaErrors: 0
        )]
    }
}
