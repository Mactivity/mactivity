import Core
import SwiftUI

// Sleep and wake (D-096).

/// History → Sleep: what's keeping the Mac awake now, the last week's sleep, and recent wakes.
struct SleepCard: View {
    let store: any PowerEventStore
    let blockers: any SleepBlockerSource
    let generation: Int
    /// For the battery each sleep used (D-213); nil on a Mac without a battery.
    var levels: (any DailyHistoryStore)?

    @State private var events: [PowerEvent] = []
    @State private var sleeps: [SleepSpan] = []
    @State private var awake: [SleepBlocker] = []

    private static let days = 7

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            SleepBlockerList(blockers: awake)
            Divider()
            timeline
            if !recentSleeps.isEmpty {
                Divider()
                RecentSleeps(spans: recentSleeps)
            }
        }
        .cardStyle()
        .task(id: generation) {
            events = await (try? store.powerEvents(days: Self.days + 1)) ?? []
            sleeps = await SleepLevels.spans(events, levels: levels, limit: 5)
        }
        .task {
            // What's awake changes by the minute; the IOKit read is cheap.
            while !Task.isCancelled {
                awake = await blockers.blockers()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// The last five sleeps of half an hour or more, newest first (D-213).
    private var recentSleeps: [SleepSpan] {
        Array(sleeps.prefix(5))
    }

    /// A row per day, midnight to midnight, filled where the Mac was asleep.
    private var timeline: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let days = (0 ..< Self.days).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        return VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
            Text("Asleep, the last week", bundle: .strings)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
            ForEach(days, id: \.self) { day in
                let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
                let asleep = SleepTimeline.asleep(events, from: day, to: end)
                let total = asleep.reduce(0) { $0 + $1.duration }
                // 23 or 25 hours the day the clocks change (D-220).
                let length = max(1, end.timeIntervalSince(day))
                HStack(spacing: Tokens.Spacing.xs) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated).day()))
                        .font(Tokens.Typography.secondary)
                        .frame(width: 64, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.07))
                            ForEach(asleep, id: \.start) { interval in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.indigo.opacity(0.75))
                                    .frame(width: max(1, proxy.size.width * interval.duration / length))
                                    .offset(x: proxy.size.width * interval.start.timeIntervalSince(day) / length)
                            }
                        }
                    }
                    .frame(height: 12)
                    Text(total > 0 ? Duration.seconds(total).formatted(.units(allowed: [.hours, .minutes], width: .narrow)) : "–")
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(day.formatted(.dateTime.weekday(.wide).month().day())))
                .accessibilityValue(Text(total > 0 ? Duration.seconds(total)
                        .formatted(.units(allowed: [.hours, .minutes], width: .wide)) : ""))
            }
            HStack {
                Spacer().frame(width: 64 + Tokens.Spacing.xs)
                // Midnight, 6, noon, 6 and midnight on the Mac's clock, 12- or 24-hour (D-221).
                ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
                    Text(Self.hourLabel(hour))
                    if hour != 24 {
                        Spacer()
                    }
                }
                Spacer().frame(width: 64 + Tokens.Spacing.xs)
            }
            .font(Tokens.Typography.caption)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
    }

    /// "12 AM", "6 AM"… or "00", "06"… as the Mac shows hours; 24 is midnight again.
    nonisolated static func hourLabel(_ hour: Int) -> String {
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour % 24))
        return date?.formatted(.dateTime.hour()) ?? "\(hour)"
    }

    nonisolated static func causeText(_ cause: WakeCause) -> String {
        switch cause {
        case .lid: String(localized: "Lid opened", bundle: .strings)
        case .powerButton: String(localized: "Power button", bundle: .strings)
        case .keyboardOrTrackpad: String(localized: "Keyboard or trackpad", bundle: .strings)
        case .powerAdapter: String(localized: "Power adapter connected", bundle: .strings)
        case .network: String(localized: "Network access", bundle: .strings)
        case .bluetooth: String(localized: "A Bluetooth device", bundle: .strings)
        case .usb: String(localized: "A USB device", bundle: .strings)
        case .scheduled: String(localized: "Scheduled: maintenance or Power Nap", bundle: .strings)
        case .other: String(localized: "Something else", bundle: .strings, comment: "Wake reason macOS didn't make clear")
        }
    }
}

/// Each sleep's battery use from the battery level just before it and just after it (D-213):
/// minute readings, read for those few minutes only. A week's readings in one go come back by the
/// quarter-hour, which blurs in the time awake either side.
enum SleepLevels {
    static func spans(_ events: [PowerEvent], levels: (any DailyHistoryStore)?, limit: Int) async -> [SleepSpan] {
        let bare = Array(SleepDrain.spans(events, levels: []).prefix(limit))
        guard let levels, !bare.isEmpty else {
            return bare
        }
        var readings: [SeriesPoint] = []
        for span in bare {
            let window = SleepDrain.readingWindow
            readings += await (try? levels.series(metric: .batteryLevel, app: nil, from: span.start - window, to: span.start + 60)) ?? []
            readings += await (try? levels.series(metric: .batteryLevel, app: nil, from: span.end, to: span.end + window)) ?? []
        }
        return Array(SleepDrain.spans(events, levels: readings.sorted { $0.at < $1.at }).prefix(limit))
    }
}

