import Core
import SwiftUI

/// Overview's Today so far (D-194): the day's events on a 24-hour ribbon, a line of what they
/// add up to, and the way into Your day. From History, like Your day; reloaded every five
/// minutes while Overview shows.
struct TodayCard: View {
    let services: AppServices
    /// The menu bar window's: no button and no counts, the time in use and the ribbon; the whole
    /// card opens Your day.
    var compact = false
    @State private var result: DayStoryResult?
    @State private var dayStart = Calendar.current.startOfDay(for: Date())

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
                Label {
                    Text("Today so far", bundle: .strings, comment: "Overview: the day's events up to now")
                } icon: {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(TodayRibbon.tint)
                }
                .font(Tokens.Typography.cardTitle)
                if let result {
                    Text(compact ? inUse(result) : summary(result))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Tokens.Spacing.s)
                if !compact {
                    Button(String(localized: "Your Day", bundle: .strings, comment: "Overview: opens today's timeline on History")) {
                        services.navigation.showDay(Date())
                    }
                    .fixedSize()
                }
            }
            TodayRibbon(events: result?.events ?? [], dayStart: dayStart)
                .frame(height: compact ? Tokens.Layout.todayRibbonCompactHeight : Tokens.Layout.todayRibbonHeight)
                .accessibilityElement()
                .accessibilityLabel(Text("Today so far", bundle: .strings, comment: "Overview: the day's events up to now"))
                .accessibilityValue(result.map(spoken) ?? "")
        }
        .cardStyle()
        .contentShape(.rect)
        .onTapGesture { services.navigation.showDay(Date()) }
        .accessibilityAddTraits(compact ? .isButton : [])
        .accessibilityHint(compact ? Text(
            "Opens Your day on History",
            bundle: .strings,
            comment: "Menu bar window: what the Today card does"
        ) : Text(verbatim: ""))
        .task(id: services.historyGeneration) {
            while !Task.isCancelled {
                dayStart = Calendar.current.startOfDay(for: Date())
                result = await DayStoryLoader.load(services, day: Date())
                try? await Task.sleep(for: .seconds(300), tolerance: .seconds(30))
            }
        }
    }

    private func inUse(_ result: DayStoryResult) -> String {
        result.activeSeconds >= 60
            ? String(
                localized: "\(YourWeekContent.hours(result.activeSeconds)) in use",
                bundle: .strings,
                comment: "Your day: time in use, e.g. 5h 12m in use"
            )
            : ""
    }

    /// "2h 22m in use · Slowdowns: 1 · Alerts: 3 · Agents: 2h 10m".
    private func summary(_ result: DayStoryResult) -> String {
        var parts: [String] = []
        if result.activeSeconds >= 60 {
            parts.append(String(
                localized: "\(YourWeekContent.hours(result.activeSeconds)) in use",
                bundle: .strings,
                comment: "Your day: time in use, e.g. 5h 12m in use"
            ))
        }
        let slowdowns = result.events.count {
            if case .slowdown = $0.kind {
                true
            } else {
                false
            }
        }
        if slowdowns > 0 {
            parts.append(String(localized: "Slowdowns: \(slowdowns)", bundle: .strings, comment: "Today so far: how many slowdowns"))
        }
        let alerts = result.events.reduce(0) {
            if case let .alert(_, _, count) = $1.kind {
                $0 + count
            } else {
                $0
            }
        }
        if alerts > 0 {
            parts.append(String(localized: "Alerts: \(alerts)", bundle: .strings, comment: "Today so far: how many alerts fired"))
        }
        let agentSeconds = result.agentSeconds
        if agentSeconds >= 60 {
            parts.append(String(
                localized: "Agents: \(YourWeekContent.hours(agentSeconds))",
                bundle: .strings,
                comment: "Today so far: coding-agent time"
            ))
        }
        return parts.joined(separator: " · ")
    }

    /// For VoiceOver: the summary, then each event in order.
    private func spoken(_ result: DayStoryResult) -> String {
        ([summary(result)] + result.events.map { event in
            "\(event.start.formatted(date: .omitted, time: .shortened)): \(DayEventText.title(event))"
        })
        .filter { !$0.isEmpty }
        .joined(separator: ". ")
    }
}

/// The day as a track from midnight to midnight: stretches as bars, moments as dots, now as a line.
struct TodayRibbon: View {
    static let tint = Tokens.SidebarTint.history
    let events: [DayEvent]
    let dayStart: Date

    var body: some View {
        Canvas { context, size in
            let trackHeight: CGFloat = 8
            let labelHeight: CGFloat = 14
            let midY = (size.height - labelHeight) / 2
            // 23 or 25 hours on a daylight-saving day (D-219).
            let dayLength = (Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400))
                .timeIntervalSince(dayStart)
            func x(_ date: Date) -> CGFloat {
                CGFloat(min(1, max(0, date.timeIntervalSince(dayStart) / dayLength))) * size.width
            }
            let track = CGRect(x: 0, y: midY - trackHeight / 2, width: size.width, height: trackHeight)
            context.fill(Path(roundedRect: track, cornerRadius: trackHeight / 2), with: .color(.primary.opacity(0.08)))
            // Stretches first, so moments sit on top of them.
            for event in events {
                guard let end = event.end else {
                    continue
                }
                let rect = CGRect(x: x(event.start), y: midY - trackHeight / 2, width: max(3, x(end) - x(event.start)), height: trackHeight)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: trackHeight / 2),
                    with: .color(DayEventText.tint(event.kind).opacity(0.85))
                )
            }
            for event in events where event.end == nil {
                let center = CGPoint(x: x(event.start), y: midY)
                let dot = Path(ellipseIn: CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9))
                context.fill(dot, with: .color(DayEventText.tint(event.kind)))
                context.stroke(dot, with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 1.5)
            }
            // Now.
            let now = x(Date())
            context.stroke(
                Path { $0.move(to: CGPoint(x: now, y: midY - 9)); $0.addLine(to: CGPoint(x: now, y: midY + 9)) },
                with: .color(.primary.opacity(0.6)), lineWidth: 1.5
            )
            for hour in [0, 6, 12, 18] {
                let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: dayStart) ?? dayStart
                let label = Text(date.formatted(.dateTime.hour())).font(Tokens.Typography.caption).foregroundStyle(.secondary)
                context.draw(label, at: CGPoint(x: x(date) + (hour == 0 ? 0 : 0), y: size.height - labelHeight / 2), anchor: .leading)
            }
        }
    }
}
