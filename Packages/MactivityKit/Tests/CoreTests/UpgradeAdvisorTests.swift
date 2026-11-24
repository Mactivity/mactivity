@testable import Core
import Foundation
import Testing

/// "Your next Mac" from a week of quarter-hours shaped like three kinds of use (D-181).
struct UpgradeAdvisorTests {
    private static let gib = 1_073_741_824.0
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    private var start: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 5)) ?? Date()
    }

    /// Quarter-hours over `days` days, the value from the hour of the day.
    private func series(days: Int = 7, _ value: (Int) -> Double) -> [SeriesPoint] {
        (0 ..< days * 96).map { index in
            let at = start.addingTimeInterval(Double(index) * 900)
            let hour = calendar.component(.hour, from: at)
            return SeriesPoint(at: at, average: value(hour), maximum: value(hour) * 1.1)
        }
    }

    private func diskFree(days: Int = 7, from free: Double, losingPerDay: Double) -> [DayValue] {
        (0 ..< days).map { day in
            DayValue(day: start.addingTimeInterval(Double(day) * 86400), average: free - Double(day) * losingPerDay, maximum: free)
        }
    }

    private func light() -> UpgradeInputs {
        var inputs = UpgradeInputs(
            days: 7, installedMemory: UInt64(16 * Self.gib), performanceCores: 4, diskCapacity: 512_000_000_000, hasBattery: true
        )
        inputs.cpu = series { (9 ..< 18).contains($0) ? 22 : 4 }
        inputs.memoryUsed = series { (9 ..< 18).contains($0) ? 8 * Self.gib : 5 * Self.gib }
        inputs.memoryPressure = series { _ in 20 }
        inputs.gpu = series { _ in 8 }
        inputs.onBattery = series { (9 ..< 17).contains($0) ? 1 : 0 }
        inputs.batteryLevel = series { 100 - Double($0) }
        inputs.diskFree = diskFree(from: 300_000_000_000, losingPerDay: 0)
        return inputs
    }

    @Test func aLightUserFitsAnAir() {
        let advice = UpgradeAdvisor.advise(light(), calendar: calendar)
        #expect(advice.chip == .base)
        #expect(advice.form == .air)
        #expect(advice.memoryVerdict == 16)
        #expect(advice.need(.processor)?.fit == .plenty)
        // 212 GB used, steady, plus a quarter free: 265 GB fits 512 GB, not 256.
        #expect(advice.need(.storage)?.verdict == "512 GB")
        #expect(advice.need(.battery)?.verdict == "All-day battery")
        #expect(!advice.isEarly)
        #expect(advice.busiestHours.map { (9 ... 17).contains($0.lowerBound) } == true)
    }

    @Test func aDeveloperUnderPressureGetsAProWithMoreMemory() {
        var inputs = UpgradeInputs(
            days: 7, installedMemory: UInt64(36 * Self.gib), performanceCores: 10, diskCapacity: 1_000_000_000_000, hasBattery: true
        )
        // Builds at 90% from 10 to 1 every day: 21 hours a week near full.
        inputs.cpu = series { (10 ..< 13).contains($0) ? 90 : 25 }
        inputs.memoryUsed = series { (10 ..< 13).contains($0) ? 33 * Self.gib : 24 * Self.gib }
        inputs.memoryPressure = series { (10 ..< 13).contains($0) ? 70 : 30 }
        inputs.swap = series { (10 ..< 13).contains($0) ? 6 * Self.gib : 1 * Self.gib }
        inputs.gpu = series { _ in 10 }
        inputs.diskFree = diskFree(days: 20, from: 300_000_000_000, losingPerDay: 1_000_000_000)
        inputs.cpuApps = ["Xcode"]
        let advice = UpgradeAdvisor.advise(inputs, calendar: calendar)
        #expect(advice.chip == .max)
        #expect(advice.form == .pro)
        #expect(advice.need(.processor)?.fit == .short)
        #expect(advice.need(.processor)?.topApp == "Xcode")
        #expect(advice.need(.memory)?.fit == .short)
        #expect(advice.memoryVerdict > 36)
        // 700 GB used, 30 GB a month for three years, plus a quarter free: 2.2 TB.
        #expect(advice.need(.storage)?.verdict == "4 TB")
    }

    @Test func heavyGraphicsAskForTheMostGPUCores() {
        var inputs = light()
        inputs.gpu = series { (19 ..< 22).contains($0) ? 95 : 10 }
        let advice = UpgradeAdvisor.advise(inputs, calendar: calendar)
        #expect(advice.need(.graphics)?.verdict == "Most GPU cores")
        #expect(advice.chip == .max)
        #expect(advice.form == .pro)
    }

    @Test func noHistoryNoAdvice() {
        let inputs = UpgradeInputs(days: 7, installedMemory: 0, performanceCores: 0, diskCapacity: 0, hasBattery: false)
        let advice = UpgradeAdvisor.advise(inputs, calendar: calendar)
        #expect(advice.needs.isEmpty)
        #expect(advice.isEarly)
    }

    @Test func aDesktopHasNoBatteryNeed() {
        var inputs = light()
        inputs.hasBattery = false
        #expect(UpgradeAdvisor.advise(inputs, calendar: calendar).need(.battery) == nil)
    }

    @Test("On a desktop, a desktop: a Mac mini for light use, a Mac Studio for a Max chip or over 64 GB (D-187)")
    func desktopsGetDesktops() {
        var light = light()
        light.hasBattery = false
        #expect(UpgradeAdvisor.advise(light, calendar: calendar).form == .mini)

        var graphics = light
        graphics.gpu = series { (19 ..< 22).contains($0) ? 95 : 10 }
        #expect(UpgradeAdvisor.advise(graphics, calendar: calendar).form == .studio)

        var memory = UpgradeAdvice()
        memory.memoryVerdict = 96
        #expect(UpgradeAdvisor.desktop(memory).0 == .studio)
        memory.memoryVerdict = 64
        #expect(UpgradeAdvisor.desktop(memory).0 == .mini)
    }

    @Test func storageGrowthIsAFittedLineNeverNegative() {
        let growing = diskFree(days: 20, from: 500e9, losingPerDay: 2e9)
        #expect(abs(UpgradeAdvisor.growthPerMonth(growing) - 60e9) < 1e6)
        #expect(UpgradeAdvisor.growthPerMonth(diskFree(days: 20, from: 500e9, losingPerDay: -3e9)) == 0)
        // Under two weeks isn't a trend: one week of builds would read as years of growth.
        #expect(UpgradeAdvisor.growthPerMonth(diskFree(days: 7, from: 500e9, losingPerDay: 5e9)) == 0)
    }

    @Test func sizesRoundUpToWhatAppleSells() {
        #expect(UpgradeAdvisor.size(UInt64(17), in: UpgradeAdvisor.memorySizes) == 24)
        #expect(UpgradeAdvisor.size(UInt64(200), in: UpgradeAdvisor.memorySizes) == 128)
        #expect(UpgradeAdvisor.size(0.6, in: UpgradeAdvisor.storageSizes) == 1)
    }

    // MARK: The desk (D-237)

    private func desk(displays: Int, closed: Double, docked: Double = 0.9) -> DeskUsage {
        DeskUsage(
            samples: 1000,
            dockedShare: docked,
            closedShare: closed,
            externalDisplays: displays,
            largestWidth: 3840,
            largestHeight: 2160
        )
    }

    @Test("Two displays on an Air: M4 or later, and both its ports")
    func airTwoDisplays() {
        var inputs = light()
        inputs.desk = desk(displays: 2, closed: 0.1)
        let advice = UpgradeAdvisor.advise(inputs, calendar: calendar)
        #expect(advice.form == .air)
        #expect(advice.deskNotes.first?.contains("M4") == true)
        #expect(advice.alternative == nil)
    }

    @Test("Closed on the desk and never on battery: a Mac mini, with the laptop beside it")
    func closedOnTheDesk() {
        var inputs = light()
        inputs.onBattery = series { _ in 0 }
        inputs.desk = desk(displays: 2, closed: 0.85)
        let advice = UpgradeAdvisor.advise(inputs, calendar: calendar)
        #expect(advice.form == .mini)
        #expect(advice.alternative?.form == .air)
        #expect(advice.formReason.contains("closed on the desk"))
    }

    @Test("Closed on the desk but it travels: the laptop, with a Mac mini to weigh")
    func closedButTravels() {
        var inputs = light()
        inputs.desk = desk(displays: 2, closed: 0.6)
        let advice = UpgradeAdvisor.advise(inputs, calendar: calendar)
        #expect(advice.form == .air)
        #expect(advice.alternative?.form == .mini)
    }

    @Test("Three displays rule out the Air: a MacBook Pro with a Max chip")
    func threeDisplays() {
        var inputs = light()
        inputs.desk = desk(displays: 3, closed: 0.1)
        let advice = UpgradeAdvisor.advise(inputs, calendar: calendar)
        #expect(advice.form == .pro)
        #expect(advice.chip == .max)
        // Closed on the desk: a Mac mini drives three, four take a Mac Studio.
        inputs.onBattery = series { _ in 0 }
        inputs.desk = desk(displays: 3, closed: 0.9)
        #expect(UpgradeAdvisor.advise(inputs, calendar: calendar).form == .mini)
        inputs.desk = desk(displays: 4, closed: 0.9)
        let four = UpgradeAdvisor.advise(inputs, calendar: calendar)
        #expect(four.form == .studio)
        #expect(four.chip == .max)
    }

    @Test("A day of samples before the desk counts")
    func deskUsage() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let samples = (0 ..< 200).map { index in
            DeskSample(
                at: t0 + Double(index) * 600, externalDisplays: index < 150 ? 2 : 0, largestWidth: 3840, largestHeight: 2160,
                lidClosed: index < 120
            )
        }
        let usage = DeskUsage.from(samples)
        #expect(usage?.externalDisplays == 2)
        #expect(usage?.dockedShare == 0.75)
        #expect(usage?.closedShare == 0.6)
        #expect(DeskUsage.from(Array(samples.prefix(100))) == nil)
        #expect(DeskUsage.name(width: 3840, height: 2160) == "4K")
    }
}
