import Charts
import Core
import Observation
import SwiftUI

/// One app's history (D-168): from an app row's History…, its last 7, 30 or 90 days. The
/// summary, four charts and the hours of the week it's busiest, all from History on this Mac.
@MainActor
@Observable
public final class AppHistoryModel {
    public enum Span: Int, CaseIterable, Identifiable, Sendable {
        case week = 7, month = 30, quarter = 90

        public var id: Int {
            rawValue
        }

        var title: String {
            switch self {
            case .week: String(localized: "7 days", bundle: .strings)
            case .month: String(localized: "30 days", bundle: .strings)
            case .quarter: String(localized: "90 days", bundle: .strings)
            }
        }
    }

    struct Loaded: Equatable {
        var cpu: [SeriesPoint] = []
        var memory: [SeriesPoint] = []
        var energy: [SeriesPoint] = []
        var network: [SeriesPoint] = []
        /// Every CPU point, for the week grid.
        var rhythm: [[Double?]] = []
        var cpuSummary: (average: Double, peak: Double)?
        var memorySummary: (average: Double, peak: Double)?
        var frontSeconds: Double = 0
        var crashes = 0
        var alerts = 0
        /// Today beside its usual day, once Mactivity has learned it (D-201).
        var usual: [UnusualUsage] = []
        /// How long it takes to open, lately (D-215).
        var launch: Double?

        static func == (lhs: Loaded, rhs: Loaded) -> Bool {
            lhs.cpu == rhs.cpu && lhs.memory == rhs.memory && lhs.frontSeconds == rhs.frontSeconds && lhs.crashes == rhs.crashes
        }
    }

    public var isPresented = false
    public private(set) var app: AppIdentity?
    var span = Span.month
    private(set) var loaded: Loaded?

    public init() {}

    public func open(_ app: AppIdentity) {
        self.app = app
        loaded = nil
        isPresented = true
    }

    func load(_ services: AppServices) async {
        guard let app else {
            return
        }
        let end = Date()
        let start = end.addingTimeInterval(-Double(span.rawValue) * 86400)
        let calendar = Calendar.autoupdatingCurrent
        let daily = services.history as? any DailyHistoryStore
        func series(_ metric: Metric) async -> [SeriesPoint] {
            await (try? daily?.series(metric: metric, app: app.id, from: start, to: end)) ?? []
        }
        let bucket: AppRhythm.Bucket = span == .week ? .hour : .day
        let cpu = await series(.cpu)
        let memory = await series(.memory)
        var result = Loaded()
        result.cpu = AppRhythm.bucketed(cpu, by: bucket, calendar: calendar)
        result.memory = AppRhythm.bucketed(memory, by: bucket, calendar: calendar)
        result.energy = await AppRhythm.bucketed(series(.energyImpact), by: bucket, calendar: calendar)
        let down = await series(.netIn)
        let up = await series(.netOut)
        let upByTime = Dictionary(up.map { ($0.at, $0) }, uniquingKeysWith: { first, _ in first })
        let combined = down.map { point in
            SeriesPoint(
                at: point.at, average: point.average + (upByTime[point.at]?.average ?? 0),
                maximum: point.maximum + (upByTime[point.at]?.maximum ?? 0)
            )
        }
        result.network = AppRhythm.bucketed(combined, by: bucket, calendar: calendar)
        result.rhythm = AppRhythm.week(cpu, calendar: calendar)
        result.cpuSummary = AppRhythm.summary(cpu)
        result.memorySummary = AppRhythm.summary(memory)
        let focus = services.history as? any FocusStore
        let front = await (try? focus?.focusTotals(from: start, to: end, limit: 500)) ?? []
        result.frontSeconds = front.first { $0.app.id == app.id }?.value ?? 0
        let reports = await CrashFilter.relevant(services.crashReports.reports(since: start))
        result.crashes = reports.count { $0.bundleID == app.bundleID && app.bundleID != nil || $0.appName == app.name }
        let alerts = await (try? services.alertLog.recentAlerts(limit: 2000)) ?? []
        result.alerts = alerts.count { $0.app.id == app.id && $0.firedAt >= start }
        result.usual = await Self.todayAndUsual(app, services: services, now: end)
        if let store = services.history as? any AppLaunchStore {
            let launches = await (try? store.launches(from: end.addingTimeInterval(-35 * 86400), to: end)) ?? []
            result.launch = AppLaunchTimes.byApp(launches.filter { $0.appID == app.id }, now: end).first?.recent
        }
        guard self.app == app else {
            return
        }
        loaded = result
    }
}

