import Core
import Foundation

/// Camera and microphone history for previews and Simulated data (D-259): a video call this
/// morning, a voice memo, a screen recording yesterday, and Maps reading the location.
enum SimulatedSensors {
    static func changes(around now: Date) -> [SensorChange] {
        let day: TimeInterval = 86400
        let today = Calendar.current.startOfDay(for: now)
        func uses(_ codes: String...) -> Set<SensorUse> {
            Set(codes.compactMap { SensorUse(code: $0) })
        }
        let changes = [
            SensorChange(at: today - 2 * day + 15 * 3600, active: uses("scr:com.apple.QuickTimePlayerX")),
            SensorChange(at: today - 2 * day + 15 * 3600 + 840, active: []),
            SensorChange(at: today - day + 9 * 3600, active: uses("cam:com.apple.PhotoBooth")),
            SensorChange(at: today - day + 9 * 3600 + 600, active: []),
            SensorChange(at: today - day + 17 * 3600, active: uses("loc:com.apple.Maps")),
            SensorChange(at: today - day + 17 * 3600 + 120, active: []),
            SensorChange(at: today - day + 19 * 3600, active: uses("mic:com.apple.FaceTime")),
            SensorChange(at: today - day + 19 * 3600 + 1900, active: []),
            SensorChange(at: today + 10 * 3600, active: uses("cam:com.apple.FaceTime", "mic:com.apple.FaceTime")),
            SensorChange(at: today + 10 * 3600 + 1500, active: []),
            SensorChange(at: today + 11 * 3600, active: uses("mic:com.apple.VoiceMemos")),
            SensorChange(at: today + 11 * 3600 + 300, active: []),
        ]
        return changes.filter { $0.at <= now }
    }

    static func changes(from: Date, to: Date) -> [SensorChange] {
        let all = changes(around: to)
        let before = all.last { $0.at < from }
        return (before.map { [$0] } ?? []) + all.filter { $0.at >= from && $0.at < to }
    }
}

extension SimulatedHistoryStore: SensorHistoryStore {
    public func recordSensorChanges(_: [SensorChange]) async throws {}

    public func sensorChanges(from: Date, to: Date) async throws -> [SensorChange] {
        SimulatedSensors.changes(from: from, to: to)
    }

    public func lastSensorChange() async throws -> SensorChange? {
        SimulatedSensors.changes(around: Date()).last
    }
}

extension SimulatedThirtyDayHistory: SensorHistoryStore {
    public func recordSensorChanges(_: [SensorChange]) async throws {}

    public func sensorChanges(from: Date, to: Date) async throws -> [SensorChange] {
        SimulatedSensors.changes(from: from, to: to)
    }

    public func lastSensorChange() async throws -> SensorChange? {
        SimulatedSensors.changes(around: Date()).last
    }
}

/// Nothing in use and no record to read: the simulated Mac's camera stays off.
public struct SimulatedSensorActivity: SensorActivitySource {
    public init() {}

    public func inUse() -> Set<PrivacySensor> {
        []
    }

    public func changes(from _: Date, to _: Date) async -> [SensorChange]? {
        []
    }
}
