import Charts
import Core
import SwiftUI

/// Your week, day by day (D-184): time in use on each of the last seven days, the day with the
/// most at full color and its hours above it. Fills the card's right side, which sat empty.
struct WeekDaysChart: View {
    let days: [DayTotal]
    var title = String(localized: "Time in use by day", bundle: .strings, comment: "Your week: the chart of each day's time in use")
    var tint = Color.accentColor

    private var most: DayTotal? {
        days.filter { $0.seconds > 0 }.max { $0.seconds < $1.seconds }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text(title)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
            Chart(days, id: \.day) { day in
                BarMark(
                    x: .value(String(localized: "Day", bundle: .strings, comment: "Chart axis: a day of the week"), day.day, unit: .day),
                    y: .value(
                        String(localized: "In use", bundle: .strings, comment: "Your week: time the Mac was in use"),
                        day.seconds / 3600
                    ),
                    width: .ratio(0.62)
                )
                .clipShape(.rect(cornerRadius: 3))
                .foregroundStyle(tint.opacity(day.day == most?.day ? 1 : 0.45))
                .annotation(position: .top, spacing: 3) {
                    if day.seconds >= 60 {
                        Text(YourWeekContent.hours(day.seconds, units: 1))
                            .font(Tokens.Typography.secondary.weight(day.day == most?.day ? .semibold : .regular))
                            .foregroundStyle(day.day == most?.day ? .primary : .secondary)
                            .monospacedDigit()
                    }
                }
                .accessibilityLabel(day.day.formatted(.dateTime.weekday(.wide)))
                .accessibilityValue(YourWeekContent.hours(day.seconds))
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                        .font(Tokens.Typography.chartLabel)
                }
            }
            .chartYAxis(.hidden)
            // Headroom for the tallest bar's label.
            .chartYScale(domain: 0 ... max(1, (most?.seconds ?? 0) / 3600 * 1.25))
            .frame(height: Tokens.Layout.weekDaysChartHeight)
        }
    }
}
