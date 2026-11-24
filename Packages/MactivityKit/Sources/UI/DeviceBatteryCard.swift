import Charts
import Core
import SwiftUI

/// AirPods, mice, keyboards and trackpads over the history range (D-094): each one's level as a
/// line, when it was last charged, and about how long it has left at its recent rate.
struct DeviceBatteryCard: View {
    let store: any DeviceBatteryStore
    let range: HistoryRange
    let generation: Int

    @State private var devices: [DeviceBatteryHistory] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            if devices.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No accessories yet", bundle: .strings), systemImage: "airpodspro")
                } description: {
                    Text(
                        """
                        AirPods, Magic Mouse, Magic Keyboard and Magic Trackpad show up here with their battery \
                        over time. AirPods need Bluetooth access: Settings → Privacy.
                        """,
                        bundle: .strings
                    )
                }
                .frame(maxWidth: .infinity, minHeight: 140)
                .opacity(loaded ? 1 : 0)
            } else {
                ForEach(devices) { device in
                    DeviceBatteryRow(device: device, range: range)
                    if device.id != devices.last?.id {
                        Divider()
                    }
                }
            }
        }
        .cardStyle()
        .task(id: LoadKey(range: range, generation: generation)) {
            // New readings arrive every 10 minutes; check back as often while it's on screen.
            while !Task.isCancelled {
                let days = max(1, Int((Double(range.duration.components.seconds) / 86400).rounded(.up)))
                let found = await (try? store.deviceHistory(days: days)) ?? []
                guard !Task.isCancelled else {
                    return
                }
                devices = found
                loaded = true
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    private struct LoadKey: Hashable {
        let range: HistoryRange
        let generation: Int
    }
}

struct DeviceBatteryRow: View {
    let device: DeviceBatteryHistory
    let range: HistoryRange

    var body: some View {
        let now = Date()
        let latest = device.points.last?.percent ?? 0
        let tint = latest <= 20 ? Tokens.Colors.strain : MetricTab.battery.tint
        HStack(alignment: .center, spacing: Tokens.Spacing.m) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                HStack(spacing: Tokens.Spacing.xs) {
                    Image(systemName: Self.symbol(device.kind))
                        .foregroundStyle(tint)
                        .frame(width: 22)
                    Text(device.name)
                        .font(Tokens.Typography.cardTitle)
                        .lineLimit(1)
                }
                Text(Formatters.percent(latest))
                    .font(Tokens.Typography.headline)
                    .monospacedDigit()
                Text(Self.summary(device.insight(now: now), now: now))
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(width: 220, alignment: .leading)
            Chart(device.points, id: \.at) { point in
                AreaMark(x: .value(HistoryStrip.fromAxis, point.at), y: .value(HistoryStrip.averageAxis, point.percent))
                    .foregroundStyle(tint.opacity(0.18))
                    .interpolationMethod(.stepEnd)
                LineMark(x: .value(HistoryStrip.fromAxis, point.at), y: .value(HistoryStrip.averageAxis, point.percent))
                    .foregroundStyle(tint)
                    .interpolationMethod(.stepEnd)
            }
            .chartXScale(domain: now.addingTimeInterval(-TimeInterval(range.duration.components.seconds)) ... now)
            .chartYScale(domain: 0 ... 100)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel { Text(Formatters.percent(value.as(Double.self) ?? 0)) }
                        .font(Tokens.Typography.chartLabel)
                }
            }
            .chartXAxis {
                AxisMarks(values: HistoryStrip.axisValues(range)) {
                    AxisGridLine()
                    AxisValueLabel(format: HistoryStrip.axisFormat(range))
                        .font(Tokens.Typography.chartLabel)
                }
            }
            .frame(height: 90)
            .accessibilityLabel(Text(device.name))
            .accessibilityValue(Text(Self.summary(device.insight(now: now), now: now)))
        }
    }

    nonisolated static func symbol(_ kind: PeripheralBattery.Kind) -> String {
        switch kind {
        case .airPods: "airpodspro"
        case .mouse: "magicmouse.fill"
        case .keyboard: "keyboard.fill"
        case .trackpad: "rectangle.and.hand.point.up.left.fill"
        case .other: "dot.radiowaves.left.and.right"
        }
    }

    /// "Charged 3 days ago · about 5 days left".
    nonisolated static func summary(_ insight: DeviceBatteryInsight, now: Date) -> String {
        var parts: [String] = []
        if let charged = insight.lastCharged {
            let when = charged.formatted(.relative(presentation: .named))
            parts.append(String(
                localized: "Charged \(when)",
                bundle: .strings,
                comment: "Accessory battery: when it was last charged, e.g. 3 days ago"
            ))
        }
        if let days = insight.daysLeft {
            let left = Duration.seconds(max(3600, days * 86400)).formatted(.units(
                allowed: [.days, .hours],
                width: .wide,
                maximumUnitCount: 1
            ))
            parts.append(String(
                localized: "about \(left) left",
                bundle: .strings,
                comment: "Accessory battery: time left at its recent drain, e.g. about 5 days left"
            ))
        }
        return parts.isEmpty
            ? String(localized: "Mactivity notes the level every 10 minutes while it's connected.", bundle: .strings)
            : parts.joined(separator: " · ")
    }
}
