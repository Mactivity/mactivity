@testable import Core
import Foundation
import Testing

/// Compare two Macs (1.6): the report file.
struct MacProfileTests {
    static func profile(name: String, cpu: Double, memory: Double, days: Int = 30) -> MacProfile {
        MacProfile(
            name: name, model: "MacBook Pro", chip: "Apple M2 Pro", memory: 32_000_000_000, disk: 1_000_000_000_000, cores: 12,
            system: "macOS 26.1", hasBattery: true, days: days,
            start: Date(timeIntervalSince1970: 1_790_000_000), end: Date(timeIntervalSince1970: 1_792_592_000),
            figures: MacProfile.Figures(
                cpuAverage: cpu, cpuBusy: cpu * 2, memoryAverage: memory, memoryPeak: memory * 1.5, pressureAverage: 30,
                swapAverage: 1e9, gpuAverage: 10, hotShare: 0.01, onBatteryShare: 0.2, writtenPerDay: 20e9,
                downloadedPerDay: 3e9, diskFree: 300e9, cpuApps: ["Xcode"], memoryApps: ["Safari"]
            )
        )
    }

    @Test("Saved and read back exactly; a newer format or another file isn't read")
    func roundTrip() throws {
        let profile = Self.profile(name: "Kade's MacBook Pro", cpu: 22, memory: 18e9)
        let data = try profile.encoded()
        #expect(MacProfile.decode(data) == profile)
        var future = profile
        future.formatVersion = MacProfile.formatVersion + 1
        #expect(try MacProfile.decode(future.encoded()) == nil)
        #expect(MacProfile.decode(Data("{\"hello\": 1}".utf8)) == nil)
    }

    @Test("Figures from Your next Mac's inputs: averages, the busiest tenth, per-day totals")
    func figures() {
        var inputs = UpgradeInputs(days: 10, installedMemory: 16_000_000_000, performanceCores: 8, diskCapacity: 0, hasBattery: false)
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        inputs.cpu = (0 ..< 10).map { SeriesPoint(at: at.addingTimeInterval(Double($0) * 900), average: Double($0) * 10, maximum: 0) }
        inputs.thermal = [SeriesPoint(at: at, average: 0, maximum: 2), SeriesPoint(at: at, average: 0, maximum: 0)]
        let figures = MacProfile.Figures.from(inputs, written: 100e9, downloaded: 10e9)
        #expect(figures.cpuAverage == 45)
        #expect(figures.cpuBusy == 90)
        #expect(figures.hotShare == 0.5)
        #expect(figures.writtenPerDay == 10e9)
        #expect(figures.onBatteryShare == nil)
    }

    @Test("A report from anyone: an impossible span or figure isn't read, long names are cut (D-251)")
    func untrusted() throws {
        let good = Self.profile(name: "Mac", cpu: 22, memory: 18e9)
        var years = good
        years.days = 100_000
        var huge = good
        huge.figures.memoryAverage = 1e30
        var negative = good
        negative.days = -5
        var share = good
        share.figures.hotShare = 7
        for bad in [years, huge, negative, share] {
            #expect(try MacProfile.decode(bad.encoded()) == nil)
        }
        var long = good
        long.name = String(repeating: "M", count: 10000)
        long.figures.cpuApps = (0 ..< 50).map { "App \($0)" }
        let read = try #require(MacProfile.decode(long.encoded()))
        #expect(read.name.count == 80)
        #expect(read.figures.cpuApps.count == 3)
        #expect(MacProfile.decode(Data(count: MacProfile.largestFile + 1)) == nil)
    }
}
