import Foundation

/// Reading the days `Baselines` compares from History (D-198, D-201): shared by Overview, the
/// Out of the ordinary alert, an app's history page and `mactivity unusual`.
extension Baselines {
    /// How far back "usual" looks.
    public static let pastDays = 14
    /// Apps read for each day: enough to cover anything that could stand out.
    static let appsPerDay = 30

    /// Each metric's `pastDays` days before `today`, oldest first. These don't change once the
    /// day is over, so callers keep them for the day.
    public static func readPast(
        _ history: any DailyHistoryStore, before today: Date, calendar: Calendar = .current
    ) async -> [Metric: [[AppTotal]]] {
        var past: [Metric: [[AppTotal]]] = [:]
        for metric in metrics {
            var days: [[AppTotal]] = []
            for offset in (1 ... pastDays).reversed() {
                guard let start = calendar.date(byAdding: .day, value: -offset, to: today),
                      let end = calendar.date(byAdding: .day, value: 1, to: start) else {
                    continue
                }
                await days.append((try? history.topApps(metric: metric, from: start, to: end, limit: appsPerDay)) ?? [])
            }
            past[metric] = days
        }
        return past
    }

    /// What stands out from `today` (midnight) to `now` against `past`, most unusual first.
    public static func readToday(
        _ history: any DailyHistoryStore, past: [Metric: [[AppTotal]]], today: Date, now: Date, limit: Int = 4
    ) async -> [UnusualUsage] {
        var result: [UnusualUsage] = []
        for metric in metrics {
            let todays = await (try? history.topApps(metric: metric, from: today, to: now, limit: appsPerDay)) ?? []
            result += unusual(metric: metric, today: todays, before: past[metric] ?? [])
        }
        return Array(result.sorted { score($0) > score($1) }.prefix(limit))
    }

    /// Days with any use in `past`: under `minimumDays`, Mactivity is still learning.
    public static func daysLearned(_ past: [Metric: [[AppTotal]]]) -> Int {
        (past[.cpu] ?? []).count { !$0.isEmpty }
    }
}
