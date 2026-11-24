import Core
import Foundation
import PrivateAPIs

/// Camera and microphone history's real source (1.8, D-259): what's running now from public API
/// (CoreMediaIO and Core Audio, as calls are detected for held alerts), and which app used what
/// from the privacy indicators' own record (`SensorIndicatorLog`).
public struct LiveSensorActivity: SensorActivitySource {
    public init() {}

    public func inUse() -> Set<PrivacySensor> {
        var sensors: Set<PrivacySensor> = []
        if LivePresenting.cameraInUse() {
            sensors.insert(.camera)
        }
        if LivePresenting.microphoneInUse() {
            sensors.insert(.microphone)
        }
        return sensors
    }

    public func changes(from: Date, to: Date) async -> [SensorChange]? {
        await Task.detached(priority: .utility) {
            SensorIndicatorLog.read(from: from, to: to)
        }.value
    }
}
