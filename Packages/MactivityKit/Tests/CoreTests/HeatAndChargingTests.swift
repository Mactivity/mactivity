@testable import Core
import Foundation
import Testing

/// Heat by app and charging habits (D-255), over four days of made-up quarter-hours.
struct HeatAndChargingTests {
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    let count = 384

    func at(_ index: Int) -> Date {
        start.addingTimeInterval(Double(index) * 900)
    }

    func series(_ value: (Int) -> Double) -> [SeriesPoint] {
        (0 ..< count).map { SeriesPoint(at: at($0), average: value($0), maximum: value($0)) }
    }

    func app(_ name: String) -> AppIdentity {
        AppIdentity(id: name, name: name, bundleID: nil, iconKey: "other", kind: .app)
    }

    @Test("The app busy in the warmest tenth comes first, beside its share the rest of the time")
    func heat() throws {
        // Every tenth quarter-hour is hot, and that's when the compiler runs.
        let temperature = series { $0 % 10 == 0 ? 90 : 50 }
        let compiler = app("Xcode")
        let browser = app("Safari")
        let result = try #require(HeatByApp.rank(temperature: temperature, apps: [
            compiler: series { $0 % 10 == 0 ? 300 : 5 },
            browser: series { _ in 20 },
        ]))
        #expect(result.warmFrom == 90)
        #expect(result.apps.first?.app == compiler)
        #expect((result.apps.first?.warmShare ?? 0) > 0.9)
        #expect((result.apps.first?.usualShare ?? 1) < 0.25)
        #expect(HeatByApp.rank(temperature: Array(temperature.prefix(100)), apps: [:]) == nil)
    }

    @Test("Charging: hours at full, charging while warm, and runs under 10%")
    func charging() throws {
        // Each day: plugged in at 100% for 16 hours, then 8 hours on battery down to 5%.
        let level = series { index in
            let quarter = index % 96
            return quarter < 64 ? 100 : max(5, 100 - Double(quarter - 64) * 3.2)
        }
        let onBattery = series { $0 % 96 < 64 ? 0 : 1 }
        let habits = try #require(ChargingHabits.read(level: level, onBattery: onBattery, temperature: [], bucket: 900))
        #expect(abs(habits.fullHoursPerDay - 16) < 0.5)
        #expect(habits.lowRuns == 4)
        #expect(habits.advice.first == .sitsAtFull(hours: habits.fullHoursPerDay))
        #expect(habits.advice.contains(.runsLow(times: 4)))
        let gentle = ChargingHabits(fullHoursPerDay: 2, warmChargingShare: 0.1, lowRuns: 0, days: 28)
        #expect(gentle.advice == [.fine])
        #expect(ChargingHabits.read(level: Array(level.prefix(10)), onBattery: [], temperature: [], bucket: 900) == nil)
    }

    @Test("A Mac that stays cool isn't warm in its warmest tenth; an app busy all the time isn't named")
    func cool() throws {
        let cool = try #require(HeatByApp.rank(temperature: series { $0 % 10 == 0 ? 39 : 35 }, apps: [app("Xcode"): series { _ in 50 }]))
        #expect(cool.staysCool)
        #expect(cool.apps.isEmpty)
        let warm = try #require(HeatByApp.rank(temperature: series { $0 % 10 == 0 ? 80 : 45 }, apps: [
            app("macOS"): series { _ in 100 },
            app("Claude Code"): series { $0 % 10 == 0 ? 120 : 1 },
        ]))
        #expect(warm.apps.map(\.app.name) == ["Claude Code"])
        // Charging at 39 °C isn't charging warm.
        let level = series { Double($0 % 96) }
        let habits = try #require(ChargingHabits.read(
            level: level, onBattery: series { _ in 0 }, temperature: series { $0 % 10 == 0 ? 39 : 35 }, bucket: 900
        ))
        #expect(habits.warmChargingShare == 0)
    }
}
