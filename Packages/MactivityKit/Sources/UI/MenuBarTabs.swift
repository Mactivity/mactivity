import Core
import SwiftUI

/// Uptime, one line per metric, the busiest apps and the day so far (spec 4.2), in the order the
/// person put them (D-241): drag a row to move it (D-242); right-click a row or a section to
/// move or hide it. Rows turned off in Settings → Menu Bar are left out.
struct CompactOverview: View {
    let services: AppServices
    /// Opens a row's tab in this window, as the rows below open their app (D-197).
    var select: (CompactTab) -> Void = { _ in }
    /// Settings → Menu Bar, where all of it can be arranged.
    var edit: () -> Void = {}

    static let uptimeSymbol = "clock"
    static let temperatureSymbol = "thermometer.medium"

    @AppStorage(PreferenceKey.overviewHiddenRows) private var hiddenRaw = ""
    @AppStorage(PreferenceKey.compactLayout) private var layout = CompactLayout.standard
    @StoredFigureChoices private var choices

    private var metrics: LiveMetrics {
        services.metrics
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            if let snapshot = metrics.snapshot {
                ForEach(layout.visibleSections) { section in
                    Group {
                        switch section {
                        case .figures: figures(snapshot)
                        case .busiest:
                            TopAppsCard(
                                title: String(localized: "Busiest right now", bundle: .strings),
                                apps: snapshot.topApps(by: .cpu, limit: 3), metric: .cpu, tab: .cpu, navigation: services.navigation
                            )
                        // The day so far at a glance; a click opens Your day (D-194).
                        case .today: TodayCard(services: services, compact: true)
                        }
                    }
                    .contextMenu { sectionMenu(section) }
                }
            } else {
                VStack(spacing: Tokens.Spacing.xs) {
                    Text("Sampling…", bundle: .strings).foregroundStyle(.secondary)
                }
                .cardStyle()
            }
        }
        .animation(Tokens.Motion.figure, value: layout)
        .animation(Tokens.Motion.figure, value: hiddenRaw)
    }

    @ViewBuilder private func figures(_ snapshot: Snapshot) -> some View {
        let rows = Self.rows(
            snapshot, hidden: OverviewRow.decodeHidden(hiddenRaw), choices: choices, hasBattery: metrics.hardware.hasBattery,
            order: layout.rows
        )
        if !rows.isEmpty {
            let values = Dictionary(uniqueKeysWithValues: rows.map { ($0.row, $0.value) })
            ReorderableStack(items: rows.map(\.row), spacing: Tokens.Spacing.xs, move: { row, index in
                layout = layout.moving(row, toIndex: index, among: rows.map(\.row))
            }, row: { row in
                self.row(row, value: values[row] ?? "")
            })
            .cardStyle()
        }
    }

    private func row(_ row: OverviewRow, value: String) -> some View {
        Group {
            if let tab = CompactTab(rawValue: row.rawValue) {
                Button {
                    select(tab)
                } label: {
                    CompactOverviewRow(label: row.title, value: value, symbol: Self.symbol(row))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(Text("Show \(row.title)", bundle: .strings, comment: "Menu bar window: opens a metric's tab"))
            } else {
                CompactOverviewRow(label: row.title, value: value, symbol: Self.symbol(row))
            }
        }
        .contextMenu {
            Button(String(localized: "Move to Top", bundle: .strings, comment: "Overview tile menu")) {
                layout = layout.rowToTop(row)
            }
            Button(String(localized: "Hide", bundle: .strings, comment: "Overview tile menu: hides the tile")) {
                var hidden = OverviewRow.decodeHidden(hiddenRaw)
                hidden.insert(row)
                hiddenRaw = OverviewRow.encodeHidden(hidden)
            }
            Divider()
            editButton
        }
    }

    @ViewBuilder private func sectionMenu(_ section: CompactSection) -> some View {
        Button(String(localized: "Move Up", bundle: .strings, comment: "Edit Overview: moves a tile earlier")) {
            layout = layout.moving(section, by: -1)
        }
        .disabled(layout.sections.first == section)
        Button(String(localized: "Move Down", bundle: .strings, comment: "Edit Overview: moves a tile later")) {
            layout = layout.moving(section, by: 1)
        }
        .disabled(layout.sections.last == section)
        Button(String(localized: "Hide", bundle: .strings, comment: "Overview tile menu: hides the tile")) {
            layout = layout.showing(section, false)
        }
        Divider()
        editButton
    }

    private var editButton: some View {
        Button(
            String(localized: "Edit Menu Bar Window…", bundle: .strings, comment: "Opens Settings → Menu Bar to arrange the window"),
            action: edit
        )
    }

    /// The rows shown, in order, with their figures. Temperature only when the Mac has the sensor,
    /// Battery only when it has a battery.
    static func rows(
        _ snapshot: Snapshot, hidden: Set<OverviewRow>, choices: FigureChoices, hasBattery: Bool = true,
        order: [OverviewRow] = OverviewRow.allCases
    ) -> [(row: OverviewRow, value: String)] {
        order.filter { !hidden.contains($0) }.compactMap { row in
            switch row {
            case .battery where !hasBattery:
                return nil
            case .uptime:
                return (row, Formatters.duration(snapshot.system.uptime))
            case .temperature:
                return choices.temperature.celsius(snapshot.system.sensors).map { (row, Formatters.temperature(celsius: $0)) }
            default:
                return row.tab.map { (row, value($0, snapshot, choices: choices)) }
            }
        }
    }

    /// The figure and its short caption. No trailing space when there's no caption: the values
    /// are trailing-aligned, and a space would push that row's figure 3 pt left of the others.
    static func value(_ tab: MetricTab, _ snapshot: Snapshot, choices: FigureChoices = .automatic) -> String {
        tab.rowValue(snapshot, choices: choices)
    }

    static func symbol(_ row: OverviewRow) -> String {
        switch row {
        case .uptime: uptimeSymbol
        case .temperature: temperatureSymbol
        default: row.tab?.symbol ?? uptimeSymbol
        }
    }
}

