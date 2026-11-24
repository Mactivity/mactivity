import Core
import SwiftUI

/// Battery tab → Battery temperature (D-275): how warm it ran while charging and otherwise, over
/// the same range as the charge line and its watts above.
struct BatteryTemperatureCard: View {
    let services: AppServices
    let range: HistoryRange
    @State private var summary: BatteryTemperatureSummary?
    @State private var loaded = false

    private static let spec = HistoryStrip.Spec(
        id: "batteryTemperature",
        title: String(localized: "Battery temperature", bundle: .strings, comment: "Battery tab section"),
        metrics: [.batteryTempCharging, .batteryTempInUse],
        tint: .orange
    )

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            CardHeader(title: Self.spec.title, symbol: "thermometer.medium", status: nil, tint: Self.spec.tint)
                .help(Self.help)
            if let summary {
                Text(Self.text(summary, range: range))
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .help(Self.help)
            }
            if loaded, summary == nil {
                Text(emptyText)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle()
            } else {
                HistoryStrip(spec: Self.spec, range: range, services: services, showsTitle: false)
                    .frame(height: Tokens.Layout.historyStripHeight)
            }
        }
        .task(id: "\(range.rawValue)-\(services.historyGeneration)") {
            let end = Date()
            let start = end.addingTimeInterval(-TimeInterval(range.duration.components.seconds))
            let history = services.history
            let charging = await (try? history.series(metric: .batteryTempCharging, app: nil, range: range)) ?? []
            let inUse = await (try? history.series(metric: .batteryTempInUse, app: nil, range: range)) ?? []
            summary = BatteryTemperatureSummary.read(charging: charging, inUse: inUse, rangeStart: start)
            loaded = true
        }
    }

    /// Says plainly whether it's a matter of waiting, or this Mac can't.
    private var emptyText: String {
        guard services.metrics.snapshot?.system.battery?.temperatureCelsius != nil else {
            return String(
                localized: "This Mac's battery isn't reporting its temperature, so there's nothing to record.",
                bundle: .strings
            )
        }
        return String(
            localized: """
            Mactivity has only just started recording the battery's temperature. \
            The first readings appear here within a few minutes.
            """,
            bundle: .strings
        )
    }

    /// "While charging: average 31°, peak 38° · In use: average 28°, peak 34°", from when it began.
    nonisolated static func text(_ summary: BatteryTemperatureSummary, range: HistoryRange) -> String {
        var parts: [String] = []
        if let side = summary.charging {
            let (average, peak) = (Formatters.temperature(celsius: side.average), Formatters.temperature(celsius: side.peak))
            parts.append(String(
                localized: "While charging: average \(average), peak \(peak)", bundle: .strings,
                comment: "Battery temperature over the range"
            ))
        }
        if let side = summary.inUse {
            let (average, peak) = (Formatters.temperature(celsius: side.average), Formatters.temperature(celsius: side.peak))
            parts.append(String(
                localized: "In use: average \(average), peak \(peak)", bundle: .strings,
                comment: "Battery temperature over the range, while not charging"
            ))
        }
        let figures = parts.joined(separator: " · ")
        guard let since = summary.since else {
            return figures
        }
        let start = since.formatted(date: range.isWithinDay ? .omitted : .abbreviated, time: .shortened)
        return String(
            localized: "Recording since \(start). \(figures)", bundle: .strings,
            comment: "Battery temperature: when recording began inside the range, then the figures"
        )
    }

    static let help = String(
        localized: """
        How warm the battery itself runs, from its own sensor. Heat is one of the things that wears a battery fastest, \
        more so while it charges. In use is all the other time your Mac is awake: on battery, or plugged in and not charging.
        """,
        bundle: .strings
    )
}

