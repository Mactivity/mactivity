import Core
import SwiftUI

/// Battery health month by month (D-205): each month's maximum capacity and the charge cycles
/// used in it, newest first, with the forecast under them.
struct BatteryMonthsTable: View {
    let months: [BatteryMonth]
    var forecast: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text("Battery health by month", bundle: .strings).font(Tokens.Typography.cardTitle)
            Grid(alignment: .trailing, horizontalSpacing: Tokens.Spacing.l, verticalSpacing: Tokens.Spacing.xs) {
                GridRow {
                    Text("Month", bundle: .strings).gridColumnAlignment(.leading)
                    Text("Max capacity", bundle: .strings, comment: "Battery figure: maximum capacity")
                    Text("Cycles", bundle: .strings, comment: "Battery charge cycles used in a month")
                }
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
                Divider()
                ForEach(months) { month in
                    GridRow {
                        Text(month.month.formatted(.dateTime.month(.wide).year()))
                        Text(month.capacityPercent.map { Formatters.percent($0) } ?? "–")
                        Text(month.cycles.map { $0.formatted() } ?? "–")
                    }
                    .monospacedDigit()
                }
            }
            if let forecast {
                Text(forecast).font(Tokens.Typography.secondary).foregroundStyle(.secondary)
            }
        }
        .padding(Tokens.Spacing.m)
        .frame(minWidth: 300)
    }
}
