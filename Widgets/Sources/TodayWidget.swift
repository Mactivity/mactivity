import Readouts
import SwiftUI
import WidgetKit

/// Today so far on the desktop (D-200): the day's events on a midnight-to-midnight ribbon, as
/// Overview shows it, from the file the app writes every 15 minutes.
struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.todayWidgetKind, provider: SystemWidgetProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Today so far")
        .description("Your day on one line: busy stretches, slowdowns, agents, charging and alerts.")
        .supportedFamilies([.systemMedium])
    }
}

struct TodayWidgetView: View {
    let entry: SystemEntry

    var body: some View {
        switch entry.state {
        case let .figures(snapshot):
            if let today = snapshot.today {
                content(today)
            } else {
                OpenAppView(detail: "Your day appears after Mactivity has read it, within 15 minutes.")
            }
        case .needsSignedBuild:
            OpenAppView(detail: "Widgets need a signed build of Mactivity.")
        case .openApp:
            OpenAppView(detail: "Figures appear while Mactivity is running.")
        }
    }

    private func content(_ today: WidgetSnapshot.Today) -> some View {
        VStack(alignment: .leading, spacing: WidgetStyle.small) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today so far").font(WidgetStyle.label)
                Spacer()
                if today.activeSeconds >= 60 {
                    let inUse = Duration.seconds(today.activeSeconds).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
                    Text("\(inUse) in use").font(WidgetStyle.detail).foregroundStyle(.secondary)
                }
                // Opens History on today (1.6), through the controls' link.
                if let link = try? ControlsFile.link(.yourDay) {
                    Link(destination: link) {
                        Label("Your Day", systemImage: "arrow.up.forward.app")
                            .labelStyle(.iconOnly)
                            .font(WidgetStyle.detail)
                    }
                    .help("Your Day")
                }
            }
            TodayWidgetRibbon(today: today, now: entry.date)
            Text(summary(today))
                .font(WidgetStyle.detail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// "Slowdowns: 1 · Alerts: 3 · Agents: 2h 10m", or what was quiet.
    private func summary(_ today: WidgetSnapshot.Today) -> String {
        let slowdowns = today.marks.count { $0.kind == "slowdown" }
        // As Overview counts them (D-219); the marks only for files from before.
        let alerts = today.alertCount ?? today.marks.count { $0.kind == "alert" }
        let agentSeconds = today.agentSeconds ?? today.marks.filter { $0.kind == "agent" }.reduce(0.0) { total, mark in
            total + (mark.end.map { $0.timeIntervalSince(mark.start) } ?? 0)
        }
        var parts: [String] = []
        if slowdowns > 0 {
            parts.append(String(localized: "Slowdowns: \(slowdowns)"))
        }
        if alerts > 0 {
            parts.append(String(localized: "Alerts: \(alerts)"))
        }
        if agentSeconds >= 60 {
            let time = Duration.seconds(agentSeconds).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
            parts.append(String(localized: "Agents: \(time)"))
        }
        return parts.isEmpty ? String(localized: "A quiet day so far") : parts.joined(separator: " · ")
    }
}

/// The ribbon, drawn as Overview draws it (TodayRibbon in the app), by the event kinds' codes.
struct TodayWidgetRibbon: View {
    let today: WidgetSnapshot.Today
    let now: Date

    static func color(_ kind: String) -> Color {
        switch kind {
        case "wake": .orange
        case "sleep": .indigo
        case "busy": .blue
        case "slowdown", "crash": .red
        case "unplugged", "plugged_in": .green
        case "download": .cyan
        case "alert": .yellow
        case "agent": .orange
        case "note": .purple
        case "sensor": .green
        default: .gray
        }
    }

    var body: some View {
        Canvas { context, size in
            let track: CGFloat = 8
            let labels: CGFloat = 13
            let midY = (size.height - labels) / 2
            // 23 or 25 hours on a daylight-saving day (D-219).
            let dayLength = (Calendar.current.date(byAdding: .day, value: 1, to: today.dayStart) ?? today.dayStart
                .addingTimeInterval(86400)).timeIntervalSince(today.dayStart)
            func x(_ date: Date) -> CGFloat {
                CGFloat(min(1, max(0, date.timeIntervalSince(today.dayStart) / dayLength))) * size.width
            }
            context.fill(
                Path(roundedRect: CGRect(x: 0, y: midY - track / 2, width: size.width, height: track), cornerRadius: track / 2),
                with: .color(.primary.opacity(0.1))
            )
            for mark in today.marks {
                guard let end = mark.end else {
                    continue
                }
                let rect = CGRect(x: x(mark.start), y: midY - track / 2, width: max(3, x(end) - x(mark.start)), height: track)
                context.fill(Path(roundedRect: rect, cornerRadius: track / 2), with: .color(Self.color(mark.kind).opacity(0.85)))
            }
            for mark in today.marks where mark.end == nil {
                let center = CGPoint(x: x(mark.start), y: midY)
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)),
                    with: .color(Self.color(mark.kind))
                )
            }
            let line = x(now)
            context.stroke(
                Path { $0.move(to: CGPoint(x: line, y: midY - 8)); $0.addLine(to: CGPoint(x: line, y: midY + 8)) },
                with: .color(.primary.opacity(0.6)), lineWidth: 1.5
            )
            for hour in [0, 6, 12, 18] {
                let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: today.dayStart) ?? today.dayStart
                let label = Text(date.formatted(.dateTime.hour())).font(.caption2).foregroundStyle(.secondary)
                context.draw(label, at: CGPoint(x: x(date), y: size.height - labels / 2), anchor: .leading)
            }
        }
        .frame(maxHeight: .infinity)
    }
}
