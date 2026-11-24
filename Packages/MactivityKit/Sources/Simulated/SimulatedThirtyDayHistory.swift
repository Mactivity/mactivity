import Core
import Foundation

/// Thirty days of made-up but plausible history: a daily rhythm, bursts, a sleeping Mac at night,
/// and a few spells of thermal pressure. Deterministic for a given `now`. Used by chart renders
/// and by the website's screenshots (scripts/site-shots.sh).
public actor SimulatedThirtyDayHistory: HistoryStore, BatteryHistoryStore {
    private let apps: SimulatedHistoryStore
    let now: Date

    /// `apps` answers the top-apps questions (record a few snapshots into it first); `now` is
    /// where the thirty days end. Tests pass a fixed date so renders compare run to run.
    public init(apps: SimulatedHistoryStore, now: Date = Date()) {
        self.apps = apps
        self.now = now
    }

    public func series(metric: Metric, app _: AppIdentity.ID?, range: HistoryRange) async throws -> [SeriesPoint] {
        let step: TimeInterval = switch range {
        case .h12, .h24: 60
        case .d7, .d30: 900
        case .d90, .y1: 3600
        }
        let count = Int(Double(range.duration.components.seconds) / step)
        return (0 ..< count).compactMap { index in
            let at = now - Double(count - index) * step
            let hour = Calendar.current.component(.hour, from: at)
            // Asleep from 1 to 7: no points, so the chart shows a gap.
            if (1 ..< 7).contains(hour) {
                return nil
            }
            // Not charging then: no reading, rather than a reading of 0.
            if metric == .batteryTempCharging, !(hour >= 22 || hour < 9) {
                return nil
            }
            let (average, maximum) = Self.value(metric, at: at, index: index)
            return SeriesPoint(at: at, average: average, maximum: maximum)
        }
    }

    private static func value(_ metric: Metric, at: Date, index: Int) -> (Double, Double) {
        let t = at.timeIntervalSince1970
        let daily = 0.5 + 0.5 * sin(t / 86400 * 2 * .pi)
        let wobble = 0.5 + 0.5 * sin(t / 1300) * cos(t / 4700)
        let burst = index % 97 < 6 ? 1.0 : 0
        let load = min(1, 0.15 + 0.35 * daily + 0.3 * wobble + 0.3 * burst)
        let peak = min(1, load + 0.1 + 0.25 * wobble)
        switch metric {
        case .memory: return (18e9 + 8e9 * daily, 19e9 + 9e9 * daily)
        case .diskRead, .diskWrite, .netIn, .netOut:
            let scale = metric == .diskWrite || metric == .netIn ? 4e6 : 1.5e6
            return (scale * load * load, scale * peak * peak)
        case .cpuTemperature, .gpuTemperature:
            let base = metric == .cpuTemperature ? 48.0 : 42.0
            return (base + 30 * load, base + 34 * peak)
        case .fanSpeed: return (1200 + 3000 * load * load, 1300 + 3500 * peak * peak)
        case .thermalPressure:
            let rank = index % 211 < 3 ? Double(ThermalPressure.serious.rank) : 0
            return (rank, rank)
        case .batteryLevel:
            // A day's discharge from 100, charged overnight.
            let hour = Double(Calendar.current.component(.hour, from: at))
            let level = max(15, 100 - max(0, hour - 7) * 5.5)
            return (level, level)
        case .memoryPressure: return (18 + 30 * load, 22 + 45 * peak)
        case .onBattery:
            let hour = Calendar.current.component(.hour, from: at)
            let away = (9 ..< 17).contains(hour) ? 1.0 : 0
            return (away, away)
        case .powerDraw:
            // Milliwatts: about 6 W idle, up to 40 W at peak.
            return (6000 + 22000 * load, 9000 + 31000 * peak)
        case .batteryTempCharging:
            // Charging overnight and in the morning; the series leaves out the rest of the day.
            return (31 + 6 * wobble, 34 + 7 * peak)
        case .batteryTempInUse: return (25 + 9 * load, 27 + 12 * peak)
        case .swapUsed: return (0.6e9 + 2.4e9 * daily, 0.8e9 + 2.8e9 * daily)
        case .diskFree:
            // About 1 GB a day less, from 780 GB a year ago.
            let days = (t - 1_760_000_000) / 86400
            return (780e9 - days * 1e9, 780e9 - days * 1e9)
        default: return (100 * load, 100 * peak)
        }
    }

    public func record(_: Snapshot) async throws {}

    public func topApps(metric: Metric, range: HistoryRange, limit: Int) async throws -> [AppTotal] {
        try await apps.topApps(metric: metric, range: range, limit: limit)
    }

    public func topAppsInPreviousPeriod(metric: Metric, range: HistoryRange, limit: Int) async throws -> [AppTotal] {
        try await apps.topAppsInPreviousPeriod(metric: metric, range: range, limit: limit)
    }

    public func total(metric _: Metric, range _: HistoryRange) async throws -> Double {
        0
    }

    public func flush() async throws {}

    public func storageSizeBytes() async -> UInt64 {
        0
    }

    public func deleteAll() async throws {}

    public func setRetention(days _: Int) async {}

    public func batteryHistory(days: Int) async throws -> [BatteryDay] {
        try await apps.batteryHistory(days: days)
    }
}

