import Core
import Foundation

/// A working week's streaks: long runs in Xcode, broken up by Messages and Safari (D-271).
extension SimulatedThirtyDayHistory {
    public func focusStretches(from: Date, to: Date) async throws -> [FocusStretch] {
        let apps = try await focusTotals(from: from, to: to, limit: 4).map(\.app)
        guard let xcode = apps.first, let safari = apps.dropFirst().first, let terminal = apps.dropFirst(2).first,
              let messages = apps.dropFirst(3).first
        else {
            return []
        }
        // Minutes: the app, its length, and a look away of 15 s after some.
        let day: [(AppIdentity, Double)] = [
            (xcode, 62), (messages, 4), (xcode, 38), (safari, 12), (terminal, 21), (messages, 2), (safari, 27), (xcode, 18),
        ]
        var stretches: [FocusStretch] = []
        let calendar = Calendar.current
        var start = calendar.startOfDay(for: from)
        while start < to {
            var at = start.addingTimeInterval(9 * 3600)
            let weekday = calendar.component(.weekday, from: start)
            for (index, (app, minutes)) in day.enumerated() {
                let length = minutes * 60 * (0.7 + 0.1 * Double((weekday + index) % 5))
                let end = at.addingTimeInterval(length)
                if at >= from, end <= to {
                    stretches.append(FocusStretch(app: app, start: at, end: end))
                }
                at = end.addingTimeInterval(index == 2 ? 600 : 4)
            }
            start = calendar.date(byAdding: .day, value: 1, to: start) ?? to
        }
        return stretches
    }
}

/// Twelve weeks of hours: busy weekday afternoons, a quiet weekend, asleep overnight (D-272).
extension SimulatedThirtyDayHistory: HourRhythmStore {
    public func wholeMacHours(from: Date, to: Date) async throws -> [HourSample] {
        let calendar = Calendar.current
        return stride(from: from.timeIntervalSince1970, to: to.timeIntervalSince1970, by: 3600).compactMap { t -> HourSample? in
            let at = Date(timeIntervalSince1970: t)
            let hour = calendar.component(.hour, from: at)
            guard (7 ..< 24).contains(hour) else {
                return nil
            }
            let weekend = calendar.isDateInWeekend(at)
            let afternoon = max(0, 1 - abs(Double(hour) - 15) / 7)
            let wobble = 0.5 + 0.5 * sin(t / 13000)
            return HourSample(at: at, cpu: (weekend ? 3 : 8) + (weekend ? 10 : 34) * afternoon * (0.6 + 0.4 * wobble), coveredMinutes: 50)
        }
    }
}

/// Two chargers over a few weeks, the smaller one mostly at a desk (D-274).
extension SimulatedThirtyDayHistory: ChargerHistoryStore {
    public func chargerUse(days: Int) async throws -> [ChargerUse] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return (0 ..< min(days, 21)).reversed().flatMap { back -> [ChargerUse] in
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else {
                return []
            }
            func use(_ rating: Int, _ band: ChargeBand?, minutes: Double, gained: Double, watts: Double, peak: Double) -> ChargerUse {
                ChargerUse(
                    day: day, ratingWatts: rating, condition: ChargeCondition(band: band, isWarm: false, isBusy: false),
                    seconds: minutes * 60, percentGained: gained, deliveredWattSeconds: watts * minutes * 60,
                    deliveredSeconds: minutes * 60, peakWatts: peak
                )
            }
            guard back % 3 == 0 else {
                return [
                    use(96, .low, minutes: 18, gained: 26, watts: 74, peak: 91),
                    use(96, .middle, minutes: 22, gained: 19, watts: 46, peak: 70),
                    use(96, .high, minutes: 28, gained: 8, watts: 21, peak: 34),
                    use(96, nil, minutes: 240, gained: 0, watts: 12, peak: 28),
                ]
            }
            return [
                use(67, .low, minutes: 24, gained: 22, watts: 51, peak: 62),
                use(67, .middle, minutes: 26, gained: 18, watts: 34, peak: 52),
                use(67, .high, minutes: 30, gained: 8, watts: 19, peak: 30),
                use(67, nil, minutes: 180, gained: 0, watts: 11, peak: 24),
            ]
        }
    }
}
