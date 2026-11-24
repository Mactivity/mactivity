import AppKit
import Core
import CoreTransferable
import Export
import SwiftUI

/// Builds a `WeeklyReport` from the stores: seven days ending at `end` (D-102).
@MainActor
public enum WeeklyReportLoader {
    public static func load(_ services: AppServices, end: Date = Date()) async -> WeeklyReport {
        // Seven calendar days, today so far the last: the same span as the day-by-day bars, so
        // they add up to In use (D-184).
        let days = WeeklyReport.days(ending: end)
        let start = days.first?.start ?? end.addingTimeInterval(-7 * 86400)
        let history = services.history
        let focus = history as? any FocusStore
        let daily = history as? any DailyHistoryStore
        let active = await (try? focus?.activeSeconds(from: start, to: end)) ?? 0
        let previous = await (try? focus?.activeSeconds(from: start.addingTimeInterval(-7 * 86400), to: start))
        let top = await (try? focus?.topApps(from: start, to: end)) ?? []
        let events = await (try? (history as? any PowerEventStore)?.powerEvents(days: 8)) ?? []
        let data = await (try? daily?.systemTotal(metrics: [.netIn, .netOut], from: start, to: end)) ?? 0
        let written = await (try? daily?.systemTotal(metrics: [.diskWrite], from: start, to: end)) ?? 0
        let crashes = await CrashFilter.relevant(services.crashReports.reports(since: start)).count
        let first = await (try? focus?.firstFocus()).flatMap { $0 }
        let cpuDays = await (try? daily?.dailyValues(metric: .cpu, days: 7)) ?? []
        var byDay: [DayTotal] = []
        for day in days {
            let seconds = await (try? focus?.activeSeconds(from: day.start, to: day.end)) ?? 0
            byDay.append(DayTotal(day: day.start, seconds: seconds))
        }
        var agentSeconds: Double?
        var topAgent: AgentWeek.Total?
        if let agents = history as? any AgentHistoryStore,
           let rows = try? await agents.agentUsage(from: start, to: end), !rows.isEmpty {
            agentSeconds = AgentWeek.byDay(rows, days: days).reduce(0) { $0 + $1.seconds }
            topAgent = AgentWeek.totals(rows).first
        }
        var charges: Int?
        if services.metrics.hardware.hasBattery {
            let levels = await (try? history.series(metric: .batteryLevel, app: nil, range: .d7)) ?? []
            charges = ChargeSessions.count(levels)
        }
        return WeeklyReport(
            start: start, end: end, activeSeconds: active, previousActiveSeconds: previous, topApps: top,
            averageSleepSeconds: WeeklyReport.averageSleep(events, from: start, to: end),
            dataBytes: data, writtenBytes: written, crashes: crashes,
            // The day it was used most, as the day-by-day chart shows it; by processor only when
            // time in use wasn't recorded (D-184).
            busiestDay: byDay.filter { $0.seconds > 0 }.max { $0.seconds < $1.seconds }?.day
                ?? cpuDays.max { $0.average < $1.average }?.day,
            charges: charges,
            recordingSince: WeeklyReport.recordingSince(firstFocus: first, weekStart: start),
            activeByDay: byDay, agentSeconds: agentSeconds, topAgent: topAgent
        )
    }
}

private extension FocusStore {
    func topApps(from start: Date, to end: Date) async throws -> [AppTotal] {
        try await focusTotals(from: start, to: end, limit: 5)
    }
}

/// History → Your week: the week's figures, and a Share button for its image.
struct YourWeekCard: View {
    let services: AppServices
    @Environment(\.colorScheme) private var colorScheme

