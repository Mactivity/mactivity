import Foundation

// Agent history (D-192): coding-agent sessions over time, by agent and project, a quarter-hour
// at a time. Sampled once a minute, with or without a window open: one
// process-table read a minute.

/// One agent's work in one project during one quarter-hour.
public struct AgentUsage: Hashable, Sendable {
    /// The quarter-hour's start.
    public let start: Date
    /// "Claude Code", "Codex"…
    public let agent: String
    /// The project folder's name; empty when the session's folder wasn't known.
    public let project: String
    /// Minutes in the quarter-hour that any session of it was running.
    public var minutes: Int
    /// Each of those minutes' processor use, as a share of the whole Mac, added up.
    public var cpuTotal: Double
    /// The most memory its sessions held together at any one minute.
    public var peakMemory: UInt64

    public init(start: Date, agent: String, project: String, minutes: Int, cpuTotal: Double, peakMemory: UInt64) {
        self.start = start
        self.agent = agent
        self.project = project
        self.minutes = minutes
        self.cpuTotal = cpuTotal
        self.peakMemory = peakMemory
    }

    /// Average processor share over the minutes it ran.
    public var averageCPU: Double {
        minutes > 0 ? cpuTotal / Double(minutes) : 0
    }
}

public protocol AgentHistoryStore: Sendable {
    /// Writes each row, replacing one already there for the same quarter-hour, agent and project:
    /// the current quarter-hour is written again every minute as it fills.
    func recordAgentUsage(_ rows: [AgentUsage]) async throws
    /// Rows whose quarter-hour starts in the span, oldest first.
    func agentUsage(from: Date, to: Date) async throws -> [AgentUsage]
}

/// Turns a minute's running sessions into the current quarter-hour's rows. Pure.
public struct AgentUsageAccumulator: Sendable {
    private struct Key: Hashable {
        let agent: String
        let project: String
    }

    private var quarter: Date?
    private var lastMinute: Date?
    private var rows: [Key: AgentUsage] = [:]

    public init() {}

    /// Whether `date` is in a minute not yet added: ask before reading the sessions, so they're
    /// read once a minute, not every snapshot.
    public func isNewMinute(_ date: Date) -> Bool {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60) != lastMinute
    }

    /// Starts from rows already written for `date`'s quarter-hour (D-219): after a relaunch the
    /// quarter's first minutes stay counted rather than being written over from zero.
    public mutating func seed(_ stored: [AgentUsage], at date: Date) {
        let start = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 900).rounded(.down) * 900)
        quarter = start
        rows = [:]
        for row in stored where row.start == start {
            rows[Key(agent: row.agent, project: row.project)] = row
        }
    }

    /// Adds `sessions` as one minute at `date`; a second call in the same minute is ignored.
    /// Returns the quarter-hour's rows so far, to write, or none when no agent ran this minute.
    public mutating func add(_ sessions: [AgentSession], at date: Date) -> [AgentUsage] {
        let minute = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
        guard minute != lastMinute else {
            return []
        }
        lastMinute = minute
        let start = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 900).rounded(.down) * 900)
        if start != quarter {
            quarter = start
            rows = [:]
        }
        guard !sessions.isEmpty else {
            return []
        }
        // Two sessions of one agent in one project are one row: their minute counts once, their
        // processor and memory add up.
        let grouped = Dictionary(grouping: sessions) { Key(agent: $0.agent, project: $0.project ?? "") }
        for (key, group) in grouped {
            var row = rows[key] ?? AgentUsage(start: start, agent: key.agent, project: key.project, minutes: 0, cpuTotal: 0, peakMemory: 0)
            row.minutes += 1
            row.cpuTotal += group.reduce(0) { $0 + $1.cpuPercent }
            row.peakMemory = max(row.peakMemory, group.reduce(0) { $0 + $1.memoryBytes })
            rows[key] = row
        }
        return rows.values.sorted { ($0.agent, $0.project) < ($1.agent, $1.project) }
    }
}

/// Summaries of agent history for the Agents page and Your day.
public enum AgentWeek {
    public struct Total: Hashable, Sendable, Identifiable {
        public let agent: String
        public let project: String
        public let minutes: Int
        public let cpuTotal: Double
        public let peakMemory: UInt64
        /// Calendar days it ran on.
        public let days: Int

        public init(agent: String, project: String, minutes: Int, cpuTotal: Double, peakMemory: UInt64, days: Int) {
            self.agent = agent
            self.project = project
            self.minutes = minutes
            self.cpuTotal = cpuTotal
            self.peakMemory = peakMemory
            self.days = days
        }

        public var id: String {
            agent + "\u{1F}" + project
        }

        public var averageCPU: Double {
            minutes > 0 ? cpuTotal / Double(minutes) : 0
        }
    }

    /// One stretch of an agent working in a project: back-to-back quarter-hours.
    public struct Stretch: Hashable, Sendable {
        public let agent: String
        public let project: String
        public let start: Date
        public let end: Date
        public let minutes: Int
    }

    /// By agent and project, most time first.
    public static func totals(_ rows: [AgentUsage], calendar: Calendar = .current) -> [Total] {
        Dictionary(grouping: rows) { $0.agent + "\u{1F}" + $0.project }.values.compactMap { group -> Total? in
            guard let first = group.first else {
                return nil
            }
            return Total(
                agent: first.agent, project: first.project,
                minutes: group.reduce(0) { $0 + $1.minutes },
                cpuTotal: group.reduce(0) { $0 + $1.cpuTotal },
                peakMemory: group.map(\.peakMemory).max() ?? 0,
                days: Set(group.map { calendar.startOfDay(for: $0.start) }).count
            )
        }
        .sorted { ($0.minutes, $1.agent, $1.project) > ($1.minutes, $0.agent, $0.project) }
    }

    /// Time any agent ran on each day, every agent's minutes counted once per quarter-hour at most
    /// fifteen: two agents side by side are still fifteen minutes of agent time.
    public static func byDay(_ rows: [AgentUsage], days: [DateInterval]) -> [DayTotal] {
        let quarters = Dictionary(grouping: rows, by: \.start).mapValues { min(15, $0.map(\.minutes).max() ?? 0) }
        return days.map { day in
            let minutes = quarters.filter { day.contains($0.key) && $0.key < day.end }.values.reduce(0, +)
            return DayTotal(day: day.start, seconds: Double(minutes * 60))
        }
    }

    /// Each agent's stretches in each project: quarter-hours back to back, oldest first.
    public static func stretches(_ rows: [AgentUsage]) -> [Stretch] {
        var result: [Stretch] = []
        let grouped = Dictionary(grouping: rows) { $0.agent + "\u{1F}" + $0.project }
        for group in grouped.values {
            let sorted = group.sorted { $0.start < $1.start }
            var current: (start: Date, end: Date, minutes: Int)?
            for row in sorted {
                let end = row.start.addingTimeInterval(900)
                if let open = current, open.end >= row.start {
                    current = (open.start, end, open.minutes + row.minutes)
                } else {
                    if let open = current {
                        result.append(Stretch(
                            agent: row.agent,
                            project: row.project,
                            start: open.start,
                            end: open.end,
                            minutes: open.minutes
                        ))
                    }
                    current = (row.start, end, row.minutes)
                }
            }
            if let open = current, let row = sorted.last {
                result.append(Stretch(agent: row.agent, project: row.project, start: open.start, end: open.end, minutes: open.minutes))
            }
        }
        return result.sorted { ($0.start, $0.agent) < ($1.start, $1.agent) }
    }
}
