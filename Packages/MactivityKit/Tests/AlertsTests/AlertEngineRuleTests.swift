@testable import Alerts
import Core
import Foundation
import Testing

private func evaluate(
    _ settings: AlertSettings,
    _ activity: [AppActivityHistory],
    state: AlertState = AlertState(),
    context: AlertContext = Fixture.context()
) -> AlertEvaluation {
    AlertEngine.evaluate(settings: settings, activity: activity, state: state, context: context)
}

private func steady(_ values: Fixture.Values, minutes: Double) -> [AppActivityHistory] {
    Fixture.history(Fixture.points(minutes: minutes) { _, _ in values })
}

@Suite("Alert engine: High CPU")
struct HighCPURuleTests {
    let settings = Fixture.only(.highCPU)

    @Test("Fires on an 84% average over 10 minutes, with the spec's text")
    func fires() throws {
        let result = evaluate(settings, steady(.init(cpu: 84), minutes: 10))
        let alert = try #require(result.alerts.first)
        #expect(result.alerts.count == 1)
        #expect(alert.rule == .highCPU)
        #expect(alert.app == Fixture.app)
        #expect(alert.firedAt == Fixture.now)
        #expect(alert.title == "Hog is using a lot of CPU")
        #expect(alert.body == "Averaged \(Formatters.percent(84)) for 10 minutes.")
    }

    @Test("Fires at exactly the threshold")
    func atThreshold() {
        #expect(evaluate(settings, steady(.init(cpu: 70), minutes: 10)).alerts.count == 1)
    }

    @Test("A busy minute, eight asleep, and a busy second isn't 10 busy minutes (D-139)")
    func sparse() {
        let all = Fixture.points(minutes: 10) { _, _ in .init(cpu: 100) }
        // The first minute and the last few seconds only.
        let points = all.filter { $0.at <= Fixture.now.addingTimeInterval(-540) || $0.at >= Fixture.now.addingTimeInterval(-5) }
        #expect(evaluate(settings, Fixture.history(points)).alerts.isEmpty)
        // Readings every 10 s (idle) or 20 s (Low Power Mode) still cover the window.
        let idle = Fixture.points(minutes: 10, step: 20) { _, _ in .init(cpu: 90) }
        #expect(evaluate(settings, Fixture.history(idle)).alerts.count == 1)
    }

    @Test("Doesn't fire just below the threshold")
    func belowThreshold() {
        #expect(evaluate(settings, steady(.init(cpu: 69.9), minutes: 10)).alerts.isEmpty)
    }

    @Test("Needs points back to 90% of the window")
    func coverage() {
        // 9 minutes is exactly 0.9 × 10; the oldest point sits on the line.
        #expect(evaluate(settings, steady(.init(cpu: 100), minutes: 9)).alerts.count == 1)
        // 8 m 55 s: the oldest point is 5 s short.
        #expect(evaluate(settings, steady(.init(cpu: 100), minutes: 8 + 55.0 / 60)).alerts.isEmpty)
    }

    @Test("Only points inside the window count")
    func window() {
        // 30 minutes idle, then 10 minutes at 90%: fires.
        let late = Fixture.points(minutes: 40) { _, ago in .init(cpu: ago <= 600 ? 90 : 0) }
        #expect(evaluate(settings, Fixture.history(late)).alerts.count == 1)
        // 30 minutes at 100%, then 10 minutes at 50%: the old load doesn't count.
        let early = Fixture.points(minutes: 40) { _, ago in .init(cpu: ago <= 600 ? 50 : 100) }
        #expect(evaluate(settings, Fixture.history(early)).alerts.isEmpty)
    }

    @Test("Points after now don't count")
    func future() {
        let later = Fixture.now.addingTimeInterval(600)
        let points = Fixture.points(minutes: 20, now: later) { _, ago in .init(cpu: ago < 600 ? 100 : 0) }
        #expect(evaluate(settings, Fixture.history(points)).alerts.isEmpty)
    }

