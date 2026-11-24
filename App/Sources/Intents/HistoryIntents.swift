import AppIntents
import Core
import Foundation
import History
import Readouts
import Sampling

// What History knows, for Shortcuts and Siri (1.6): your day, out of the ordinary, builds and
// agents. Each returns its summary as text, so a shortcut can pass it along.

enum DayChoice: String, AppEnum {
    case today, yesterday

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Day"
    static let caseDisplayRepresentations: [DayChoice: DisplayRepresentation] = [.today: "Today", .yesterday: "Yesterday"]
}

struct GetYourDayIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Your Day"
    static let description = IntentDescription(
        "Time in use, slowdowns, alerts, crashes and your agents' time, for today or yesterday.",
        categoryName: "History"
    )

    @Parameter(title: "Day", default: .today)
    var day: DayChoice

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let store = try await IntentData.history()
        let now = Date()
        let calendar = Calendar.current
        let date = day == .today ? now : calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let crashes = await LiveCrashReports().reports(since: calendar.startOfDay(for: date)).filter(\.isAppCrash)
        let result = await DayStoryReader.read(
            day: date, now: now, history: store, hasBattery: AppModel.shared.services.metrics.hardware.hasBattery,
            alerts: store, crashes: crashes
        )
        let text = HistorySummaries.day(result, isToday: day == .today)
        return .result(value: text, dialog: "\(text)")
    }
}

struct GetUnusualIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Out of the Ordinary"
    static let description = IntentDescription(
        "Apps doing far more than their usual day on this Mac, today.",
        categoryName: "History"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let store = try await IntentData.history()
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        let past = await Baselines.readPast(store, before: today)
        let found = await Baselines.readToday(store, past: past, today: today, now: now, limit: 4)
        let text = HistorySummaries.unusual(found, daysLeftToLearn: Baselines.minimumDays - Baselines.daysLearned(past))
        return .result(value: text, dialog: "\(text)")
    }
}

struct GetBuildTimesIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Build Times"
    static let description = IntentDescription(
        "This week's builds, and the projects whose builds got slower.",
        categoryName: "Developer"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let store = try await IntentData.history()
        let now = Date()
        // The trend reads four weeks; the count is this week's.
        let runs = await (try? store.buildRuns(from: now.addingTimeInterval(-28 * 86400), to: now)) ?? []
        let week = runs.filter { $0.start >= now.addingTimeInterval(-7 * 86400) }
        let projects = BuildStats.byProject(runs, now: now).filter { project in week.contains { $0.project == project.project } }
        let text = HistorySummaries.builds(projects, builds: week.count)
        return .result(value: text, dialog: "\(text)")
    }
}

struct GetAgentTimeIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Agent Time"
    static let description = IntentDescription(
        "How long your coding agents worked this week, and where.",
        categoryName: "Developer"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let store = try await IntentData.history()
        let now = Date()
        let rows = await (try? store.agentUsage(from: now.addingTimeInterval(-7 * 86400), to: now)) ?? []
        let text = HistorySummaries.agents(rows)
        return .result(value: text, dialog: "\(text)")
    }
}
