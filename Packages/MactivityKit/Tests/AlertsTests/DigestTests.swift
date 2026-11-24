@testable import Alerts
import Core
import Foundation
import Testing

@Suite("Daily digest")
struct DigestTests {
    let locale = Locale(identifier: "en_US")

    func total(_ name: String, _ value: Double, kind: AppIdentity.Kind = .app) -> AppTotal {
        AppTotal(app: AppIdentity(id: name, name: name, bundleID: name, iconKey: "", kind: kind), value: value)
    }

    @Test("Names the busiest app, the biggest memory user, and the alerts")
    func full() throws {
        let alert = Alert(rule: .highCPU, app: total("Xcode", 0).app, firedAt: Date(), title: "t", body: "b")
        let content = try #require(Digest.content(
            topCPU: [total("macOS", 30, kind: .system), total("Xcode", 23)],
            topMemory: [total("Safari", 4_400_000_000)],
            topNetwork: [total("Music", 50000)],
            alerts: [alert],
            locale: locale
        ))
        #expect(content.body.contains("Busiest: Xcode, 23% CPU on average."))
        #expect(content.body.contains("Most memory: Safari, 4.1 GB."))
        #expect(!content.body.contains("Most network"))
        #expect(content.body.contains("1 alert: Xcode."))
    }

    @Test("A quiet day with no data sends nothing")
    func quiet() {
        #expect(Digest.content(topCPU: [], topMemory: [], topNetwork: [], alerts: []) == nil)
    }

    @Test("Due once a day, after 7 am")
    func due() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 8)))
        let early = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 6)))
        let yesterday = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 9)))
        #expect(Digest.isDue(now: morning, lastSent: nil, calendar: calendar))
        #expect(!Digest.isDue(now: early, lastSent: yesterday, calendar: calendar))
        #expect(Digest.isDue(now: morning, lastSent: yesterday, calendar: calendar))
        #expect(!Digest.isDue(now: morning, lastSent: morning.addingTimeInterval(-600), calendar: calendar))
    }
}
