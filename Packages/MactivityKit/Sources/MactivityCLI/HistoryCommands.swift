import Core
import Foundation
import History
import Sampling

/// Which day `mactivity day` tells.
enum DaySpec: Equatable {
    case today, yesterday
    case date(year: Int, month: Int, day: Int)

    /// "today", "yesterday" or "2026-10-14".
    init?(_ text: String) {
        switch text.lowercased() {
        case "today": self = .today
        case "yesterday": self = .yesterday
        default:
            let parts = text.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3, (1 ... 12).contains(parts[1]), (1 ... 31).contains(parts[2]) else {
                return nil
            }
            self = .date(year: parts[0], month: parts[1], day: parts[2])
        }
    }

    /// As typed: "today", "yesterday", "2026-02-30".
    var text: String {
        switch self {
        case .today: "today"
        case .yesterday: "yesterday"
        case let .date(year, month, day): String(format: "%04d-%02d-%02d", year, month, day)
        }
    }

    /// Nil for a date that doesn't exist (2026-02-30 isn't March 2) or hasn't happened yet.
    func date(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .today:
            return calendar.startOfDay(for: now)
        case .yesterday:
            return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        case let .date(year, month, day):
            // Typed as ISO 8601, which is Gregorian whatever calendar the Mac shows (Buddhist,
            // Japanese, Hebrew), in the Mac's time zone (D-221).
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = calendar.timeZone
            guard let date = gregorian.date(from: DateComponents(year: year, month: month, day: day)),
                  gregorian.dateComponents([.year, .month, .day], from: date) == DateComponents(year: year, month: month, day: day),
                  date <= now else {
                return nil
            }
            return date
        }
    }
}

extension ArgumentParser {
    static func parseAgents(_ arguments: [String]) throws(UsageError) -> Command {
        var days = 7
        var json = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            switch argument {
            case "--json":
                json = true
            case "-h", "--help":
                return .help(topic: "agents")
            case "--days":
                guard index < arguments.count else {
                    throw .missingValue(argument)
                }
                days = try dayCount(arguments[index])
                index += 1
            default:
                if argument.hasPrefix("--days=") {
                    days = try dayCount(String(argument.dropFirst("--days=".count)))
                } else if argument.hasPrefix("-") {
                    throw .unknownOption(argument, command: "agents")
                } else {
                    throw .unexpectedArgument(argument, command: "agents")
                }
            }
        }
        return .agents(days: days, json: json)
    }

    static func parseBuilds(_ arguments: [String]) throws(UsageError) -> Command {
        // The same options as agents, with errors that name builds.
        let parsed: Command
        do {
            parsed = try parseAgents(arguments)
        } catch {
            switch error {
            case let .unknownOption(option, _): throw .unknownOption(option, command: "builds")
            case let .unexpectedArgument(argument, _): throw .unexpectedArgument(argument, command: "builds")
            default: throw error
            }
        }
        if case let .agents(days, json) = parsed {
            return .builds(days: days, json: json)
        }
        return .help(topic: "builds")
    }

    static func parseDay(_ arguments: [String]) throws(UsageError) -> Command {
        var spec = DaySpec.today
        var json = false
        var named = false
        for argument in arguments {
            switch argument {
            case "--json":
                json = true
            case "-h", "--help":
                return .help(topic: "day")
            default:
                if argument.hasPrefix("-") {
                    throw .unknownOption(argument, command: "day")
                }
                guard !named, let parsed = DaySpec(argument) else {
                    throw named ? .unexpectedArgument(argument, command: "day") : .invalidDate(argument)
                }
                spec = parsed
                named = true
            }
        }
        return .day(spec, json: json)
    }

    private static func dayCount(_ value: String) throws(UsageError) -> Int {
        guard let number = Int(value), (1 ... 365).contains(number) else {
            throw .invalidDays(value)
        }
        return number
    }
}

/// History, read-only, from the app's own database (D-193).
enum HistoryReading {
    enum Failure: LocalizedError {
        case noHistory
        case tooOld

        var errorDescription: String? {
            switch self {
            case .noHistory: "No history yet. Mactivity records it while it runs."
            case .tooOld: "This history is from an older Mactivity. Update Mactivity to read agent history."
            }
        }
    }