/// One line of the compact overview: symbol and name on the left, the figure on the right.
struct CompactOverviewRow: View {
    let label: String
    let value: String
    let symbol: String

    var body: some View {
        HStack {
            Label {
                Text(label)
            } icon: {
                // Fixed-size symbols, so every title starts at the same x.
                RowSymbol(symbol)
            }
            .labelStyle(.centeredIcon)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            Spacer()
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(Tokens.Typography.body)
        // One whole-point height for every row. A symbol's baseline depends on the symbol, so
        // baseline-aligned rows came out a fraction of a point apart.
        .frame(height: Tokens.Layout.compactRowHeight)
    }
}

/// Headline, 3–4 secondary figures, top 5 apps (spec 4.2).
struct CompactMetricView: View {
    let tab: MetricTab
    let services: AppServices

    private var metrics: LiveMetrics {
        services.metrics
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HeadlineCard(tab, metrics: metrics, compact: true)
            if let snapshot = metrics.snapshot {
                SecondaryFiguresCard(figures: Array(tab.figures(snapshot).prefix(4)), columns: 2)
                TopAppsCard(
                    // The list is by Energy Impact (`MetricTab.appMetric`), as in the main window.
                    title: tab == .battery
                        ? String(localized: "Energy Impact by app", bundle: .strings)
                        : String(localized: "Top apps", bundle: .strings),
                    apps: snapshot.topApps(by: tab.appMetric, limit: 5),
                    metric: tab.appMetric,
                    total: AppListView.shareTotal(snapshot.apps, metric: tab.appMetric),
                    tab: tab,
                    navigation: services.navigation
                )
            }
        }
        // Its top apps change every tick; elsewhere per-app GPU is read every 3 s (D-086).
        .onAppear { metrics.showsPerAppGPU = tab == .gpu }
        .onChange(of: tab) { _, tab in metrics.showsPerAppGPU = tab == .gpu }
        .onDisappear { metrics.showsPerAppGPU = false }
    }
}

/// Click an app to open the main window on this metric's tab with the app highlighted.
struct TopAppsCard: View {
    let title: String
    let apps: [AppAggregate]
    let metric: Metric
    /// All apps' Energy Impact, for shares (D-112); nil for metrics with units.
    var total: Double?
    let tab: MetricTab
    let navigation: AppNavigation

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            CardHeader(title: title, symbol: Tokens.Symbols.apps, status: nil, tint: tab.tint)
            ForEach(apps) { app in
                Button {
                    navigation.show(tab.sidebarItem, highlighting: app.app.id)
                } label: {
                    HStack(spacing: Tokens.Spacing.xs) {
                        AppIconView(app.app)
                        Text(app.app.name)
                            .lineLimit(1)
                        Spacer()
                        Text(AppListView.valueText(app.value(for: metric), metric: metric, total: total))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("Show \(app.app.name) in Mactivity", bundle: .strings))
            }
        }
        .cardStyle()
    }
}
