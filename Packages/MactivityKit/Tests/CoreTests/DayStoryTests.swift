@testable import Core
import Foundation
import Testing

/// A day's story from made-up quarter-hours (D-191).
struct DayStoryTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    private var day: DateInterval {
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13)) ?? Date()
        return DateInterval(start: start, duration: 86400)
    }

    /// Quarter-hours over the day, the value from the minute of the day.
    private func series(_ value: (Int) -> Double) -> [SeriesPoint] {
        (0 ..< 96).map { index in
            let at = day.start.addingTimeInterval(Double(index) * 900)
            return SeriesPoint(at: at, average: value(index * 15), maximum: value(index * 15))
        }
    }

    private func at(_ hour: Double) -> Date {
        day.start.addingTimeInterval(hour * 3600)
    }

    @Test("Sleep and wake, with what woke it, in time order")
    func power() {
        var inputs = DayStoryInputs(day: day, bucket: 900)
        inputs.power = [
            PowerEvent(at: at(23.5), kind: .sleep),
            PowerEvent(at: at(7.25), kind: .wake, reason: "lid"),
            PowerEvent(at: at(-2), kind: .sleep),
        ]
        let events = DayStory.events(inputs)
        #expect(events.map(\.kind) == [.wake(.lid), .sleep])
    }

    @Test("A busy hour is one stretch; a lone busy quarter-hour isn't enough; a slowdown tells its own")
    func busy() {
        var inputs = DayStoryInputs(day: day, bucket: 900)
        // 9:00–10:00 at 65%, 13:00–13:15 at 70% (too short), 15:00–15:45 at 95% (a slowdown).
        inputs.cpu = series { minute in
            switch minute {
            case 540 ..< 600: 65
            case 780 ..< 795: 70
            case 900 ..< 945: 95
            default: 10
            }
        }
        let events = DayStory.events(inputs)
        let busy = events.filter {
            if case .busy = $0.kind {
                true
            } else {
                false
            }
        }
        #expect(busy.count == 1)
        #expect(busy.first?.start == at(9))
        #expect(busy.first?.end == at(10))
        #expect(events.contains {
            if case .slowdown = $0.kind {
                $0.start == at(15)
            } else {
                false
            }
        })
    }

    @Test("Off the charger and back on, with the charge each time")
    func charging() {
        var inputs = DayStoryInputs(day: day, bucket: 900)
        inputs.onBattery = series { minute in (480 ..< 720).contains(minute) ? 1 : 0 }
        inputs.batteryLevel = series { minute in minute < 480 ? 100 : max(40, 100 - Double(minute - 480) / 4) }
        let events = DayStory.events(inputs).map(\.kind)
        #expect(events == [.unplugged(level: 100), .pluggedIn(level: 40)])
    }

    @Test("Heavy download hours back to back are one stretch; quiet hours aren't listed")
    func downloads() {
        var inputs = DayStoryInputs(day: day, bucket: 900)
        // 2 MB/s from 20:00 to 22:00: 7.2 GB an hour, one stretch. 100 kB/s otherwise: 0.36 GB an hour.
        inputs.netIn = series { minute in (1200 ..< 1320).contains(minute) ? 2e6 : 1e5 }
        let events = DayStory.events(inputs)
        #expect(events.count == 1)
        #expect(events.first?.start == at(20))
        #expect(events.first?.end == at(22))
        if case let .download(bytes) = events.first?.kind {
            #expect(abs(bytes - 14.4e9) < 1e6)
        }
    }

    @Test("Alerts and crashes on the day, not the day before")
    func alertsAndCrashes() {
        var inputs = DayStoryInputs(day: day, bucket: 900)
        let app = AppIdentity(id: "safari", name: "Safari", bundleID: "com.apple.Safari", iconKey: "s", kind: .app)
        inputs.alerts = [
            Alert(rule: .highCPU, app: app, firedAt: at(11), title: "Safari is using a lot of CPU", body: ""),
            Alert(rule: .highCPU, app: app, firedAt: at(-1), title: "Yesterday", body: ""),
        ]
        inputs.crashes = [CrashReport(id: "1", at: at(16), appName: "Xcode", bundleID: nil, kind: .crash, path: "/dev/null")]
        let events = DayStory.events(inputs).map(\.kind)
        #expect(events == [.alert(title: "Safari is using a lot of CPU", app: app, count: 1), .crash(app: "Xcode", hang: false)])
    }

    @Test("The same alert all day is one line at its first time, with the count")
    func repeatedAlerts() {
        var inputs = DayStoryInputs(day: day, bucket: 900)
        let app = AppIdentity(id: "safari", name: "Safari", bundleID: "com.apple.Safari", iconKey: "s", kind: .app)
        inputs.alerts = [14, 10, 18, 12].map {
            Alert(rule: .growingMemory, app: app, firedAt: at($0), title: "Safari's memory keeps climbing", body: "")
        }
        let events = DayStory.events(inputs)
        #expect(events.count == 1)
        #expect(events.first?.start == at(10))
        #expect(events.first?.kind == .alert(title: "Safari's memory keeps climbing", app: app, count: 4))
    }

    @Test("An agent's quarter-hours back to back are one session on the day")
    func agents() {
        var inputs = DayStoryInputs(day: day, bucket: 900)
        inputs.agents = [9.0, 9.25, 9.5, 14].map {
            AgentUsage(start: at($0), agent: "Claude Code", project: "mactivity", minutes: 15, cpuTotal: 0, peakMemory: 0)
        }
        let events = DayStory.events(inputs)
        #expect(events.map(\.kind) == Array(repeating: .agent(name: "Claude Code", project: "mactivity"), count: 2))
        #expect(events.first?.start == at(9))
        #expect(events.first?.end == at(9.75))
    }

    @Test("Network drops and time on a hotspot or VPN are events; Wi-Fi isn't (D-233)")
    func network() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var inputs = DayStoryInputs(day: DateInterval(start: start, duration: 86400), bucket: 60)
        inputs.networkChanges = [
            NetworkChange(at: start - 3600, kind: .wifi, interface: "en0"),
            NetworkChange(at: start + 3600, kind: .offline, interface: nil),
            NetworkChange(at: start + 3600 + 30, kind: .wifi, interface: "en0"),
            NetworkChange(at: start + 7200, kind: .offline, interface: nil),
            NetworkChange(at: start + 7200 + 300, kind: .wifi, interface: "en0"),
            NetworkChange(at: start + 10800, kind: .vpn, interface: "utun4"),
            NetworkChange(at: start + 14400, kind: .wifi, interface: "en0"),
        ]
        let events = DayStory.events(inputs)
        // The 30-second blip isn't one; the 5-minute drop and the VPN hour are.
        #expect(events.map(\.kind) == [.network(.offline), .network(.vpn)])
        #expect(events.first?.end == start + 7200 + 300)
        #expect(events.last?.kind.englishText == "On a VPN")
    }

    @Test("The day's usual network isn't an event; a drop around sleep isn't either (D-236)")
    func usualNetwork() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var inputs = DayStoryInputs(day: DateInterval(start: start, duration: 86400), bucket: 60)
        // A desktop on Ethernet all day, a VPN for an hour, a drop just before sleep.
        inputs.networkChanges = [
            NetworkChange(at: start - 3600, kind: .ethernet, interface: "en7"),
            NetworkChange(at: start + 3600, kind: .vpn, interface: "utun4"),
            NetworkChange(at: start + 7200, kind: .ethernet, interface: "en7"),
            NetworkChange(at: start + 80000, kind: .offline, interface: nil),
            NetworkChange(at: start + 80300, kind: .asleep, interface: nil),
        ]
        #expect(DayStory.events(inputs).map(\.kind) == [.network(.vpn)])
    }

    @Test("The person's notes are part of the day, in time order; one line, cut to 280 (D-253)")
    func notes() {
        var inputs = DayStoryInputs(day: day, bucket: 900)
        let note = HistoryNote(at: at(10), text: "  Installed the\nnew driver ")
        inputs.notes = [note, HistoryNote(at: at(30), text: "Tomorrow")]
        inputs.power = [PowerEvent(at: at(7.25), kind: .wake, reason: "lid")]
        let events = DayStory.events(inputs)
        #expect(events.map(\.kind) == [.wake(.lid), .note(id: note.id, text: "Installed the new driver")])
        #expect(events.last?.kind.code == "note")
        #expect(HistoryNote(at: at(1), text: String(repeating: "a", count: 400)).text.count == HistoryNote.longest)
    }
}
