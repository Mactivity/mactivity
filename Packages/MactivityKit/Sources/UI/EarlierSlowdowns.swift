import Core
import Foundation
import SwiftUI

/// A slowdown that has passed (D-169), with the apps that were busiest during it.
struct EarlierSlowdown: Hashable, Identifiable, Sendable {
    let spell: SlowSpell
    let apps: [AppIdentity]

    var id: Date {
        spell.start
    }

    static let days = 7
    static let limit = 4

    /// The last day by the minute and the six before it by the quarter-hour, most recent first.
    static func load(_ history: any HistoryStore, now: Date) async -> [EarlierSlowdown] {
        func recent(_ metric: Metric) async -> [SeriesPoint] {
            await (try? history.series(metric: metric, app: nil, range: .h24)) ?? []
        }
        let minutes = await SlowSpells.find(
            cpu: recent(.cpu), memoryPressure: recent(.memoryPressure), thermal: recent(.thermalPressure), bucket: 60
        )
        guard let daily = history as? any DailyHistoryStore else {
            return Array(minutes.reversed().prefix(limit)).map { EarlierSlowdown(spell: $0, apps: []) }
        }
        let from = now.addingTimeInterval(-Double(days) * 86400)
        let to = now.addingTimeInterval(-86400)
        func older(_ metric: Metric) async -> [SeriesPoint] {
            await (try? daily.series(metric: metric, app: nil, from: from, to: to)) ?? []
        }
        let quarters = await SlowSpells.find(
            cpu: older(.cpu), memoryPressure: older(.memoryPressure), thermal: older(.thermalPressure), bucket: 900
        )
        var result: [EarlierSlowdown] = []
        for spell in SlowSpells.recent(minutes: minutes, quarters: quarters, limit: limit) {
            let metric = spell.causes.first?.metric ?? .cpu
            let apps = await (try? daily.topApps(metric: metric, from: spell.start, to: spell.end, limit: 3)) ?? []
            result.append(EarlierSlowdown(spell: spell, apps: apps.map(\.app)))
        }
        return result
    }

    /// "Today, 2:10 – 2:45 PM", "Yesterday, …", "Tuesday, …".
    static func when(_ spell: SlowSpell, calendar: Calendar = .autoupdatingCurrent) -> String {
        let times = (spell.start ..< spell.end).formatted(.interval.hour().minute())
        if calendar.isDateInToday(spell.start) {
            return String(
                localized: "Today, \(times)",
                bundle: .strings,
                comment: "When a past slowdown happened, e.g. Today, 2:10 – 2:45 PM"
            )
        }
        if calendar.isDateInYesterday(spell.start) {
            return String(
                localized: "Yesterday, \(times)",
                bundle: .strings,
                comment: "When a past slowdown happened, e.g. Yesterday, 2:10 – 2:45 PM"
            )
        }
        let day = spell.start.formatted(.dateTime.weekday(.wide))
        return String(
            localized: "\(day), \(times)",
            bundle: .strings,
            comment: "When a past slowdown happened: weekday, then times, e.g. Tuesday, 2:10 – 2:45 PM"
        )
    }

    static func title(_ cause: SlowSpell.Cause) -> String {
        switch cause {
        case .cpu: String(localized: "Processor near full", bundle: .strings, comment: "A past slowdown: the whole Mac's CPU was over 80%")
        case .memory: String(localized: "Memory ran short", bundle: .strings, comment: "A past slowdown: memory pressure was high")
        case .heat: String(localized: "Slowed down to stay cool", bundle: .strings, comment: "A past slowdown: macOS throttled for heat")
        }
    }

    /// The other causes, for "Also: …".
    static func alsoPhrase(_ cause: SlowSpell.Cause) -> String {
        switch cause {
        case .cpu: String(localized: "processor near full", bundle: .strings, comment: "Listed after Also: in a past slowdown")
        case .memory: String(localized: "memory ran short", bundle: .strings, comment: "Listed after Also: in a past slowdown")
        case .heat: String(localized: "throttled for heat", bundle: .strings, comment: "Listed after Also: in a past slowdown")
        }
    }

    static func symbol(_ cause: SlowSpell.Cause) -> String {
        switch cause {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .heat: "thermometer.high"
        }
    }
}

/// The diagnosis sheet's "Slowdowns in the last 7 days": what History saw after the fact.
struct EarlierSlowdownsSection: View {
    let slowdowns: [EarlierSlowdown]
    /// Opens an app's history page.
    let showHistory: (AppIdentity) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                Text("Slowdowns in the last 7 days", bundle: .strings).font(Tokens.Typography.cardTitle)
                Text("Times your Mac struggled, from History, with the apps busiest then.", bundle: .strings)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
            ForEach(slowdowns) { row($0) }
        }
    }

    private func row(_ slowdown: EarlierSlowdown) -> some View {
        let spell = slowdown.spell
        let primary = spell.causes.first ?? .cpu
        return HStack(alignment: .top, spacing: Tokens.Spacing.s) {
            Image(systemName: EarlierSlowdown.symbol(primary))
                .foregroundStyle(.secondary)
                .frame(width: Tokens.IconSize.card)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                Text(EarlierSlowdown.title(primary)).font(Tokens.Typography.cardTitle)
                Text(verbatim: "\(EarlierSlowdown.when(spell)) · \(Formatters.duration(.seconds(spell.duration)))")
                    .foregroundStyle(.secondary)
                if spell.causes.count > 1 {
                    let others = spell.causes.dropFirst().map(EarlierSlowdown.alsoPhrase).formatted(.list(type: .and))
                    Text("Also: \(others)", bundle: .strings, comment: "A past slowdown's other causes, e.g. Also: memory ran short")
                        .foregroundStyle(.secondary)
                }
                if !slowdown.apps.isEmpty {
                    HStack(spacing: Tokens.Spacing.xs) {
                        ForEach(slowdown.apps) { app in
                            Button { showHistory(app) } label: {
                                HStack(spacing: Tokens.Spacing.xxs) {
                                    AppIconView(app, size: Tokens.IconSize.small)
                                    Text(app.name).lineLimit(1)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(Text(
                                "Show \(app.name)’s history",
                                bundle: .strings,
                                comment: "Tooltip on a top app: opens its history page"
                            ))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.Spacing.s)
        .background(.background.secondary, in: .rect(cornerRadius: Tokens.Radius.card))
    }
}
