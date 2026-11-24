import Core
import SwiftUI

struct AppRow: View {
    let app: AppAggregate
    let metric: Metric
    let total: Double?

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            AppIconView(app.app)
            Text(app.app.name)
                .lineLimit(1)
            Text("\(app.processCount) processes", bundle: .strings)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
            Spacer()
            Text(AppListView.valueText(app.value(for: metric), metric: metric, total: total))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

struct ProcessRow: View {
    let process: ProcessSample
    let metric: Metric
    let total: Double?
    /// "Tab", "Extensions"… in a browser (D-154).
    var kind: String?

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Text(process.name)
                .lineLimit(1)
            // A browser's part (D-154), or what a macOS process is for (D-214).
            if let note = kind ?? SystemProcesses.describe(process.name) {
                Text(note)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(String(process.pid))
                .font(Tokens.Typography.code)
                .foregroundStyle(.secondary)
            Spacer()
            Text(AppListView.valueText(process.value(for: metric), metric: metric, total: total))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
