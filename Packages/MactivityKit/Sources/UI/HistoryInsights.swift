import Core
import SwiftUI

// History's plain-language notes and the data-used card (D-095).

extension HistoryView {
    /// Figures only the whole Mac has: memory pressure, swap, and the startup disk's free space.
    /// The battery's level is the Battery section's own chart on a laptop (D-105).
    static let systemSpecs: [HistoryStrip.Spec] = [
        HistoryStrip.Spec(id: "pressure", title: Metric.memoryPressure.title, metrics: [.memoryPressure], tint: MetricTab.memory.tint),
        HistoryStrip.Spec(id: "swap", title: Metric.swapUsed.title, metrics: [.swapUsed], tint: MetricTab.memory.tint),
        HistoryStrip.Spec(id: "free", title: Metric.diskFree.title, metrics: [.diskFree], tint: MetricTab.disk.tint),
    ]

    static func symbol(forSystemSpec id: String) -> String {
        switch id {
        case "pressure": "gauge.with.dots.needle.67percent"
        case "swap": "arrow.left.arrow.right"
        default: "internaldrive"
        }
    }
}

/// "Full in about 3 weeks at this rate", from the last 30 days of free space.
struct DiskForecastNote: View {
    let store: any DailyHistoryStore
    let generation: Int

    @State private var text = ""

    var body: some View {
        Text(text)
            .font(Tokens.Typography.secondary)
            .foregroundStyle(.secondary)
            .task(id: generation) {
                let days = await (try? store.dailyValues(metric: .diskFree, days: 30)) ?? []
                text = Self.text(DiskForecast.daysUntilFull(days))
            }
    }

    nonisolated static func text(_ days: Double?) -> String {
        guard let days else {
            return ""
        }
        guard days >= 1 else {
            return String(localized: "Full within a day at this rate", bundle: .strings)
        }
        let span = Duration.seconds(days * 86400).formatted(.units(allowed: [.weeks, .days], width: .wide, maximumUnitCount: 1))
        return String(
            localized: "Full in about \(span) at this rate",
            bundle: .strings,
            comment: "Startup disk forecast, e.g. about 3 weeks"
        )
    }
}

/// Network data per app over the range: "Safari 14.2 GB", with the whole Mac's total.
struct DataUsedCard: View {
    let store: any DailyHistoryStore
    let range: HistoryRange
    let generation: Int

    @State private var apps: [AppTotal] = []
    @State private var total: Double = 0

    private static let metrics: [Metric] = [.netIn, .netOut]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text(
                "\(Formatters.bytes(total)) sent and received · \(range.label)",
                bundle: .strings,
                comment: "Data used: the Mac's total over the history range"
            )
            .font(Tokens.Typography.secondary)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            let largest = apps.first?.value ?? 0
            ForEach(apps, id: \.app.id) { app in
                HStack(spacing: Tokens.Spacing.xs) {
                    AppIconView(app.app, size: Tokens.IconSize.small)
                    Text(app.app.name)
                        .lineLimit(1)
                        .frame(width: 180, alignment: .leading)
                    GeometryReader { proxy in
                        Capsule()
                            .fill(MetricTab.network.tint.opacity(0.7))
                            .frame(width: max(2, proxy.size.width * (largest > 0 ? app.value / largest : 0)))
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 6)
                    Text(Formatters.bytes(app.value))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                }
            }
            if apps.isEmpty {
                Text("No network use recorded yet.", bundle: .strings)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
        .task(id: "\(range.rawValue)-\(generation)") {
            let end = Date()
            let start = end.addingTimeInterval(-TimeInterval(range.duration.components.seconds))
            let found = await (try? store.totals(metrics: Self.metrics, from: start, to: end, limit: 8)) ?? []
            let sum = await (try? store.systemTotal(metrics: Self.metrics, from: start, to: end)) ?? 0
            guard !Task.isCancelled else {
                return
            }
            apps = found
            total = sum
        }
    }
}
