import Core
import Foundation
import Testing
@testable import UI

/// What the camera and microphone recorder keeps (D-259).
@MainActor
@Suite("Camera and microphone recording")
struct SensorRecorderTests {
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    struct Source: SensorActivitySource {
        var log: [SensorChange]?
        var now: Set<PrivacySensor> = []

        func inUse() -> Set<PrivacySensor> {
            now
        }

        func changes(from: Date, to: Date) async -> [SensorChange]? {
            log?.filter { $0.at >= from && $0.at <= to }
        }
    }

    actor Store: SensorHistoryStore {
        var kept: [SensorChange] = []

        init(_ kept: [SensorChange] = []) {
            self.kept = kept
        }

        func recordSensorChanges(_ changes: [SensorChange]) {
            kept += changes
        }

        func sensorChanges(from _: Date, to _: Date) -> [SensorChange] {
            kept
        }

        func lastSensorChange() -> SensorChange? {
            kept.max { $0.at < $1.at }
        }
    }

    func use(_ code: String) -> SensorUse {
        let parts = code.split(separator: ":")
        return SensorUse(sensor: PrivacySensor(code: String(parts[0])) ?? .camera, app: String(parts[1]))
    }

    @Test("Only changes newer than the last kept one; nothing read twice")
    func onlyNew() async {
        let zoom = SensorChange(at: base, active: [use("cam:us.zoom.xos")])
        let off = SensorChange(at: base + 600, active: [])
        let store = Store([zoom])
        let recorder = SensorRecorder(source: Source(log: [zoom, off]))
        recorder.attach(store)
        await recorder.read(at: base + 900, inUse: [], changed: true)
        #expect(await store.kept == [zoom, off])
    }

    @Test("A restart ends what was in use: an empty change at the startup")
    func restart() {
        let zoom = SensorChange(at: base, active: [use("mic:us.zoom.xos")])
        let later = SensorChange(at: base + 7200, active: [use("cam:com.apple.FaceTime")])
        let fresh = SensorRecorder.fresh([zoom, later], after: zoom, bootedAt: base + 3600)
        #expect(fresh == [SensorChange(at: base + 3600, active: []), later])
        // Nothing was in use: nothing to end.
        #expect(SensorRecorder.fresh([later], after: SensorChange(at: base, active: []), bootedAt: base + 3600) == [later])
    }

    @Test("Fallback: no log, so a change in the public state is kept without the app")
    func fallback() async {
        let store = Store()
        let recorder = SensorRecorder(source: Source(log: nil))
        recorder.attach(store)
        await recorder.read(at: base, inUse: [.camera], changed: true)
        #expect(await store.kept == [SensorChange(at: base, active: [SensorUse(sensor: .camera, app: nil)])])
        // The safety read with nothing changed keeps nothing.
        await recorder.read(at: base + 60, inUse: [.camera], changed: false)
        #expect(await store.kept.count == 1)
    }
}
