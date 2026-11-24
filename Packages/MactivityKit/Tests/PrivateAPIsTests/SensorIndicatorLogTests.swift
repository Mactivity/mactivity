import Core
import Foundation
@testable import PrivateAPIs
import Testing

@Suite("Privacy indicators' log (D-259)")
struct SensorIndicatorLogTests {
    /// As `log show --style ndjson` prints them on macOS 27.2 (trimmed to the fields read), with
    /// the times changed; the last line adds an unknown code to the camera and microphone.
    static let output = """
    {"timestamp":"2026-10-29 14:22:17.299171-0700","eventMessage":"Active activity attributions changed to [\\"loc:com.apple.MobileSMS\\"]"}
    {"timestamp":"2026-10-29 14:22:28.497012-0700","eventMessage":"Active activity attributions changed to []"}
    {"timestamp":"2026-10-29 15:02:03.100000-0700","eventMessage":"Active activity attributions changed to [\\"scr:com.apple.Terminal\\"]"}
    {"timestamp":"2026-10-30 16:01:07.228000-0700","eventMessage":"Active activity attributions changed to \
    [\\"cam:com.apple.PhotoBooth\\"]"}
    {"timestamp":"2026-10-30 16:01:16.278000-0700","eventMessage":"Active activity attributions changed to []"}
    {"timestamp":"2026-10-30 16:01:18.693000-0700","eventMessage":"Active activity attributions changed to \
    [\\"mic:com.example.murmur\\", \\"zzz:com.example\\"]"}
    {"timestamp":"2026-10-29 16:00:01.000000-0700","eventMessage":"Recent activity attributions changed to [\\"loc:com.apple.MobileSMS\\"]"}
    {"count":5,"finished":1}
    """

    @Test("Changes from the log, oldest first; other messages and unknown codes left out")
    func parse() {
        let changes = SensorIndicatorLog.changes(ndjson: Data(Self.output.utf8))
        #expect(changes.count == 6)
        #expect(changes[0].active == [SensorUse(sensor: .location, app: "com.apple.MobileSMS")])
        #expect(changes[1].active.isEmpty)
        #expect(changes[2].active == [SensorUse(sensor: .screen, app: "com.apple.Terminal")])
        #expect(changes[3].active == [SensorUse(sensor: .camera, app: "com.apple.PhotoBooth")])
        #expect(changes[5].active == [SensorUse(sensor: .microphone, app: "com.example.murmur")])
        // 14:22:17 at UTC-7.
        #expect(changes[0].at.timeIntervalSince1970.rounded() == 1_793_308_937)
    }

    @Test("A message in another form isn't a change")
    func otherForms() {
        #expect(SensorIndicatorLog.uses(in: "Sorted active attributions from SystemStatus update: []") == nil)
        #expect(SensorIndicatorLog.uses(in: "Active activity attributions changed to not-json") == nil)
        #expect(SensorIndicatorLog.uses(in: "Active activity attributions changed to [\"cam:\"]") == [])
        #expect(SensorIndicatorLog.changes(ndjson: Data("garbage\n{}\n".utf8)).isEmpty)
    }

    @Test("Fallback: a command that can't run, or fails, reads as nil, so only the public state is recorded")
    func fallback() {
        #expect(SensorIndicatorLog.run("/nonexistent/log", [], timeout: 5) == nil)
        #expect(SensorIndicatorLog.run("/usr/bin/false", [], timeout: 5) == nil)
        #expect(SensorIndicatorLog.run("/bin/echo", ["hi"], timeout: 5) == Data("hi\n".utf8))
    }
}
