import Foundation

/// The counts behind the summary line.
public struct StartupSummary: Hashable, Sendable {
    /// Items that start with the Mac (see `StartupItem.startsWithMac`).
    public let starting: Int
    /// Of those, the ones resolved to an app on this Mac.
    public let fromApps: Int
    public let broken: Int
    public let unusual: Int
    /// Listed but off, not registered, or unknown and not running.
    public let notStarting: Int
    public let macOS: Int

    public init(items: [StartupItem], macOSCount: Int) {
        let starting = items.filter(\.startsWithMac)
        self.starting = starting.count
        fromApps = starting.count(where: \.owner.isInstalled)
        broken = items.count(where: { $0.isBroken && $0.state != .disabledByMactivity })
        unusual = items.count(where: { $0.isUnusual && $0.state != .disabledByMactivity })
        notStarting = items.count - starting.count
        macOS = macOSCount
    }

    /// "14 things start with your Mac · 9 from apps you have · 2 broken · 1 unusual".
    public var line: String {
        var parts = [String(localized: "\(starting) things start with your Mac", bundle: .strings, comment: "Startup summary")]
        parts.append(String(localized: "\(fromApps) from apps you have", bundle: .strings, comment: "Startup summary: from installed apps"))
        if broken > 0 {
            parts.append(String(localized: "\(broken) broken", bundle: .strings, comment: "Startup summary: broken items"))
        }
        if unusual > 0 {
            parts.append(String(localized: "\(unusual) unusual", bundle: .strings, comment: "Startup summary: items in unusual locations"))
        }
        return parts.joined(separator: " · ")
    }

    /// "Plus 911 from macOS, not listed. 3 more are off or only start when their app turns them on."
    public var footnote: String {
        let text = String(
            localized: "Plus \(macOS) from macOS, not listed.",
            bundle: .strings,
            comment: "Startup footnote: system launch agents and daemons that aren't listed"
        )
        guard notStarting > 0 else {
            return text
        }
        let more = String(
            localized: "\(notStarting) more are off or start only when their app turns them on.",
            bundle: .strings,
            comment: "Startup footnote: listed items that don't start with the Mac"
        )
        return "\(text) \(more)"
    }
}

/// Owner groups, apps alphabetically and Unknown last; items by kind, then name.
public struct StartupGroup: Identifiable, Hashable, Sendable {
    public let owner: StartupOwner
    public let items: [StartupItem]

    public var id: String {
        owner.id
    }

    public static func grouped(_ items: [StartupItem]) -> [StartupGroup] {
        let byOwner = Dictionary(grouping: items, by: \.owner.id)
        let kindOrder = Dictionary(uniqueKeysWithValues: StartupKind.allCases.enumerated().map { ($1, $0) })
        return byOwner.values.compactMap { members -> StartupGroup? in
            guard let owner = members.first?.owner else {
                return nil
            }
            let sorted = members.sorted {
                let left = kindOrder[$0.kind] ?? 0
                let right = kindOrder[$1.kind] ?? 0
                if left != right {
                    return left < right
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return StartupGroup(owner: owner, items: sorted)
        }
        .sorted { lhs, rhs in
            if lhs.owner.isKnown != rhs.owner.isKnown {
                return lhs.owner.isKnown
            }
            return lhs.owner.name.localizedStandardCompare(rhs.owner.name) == .orderedAscending
        }
    }
}

/// Words for schedules and states.
public enum StartupText {
    /// launchd's hour and minute as the Mac shows times: "3:15 AM", or "03:15" with a 24-hour
    /// clock (D-221).
    public static func clock(hour: Int, minute: Int) -> String {
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour, minute: minute))
        return date?.formatted(date: .omitted, time: .shortened) ?? String(format: "%d:%02d", hour, minute)
    }

    /// "At login", "At startup", "Always running", "Every 1h", "Daily at 3:15", "On demand".
    public static func schedule(_ schedule: StartupSchedule, kind: StartupKind) -> String {
        let daemon = kind == .daemon
        switch schedule {
        case .atLoad:
            return daemon
                ? String(localized: "At startup", bundle: .strings, comment: "Startup schedule: a daemon runs when the Mac starts")
                : String(localized: "At login", bundle: .strings, comment: "Startup schedule: an agent runs when the user logs in")
        case let .alwaysRunning(conditional):
            return conditional
                ? String(localized: "Kept running", bundle: .strings, comment: "Startup schedule: launchd restarts it under conditions")
                : String(localized: "Always running", bundle: .strings, comment: "Startup schedule: launchd restarts it whenever it exits")
        case let .interval(seconds, runsAtLoad):
            let every = interval(seconds)
            guard runsAtLoad else {
                return String(localized: "Every \(every)", bundle: .strings, comment: "Startup schedule: runs every interval, like 1h 30m")
            }
            return daemon
                ? String(localized: "At startup, then every \(every)", bundle: .strings, comment: "Startup schedule; interval like 1h 30m")
                : String(localized: "At login, then every \(every)", bundle: .strings, comment: "Startup schedule; interval like 1h 30m")
        case let .calendar(entries, runsAtLoad):
            guard runsAtLoad else {
                return calendar(entries)
            }
            let text = calendar(entries, continuing: true)
            return daemon
                ? String(
                    localized: "At startup, then \(text)",
                    bundle: .strings,
                    comment: "Startup schedule; the argument is a calendar schedule like “monthly on day 1”"
                )
                : String(
                    localized: "At login, then \(text)",
                    bundle: .strings,
                    comment: "Startup schedule; the argument is a calendar schedule like “monthly on day 1”"
                )
        case .onDemand:
            return String(localized: "On demand", bundle: .strings, comment: "Startup schedule: launched only when something asks for it")
        }
    }

