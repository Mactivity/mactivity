@testable import Core
import Foundation
import Testing

struct SlowSpellsTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func minutes(_ values: [Double]) -> [SeriesPoint] {
        values.enumerated().map { index, value in
            SeriesPoint(at: base.addingTimeInterval(Double(index) * 60), average: value, maximum: value)
        }
    }

    @Test func busyMinutesInARowMakeOneSpell() {
        let cpu = minutes([20, 85, 90, 95, 88, 30])
        let spells = SlowSpells.find(cpu: cpu, memoryPressure: [], thermal: [], bucket: 60)
        #expect(spells.count == 1)
        #expect(spells.first?.start == base.addingTimeInterval(60))
        #expect(spells.first?.end == base.addingTimeInterval(300))
        #expect(spells.first?.causes == [.cpu])
        #expect(spells.first?.peakCPU == 95)
    }

    @Test func aBlipIsNotASpell() {
        let cpu = minutes([20, 95, 96, 20, 20])
        #expect(SlowSpells.find(cpu: cpu, memoryPressure: [], thermal: [], bucket: 60).isEmpty)
    }

    @Test func aCalmMinuteSplitsSpells() {
        let cpu = minutes([90, 90, 90, 10, 90, 90, 90])
        let spells = SlowSpells.find(cpu: cpu, memoryPressure: [], thermal: [], bucket: 60)
        #expect(spells.count == 2)
    }

    @Test func causesJoinAcrossTheSpellMostTellingFirst() {
        let cpu = minutes([90, 90, 40, 40])
        let memory = minutes([50, 85, 90, 85])
        let thermal = minutes([0, 0, 2, 2])
        let spells = SlowSpells.find(cpu: cpu, memoryPressure: memory, thermal: thermal, bucket: 60)
        #expect(spells.count == 1)
        #expect(spells.first?.causes == [.cpu, .memory, .heat])
        #expect(spells.first?.duration == 240)
        #expect(spells.first?.peakMemoryPressure == 90)
    }

    @Test func oneQuarterHourIsLongEnough() {
        let quarter = [SeriesPoint(at: base, average: 82, maximum: 100)]
        let spells = SlowSpells.find(cpu: quarter, memoryPressure: [], thermal: [], bucket: 900)
        #expect(spells.first?.duration == 900)
    }

    @Test func aGapInHistoryEndsTheSpell() {
        // The Mac slept between 3 and 10 minutes in: two spells, not one spanning the sleep.
        let cpu = minutes([90, 90, 90]) + minutes([90, 90, 90]).map {
            SeriesPoint(at: $0.at.addingTimeInterval(600), average: $0.average, maximum: $0.maximum)
        }
        #expect(SlowSpells.find(cpu: cpu, memoryPressure: [], thermal: [], bucket: 60).count == 2)
    }

    @Test func recentPrefersMinutesOverTheSameQuarter() {
        let minute = SlowSpell(
            start: base.addingTimeInterval(120),
            end: base.addingTimeInterval(420),
            causes: [.cpu],
            peakCPU: 90,
            peakMemoryPressure: 0
        )
        let sameQuarter = SlowSpell(start: base, end: base.addingTimeInterval(900), causes: [.cpu], peakCPU: 81, peakMemoryPressure: 0)
        let earlier = SlowSpell(
            start: base.addingTimeInterval(-86400),
            end: base.addingTimeInterval(-85500),
            causes: [.memory],
            peakCPU: 0,
            peakMemoryPressure: 85
        )
        let spells = SlowSpells.recent(minutes: [minute], quarters: [earlier, sameQuarter], limit: 5)
        #expect(spells == [minute, earlier])
        #expect(SlowSpells.recent(minutes: [minute], quarters: [earlier], limit: 1) == [minute])
    }
}
