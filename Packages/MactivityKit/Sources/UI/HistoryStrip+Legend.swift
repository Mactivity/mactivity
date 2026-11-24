import SwiftUI

extension HistoryStrip {
    /// Which color is which, for strips with more than one series.
    var legend: some View {
        HStack(spacing: Tokens.Spacing.s) {
            ForEach(Array(spec.metrics.enumerated()), id: \.element) { index, metric in
                HStack(spacing: Tokens.Spacing.xxs) {
                    Circle()
                        .fill(color(index))
                        .frame(width: Tokens.Layout.statusDot, height: Tokens.Layout.statusDot)
                    Text(metric.title)
                }
            }
        }
        .font(Tokens.Typography.secondary)
        .foregroundStyle(.secondary)
    }

    func color(_ index: Int) -> Color {
        index == 0 ? spec.tint : Tokens.Colors.chartSecondary(spec.tint)
    }
}
