import AppKit
import Charts
import Core
import Export
import os
import SwiftUI

/// The report as a two-page US Letter PDF (D-159): figures, a day-by-day CPU chart and the
/// busiest hour on the first page; the busiest apps, alerts and crashes on the second. Drawn by
/// SwiftUI into a PDF context, so text stays text: searchable and sharp when printed.
@MainActor
public enum ReportPDF {
    static let pageSize = CGSize(width: 612, height: 792)
    private static let log = Logger(subsystem: "app.mactivity.ui", category: "report")

    public static func data(_ report: UsageReport) -> Data? {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            return nil
        }
        let pages: [AnyView] = [AnyView(ReportFirstPage(report: report)), AnyView(ReportSecondPage(report: report))]
        for page in pages {
            let renderer = ImageRenderer(content: page
                .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
                .background(Color.white)
                .environment(\.colorScheme, .light))
            renderer.proposedSize = ProposedViewSize(pageSize)
            context.beginPDFPage(nil)
            // The page's layout is fixed, whatever size the windows' figures are (D-276).
            Customization.shared.atStandardSize {
                renderer.render { _, draw in draw(context) }
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    @MainActor private static var isPreparing = false

    /// Asks where to save, writes the PDF, and shows it in Finder.
    public static func save(_ services: AppServices, period: UsageReport.Period) {
        // A month takes a moment to read: say so, and don't stack a second save panel behind the
        // first when the menu item is chosen again meanwhile (D-196).
        guard !isPreparing else {
            return
        }
        isPreparing = true
        services.show(toast: String(localized: "Preparing the report…", bundle: .strings))
        Task {
            let report = await UsageReportLoader.load(services, period: period, mac: "\(MacModel.name()), \(MacModel.chip())")
            isPreparing = false
            let panel = NSSavePanel()
            panel.title = String(localized: "Save Report", bundle: .strings)
            panel.nameFieldStringValue = fileName(report)
            panel.allowedContentTypes = [.pdf]
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            guard panel.runModal() == .OK, let url = panel.url else {
                return
            }
            guard let pdf = data(report) else {
                services.show(toast: String(localized: "The report couldn't be made.", bundle: .strings))
                return
            }
            do {
                try pdf.write(to: url, options: .atomic)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                log.error("Report: write failed")
                services.show(toast: String(localized: "The report couldn't be saved there.", bundle: .strings))
            }
        }
    }

    /// "Mactivity Report, Oct 4 – 11, 2026.pdf".
    static func fileName(_ report: UsageReport) -> String {
        String(localized: "Mactivity Report, \(ReportText.range(report)).pdf", bundle: .strings, comment: "Report file name; a date range")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
    }
}

enum ReportText {
    /// "Oct 4 – 11, 2026": the system's own range format, in the person's language.
    static func range(_ report: UsageReport) -> String {
        (report.start ..< report.end).formatted(.interval.month(.abbreviated).day().year())
    }

    static func title(_ report: UsageReport) -> String {
        switch report.period {
        case .week: String(localized: "Your Mac this week", bundle: .strings, comment: "Report title")
        case .month: String(localized: "Your Mac this month", bundle: .strings, comment: "Report title")
        }
    }

    /// "12% more than the period before"; under half a percent either way, "about the same".
    static func change(_ fraction: Double) -> String {
        guard abs(fraction) >= 0.005 else {
            return String(localized: "About the same as the period before", bundle: .strings)
        }
        let change = Formatters.percent(abs(fraction) * 100)
        return fraction > 0
            ? String(localized: "\(change) more than the period before", bundle: .strings)
            : String(localized: "\(change) less than the period before", bundle: .strings)
    }

    static func hours(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .narrow, maximumUnitCount: 2))
    }
}

private struct ReportFrame<Content: View>: View {
    let report: UsageReport
    let page: Int
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ReportText.title(report)).font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text([ReportText.range(report), report.mac].compactMap(\.self).joined(separator: " · "))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            content
            Spacer(minLength: 0)
            HStack {
                Text("Made by Mactivity from this Mac's own history. Nothing in it left the Mac.", bundle: .strings)
                Spacer()
                Text(verbatim: "\(page) / 2")
            }
            .font(.system(size: 8))
            .foregroundStyle(.secondary)
        }
        .padding(40)
        .foregroundStyle(.black)
    }
}

private struct Tile: View {
    let title: String
    let value: String
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
            if let note {
                Text(note).font(.system(size: 8.5)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
        .padding(10)
        .background(Color(white: 0.96), in: .rect(cornerRadius: 8))
    }
}

struct ReportFirstPage: View {
    let report: UsageReport

