@testable import Core
import Foundation
import Testing

/// What's normal for each app, and what stands out today (D-198).
struct BaselinesTests {
    private func app(_ name: String, kind: AppIdentity.Kind = .app) -> AppIdentity {
        AppIdentity(id: name.lowercased(), name: name, bundleID: nil, iconKey: "x", kind: kind)
    }

    private func day(_ values: [String: Double]) -> [AppTotal] {
        values.map { AppTotal(app: app($0.key), value: $0.value) }.sorted { $0.value > $1.value }
    }

    @Test("Three times its usual memory stands out; a normal day doesn't")
    func memory() {
        let before = (0 ..< 10).map { _ in day(["Safari": 1.4e9, "Xcode": 3e9]) }
        let today = day(["Safari": 4.2e9, "Xcode": 3.1e9])
        let found = Baselines.unusual(metric: .memory, today: today, before: before)
        #expect(found.map(\.app.name) == ["Safari"])
        #expect(found.first.map { abs(($0.ratio ?? 0) - 3) < 0.01 } == true)
    }

    @Test("An app that's rarely there but busy today stands out, with no usual")
    func rarelyBusy() {
        var before = (0 ..< 8).map { _ in day(["Safari": 4]) }
        before[2] = day(["Safari": 4, "Docker": 2])
        let today = day(["Safari": 4, "Docker": 18])
        let found = Baselines.unusual(metric: .cpu, today: today, before: before)
        #expect(found.first?.app.name == "Docker")
        #expect(found.first?.usual == 0)
        #expect(found.first?.ratio == nil)
    }

    @Test("Below the floor nothing stands out, however many times its usual; macOS never does")
    func floors() {
        let before = (0 ..< 8).map { _ in day(["Notes": 0.2]) + [AppTotal(app: app("macOS", kind: .system), value: 2)] }
        let today = day(["Notes": 2]) + [AppTotal(app: app("macOS", kind: .system), value: 40)]
        #expect(Baselines.unusual(metric: .cpu, today: today, before: before).isEmpty)
    }

    @Test("A first few days are still learning")
    func learning() {
        let before = (0 ..< 4).map { _ in day(["Safari": 1e9]) }
        #expect(Baselines.unusual(metric: .memory, today: day(["Safari": 9e9]), before: before).isEmpty)
        // Days the Mac wasn't used don't count toward the five.
        let withGaps = before + [[], [], []]
        #expect(Baselines.unusual(metric: .memory, today: day(["Safari": 9e9]), before: withGaps).isEmpty)
    }

    @Test("The usual is the median day, so one heavy day doesn't move it")
    func median() {
        var before = (0 ..< 9).map { _ in day(["Xcode": 10]) }
        before.append(day(["Xcode": 90]))
        let found = Baselines.unusual(metric: .cpu, today: day(["Xcode": 30]), before: before)
        #expect(found.first?.usual == 10)
    }

    @Test("A change that's lasted a few days is the new normal, not news every morning")
    func newNormal() {
        var before = (0 ..< 10).map { _ in day(["Simulator": 0.02e9]) }
        let today = day(["Simulator": 5e9])
        #expect(!Baselines.unusual(metric: .memory, today: today, before: before).isEmpty, "the first heavy day")
        before += (0 ..< 3).map { _ in day(["Simulator": 5e9]) }
        #expect(Baselines.unusual(metric: .memory, today: today, before: before).isEmpty, "three heavy days on")
    }

    @Test("An app's usual daily peak is the median of its daily highs, once it has five days (D-218)")
    func usualPeak() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let highs = [6.0, 9.0, 7.0, 15.0, 6.5]
        var points: [SeriesPoint] = []
        for (day, high) in highs.enumerated() {
            let date = start + Double(day) * 86400
            points.append(SeriesPoint(at: date, average: 2e9, maximum: high * 1e9))
            points.append(SeriesPoint(at: date + 3600, average: 2e9, maximum: 3e9))
        }
        #expect(MemoryPeaks.usual(points, calendar: calendar) == 7e9)
        #expect(MemoryPeaks.usual(Array(points.prefix(8)), calendar: calendar) == nil, "four days: still learning")
    }
}
