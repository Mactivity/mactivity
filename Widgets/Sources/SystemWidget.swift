import Core
import Readouts
import SwiftUI
import WidgetKit

/// Small: CPU with a sparkline. Medium: CPU, memory, battery. Large: plus the top 3 apps.
struct SystemWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.widgetKind, provider: SystemWidgetProvider()) { entry in
            SystemWidgetView(entry: entry)
                // System container background, so tinted and clear modes can replace it with glass.
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Mactivity")
        .description("CPU, memory, and battery, with the apps using the most.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// The widget's own named constants (the extension doesn't link the UI package's `Tokens`).
enum WidgetStyle {
    static let hero = Font.system(size: 34, weight: .semibold, design: .rounded)
    static let figure = Font.system(size: 22, weight: .semibold, design: .rounded)
    static let label = Font.caption.weight(.semibold)
    static let detail = Font.caption
    static let tight: CGFloat = 2
    static let small: CGFloat = 4
    static let medium: CGFloat = 8
    static let large: CGFloat = 12
    static let sparklineHeight: CGFloat = 36
    /// Share of each bar's slot the bar fills; the rest is the gap.
    static let barShare: CGFloat = 0.6
    static let barRadius: CGFloat = 1
    static let trackRadius: CGFloat = 6
    static let trackOpacity = 0.12
    static let appIcon = "gauge.with.dots.needle.33percent"
}

struct SystemWidgetView: View {
    let entry: SystemEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch entry.state {
        case let .figures(snapshot):
            switch family {
            case .systemSmall: SmallLayout(snapshot: snapshot)
            case .systemLarge: LargeLayout(snapshot: snapshot)
            default: MediumLayout(snapshot: snapshot)
            }
        case .needsSignedBuild:
            OpenAppView(detail: "Widgets need a signed build of Mactivity.")
        case .openApp:
            OpenAppView(detail: "Figures appear while Mactivity is running.")
        }
    }
}

// MARK: - Layouts

private struct SmallLayout: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetStyle.small) {
            MetricLabel(title: "CPU", symbol: "cpu")
            Text(Formatters.percent(snapshot.cpuPercent))
                .font(WidgetStyle.hero)
                .monospacedDigit()
                .widgetAccentable()
            Spacer(minLength: 0)
            SparklineView(values: snapshot.cpuHistory)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CPU \(Formatters.percent(snapshot.cpuPercent))")
    }
}

