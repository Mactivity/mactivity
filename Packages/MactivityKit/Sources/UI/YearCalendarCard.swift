import Charts
import Core
import SwiftUI

/// A year at a glance (D-093): one square per day, stronger for a busier day, weeks as columns.
/// Pick a day to see its hours and its busiest apps.
struct YearCalendarCard: View {
    let store: any DailyHistoryStore
    let generation: Int
    /// For Your day under the selected day (D-191); none in tests that only draw the calendar.
    var services: AppServices?

    @State private var choice: CalendarMetric = .cpu
    @State private var values: [Date: DayValue] = [:]
    @State private var hovered: Date?
    @State private var selected: Date?
    @State private var dayBins: [HistoryBin] = []
    @State private var dayApps: [AppTotal] = []
    @State private var width: CGFloat = 0
    @Environment(\.colorSchemeContrast) private var contrast

    private let calendar = Calendar.autoupdatingCurrent

    var body: some View {
        let layout = YearCalendarLayout(today: Date(), calendar: calendar, width: width)
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack {
                Picker(
                    String(localized: "Metric", bundle: .strings, comment: "Year calendar: which figure colors the days"),
                    selection: $choice
                ) {
                    ForEach(CalendarMetric.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Text(caption(for: hovered ?? selected))
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            grid(layout)
            legend
            Divider()
            dayDetail
        }
        .cardStyle()
        .task(id: LoadKey(choice: choice, generation: generation)) { await loadDays() }
        .task(id: DayKey(choice: choice, day: selected, generation: generation)) { await loadDay() }
        // A day asked for from elsewhere (Today so far, D-194).
        .onChange(of: services?.navigation.historyDay, initial: true) { _, day in
            if let day {
                selected = calendar.startOfDay(for: day)
            }
        }
    }

    // MARK: Grid

    private func grid(_ layout: YearCalendarLayout) -> some View {
        let maximum = values.values.map(\.average).max() ?? 0
        return Canvas { context, _ in
            for (label, x) in layout.monthLabels {
                context.draw(
                    Text(label).font(Tokens.Typography.caption).foregroundStyle(.secondary),
                    at: CGPoint(x: x, y: 0), anchor: .topLeading
                )
            }
            for (label, y) in layout.weekdayLabels {
                context.draw(
                    Text(label).font(Tokens.Typography.caption).foregroundStyle(.secondary),
                    at: CGPoint(x: 0, y: y), anchor: .leading
                )
            }
            for cell in layout.cells {
                let rect = layout.rect(cell)
                let path = Path(roundedRect: rect, cornerRadius: rect.width * 0.2)
                context.fill(path, with: .color(fill(values[cell.day], maximum: maximum)))
                if contrast == .increased {
                    context.stroke(path, with: .color(.primary.opacity(0.25)), lineWidth: 0.5)
                }
                if cell.day == selected {
                    context.stroke(path, with: .color(.primary), lineWidth: 1.5)
                }
            }
        }
        .frame(height: layout.height)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onContinuousHover { phase in
            if case let .active(point) = phase {
                hovered = layout.day(at: point)
            } else {
                hovered = nil
            }
        }
        .onTapGesture { point in
            if let day = layout.day(at: point) {
                selected = day
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Year calendar", bundle: .strings))
        .accessibilityValue(caption(for: selected))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 1 : -1
            let today = calendar.startOfDay(for: Date())
            if let day = calendar.date(byAdding: .day, value: step, to: selected ?? today), day <= today {
                selected = day
            }
        }
    }

    /// No data: a faint square. Otherwise four steps of the metric's color by the day's share of
    /// the year's busiest.
    private func fill(_ value: DayValue?, maximum: Double) -> Color {
        guard let value, maximum > 0 else {
            return .primary.opacity(contrast == .increased ? 0.14 : 0.07)
        }
        return choice.tint.opacity(Self.opacity(level: Self.level(value.average, maximum: maximum)))
    }

    /// 1…4 by quarters of the busiest day.
    nonisolated static func level(_ value: Double, maximum: Double) -> Int {
        guard maximum > 0 else {
            return 1
        }
        return min(4, max(1, Int((value / maximum * 4).rounded(.up))))
    }

    nonisolated static func opacity(level: Int) -> Double {
        [0.22, 0.45, 0.7, 1][min(3, max(0, level - 1))]
    }

    private var legend: some View {
        HStack(spacing: 3) {
            Spacer()
            Text("Less", bundle: .strings, comment: "Year calendar legend: lighter squares")
            ForEach(1 ... 4, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(choice.tint.opacity(Self.opacity(level: level)))
                    .frame(width: 10, height: 10)
            }
            Text("More", bundle: .strings, comment: "Year calendar legend: stronger squares")
        }
        .font(Tokens.Typography.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    // MARK: A day

    /// The day before and after, and back to today (D-191): Your day without hunting for a square.
    private func dayStepper(_ day: Date) -> some View {
        let today = calendar.startOfDay(for: Date())
        let earliest = calendar.date(byAdding: .day, value: -(YearCalendarLayout.days - 1), to: today) ?? today
        return ControlGroup {
            Button {
                step(-1, from: day, earliest: earliest, today: today)
            } label: {
                Label(String(localized: "Previous Day", bundle: .strings), systemImage: "chevron.left")
            }
            .disabled(day <= earliest)
            Button(String(localized: "Today", bundle: .strings, comment: "Year calendar: go back to today")) { selected = today }
                .disabled(calendar.isDate(day, inSameDayAs: today))
            Button {
                step(1, from: day, earliest: earliest, today: today)
            } label: {
                Label(String(localized: "Next Day", bundle: .strings), systemImage: "chevron.right")
            }
            .disabled(day >= today)
        }
        .controlSize(.small)
        .fixedSize()
    }

    private func step(_ days: Int, from day: Date, earliest: Date, today: Date) {
        if let next = calendar.date(byAdding: .day, value: days, to: day), next >= earliest, next <= today {
            selected = next
        }
    }

    @ViewBuilder private var dayDetail: some View {
        if let selected {
            HStack(alignment: .top, spacing: Tokens.Spacing.m) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    HStack(spacing: Tokens.Spacing.xs) {
                        Text(selected.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                            .font(Tokens.Typography.cardTitle)
                        Spacer(minLength: Tokens.Spacing.s)
                        dayStepper(selected)
                    }
                    if dayBins.isEmpty {
                        Text("Nothing recorded this day.", bundle: .strings)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 110, alignment: .center)
                    } else {
                        Chart(dayBins, id: \.start) { bin in
                            BarMark(
                                x: .value(HistoryStrip.fromAxis, bin.start, unit: .hour),
                                y: .value(HistoryStrip.averageAxis, bin.average)
                            )
                            .foregroundStyle(choice.tint)
                        }
                        .chartXScale(domain: selected ...
                            (calendar.date(byAdding: .day, value: 1, to: selected) ?? selected.addingTimeInterval(86400)))
                        .chartXAxis {
                            AxisMarks(values: .stride(by: .hour, count: 6)) {
                                AxisGridLine()
                                AxisValueLabel(format: .dateTime.hour()).font(Tokens.Typography.chartLabel)
                            }
                        }
                        .chartYAxis {
                            AxisMarks { value in
                                AxisGridLine()
                                AxisValueLabel { Text(choice.format(value.as(Double.self))) }.font(Tokens.Typography.chartLabel)
                            }
                        }
                        .frame(height: 110)
                    }
                }
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    Text("Busiest apps", bundle: .strings, comment: "Year calendar: the selected day's top apps")
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                    // At the size of the strips' Top apps lists below.
                    ForEach(dayApps, id: \.app.id) { total in
                        HStack(spacing: Tokens.Spacing.xs) {
                            AppIconView(total.app, size: Tokens.IconSize.small)
                            Text(total.app.name).lineLimit(1)
                            Spacer(minLength: Tokens.Spacing.xs)
                            Text(choice.format(total.value))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(Tokens.Typography.secondary)
                    }
                    // A day without per-app figures: say so rather than leave the heading alone.
                    if dayApps.isEmpty {
                        Text(
                            "No apps recorded this day",
                            bundle: .strings,
                            comment: "Year calendar: the selected day has no per-app figures"
                        )
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: Tokens.Layout.historyTopAppsWidth, alignment: .leading)
            }
            if let services {
                Divider()
                DayTimeline(services: services, day: selected, generation: generation)
            }
        }
    }

    /// Disk and Network: read plus write (in plus out) at each time, averages and peaks alike.
    nonisolated static func sum(_ series: [[SeriesPoint]]) -> [SeriesPoint] {
        guard series.count > 1 else {
            return series.first ?? []
        }
        var byTime: [Date: (average: Double, maximum: Double)] = [:]
        for point in series.joined() {
            let previous = byTime[point.at] ?? (0, 0)
            byTime[point.at] = (previous.average + point.average, previous.maximum + point.maximum)
        }
        return byTime.map { SeriesPoint(at: $0.key, average: $0.value.average, maximum: $0.value.maximum) }
            .sorted { $0.at < $1.at }
    }

    /// "Tue, Sep 3 · 23% average · peak 87%" for the pointed-at or selected day.
    private func caption(for day: Date?) -> String {
        guard let day else {
            return String(localized: "Pick a day to see its hours and busiest apps.", bundle: .strings)
        }
        let date = day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        guard let value = values[day] else {
            return String(localized: "\(date) · nothing recorded", bundle: .strings, comment: "Year calendar: a day without data")
        }
        return String(
            localized: "\(date) · \(choice.format(value.average)) average · peak \(choice.format(value.maximum))",
            bundle: .strings,
            comment: "Year calendar: a day, its average and its peak"
        )
    }

    // MARK: Loading

    private struct LoadKey: Hashable {
        let choice: CalendarMetric
        let generation: Int
    }

    private struct DayKey: Hashable {
        let choice: CalendarMetric
        let day: Date?
        let generation: Int
    }

    private func loadDays() async {
        var merged: [Date: DayValue] = [:]
        for metric in choice.metrics {
            let days = await (try? store.dailyValues(metric: metric, days: YearCalendarLayout.days)) ?? []
            for value in days {
                let previous = merged[value.day]
                merged[value.day] = DayValue(
                    day: value.day,
                    average: (previous?.average ?? 0) + value.average,
                    maximum: (previous?.maximum ?? 0) + value.maximum
                )
            }
        }
        guard !Task.isCancelled else {
            return
        }
        values = merged
        if selected == nil {
            selected = calendar.startOfDay(for: Date())
        }
    }

    private func loadDay() async {
        guard let day = selected, let end = calendar.date(byAdding: .day, value: 1, to: day) else {
            return
        }
        var series: [[SeriesPoint]] = []
        for metric in choice.metrics {
            await series.append((try? store.series(metric: metric, app: nil, from: day, to: end)) ?? [])
        }
        // One bar per hour, in local time.
        let bins = HistoryBinning.bins(Self.sum(series), interval: 3600, timeZone: calendar.timeZone)
        let apps = await (try? store.topApps(metric: choice.metrics[0], from: day, to: end, limit: 5)) ?? []
        guard !Task.isCancelled else {
            return
        }
        dayBins = bins
        dayApps = apps
    }
}

/// What colors the calendar. Disk and Network add their two directions.
enum CalendarMetric: String, CaseIterable, Identifiable, Hashable {
    case cpu, gpu, memory, disk, network

    var id: String {
        rawValue
    }

    var metrics: [Metric] {
        switch self {
        case .cpu: [.cpu]
        case .gpu: [.gpu]
        case .memory: [.memory]
        case .disk: [.diskRead, .diskWrite]
        case .network: [.netIn, .netOut]
        }
    }

    private var tab: MetricTab {
        switch self {
        case .cpu: .cpu
        case .gpu: .gpu
        case .memory: .memory
        case .disk: .disk
        case .network: .network
        }
    }

    var title: String {
        tab.title(hasBattery: true)
    }

    var tint: Color {
        tab.tint
    }

    func format(_ value: Double?) -> String {
        Formatters.metric(value, metrics[0])
    }
}

/// Where each day's square goes: the weeks of the last year as columns, ending with this week,
/// weekdays as rows in the locale's order, month names over the columns where a month starts.
struct YearCalendarLayout {
    static let days = 365
    static let columns = 53
    static let labelWidth: CGFloat = 28
    static let monthHeight: CGFloat = 16
    static let gap: CGFloat = 3
    static let maxSide: CGFloat = 14

    struct Cell: Hashable {
        let day: Date
        let column: Int
        let row: Int
    }

    let cells: [Cell]
    let side: CGFloat
    /// Side plus gap. Fits the width, always: at the minimum window a 6 pt floor on the side ran
    /// the last weeks (and today's ring) past the card's edge.
    let pitch: CGFloat
    let monthLabels: [(String, CGFloat)]
    let weekdayLabels: [(String, CGFloat)]

    init(today: Date, calendar: Calendar, width: CGFloat) {
        let columns = Self.columns
        // A point spare on the right for the selected day's ring.
        let pitch = max(4, min(Self.maxSide + Self.gap, (width - Self.labelWidth - 1) / CGFloat(columns)))
        self.pitch = pitch
        side = pitch - min(Self.gap, pitch * 0.25)
        let end = calendar.startOfDay(for: today)
        let weekday = (calendar.component(.weekday, from: end) - calendar.firstWeekday + 7) % 7
        let firstColumnStart = calendar.date(byAdding: .day, value: -(weekday + (columns - 1) * 7), to: end) ?? end
        let earliest = calendar.date(byAdding: .day, value: -(Self.days - 1), to: end) ?? end
        var cells: [Cell] = []
        var months: [(String, CGFloat)] = []
        for column in 0 ..< columns {
            for row in 0 ..< 7 {
                guard let day = calendar.date(byAdding: .day, value: column * 7 + row, to: firstColumnStart),
                      day >= earliest, day <= end
                else {
                    continue
                }
                cells.append(Cell(day: day, column: column, row: row))
                if calendar.component(.day, from: day) == 1 {
                    months.append((day.formatted(.dateTime.month(.abbreviated)), Self.labelWidth + CGFloat(column) * pitch))
                }
            }
        }
        self.cells = cells
        monthLabels = months
        // Every other weekday, like a wall calendar's margin: the second, fourth and sixth rows.
        let symbols = calendar.veryShortWeekdaySymbols
        let middle = side / 2
        weekdayLabels = [1, 3, 5].map { row in
            let index = (calendar.firstWeekday - 1 + row) % 7
            return (symbols[index], Self.monthHeight + CGFloat(row) * pitch + middle)
        }
    }

    var height: CGFloat {
        Self.monthHeight + 7 * pitch
    }

    func rect(_ cell: Cell) -> CGRect {
        CGRect(
            x: Self.labelWidth + CGFloat(cell.column) * pitch,
            y: Self.monthHeight + CGFloat(cell.row) * pitch,
            width: side,
            height: side
        )
    }

    func day(at point: CGPoint) -> Date? {
        let column = Int(((point.x - Self.labelWidth) / pitch).rounded(.down))
        let row = Int(((point.y - Self.monthHeight) / pitch).rounded(.down))
        return cells.first { $0.column == column && $0.row == row }?.day
    }
}
