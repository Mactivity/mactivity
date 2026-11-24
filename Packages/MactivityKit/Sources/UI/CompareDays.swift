import Core
import Observation
import SwiftUI

/// Compare (D-207): two days, or the weeks ending on them, side by side: time in use, slowdowns,
/// alerts, the Mac's average processor, memory and power, data, disk writes, and the apps that
/// changed most. Opened from Your day and Quick Search.
@MainActor
@Observable
public final class CompareModel {
    public enum Span: Int, CaseIterable, Identifiable, Sendable {
        case day = 1, week = 7

        public var id: Int {
            rawValue
        }

        var title: String {
            switch self {
            case .day: String(localized: "Days", bundle: .strings, comment: "Compare: two single days")
            case .week: String(localized: "Weeks", bundle: .strings, comment: "Compare: the weeks ending on two days")
            }
        }
    }

    /// One period's figures. Nil where history has nothing.
    struct Side: Equatable {
        var inUse: Double = 0
        var slowdowns = 0
        var alerts = 0
        var cpu: Double?
        var memory: Double?
        var power: Double?
        var received: Double?
        var sent: Double?
        var written: Double?
        var apps: [Metric: [AppTotal]] = [:]
    }

    public var isPresented = false
    var first = Date()
    var second = Date()
    /// Switching to weeks puts the second week before the first rather than one day before it,
    /// where the two would share six days; and back.
    var span = Span.day {
        didSet {
            guard span != oldValue, let moved = Calendar.current.date(byAdding: .day, value: -span.rawValue, to: first) else {
                return
            }
            second = moved
        }
    }

    private(set) var sides: (first: Side, second: Side)?
    /// Render tests: these figures, never read.
    @ObservationIgnored private var isFixed = false

    public init() {}

    /// Already worked out: render tests.
    init(first: Date, second: Date, sides: (Side, Side)) {
        self.first = first
        self.second = second
        self.sides = sides
        isFixed = true
    }

    /// `day` beside the day before it.
    public func open(day: Date) {
        let calendar = Calendar.current
        first = calendar.startOfDay(for: day)
        second = calendar.date(byAdding: .day, value: -1, to: first) ?? first
        span = .day
        sides = nil
        isPresented = true
    }

    func load(_ services: AppServices) async {
        guard !isFixed else {
            return
        }
        let now = Date()
        let key = (first, second, span)
        let a = await Self.side(services, DayComparison.interval(ending: first, days: span.rawValue, now: now), now: now)
        let b = await Self.side(services, DayComparison.interval(ending: second, days: span.rawValue, now: now), now: now)
        guard key == (first, second, span) else {
            return
        }
        sides = (a, b)
    }

    func shifts(_ metric: Metric) -> [AppShift] {
        guard let sides else {
            return []
        }
        return DayComparison.shifts(metric: metric, first: sides.first.apps[metric] ?? [], second: sides.second.apps[metric] ?? [])
    }

    private static func side(_ services: AppServices, _ period: DateInterval, now: Date) async -> Side {
        var side = Side()
        let calendar = Calendar.current
        var day = period.start
        while day < period.end, let next = calendar.date(byAdding: .day, value: 1, to: day) {
            let result = await DayStoryLoader.load(services, day: day, now: now)
            side.inUse += result.activeSeconds
            side.slowdowns += DayComparison.slowdowns(result)
            side.alerts += DayComparison.alerts(result)
            day = next
        }
        guard let daily = services.history as? any DailyHistoryStore, period.duration > 0 else {
            return side
        }
        func average(_ metric: Metric) async -> Double? {
            let points = await (try? daily.series(metric: metric, app: nil, from: period.start, to: period.end)) ?? []
            return points.isEmpty ? nil : points.reduce(0) { $0 + $1.average } / Double(points.count)
        }
        func total(_ metric: Metric) async -> Double? {
            let value = await (try? daily.systemTotal(metrics: [metric], from: period.start, to: period.end)) ?? 0
            return value > 0 ? value : nil
        }
        side.cpu = await average(.cpu)
        side.memory = await average(.memory)
        side.power = await average(.energy)
        side.received = await total(.netIn)
        side.sent = await total(.netOut)
        side.written = await total(.diskWrite)
        for metric in [Metric.cpu, .memory] {
            side.apps[metric] = await (try? daily.topApps(metric: metric, from: period.start, to: period.end, limit: 30)) ?? []
        }
        return side
    }
}