/// A year calendar with some texture (D-093): quieter weekends, busy spells, a week away.
extension SimulatedThirtyDayHistory: DailyHistoryStore {
    public func dailyValues(metric: Metric, days: Int) async throws -> [DayValue] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return (0 ..< max(1, days)).reversed().compactMap { back -> DayValue? in
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else {
                return nil
            }
            // Away for a week in early summer: no data, so the calendar shows gaps.
            if (150 ..< 157).contains(back) {
                return nil
            }
            let weekend = calendar.isDateInWeekend(day)
            let hash = Double((back &* 2_654_435_761) % 1000) / 1000
            let busy = 0.35 + 0.65 * hash * (weekend ? 0.45 : 1)
            let (average, maximum) = Self.value(metric, at: day.addingTimeInterval(14 * 3600), index: back)
            return DayValue(day: day, average: average * busy, maximum: maximum * (0.6 + 0.4 * busy))
        }
    }

    public func series(metric: Metric, app _: AppIdentity.ID?, from: Date, to: Date) async throws -> [SeriesPoint] {
        stride(from: from.timeIntervalSince1970, to: to.timeIntervalSince1970, by: 900).enumerated().compactMap { index, t in
            let at = Date(timeIntervalSince1970: t)
            let hour = Calendar.current.component(.hour, from: at)
            if (1 ..< 7).contains(hour) || (metric == .batteryTempCharging && !(hour >= 22 || hour < 9)) {
                return nil
            }
            let (average, maximum) = Self.value(metric, at: at, index: index)
            return SeriesPoint(at: at, average: average, maximum: maximum)
        }
    }

    public func topApps(metric: Metric, from _: Date, to _: Date, limit: Int) async throws -> [AppTotal] {
        try await apps.topApps(metric: metric, range: .d30, limit: limit)
    }

    /// The top apps' averages as if held for the whole span.
    public func totals(metrics: [Metric], from: Date, to: Date, limit: Int) async throws -> [AppTotal] {
        let seconds = to.timeIntervalSince(from)
        var byApp: [AppIdentity.ID: AppTotal] = [:]
        for metric in metrics {
            for total in try await apps.topApps(metric: metric, range: .d30, limit: limit) {
                let previous = byApp[total.app.id]?.value ?? 0
                byApp[total.app.id] = AppTotal(app: total.app, value: previous + total.value * seconds)
            }
        }
        return byApp.values.sorted { $0.value > $1.value }.prefix(limit).map(\.self)
    }

    public func systemTotal(metrics: [Metric], from: Date, to: Date) async throws -> Double {
        try await totals(metrics: metrics, from: from, to: to, limit: 50).reduce(0) { $0 + $1.value } * 1.2
    }

    public func firstRecorded() async throws -> Date? {
        Date().addingTimeInterval(-30 * 86400)
    }
}

/// AirPods charged every couple of days, a trackpad charged once a month (D-094).
extension SimulatedThirtyDayHistory: DeviceBatteryStore {
    public func recordDevices(_: [PeripheralBattery], at _: Date) async throws {}

    public func deviceHistory(days: Int) async throws -> [DeviceBatteryHistory] {
        let start = now.addingTimeInterval(-Double(max(1, days)) * 86400)
        func curve(every period: Double, drainPerHour: Double) -> [DeviceBatteryPoint] {
            stride(from: start.timeIntervalSince1970, through: now.timeIntervalSince1970, by: 3600).map { t in
                let sinceCharge = (t / 3600).truncatingRemainder(dividingBy: period)
                return DeviceBatteryPoint(at: Date(timeIntervalSince1970: t), percent: max(5, 100 - sinceCharge * drainPerHour))
            }
        }
        return [
            DeviceBatteryHistory(id: "airpods", name: "AirPods Pro", kind: .airPods, points: curve(every: 40, drainPerHour: 2.2)),
            DeviceBatteryHistory(
                id: "trackpad", name: "Magic Trackpad", kind: .trackpad, points: curve(every: 24 * 30, drainPerHour: 0.12)
            ),
        ]
    }
}

/// Asleep most nights from about 23:30 to 7:10, woken by the lid; a night it didn't sleep (D-096).
extension SimulatedThirtyDayHistory: PowerEventStore {
    public func recordPowerEvent(_: PowerEvent) async throws {}

