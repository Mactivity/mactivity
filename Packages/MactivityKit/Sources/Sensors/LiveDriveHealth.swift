import CDriveHealth
import Core
import Foundation

/// NVMe SMART for each drive that answers it (D-157), through the C shim over IOKit's public
/// NVMeSMARTLibExternal.h. External drives in USB enclosures usually don't pass SMART through,
/// so they're simply not listed. A read takes about a millisecond; done when the Disk tab shows.
public struct LiveDriveHealth: DriveHealthSource {
    public init() {}

    public func drives() async -> [DriveHealth] {
        var raw = [MactivityDriveHealth](repeating: MactivityDriveHealth(), count: 8)
        let count = Int(raw.withUnsafeMutableBufferPointer { mactivity_drive_health($0.baseAddress, Int32($0.count)) })
        return raw.prefix(max(0, count)).enumerated().map { index, drive in
            let model = withUnsafeBytes(of: drive.model) { bytes in
                (String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespaces)
            }
            return DriveHealth(
                index: index, model: model.isEmpty ? "NVMe drive" : model, isInternal: drive.isInternal != 0,
                percentUsed: Int(drive.percentUsed), availableSpare: Int(drive.availableSpare), spareThreshold: Int(drive.spareThreshold),
                criticalWarning: Int(drive.criticalWarning),
                temperatureCelsius: drive.temperatureKelvin > 0 ? Double(drive.temperatureKelvin) - 273.15 : nil,
                bytesRead: drive.unitsRead.multipliedReportingOverflow(by: DriveHealth.dataUnitBytes).partialValue,
                bytesWritten: drive.unitsWritten.multipliedReportingOverflow(by: DriveHealth.dataUnitBytes).partialValue,
                powerOnHours: drive.powerOnHours, unsafeShutdowns: drive.unsafeShutdowns, mediaErrors: drive.mediaErrors
            )
        }
        .sorted { $0.isInternal && !$1.isInternal }
    }
}
