import Core
import Foundation
import FoundationModels
import Observation
import os

/// Ask Mactivity (D-153): a question typed in Quick Search, answered by Apple Intelligence's
/// on-device model from the Mac's figures now and a tool that reads history. Only
/// `SystemLanguageModel.default`, which runs on the Mac: never the Private Cloud Compute model,
/// so nothing leaves the Mac (CLAUDE.md rule 3). Offered only where Apple Intelligence is on.
@MainActor
@Observable
public final class AskModel {
    public enum State: Equatable, Sendable {
        case idle
        case answering
        case answered
        case failed(String)
    }

    private static let log = Logger(subsystem: "app.mactivity.ui", category: "ask")

    public private(set) var question = ""
    public private(set) var answer = ""
    public private(set) var state = State.idle
    @ObservationIgnored private var task: Task<Void, Never>?

    public init() {}

    /// Apple Intelligence is on and its model is ready.
    public var isAvailable: Bool {
        Self.isModelAvailable
    }

    nonisolated static var isModelAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// Offered in Quick Search: turned on in Settings, and the model is there (D-161).
    public var isOffered: Bool {
        UserDefaults.standard.bool(forKey: PreferenceKey.askMactivity) && isAvailable
    }

    public func ask(_ question: String, services: AppServices) {
        task?.cancel()
        self.question = question
        answer = ""
        state = .answering
        let snapshot = services.metrics.snapshot
        let causes = snapshot.map { Slowdown.diagnose([$0], lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled) } ?? []
        var context = AskContext.describe(snapshot, causes: causes, now: Date())
        // What's out of the ordinary today (D-198), in a line the model can quote.
        if !services.unusual.found.isEmpty {
            context += "\nOut of the ordinary today, against each app's usual day: "
                + services.unusual.found.map { "\($0.app.name) \(UnusualText.english($0))" }.joined(separator: "; ") + "."
        }
        let history = services.history
        var tools: [any Tool] = []
        if let daily = history as? any DailyHistoryStore {
            tools.append(AppHistoryTool(store: daily))
        }
        // A day's story and agent history (D-199): "why was it slow yesterday", "what did my agents do".
        tools.append(DayTimelineTool(
            history: history, alerts: services.alertLog, crashes: services.crashReports, hasBattery: services.metrics.hardware.hasBattery
        ))
        if let agents = history as? any AgentHistoryStore {
            tools.append(AgentHistoryTool(store: agents))
        }
        task = Task { [weak self] in
            let session = LanguageModelSession(model: .default, tools: tools, instructions: Self.instructions)
            do {
                let stream = session.streamResponse(to: "The Mac now:\n\(context)\n\nQuestion: \(question)")
                for try await partial in stream {
                    guard !Task.isCancelled else {
                        return
                    }
                    self?.answer = partial.content
                }
                self?.state = .answered
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                Self.log.error("Ask failed: \(String(describing: error), privacy: .public)")
                self?.state = .failed(Self.message(for: error))
            }
        }
    }

    public func reset() {
        task?.cancel()
        task = nil
        question = ""
        answer = ""
        state = .idle
    }

    static let instructions = """
    You are the assistant inside Mactivity, a Mac system monitor, on the person's own Mac. Answer \
    questions about what the Mac is doing and has been doing, using only the figures given, the \
    appHistory tool for which apps used the most over a period, the dayTimeline tool for what happened \
    on a day (wakes, slowdowns and the apps behind them, charging, alerts, crashes, agent sessions), and \
    the agentHistory tool for coding agents' time per project. Be brief: two to four sentences. Name the apps involved. If \
    the figures don't answer the question, say so plainly instead of guessing. CPU percentages are \
    of the whole Mac. Mactivity's app list can quit an app after asking; suggest it when quitting \
    would help. Never suggest deleting files or running Terminal commands.
    """

    nonisolated static func message(for error: any Error) -> String {
        if let failure = error as? LanguageModelSession.GenerationError {
            switch failure {
            case .exceededContextWindowSize:
                return String(
                    localized: "That question needed more than the on-device model can take. Try a shorter one.",
                    bundle: .strings
                )
            case .guardrailViolation, .refusal:
                return String(localized: "The on-device model wouldn't answer that one.", bundle: .strings)
            default:
                break
            }
        }
        return String(localized: "Apple Intelligence couldn't answer just now. Try again in a moment.", bundle: .strings)
    }
}

/// History for the model: which apps used the most of a figure over a period.
struct AppHistoryTool: Tool {
    let store: any DailyHistoryStore

    let name = "appHistory"
    let description = "Which apps used the most CPU, memory, energy, disk or network over an earlier period, from Mactivity's history."

    @Generable
    struct Arguments {
        @Guide(description: "What to rank apps by", .anyOf(["cpu", "memory", "energy", "disk", "network"]))
        var figure: String
        @Guide(description: "The period", .anyOf(["last hour", "today", "yesterday", "last 7 days", "last 30 days"]))
        var period: String
    }

