import Core
import SwiftUI

/// What wears your SSD on the Disk tab (D-281): the apps that wrote the most over the last 30
/// days, beside what the internal drive says it has written over its life. Read when the card
/// shows and when history changes; the queries are the ones the totals on this tab run.
struct SSDWearCard: View {
    let services: AppServices
    @State private var report: SSDWearReport?

    var body: some View {
        SSDWearContent(report: report) { services.appHistory.open($0) }
            .task(id: services.historyGeneration) { await load() }
    }

    private func load() async {
        guard let store = services.history as? any DailyHistoryStore else {
            return
        }
        let now = Date()
        let start = now.addingTimeInterval(-SSDWearReport.span)
        let totals = await (try? store.totals(metrics: [.diskWrite], from: start, to: now, limit: 6)) ?? []
        let system = await (try? store.systemTotal(metrics: [.diskWrite], from: start, to: now)) ?? 0
        let first = await (try? store.firstRecorded()).flatMap { $0 }
        let drives = await services.driveHealth.drives()
        guard !Task.isCancelled else {
            return
        }
        report = SSDWearReport.make(totals: totals, allDrivesWritten: system, firstRecorded: first, drives: drives, now: now)
    }
}

/// The card itself, given a report: render tests.
struct SSDWearContent: View {
    let report: SSDWearReport?
    let openApp: (AppIdentity) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text("What wears your SSD", bundle: .strings)
                .font(Tokens.Typography.cardTitle)
            HStack(alignment: .top, spacing: Tokens.Spacing.l) {
                writers
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                drive
                    .frame(minWidth: 200, maxWidth: 280, alignment: .leading)
            }
            Text(
                """
                Apps' figures count what they wrote to any drive. macOS doesn't record which drive an app wrote to, \
                so anything written to an external drive is in here too. Only the drive's own figure is that drive alone.
                """,
                bundle: .strings
            )
            .font(Tokens.Typography.secondary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }

    private var writers: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
            Text(Self.spanTitle(report))
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
            if let report, !report.writers.isEmpty {
                ForEach(report.writers, id: \.app.id) { writer in
                    HStack(spacing: Tokens.Spacing.xs) {
                        AppIconView(writer.app, size: Tokens.IconSize.small)
                        Text(writer.app.name).lineLimit(1)
                        Spacer(minLength: Tokens.Spacing.xs)
                        Text(Formatters.bytes(writer.value))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                    .onTapGesture { openApp(writer.app) }
                    .accessibilityAddTraits(.isButton)
                    .help(Text(
                        "Show \(writer.app.name)’s history",
                        bundle: .strings,
                        comment: "Tooltip on a top app: opens its history page"
                    ))
                }
                Text(Self.allDrivesLine(report))
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.top, Tokens.Spacing.xxs)
                    .help(Text(
                        """
                        What every drive in this Mac counted. It's usually more than the apps add up to: the file system's \
                        own work and programs that ran between readings aren't charged to an app.
                        """,
                        bundle: .strings
                    ))
            } else {
                Text("Nothing recorded yet.", bundle: .strings)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var drive: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
            Text("The internal drive's own count", bundle: .strings)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
            if let drive = report?.internalDrive {
                Text(Formatters.bytes(drive.bytesWritten))
                    .font(Tokens.Typography.cardTitle)
                    .monospacedDigit()
                Text("written over its life", bundle: .strings, comment: "SSD wear card, under a figure: 10 TB written over its life")
                    .foregroundStyle(.secondary)
                Text(
                    "\(Formatters.percent(Double(drive.percentUsed))) of rated life used",
                    bundle: .strings,
                    comment: "Drive wear, e.g. 2% of rated life used"
                )
                .foregroundStyle(.secondary)
                .monospacedDigit()
                Text(drive.model)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("This drive doesn't report what it has written.", bundle: .strings)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(Text("The figure the drive keeps itself, since it was made. It's what counts against an SSD's rated life.", bundle: .strings))
    }

    /// "Written by each app, last 30 days", or since the day history starts.
    nonisolated static func spanTitle(_ report: SSDWearReport?) -> String {
        guard let report, report.startsLate else {
            return String(localized: "Written by each app, last 30 days", bundle: .strings)
        }
        let date = report.since.formatted(date: .abbreviated, time: .omitted)
        return String(
            localized: "Written by each app since \(date)",
            bundle: .strings,
            comment: "SSD wear card: history starts on this date"
        )
    }

    nonisolated static func allDrivesLine(_ report: SSDWearReport) -> String {
        let total = Formatters.bytes(report.allDrivesWritten)
        return String(
            localized: "All drives together: \(total)",
            bundle: .strings,
            comment: "SSD wear card: everything written over the span"
        )
    }
}
