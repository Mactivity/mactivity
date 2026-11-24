import AppKit
import Charts
import Core
import SwiftUI

/// Camera and microphone on the Devices page (1.8, D-259): which apps used the camera, a
/// microphone, the screen or the location in the last week, and the latest times, from what
/// macOS's privacy indicators recorded. Kept on this Mac.
struct SensorHistoryCard: View {
    let services: AppServices

    @State private var sessions: [SensorSession] = []
    @State private var loadedAt = Date()
    @State private var loaded = false

    static let days = 7
    static let recentShown = 8

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Camera and microphone", bundle: .strings, comment: "Devices page: which apps used the camera and microphone")
                    .font(Tokens.Typography.cardTitle)
                Spacer()
                Text("Last 7 days", bundle: .strings, comment: "Devices page: the span of camera and microphone history")
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
            if loaded, sessions.isEmpty {
                Text("No app has used the camera, a microphone or the screen in the last 7 days.", bundle: .strings)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
            } else if loaded {
                calls
                totalsGrid
                Divider()
                Text("Recent", bundle: .strings, comment: "Devices page: the latest camera and microphone uses")
                    .font(Tokens.Typography.secondary.weight(.semibold))
                recentList
            }
            Text(SensorText.note(unknownApp: sessions.contains { $0.app == nil }))
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .task(id: services.historyGeneration) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Time in calls (D-262): the week's total, today's, the apps, and a bar for each day.
    @ViewBuilder private var calls: some View {
        let found = CallTime.calls(sessions, now: loadedAt)
        if !found.isEmpty {
            let days = CallTime.perDay(found, days: Self.days, now: loadedAt)
            let week = days.reduce(0) { $0 + $1.seconds }
            let apps = CallTime.byApp(found, from: loadedAt.addingTimeInterval(-Double(Self.days) * 86400), now: loadedAt)
            HStack(alignment: .center, spacing: Tokens.Spacing.m) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.lineGap) {
                    Text(SensorText.calls(week: week, today: days.last?.seconds ?? 0))
                        .monospacedDigit()
                    Text(SensorText.callApps(apps))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .help(SensorText.callsHelp)
                Spacer()
                Chart(days, id: \.day) { day in
                    BarMark(x: .value("Day", day.day, unit: .day), y: .value("Seconds", day.seconds))
                        .foregroundStyle(.green.opacity(0.75))
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                            .font(Tokens.Typography.chartLabel)
                    }
                }
                .chartYAxis(.hidden)
                .frame(width: 180, height: 44)
                .accessibilityHidden(true)
            }
            Divider()
        }
    }

    private var totalsGrid: some View {
        let from = loadedAt.addingTimeInterval(-Double(Self.days) * 86400)
        let totals = SensorSessions.totals(sessions, from: from, now: loadedAt)
        let apps = SensorText.appsInOrder(totals)
        return Grid(alignment: .leading, horizontalSpacing: Tokens.Spacing.m, verticalSpacing: Tokens.Spacing.xs) {
            ForEach(apps, id: \.self) { app in
                GridRow {
                    SensorAppLabel(app: app)
                    Text(SensorText.uses(totals.filter { $0.app == app }))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            ForEach(SensorMoment.moments(sessions, now: loadedAt).prefix(Self.recentShown)) { moment in
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
                    HStack(spacing: Tokens.Spacing.xxs) {
                        ForEach(moment.sensors, id: \.self) { Image(systemName: $0.symbol) }
                    }
                    .foregroundStyle(moment.end == nil ? AnyShapeStyle(Tokens.Colors.strain) : AnyShapeStyle(.secondary))
                    .frame(width: 44, alignment: .leading)
                    SensorAppLabel(app: moment.app)
                    Spacer()
                    Text(SensorText.when(moment, now: loadedAt))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(Tokens.Typography.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(SensorText.spoken(moment, now: loadedAt))
            }
        }
    }

    private func load() async {
        let now = Date()
        let from = now.addingTimeInterval(-Double(Self.days) * 86400)
        let changes = await (try? (services.history as? any SensorHistoryStore)?.sensorChanges(from: from, to: now)) ?? []
        guard !Task.isCancelled else {
            return
        }
        sessions = SensorSessions.sessions(changes, from: from, now: now)
        loadedAt = now
        loaded = true
    }
}

/// An app's icon and name from its bundle ID, or "An app" when macOS didn't say which.
private struct SensorAppLabel: View {
    let app: String?

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            if let app {
                AppIconView(SensorText.identity(app), size: Tokens.IconSize.row)
                Text(MutedAppsSection.displayName(app)).lineLimit(1)
            } else {
                Image(systemName: "questionmark.app").frame(width: Tokens.IconSize.row).foregroundStyle(.secondary)
                Text("An app", bundle: .strings, comment: "Camera and microphone history: macOS didn't say which app").lineLimit(1)
            }
        }
    }
}