    var body: some View {
        ReportFrame(report: report, page: 1) {
            let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
            LazyVGrid(columns: columns, spacing: 10) {
                Tile(
                    title: String(localized: "Time in use", bundle: .strings), value: ReportText.hours(report.activeSeconds),
                    note: report.activeChange.map(ReportText.change)
                )
                Tile(
                    title: String(localized: "Processor", bundle: .strings, comment: "Report tile: CPU"),
                    value: report.averageCPU.map { Formatters.percent($0) } ?? "–",
                    note: report.peakCPU.map {
                        String(localized: "on average; peak \(Formatters.percent($0))", bundle: .strings, comment: "Report: CPU peak")
                    }
                )
                Tile(
                    title: String(localized: "Memory pressure", bundle: .strings),
                    value: report.averageMemoryPressure.map { Formatters.percent($0) } ?? "–",
                    note: report.peakSwapBytes.flatMap { $0 > 0 ? $0 : nil }.map {
                        String(localized: "on average; swap up to \(Formatters.memory($0))", bundle: .strings)
                    }
                )
                Tile(title: String(localized: "Written to disk", bundle: .strings), value: Formatters.bytes(report.writtenBytes))
                Tile(title: String(localized: "Network data", bundle: .strings), value: Formatters.bytes(report.networkBytes))
                Tile(
                    title: String(localized: "Sleep", bundle: .strings, comment: "Report tile: average sleep per night"),
                    value: report.averageSleepSeconds.map(ReportText.hours) ?? "–",
                    note: report.averageSleepSeconds == nil ? nil : String(localized: "asleep per night, on average", bundle: .strings)
                )
                if let onBattery = report.onBatterySeconds {
                    Tile(
                        title: String(localized: "On battery", bundle: .strings), value: ReportText.hours(onBattery),
                        note: report.batteryHealthPercent.map {
                            String(localized: "Battery health \(Formatters.percent($0))", bundle: .strings)
                        }
                    )
                }
                Tile(
                    title: String(localized: "Problems", bundle: .strings, comment: "Report tile: alerts and crashes"),
                    value: (report.alerts.reduce(0) { $0 + $1.count } + report.crashes.reduce(0) { $0 + $1.count }).formatted(),
                    note: String(localized: "alerts and app crashes", bundle: .strings)
                )
            }
            if !report.dailyCPU.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Processor, day by day", bundle: .strings).font(.system(size: 11, weight: .semibold))
                    Chart(report.dailyCPU, id: \.day) { day in
                        BarMark(x: .value("Day", day.day, unit: .day), y: .value("CPU", day.average))
                            .foregroundStyle(Color(red: 0.18, green: 0.48, blue: 1))
                            .cornerRadius(2)
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel { Text(Formatters.percent(value.as(Double.self) ?? 0)) }
                        }
                    }
                    .frame(height: 150)
                }
            }
            if let peak = report.peak {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The busiest hour", bundle: .strings).font(.system(size: 11, weight: .semibold))
                    let when = peak.start.formatted(.dateTime.weekday(.wide).month().day().hour())
                    let cpu = Formatters.percent(peak.cpuPercent)
                    Text("\(when): the processor averaged \(cpu).", bundle: .strings)
                        .font(.system(size: 10))
                    if !peak.apps.isEmpty {
                        let apps = peak.apps.map { "\($0.app.name) \(Formatters.percent($0.value, fractionDigits: 1))" }
                            .formatted(.list(type: .and))
                        Text("Working hardest: \(apps)", bundle: .strings).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct ReportSecondPage: View {
    let report: UsageReport

    var body: some View {
        ReportFrame(report: report, page: 2) {
            let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                list(String(localized: "In front the longest", bundle: .strings), report.inFront) { ReportText.hours($0) }
                list(String(localized: "Most processor", bundle: .strings), report.byCPU) {
                    String(localized: "\(Formatters.percent($0, fractionDigits: 1)) on average", bundle: .strings)
                }
                list(String(localized: "Most memory", bundle: .strings), report.byMemory) {
                    String(localized: "\(Formatters.memory($0)) on average", bundle: .strings)
                }
                list(String(localized: "Most energy", bundle: .strings), report.byEnergy) {
                    String(localized: "\(Formatters.percent($0)) of all", bundle: .strings)
                }
            }
            counts(
                String(localized: "Alerts", bundle: .strings),
                report.alerts,
                empty: String(localized: "No alerts in this period.", bundle: .strings)
            )
            counts(
                String(localized: "App crashes", bundle: .strings),
                report.crashes,
                empty: String(localized: "No app crashed in this period.", bundle: .strings)
            )
        }
    }

    private func list(_ title: String, _ apps: [AppTotal], value: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .semibold))
            if apps.isEmpty {
                Text("Not enough history yet.", bundle: .strings).font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            ForEach(Array(apps.enumerated()), id: \.element.app.id) { index, app in
                HStack(spacing: 6) {
                    Text(verbatim: "\(index + 1).").foregroundStyle(.secondary).frame(width: 14, alignment: .trailing)
                    Text(app.app.name).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(value(app.value)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.system(size: 9.5))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func counts(_ title: String, _ counts: [UsageReport.Count], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .semibold))
            if counts.isEmpty {
                Text(empty).font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            ForEach(counts.prefix(8)) { count in
                HStack {
                    Text(count.name).lineLimit(1)
                    Spacer()
                    Text(count.count.formatted()).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.system(size: 9.5))
            }
        }
    }
}