    /// "45s", "30m", "1h", "1h 30m", "1d". Whole units, no rounding surprises.
    public static func interval(_ seconds: Int) -> String {
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        let rest = seconds % 60
        var parts: [String] = []
        if days > 0 {
            parts.append(String(localized: "\(days)d", bundle: .strings, comment: "Interval part: days, abbreviated"))
        }
        if hours > 0 {
            parts.append(String(localized: "\(hours)h", bundle: .strings, comment: "Interval part: hours, abbreviated"))
        }
        if minutes > 0 {
            parts.append(String(localized: "\(minutes)m", bundle: .strings, comment: "Interval part: minutes, abbreviated"))
        }
        if rest > 0 || parts.isEmpty {
            parts.append(String(localized: "\(rest)s", bundle: .strings, comment: "Interval part: seconds, abbreviated"))
        }
        return parts.joined(separator: " ")
    }

    /// Weekday and month names in the language the strings are shown in, from the Gregorian
    /// calendar launchd uses. Sunday first, January first.
    private static let calendarSymbols: (weekdays: [String], months: [String]) = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: Bundle.strings.preferredLocalizations.first ?? "en")
        return (calendar.weekdaySymbols, calendar.standaloneMonthSymbols)
    }()

    /// One entry in words; several become "3 times a day" style counts.
    public static func calendar(_ entries: [CalendarInterval]) -> String {
        calendar(entries, continuing: false)
    }

    /// - Parameter continuing: the form that follows "At login, then …" (lowercase in English).
    static func calendar(_ entries: [CalendarInterval], continuing: Bool) -> String {
        guard let entry = entries.first else {
            return continuing
                ? String(localized: "on a schedule", bundle: .strings, comment: "Follows “At login, then”")
                : String(localized: "On a schedule", bundle: .strings, comment: "Startup schedule")
        }
        if entries.count > 1 {
            let count = entries.count
            return continuing
                ? String(localized: "on a schedule (\(count) times)", bundle: .strings, comment: "Follows “At login, then”")
                : String(localized: "On a schedule (\(count) times)", bundle: .strings, comment: "Startup schedule")
        }
        guard let base = calendarBase(entry, continuing: continuing) else {
            if let minute = entry.minute {
                let padded = String(format: "%02d", minute)
                return continuing
                    ? String(localized: "hourly at :\(padded)", bundle: .strings, comment: "Follows “At login, then”; minute like 05")
                    : String(localized: "Hourly at :\(padded)", bundle: .strings, comment: "Startup schedule; minute like 05")
            }
            return continuing
                ? String(localized: "every minute", bundle: .strings, comment: "Follows “At login, then”")
                : String(localized: "Every minute", bundle: .strings, comment: "Startup schedule")
        }
        switch (entry.hour, entry.minute) {
        case let (hour?, minute?):
            let time = clock(hour: hour, minute: minute)
            return String(localized: "\(base) at \(time)", bundle: .strings, comment: "Calendar schedule, then a time: “Daily at 3:15”")
        case let (hour?, nil):
            let time = clock(hour: hour, minute: 0)
            return String(
                localized: "\(base), every minute of \(time)",
                bundle: .strings,
                comment: "Calendar schedule, then an hour it runs every minute of: “Daily, every minute of 4:00”"
            )
        case let (nil, minute?):
            let padded = String(format: "%02d", minute)
            return String(
                localized: "\(base), every hour at :\(padded)",
                bundle: .strings,
                comment: "Calendar schedule, then a minute past each hour: “Monthly on day 1, every hour at :05”"
            )
        case (nil, nil):
            return base
        }
    }

    /// "Yearly in March on day 3", "Monthly on day 1", "Weekly on Sunday", "Daily", or nil when
    /// the entry names no day, weekday, month, or hour.
    private static func calendarBase(_ entry: CalendarInterval, continuing: Bool) -> String? {
        if let month = entry.month, (1 ... 12).contains(month) {
            let name = calendarSymbols.months[month - 1]
            if let day = entry.day {
                return continuing
                    ? String(localized: "yearly in \(name) on day \(day)", bundle: .strings, comment: "Follows “At login, then”; month")
                    : String(localized: "Yearly in \(name) on day \(day)", bundle: .strings, comment: "Startup schedule; month")
            }
            return continuing
                ? String(localized: "yearly in \(name)", bundle: .strings, comment: "Follows “At login, then”; month name")
                : String(localized: "Yearly in \(name)", bundle: .strings, comment: "Startup schedule; month name")
        }
        if let day = entry.day {
            return continuing
                ? String(localized: "monthly on day \(day)", bundle: .strings, comment: "Follows “At login, then”; day of the month")
                : String(localized: "Monthly on day \(day)", bundle: .strings, comment: "Startup schedule; day of the month")
        }
        if let weekday = entry.weekday {
            let name = calendarSymbols.weekdays[((weekday % 7) + 7) % 7]
            return continuing
                ? String(localized: "weekly on \(name)", bundle: .strings, comment: "Follows “At login, then”; weekday name")
                : String(localized: "Weekly on \(name)", bundle: .strings, comment: "Startup schedule; weekday name")
        }
        if entry.hour != nil {
            return continuing
                ? String(localized: "daily", bundle: .strings, comment: "Follows “At login, then”")
                : String(localized: "Daily", bundle: .strings, comment: "Startup schedule")
        }
        return nil
    }

    /// "Running", "Not running", or nil when it can't be told.
    public static func running(_ item: StartupItem) -> String {
        switch item.isRunning {
        case true?: String(localized: "Running", bundle: .strings, comment: "Startup item's process is running")
        case false?: String(localized: "Not running", bundle: .strings, comment: "Startup item's process isn't running")
        case nil: "—"
        }
    }
}