extension AppHistoryModel {
    /// Today's processor, memory and power beside the app's usual day, from the days Out of the
    /// ordinary already read (D-201); empty while still learning.
    static func todayAndUsual(_ app: AppIdentity, services: AppServices, now: Date) async -> [UnusualUsage] {
        guard let daily = services.history as? any DailyHistoryStore else {
            return []
        }
        await services.unusual.refresh(services, now: now)
        let today = Calendar.current.startOfDay(for: now)
        var result: [UnusualUsage] = []
        for metric in Baselines.metrics {
            guard let usual = services.unusual.usual(app.id, metric: metric) else {
                continue
            }
            let todays = await (try? daily.topApps(metric: metric, from: today, to: now, limit: 200)) ?? []
            let value = todays.first { $0.app.id == app.id }?.value ?? 0
            result.append(UnusualUsage(app: app, metric: metric, today: value, usual: usual))
        }
        return result
    }
}

struct AppHistorySheet: View {
    let services: AppServices
    @Bindable var model: AppHistoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            header
            if let loaded = model.loaded {
                if loaded.cpu.isEmpty, loaded.memory.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No history for this app yet", bundle: .strings),
                        systemImage: "clock.arrow.circlepath",
                        description: Text(
                            "Mactivity records each app while it runs. Check back once it has been open a while.",
                            bundle: .strings
                        )
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Scrolls in a small window or on a small screen (D-175).
                    ScrollView { content(loaded) }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Spacer()
                Button(String(localized: "Done", bundle: .strings)) { model.isPresented = false }
                    .keyboardShortcut(.defaultAction)
                    // Esc closes it too, as Return does: an information sheet has nothing to cancel (D-196).
                    .background {
                        Button("") { model.isPresented = false }
                            .keyboardShortcut(.cancelAction)
                            .hidden()
                    }
            }
        }
        .padding(Tokens.Spacing.l)
        // Its full size when the screen has room, smaller (the content scrolls) when it hasn't:
        // a fixed 780 × 700 was larger than a minimum-size main window (D-175).
        .frame(minWidth: 640, idealWidth: 780, maxWidth: 780, minHeight: 460, idealHeight: 700, maxHeight: 700)
        .task(id: TaskKey(app: model.app?.id, span: model.span)) {
            await model.load(services)
        }
    }

    private struct TaskKey: Hashable {
        let app: String?
        let span: AppHistoryModel.Span
    }

    private var header: some View {
        HStack(spacing: Tokens.Spacing.s) {
            if let app = model.app {
                AppIconView(app, size: 36)
                // Titled like every other sheet: the 28 pt headline over a body-size subtitle.
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    Text(app.name).font(Tokens.Typography.headline).lineLimit(1)
                    Text("History on this Mac", bundle: .strings).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Picker(String(localized: "Period", bundle: .strings), selection: $model.span) {
                ForEach(AppHistoryModel.Span.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private func content(_ loaded: AppHistoryModel.Loaded) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            HStack(spacing: Tokens.Spacing.s) {
                tile(
                    String(localized: "In front", bundle: .strings), ReportText.hours(loaded.frontSeconds),
                    note: loaded.launch.map { String(
                        localized: "Opens in \(Formatters.seconds($0))",
                        bundle: .strings,
                        comment: "App history: launch time"
                    ) }
                )
                tile(
                    String(localized: "Processor", bundle: .strings, comment: "App history tile: CPU"),
                    loaded.cpuSummary.map { Formatters.percent($0.average, fractionDigits: 1) } ?? "–",
                    note: loaded.cpuSummary.map { String(localized: "peak \(Formatters.percent($0.peak))", bundle: .strings) }
                )
                tile(
                    String(localized: "Memory", bundle: .strings),
                    loaded.memorySummary.map { Formatters.memory($0.average) } ?? "–",
                    note: loaded.memorySummary.map { String(localized: "peak \(Formatters.memory($0.peak))", bundle: .strings) }
                )
                tile(
                    String(localized: "Crashes", bundle: .strings), loaded.crashes.formatted(),
                    note: String(localized: "Alerts: \(loaded.alerts)", bundle: .strings)
                )
            }
            if !loaded.usual.isEmpty {
                UsualDayRow(usual: loaded.usual)
            }
            Grid(horizontalSpacing: Tokens.Spacing.s, verticalSpacing: Tokens.Spacing.s) {
                GridRow {
                    chart(
                        String(localized: "Processor", bundle: .strings, comment: "App history chart: CPU"),
                        loaded.cpu,
                        color: MetricTab.cpu.tint
                    ) {
                        Formatters.percent($0)
                    }
                    chart(String(localized: "Memory", bundle: .strings), loaded.memory, color: MetricTab.memory.tint) {
                        Formatters.memory($0)
                    }
                }
                GridRow {
                    chart(String(localized: "Energy Impact", bundle: .strings), loaded.energy, color: MetricTab.battery.tint) {
                        $0.formatted(.number.precision(.fractionLength(0)))
                    }
                    chart(String(localized: "Network", bundle: .strings), loaded.network, color: MetricTab.network.tint) {
                        Formatters.rate($0)
                    }
                }
            }
            WeekRhythmView(grid: loaded.rhythm)
        }
    }

    private func tile(_ title: String, _ value: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Tokens.Typography.secondary).foregroundStyle(.secondary)
            // The same figure style as Your week's tiles.
            Text(value).font(Tokens.Typography.headline).monospacedDigit().lineLimit(1)
            Text(note ?? " ").font(Tokens.Typography.secondary).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func chart(_ title: String, _ points: [SeriesPoint], color: Color, label: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text(title).font(Tokens.Typography.secondary.weight(.semibold))
            Chart(points, id: \.at) { point in
                AreaMark(x: .value("Time", point.at), y: .value(title, point.average))
                    .foregroundStyle(color.opacity(0.25))
                LineMark(x: .value("Time", point.at), y: .value(title, point.average))
                    .foregroundStyle(color)
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel { Text(label(value.as(Double.self) ?? 0)) }
                        .font(Tokens.Typography.chartLabel)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) {
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel().font(Tokens.Typography.chartLabel)
                }
            }
            .frame(height: 78)
        }
        .cardStyle()
    }
}

