import Charts
import Core
import SwiftUI

/// History strip (spec 4.3 step 3): the metric over the toolbar's range as bars, scrubbable, with
/// the top apps for that range beneath it.
///
/// The points are binned first (`HistoryBinning`): thirty days of quarter-hour points is about
/// 2,900, and a strip draws at most `Tokens.Layout.historyMaxBars` bars, fewer when it's narrow.
struct HistoryStrip: View {
    /// What a strip draws: one or more series, and optionally the top apps for the range.
    struct Spec: Hashable {
        let id: String
        let title: String
        let metrics: [Metric]
        let topAppsMetric: Metric?
        /// Mark where thermal pressure reached "serious" or worse (expansion E8).
        var marksThrottling = false
        /// The bars' color (D-057).
        let tint: Color

        init(tab: MetricTab, hasBattery: Bool = true) {
            id = tab.rawValue
            title = tab.title(hasBattery: hasBattery)
            // On a laptop the Battery tab charts the charge: a line anyone reads at a glance,
            // where Energy Impact's unitless score isn't (D-105). Its apps stay by energy.
            metrics = tab == .battery && hasBattery ? [.batteryLevel] : tab.historyMetrics
            topAppsMetric = tab.appMetric
            marksThrottling = tab == .cpu
            tint = tab.tint
        }

        init(id: String, title: String, metrics: [Metric], topAppsMetric: Metric? = nil, tint: Color = Tokens.Colors.chartDefault) {
            self.id = id
            self.title = title
            self.metrics = metrics
            self.topAppsMetric = topAppsMetric
            self.tint = tint
        }
    }

    let spec: Spec
    let range: HistoryRange
    let services: AppServices
    /// Alert threshold to draw as a rule line, in the first metric's units.
    var threshold: Double?
    /// "History" above the chart. The History tab turns it off: each strip already sits under
    /// its metric's heading there.
    var showsTitle = true

    init(tab: MetricTab, range: HistoryRange, services: AppServices, threshold: Double? = nil, showsTitle: Bool = true) {
        self.init(
            spec: TabSpecs.spec(tab: tab, hasBattery: services.metrics.hardware.hasBattery),
            range: range,
            services: services,
            threshold: threshold,
            showsTitle: showsTitle
        )
    }

    init(spec: Spec, range: HistoryRange, services: AppServices, threshold: Double? = nil, showsTitle: Bool = true) {
        self.spec = spec
        self.range = range
        self.services = services
        self.threshold = threshold
        self.showsTitle = showsTitle
    }

    /// With a moment already pinned: render tests.
    init(tab: MetricTab, range: HistoryRange, services: AppServices, pinned: DateInterval) {
        self.init(tab: tab, range: range, services: services)
        _pinned = State(initialValue: HistoryBin(start: pinned.start, end: pinned.end, average: 0, maximum: 0))
    }

    /// Points as the store returned them, and the bars made from them.
    @State private var series: [Metric: [SeriesPoint]] = [:]
    /// The whole Mac's power over the range, beside the charge line (D-258).
    @State private var power: PowerSummary?
    @State private var thermal: [SeriesPoint] = []
    @State private var notes: [HistoryNote] = []
    @State private var bars = Bars()
    /// The chart's width, which decides how many bars fit.
    @State private var chartWidth: CGFloat = 0

    /// VoiceOver's summary of the range: average, and the peak and when. Made when the points load.
    @State private var spokenSummary = ""
    @State var topApps: [AppTotal] = []
    @State var changes: [AppIdentity.ID: PeriodChange] = [:]
    @AppStorage(PreferenceKey.historyComparesPrevious) var comparesPrevious = false
    /// A bar clicked to see the apps behind that moment (D-190), and those apps once loaded.
    @State var pinned: HistoryBin?
    @State var momentApps: [AppTotal]?
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var selection: Date?
    /// When the points were loaded: the chart spans the range up to here, whatever the data covers.
    @State private var loadedAt = Date()
    /// Which strip and range the points are for.
    @State private var loadedFor: String?