    @Test("Threshold and window come from the settings")
    func customSettings() throws {
        let custom = Fixture.only(.highCPU, threshold: 30, window: .seconds(60))
        let alert = try #require(evaluate(custom, steady(.init(cpu: 40), minutes: 1)).alerts.first)
        #expect(alert.body == "Averaged \(Formatters.percent(40)) for 1 minute.")
    }
}

@Suite("Alert engine: Growing memory")
struct GrowingMemoryRuleTests {
    let settings = Fixture.only(.growingMemory)

    /// `start` for the first 6 minutes (the baseline the rule reads), then linear growth to
    /// `start + growth` at the end.
    func linear(start: UInt64, growth: UInt64, minutes: Double = 60) -> [AppActivityHistory] {
        let count = UInt64(minutes * 12)
        let flat: UInt64 = 72
        return Fixture.history(Fixture.points(minutes: minutes) { index, _ in
            let step = UInt64(index)
            return .init(memory: step <= flat ? start : start + growth * (step - flat) / (count - flat))
        })
    }

    @Test("One bad reading at the window's start doesn't make a steady app look like it grew (D-130)")
    func ignoresDipAtStart() {
        // Steady at 2.0 GB, creeping to 2.05 GB, with the first three readings near zero, as on
        // A Mac right after a wake: it fired "Up 2.0 GB in an hour, now 2.0 GB".
        let points = Fixture.points(minutes: 60) { index, _ in
            .init(memory: index < 3 ? 50_000_000 : 2_000_000_000 + UInt64(index) * 70000)
        }
        #expect(evaluate(settings, Fixture.history(points)).alerts.isEmpty)
    }

    @Test("Fires on +1.4 GB in an hour, with the spec's text")
    func fires() throws {
        let result = evaluate(settings, linear(start: 1_900_000_000, growth: 1_400_000_000))
        let alert = try #require(result.alerts.first)
        #expect(result.alerts.count == 1)
        #expect(alert.rule == .growingMemory)
        #expect(alert.title == "Hog's memory keeps climbing")
        let growth = Formatters.memory(UInt64(1_400_000_000))
        let current = Formatters.memory(UInt64(3_300_000_000))
        #expect(alert.body == "Up \(growth) in an hour, now \(current).")
    }

    @Test("Not while the app is still below its usual daily peak on this Mac; past it, it alerts (D-218)")
    func usualPeak() {
        let growing = linear(start: 1_900_000_000, growth: 1_400_000_000)
        let ordinary = Fixture.context(peaks: [Fixture.app.id: 6_900_000_000])
        #expect(evaluate(settings, growing, context: ordinary).alerts.isEmpty, "3.3 GB is an ordinary day for it")
        let past = Fixture.context(peaks: [Fixture.app.id: 3_000_000_000])
        #expect(evaluate(settings, growing, context: past).alerts.count == 1)
    }

    @Test("Fires at exactly the threshold")
    func atThreshold() {
        #expect(evaluate(settings, linear(start: 500_000_000, growth: 1_073_741_824)).alerts.count == 1)
    }

