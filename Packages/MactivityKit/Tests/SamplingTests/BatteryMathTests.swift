import Core
import Foundation
@testable import Sampling
import Testing

@Suite("Battery math")
struct BatteryMathTests {
    static let caseNames = [
        "acCharged", "batteryDischarging", "acCharging", "batteryEstimating", "designCapacityZero", "ups", "removed",
    ]

    let cases: [String: [String: Any]]

    init() throws {
        let fixture = try JSONFixture.object("battery-m5pro.json")
        cases = try #require(fixture["cases"] as? [String: [String: Any]])
    }

    @Test("Every fixture case converts to the expected BatteryStats", arguments: caseNames)
    func fixtureCase(name: String) throws {
        let testCase = try #require(cases[name], "missing case \(name)")
        let powerSource = try #require(testCase["powerSource"] as? [String: Any])
        let smartBattery = testCase["smartBattery"] as? [String: Any]
        let stats = BatteryMath.stats(powerSource: powerSource, smartBattery: smartBattery)

        guard let expected = testCase["expected"] as? [String: Any] else {
            #expect(stats == nil)
            return
        }
        let actual = try #require(stats)
        #expect(close(actual.percent, expected["percent"]))
        #expect(actual.isCharging == (expected["isCharging"] as? Bool))
        #expect(actual.source.rawValue == (expected["source"] as? String))
        #expect(actual.timeRemaining == (expected["timeRemainingMinutes"] as? Int).map { .seconds($0 * 60) })
        #expect(actual.cycleCount == (expected["cycleCount"] as? Int))
        #expect(optionalClose(actual.maxCapacityPercent, expected["maxCapacityPercent"]))
        #expect(optionalClose(actual.powerDrawWatts, expected["powerDrawWatts"]))
        // D-109: the whole Mac's load from either source, and the adapter only while on it.
        #expect(optionalClose(actual.systemLoadWatts, expected["systemLoadWatts"]))
        #expect(optionalClose(actual.adapterWatts, expected["adapterWatts"]))
    }

    /// Captured from `AppleSmartBatteryPack` on this Mac (M5 Pro, macOS 27), where the top-level
    /// entry has no `Temperature`: 25.79 °C (D-275).
    @Test("The battery's temperature, from the pack's key or a top-level one; nonsense is unknown")
    func temperature() throws {
        let fixture = try JSONFixture.object("battery-m5pro.json")
        let pack = try #require((fixture["packBatteryData"] as? [String: Any])?["Temperature"])
        let reading = try #require(BatteryMath.temperatureCelsius(["Temperature": pack]))
        #expect(abs(reading - 25.79) < 1e-9)
        #expect(BatteryMath.temperatureCelsius(["BatteryData": ["Temperature": 3050]]) == 30.5)
        #expect(BatteryMath.temperatureCelsius(["BatteryData": ["DesignCapacity": 6249]]) == nil)
        #expect(BatteryMath.temperatureCelsius([:]) == nil)
        #expect(BatteryMath.temperatureCelsius(["Temperature": 0]) == nil)
        #expect(BatteryMath.temperatureCelsius(["Temperature": 65535]) == nil)
        #expect(BatteryMath.temperatureCelsius(["Temperature": "warm"]) == nil)
    }

    @Test("What the adapter really delivers: 0 and missing are unknown, on battery it's not asked")
    func delivered() throws {
        // The real acCharged reading: 9.027 W in, all of it to the Mac.
        let fixture = try #require(cases["acCharged"])
        let smart = try #require(fixture["smartBattery"] as? [String: Any])
        let watts = try #require(BatteryMath.adapterInputWatts(smart))
        #expect(abs(watts - 9.027) < 1e-9)
        #expect(BatteryMath.adapterInputWatts(["PowerTelemetryData": ["SystemPowerIn": 0]]) == nil)
        #expect(BatteryMath.adapterInputWatts([:]) == nil)
        let source = try #require(fixture["powerSource"] as? [String: Any])
        #expect(BatteryMath.stats(powerSource: source, smartBattery: smart)?.adapterInputWatts == watts)
        let away = try #require(cases["batteryDischarging"])
        let stats = try BatteryMath.stats(
            powerSource: #require(away["powerSource"] as? [String: Any]),
            smartBattery: away["smartBattery"] as? [String: Any]
        )
        #expect(stats?.adapterInputWatts == nil)
        #expect(stats?.temperatureCelsius == nil)
    }