    private var loadKey: String {
        "\(spec.id) \(range)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.m) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                HStack {
                    if showsTitle {
                        Text("History", bundle: .strings, comment: "History strip title")
                            .font(Tokens.Typography.cardTitle)
                    }
                    Spacer()
                    Text(caption)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .help(Self.captionHelp(spec.metrics.first))
                    if let power, selectedBin == nil {
                        Text(Self.powerCaption(power, range: range))
                            .font(Tokens.Typography.secondary)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .help(Self.powerHelp)
                    }
                }
                if series.values.allSatisfy(\.isEmpty) {
                    ContentUnavailableView {
                        Label(String(localized: "No history yet", bundle: .strings), systemImage: "clock")
                    } description: {
                        Text("Mactivity records a point every minute. Check back soon.", bundle: .strings)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    chart
                    if spec.metrics.count > 1 {
                        legend
                    }
                }
            }
            if spec.topAppsMetric != nil {
                topAppsList
                    .frame(width: Tokens.Layout.historyTopAppsWidth)
            }
        }
        .cardStyle()
        // Reloads while someone can see it: a covered or minimized window samples at the idle
        // cadence (D-061), and the strip waits until it shows again, then reloads at once (D-086).
        .task(id: pinned?.start) { await loadMoment() }
        .onChange(of: range) { pinned = nil }
        .task(id: TaskKey(
            spec: spec.id, range: range, generation: services.historyGeneration, compares: comparesPrevious,
            isShown: services.metrics.cadence == .visible
        )) {
            await reloadForever(isShown: services.metrics.cadence == .visible)
        }
    }

    private struct TaskKey: Hashable {
        let spec: String
        let range: HistoryRange
        let generation: Int
        let compares: Bool
        let isShown: Bool
    }

    /// Binned bars and the thermal spans, rebuilt when the points or the bar width change.
    private struct Bars {
        var interval: TimeInterval = 0
        var bins: [Metric: [HistoryBin]] = [:]
        var throttled: [HistorySpan] = []
    }

    private var chart: some View {
        let count = spec.metrics.count
        return Chart {
            ForEach(bars.throttled, id: \.start) { span in
                RectangleMark(xStart: .value(Self.fromAxis, span.start), xEnd: .value(Self.toAxis, span.end))
                    .foregroundStyle(Tokens.Colors.strainFill(contrast))
                    .annotation(position: .top, alignment: .center, spacing: 0) {
                        Image(systemName: "thermometer.high")
                            .font(Tokens.Typography.secondary)
                            .foregroundStyle(Tokens.Colors.strain)
                            .accessibilityLabel(Text("Thermal pressure was high", bundle: .strings))
                    }
            }
            ForEach(Array(spec.metrics.enumerated()), id: \.element) { index, metric in
                ForEach(bars.bins[metric] ?? [], id: \.start) { bin in
                    barMarks(bin, series: index, of: count)
                }
            }
            if let threshold = Self.visibleThreshold(threshold, plottedPeak: plottedPeak) {
                RuleMark(y: .value(Self.thresholdAxis, threshold))
                    .foregroundStyle(Tokens.Colors.threshold)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            noteMarks(notes)
            if let selected = selectedBin {
                RuleMark(x: .value(Self.selectedAxis, selected.middle))
                    .foregroundStyle(.secondary)
            }
        }
        // The whole range, always: a metric with only minutes of data (new since an update, or
        // a fresh install) otherwise stretched them across the strip, every label "6 PM".
        .chartXScale(domain: loadedAt.addingTimeInterval(-TimeInterval(range.duration.components.seconds)) ... loadedAt)
        // The pointer, read directly: hovering scrubs the caption, a click pins that bar and
        // Top apps shows the apps behind it (D-190).
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(.rect)
                    .onContinuousHover { phase in
                        if case let .active(point) = phase {
                            selection = Self.date(at: point, proxy: proxy, geometry: geometry)
                        } else {
                            selection = nil
                        }
                    }
                    .help(Text("Click a bar to see the apps behind it", bundle: .strings, comment: "History chart tooltip (D-190)"))
                    .onTapGesture { point in
                        guard let date = Self.date(at: point, proxy: proxy, geometry: geometry), let first = spec.metrics.first else {
                            return
                        }
                        pin(HistoryBinning.bin(at: date, in: bars.bins[first] ?? []))
                    }
            }
        }
        // Short labels: "1 PM" within a day, "Sep 20" across days. The default "Sep 20 at 1 PM"
        // truncated to "Sep 20…" in narrow strips.
        .chartXAxis {
            AxisMarks(values: Self.axisValues(range)) { _ in
                AxisGridLine()
                AxisValueLabel(format: Self.axisFormat(range), collisionResolution: .greedy)
                    .font(Tokens.Typography.chartLabel)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(Formatters.axis(number, spec.metrics[0]))
                    }
                }
                .font(Tokens.Typography.chartLabel)
            }
        }
        .chartYScale(domain: .automatic(includesZero: true))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            chartWidth = width
            rebin()
        }
        .accessibilityLabel(Text("\(spec.title) history, \(range.label)", bundle: .strings, comment: "Chart: metric name, range"))
        .accessibilityValue(spokenSummary)
        // Rewind without a pointer: the apps behind the range's busiest bar (D-190).
        .accessibilityAction(named: Text("Show the apps behind the busiest moment", bundle: .strings)) {
            guard spec.topAppsMetric != nil, let first = spec.metrics.first else {
                return
            }
            pinned = bars.bins[first]?.max { $0.average < $1.average }
        }
    }

    /// The tallest mark drawn: peaks on a single-metric strip, averages when there are two.
    private var plottedPeak: Double {
        bars.bins.values.joined().map { spec.metrics.count == 1 ? $0.maximum : $0.average }.max() ?? 0
    }

    /// One series: its peak behind its average. Several: averages side by side.
    @ChartContentBuilder
    private func barMarks(_ bin: HistoryBin, series index: Int, of count: Int) -> some ChartContent {
        let slot = HistoryBinning.slot(of: bin, series: index, of: count)
        let from = PlottableValue.value(Self.fromAxis, slot.start)
        let to = PlottableValue.value(Self.toAxis, slot.end)
        let zero = PlottableValue.value(Self.zeroAxis, 0.0)
        // Bars as rectangles from zero: `BarMark(xStart:xEnd:y:)` doesn't reach down to zero on
        // a continuous y scale, and there's no `BarMark(xStart:xEnd:yStart:yEnd:)`.
        // With a moment pinned, the other bars step back so it stands out (D-190).
        let faded = pinned.map { !($0.start ..< $0.end).contains(bin.middle) } ?? false
        if count == 1 {
            RectangleMark(xStart: from, xEnd: to, yStart: zero, yEnd: .value(Self.peakAxis, bin.maximum))
                .foregroundStyle(Tokens.Colors.chartPeak(spec.tint))
                .opacity(faded ? 0.3 : 1)
                .cornerRadius(Tokens.Radius.historyBar)
        }
        RectangleMark(xStart: from, xEnd: to, yStart: zero, yEnd: .value(Self.averageAxis, bin.average))
            .foregroundStyle(color(index))
            .opacity(faded ? 0.3 : 1)
            .cornerRadius(Tokens.Radius.historyBar)
    }

    /// The first series' bar at the pinned moment, as the bars are now (they rebin with the width).
    var pinnedBin: HistoryBin? {
        guard let pinned, let first = spec.metrics.first else {
            return nil
        }
        return HistoryBinning.bin(at: pinned.middle, in: bars.bins[first] ?? []) ?? pinned
    }

    /// The first series' bar under the pointer.
    private var selectedBin: HistoryBin? {
        guard let selection, let first = spec.metrics.first else {
            return nil
        }
        return HistoryBinning.bin(at: selection, in: bars.bins[first] ?? [])
    }

    /// Rebuilds the bars when the points changed (`force`) or a different bar width fits.
    private func rebin(force: Bool = false) {
        let duration = TimeInterval(range.duration.components.seconds)
        // Before the first layout, assume room for the most bars; the width arrives right after.
        let maxBins = chartWidth > 0
            ? HistoryBinning.maxBins(width: chartWidth, series: spec.metrics.count)
            : Tokens.Layout.historyMaxBars / max(1, spec.metrics.count)
        let interval = HistoryBinning.interval(for: duration, maxBins: maxBins)
        guard force || interval != bars.interval else {
            return
        }
        // The Mac's zone, each point by its own date's offset (D-220).
        let zone = TimeZone.autoupdatingCurrent
        var binned: [Metric: [HistoryBin]] = [:]
        for (metric, points) in series {
            binned[metric] = HistoryBinning.bins(points, interval: interval, timeZone: zone)
        }
        let serious = Double(ThermalPressure.serious.rank)
        let pressure = HistoryBinning.bins(thermal, interval: interval, timeZone: zone)
        bars = Bars(interval: interval, bins: binned, throttled: HistoryBinning.spans(pressure) { $0.maximum >= serious })
    }
}