    @Test("After alerting, waits until the app has grown by the threshold again (D-111)")
    func waitsForNewGrowth() {
        let first = evaluate(settings, linear(start: 1_000_000_000, growth: 1_200_000_000))
        #expect(first.alerts.count == 1)
        #expect(first.state.levelAtLastAlert.values.first == 2_200_000_000)
        // Two hours on (past the cooldown), still growing, but only to 2.5 GB: no second alert.
        let later = Fixture.now.addingTimeInterval(2 * 3600)
        let small = Fixture.history(Fixture.points(minutes: 60, now: later) { index, _ in
            .init(memory: 1_300_000_000 + 1_200_000_000 * UInt64(index) / 720)
        })
        let quiet = AlertEngine.evaluate(settings: settings, activity: small, state: first.state, context: Fixture.context(now: later))
        #expect(quiet.alerts.isEmpty)
        // Grown past 3.2 GB (2.2 + the 1 GB threshold): it alerts again.
        let big = Fixture.history(Fixture.points(minutes: 60, now: later) { index, _ in
            .init(memory: 2_300_000_000 + 1_200_000_000 * UInt64(index) / 720)
        })
        #expect(AlertEngine.evaluate(settings: settings, activity: big, state: first.state, context: Fixture.context(now: later))
            .alerts.count == 1)
    }

    @Test("The level is forgotten once the app gives the memory back")
    func forgetsAfterRelease() {
        let key = AlertKey(appID: Fixture.app.id, rule: .growingMemory)
        var state = AlertState(lastFired: [key: Fixture.now], levelAtLastAlert: [key: 3e9])
        func point(_ bytes: UInt64) -> AppActivityPoint {
            AppActivityPoint(at: Fixture.now, cpuPercent: 0, memoryBytes: bytes, diskWriteBPS: 0, netInBPS: nil, netOutBPS: nil)
        }
        AlertEngine.forgetLevel(key, in: &state, latest: point(2_500_000_000), threshold: 1e9, now: Fixture.now)
        #expect(state.levelAtLastAlert[key] != nil)
        AlertEngine.forgetLevel(key, in: &state, latest: point(1_900_000_000), threshold: 1e9, now: Fixture.now)
        #expect(state.levelAtLastAlert[key] == nil)
    }

    @Test("Doesn't fire just below the threshold")
    func belowThreshold() {
        #expect(evaluate(settings, linear(start: 500_000_000, growth: 999_999_000)).alerts.isEmpty)
    }

    @Test("Doesn't fire when growth has stopped")
    func stoppedGrowing() {
        // +1.4 GB over the first 50 minutes, flat for the last 10.
        let points = Fixture.points(minutes: 60) { _, ago in
            let elapsed = min(3000, 3600 - ago)
            return .init(memory: 1_000_000_000 + UInt64(elapsed / 3000 * 1_400_000_000))
        }
        #expect(evaluate(settings, Fixture.history(points)).alerts.isEmpty)
    }

    @Test("Still growing compares with the point closest to 5 minutes ago")
    func stillGrowing() {
        // Flat until 5 minutes ago, then a jump in the last point only.
        let jump = Fixture.points(minutes: 60) { _, ago in
            .init(memory: ago == 0 ? 2_500_000_000 : 1_000_000_000)
        }
        #expect(evaluate(settings, Fixture.history(jump)).alerts.count == 1)
        // Grew to its peak 6 minutes ago and has been falling slightly since: not growing.
        let falling = Fixture.points(minutes: 60) { _, ago in
            ago >= 360
                ? .init(memory: 1_000_000_000 + UInt64((3600 - ago) / 3240 * 1_500_000_000))
                : .init(memory: 2_500_000_000 - UInt64((360 - ago) * 1000))
        }
        #expect(evaluate(settings, Fixture.history(falling)).alerts.isEmpty)
    }

    @Test("Shrinking memory never fires")
    func shrinking() {
        let points = Fixture.points(minutes: 60) { index, _ in .init(memory: 5_000_000_000 - UInt64(index) * 3_000_000) }
        #expect(evaluate(settings, Fixture.history(points)).alerts.isEmpty)
    }

    @Test("Needs 54 of the 60 minutes")
    func coverage() {
        #expect(evaluate(settings, linear(start: 0, growth: 2_000_000_000, minutes: 54)).alerts.count == 1)
        #expect(evaluate(settings, linear(start: 0, growth: 2_000_000_000, minutes: 50)).alerts.isEmpty)
    }

    @Test("A 30-minute window reads \"30 minutes\"")
    func shorterWindow() throws {
        let custom = Fixture.only(.growingMemory, window: .seconds(30 * 60))
        let result = evaluate(custom, linear(start: 1_000_000_000, growth: 2_000_000_000, minutes: 30))
        let alert = try #require(result.alerts.first)
        let growth = Formatters.memory(UInt64(2_000_000_000))
        let current = Formatters.memory(UInt64(3_000_000_000))
        #expect(alert.body == "Up \(growth) in 30 minutes, now \(current).")
    }
}

@Suite("Alert engine: Heavy disk")
struct HeavyDiskRuleTests {
    let settings = Fixture.only(.heavyDisk)

