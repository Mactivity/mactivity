import Core
import Foundation
import Simulated
import Testing

@Suite("Chargers compared (D-274)")
struct ChargersTests {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)
    private let day = Date(timeIntervalSince1970: 1_790_000_000 - 3600)

    private func plugged(
        _ percent: Double, watts: Double? = 96, charging: Bool = true, delivered: Double? = 60, temperature: Double? = 30,
        load: Double? = 10
    ) -> BatteryStats {
        BatteryStats(
            percent: percent, isCharging: charging, source: .ac, timeRemaining: nil, cycleCount: nil, maxCapacityPercent: nil,
            powerDrawWatts: 0, systemLoadWatts: load, adapterWatts: watts, temperatureCelsius: temperature,
            adapterInputWatts: delivered
        )
    }

    private func onBattery(_ percent: Double) -> BatteryStats {
        BatteryStats(
            percent: percent, isCharging: false, source: .battery, timeRemaining: nil, cycleCount: nil, maxCapacityPercent: nil,
            powerDrawWatts: 9, systemLoadWatts: 9
        )
    }

    // MARK: The tally

    @Test("A charge's time, gain and watts are tallied by rating and charge level")
    func tally() throws {
        var tally = ChargerTally()
        for (index, percent) in [40.0, 41, 41, 42].enumerated() {
            tally.add(plugged(percent), at: base + Double(index) * 10)
        }
        let use = try #require(tally.drain().first)
        #expect(use.ratingWatts == 96)
        #expect(use.condition == ChargeCondition(band: .low, isWarm: false, isBusy: false))
        #expect(use.seconds == 30)
        #expect(use.percentGained == 2)
        #expect(use.deliveredWattSeconds == 60 * 30)
        #expect(use.peakWatts == 60)
        #expect(!tally.hasUnsaved)
    }

    @Test("Nothing is counted across sleep: neither the time nor the charge")
    func sleep() {
        var tally = ChargerTally()
        tally.add(plugged(40), at: base)
        tally.add(plugged(90), at: base + 3600)
        #expect(tally.drain().isEmpty)
    }

    @Test("Another charger starts its own count; unplugging ends the charger's")
    func switchingChargers() {
        var tally = ChargerTally()
        tally.add(plugged(40, watts: 96), at: base)
        tally.add(plugged(41, watts: 96), at: base + 10)
        tally.add(plugged(41, watts: 30), at: base + 20) // Not 10 s of the 30 W: it wasn't on it yet.
        tally.add(onBattery(41), at: base + 30)
        tally.add(plugged(41, watts: 30), at: base + 40) // Plugged in again: starts over.
        let uses = tally.drain()
        #expect(uses.map(\.ratingWatts) == [96])
        #expect(uses.first?.seconds == 10)
    }

    @Test("Plugged in and not charging is time on the charger, with no fill speed")
    func notCharging() throws {
        var tally = ChargerTally()
        tally.add(plugged(100, charging: false, delivered: 12), at: base)
        tally.add(plugged(100, charging: false, delivered: 12), at: base + 10)
        let use = try #require(tally.drain().first)
        #expect(use.condition.band == nil)
        #expect(use.percentGained == 0)
        #expect(use.seconds == 10)
    }

    @Test("Heat and load say which comparison a moment belongs to; an unknown heat stays unknown")
    func conditions() {
        var tally = ChargerTally()
        tally.add(plugged(85, temperature: 36, load: 30), at: base)
        tally.add(plugged(85, temperature: 36, load: 30), at: base + 10)
        #expect(tally.drain().first?.condition == ChargeCondition(band: .high, isWarm: true, isBusy: true))
        tally.add(plugged(85, temperature: nil), at: base + 20)
        #expect(tally.drain().first?.condition.isWarm == nil)
    }

    @Test("A failed write puts back what it took")
    func restore() {
        var tally = ChargerTally()
        tally.add(plugged(40), at: base)
        tally.add(plugged(41), at: base + 10)
        let uses = tally.drain()
        tally.restore(uses)
        tally.add(plugged(42), at: base + 20)
        let merged = tally.drain()
        #expect(merged.count == 1)
        #expect(merged.first?.seconds == 20)
        #expect(merged.first?.percentGained == 2)
    }

    // MARK: The comparison

    private func use(
        _ rating: Int, _ band: ChargeBand?, minutes: Double, gained: Double, warm: Bool = false, busy: Bool = false, watts: Double = 50
    ) -> ChargerUse {
        ChargerUse(
            day: day, ratingWatts: rating, condition: ChargeCondition(band: band, isWarm: warm, isBusy: busy), seconds: minutes * 60,
            percentGained: gained, deliveredWattSeconds: watts * minutes * 60, deliveredSeconds: minutes * 60, peakWatts: watts + 10
        )
    }

    @Test("Charge level by charge level, clearly faster like for like")
    func faster() throws {
        let comparison = ChargerComparison.read([
            use(96, .low, minutes: 40, gained: 40), use(96, .middle, minutes: 40, gained: 30),
            use(30, .low, minutes: 40, gained: 20), use(30, .middle, minutes: 40, gained: 15),
        ])
        guard case let .faster(fast, slow, ratio, matched) = try #require(comparison.verdicts.first) else {
            Issue.record("Expected a winner")
            return
        }
        #expect(fast == 96)
        #expect(slow == 30)
        #expect(abs(ratio - 2) < 1e-9)
        #expect(matched == 80 * 60)
    }

    @Test("A charger used only near full isn't slower than one used only when low")
    func unlikeIsNotCompared() throws {
        let comparison = ChargerComparison.read([
            use(96, .high, minutes: 300, gained: 20),
            use(30, .low, minutes: 300, gained: 200),
        ])
        guard case let .tooLittle(_, _, matched) = try #require(comparison.verdicts.first) else {
            Issue.record("Nothing matched, so nothing can be said")
            return
        }
        #expect(matched == 0)
    }

    @Test("Warm isn't compared with cool, or a busy Mac with a light one")
    func heatAndLoad() {
        let comparison = ChargerComparison.read([
            use(96, .low, minutes: 100, gained: 100, warm: true),
            use(30, .low, minutes: 100, gained: 100, warm: false),
            use(60, .low, minutes: 100, gained: 100, warm: false, busy: true),
        ])
        for verdict in comparison.verdicts {
            guard case .tooLittle = verdict else {
                Issue.record("\(verdict) compares unlike charging")
                continue
            }
        }
        #expect(comparison.verdicts.count == 3)
    }

    @Test("Too little charging declares no winner, however lopsided")
    func tooLittle() throws {
        let short = ChargerComparison.read([use(96, .low, minutes: 30, gained: 40), use(30, .low, minutes: 30, gained: 5)])
        guard case let .tooLittle(_, _, matched) = try #require(short.verdicts.first) else {
            Issue.record("Half an hour isn't enough")
            return
        }
        #expect(matched == 30 * 60)
        // An hour matched, but one percent gained in it is rounding, not a speed.
        let flat = ChargerComparison.read([use(96, .high, minutes: 90, gained: 30), use(30, .high, minutes: 90, gained: 1)])
        guard case .tooLittle = try #require(flat.verdicts.first) else {
            Issue.record("Too few points gained to judge")
            return
        }
    }

    @Test("A small difference says they're about the same")
    func aboutTheSame() throws {
        let comparison = ChargerComparison.read([use(96, .low, minutes: 90, gained: 90), use(67, .low, minutes: 90, gained: 84)])
        guard case .aboutTheSame = try #require(comparison.verdicts.first) else {
            Issue.record("7% isn't a clear difference")
            return
        }
    }

    @Test("Each charger's figures: watts while charging, and speed only with time behind it")
    func figures() throws {
        let comparison = ChargerComparison.read([
            use(96, .low, minutes: 60, gained: 80, watts: 80),
            use(96, .high, minutes: 5, gained: 1, watts: 20),
            use(96, nil, minutes: 600, gained: 0, watts: 10),
        ])
        let charger = try #require(comparison.chargers.first)
        #expect(comparison.chargers.count == 1)
        #expect(comparison.verdicts.isEmpty)
        #expect(comparison.since == day)
        #expect(charger.fillSpeed[.low] == 80)
        #expect(charger.fillSpeed[.high] == nil)
        #expect(charger.chargingSeconds == 65 * 60)
        // The ten hours at full, drawing 10 W, don't lower what it delivers while charging.
        #expect(abs((charger.averageDeliveredWatts ?? 0) - (80 * 60 + 20 * 5) / 65.0) < 1e-9)
        #expect(charger.peakDeliveredWatts == 90)
    }

    // MARK: Battery temperature

    @Test("Each side's average and peak, and when recording began inside the range")
    func temperature() throws {
        let start = base - 86400
        let summary = try #require(BatteryTemperatureSummary.read(
            charging: [SeriesPoint(at: base, average: 30, maximum: 34), SeriesPoint(at: base + 60, average: 32, maximum: 33)],
            inUse: [],
            rangeStart: start
        ))
        #expect(summary.charging?.average == 31)
        #expect(summary.charging?.peak == 34)
        #expect(summary.inUse == nil)
        #expect(summary.since == base)
        #expect(BatteryTemperatureSummary.read(charging: [], inUse: [], rangeStart: start) == nil)
        // A reading before the range doesn't count; one at its start isn't late.
        let covered = try #require(BatteryTemperatureSummary.read(
            charging: [], inUse: [SeriesPoint(at: start - 60, average: 90, maximum: 90), SeriesPoint(at: start, average: 28, maximum: 28)],
            rangeStart: start
        ))
        #expect(covered.inUse?.average == 28)
        #expect(covered.since == nil)
    }

    @Test("A snapshot's temperature goes to charging or in use, never both")
    func split() async {
        let base = await SimulatedSnapshotSource(hasBattery: true).next()
        func snapshot(_ battery: BatteryStats) -> Snapshot {
            let system = base.system
            return Snapshot(
                at: base.at, interval: base.interval,
                system: SystemSample(
                    cpu: system.cpu, memory: system.memory, disk: system.disk, network: system.network, gpu: system.gpu,
                    battery: battery, sensors: system.sensors, thermal: system.thermal, uptime: system.uptime
                ),
                apps: base.apps, processes: []
            )
        }
        let charging = snapshot(plugged(50, temperature: 33))
        #expect(charging.systemValue(for: .batteryTempCharging) == 33)
        #expect(charging.systemValue(for: .batteryTempInUse) == nil)
        let full = snapshot(plugged(100, charging: false, temperature: 28))
        #expect(full.systemValue(for: .batteryTempCharging) == nil)
        #expect(full.systemValue(for: .batteryTempInUse) == 28)
        let unknown = snapshot(onBattery(50))
        #expect(unknown.systemValue(for: .batteryTempCharging) == nil)
        #expect(unknown.systemValue(for: .batteryTempInUse) == nil)
    }
}
