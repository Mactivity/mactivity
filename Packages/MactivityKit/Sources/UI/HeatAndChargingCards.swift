import AppKit
import Core
import SwiftUI

/// History → Heat by app (1.7, D-255): the apps with the biggest share of the processor in the
/// Mac's warmest quarter-hours of the last four weeks, beside their share the rest of the time.
struct HeatByAppCard: View {
    static let weeks = 4
    let store: any DailyHistoryStore
    let generation: Int
    @State private var result: HeatByApp.Result??

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            switch result {
            case .none:
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            case .some(.none):
                Text("A few days of history are needed to tell which apps keep your Mac warm.", bundle: .strings)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
            case let .some(.some(result)) where result.staysCool:
                let warmest = Formatters.temperature(celsius: result.warmest)
                Text(
                    "Your Mac stays cool: even its warmest quarter-hour of the last 4 weeks averaged \(warmest).",
                    bundle: .strings,
                    comment: "Heat by app: the warmest quarter-hour's average temperature, e.g. 44 °C"
                )
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
            case let .some(.some(result)):
                if result.apps.isEmpty {
                    Text("No app stands out in your Mac's warmest hours.", bundle: .strings)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(result.apps) { heat in
                        row(heat)
                    }
                }
                Text(
                    "Your Mac's warmest tenth of the last 4 weeks: \(Formatters.temperature(celsius: result.warmFrom)) and up.",
                    bundle: .strings,
                    comment: "Heat by app: what counted as warm, e.g. 74 °C and up"
                )
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .task(id: generation) {
            result = await .some(Self.load(store))
        }
    }

    private func row(_ heat: AppHeat) -> some View {
        HStack(spacing: Tokens.Spacing.s) {
            AppIconView(heat.app, size: Tokens.IconSize.small)
            Text(heat.app.name)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)
            ProgressView(value: heat.warmShare)
                .tint(.orange)
                .frame(maxWidth: 160)
                .accessibilityHidden(true)
            Text(
                "\(Formatters.percent(heat.warmShare * 100)) when warm · \(Formatters.percent(heat.usualShare * 100)) usually",
                bundle: .strings,
                comment: "Heat by app: the app's share of the processor in the warmest hours, then the rest of the time"
            )
            .font(Tokens.Typography.secondary)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            Spacer(minLength: 0)
        }
    }

    /// The warm hours' temperatures and the 12 busiest apps' processor over the same weeks: 14 reads.
    static func load(_ store: any DailyHistoryStore, now: Date = Date()) async -> HeatByApp.Result? {
        let start = now.addingTimeInterval(-Double(weeks) * 7 * 86400)
        let temperature = await (try? store.series(metric: .cpuTemperature, app: nil, from: start, to: now)) ?? []
        guard temperature.count >= HeatByApp.minimumBuckets else {
            return nil
        }
        let top = await (try? store.topApps(metric: .cpu, from: start, to: now, limit: 12)) ?? []
        var apps: [AppIdentity: [SeriesPoint]] = [:]
        for total in top {
            apps[total.app] = await (try? store.series(metric: .cpu, app: total.app.id, from: start, to: now)) ?? []
        }
        return HeatByApp.rank(temperature: temperature, apps: apps)
    }
}

/// History → Charging habits (1.7, D-255), on a Mac with a battery: advice only.
struct ChargingHabitsCard: View {
    let store: any DailyHistoryStore
    let generation: Int
    @State private var habits: ChargingHabits??

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            switch habits {
            case .none:
                ProgressView().frame(maxWidth: .infinity, minHeight: 60)
            case .some(.none):
                Text("A few days of history are needed to say how the battery is charged.", bundle: .strings)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
            case let .some(.some(habits)):
                ForEach(habits.advice, id: \.self) { advice in
                    Label {
                        Text(Self.text(advice))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: Self.symbol(advice))
                            .foregroundStyle(advice == .fine ? .green : .orange)
                    }
                }
                HStack {
                    Text("Advice only: Mactivity never changes how your Mac charges.", bundle: .strings)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if habits.advice != [.fine] {
                        Button(String(localized: "Battery Settings…", bundle: .strings)) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .task(id: generation) {
            habits = await .some(Self.load(store))
        }
    }

    static func load(_ store: any DailyHistoryStore, now: Date = Date()) async -> ChargingHabits? {
        let start = now.addingTimeInterval(-28 * 86400)
        let level = await (try? store.series(metric: .batteryLevel, app: nil, from: start, to: now)) ?? []
        let onBattery = await (try? store.series(metric: .onBattery, app: nil, from: start, to: now)) ?? []
        let temperature = await (try? store.series(metric: .cpuTemperature, app: nil, from: start, to: now)) ?? []
        let bucket = zip(level.prefix(20), level.prefix(20).dropFirst()).map { $1.at.timeIntervalSince($0.at) }.min() ?? 900
        return ChargingHabits.read(level: level, onBattery: onBattery, temperature: temperature, bucket: bucket)
    }

    static func text(_ advice: ChargingHabits.Advice) -> String {
        switch advice {
        case let .sitsAtFull(hours):
            let time = YourWeekContent.hours(hours * 3600, units: 1)
            return String(
                localized: """
                It sat plugged in at full charge about \(time) a day. Optimized Battery Charging, in Battery \
                settings, holds it short of full until you need it, which is easier on the battery.
                """,
                bundle: .strings,
                comment: "Charging habits: hours a day at full charge, e.g. 14h"
            )
        case let .chargesWarm(share):
            return String(
                localized: """
                \(Formatters.percent(share * 100)) of its charging happened while your Mac ran warm. Heat while \
                charging wears a battery fastest; charging during lighter work helps.
                """,
                bundle: .strings,
                comment: "Charging habits: the share of charging while warm, e.g. 35%"
            )
        case let .runsLow(times):
            return String(
                localized: "It ran down under 10% \(times) times in 4 weeks. Plugging in a little sooner is easier on the battery.",
                bundle: .strings,
                comment: "Charging habits: how many times the battery dropped under 10%"
            )
        case .fine:
            return String(
                localized: "Nothing to change: it doesn't sit at full for long, charge while hot, or run low often.",
                bundle: .strings
            )
        }
    }

    static func symbol(_ advice: ChargingHabits.Advice) -> String {
        switch advice {
        case .sitsAtFull: "battery.100percent.bolt"
        case .chargesWarm: "thermometer.high"
        case .runsLow: "battery.25percent"
        case .fine: "checkmark.circle"
        }
    }
}
