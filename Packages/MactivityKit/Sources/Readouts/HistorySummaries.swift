import Core
import Foundation

/// Speakable summaries of what History knows (1.6): your day, out of the ordinary, builds and
/// agents, for Siri and Shortcuts. Pure, so the wording is tested.
public enum HistorySummaries {
    /// "Today: 5h 12m in use. 1 slowdown, 2 alerts and 1 crash. Agents worked 2h 10m."
    public static func day(_ result: DayStoryResult, isToday: Bool, locale: Locale = .current) -> String {
        let used = hours(result.activeSeconds, locale: locale)
        var sentences = [isToday
            ? String(localized: "Today: \(used) in use.", bundle: .strings, locale: locale, comment: "Siri: your day, time in use")
            : String(localized: "Yesterday: \(used) in use.", bundle: .strings, locale: locale, comment: "Siri: your day, time in use")]
        var slowdowns = 0
        var alerts = 0
        var crashes = 0
        for event in result.events {
            switch event.kind {
            case .slowdown: slowdowns += 1
            case let .alert(_, _, count): alerts += count
            case .crash: crashes += 1
            default: break
            }
        }
        var parts: [String] = []
        if slowdowns > 0 {
            parts.append(String(localized: "\(slowdowns) slowdowns", bundle: .strings, locale: locale, comment: "Siri: your day"))
        }
        if alerts > 0 {
            parts.append(String(localized: "\(alerts) alerts", bundle: .strings, locale: locale, comment: "Siri: your day"))
        }
        if crashes > 0 {
            parts.append(String(localized: "\(crashes) crashes", bundle: .strings, locale: locale, comment: "Siri: your day"))
        }
        if parts.isEmpty {
            sentences.append(String(localized: "A quiet day: no slowdowns, alerts or crashes.", bundle: .strings, locale: locale))
        } else {
            sentences.append(parts.formatted(.list(type: .and).locale(locale)) + ".")
        }
        if result.agentSeconds >= 60 {
            let agents = hours(result.agentSeconds, locale: locale)
            sentences.append(String(localized: "Agents worked \(agents).", bundle: .strings, locale: locale, comment: "Siri: your day"))
        }
        return sentences.joined(separator: " ")
    }

    /// "Safari: 5.5 GB of memory today, 4× its usual 1.3 GB." One line per app.
    public static func unusual(_ found: [UnusualUsage], daysLeftToLearn: Int, locale: Locale = .current) -> String {
        guard daysLeftToLearn <= 0 else {
            return String(
                localized: "Still learning this Mac's usual day: \(daysLeftToLearn) more days of history.",
                bundle: .strings, locale: locale, comment: "Siri: out of the ordinary, before there's enough history"
            )
        }
        guard !found.isEmpty else {
            return String(
                localized: "Nothing out of the ordinary today: every app is close to its usual day.",
                bundle: .strings, locale: locale
            )
        }
        return found.map { "\($0.app.name): \(UnusualText.detail($0))." }.joined(separator: "\n")
    }

    /// "This week: 23 builds in 3 projects. Slower: mactivity, 2m 10s against 1m 40s."
    public static func builds(_ projects: [ProjectBuilds], builds: Int, locale: Locale = .current) -> String {
        guard builds > 0 else {
            return String(localized: "No builds this week.", bundle: .strings, locale: locale, comment: "Siri: build times")
        }
        let count = projects.count
        var sentences = [String(
            localized: "This week: \(builds) builds in \(count) projects.", bundle: .strings, locale: locale, comment: "Siri: build times"
        )]
        for project in projects where project.isSlower {
            guard let recent = project.recentMedian, let earlier = project.earlierMedian else {
                continue
            }
            let name = project.project.isEmpty ? project.tool : project.project
            sentences.append(String(
                localized: "Slower: \(name), \(seconds(recent, locale: locale)) against \(seconds(earlier, locale: locale)).",
                bundle: .strings, locale: locale, comment: "Siri: a project whose builds got slower: its median now, then before"
            ))
        }
        return sentences.joined(separator: " ")
    }

    /// "This week your agents worked 32h, most in mactivity (29h, Claude Code)."
    public static func agents(_ rows: [AgentUsage], locale: Locale = .current) -> String {
        // Two agents at once count once: each quarter-hour's busiest row (D-219).
        let total = Dictionary(grouping: rows, by: \.start).values.reduce(0) { $0 + ($1.map(\.minutes).max() ?? 0) }
        guard total > 0 else {
            return String(localized: "No agent sessions this week.", bundle: .strings, locale: locale, comment: "Siri: agent time")
        }
        let time = hours(Double(total) * 60, locale: locale)
        let byProject = Dictionary(grouping: rows, by: \.project).mapValues { $0.reduce(0) { $0 + $1.minutes } }
        guard let top = byProject.max(by: { $0.value < $1.value }), !top.key.isEmpty else {
            return String(localized: "This week your agents worked \(time).", bundle: .strings, locale: locale, comment: "Siri: agent time")
        }
        let agent = Dictionary(grouping: rows.filter { $0.project == top.key }, by: \.agent)
            .mapValues { $0.reduce(0) { $0 + $1.minutes } }
            .max { $0.value < $1.value }?.key ?? ""
        let projectTime = hours(Double(top.value) * 60, locale: locale)
        return String(
            localized: "This week your agents worked \(time), most in \(top.key) (\(projectTime), \(agent)).",
            bundle: .strings, locale: locale, comment: "Siri: agent time, then the busiest project, its time and its agent"
        )
    }

    static func hours(_ seconds: Double, locale: Locale) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .narrow, maximumUnitCount: 2).locale(locale))
    }

    static func seconds(_ value: Double, locale: Locale) -> String {
        Duration.seconds(value.rounded())
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2).locale(locale))
    }
}
