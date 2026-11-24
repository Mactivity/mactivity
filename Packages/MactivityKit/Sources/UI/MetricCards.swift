import Core
import SwiftUI

/// Headline card (spec 4.3 step 1): the big figure, a status word, a live sparkline.
public struct HeadlineCard: View {
    private let tab: MetricTab
    private let metrics: LiveMetrics
    private let compact: Bool
    /// Settings → General → Figures: what Memory, Disk, Network, and Battery headline.
    @StoredFigureChoices private var choices

    public init(_ tab: MetricTab, metrics: LiveMetrics, compact: Bool = false) {
        self.tab = tab
        self.metrics = metrics
        self.compact = compact
    }

    /// The tab's symbol; on the Battery card, the battery's own level (D-176: a full green battery
    /// beside "3% · Critical" read wrong).
    private func symbol(hasBattery: Bool) -> String {
        guard tab == .battery, hasBattery, let battery = metrics.snapshot?.system.battery else {
            return tab.symbol(hasBattery: hasBattery)
        }
        return Self.batterySymbol(percent: battery.percent, charging: battery.isCharging)
    }

    /// The SF Symbol for a battery level, in the five steps the symbols come in.
    static func batterySymbol(percent: Double, charging: Bool) -> String {
        if charging {
            return "battery.100percent.bolt"
        }
        return switch percent {
        case ..<12.5: "battery.0percent"
        case ..<37.5: "battery.25percent"
        case ..<62.5: "battery.50percent"
        case ..<87.5: "battery.75percent"
        default: "battery.100percent"
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            let hasBattery = metrics.hardware.hasBattery
            CardHeader(
                title: tab.title(hasBattery: hasBattery),
                symbol: symbol(hasBattery: hasBattery),
                status: metrics.snapshot.flatMap(tab.status),
                tint: tab.tint
            )
            if let snapshot = metrics.snapshot {
                let headline = tab.headline(snapshot, choices: choices)
                FigureText(headline.figure, value: headline.value, font: compact ? Tokens.Typography.headline : Tokens.Typography.hero)
                Text(tab.caption(snapshot, choices: choices))
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            } else {
                FigureText("–", value: 0, font: compact ? Tokens.Typography.headline : Tokens.Typography.hero)
                Text("Sampling…", bundle: .strings, comment: "Shown until the first sample arrives")
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
            Sparkline(
                points: metrics.sparklines[tab] ?? [],
                domain: tab.sparklineDomain(hasBattery: metrics.hardware.hasBattery),
                tint: tab.tint,
                unit: tab.sparklineUnit(hasBattery: metrics.hardware.hasBattery)
            )
            .frame(height: compact ? Tokens.Layout.menuBarSparklineHeight : Tokens.Layout.sparklineHeight)
        }
        .cardStyle()
        .accessibilityElement(children: .combine)
    }
}

/// Secondary figures (spec 4.3 step 2).
struct SecondaryFiguresCard: View {
    let figures: [Figure]
    var columns = 3

    var body: some View {
        grid(columns: columns)
            .frame(maxHeight: .infinity, alignment: .top)
            .cardStyle()
    }

    private func grid(columns: Int) -> some View {
        // Rows 8 pt apart on every tab: Battery's four rows then fit beside the headline card, so
        // History starts at the same height on every metric page. Every cell takes an equal share
        // of the width, so a live value that gets wider doesn't push the next column over, and
        // one that doesn't fit truncates at the same text size as its neighbors rather than
        // shrinking on its own (a scale factor per cell made one row two sizes).
        Grid(alignment: .leading, horizontalSpacing: Tokens.Spacing.l, verticalSpacing: Tokens.Spacing.xs) {
            ForEach(Array(stride(from: 0, to: figures.count, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(figures[start ..< min(start + columns, figures.count)]) { figure in
                        LabeledContent {
                            Text(figure.value)
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        } label: {
                            Text(figure.label)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .labeledContentStyle(.stacked)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // The whole figure (a cell can truncate it) and, for terms like Wired,
                        // what it means.
                        .help(figure.hoverText)
                    }
                }
            }
        }
    }
}

/// Label above value, value in the primary style: the secondary-figure layout.
struct StackedLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
            configuration.label
                .font(Tokens.Typography.secondary)
            configuration.content
                .font(Tokens.Typography.body)
        }
    }
}

extension LabeledContentStyle where Self == StackedLabeledContentStyle {
    static var stacked: StackedLabeledContentStyle {
        StackedLabeledContentStyle()
    }
}