extension HistoryStrip: Equatable {
    /// The inputs; the state and environment are SwiftUI's. Lets a parent that re-evaluates
    /// (every 3 s for the app list) skip rebuilding the chart when nothing it draws changed.
    nonisolated static func == (lhs: HistoryStrip, rhs: HistoryStrip) -> Bool {
        lhs.spec == rhs.spec && lhs.range == rhs.range && lhs.services === rhs.services
            && lhs.threshold == rhs.threshold && lhs.showsTitle == rhs.showsTitle
    }

    /// One spec per tab, made once: a parent re-evaluating then hands the strip the same value
    /// (the same `metrics` storage), so the strip and its chart aren't rebuilt (D-086).
    @MainActor
    enum TabSpecs {
        private static var specs: [MetricTab: [Bool: Spec]] = [:]

        static func spec(tab: MetricTab, hasBattery: Bool) -> Spec {
            if let spec = specs[tab]?[hasBattery] {
                return spec
            }
            let spec = Spec(tab: tab, hasBattery: hasBattery)
            specs[tab, default: [:]][hasBattery] = spec
            return spec
        }
    }
}

extension HistoryStrip {
    /// Loads once, then every minute (history gains a point a minute) while shown. Slack lets
    /// the wake-up coalesce with others.
    private func reloadForever(isShown: Bool) async {
        // Hidden, it keeps what it has, but only if that's this strip's: the view stays the same
        // when the tab changes, and another metric's points read in this one's units (D-239).
        if !isShown, !series.isEmpty, loadedFor == loadKey {
            return
        }
        await reload()
        while isShown, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60), tolerance: .seconds(10))
            guard !Task.isCancelled else {
                return
            }
            await reload()
        }
    }

    private func reload() async {
        let store = services.history
        // Only what falls inside the strip: a store's buckets can begin before the range does,
        // and those bars were drawn left of the plot, under the title.
        let start = Date().addingTimeInterval(-TimeInterval(range.duration.components.seconds))
        var loaded: [Metric: [SeriesPoint]] = [:]
        for metric in spec.metrics {
            loaded[metric] = await ((try? store.series(metric: metric, app: nil, range: range)) ?? []).filter { $0.at >= start }
        }
        var top: [AppTotal] = []
        var moved: [AppIdentity.ID: PeriodChange] = [:]
        if let metric = spec.topAppsMetric {
            // Energy Impact is a score with no unit: each app's share of the total says more (D-105).
            let shares = metric == .energyImpact
            top = await (try? store.topApps(metric: metric, range: range, limit: shares ? 200 : 5)) ?? []
            if shares {
                top = Array(Self.shares(top).prefix(5))
            }
            if comparesPrevious {
                // A wider previous ranking, so an app that was 7th before isn't marked new.
                var previous = await (try? store.topAppsInPreviousPeriod(metric: metric, range: range, limit: shares ? 200 : 50)) ?? []
                if shares {
                    previous = Self.shares(previous)
                }
                moved = PeriodChange.changes(current: top, previous: previous)
            }
        }
        // On the charge line, the whole Mac's watts over the same range (D-258).
        var draw: PowerSummary?
        if spec.metrics.first == .batteryLevel {
            let points = await (try? store.series(metric: .powerDraw, app: nil, range: range)) ?? []
            draw = PowerSummary.read(points, rangeStart: start)
        }
        var pressure: [SeriesPoint] = []
        if spec.marksThrottling {
            pressure = await ((try? store.series(metric: .thermalPressure, app: nil, range: range)) ?? []).filter { $0.at >= start }
        }
        let pinned = await Self.notes(in: store, from: start)
        guard !Task.isCancelled else {
            return
        }
        notes = pinned
        series = loaded
        power = draw
        loadedFor = loadKey
        loadedAt = Date()
        spokenSummary = spec.metrics.first.flatMap { Self.spokenSummary(loaded[$0] ?? [], metric: $0, range: range) } ?? ""
        thermal = pressure
        topApps = top
        changes = moved
        rebin(force: true)
    }
}