/// Today beside the app's usual day on this Mac (D-201): "Memory 5.5 GB today, usually 1.3 GB",
/// with the figures that stand out in the strain color.
struct UsualDayRow: View {
    let usual: [UnusualUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text("Today and its usual day", bundle: .strings, comment: "App history: today's figures beside the app's typical day")
                .font(Tokens.Typography.secondary.weight(.semibold))
            HStack(alignment: .top, spacing: Tokens.Spacing.m) {
                ForEach(usual) { usage in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(usage.metric)).font(Tokens.Typography.secondary).foregroundStyle(.secondary)
                        Text(UnusualText.figure(usage.metric, usage.today))
                            .font(Tokens.Typography.cardTitle)
                            .monospacedDigit()
                            .foregroundStyle(standsOut(usage) ? AnyShapeStyle(Tokens.Colors.strainLabel) : AnyShapeStyle(.primary))
                        Text(note(usage))
                            .font(Tokens.Typography.secondary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    /// "usually 1.3 GB", and "usually 1.3 GB · 4×" when it stands out.
    private func note(_ usage: UnusualUsage) -> String {
        let usual = UnusualText.figure(usage.metric, usage.usual)
        if standsOut(usage), let ratio = usage.ratio {
            let times = Int(ratio.rounded()).formatted()
            return String(
                localized: "usually \(usual) · \(times)×",
                bundle: .strings,
                comment: "App history: its usual day's figure, and today at so many times it"
            )
        }
        return String(localized: "usually \(usual)", bundle: .strings, comment: "App history: its usual day's figure")
    }

    private func title(_ metric: Metric) -> String {
        switch metric {
        case .memory: String(localized: "Memory", bundle: .strings)
        case .energy: String(localized: "Power", bundle: .strings, comment: "App history: power drawn")
        default: String(localized: "Processor", bundle: .strings, comment: "App history tile: CPU")
        }
    }

    /// As Out of the ordinary decides: over the floor and well past its usual.
    private func standsOut(_ usage: UnusualUsage) -> Bool {
        usage.today >= Baselines.floor(usage.metric) && usage.today >= Baselines.ratio * usage.usual
    }
}

/// When in the week an app is busiest: seven rows of 24 hours, darker where its CPU was higher.
struct WeekRhythmView: View {
    let grid: [[Double?]]

    var body: some View {
        let peak = grid.flatMap { $0 }.compactMap(\.self).max() ?? 0
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text("When it’s busiest", bundle: .strings, comment: "App history: weekday × hour grid of CPU")
                .font(Tokens.Typography.secondary.weight(.semibold))
            HStack(alignment: .top, spacing: Tokens.Spacing.xs) {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(Array(Self.weekdays.enumerated()), id: \.offset) { _, day in
                        Text(day)
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(.secondary)
                            .frame(height: 10 * Customization.shared.figureScale)
                    }
                }
                VStack(spacing: 2) {
                    ForEach(Array(grid.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 2) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Self.color(value, peak: peak))
                                    .frame(height: 10 * Customization.shared.figureScale)
                            }
                        }
                    }
                    // Each label starts at its hour's column.
                    GeometryReader { proxy in
                        ForEach([0, 6, 12, 18], id: \.self) { hour in
                            Text(Self.hourLabel(hour))
                                .font(Tokens.Typography.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .offset(x: proxy.size.width * CGFloat(hour) / 24)
                        }
                    }
                    .frame(height: 14)
                }
            }
        }
        .cardStyle()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("When it’s busiest", bundle: .strings))
    }

    static var weekdays: [String] {
        let calendar = Calendar.autoupdatingCurrent
        let symbols = calendar.veryShortWeekdaySymbols
        return (0 ..< 7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    static func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(from: DateComponents(hour: hour)) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    static func color(_ value: Double?, peak: Double) -> Color {
        guard let value, peak > 0 else {
            return Color.secondary.opacity(0.08)
        }
        return MetricTab.cpu.tint.opacity(0.15 + 0.85 * min(1, value / peak))
    }
}