/// The tab's secondary figures, in a view of its own: they change with every snapshot, and
/// reading the snapshot in `MetricDetailView` rebuilt the whole tab every second (D-086).
struct LiveSecondaryFigures: View {
    let tab: MetricTab
    let metrics: LiveMetrics
    /// For Network's and Disk's totals so far today (D-188).
    var history: (any HistoryStore)?
    @State private var width: CGFloat = 0
    @State private var today: [Figure] = []
    /// Today's totals start over when the tab changes or History is swapped (turning Simulated
    /// data on or off replaces the store), so they never keep reading the old one.
    private struct TodayKey: Equatable {
        let tab: MetricTab
        let store: ObjectIdentifier?
    }

    private static var wide: CGFloat {
        Tokens.Layout.figuresThreeColumnMinWidth + Tokens.Spacing.gridGutter + Tokens.Layout.accessoriesCardWidth
    }

    /// Two columns beside the full card: names like "AirPods Pro" stay readable.
    private static var twoColumns: CGFloat {
        Tokens.Layout.figuresTwoColumnMinWidth + Tokens.Spacing.gridGutter + Tokens.Layout.accessoriesCardWidth
    }

    private static var narrow: CGFloat {
        Tokens.Layout.figuresTwoColumnMinWidth + Tokens.Spacing.gridGutter + Tokens.Layout.accessoriesCardNarrowWidth
    }

    var body: some View {
        content
            .task(id: TodayKey(tab: tab, store: history.map { ObjectIdentifier($0 as AnyObject) })) { await keepTodayCurrent() }
    }

    /// Today's pair after the first row (Download, Upload, Interface or Reading, Writing,
    /// Capacity), so the two sit side by side in three columns.
    private var figures: [Figure] {
        var figures = metrics.snapshot.map(tab.figures) ?? []
        figures.insert(contentsOf: today, at: min(3, figures.count))
        return figures
    }

    @ViewBuilder private var content: some View {
        let figures = figures
        let accessories = tab == .battery ? metrics.snapshot?.system.sensors?.peripherals ?? [] : []
        if accessories.isEmpty {
            // Three columns when a label like "Performance cores (10)" fits in a third; two
            // otherwise, which also fills the height the headline card beside it sets.
            SecondaryFiguresCard(figures: figures, columns: width == 0 || width >= Tokens.Layout.figuresThreeColumnRoomyWidth ? 3 : 2)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        } else {
            // The Mac's own power and heat on one card, Bluetooth accessories on another (D-165).
            // By width alone, so a live figure can't flip the layout (D-174, D-176): three columns
            // and the full card, two columns and the full card, then a narrow one, or underneath.
            Group {
                // Stacked until the width is known, so a narrow window doesn't grow to fit the first layout.
                if width >= Self.wide {
                    HStack(alignment: .top, spacing: Tokens.Spacing.gridGutter) {
                        SecondaryFiguresCard(figures: figures)
                        AccessoriesCard(accessories: accessories)
                            .frame(width: Tokens.Layout.accessoriesCardWidth)
                    }
                } else if width >= Self.twoColumns {
                    HStack(alignment: .top, spacing: Tokens.Spacing.gridGutter) {
                        SecondaryFiguresCard(figures: figures, columns: 2)
                        AccessoriesCard(accessories: accessories)
                            .frame(width: Tokens.Layout.accessoriesCardWidth)
                    }
                } else if width >= Self.narrow {
                    HStack(alignment: .top, spacing: Tokens.Spacing.gridGutter) {
                        SecondaryFiguresCard(figures: figures, columns: 2)
                        AccessoriesCard(accessories: accessories, showsBars: false)
                            .frame(width: Tokens.Layout.accessoriesCardNarrowWidth)
                    }
                } else {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.gridGutter) {
                        SecondaryFiguresCard(figures: figures, columns: 2)
                        AccessoriesCard(accessories: accessories)
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
    }

    /// Received and sent, or read and written, since midnight: History's minutes, once a minute
    /// while the tab shows (the task ends when it goes).
    private func keepTodayCurrent() async {
        // Another tab's totals don't linger while this one's load.
        today = []
        guard tab == .network || tab == .disk, let daily = history as? any DailyHistoryStore else {
            return
        }
        let pairs: [(Metric, String)] = tab == .network
            ? [(.netIn, FigureWords.receivedToday), (.netOut, FigureWords.sentToday)]
            : [(.diskRead, FigureWords.readToday), (.diskWrite, FigureWords.writtenToday)]
        while !Task.isCancelled {
            let now = Date()
            let midnight = Calendar.current.startOfDay(for: now)
            var figures: [Figure] = []
            for (metric, label) in pairs {
                let bytes = await (try? daily.systemTotal(metrics: [metric], from: midnight, to: now)) ?? 0
                figures.append(Figure(label, Formatters.bytes(bytes), help: FigureHelp.bytesTotal))
            }
            today = figures
            try? await Task.sleep(for: .seconds(60), tolerance: .seconds(10))
        }
    }
}