private struct MediumLayout: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: WidgetStyle.large) {
            VStack(alignment: .leading, spacing: WidgetStyle.small) {
                MetricFigure(title: "CPU", symbol: "cpu", value: Formatters.percent(snapshot.cpuPercent), detail: nil)
                Spacer(minLength: 0)
                SparklineView(values: snapshot.cpuHistory)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MemoryFigure(snapshot: snapshot)
                .frame(maxWidth: .infinity, alignment: .leading)
            // A desktop has no battery: the GPU takes its place.
            if let battery = snapshot.battery {
                BatteryFigure(battery: battery)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                MetricFigure(
                    title: "GPU",
                    symbol: "cube.transparent",
                    value: snapshot.gpuPercent.map { Formatters.percent($0) } ?? "–",
                    detail: nil
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct LargeLayout: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetStyle.large) {
            MediumLayout(snapshot: snapshot)
            Divider()
            VStack(alignment: .leading, spacing: WidgetStyle.medium) {
                MetricLabel(title: "Top Apps", symbol: "list.number")
                if snapshot.topApps.isEmpty {
                    Text("Nothing busy right now.")
                        .font(WidgetStyle.detail)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(snapshot.topApps.enumerated()), id: \.offset) { _, app in
                    TopAppRow(app: app)
                }
            }
            Spacer(minLength: 0)
            Text("Updated \(snapshot.updatedAt, style: .relative) ago")
                .font(WidgetStyle.detail)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Pieces

private struct MetricLabel: View {
    let title: LocalizedStringKey
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(WidgetStyle.label)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct MetricFigure: View {
    let title: LocalizedStringKey
    let symbol: String
    let value: String
    let detail: Text?

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetStyle.tight) {
            MetricLabel(title: title, symbol: symbol)
            Text(value)
                .font(WidgetStyle.figure)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .widgetAccentable()
            if let detail {
                detail
                    .font(WidgetStyle.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MemoryFigure: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetStyle.small) {
            MetricFigure(
                title: "Memory",
                symbol: "memorychip",
                value: Formatters.memory(snapshot.memoryUsedBytes),
                detail: Text(
                    "of \(Formatters.memory(snapshot.memoryTotalBytes))",
                    comment: "Under used memory: the Mac's total memory, e.g. of 48 GB"
                )
            )
            Spacer(minLength: 0)
            Gauge(value: min(1, max(0, snapshot.memoryUsedPercent / 100))) {
                EmptyView()
            }
            .gaugeStyle(.linearCapacity)
            .tint(.accentColor)
            .widgetAccentable()
            .accessibilityHidden(true)
        }
    }
}

private struct BatteryFigure: View {
    let battery: WidgetSnapshot.Battery

    var body: some View {
        MetricFigure(title: "Battery", symbol: symbol(battery), value: Formatters.percent(battery.percent), detail: state(battery))
    }

    private func state(_ battery: WidgetSnapshot.Battery) -> Text {
        if battery.isCharging {
            return Text("Charging", comment: "Battery state under the percentage")
        }
        return battery.onAC
            ? Text("On power", comment: "Battery state: plugged into a power adapter, not charging")
            : Text("On battery", comment: "Battery state: running on the battery")
    }

    private func symbol(_ battery: WidgetSnapshot.Battery) -> String {
        if battery.isCharging {
            return "battery.100percent.bolt"
        }
        switch battery.percent {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

private struct TopAppRow: View {
    let app: WidgetSnapshot.TopApp

    var body: some View {
        HStack(spacing: WidgetStyle.medium) {
            Text(app.name)
                .lineLimit(1)
            Spacer(minLength: WidgetStyle.small)
            Text(Formatters.percent(app.cpuPercent))
                .monospacedDigit()
                .widgetAccentable()
            Text(Formatters.memory(app.memoryBytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

struct OpenAppView: View {
    let detail: LocalizedStringKey

    var body: some View {
        VStack(spacing: WidgetStyle.small) {
            Image(systemName: WidgetStyle.appIcon)
                .font(.title2)
                .foregroundStyle(.tint)
                .widgetAccentable()
            Text("Open Mactivity")
                .font(.headline)
            Text(detail)
                .font(WidgetStyle.detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// CPU over the last half hour, one bar a minute, like the app's sparklines. One `Path`, not
/// Swift Charts (D-032).
private struct SparklineView: View {
    let values: [Double]

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        SparklineBarsShape(values: values)
            .fill(.tint)
            .padding(WidgetStyle.small)
            .background {
                // Full color only: tinted and clear modes flatten fills into a solid block.
                if renderingMode == .fullColor {
                    RoundedRectangle(cornerRadius: WidgetStyle.trackRadius)
                        .fill(Color.accentColor.opacity(WidgetStyle.trackOpacity))
                }
            }
            .widgetAccentable()
            .frame(height: WidgetStyle.sparklineHeight)
            .accessibilityHidden(true)
    }
}

/// One rounded bar per value, spread across the width, on a fixed 0–100 scale so the height
/// means load. A zero is still a stub as tall as the bar is wide.
struct SparklineBarsShape: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !values.isEmpty, rect.width > 0, rect.height > 0 else {
            return path
        }
        let pitch = rect.width / CGFloat(values.count)
        let width = max(1, pitch * WidgetStyle.barShare)
        let radius = min(width / 2, WidgetStyle.barRadius)
        let corners = RectangleCornerRadii(topLeading: radius, bottomLeading: 0, bottomTrailing: 0, topTrailing: radius)
        for (index, value) in values.enumerated() {
            let height = max(min(width, rect.height), rect.height * CGFloat(min(100, max(0, value)) / 100))
            let x = rect.minX + CGFloat(index) * pitch + (pitch - width) / 2
            path.addRoundedRect(in: CGRect(x: x, y: rect.maxY - height, width: width, height: height), cornerRadii: corners)
        }
        return path
    }
}
