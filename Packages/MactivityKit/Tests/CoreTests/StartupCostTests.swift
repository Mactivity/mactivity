@testable import Core
import Foundation
import Testing

struct StartupCostTests {
    private let boot = Date(timeIntervalSince1970: 1_800_000_000)

    /// Minutes of whole-Mac CPU starting `delay` seconds after startup.
    private func minutes(_ values: [Double], delay: TimeInterval = 40) -> [SeriesPoint] {
        values.enumerated().map { index, value in
            SeriesPoint(at: boot.addingTimeInterval(delay + Double(index) * 60), average: value, maximum: value)
        }
    }

    @Test func settlesAtTheFirstCalmRun() throws {
        let cost = try #require(StartupCosts.measure(cpu: minutes([90, 70, 60, 20, 30, 15, 10, 10, 10, 10]), bootedAt: boot))
        // Minute 3 is calm but minute 4 isn't; minutes 5 and 6 are the first calm pair.
        #expect(cost.settledAfter == 300)
        #expect(cost.loginAt == boot.addingTimeInterval(40))
        #expect(cost.averageCPU == 32.5)
    }

    @Test func aCalmStartSettlesAtOnce() {
        #expect(StartupCosts.measure(cpu: minutes([5, 5, 5, 5]), bootedAt: boot)?.settledAfter == 0)
    }

    @Test func stillBusyAtTheEnd() throws {
        let cost = try #require(StartupCosts.measure(cpu: minutes(Array(repeating: 60, count: 12)), bootedAt: boot))
        #expect(cost.settledAfter == nil)
        #expect(cost.averageCPU == 60)
    }

    @Test func recordingThatStartedLateSaysNothing() {
        #expect(StartupCosts.measure(cpu: minutes([90, 10, 10, 10], delay: 45 * 60), bootedAt: boot) == nil)
    }

    @Test func tooFewMinutesSaysNothing() {
        #expect(StartupCosts.measure(cpu: minutes([90, 10, 10]), bootedAt: boot) == nil)
    }

    @Test func minutesBeforeTheStartupAreIgnored() {
        let before = SeriesPoint(at: boot.addingTimeInterval(-600), average: 99, maximum: 99)
        #expect(StartupCosts.measure(cpu: [before] + minutes([5, 5, 5, 5]), bootedAt: boot)?.averageCPU == 5)
    }

    @Test func aGapBreaksACalmRun() throws {
        // Calm at minute 1, the Mac sleeps, calm again 10 minutes later: not two in a row.
        var points = minutes([80, 10])
        points += minutes([10, 80, 80], delay: 40 + 6 * 60)
        let cost = try #require(StartupCosts.measure(cpu: points, bootedAt: boot))
        #expect(cost.settledAfter == nil)
    }

    @Test func checkupNamesASlowStartup() {
        var inputs = CheckupInputs()
        inputs.lastStartup = StartupCost(bootedAt: boot, loginAt: boot, settledAfter: 8 * 60, averageCPU: 50)
        inputs.lastStartupApps = ["Dropbox", "Creative Cloud"]
        let item = Checkup.items(inputs).first { $0.id == "slow-startup" }
        #expect(item?.area == .startup)
        #expect(item?.detail.contains("Dropbox") == true)

        inputs.lastStartup = StartupCost(bootedAt: boot, loginAt: boot, settledAfter: 2 * 60, averageCPU: 20)
        #expect(!Checkup.items(inputs).contains { $0.id == "slow-startup" })
        inputs.lastStartup = StartupCost(bootedAt: boot, loginAt: boot, settledAfter: nil, averageCPU: 70)
        #expect(Checkup.items(inputs).contains { $0.id == "slow-startup" })
    }
}
