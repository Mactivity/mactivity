import Core
import Foundation
import Storage
import Testing
@testable import UI

@Suite("Readable figures (D-112)")
struct ReadableFiguresTests {
    @Test("Energy Impact shows as each app's share; other metrics keep their units")
    func shares() {
        #expect(AppListView.valueText(96.8, metric: .energyImpact, total: 193.6) == Formatters.percent(50))
        #expect(AppListView.valueText(0.1, metric: .energyImpact, total: 193.6) == Formatters.percent(0.05))
        #expect(AppListView.valueText(nil, metric: .energyImpact, total: 10) == "–")
        #expect(AppListView.valueText(12, metric: .cpu, total: nil) == Formatters.metric(12, .cpu))
    }

    @Test("Large counts the short way")
    func counts() {
        #expect(DiskActivityCard.count(35_340_815) == "35.3M")
        #expect(DiskActivityCard.count(940) == "940")
    }

    @Test("Totals history can't fully cover read as at least")
    func lowerBound() {
        #expect(DiskActivityCard.text(SpanTotal(value: 1.2e12, isLowerBound: true)).hasPrefix("≥ "))
        #expect(!DiskActivityCard.text(SpanTotal(value: 1.2e12, isLowerBound: false)).hasPrefix("≥"))
    }
}

@Suite("History strips keep their data readable (D-113)")
struct ThresholdLineTests {
    @Test("The alert line shows only once the data comes within half of it")
    func threshold() {
        #expect(HistoryStrip.visibleThreshold(10e6, plottedPeak: 2e5) == nil)
        #expect(HistoryStrip.visibleThreshold(10e6, plottedPeak: 5e6) == 10e6)
        #expect(HistoryStrip.visibleThreshold(70, plottedPeak: 88) == 70)
        #expect(HistoryStrip.visibleThreshold(nil, plottedPeak: 88) == nil)
    }
}

@Suite("Energy use by app (D-114)")
struct EnergyUseListTests {
    private let app = AppIdentity(id: "x", name: "Xcode", bundleID: nil, iconKey: "other", kind: .app)

    @Test("Battery shares need half an hour on battery; otherwise the list shows energy shares")
    func mode() {
        let apps = [AppTotal(app: app, value: 1)]
        #expect(BatteryUseList.usesBattery(BatteryUse(apps: apps, onBatterySeconds: 3 * 3600, drainedPercent: 40), span: .range))
        #expect(!BatteryUseList.usesBattery(BatteryUse(apps: apps, onBatterySeconds: 600, drainedPercent: 2), span: .range))
        #expect(!BatteryUseList.usesBattery(BatteryUse(apps: [], onBatterySeconds: 3 * 3600, drainedPercent: 0), span: .range))
        #expect(!BatteryUseList.usesBattery(nil, span: .range))
        // Since unplugged, ten minutes on battery is the answer, not too little to say (D-150).
        #expect(BatteryUseList.usesBattery(BatteryUse(apps: apps, onBatterySeconds: 600, drainedPercent: 2), span: .sinceUnplugged))
    }

    @Test("The list follows the page's range; Since unplugged only on battery (D-258)")
    func spans() {
        #expect(BatteryUseList.Span.range.title(range: .d30) == HistoryRange.d30.label)
        #expect(BatteryUseList.Span.offered(onBattery: false) == [.range])
        #expect(BatteryUseList.Span.offered(onBattery: true) == [.range, .sinceUnplugged])
    }
}

@Suite("Cleanup summary (D-117)")
@MainActor
struct CleanupSummaryTests {
    @Test("Backups over six months old; one without a date isn't called old")
    func oldBackups() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func backup(_ days: Double?, gb: UInt64) -> DeviceBackup {
            DeviceBackup(
                path: "/b/\(UUID())", deviceName: "iPhone", productName: nil, systemVersion: nil,
                date: days.map { now.addingTimeInterval(-$0 * 86400) }, size: gb * 1_000_000_000, isEncrypted: false
            )
        }
        let old = CleanupSummary.oldBackups([backup(900, gb: 30), backup(400, gb: 18), backup(3, gb: 60), backup(nil, gb: 5)], now: now)
        #expect(old?.bytes == 48_000_000_000)
        #expect(old?.oldest == now.addingTimeInterval(-900 * 86400))
        #expect(CleanupSummary.oldBackups([backup(3, gb: 60), backup(nil, gb: 5)], now: now) == nil)
    }
}
