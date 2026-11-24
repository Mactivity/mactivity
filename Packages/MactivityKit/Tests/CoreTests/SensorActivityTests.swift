import Core
import Foundation
import Testing

@Suite("Camera and microphone history (D-259)")
struct SensorActivityTests {
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func at(_ minutes: Double) -> Date {
        base.addingTimeInterval(minutes * 60)
    }

    func change(_ minutes: Double, _ codes: String...) -> SensorChange {
        SensorChange(at: at(minutes), active: Set(codes.compactMap { SensorUse(code: $0) }))
    }

    @Test("Codes: known sensors with and without an app; unknown ones left out")
    func codes() {
        #expect(SensorUse(code: "cam:us.zoom.xos") == SensorUse(sensor: .camera, app: "us.zoom.xos"))
        #expect(SensorUse(code: "mic:") == SensorUse(sensor: .microphone, app: nil))
        #expect(SensorUse(code: "xyz:com.example") == nil)
        let stored = change(0, "mic:us.zoom.xos", "cam:us.zoom.xos")
        #expect(stored.encoded == "cam:us.zoom.xos,mic:us.zoom.xos")
        #expect(SensorChange(at: stored.at, encoded: stored.encoded + ",xyz:other") == stored)
    }

    @Test("A call: camera and microphone each one stretch, from the change that started them to the one that ended them")
    func call() {
        let sessions = SensorSessions.sessions(
            [change(0, "cam:us.zoom.xos", "mic:us.zoom.xos"), change(45, "mic:us.zoom.xos"), change(50)],
            from: at(-60), now: at(120)
        )
        #expect(sessions.count == 2)
        let camera = sessions.first { $0.sensor == .camera }
        let microphone = sessions.first { $0.sensor == .microphone }
        #expect(camera?.start == at(0) && camera?.end == at(45))
        #expect(microphone?.start == at(0) && microphone?.end == at(50))
    }

    @Test("A drop under 30 seconds joins; a longer one doesn't")
    func gaps() {
        let short = SensorSessions.sessions(
            [change(0, "mic:com.apple.FaceTime"), change(10), change(10.25, "mic:com.apple.FaceTime"), change(20)],
            from: at(-1), now: at(30)
        )
        #expect(short.count == 1)
        #expect(short.first?.end == at(20))
        let long = SensorSessions.sessions(
            [change(0, "mic:com.apple.FaceTime"), change(10), change(11, "mic:com.apple.FaceTime"), change(20)],
            from: at(-1), now: at(30)
        )
        #expect(long.count == 2)
    }

    @Test("Still in use: no end. Ended before the span: left out")
    func ongoingAndClipped() {
        let sessions = SensorSessions.sessions(
            [change(0, "scr:com.apple.QuickTimePlayerX"), change(5), change(60, "cam:com.apple.FaceTime")],
            from: at(30), now: at(90)
        )
        #expect(sessions.map(\.sensor) == [.camera])
        #expect(sessions.first?.end == nil)
        #expect(sessions.first?.length(now: at(90)) == TimeInterval(30 * 60))
    }

    @Test("Totals count only the span, per app and sensor, longest first")
    func totals() {
        let sessions = SensorSessions.sessions(
            [
                change(-30, "cam:us.zoom.xos"), change(30), change(40, "cam:com.apple.FaceTime"), change(50),
                change(60, "cam:us.zoom.xos"), change(70),
            ],
            from: at(0), now: at(100)
        )
        let totals = SensorSessions.totals(sessions, from: at(0), now: at(100))
        #expect(totals.map(\.app) == ["us.zoom.xos", "com.apple.FaceTime"])
        #expect(totals.first?.seconds == TimeInterval(40 * 60))
        #expect(totals.first?.times == 2)
        #expect(totals.first?.lastUsed == at(70))
    }
}

@Suite("Camera and microphone on Your day (D-259)")
struct SensorDayTests {
    let day = DateInterval(start: Date(timeIntervalSince1970: 1_800_000_000), duration: 86400)

    func change(_ minutes: Double, _ codes: String...) -> SensorChange {
        SensorChange(at: day.start.addingTimeInterval(minutes * 60), active: Set(codes.compactMap { SensorUse(code: $0) }))
    }

    @Test("A call is one event; a screenshot and the location aren't events; yesterday's call isn't today's")
    func events() {
        var inputs = DayStoryInputs(day: day, bucket: 60)
        inputs.sensorChanges = [
            change(-120, "cam:us.zoom.xos"), change(-60),
            change(600, "cam:com.apple.FaceTime", "mic:com.apple.FaceTime"), change(640),
            change(700, "scr:com.apple.screencaptureui"), change(700.1),
            change(800, "loc:com.apple.Maps"), change(801),
            change(900, "scr:com.apple.QuickTimePlayerX"), change(915),
        ]
        let events = DayStory.events(inputs)
        #expect(events.map(\.kind) == [
            .sensor(sensors: [.camera, .microphone], app: "com.apple.FaceTime"),
            .sensor(sensors: [.screen], app: "com.apple.QuickTimePlayerX"),
        ])
        #expect(events.first?.end == day.start.addingTimeInterval(640 * 60))
        #expect(events.first?.kind.englishText == "com.apple.FaceTime used the camera and microphone")
    }
}

@Suite("Time in calls (D-262)")
struct CallTimeTests {
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func session(_ sensor: PrivacySensor, _ app: String?, _ start: Double, _ end: Double?) -> SensorSession {
        SensorSession(sensor: sensor, app: app, start: base + start * 60, end: end.map { base + $0 * 60 })
    }

    @Test("A call needs the microphone for two minutes, from an app that isn't a recorder")
    func calls() {
        let found = CallTime.calls([
            session(.camera, "com.apple.FaceTime", 0, 30), session(.microphone, "com.apple.FaceTime", 0, 31),
            session(.microphone, "com.apple.VoiceMemos", 40, 60),
            session(.camera, "com.apple.PhotoBooth", 70, 90),
            session(.microphone, "us.zoom.xos", 100, 101),
            session(.microphone, nil, 110, 125),
        ], now: base + 200 * 60)
        #expect(found.map(\.app) == [nil, "com.apple.FaceTime"])
        let apps = CallTime.byApp(found, from: base, now: base + 200 * 60)
        #expect(apps.map(\.app) == ["com.apple.FaceTime", nil])
        #expect(apps.first?.seconds == TimeInterval(31 * 60))
    }

    @Test("By day, a call over midnight split between the two days")
    func perDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let midnight = calendar.startOfDay(for: base)
        let call = SensorMoment(app: "com.apple.FaceTime", sensors: [.microphone], start: midnight - 600, end: midnight + 1200)
        let days = CallTime.perDay([call], days: 2, now: midnight + 3600, calendar: calendar)
        #expect(days.map(\.seconds) == [600, 1200])
        #expect(days.last?.day == midnight)
    }
}