    func call(arguments: Arguments) async throws -> String {
        let (from, to) = Self.range(arguments.period, now: Date(), calendar: .autoupdatingCurrent)
        switch arguments.figure {
        case "disk", "network":
            let metrics: [Metric] = arguments.figure == "disk" ? [.diskRead, .diskWrite] : [.netIn, .netOut]
            let totals = try await store.totals(metrics: metrics, from: from, to: to, limit: 6)
            return Self.describe(totals, period: arguments.period, figure: arguments.figure) { Formatters.bytes($0) }
        default:
            let metric: Metric = switch arguments.figure {
            case "memory": .memory
            case "energy": .energyImpact
            default: .cpu
            }
            let top = try await store.topApps(metric: metric, from: from, to: to, limit: 6)
            return Self.describe(top, period: arguments.period, figure: arguments.figure) { value in
                switch metric {
                case .memory: Formatters.memory(value)
                case .cpu: Formatters.percent(value, fractionDigits: 1) + " CPU on average"
                default: "Energy Impact \(Int(value.rounded())) on average"
                }
            }
        }
    }

    nonisolated static func range(_ period: String, now: Date, calendar: Calendar) -> (Date, Date) {
        let today = calendar.startOfDay(for: now)
        switch period {
        case "last hour": return (now.addingTimeInterval(-3600), now)
        case "yesterday": return (calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86400), today)
        case "last 7 days": return (now.addingTimeInterval(-7 * 86400), now)
        case "last 30 days": return (now.addingTimeInterval(-30 * 86400), now)
        default: return (today, now)
        }
    }

    nonisolated static func describe(_ totals: [AppTotal], period: String, figure: String, format: (Double) -> String) -> String {
        guard !totals.isEmpty else {
            return "Mactivity has no \(figure) history for \(period)."
        }
        return "Top apps by \(figure), \(period): " + totals.map { "\($0.app.name) \(format($0.value))" }.joined(separator: "; ") + "."
    }
}

/// A day's events for the model (D-199): Your day, as plain English lines.
struct DayTimelineTool: Tool {
    let history: any HistoryStore
    let alerts: any AlertStateStore
    /// Crashes, as Your day shows them (D-219).
    let crashes: any CrashReportSource
    let hasBattery: Bool

    let name = "dayTimeline"
    let description = """
    What happened on this Mac on a day, in order: wakes and sleep, busy stretches and slowdowns with the apps \
    behind them, unplugging and charging, big downloads, alerts, crashes and coding-agent sessions.
    """

    @Generable
    struct Arguments {
        @Guide(
            description: "Which day",
            .anyOf(["today", "yesterday", "2 days ago", "3 days ago", "4 days ago", "5 days ago", "6 days ago"])
        )
        var day: String
    }

    func call(arguments: Arguments) async throws -> String {
        let back = arguments.day == "today" ? 0 : arguments.day == "yesterday" ? 1 : Int(arguments.day.prefix(1)) ?? 0
        let calendar = Calendar.autoupdatingCurrent
        let day = calendar.date(byAdding: .day, value: -back, to: Date()) ?? Date()
        let start = calendar.startOfDay(for: day)
        let crashed = await CrashFilter.relevant(crashes.reports(since: start))
        let result = await DayStoryReader.read(day: day, history: history, hasBattery: hasBattery, alerts: alerts, crashes: crashed)
        let label = day.formatted(.dateTime.weekday(.wide).month().day())
        let inUse = Duration.seconds(result.activeSeconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        guard !result.events.isEmpty else {
            return "\(label): \(inUse) in use; nothing notable recorded."
        }
        return "\(label), \(inUse) in use:\n" + result.englishLines().joined(separator: "\n")
    }
}

/// Coding agents' time per project for the model (D-199).
struct AgentHistoryTool: Tool {
    let store: any AgentHistoryStore

    let name = "agentHistory"
    let description = """
    How long each coding agent (Claude Code, Codex, Gemini CLI, Aider…) worked in each project, with its average CPU \
    and peak memory.
    """

    @Generable
    struct Arguments {
        @Guide(description: "The period", .anyOf(["today", "yesterday", "last 7 days", "last 30 days"]))
        var period: String
    }

    func call(arguments: Arguments) async throws -> String {
        let (from, to) = AppHistoryTool.range(arguments.period, now: Date(), calendar: .autoupdatingCurrent)
        let totals = try await AgentWeek.totals(store.agentUsage(from: from, to: to))
        guard !totals.isEmpty else {
            return "No coding-agent sessions recorded \(arguments.period)."
        }
        return "Coding agents, \(arguments.period): " + totals.prefix(8).map { total in
            let time = Duration.seconds(Double(total.minutes * 60)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
            let place = total.project.isEmpty ? "" : " in \(total.project)"
            return "\(total.agent)\(place) \(time), \(Formatters.percent(total.averageCPU, fractionDigits: 1)) CPU on average, "
                + "peak \(Formatters.memory(total.peakMemory))"
        }.joined(separator: "; ") + "."
    }
}
