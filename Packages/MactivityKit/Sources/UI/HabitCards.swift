import Charts
import Core
import SwiftUI

/// History → Focus streaks (D-271): each day's longest stretches in one app, and the apps that
/// ended the ones worth counting.
struct FocusStreaksCard: View {
    nonisolated static let days = 7

    let store: any FocusStore
    let generation: Int
    @State private var report: FocusStreaks.Report?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            if let report {
                if report.days.isEmpty {
                    Text("Mactivity notes which app is in front while you use your Mac. Nothing yet.", bundle: .strings)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                } else {
                    Text(
                        "Last 7 days. Up to 30 seconds in another app doesn't end a streak; longer does, or stepping away.",
                        bundle: .strings,
                        comment: "Focus streaks: what the list covers and what counts"
                    )
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    days(report.days)
                    breakers(report.breakers)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .task(id: generation) {
            report = await Self.load(store)
        }
    }

    private func days(_ days: [FocusStreaks.Day]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Tokens.Spacing.s, verticalSpacing: Tokens.Spacing.xs) {
            ForEach(days, id: \.day) { day in
                if let longest = day.longest.first {
                    GridRow {
                        Text(day.day.formatted(.dateTime.weekday(.abbreviated).day()))
                            .font(Tokens.Typography.secondary)
                            .foregroundStyle(.secondary)
                        HStack(spacing: Tokens.Spacing.xs) {
                            AppIconView(longest.app, size: Tokens.IconSize.small)
                            Text(longest.app.name).lineLimit(1)
                        }
                        Text(Self.duration(longest.seconds))
                            .monospacedDigit()
                            .gridColumnAlignment(.trailing)
                        Text(Self.others(longest, then: Array(day.longest.dropFirst())))
                            .font(Tokens.Typography.secondary)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    @ViewBuilder private func breakers(_ breakers: [FocusStreaks.Breaker]) -> some View {
        if !breakers.isEmpty {
            Divider()
            Text("What broke up streaks of 5 minutes or more, and how many times", bundle: .strings, comment: "Focus streaks")
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
            FlowLayout(spacing: Tokens.Spacing.s) {
                ForEach(breakers, id: \.app.id) { breaker in
                    HStack(spacing: Tokens.Spacing.xxs) {
                        AppIconView(breaker.app, size: Tokens.IconSize.small)
                        Text(breaker.app.name).lineLimit(1)
                        Text(breaker.count.formatted())
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// When the longest ran, then the day's next longest.
    nonisolated static func others(_ longest: FocusStreak, then: [FocusStreak]) -> String {
        let when = (longest.start ..< longest.end).formatted(.interval.hour().minute())
        let rest = then.map { "\($0.app.name) \(duration($0.seconds))" }.formatted(.list(type: .and, width: .narrow))
        return rest.isEmpty ? when : "\(when) · \(rest)"
    }

    /// Under a minute in seconds: "1m" for a look of 6 s would overstate it.
    nonisolated static func duration(_ seconds: Double) -> String {
        guard seconds < 60 else {
            return TimeInFrontCard.duration(seconds)
        }
        return Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.seconds], width: .narrow))
    }

    /// From the start of the day six days ago: seven whole days, today so far the last.
    nonisolated static func load(_ store: any FocusStore, now: Date = Date()) async -> FocusStreaks.Report {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)) ?? now
        let rows = await (try? store.focusStretches(from: start, to: now)) ?? []
        return FocusStreaks.report(rows, calendar: calendar)
    }
}

/// History → Busiest hours (D-272): each day of the week by the hour, darker when busier. A square
/// with no samples stays blank: the Mac was off or asleep, which isn't idle.
struct BusiestHoursCard: View {
    let store: any HourRhythmStore
    let generation: Int
    @State private var hours: BusiestHours?
    @State private var hovered: BusiestHours.Cell?
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            if let hours {
                if hours.cells.isEmpty {
                    Text("Mactivity fills this in as it records each hour. Nothing yet.", bundle: .strings)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                } else {
                    summary(hours)
                    chart(hours)
                    Text(
                        """
                        Processor use, last 12 weeks. A blank square has no samples: your Mac was off or asleep, \
                        and that doesn't count as idle.
                        """,
                        bundle: .strings,
                        comment: "Busiest hours: what the grid shows"
                    )
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .task(id: generation) {
            hours = await Self.load(store)
        }
    }

    /// While the pointer's over a square, that square; otherwise the week's two extremes.
    private func summary(_ hours: BusiestHours) -> some View {
        Group {
            if let hovered {
                Text(Self.cellText(hovered))
            } else if let hardest = hours.hardest {
                VStack(alignment: .leading, spacing: Tokens.Spacing.lineGap) {
                    Text(Self.hardestText(hardest))
                    if let idlest = hours.idlest {
                        Text(Self.idlestText(idlest))
                    }
                }
            } else {
                Text("A week of history is needed to say when your Mac works hardest.", bundle: .strings)
            }
        }
        .font(Tokens.Typography.secondary)
        .monospacedDigit()
        // Two lines' worth, so hovering doesn't move the chart.
        .frame(minHeight: 2 * 14 * Customization.shared.figureScale, alignment: .topLeading)
    }

    /// Hours across, the week's days down, on plain numbers: a square is hour … hour + 1 by
    /// row … row + 1, with row 0 at the top. Text categories drew rows as thin lines.
    private func chart(_ hours: BusiestHours) -> some View {
        let weekdays = BusiestHours.weekdays()
        let peak = max(hours.cells.map(\.average).max() ?? 1, 1)
        return Chart(hours.cells) { cell in
            let row = Double(weekdays.firstIndex(of: cell.weekday) ?? 0)
            RectangleMark(
                xStart: .value(Self.hourAxis, Double(cell.hour) + 0.05),
                xEnd: .value(Self.hourAxis, Double(cell.hour) + 0.95),
                yStart: .value(Self.dayAxis, row + 0.06),
                yEnd: .value(Self.dayAxis, row + 0.94)
            )
            .foregroundStyle(Tokens.SidebarTint.cpu.opacity(Self.opacity(cell.average, peak: peak, contrast: contrast)))
            .accessibilityLabel(Text(verbatim: "\(Self.fullDayName(cell.weekday)) \(Self.hourName(cell.hour))"))
            .accessibilityValue(Text(Formatters.percent(cell.average)))
        }
        .chartXScale(domain: 0.0 ... 24.0)
        // Row 0 at the top.
        .chartYScale(domain: [7.0, 0.0])
        .chartXAxis {
            AxisMarks(values: [0.0, 6.0, 12.0, 18.0]) { value in
                AxisValueLabel(anchor: .topLeading) {
                    Text(Self.hourName(Int(value.as(Double.self) ?? 0)))
                }
                .font(Tokens.Typography.chartLabel)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: weekdays.indices.map { Double($0) + 0.5 }) { value in
                AxisValueLabel {
                    Text(Self.dayName(weekdays[min(6, Int(value.as(Double.self) ?? 0))]))
                }
                .font(Tokens.Typography.chartLabel)
            }
        }
        .chartPlotStyle { $0.background(Tokens.Surfaces.inset) }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(.rect)
                    .onContinuousHover { phase in
                        guard case let .active(point) = phase, let frame = proxy.plotFrame.map({ geometry[$0] }),
                              let hour = proxy.value(atX: point.x - frame.minX, as: Double.self),
                              let row = proxy.value(atY: point.y - frame.minY, as: Double.self),
                              weekdays.indices.contains(Int(row))
                        else {
                            hovered = nil
                            return
                        }
                        hovered = hours.cells.first { $0.weekday == weekdays[Int(row)] && $0.hour == Int(hour) }
                    }
            }
        }
        .frame(height: 170 * Customization.shared.figureScale)
    }

    nonisolated static func opacity(_ average: Double, peak: Double, contrast: ColorSchemeContrast) -> Double {
        let floor = contrast == .increased ? 0.3 : 0.14
        return floor + (1 - floor) * min(1, max(0, average / peak))
    }

    nonisolated static func dayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols
        return symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : ""
    }

    /// As the Mac shows hours, 12- or 24-hour.
    nonisolated static func hourName(_ hour: Int) -> String {
        SleepCard.hourLabel(hour)
    }

    nonisolated static func fullDayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        return symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : ""
    }

    nonisolated static func hardestText(_ cell: BusiestHours.Cell) -> String {
        let (day, hour, percent) = (fullDayName(cell.weekday), hourName(cell.hour), Formatters.percent(cell.average))
        return String(
            localized: "Works hardest: \(day) around \(hour), \(percent) of the processor on average.",
            bundle: .strings,
            comment: "Busiest hours: a weekday, an hour, a percent"
        )
    }

    nonisolated static func idlestText(_ cell: BusiestHours.Cell) -> String {
        let (day, hour, percent) = (fullDayName(cell.weekday), hourName(cell.hour), Formatters.percent(cell.average))
        return String(
            localized: "Sits most idle: \(day) around \(hour), \(percent).",
            bundle: .strings,
            comment: "Busiest hours: a weekday, an hour, a percent"
        )
    }

    nonisolated static func cellText(_ cell: BusiestHours.Cell) -> String {
        let (day, hour, percent) = (fullDayName(cell.weekday), hourName(cell.hour), Formatters.percent(cell.average))
        let time = TimeInFrontCard.duration(cell.minutes * 60)
        return String(
            localized: "\(day) around \(hour): \(percent) on average, from \(time) recorded.",
            bundle: .strings,
            comment: "Busiest hours, hovering a square: a weekday, an hour, a percent, how much time it's based on"
        )
    }

    nonisolated static func load(_ store: any HourRhythmStore, now: Date = Date()) async -> BusiestHours {
        let start = now.addingTimeInterval(-Double(BusiestHours.weeks) * 7 * 86400)
        return await BusiestHours.read((try? store.wholeMacHours(from: start, to: now)) ?? [])
    }

    private static let hourAxis = String(localized: "Hour", bundle: .strings, comment: "Chart axis: an hour of the day")
    private static let dayAxis = String(localized: "Day", bundle: .strings, comment: "Chart axis: a day of the week")
}
