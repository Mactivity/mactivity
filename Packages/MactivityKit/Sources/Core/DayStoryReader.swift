import Foundation

/// A day's story and what goes with it: the apps behind each stretch, and time in use.
public struct DayStoryResult: Sendable {
    public let events: [DayEvent]
    /// The apps behind each busy stretch and slowdown, by event ID.
    public let apps: [String: [AppIdentity]]
    public let activeSeconds: Double
    /// Agents' time, overlapping sessions counted once and in their real minutes, as the Agents
    /// tab counts it (D-219). Adding up the timeline's agent stretches would count two projects
    /// at once twice and round each up to a quarter-hour.
    public let agentSeconds: Double

    public init(events: [DayEvent], apps: [String: [AppIdentity]], activeSeconds: Double, agentSeconds: Double = 0) {
        self.events = events
        self.apps = apps
        self.activeSeconds = activeSeconds
        self.agentSeconds = agentSeconds
    }
}

/// Reads one calendar day from History into a `DayStoryResult` (D-191), for the app and for the
/// `mactivity` command (D-193). Each store is optional: whatever the history offers is used.
public enum DayStoryReader {
    public static func read(
        day: Date, now: Date = Date(), history: any HistoryStore, hasBattery: Bool,
        alerts: (any AlertStateStore)?, crashes: [CrashReport] = [], calendar: Calendar = .current
    ) async -> DayStoryResult {
        let start = calendar.startOfDay(for: day)
        let end = min(calendar.date(byAdding: .day, value: 1, to: start) ?? now, now)
        guard let daily = history as? any DailyHistoryStore, end > start else {
            return DayStoryResult(events: [], apps: [:], activeSeconds: 0)
        }
        func series(_ metric: Metric) async -> [SeriesPoint] {
            await (try? daily.series(metric: metric, app: nil, from: start, to: end)) ?? []
        }
        let cpu = await series(.cpu)
        // The tier History read: minutes for a recent day, quarter-hours or hours further back.
        let gaps = zip(cpu, cpu.dropFirst()).map { $1.at.timeIntervalSince($0.at) }.filter { $0 > 0 }
        var inputs = DayStoryInputs(day: DateInterval(start: start, end: end), bucket: gaps.min() ?? 900)
        inputs.cpu = cpu
        inputs.memoryPressure = await series(.memoryPressure)
        inputs.thermal = await series(.thermalPressure)
        inputs.netIn = await series(.netIn)
        if hasBattery {
            inputs.onBattery = await series(.onBattery)
            inputs.batteryLevel = await series(.batteryLevel)
        }
        let daysBack = max(1, Int(now.timeIntervalSince(start) / 86400) + 1)
        inputs.power = await (try? (history as? any PowerEventStore)?.powerEvents(days: daysBack)) ?? []
        inputs.alerts = await (try? alerts?.recentAlerts(limit: 2000)) ?? []
        inputs.crashes = crashes
        inputs.agents = await (try? (history as? any AgentHistoryStore)?.agentUsage(from: start, to: end)) ?? []
        inputs.networkChanges = await (try? (history as? any NetworkHistoryStore)?.networkChanges(from: start, to: end)) ?? []
        inputs.notes = await (try? (history as? any NoteStore)?.notes(from: start, to: end)) ?? []
        inputs.sensorChanges = await (try? (history as? any SensorHistoryStore)?.sensorChanges(from: start, to: end)) ?? []
        let events = DayStory.events(inputs)
        var apps: [String: [AppIdentity]] = [:]
        for event in events {
            guard let metric = event.appMetric, let until = event.end else {
                continue
            }
            let top = await (try? daily.topApps(metric: metric, from: event.start, to: until, limit: 3)) ?? []
            apps[event.id] = top.filter { $0.app.kind != .system }.map(\.app)
        }
        let active = await (try? (history as? any FocusStore)?.activeSeconds(from: start, to: end)) ?? 0
        let agentSeconds = AgentWeek.byDay(inputs.agents, days: [DateInterval(start: start, end: max(start, end))]).first?.seconds ?? 0
        return DayStoryResult(events: events, apps: apps, activeSeconds: active, agentSeconds: agentSeconds)
    }
}
