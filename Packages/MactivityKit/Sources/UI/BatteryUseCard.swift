import Core
import SwiftUI

/// The Battery tab's "what used energy" (D-100, D-114), in the app list's place, over the page's
/// range (D-258) or since unplugged. With time on battery, each app's share of the battery used, like the iPhone's;
/// plugged in the whole time, each app's share of all the energy used, so the list isn't empty on
/// a Mac that lives on its charger. Plus how long the Mac was on battery and how much it used, and
/// the battery's health with a forecast of when it reaches 80%.
struct BatteryUseList: View {
    let services: AppServices
    let span: Span
    /// The page's range, which the list follows (D-258).
    let range: HistoryRange

    enum Span: String, CaseIterable, Identifiable, Hashable {
        /// The page's range, the same one the History strip shows (D-258).
        case range
        /// Since the Mac last went on battery (D-150): offered only while it's on battery.
        case sinceUnplugged

        var id: String {
            rawValue
        }

        /// The range's own label ("24 h", "30 d"), so the switch reads like the toolbar's.
        func title(range: HistoryRange) -> String {
            switch self {
            case .range: range.label
            case .sinceUnplugged: String(
                    localized: "Since unplugged",
                    bundle: .strings,
                    comment: "Battery tab: since the charger was disconnected"
                )
            }
        }

        static func offered(onBattery: Bool) -> [Span] {
            onBattery ? allCases : [.range]
        }
    }

    /// Less than this on battery and battery shares say too little: the list shows energy shares.
    static let batteryMinimum: TimeInterval = 1800

    @State private var use: BatteryUse?
    /// Each app's share of all energy over the span, in percent, when there was too little
    /// time on battery (D-114).
    @State private var energy: [AppTotal] = []
    @State private var health: [BatteryDay] = []
    @State private var unpluggedAt: Date?
    /// Each app's average power over the span, in milliwatts (D-258).
    @State private var watts: [AppIdentity.ID: Double] = [:]

    var body: some View {
        List {
            Section {
                if let rows, !rows.isEmpty {
                    ForEach(rows, id: \.app.id) { app in
                        HStack(spacing: Tokens.Spacing.xs) {
                            AppIconView(app.app, size: Tokens.IconSize.row)
                            Text(app.app.name)
                                .lineLimit(1)
                                .frame(width: 200, alignment: .leading)
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(MetricTab.battery.tint.opacity(0.75))
                                    .frame(width: max(2, proxy.size.width * app.value))
                                    .frame(maxHeight: .infinity, alignment: .center)
                            }
                            .frame(height: 6)
                            Text(watts[app.app.id].map { Formatters.power(milliwatts: $0) } ?? "")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 64, alignment: .trailing)
                                .help(Self.wattsHelp)
                            Text(Formatters.percent(app.value * 100))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                } else {
                    Text("Nothing recorded yet in this span.", bundle: .strings)
                        .foregroundStyle(.secondary)
                }
            } header: {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(summary)
                        Spacer()
                        if services.metrics.hardware.hasBattery {
                            BatteryHealthLine(days: health)
                        }
                    }
                    // Plugged in: whether the charger keeps up (D-214).
                    if let battery = services.metrics.snapshot?.system.battery, battery.source == .ac, let verdict = ChargerCheck.verdict(
                        charger: battery.adapterWatts, drawingNow: battery.systemLoadWatts,
                        heldAt: !battery.isCharging && battery.percent < 95 ? battery.percent : nil
                    ) {
                        Label(ChargerCheck.text(verdict), systemImage: "powerplug")
                            .foregroundStyle(Self.isShort(verdict) ? AnyShapeStyle(Tokens.Colors.strainLabel) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                    }
                }
                .monospacedDigit()
            }
        }
        .listStyle(.inset)
        .task(id: TaskKey(span: span, range: range, generation: services.historyGeneration)) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private struct TaskKey: Hashable {
        let span: Span
        let range: HistoryRange
        let generation: Int
    }

    /// Battery shares when the span had enough time on battery; otherwise energy shares, as
    /// fractions like the battery's.
    private var rows: [AppTotal]? {
        if Self.usesBattery(use, span: span) {
            return use?.apps
        }
        return energy.map { AppTotal(app: $0.app, value: $0.value / 100) }
    }

    /// Since unplugged, any time on battery counts: that's the question asked.
    nonisolated static func usesBattery(_ use: BatteryUse?, span: Span) -> Bool {
        guard let use else {
            return false
        }
        return use.onBatterySeconds >= (span == .sinceUnplugged ? 60 : batteryMinimum) && !use.apps.isEmpty
    }