struct CompareSheet: View {
    let services: AppServices
    @Bindable var model: CompareModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Compare", bundle: .strings, comment: "Sheet title: two days or weeks side by side")
                    .font(Tokens.Typography.headline)
                Spacer()
                Picker(String(localized: "Compare", bundle: .strings), selection: $model.span) {
                    ForEach(CompareModel.Span.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                    figures
                    if model.sides != nil {
                        HStack(alignment: .top, spacing: Tokens.Spacing.s) {
                            shiftList(.cpu, title: String(localized: "Processor", bundle: .strings, comment: "App history tile: CPU"))
                            shiftList(.memory, title: String(localized: "Memory", bundle: .strings))
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button(String(localized: "Done", bundle: .strings)) { model.isPresented = false }
                    .keyboardShortcut(.defaultAction)
                    // Esc closes it too: an information sheet has nothing to cancel (D-196).
                    .background {
                        Button("") { model.isPresented = false }
                            .keyboardShortcut(.cancelAction)
                            .hidden()
                    }
            }
        }
        .padding(Tokens.Spacing.l)
        .frame(minWidth: 600, idealWidth: 720, maxWidth: 760, minHeight: 440, idealHeight: 620, maxHeight: 680)
        .task(id: TaskKey(first: model.first, second: model.second, span: model.span)) {
            await model.load(services)
        }
    }

    private struct TaskKey: Hashable {
        let first: Date
        let second: Date
        let span: CompareModel.Span
    }

    private var figures: some View {
        Grid(alignment: .leading, horizontalSpacing: Tokens.Spacing.l, verticalSpacing: Tokens.Spacing.s) {
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                picker($model.first)
                picker($model.second)
                Text("Change", bundle: .strings, comment: "Compare: the difference between the two")
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            if let sides = model.sides {
                ForEach(Self.rows(sides.first, sides.second), id: \.label) { row in
                    GridRow {
                        Text(row.label).foregroundStyle(.secondary)
                        Text(row.first).monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.second).monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.change).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            } else {
                GridRow {
                    ProgressView().controlSize(.small).gridCellColumns(4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func picker(_ date: Binding<Date>) -> some View {
        DatePicker(
            String(localized: "Day", bundle: .strings, comment: "Chart axis: calendar day"),
            selection: date, in: ...Date(), displayedComponents: .date
        )
        .labelsHidden()
        .datePickerStyle(.compact)
        .fixedSize()
    }

    struct Row {
        let label: String
        let first: String
        let second: String
        let change: String
    }

    /// Each figure's two values and the change from the second to the first (the first is the
    /// day you came from, the second what it's compared with).
    nonisolated static func rows(_ a: CompareModel.Side, _ b: CompareModel.Side) -> [Row] {
        func row(_ label: String, _ x: Double?, _ y: Double?, _ format: (Double) -> String) -> Row {
            Row(label: label, first: x.map(format) ?? "–", second: y.map(format) ?? "–", change: change(x, y))
        }
        func count(_ label: String, _ x: Int, _ y: Int) -> Row {
            let difference = x - y
            return Row(
                label: label, first: x.formatted(), second: y.formatted(),
                change: difference == 0 ? "–" : difference.formatted(.number.sign(strategy: .always()))
            )
        }
        return [
            row(String(localized: "Time in use", bundle: .strings), a.inUse, b.inUse) { YourWeekContent.hours($0) },
            count(String(localized: "Slowdowns", bundle: .strings, comment: "Compare: slowdowns in the period"), a.slowdowns, b.slowdowns),
            count(String(localized: "Alerts", bundle: .strings), a.alerts, b.alerts),
            row(String(localized: "Processor", bundle: .strings, comment: "App history tile: CPU"), a.cpu, b.cpu) {
                Formatters.percent($0, fractionDigits: 1)
            },
            row(String(localized: "Memory", bundle: .strings), a.memory, b.memory) { Formatters.memory($0) },
            row(String(localized: "Power", bundle: .strings, comment: "App history: power drawn"), a.power, b.power) {
                Formatters.power(milliwatts: $0)
            },
            row(String(localized: "Data received", bundle: .strings, comment: "Compare: network data received"), a.received, b.received) {
                Formatters.bytes($0)
            },
            row(String(localized: "Data sent", bundle: .strings, comment: "Compare: network data sent"), a.sent, b.sent) {
                Formatters.bytes($0)
            },
            row(String(localized: "Written to disk", bundle: .strings, comment: "Compare: data written to disk"), a.written, b.written) {
                Formatters.bytes($0)
            },
        ]
    }

    /// "+33%", "−10%", or "–" when either side is missing or the change is under 1%.
    nonisolated static func change(_ first: Double?, _ second: Double?) -> String {
        guard let first, let second, second > 0 else {
            return "–"
        }
        let fraction = first / second - 1
        guard abs(fraction) >= 0.01 else {
            return "–"
        }
        return fraction.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always()))
    }

    private func shiftList(_ metric: Metric, title: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text(title).font(Tokens.Typography.secondary.weight(.semibold))
            let shifts = model.shifts(metric)
            if shifts.isEmpty {
                Text("No app changed much.", bundle: .strings, comment: "Compare: apps' figures were alike in both")
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
            ForEach(shifts) { shift in
                Button {
                    services.appHistory.open(shift.app)
                } label: {
                    HStack(spacing: Tokens.Spacing.s) {
                        AppIconView(shift.app, size: Tokens.IconSize.small)
                        Text(shift.app.name).lineLimit(1)
                        Spacer(minLength: Tokens.Spacing.xs)
                        Text(verbatim: "\(UnusualText.figure(metric, shift.first)) · \(UnusualText.figure(metric, shift.second))")
                            .font(Tokens.Typography.secondary)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .cardStyle()
    }
}
