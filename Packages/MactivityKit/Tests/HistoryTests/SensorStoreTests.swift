import Core
import Foundation
@testable import History
import Testing

/// Camera and microphone history (D-259).
struct SensorStoreTests {
    @Test("Changes saved, read by span with the one before, the newest found, and gone with Delete All History")
    func roundTrip() async throws {
        let store = try SQLiteHistoryStore(url: nil)
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let zoom: Set<SensorUse> = [SensorUse(sensor: .camera, app: "us.zoom.xos"), SensorUse(sensor: .microphone, app: "us.zoom.xos")]
        try await store.recordSensorChanges([
            SensorChange(at: at, active: zoom),
            SensorChange(at: at.addingTimeInterval(600), active: []),
            SensorChange(at: at.addingTimeInterval(7200), active: [SensorUse(sensor: .microphone, app: nil)]),
        ])
        let read = try await store.sensorChanges(from: at.addingTimeInterval(60), to: at.addingTimeInterval(3600))
        #expect(read.map(\.active) == [zoom, []])
        #expect(try await store.lastSensorChange()?.active == [SensorUse(sensor: .microphone, app: nil)])
        try await store.deleteAll()
        #expect(try await store.lastSensorChange() == nil)
    }
}