    @State private var report: WeeklyReport?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            if let report {
                YourWeekContent(report: report)
                HStack {
                    Spacer()
                    // The full report, a week or a month, as a PDF (D-159).
                    Menu {
                        Button(String(localized: "Last 7 Days…", bundle: .strings)) { ReportPDF.save(services, period: .week) }
                        Button(String(localized: "Last 30 Days…", bundle: .strings)) { ReportPDF.save(services, period: .month) }
                        Divider()
                        // What to look for in a new Mac, from this one's use (D-181).
                        Button(String(localized: "Your Next Mac…", bundle: .strings)) { services.nextMac.open() }
                    } label: {
                        Label(String(localized: "Save Report", bundle: .strings), systemImage: "doc.richtext")
                    }
                    .fixedSize()
                    ShareLink(
                        item: WeeklyImageItem(report: report, colorScheme: colorScheme),
                        preview: SharePreview(
                            Text("Your week", bundle: .strings),
                            image: Image(nsImage: NSApplication.shared.applicationIconImage)
                        )
                    ) {
                        Label(String(localized: "Share Your Week", bundle: .strings), systemImage: "square.and.arrow.up")
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .cardStyle()
        .task(id: services.historyGeneration) {
            report = await WeeklyReportLoader.load(services)
        }
    }
}

/// The figures, shared by the card and the image.
struct YourWeekContent: View {
    let report: WeeklyReport
    @State private var width: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            HStack(spacing: Tokens.Spacing.xs) {
                Text((report.start ..< report.end).formatted(.interval.month(.abbreviated).day()))
                if let since = report.recordingSince {
                    let when = since.formatted(.dateTime.weekday(.abbreviated).hour().minute())
                    Text(verbatim: "·")
                    Text(
                        "Time in use recorded since \(when)", bundle: .strings,
                        comment: "Your week: time in front started recording during the week, e.g. since Mon 3:10 PM"
                    )
                }
            }
            .font(Tokens.Typography.secondary)
            .foregroundStyle(.secondary)
            // The day-by-day chart beside the figures when there's room, under them when not:
            // by measured width, so a figure can't flip the layout (D-174).
            if report.activeByDay.contains(where: { $0.seconds > 0 }) {
                if width >= Tokens.Layout.yourWeekSideBySideWidth {
                    HStack(alignment: .top, spacing: 0) {
                        // At their own width: squeezed, "0% more than the week before" wrapped.
                        figures.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: Tokens.Spacing.xl)
                        WeekDaysChart(days: report.activeByDay)
                            .frame(maxWidth: Tokens.Layout.weekDaysChartMaxWidth)
                    }
                } else {
                    figures
                    WeekDaysChart(days: report.activeByDay)
                }
            } else {
                figures
            }
            if !report.topApps.isEmpty {
                // Wraps in a narrow window rather than cutting the last app off.
                FlowLayout {
                    ForEach(report.topApps.prefix(4), id: \.app.id) { app in
                        HStack(spacing: Tokens.Spacing.xxs) {
                            AppIconView(app.app, size: Tokens.IconSize.small)
                            Text(app.app.name).lineLimit(1)
                            Text(Self.hours(app.value))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .font(Tokens.Typography.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var figures: some View {
        Grid(alignment: .leading, horizontalSpacing: Tokens.Spacing.l, verticalSpacing: Tokens.Spacing.m) {
            GridRow(alignment: .top) {
                tile(
                    String(localized: "In use", bundle: .strings, comment: "Your week: time the Mac was in use"),
                    Self.hours(report.activeSeconds),
                    note: change
                )
                tile(
                    String(localized: "Asleep a night", bundle: .strings, comment: "Your week: average sleep per night"),
                    report.averageSleepSeconds.map { Self.hours($0) } ?? "–"
                )
                tile(String(localized: "Data used", bundle: .strings), Formatters.bytes(report.dataBytes))
            }
            GridRow(alignment: .top) {
                tile(String(localized: "Written to disk", bundle: .strings), Formatters.bytes(report.writtenBytes))
                tile(String(localized: "Crashes", bundle: .strings, comment: "Your week: crash count"), report.crashes.formatted())
                tile(
                    String(localized: "Busiest day", bundle: .strings),
                    report.busiestDay.map { $0.formatted(.dateTime.weekday(.wide)) } ?? "–"
                )
            }
        }
    }

    private var change: String? {
        report.activeChange.map { value in
            let percent = Formatters.percent(abs(value) * 100)
            return value >= 0
                ? String(localized: "\(percent) more than the week before", bundle: .strings)
                : String(localized: "\(percent) less than the week before", bundle: .strings)
        }
    }

    private func tile(_ title: String, _ value: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
            Text(value)
                .font(Tokens.Typography.headline)
                .monospacedDigit()
                .lineLimit(1)
            if let note {
                Text(note)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "12h 3m"; with `units: 1`, "12h" (a bar's label).
    nonisolated static func hours(_ seconds: Double, units: Int = 2) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .narrow, maximumUnitCount: units))
    }
}

/// The shared image: the figures on the app's background, with the app's name and the week.
struct WeeklyImageView: View {
    static let width: CGFloat = 720
    let report: WeeklyReport

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            HStack(spacing: Tokens.Spacing.xs) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 28, height: 28)
                Text("My Mac this week", bundle: .strings, comment: "Title of the shared weekly image")
                    .font(Tokens.Typography.headline)
            }
            YourWeekContent(report: report)
            Text(verbatim: "Mactivity")
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
        }
        .padding(Tokens.Spacing.xl)
        .frame(width: Self.width, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// For `ShareLink`: the image, drawn when a destination is picked.
struct WeeklyImageItem: Transferable {
    let report: WeeklyReport
    let colorScheme: ColorScheme

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            let png = await MainActor.run {
                Customization.shared.atStandardSize {
                    ImageExport.pngData(
                        of: WeeklyImageView(report: item.report), width: WeeklyImageView.width, colorScheme: item.colorScheme
                    )
                }
            }
            guard let png else {
                throw CocoaError(.fileWriteUnknown)
            }
            return png
        }
        .suggestedFileName { _ in String(localized: "Your week", bundle: .strings) + ".png" }
    }
}
