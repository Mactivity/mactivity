import Core
import Foundation
import Testing
@testable import UI

/// Compare two Macs (1.6): the rows side by side.
struct MacComparisonTests {
    func profile(cpu: Double, memory: Double) -> MacProfile {
        MacProfile(
            name: "Mac", model: "Mac mini", chip: "Apple M4", memory: 16_000_000_000, disk: 0, cores: 10, system: "macOS 26.1",
            hasBattery: false, days: 30, start: Date(), end: Date(),
            figures: MacProfile.Figures(
                cpuAverage: cpu, cpuBusy: cpu, memoryAverage: memory, memoryPeak: memory, pressureAverage: 20, swapAverage: 0,
                gpuAverage: 5, hotShare: 0, onBatteryShare: nil, writtenPerDay: 1e9, downloadedPerDay: 1e9, diskFree: nil,
                cpuApps: [], memoryApps: []
            )
        )
    }

    @Test("The higher figure is marked only when it's higher by more than a fifth; no battery row without batteries")
    func rows() {
        let rows = MacComparisonRow.rows(profile(cpu: 40, memory: 10e9), profile(cpu: 20, memory: 11e9))
        let processor = rows.first
        #expect(processor?.higher == .this)
        #expect(rows[2].higher == nil)
        #expect(!rows.contains { $0.title == "On battery" })
    }
}
