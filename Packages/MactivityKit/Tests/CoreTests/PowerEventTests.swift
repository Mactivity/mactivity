@testable import Core
import Foundation
import Testing

@Suite("Sleep and wake (D-096)")
struct PowerEventTests {
    @Test("Wake reasons in plain words; the lid wins over the trackpad", arguments: [
        ("smc.sysState.Wake(0x70070000) lid SMC.OutboxNotEmpty RTP.multi-touch", WakeCause.lid),
        ("EC.PowerButton (User)", .powerButton),
        ("RTP.multi-touch", .keyboardOrTrackpad),
        ("EC.ACAttach", .powerAdapter),
        ("wifibt", .network),
        ("XHC1", .usb),
        ("rtc maintenance", .scheduled),
        ("", .other),
        ("NUB.SPMISw3IRQ nub-spmi0.0x02", .other),
    ])
    func causes(reason: String, cause: WakeCause) {
        #expect(WakeCause(reason: reason) == cause)
    }

    private let day = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("Asleep from each sleep to the next wake, clipped to the window")
    func timeline() {
        let events = [
            PowerEvent(at: day - 3600, kind: .sleep),
            PowerEvent(at: day + 7 * 3600, kind: .wake),
            PowerEvent(at: day + 12 * 3600, kind: .sleep),
            PowerEvent(at: day + 13 * 3600, kind: .wake),
            // Quit before the Mac woke: the other half wasn't seen.
            PowerEvent(at: day + 23 * 3600, kind: .sleep),
        ]
        let asleep = SleepTimeline.asleep(events, from: day, to: day + 86400)
        #expect(asleep == [
            DateInterval(start: day, end: day + 7 * 3600),
            DateInterval(start: day + 12 * 3600, end: day + 13 * 3600),
        ])
    }

    @Test("Still asleep: the latest sleep counts until now, when asked (D-131)")
    func ongoing() {
        // Three days on one Mac: asleep from the afternoon, Mactivity running in maintenance wakes at
        // 6 am. Without the ongoing sleep the night read as zero hours asleep, "stayed awake".
        let events = [PowerEvent(at: day - 14 * 3600, kind: .sleep)]
        #expect(SleepTimeline.asleep(events, from: day, to: day + 6 * 3600).isEmpty)
        let now = day + 6 * 3600 + 60
        #expect(SleepTimeline.asleep(events, from: day, to: day + 6 * 3600, ongoingUntil: now)
            == [DateInterval(start: day, end: day + 6 * 3600)])
        // A sleep followed by a wake isn't ongoing.
        let woke = events + [PowerEvent(at: day + 3600, kind: .wake)]
        #expect(SleepTimeline.asleep(woke, from: day, to: day + 6 * 3600, ongoingUntil: now)
            == [DateInterval(start: day, end: day + 3600)])
    }

    @Test("A wake without a sleep before it is left out")
    func unmatched() {
        let events = [PowerEvent(at: day + 3600, kind: .wake), PowerEvent(at: day + 7200, kind: .wake)]
        #expect(SleepTimeline.asleep(events, from: day, to: day + 86400).isEmpty)
    }
}