/// Recent sleeps (D-213): each one's times and length, what woke the Mac, and the battery it
/// used, in the strain color when it drained fast.
struct RecentSleeps: View {
    let spans: [SleepSpan]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
            Text("Recent sleeps", bundle: .strings, comment: "Sleep card: each sleep, what woke the Mac, battery used")
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: Tokens.Spacing.m, verticalSpacing: Tokens.Spacing.xxs) {
                ForEach(spans) { span in
                    GridRow {
                        Text(Self.when(span)).monospacedDigit()
                        Text(Duration.seconds(span.end.timeIntervalSince(span.start)).formatted(.units(
                            allowed: [.hours, .minutes],
                            width: .narrow
                        )))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        Text(SleepCard.causeText(WakeCause(reason: span.wake.reason ?? "")))
                            .foregroundStyle(.secondary)
                            .help(span.wake.reason ?? "")
                        Text(Self.used(span))
                            .monospacedDigit()
                            .foregroundStyle(span.isHeavyDrain ? AnyShapeStyle(Tokens.Colors.strainLabel) : AnyShapeStyle(.secondary))
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
        }
    }

    /// "Tue 11:40 PM – 7:10 AM".
    nonisolated static func when(_ span: SleepSpan) -> String {
        "\(span.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())) – \(span.end.formatted(.dateTime.hour().minute()))"
    }

    /// "Used 4%", "Used 12%, 1.5% an hour", or nothing without readings or under an hour.
    nonisolated static func used(_ span: SleepSpan) -> String {
        // Under an hour, minutes awake either side would read as drain.
        guard let used = span.batteryUsed, span.end.timeIntervalSince(span.start) >= 3600 else {
            return ""
        }
        let amount = Formatters.percent(used)
        if span.isHeavyDrain, let rate = span.drainPerHour {
            let hourly = Formatters.percent(rate, fractionDigits: 1)
            return String(
                localized: "Used \(amount), \(hourly) an hour",
                bundle: .strings,
                comment: "Battery used while asleep, and the rate"
            )
        }
        return String(localized: "Used \(amount)", bundle: .strings, comment: "Battery used while asleep")
    }
}

/// The apps keeping the Mac awake, or a line saying nothing is.
struct SleepBlockerList: View {
    let blockers: [SleepBlocker]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text("Keeping your Mac awake now", bundle: .strings)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
            if blockers.isEmpty {
                Text("Nothing. Your Mac can sleep when it's idle.", bundle: .strings)
            }
            ForEach(blockers) { blocker in
                HStack(spacing: Tokens.Spacing.xs) {
                    AppIconView(blocker.app, size: Tokens.IconSize.small)
                    Text(blocker.app.name)
                    Text(blocker.keeps == .display
                        ? String(localized: "keeps the display on", bundle: .strings)
                        : String(localized: "keeps the Mac awake", bundle: .strings))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let since = blocker.since {
                        Text(since.formatted(.relative(presentation: .named)))
                            .foregroundStyle(.secondary)
                    }
                }
                .help(blocker.reason)
            }
        }
    }
}

/// The Battery tab's one line when an app is keeping the Mac awake; nothing otherwise. macOS's own
/// daemons are left out: there's nothing to do about them here (D-108).
struct SleepBlockersBanner: View {
    let source: any SleepBlockerSource
    /// History → Sleep, which says what each one is doing (D-196).
    var open: () -> Void = {}

    @State private var blockers: [SleepBlocker] = []

    var body: some View {
        Group {
            if !blockers.isEmpty {
                HStack(spacing: Tokens.Spacing.xs) {
                    Image(systemName: "moon.zzz")
                        .foregroundStyle(.indigo)
                    Text(Self.text(blockers))
                        .lineLimit(1)
                    Spacer()
                }
                .font(Tokens.Typography.secondary)
                .padding(.horizontal, Tokens.Spacing.s)
                .padding(.vertical, Tokens.Spacing.xs)
                .background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(.rect)
                .onTapGesture(perform: open)
                .accessibilityAddTraits(.isButton)
                .help(blockers.map { "\($0.app.name): \($0.reason)" }.joined(separator: "\n"))
            }
        }
        .task {
            while !Task.isCancelled {
                blockers = await source.blockers().filter(\.isUserFacing)
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// "Keeping your Mac awake: Music, Claude".
    nonisolated static func text(_ blockers: [SleepBlocker]) -> String {
        var names: [String] = []
        for blocker in blockers where !names.contains(blocker.app.name) {
            names.append(blocker.app.name)
        }
        let list = names.formatted(.list(type: .and))
        return String(
            localized: "Keeping your Mac awake: \(list)",
            bundle: .strings,
            comment: "Battery tab banner: apps that stop the Mac from sleeping"
        )
    }
}