    static func store() throws -> SQLiteHistoryStore {
        let url = try SQLiteHistoryStore.defaultURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Failure.noHistory
        }
        return try SQLiteHistoryStore.openReadOnly(url: url)
    }

    static func agents(days: Int, now: Date = Date()) async throws -> AgentHistoryJSON {
        let store = try store()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        let rows: [AgentUsage]
        do {
            rows = try await store.agentUsage(from: start, to: now)
        } catch {
            throw Failure.tooOld
        }
        let spans = (0 ..< days).compactMap { offset -> DateInterval? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start),
                  let next = calendar.date(byAdding: .day, value: 1, to: day) else {
                return nil
            }
            return DateInterval(start: day, end: min(next, max(day, now)))
        }
        return AgentHistoryJSON(rows: rows, days: spans, from: start, to: now)
    }

    static func day(_ spec: DaySpec, now: Date = Date()) async throws -> DayJSON {
        guard let day = spec.date(now: now) else {
            throw UsageError.invalidDate(spec.text)
        }
        let store = try store()
        // Crashes too, as the app's Your day shows them (D-219).
        let crashed = await LiveCrashReports().reports(since: Calendar.current.startOfDay(for: day)).filter(\.isAppCrash)
        let result = await DayStoryReader.read(day: day, now: now, history: store, hasBattery: true, alerts: store, crashes: crashed)
        return DayJSON(day: day, result: result)
    }

    static func builds(days: Int, now: Date = Date()) async throws -> BuildsJSON {
        let store = try store()
        let start = now.addingTimeInterval(-Double(days) * 86400)
        do {
            // The trend needs four weeks, whatever the span listed.
            let runs = try await store.buildRuns(from: min(start, now.addingTimeInterval(-28 * 86400)), to: now)
            return BuildsJSON(runs: runs.filter { $0.start >= start }, stats: BuildStats.byProject(runs, now: now), from: start, to: now)
        } catch {
            throw Failure.tooOld
        }
    }

    static func unusual(now: Date = Date()) async throws -> UnusualJSON {
        let store = try store()
        let today = Calendar.current.startOfDay(for: now)
        let past = await Baselines.readPast(store, before: today)
        let found = await Baselines.readToday(store, past: past, today: today, now: now, limit: 10)
        return UnusualJSON(day: today, daysLearned: Baselines.daysLearned(past), found: found)
    }
}

struct BuildsJSON: Encodable {
    struct Project: Encodable {
        let project: String
        let tool: String
        let builds: Int
        let lastSeconds: Double
        let lastEnded: Date
        @NullEncoded var medianSecondsThisWeek: Double?
        @NullEncoded var medianSecondsWeeksBefore: Double?
        let slower: Bool
    }

    struct Run: Encodable {
        let project: String
        let tool: String
        let start: Date
        let seconds: Double
        let averageCPUPercent: Double
        let peakMemoryBytes: UInt64
    }

    let schemaVersion = JSONOutput.schemaVersion
    let from: Date
    let to: Date
    let projects: [Project]
    let builds: [Run]

    init(runs: [BuildRun], stats: [ProjectBuilds], from: Date, to: Date) {
        self.from = from
        self.to = to
        let listed = Set(runs.map(\.project))
        // The trend reads four weeks; the count is the span asked for.
        let counts = Dictionary(grouping: runs, by: \.project).mapValues(\.count)
        projects = stats.filter { listed.contains($0.project) }.map {
            Project(
                project: $0.project, tool: $0.tool, builds: counts[$0.project] ?? 0, lastSeconds: JSONOutput.round($0.last.duration),
                lastEnded: $0.last.end, medianSecondsThisWeek: $0.recentMedian.map(JSONOutput.round),
                medianSecondsWeeksBefore: $0.earlierMedian.map(JSONOutput.round), slower: $0.isSlower
            )
        }
        builds = runs.suffix(100).map {
            Run(
                project: $0.project, tool: $0.tool, start: $0.start, seconds: JSONOutput.round($0.duration),
                averageCPUPercent: JSONOutput.round($0.averageCPU), peakMemoryBytes: $0.peakMemory
            )
        }
    }
}

struct UnusualJSON: Encodable {
    struct App: Encodable {
        let id: String
        let name: String
        let metric: String
        let today: Double
        let usual: Double
        @NullEncoded var timesUsual: Double?
        let text: String
    }

    let schemaVersion = JSONOutput.schemaVersion
    let date: String
    /// Days of history "usual" is learned from; under `Baselines.minimumDays`, nothing is listed.
    let daysLearned: Int
    let learning: Bool
    let apps: [App]

    init(day: Date, daysLearned: Int, found: [UnusualUsage]) {
        date = Formatters.localDay(day)
        self.daysLearned = daysLearned
        learning = daysLearned < Baselines.minimumDays
        apps = found.map { usage in
            App(
                id: usage.app.id, name: usage.app.name,
                metric: usage.metric.rawValue,
                today: JSONOutput.round(usage.today), usual: JSONOutput.round(usage.usual),
                timesUsual: usage.ratio.map { JSONOutput.round($0) }, text: UnusualText.english(usage)
            )
        }
    }
}

struct AgentHistoryJSON: Encodable {
    struct Total: Encodable {
        let agent: String
        @NullEncoded var project: String?
        let seconds: Double
        let averageCPUPercent: Double
        let peakMemoryBytes: UInt64
        let days: Int
    }

    struct Day: Encodable {
        let date: String
        let seconds: Double
    }

    let schemaVersion = JSONOutput.schemaVersion
    let from: Date
    let to: Date
    let totalSeconds: Double
    let agents: [Total]
    let days: [Day]