@MainActor
enum SensorText {
    /// "In calls 1h 05m this week · 25m today".
    static func calls(week: TimeInterval, today: TimeInterval) -> String {
        let week = Formatters.duration(.seconds(week))
        let today = Formatters.duration(.seconds(today))
        return String(
            localized: "In calls \(week) this week · \(today) today",
            bundle: .strings,
            comment: "Camera and microphone: time in video and voice calls, e.g. In calls 1h 05m this week · 25m today"
        )
    }

    /// "FaceTime 55m · Zoom 10m".
    static func callApps(_ apps: [(app: String?, seconds: TimeInterval)]) -> String {
        apps.prefix(3).map { app, seconds in
            let name = app.map(MutedAppsSection.displayName)
                ?? String(localized: "An app", bundle: .strings, comment: "Camera and microphone history: macOS didn't say which app")
            return "\(name) \(Formatters.duration(.seconds(seconds)))"
        }
        .joined(separator: " · ")
    }

    static let callsHelp = String(
        localized: """
        Time an app had the microphone for two minutes or more, with or without the camera. Recording apps like \
        Voice Memos, and dictation, don't count.
        """,
        bundle: .strings
    )

    /// Apps by their longest use, the ones macOS didn't name last.
    static func appsInOrder(_ totals: [SensorTotal]) -> [String?] {
        var seen: [String?] = []
        for total in totals where !seen.contains(total.app) {
            seen.append(total.app)
        }
        return seen.filter { $0 != nil } + seen.filter { $0 == nil }
    }

    /// "Camera 45m · Microphone 50m", "Location 30 times": camera, microphone, screen, location.
    static func uses(_ totals: [SensorTotal]) -> String {
        totals.sorted { $0.sensor < $1.sensor }.map { total in
            if total.sensor == .location {
                return String(
                    localized: "\(total.sensor.title) \(total.times) times",
                    bundle: .strings,
                    comment: "Camera and microphone history: how often an app read the location, e.g. Location 30 times"
                )
            }
            return "\(total.sensor.title) \(Formatters.duration(.seconds(max(60, total.seconds))))"
        }
        .joined(separator: " · ")
    }

    /// "10:02 – 10:40", "Yesterday 9:00 – 9:45", "Tue 15:00 – 15:14", "Since 10:02" while in use.
    static func when(_ moment: SensorMoment, now: Date) -> String {
        let calendar = Calendar.current
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        let start = moment.start.formatted(time)
        guard let end = moment.end else {
            return String(localized: "In use since \(start)", bundle: .strings, comment: "Camera and microphone history: still in use")
        }
        let span = "\(start) – \(end.formatted(time))"
        if calendar.isDate(moment.start, inSameDayAs: now) {
            return span
        }
        if calendar.isDateInYesterday(moment.start) {
            return String(
                localized: "Yesterday \(span)",
                bundle: .strings,
                comment: "Camera and microphone history: e.g. Yesterday 9:00 – 9:45"
            )
        }
        return "\(moment.start.formatted(.dateTime.weekday(.abbreviated))) \(span)"
    }

    /// For VoiceOver: "FaceTime, Camera and Microphone, 10:02 – 10:40".
    static func spoken(_ moment: SensorMoment, now: Date) -> String {
        let app = moment.app.map(MutedAppsSection.displayName)
            ?? String(localized: "An app", bundle: .strings, comment: "Camera and microphone history: macOS didn't say which app")
        let sensors = moment.sensors.map(\.title).formatted(.list(type: .and))
        return "\(app), \(sensors), \(when(moment, now: now))"
    }

    static func note(unknownApp: Bool) -> String {
        let base = String(
            localized: """
            From the dots macOS shows in the menu bar while an app uses the camera, a microphone, the screen or \
            the location. Kept on this Mac only.
            """,
            bundle: .strings
        )
        guard unknownApp else {
            return base
        }
        return base + " " + String(
            localized: "Where macOS's record couldn't be read, Mactivity saw the camera or microphone on but not which app.",
            bundle: .strings
        )
    }

    /// The app behind a bundle ID, for its icon.
    static func identity(_ bundleID: String) -> AppIdentity {
        let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
        return AppIdentity(
            id: bundleID, name: MutedAppsSection.displayName(bundleID), bundleID: bundleID, iconKey: path ?? "other", kind: .app
        )
    }
}