    public func powerEvents(days: Int) async throws -> [PowerEvent] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var events: [PowerEvent] = []
        for back in (1 ... max(1, days)).reversed() where back != 3 {
            guard let night = calendar.date(byAdding: .day, value: -back, to: today) else {
                continue
            }
            let sleep = night.addingTimeInterval(23.5 * 3600 + Double(back % 5) * 900)
            let wake = night.addingTimeInterval(31 * 3600 + Double(back % 3) * 600)
            events.append(PowerEvent(at: sleep, kind: .sleep))
            if back % 4 == 0 {
                events.append(PowerEvent(at: sleep.addingTimeInterval(3 * 3600), kind: .wake, reason: "rtc maintenance"))
                events.append(PowerEvent(at: sleep.addingTimeInterval(3 * 3600 + 120), kind: .sleep))
            }
            if wake < now {
                events.append(PowerEvent(at: wake, kind: .wake, reason: "smc.sysState.Wake lid RTP.multi-touch"))
            }
        }
        return events
    }
}

/// A music app holding the Mac awake, as the Battery tab's banner would show it.
public struct SimulatedSleepBlockers: SleepBlockerSource {
    public init() {}

    public func blockers() async -> [SleepBlocker] {
        [SleepBlocker(
            id: "music", pid: 501,
            app: AppIdentity(
                id: "com.apple.Music",
                name: "Music",
                bundleID: "com.apple.Music",
                iconKey: "/System/Applications/Music.app",
                kind: .app
            ),
            reason: "Playing audio", keeps: .system, since: Date().addingTimeInterval(-1800)
        )]
    }
}

/// About six hours a day in front, most of it in Xcode (D-098).
extension SimulatedThirtyDayHistory: FocusStore {
    public func recordFocus(_: AppIdentity, from _: Date, to _: Date) async throws {}

    public func firstFocus() async throws -> Date? {
        Date().addingTimeInterval(-30 * 86400)
    }

    /// Xcode and Safari in use today; Docker Desktop last in front a week ago (D-135).
    public func lastFocus() async throws -> [AppIdentity.ID: Date] {
        let now = Date()
        return [
            "com.apple.dt.Xcode": now.addingTimeInterval(-600),
            "com.apple.Safari": now.addingTimeInterval(-60),
            "com.docker.docker": now.addingTimeInterval(-7 * 86400),
        ]
    }

    public func focusTotals(from: Date, to: Date, limit: Int) async throws -> [AppTotal] {
        let days = max(1, to.timeIntervalSince(from) / 86400)
        let apps = [
            AppIdentity(
                id: "com.apple.dt.Xcode",
                name: "Xcode",
                bundleID: "com.apple.dt.Xcode",
                iconKey: "/Applications/Xcode.app",
                kind: .app
            ),
            AppIdentity(
                id: "com.apple.Safari",
                name: "Safari",
                bundleID: "com.apple.Safari",
                iconKey: "/Applications/Safari.app",
                kind: .app
            ),
            AppIdentity(
                id: "com.apple.Terminal", name: "Terminal", bundleID: "com.apple.Terminal",
                iconKey: "/System/Applications/Utilities/Terminal.app", kind: .app
            ),
            AppIdentity(
                id: "com.apple.MobileSMS", name: "Messages", bundleID: "com.apple.MobileSMS",
                iconKey: "/System/Applications/Messages.app", kind: .app
            ),
            AppIdentity(
                id: "com.apple.Music",
                name: "Music",
                bundleID: "com.apple.Music",
                iconKey: "/System/Applications/Music.app",
                kind: .app
            ),
        ]
        let shares = [0.42, 0.24, 0.14, 0.08, 0.05]
        return zip(apps, shares).prefix(limit).map { AppTotal(app: $0, value: days * 6 * 3600 * $1) }
    }

    public func activeSeconds(from: Date, to: Date) async throws -> Double {
        // Day by day, weekdays busier than weekends, so Your week's chart has a shape and its
        // bars add up to the week's total.
        let calendar = Calendar.current
        var total = 0.0
        var day = from
        while day < to {
            let next = min(to, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) ?? to)
            let weekday = calendar.component(.weekday, from: day)
            let shape = [0.45, 1.05, 1.2, 0.95, 1.35, 0.9, 0.55][(weekday - 1) % 7]
            total += next.timeIntervalSince(day) / 86400 * 6 * 3600 * 0.93 * shape
            day = next
        }
        return total
    }
}

/// A working day on battery, mostly Xcode and Safari (D-100).
extension SimulatedThirtyDayHistory: BatteryUseStore {
    public func batteryUse(from: Date, to: Date, limit: Int) async throws -> BatteryUse {
        let days = max(1, to.timeIntervalSince(from) / 86400)
        let apps = try await focusTotals(from: from, to: to, limit: limit)
        let total = apps.reduce(0) { $0 + $1.value }
        return BatteryUse(
            apps: apps.map { AppTotal(app: $0.app, value: total > 0 ? $0.value / total : 0) },
            onBatterySeconds: days * 5.5 * 3600, drainedPercent: days * 61
        )
    }

    public func unpluggedAt(now: Date) async throws -> Date? {
        now.addingTimeInterval(-(2 * 3600 + 20 * 60))
    }
}