    init(rows: [AgentUsage], days spans: [DateInterval], from: Date, to: Date) {
        self.from = from
        self.to = to
        let byDay = AgentWeek.byDay(rows, days: spans)
        totalSeconds = byDay.reduce(0) { $0 + $1.seconds }
        agents = AgentWeek.totals(rows).map {
            Total(
                agent: $0.agent, project: $0.project.isEmpty ? nil : $0.project, seconds: Double($0.minutes * 60),
                averageCPUPercent: JSONOutput.round($0.averageCPU), peakMemoryBytes: $0.peakMemory, days: $0.days
            )
        }
        days = byDay.map { Day(date: Formatters.localDay($0.day), seconds: $0.seconds) }
    }
}

struct DayJSON: Encodable {
    struct Event: Encodable {
        let kind: String
        let start: Date
        @NullEncoded var end: Date?
        let text: String
        let apps: [String]
    }

    let schemaVersion = JSONOutput.schemaVersion
    let date: String
    let activeSeconds: Double
    let events: [Event]

    init(day: Date, result: DayStoryResult) {
        date = Formatters.localDay(day)
        activeSeconds = JSONOutput.round(result.activeSeconds)
        events = result.events.map { event in
            let (kind, text) = HistoryText.describe(event.kind)
            return Event(kind: kind, start: event.start, end: event.end, text: text, apps: (result.apps[event.id] ?? []).map(\.name))
        }
    }
}

/// Plain English for the command line, the same in every locale, like the rest of its output.
enum HistoryText {
    static func describe(_ kind: DayEvent.Kind) -> (kind: String, text: String) {
        (kind.code, kind.englishText)
    }

    static func agents(_ week: AgentHistoryJSON) -> String {
        guard !week.agents.isEmpty else {
            return "No agent sessions recorded since \(week.from.formatted(date: .abbreviated, time: .omitted))."
        }
        var lines = ["Agent time: \(hours(week.totalSeconds)) since \(week.from.formatted(date: .abbreviated, time: .omitted))", ""]
        var table = TextTable([
            .init(title: "AGENT", alignment: .left), .init(title: "PROJECT", alignment: .left), .init(title: "TIME", alignment: .right),
            .init(title: "CPU", alignment: .right), .init(title: "PEAK MEMORY", alignment: .right),
        ])
        for total in week.agents {
            table.add([
                total.agent, total.project ?? "–", hours(total.seconds), Formatters.percent(total.averageCPUPercent, fractionDigits: 1),
                Int64(clamping: total.peakMemoryBytes).formatted(.byteCount(style: .memory)),
            ])
        }
        lines.append(table.render())
        return lines.joined(separator: "\n")
    }

    static func day(_ day: DayJSON) -> String {
        var lines = ["\(day.date) · \(hours(day.activeSeconds)) in use"]
        if day.events.isEmpty {
            lines.append("A quiet day: no slowdowns, busy stretches, alerts or crashes.")
        }
        for event in day.events {
            let start = event.start.formatted(date: .omitted, time: .shortened)
            let time = event.end.map { "\(start) – \($0.formatted(date: .omitted, time: .shortened))" } ?? start
            let apps = event.apps.isEmpty ? "" : "  (\(event.apps.joined(separator: ", ")))"
            lines.append("\(time.padding(toLength: 20, withPad: " ", startingAt: 0)) \(event.text)\(apps)")
        }
        return lines.joined(separator: "\n")
    }

    static func builds(_ builds: BuildsJSON) -> String {
        guard !builds.projects.isEmpty else {
            let since = builds.from.formatted(date: .abbreviated, time: .omitted)
            return "No builds recorded since \(since). Mactivity times builds while it runs."
        }
        var table = TextTable([
            .init(title: "PROJECT", alignment: .left), .init(title: "TOOL", alignment: .left), .init(title: "BUILDS", alignment: .right),
            .init(title: "LAST", alignment: .right), .init(title: "THIS WEEK", alignment: .right), .init(
                title: "BEFORE",
                alignment: .right
            ),
        ])
        for project in builds.projects {
            table.add([
                project.project.isEmpty ? "–" : project.project, project.tool, "\(project.builds)", seconds(project.lastSeconds),
                project.medianSecondsThisWeek.map(seconds) ?? "–",
                (project.medianSecondsWeeksBefore.map(seconds) ?? "–") + (project.slower ? "  slower" : ""),
            ])
        }
        return table.render()
    }

    static func seconds(_ value: Double) -> String {
        Duration.seconds(value.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }

    static func unusual(_ unusual: UnusualJSON) -> String {
        if unusual.learning {
            let left = Baselines.minimumDays - unusual.daysLearned
            return "Still learning this Mac's usual day: \(left) more day\(left == 1 ? "" : "s") of history to go."
        }
        guard !unusual.apps.isEmpty else {
            return "Nothing out of the ordinary today: every app is close to its usual day."
        }
        let width = unusual.apps.map(\.name.count).max() ?? 0
        return (["Out of the ordinary today, against each app's usual day:"] + unusual.apps.map {
            "  \($0.name.padding(toLength: width, withPad: " ", startingAt: 0))  \($0.text)"
        }).joined(separator: "\n")
    }

    static func hours(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .narrow, maximumUnitCount: 2))
    }
}