/// Battery tab → Chargers compared (D-274): what each power rating really delivers and how fast it
/// fills the battery, judged only like for like.
struct ChargersComparedCard: View {
    let store: any ChargerHistoryStore
    let generation: Int
    @State private var comparison: ChargerComparison?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            CardHeader(
                title: String(localized: "Chargers compared", bundle: .strings, comment: "Battery tab section"),
                symbol: "powerplug", status: nil, tint: MetricTab.battery.tint
            )
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                if let comparison {
                    content(comparison)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 60)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
        .task(id: generation) {
            comparison = await ChargerComparison.read((try? store.chargerUse(days: HistoryRetention.defaultDays)) ?? [])
        }
    }

    @ViewBuilder private func content(_ comparison: ChargerComparison) -> some View {
        if comparison.chargers.isEmpty {
            Text(
                """
                Mactivity has only just started recording chargers. \
                Each one you use appears here after it has charged your Mac for a while.
                """,
                bundle: .strings
            )
            .font(Tokens.Typography.secondary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            table(comparison.chargers)
            ForEach(Self.lines(comparison), id: \.self) { line in
                Text(line)
                    .font(Tokens.Typography.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(Self.note(since: comparison.since))
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func table(_ chargers: [ChargerComparison.Charger]) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: Tokens.Spacing.m, verticalSpacing: Tokens.Spacing.xs) {
            GridRow {
                Text("Rating", bundle: .strings, comment: "Chargers compared: the power rating column").gridColumnAlignment(.leading)
                Text("Delivers", bundle: .strings, comment: "Chargers compared: watts really delivered").help(Self.deliversHelp)
                Text("Under 50%", bundle: .strings, comment: "Chargers compared: fill speed at this charge level").help(Self.fillHelp)
                Text("50–80%", bundle: .strings, comment: "Chargers compared: fill speed at this charge level").help(Self.fillHelp)
                Text("Over 80%", bundle: .strings, comment: "Chargers compared: fill speed at this charge level").help(Self.fillHelp)
            }
            .font(Tokens.Typography.secondary)
            .foregroundStyle(.secondary)
            Divider()
            ForEach(chargers) { charger in
                GridRow {
                    Text(Self.rating(charger.ratingWatts))
                    Text(Self.delivers(charger))
                    Text(Self.speed(charger.fillSpeed[.low]))
                    Text(Self.speed(charger.fillSpeed[.middle]))
                    Text(Self.speed(charger.fillSpeed[.high]))
                }
                .monospacedDigit()
            }
        }
    }

    nonisolated static func rating(_ watts: Int) -> String {
        Formatters.power(milliwatts: Double(watts) * 1000)
    }

    /// "38 W, up to 91 W"; a dash until it has delivered anything while charging.
    nonisolated static func delivers(_ charger: ChargerComparison.Charger) -> String {
        guard let average = charger.averageDeliveredWatts else {
            return "–"
        }
        let typical = Formatters.power(milliwatts: average * 1000)
        guard let peak = charger.peakDeliveredWatts else {
            return typical
        }
        let most = Formatters.power(milliwatts: peak * 1000)
        return String(
            localized: "\(typical), up to \(most)", bundle: .strings,
            comment: "Chargers compared: average watts while charging, then the most it delivered"
        )
    }

    nonisolated static func speed(_ percentPerHour: Double?) -> String {
        guard let percentPerHour else {
            return "–"
        }
        let percent = Formatters.percent(percentPerHour)
        return String(localized: "\(percent) an hour", bundle: .strings, comment: "Chargers compared: how fast the battery filled")
    }

    /// One charger: what would compare it. Several: each pair's verdict, at most three.
    nonisolated static func lines(_ comparison: ChargerComparison) -> [String] {
        guard comparison.chargers.count > 1 else {
            return [String(localized: "Charge with another charger and the two are compared here, like for like.", bundle: .strings)]
        }
        return comparison.verdicts.prefix(3).map(verdict)
    }

    nonisolated static func verdict(_ verdict: ChargerComparison.Verdict) -> String {
        switch verdict {
        case let .faster(faster, slower, ratio, seconds):
            let (a, b) = (rating(faster), rating(slower))
            let percent = Formatters.percent((ratio - 1) * 100)
            let time = TimeInFrontCard.duration(seconds)
            return String(
                localized: """
                Like for like, the \(a) charger filled the battery \(percent) faster than the \(b) one, \
                over \(time) of matching charging.
                """,
                bundle: .strings,
                comment: "Chargers compared: the faster rating, how much faster, the slower rating, how much charging it's based on"
            )
        case let .aboutTheSame(first, second, seconds):
            let (a, b) = (rating(first), rating(second))
            let time = TimeInFrontCard.duration(seconds)
            return String(
                localized: """
                Like for like, the \(a) and \(b) chargers fill the battery about as fast, over \(time) of matching charging.
                """,
                bundle: .strings,
                comment: "Chargers compared: two ratings, how much charging it's based on"
            )
        case let .tooLittle(first, second, seconds):
            let (a, b) = (rating(first), rating(second))
            let time = TimeInFrontCard.duration(seconds)
            return String(
                localized: """
                Too little matching charging to compare the \(a) and \(b) chargers yet: \(time) of the hour it takes.
                """,
                bundle: .strings,
                comment: "Chargers compared: two ratings, how much charging there is so far"
            )
        }
    }

    nonisolated static func note(since: Date?) -> String {
        let start = (since ?? Date()).formatted(date: .abbreviated, time: .omitted)
        return String(
            localized: """
            Recording since \(start). Chargers are told apart only by the power rating your Mac reports, \
            so two of the same rating count as one.
            """,
            bundle: .strings,
            comment: "Chargers compared: the date recording began, and how chargers are told apart"
        )
    }

    static let deliversHelp = String(
        localized: """
        What really came in from the charger: the average while charging, and the most it ever delivered. \
        A charger gives what your Mac asks for, so this can sit well under its rating.
        """,
        bundle: .strings
    )
    static let fillHelp = String(
        localized: """
        How many percent the battery gained in an hour of charging at that level. A battery slows down as it fills, \
        and when it's warm or the Mac is busy. These figures mix all of that; the line below compares only charging that matched.
        """,
        bundle: .strings
    )
}
