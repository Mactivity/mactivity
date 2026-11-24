import Charts
import Core
import SwiftUI

/// History tab: every metric's history strip over the toolbar's range, then temperatures and
/// fans (expansion E8) and battery health by day (E14).
struct HistoryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let services: AppServices
    let range: HistoryRange

    private static let sensorSpecs = [
        HistoryStrip.Spec(
            id: "temperature",
            title: String(localized: "Temperature", bundle: .strings, comment: "History section"),
            metrics: [.cpuTemperature, .gpuTemperature],
            tint: .red
        ),
        HistoryStrip.Spec(
            id: "fans",
            title: String(localized: "Fan speed", bundle: .strings, comment: "History section"),
            metrics: [.fanSpeed],
            tint: .cyan
        ),
    ]

    /// The sensor strips this Mac can fill: no Fan speed on a fanless Mac, no Temperature without
    /// sensors, rather than "No history yet" forever. Both until the sensors have been read.
    static func sensorSpecs(for hardware: LiveMetrics.Hardware) -> [HistoryStrip.Spec] {
        sensorSpecs.filter { spec in
            (spec.id == "fans" ? hardware.hasFans : hardware.hasTemperatureSensors) != false
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: Tokens.Spacing.gridGutter) {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                        CardHeader(
                            title: String(localized: "Your week", bundle: .strings, comment: "History section: the last seven days"),
                            symbol: "calendar.badge.clock", status: nil, tint: .accentColor
                        )
                        YourWeekCard(services: services)
                    }
                    // Your month and Your year (1.7, D-254).
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                        CardHeader(
                            title: String(
                                localized: "Looking back",
                                bundle: .strings,
                                comment: "History section: Your month and Your year"
                            ),
                            symbol: "calendar.badge.checkmark", status: nil, tint: .accentColor
                        )
                        LookingBackCard(services: services)
                    }
                    NextMacBanner(services: services)
                    // Compare two Macs (1.6).
                    CompareMacsCard(services: services, model: services.compareMacs)
                    if let store = services.history as? any DailyHistoryStore {
                        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                            CardHeader(
                                title: String(localized: "The year", bundle: .strings, comment: "History section: the year calendar"),
                                symbol: "calendar", status: nil, tint: .accentColor
                            )
                            YearCalendarCard(store: store, generation: services.historyGeneration, services: services)
                        }
                    }
                    // Each day of the week by the hour (D-272).
                    if let store = services.history as? any HourRhythmStore {
                        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                            CardHeader(
                                title: String(
                                    localized: "Busiest hours",
                                    bundle: .strings,
                                    comment: "History section: each day of the week by the hour"
                                ),
                                symbol: "square.grid.3x3.square", status: nil, tint: MetricTab.cpu.tint
                            )
                            BusiestHoursCard(store: store, generation: services.historyGeneration)
                        }
                    }
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                        CardHeader(
                            title: String(
                                localized: "After updates",
                                bundle: .strings,
                                comment: "History section: apps before and after an update"
                            ),
                            symbol: "arrow.triangle.2.circlepath", status: nil, tint: .accentColor
                        )
                        AfterUpdatesCard(services: services)
                    }
                    .id(HistorySection.updates.rawValue)
                    if services.history is any BuildHistoryStore {
                        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                            CardHeader(
                                title: String(
                                    localized: "Build times",
                                    bundle: .strings,
                                    comment: "History section: how long each project's builds take"
                                ),
                                symbol: "hammer", status: nil, tint: .accentColor
                            )
                            BuildTimesCard(services: services)
                            TestTimesCard(services: services)
                        }
                        .id(HistorySection.builds.rawValue)
                    }
                    ForEach(MetricTab.allCases) { tab in
                        let hasBattery = services.metrics.hardware.hasBattery
                        section(tab.title(hasBattery: hasBattery), symbol: tab.symbol(hasBattery: hasBattery), tint: tab.tint) {
                            HistoryStrip(tab: tab, range: range, services: services, showsTitle: false)
                        }
                    }
                    ForEach(Self.systemSpecs, id: \.id) { spec in
                        section(spec.title, symbol: Self.symbol(forSystemSpec: spec.id), tint: spec.tint) {
                            HistoryStrip(spec: spec, range: range, services: services, showsTitle: false)
                        } note: {
                            if spec.id == "free", let store = services.history as? any DailyHistoryStore {
                                DiskForecastNote(store: store, generation: services.historyGeneration)
                            }
                        }
                    }
                    if let store = services.history as? any DailyHistoryStore {
                        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                            CardHeader(
                                title: String(localized: "Data used", bundle: .strings, comment: "History section: network data per app"),
                                symbol: "arrow.up.arrow.down", status: nil, tint: MetricTab.network.tint
                            )
                            DataUsedCard(store: store, range: range, generation: services.historyGeneration)
                        }
                    }
                    ForEach(Self.sensorSpecs(for: services.metrics.hardware), id: \.id) { spec in
                        section(spec.title, symbol: spec.id == "fans" ? "fan" : "thermometer.medium", tint: spec.tint) {
                            HistoryStrip(spec: spec, range: range, services: services, showsTitle: false)
                        }
                        // "temperature" is HistorySection.temperature's scroll ID.
                        .id(spec.id)
                    }
                    // Heat by app (1.7, D-255).
                    if services.metrics.hardware.hasTemperatureSensors != false, let store = services.history as? any DailyHistoryStore {
                        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                            CardHeader(
                                title: String(
                                    localized: "Heat by app",
                                    bundle: .strings,
                                    comment: "History section: apps in the warmest hours"
                                ),
                                symbol: "flame", status: nil, tint: .orange
                            )
                            HeatByAppCard(store: store, generation: services.historyGeneration)
                        }
                    }
                    if let store = services.history as? any FocusStore {
                        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                            CardHeader(
                                title: String(
                                    localized: "Time in front",
                                    bundle: .strings,
                                    comment: "History section: how long each app was in use"
                                ),
                                symbol: "macwindow", status: nil, tint: .accentColor
                            )
                            TimeInFrontCard(store: store, range: range, generation: services.historyGeneration)
                        }
                        // The longest stretches in one app, each day (D-271).
                        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                            CardHeader(
                                title: String(
                                    localized: "Focus streaks",
                                    bundle: .strings,
                                    comment: "History section: the longest stretches in one app"
                                ),
                                symbol: "scope", status: nil, tint: .accentColor
                            )
                            FocusStreaksCard(store: store, generation: services.historyGeneration)
                        }
                    }
                    if let store = services.history as? any NotificationHistoryStore {
                        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                            CardHeader(
                                title: String(
                                    localized: "Notifications",
                                    bundle: .strings,
                                    comment: "History section: which apps send the most notifications, and when"
                                ),
                                symbol: "bell", status: nil, tint: .accentColor
                            )
                            NotificationsCard(
                                model: services.notifications, store: store, range: range, generation: services.historyGeneration
                            )
                        }
                    }
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                        CardHeader(
                            title: String(localized: "Crashes and hangs", bundle: .strings, comment: "History section"),
                            symbol: "exclamationmark.triangle", status: nil, tint: Tokens.Colors.strain
                        )
                        CrashesCard(source: services.crashReports, range: range, generation: services.historyGeneration)
                    }
                    .id(HistorySection.crashes.rawValue)
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                        CardHeader(
                            title: String(
                                localized: "Flagged by macOS",
                                bundle: .strings,
                                comment: "History section: what macOS's own reports caught"
                            ),
                            symbol: "flag", status: nil, tint: Tokens.Colors.strain
                        )
                        FlaggedCard(services: services, generation: services.historyGeneration)
                    }
                    .id(HistorySection.flagged.rawValue)
                    if services.history is any AppLaunchStore {
                        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                            CardHeader(
                                title: String(
                                    localized: "App launch times",
                                    bundle: .strings,
                                    comment: "History section: how long apps take to open"
                                ),
                                symbol: "timer", status: nil, tint: .accentColor
                            )
                            LaunchTimesCard(services: services, generation: services.historyGeneration)
                        }
                        .id(HistorySection.launches.rawValue)
                    }
                    if let store = services.history as? any PowerEventStore {
                        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                            CardHeader(
                                title: String(localized: "Sleep", bundle: .strings, comment: "History section: sleep and wake"),
                                symbol: "moon.zzz", status: nil, tint: .indigo
                            )
                            SleepCard(
                                store: store, blockers: services.sleepBlockers, generation: services.historyGeneration,
                                levels: services.metrics.hardware.hasBattery ? services.history as? any DailyHistoryStore : nil
                            )
                        }
                        .id(HistorySection.sleep.rawValue)
                    }
                    if let store = services.history as? any DeviceBatteryStore {
                        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                            CardHeader(
                                title: String(
                                    localized: "Accessories",
                                    bundle: .strings,
                                    comment: "History section: AirPods, mice, keyboards"
                                ),
                                symbol: "airpodspro", status: nil, tint: MetricTab.battery.tint
                            )
                            DeviceBatteryCard(store: store, range: range, generation: services.historyGeneration)
                        }
                        .id(HistorySection.accessories.rawValue)
                    }
                    // A Mac without a battery has no battery health to chart.
                    if services.metrics.hardware.hasBattery, let store = services.history as? any BatteryHistoryStore {
                        let title = String(localized: "Battery health", bundle: .strings, comment: "History section")
                        section(title, symbol: "battery.100percent", tint: MetricTab.battery.tint) {
                            BatteryHealthCard(store: store, generation: services.historyGeneration)
                        }
                    }
                    // Charging habits (1.7, D-255): advice only.
                    if services.metrics.hardware.hasBattery, let store = services.history as? any DailyHistoryStore {
                        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                            CardHeader(
                                title: String(localized: "Charging habits", bundle: .strings, comment: "History section"),
                                symbol: "battery.100percent.bolt", status: nil, tint: MetricTab.battery.tint
                            )
                            ChargingHabitsCard(store: store, generation: services.historyGeneration)
                        }
                    }
                }
                .padding(Tokens.Spacing.l)
            }
            // Today so far → Your day (D-194): scroll to the timeline once the calendar has the day.
            .task(id: services.navigation.historyDay) {
                guard services.navigation.historyDay != nil else {
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
                withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(DayTimeline.anchor, anchor: .top) }
                try? await Task.sleep(for: .milliseconds(250))
                services.navigation.historyDay = nil
            }
            // An alert or Checkup item about crashes, sleep, accessories or heat (D-196).
            .task(id: services.navigation.historySection) {
                guard let section = services.navigation.historySection else {
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
                withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(section.rawValue, anchor: .top) }
                services.navigation.historySection = nil
            }
        }
    }

    private func section(
        _ title: String, symbol: String, tint: Color,
        @ViewBuilder content: () -> some View,
        @ViewBuilder note: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            // A card title's row: a fixed symbol box and a fixed height, so every strip starts
            // the same distance under its title. A note, if any, sits at its right.
            CardHeader(title: title, symbol: symbol, status: nil, tint: tint)
                .overlay(alignment: .trailing, content: note)
            content()
                .frame(height: Tokens.Layout.historyStripHeight)
        }
    }
}