    @Test("A fixture covers every case the test lists")
    func allCasesListed() {
        #expect(Set(cases.keys) == Set(Self.caseNames))
    }

    @Test("A negative Amperage stored as an unsigned bit pattern still reads as discharging")
    func unsignedAmperage() throws {
        let amperage = NSNumber(value: UInt64(bitPattern: -1234))
        let smart: [String: Any] = ["Amperage": amperage, "Voltage": 12400]
        let watts = try #require(BatteryMath.powerDrawWatts(smart, source: .battery))
        #expect(abs(watts - 15.3016) < 1e-9)
        // On AC, a battery that's discharging (load above the adapter) still reports its draw.
        #expect(abs((BatteryMath.powerDrawWatts(smart, source: .ac) ?? 0) - 15.3016) < 1e-9)
    }

    @Test("Time remaining: -1 and 0 are unknown, minutes become a Duration")
    func timeRemaining() {
        #expect(BatteryMath.timeRemaining(minutes: -1) == nil)
        #expect(BatteryMath.timeRemaining(minutes: 0) == nil)
        #expect(BatteryMath.timeRemaining(minutes: nil) == nil)
        // IOPS stops at 20 h; the battery's own uncapped average wins when it has one (this Mac,
        // 2026-09-27: pmset said 20:00, AvgTimeToEmpty said 1,311 minutes).
        #expect(BatteryMath.timeRemaining(minutes: 1200, smartBatteryMinutes: 1311) == .seconds(1311 * 60))
        #expect(BatteryMath.timeRemaining(minutes: 90, smartBatteryMinutes: 65535) == .seconds(90 * 60))
        #expect(BatteryMath.timeRemaining(minutes: 90, smartBatteryMinutes: 0) == .seconds(90 * 60))
        #expect(BatteryMath.timeRemaining(minutes: 95) == .seconds(95 * 60))
    }

    private func close(_ value: Double, _ expected: Any?) -> Bool {
        guard let expected = PropertyValue.double(expected) else {
            return false
        }
        return abs(value - expected) < 1e-9
    }

    private func optionalClose(_ value: Double?, _ expected: Any?) -> Bool {
        guard let value else {
            return expected == nil || expected is NSNull
        }
        return close(value, expected)
    }
}

/// Smoke test of the IOPS and IORegistry wrappers on this laptop.
@Suite(
    "Battery sampler (live)",
    .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_LIVE_TESTS"] != nil, "needs real Mac hardware: make test-live")
)
struct BatterySamplerTests {
    @Test("This MacBook Pro has a battery with plausible figures")
    func plausible() async throws {
        let stats = try #require(try await BatterySampler().sample())
        #expect((0 ... 100).contains(stats.percent))
        let cycles = try #require(stats.cycleCount)
        #expect(cycles >= 0)
        let health = try #require(stats.maxCapacityPercent)
        #expect((1 ... 100).contains(health))
        let watts = try #require(stats.powerDrawWatts)
        #expect((0 ... 200).contains(watts))
        // From the battery pack's entry on this Mac (D-275), and the adapter's watts on power (D-274).
        let celsius = try #require(stats.temperatureCelsius)
        #expect((5 ... 60).contains(celsius))
        if stats.source == .battery {
            #expect(stats.adapterInputWatts == nil)
        }
        if let remaining = stats.timeRemaining {
            #expect(remaining > .zero)
        }
    }
}
