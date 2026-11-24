import Core
import Foundation
import Testing
@testable import UI

@Suite("Camera and microphone: moments (D-259)")
struct SensorMomentTests {
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func session(_ sensor: PrivacySensor, _ app: String?, _ start: Double, _ end: Double?) -> SensorSession {
        SensorSession(sensor: sensor, app: app, start: base + start * 60, end: end.map { base + $0 * 60 })
    }

    @Test("A call's camera and microphone are one moment; another app's, its own; location left out")
    func merge() {
        let moments = SensorMoment.moments([
            session(.camera, "us.zoom.xos", 0, 40),
            session(.microphone, "us.zoom.xos", 0, 45),
            session(.microphone, "com.apple.VoiceMemos", 60, 65),
            session(.location, "com.apple.Maps", 61, 62),
        ], now: base + 6000)
        #expect(moments.count == 2)
        #expect(moments[0].app == "com.apple.VoiceMemos")
        #expect(moments[1].sensors == [.camera, .microphone])
        #expect(moments[1].end == base + 45 * 60)
    }

    @Test("Still in use: the moment has no end")
    func ongoing() {
        let moments = SensorMoment.moments([
            session(.camera, "com.apple.FaceTime", 0, nil),
            session(.microphone, "com.apple.FaceTime", 1, 30),
        ], now: base + 3600)
        #expect(moments.count == 1)
        #expect(moments[0].end == nil)
    }
}