/// Max capacity and cycles by day for the last year (expansion E14).
struct BatteryHealthCard: View {
    let store: any BatteryHistoryStore
    let generation: Int

    @State private var days: [BatteryDay] = []
    @State private var showsMonths = false

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.m) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text(caption)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                if days.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "No battery history yet", bundle: .strings), systemImage: "battery.0percent")
                    } description: {
                        Text("Mactivity records battery health once a day.", bundle: .strings)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Chart(days.filter { $0.maxCapacityPercent != nil }) { day in
                        LineMark(
                            x: .value(Self.dayAxis, day.day, unit: .day),
                            y: .value(Self.maxCapacityAxis, day.maxCapacityPercent ?? 0)
                        )
                        .foregroundStyle(Tokens.SidebarTint.battery)
                        .interpolationMethod(.monotone)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXAxis {
                        AxisMarks {
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel().font(Tokens.Typography.chartLabel)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .trailing) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let number = value.as(Double.self) {
                                    Text(Formatters.percent(number))
                                }
                            }
                            .font(Tokens.Typography.chartLabel)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                LabeledContent {
                    Text(verbatim: days.last?.cycleCount.map(String.init) ?? "–").monospacedDigit()
                } label: {
                    Text("Cycle count", bundle: .strings, comment: "Battery figure").foregroundStyle(.secondary)
                }
                .labeledContentStyle(.stacked)
                LabeledContent {
                    Text(Formatters.duration(.seconds(Int(averageMinutesOnBattery * 60)))).monospacedDigit()
                } label: {
                    Text("On battery, daily average", bundle: .strings).foregroundStyle(.secondary)
                }
                .labeledContentStyle(.stacked)
                if let perMonth = BatteryHealthForecast.cyclesPerMonth(days) {
                    LabeledContent {
                        Text(verbatim: Int(perMonth.rounded()).formatted()).monospacedDigit()
                    } label: {
                        Text("Cycles a month", bundle: .strings, comment: "Battery figure: charge cycles used per month")
                            .foregroundStyle(.secondary)
                    }
                    .labeledContentStyle(.stacked)
                }
                Spacer(minLength: 0)
                if !BatteryHealthForecast.months(days).isEmpty {
                    Button(String(localized: "By Month", bundle: .strings, comment: "Opens battery health month by month")) {
                        showsMonths = true
                    }
                    .controlSize(.small)
                    .popover(isPresented: $showsMonths, arrowEdge: .bottom) {
                        BatteryMonthsTable(
                            months: BatteryHealthForecast.months(days).reversed(),
                            forecast: BatteryHealthLine.forecast(
                                BatteryHealthForecast.estimate(80, days: days),
                                capacity: days.last { $0.maxCapacityPercent != nil }?.maxCapacityPercent
                            )
                        )
                    }
                }
            }
            .frame(width: Tokens.Layout.historyTopAppsWidth, alignment: .leading)
        }
        .cardStyle()
        .task(id: generation) {
            days = await (try? store.batteryHistory(days: 365)) ?? []
        }
    }

    private var averageMinutesOnBattery: Double {
        let recent = days.suffix(30)
        return recent.isEmpty ? 0 : recent.map(\.minutesOnBattery).reduce(0, +) / Double(recent.count)
    }

    private var caption: String {
        guard let first = days.first(where: { $0.maxCapacityPercent != nil }),
              let last = days.last(where: { $0.maxCapacityPercent != nil }),
              let from = first.maxCapacityPercent, let to = last.maxCapacityPercent
        else {
            return String(localized: "Max capacity over time", bundle: .strings)
        }
        let since = first.day.formatted(date: .abbreviated, time: .omitted)
        return String(
            localized: "Max capacity \(Formatters.percent(to)) · \(Formatters.percent(from)) on \(since)",
            bundle: .strings,
            comment: "Battery health caption: capacity now, capacity on the first recorded day, that day"
        )
    }

    /// Chart axis names, read by VoiceOver.
    private static let dayAxis = String(localized: "Day", bundle: .strings, comment: "Chart axis: calendar day")
    private static let maxCapacityAxis = String(localized: "Max capacity", bundle: .strings, comment: "Battery figure: maximum capacity")
}