extension HistoryStrip {
    /// Hour marks within a day; across days, midnights a whole number of days apart, so no two
    /// marks carry the same date (automatic marks every 1.75 days labelled "Sep 27" twice).
    static func axisValues(_ range: HistoryRange) -> AxisMarkValues {
        switch range {
        case .h12, .h24: .automatic(desiredCount: 4)
        case .d7: .stride(by: .day, count: 2)
        case .d30: .stride(by: .day, count: 7)
        case .d90: .stride(by: .month)
        case .y1: .stride(by: .month, count: 2)
        }
    }

    static func axisFormat(_ range: HistoryRange) -> Date.FormatStyle {
        switch range {
        case .h12, .h24: .dateTime.hour()
        case .d7, .d30: .dateTime.month(.abbreviated).day()
        case .d90, .y1: .dateTime.month(.abbreviated)
        }
    }
}

extension HistoryStrip {
    /// The scrubbed bar, or the range's latest.
    var caption: String {
        guard let first = spec.metrics.first, let latest = bars.bins[first]?.last else {
            return range.label
        }
        // With nothing selected, the charge line says what was used and put back (D-105).
        if first == .batteryLevel, selectedBin == nil {
            let points = series[.batteryLevel] ?? []
            let flow = BatteryFlow.totals(points)
            // Recording began inside the range (the figure is new, or history was deleted).
            if let start = points.first?.at,
               start.timeIntervalSince(loadedAt.addingTimeInterval(-TimeInterval(range.duration.components.seconds))) > 1800 {
                let since = start.formatted(date: range.isWithinDay ? .omitted : .abbreviated, time: .shortened)
                return String(
                    localized: "Since \(since): used \(Formatters.percent(flow.used)), charged \(Formatters.percent(flow.charged))",
                    bundle: .strings,
                    comment: "Battery history caption when recording began inside the range: its start, then charge used and put back"
                )
            }
            return String(
                localized: "Used \(Formatters.percent(flow.used)), charged \(Formatters.percent(flow.charged)) · \(range.label)",
                bundle: .strings,
                comment: "Battery history caption: charge used and put back over the range, e.g. Used 90%, charged 60% · 24 h"
            )
        }
        let bin = selectedBin ?? pinnedBin ?? latest
        let time = Self.caption(for: bin, range: range)
        let average = Formatters.metric(bin.average, first)
        let peak = Formatters.metric(bin.maximum, first)
        // Energy Impact has no unit, so the figure says what it is.
        if first == .energyImpact {
            return String(
                localized: "Energy Impact \(average) · peak \(peak) · \(time)",
                bundle: .strings,
                comment: "History caption: average, peak, time of the bar"
            )
        }
        return String(
            localized: "\(average) · peak \(peak) · \(time)",
            bundle: .strings,
            comment: "History caption: average, peak, time of the bar"
        )
    }
}