    @Test("Fires on 62 MB/s for 5 minutes, with the spec's text")
    func fires() throws {
        let result = evaluate(settings, steady(.init(disk: 62_000_000), minutes: 5))
        let alert = try #require(result.alerts.first)
        #expect(result.alerts.count == 1)
        #expect(alert.rule == .heavyDisk)
        #expect(alert.title == "Hog is writing a lot to disk")
        #expect(alert.body == "Averaged \(Formatters.rate(62_000_000)) for 5 minutes.")
    }

    @Test("Doesn't fire just below the threshold")
    func belowThreshold() {
        #expect(evaluate(settings, steady(.init(disk: 49_999_000), minutes: 5)).alerts.isEmpty)
    }

    @Test("A high average from a burst isn't sustained")
    func burst() {
        // 70% of points at 100 MB/s, 30% idle: averages 70 MB/s but isn't sustained.
        let points = Fixture.points(minutes: 5) { index, _ in .init(disk: index % 10 < 7 ? 100_000_000 : 0) }
        #expect(evaluate(settings, Fixture.history(points)).alerts.isEmpty)
    }

    @Test("Sustained means at least 80% of points at or above the threshold")
    func sustainedBoundary() {
        // 61 points; 80% is 48.8, so 49 must be at or above 50 MB/s. Both cases average above it.
        let fortyNine = Fixture.points(minutes: 5) { index, _ in .init(disk: index < 12 ? 20_000_000 : 60_000_000) }
        #expect(evaluate(settings, Fixture.history(fortyNine)).alerts.count == 1)
        let fortyEight = Fixture.points(minutes: 5) { index, _ in .init(disk: index < 13 ? 20_000_000 : 60_000_000) }
        #expect(evaluate(settings, Fixture.history(fortyEight)).alerts.isEmpty)
    }

    @Test("Needs 4.5 of the 5 minutes")
    func coverage() {
        #expect(evaluate(settings, steady(.init(disk: 80_000_000), minutes: 4.5)).alerts.count == 1)
        #expect(evaluate(settings, steady(.init(disk: 80_000_000), minutes: 4)).alerts.isEmpty)
    }
}

@Suite("Alert engine: Heavy network")
struct HeavyNetworkRuleTests {
    let settings = Fixture.only(.heavyNetwork)

    @Test("Downloading fires, with the spec's text")
    func download() throws {
        let alert = try #require(evaluate(settings, steady(.init(netIn: 12_000_000), minutes: 5)).alerts.first)
        #expect(alert.rule == .heavyNetwork)
        #expect(alert.title == "Hog is using a lot of network")
        #expect(alert.body == "Downloading \(Formatters.rate(12_000_000)) for 5 minutes.")
    }

    @Test("Uploading fires on its own")
    func upload() throws {
        let alert = try #require(evaluate(settings, steady(.init(netOut: 12_000_000), minutes: 5)).alerts.first)
        #expect(alert.body == "Uploading \(Formatters.rate(12_000_000)) for 5 minutes.")
    }

    @Test("Both directions heavy: one alert, naming the busier one")
    func both() throws {
        let result = evaluate(settings, steady(.init(netIn: 12_000_000, netOut: 20_000_000), minutes: 5))
        let alert = try #require(result.alerts.first)
        #expect(result.alerts.count == 1)
        #expect(alert.body == "Uploading \(Formatters.rate(20_000_000)) for 5 minutes.")
    }

    @Test("Missing figures count as zero")
    func nilIsZero() {
        // 11 MB/s in 85% of points, nil in the rest: 9.35 MB/s once nil counts as 0.
        let points = Fixture.points(minutes: 5) { index, _ in .init(netIn: index % 20 < 17 ? 11_000_000 : nil) }
        #expect(evaluate(settings, Fixture.history(points)).alerts.isEmpty)
    }

    @Test("Doesn't fire just below the threshold in either direction")
    func belowThreshold() {
        let values = Fixture.Values(netIn: 9_999_000, netOut: 9_999_000)
        #expect(evaluate(settings, steady(values, minutes: 5)).alerts.isEmpty)
    }

    @Test("Needs 4.5 of the 5 minutes")
    func coverage() {
        #expect(evaluate(settings, steady(.init(netIn: 50_000_000), minutes: 4)).alerts.isEmpty)
    }
}
