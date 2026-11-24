import Core
import Foundation
@testable import MactivityCLI
import Testing

/// `mactivity agents`, `mactivity day` (D-193) and `mactivity unusual` (D-202): parsing, and the words.
struct HistoryCommandTests {
    @Test("agents takes --days and --json; day takes a day and --json")
    func parsing() throws {
        #expect(try ArgumentParser.parse(["agents"]) == .agents(days: 7, json: false))
        #expect(try ArgumentParser.parse(["agents", "--days", "30", "--json"]) == .agents(days: 30, json: true))
        #expect(try ArgumentParser.parse(["agents", "--days=3"]) == .agents(days: 3, json: false))
        #expect(throws: UsageError.invalidDays("0")) { try ArgumentParser.parse(["agents", "--days", "0"]) }
        #expect(try ArgumentParser.parse(["day"]) == .day(.today, json: false))
        #expect(try ArgumentParser.parse(["day", "yesterday", "--json"]) == .day(.yesterday, json: true))
        #expect(try ArgumentParser.parse(["day", "2026-10-14"]) == .day(.date(year: 2026, month: 10, day: 14), json: false))
        #expect(throws: UsageError.invalidDate("tomorrow")) { try ArgumentParser.parse(["day", "tomorrow"]) }
        #expect(throws: UsageError.unexpectedArgument("today", command: "day")) { try ArgumentParser.parse(["day", "yesterday", "today"]) }
    }

    @Test("Each event in plain words")
    func words() {
        #expect(HistoryText.describe(.wake(.keyboardOrTrackpad)).text == "Woke up (keyboard or trackpad)")
        #expect(HistoryText.describe(.slowdown([.memory, .cpu])).text == "Slowdown: memory ran short, processor near full")
        #expect(HistoryText.describe(.agent(name: "Claude Code", project: "api")).text == "Claude Code in api")
        #expect(HistoryText.describe(.agent(name: "Codex", project: "")).text == "Codex")
        #expect(HistoryText.describe(.pluggedIn(level: 61.4)).kind == "plugged_in")
    }

    @Test("unusual takes only --json, and says when it's still learning or nothing stands out")
    func unusual() throws {
        #expect(try ArgumentParser.parse(["unusual", "--json"]) == .unusual(json: true))
        #expect(throws: UsageError.unexpectedArgument("today", command: "unusual")) { try ArgumentParser.parse(["unusual", "today"]) }
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(HistoryText.unusual(UnusualJSON(day: day, daysLearned: 3, found: [])).contains("2 more days"))
        #expect(HistoryText.unusual(UnusualJSON(day: day, daysLearned: 14, found: [])).hasPrefix("Nothing out of the ordinary"))
        let safari = AppIdentity(id: "com.apple.Safari", name: "Safari", bundleID: nil, iconKey: "x", kind: .app)
        let found = UnusualJSON(
            day: day, daysLearned: 14, found: [UnusualUsage(app: safari, metric: .memory, today: 5.5e9, usual: 1.3e9)]
        )
        #expect(!found.learning)
        #expect(found.apps.first?.metric == "memory")
        #expect(found.apps.first?.timesUsual == 4.23)
        #expect(HistoryText.unusual(found).contains("Safari  memory"))
    }

    @Test("builds takes --days and --json, and lists each project with its trend (D-209)")
    func builds() throws {
        #expect(try ArgumentParser.parse(["builds"]) == .builds(days: 7, json: false))
        #expect(try ArgumentParser.parse(["builds", "--days", "30", "--json"]) == .builds(days: 30, json: true))
        #expect(try ArgumentParser.parse(["builds", "-h"]) == .help(topic: "builds"))
        #expect(throws: UsageError.unknownOption("--fast", command: "builds")) { try ArgumentParser.parse(["builds", "--fast"]) }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let runs = (0 ..< 6).map { index in
            let start = now - Double(index) * 4 * 86400
            return BuildRun(
                start: start,
                end: start + (index < 2 ? 95 : 60),
                project: "Mactivity",
                tool: "Swift",
                averageCPU: 40,
                peakMemory: 1
            )
        }
        let json = BuildsJSON(runs: runs, stats: BuildStats.byProject(runs, now: now + 1), from: now - 30 * 86400, to: now)
        #expect(json.projects.first?.builds == 6)
        #expect(json.projects.first?.lastSeconds == 95)
        let text = HistoryText.builds(json)
        #expect(text.contains("Mactivity") && text.contains("1m 35s"))
        #expect(HistoryText.builds(BuildsJSON(runs: [], stats: [], from: now, to: now)).hasPrefix("No builds recorded"))
    }

    @Test("A date that doesn't exist, or hasn't happened, isn't a day (D-219)")
    func impossibleDates() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(DaySpec.date(year: 2026, month: 2, day: 30).date(now: now) == nil)
        #expect(DaySpec.date(year: 2099, month: 1, day: 1).date(now: now) == nil)
        #expect(DaySpec.date(year: 2026, month: 2, day: 28).date(now: now) != nil)
        #expect(DaySpec.date(year: 2026, month: 2, day: 30).text == "2026-02-30")
    }

    @Test(
        "A typed date is Gregorian on a Mac set to another calendar (D-221)",
        arguments: [Calendar.Identifier.buddhist, .japanese, .hebrew]
    )
    func otherCalendars(identifier: Calendar.Identifier) throws {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Bangkok"))
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let date = try #require(DaySpec.date(year: 2026, month: 9, day: 1).date(now: now, calendar: calendar))
        #expect(Formatters.localDay(date, timeZone: calendar.timeZone) == "2026-09-01")
    }

    @Test("Yesterday is the day before today's start")
    func days() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 9)) ?? Date()
        #expect(DaySpec.yesterday.date(now: now, calendar: calendar) == calendar.date(from: DateComponents(year: 2026, month: 2, day: 28)))
    }
}