    /// "On battery 3h 20m · used 42%", or what the energy shares are when it was plugged in.
    private var summary: String {
        guard Self.usesBattery(use, span: span), let use else {
            guard !energy.isEmpty else {
                return ""
            }
            return services.metrics.hardware.hasBattery
                ? String(
                    localized: "Plugged in: how the energy divided up between apps",
                    bundle: .strings, comment: "Battery tab list, when the Mac was on its charger the whole span"
                )
                : String(
                    localized: "How the energy divided up between apps",
                    bundle: .strings,
                    comment: "Energy tab list on a Mac without a battery"
                )
        }
        let time = Duration.seconds(use.onBatterySeconds).formatted(.units(
            allowed: [.hours, .minutes],
            width: .narrow,
            maximumUnitCount: 2
        ))
        let used = Formatters.percent(use.drainedPercent)
        if span == .sinceUnplugged, let unpluggedAt {
            let at = unpluggedAt
                .formatted(Calendar.current.isDateInToday(unpluggedAt) ? .dateTime.hour().minute() : .dateTime.weekday().hour().minute())
            return String(
                localized: "Unplugged at \(at) · used \(used)",
                bundle: .strings,
                comment: "Battery use since unplugged: when, and charge used"
            )
        }
        return String(
            localized: "On battery \(time) · used \(used)",
            bundle: .strings,
            comment: "Battery use: time on battery and charge used"
        )
    }

    static let wattsHelp = String(
        localized: "The app's average power over this time, in watts (W). The percentage is its share of what was used.",
        bundle: .strings
    )

    /// Worth the strain color: the charger falls short. Holding and keeping up are fine.
    nonisolated static func isShort(_ verdict: ChargerCheck.Verdict) -> Bool {
        switch verdict {
        case .short: true
        case .holding, .keepsUp: false
        }
    }

    private func load() async {
        let now = Date()
        let store = services.history as? any BatteryUseStore
        let unplugged = span == .sinceUnplugged ? await (try? store?.unpluggedAt(now: now)) : nil
        // Unplugged within the minute: nothing on battery is recorded yet.
        let start = unplugged ?? now.addingTimeInterval(span == .sinceUnplugged ? -60 : -TimeInterval(range.duration.components.seconds))
        let found = await (try? store?.batteryUse(from: start, to: now, limit: 12))
        var shares: [AppTotal] = []
        if !Self.usesBattery(found, span: span), let daily = services.history as? any DailyHistoryStore {
            // Shares of every app's energy, not just the top dozen's (D-103 weighting).
            let totals = await (try? daily.topApps(metric: .energyImpact, from: start, to: now, limit: 200)) ?? []
            shares = Array(HistoryStrip.shares(totals).prefix(12))
        }
        // Each app's average watts beside its share (D-258), from the apps' own power.
        let power = await (try? (services.history as? any DailyHistoryStore)?.topApps(metric: .energy, from: start, to: now, limit: 200)) ??
            []
        let days = await (try? (services.history as? any BatteryHistoryStore)?.batteryHistory(days: 365)) ?? []
        guard !Task.isCancelled else {
            return
        }
        use = found
        unpluggedAt = unplugged
        energy = shares
        watts = Dictionary(power.map { ($0.app.id, $0.value) }, uniquingKeysWith: { first, _ in first })
        health = days
    }
}

/// "Health 91% · Cycles: 412 · About 2 years to 80% at this rate".
struct BatteryHealthLine: View {
    let days: [BatteryDay]

    var body: some View {
        let latest = days.last { $0.maxCapacityPercent != nil }?.maxCapacityPercent
        let cycles = days.last { $0.cycleCount != nil }?.cycleCount
        var parts: [String] = []
        if let latest {
            parts.append(String(
                localized: "Health \(Formatters.percent(latest))",
                bundle: .strings,
                comment: "Battery health, e.g. Health 91%"
            ))
        }
        if let cycles {
            parts.append(String(localized: "Cycles: \(cycles)", bundle: .strings, comment: "Battery charge cycles"))
        }
        parts.append(Self.forecast(BatteryHealthForecast.estimate(80, days: days), capacity: latest))
        return Text(parts.joined(separator: " · "))
            .lineLimit(1)
            .truncationMode(.head)
    }

    nonisolated static func forecast(_ months: Double?, capacity: Double? = nil) -> String {
        // Still at full capacity: no wear to project from, now or in a few weeks (D-205).
        if months == nil, let capacity, capacity >= 99.5 {
            return String(localized: "No wear yet: still at full capacity.", bundle: .strings)
        }
        guard let months else {
            return String(localized: "A forecast appears after a few weeks of readings.", bundle: .strings)
        }
        guard months > 0 else {
            return String(localized: "At 80% or below: macOS may recommend service.", bundle: .strings)
        }
        // The system's formatter says "1 month", "14 months", "2 years" in each language.
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = months >= 24 ? [.year] : [.month]
        let whole = Int(months.rounded(.up))
        let components = months >= 24 ? DateComponents(year: Int((months / 12).rounded())) : DateComponents(month: max(1, whole))
        let span = formatter.string(from: components) ?? ""
        return String(
            localized: "About \(span) to 80% at this rate",
            bundle: .strings,
            comment: "Battery health forecast, e.g. about 14 months"
        )
    }
}
