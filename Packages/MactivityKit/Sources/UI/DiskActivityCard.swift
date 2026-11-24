import Core
import SwiftUI

/// The Disk tab's totals (D-097): data read and written since startup (from the disks' own
/// counters, like Activity Monitor) and today, this week, this month and this year (the counters
/// plus history from before startup, D-112), the operation counts, and which apps wrote the most
/// today.
struct DiskActivityCard: View {
    let services: AppServices

    @State private var spans: [Span: (read: SpanTotal, written: SpanTotal)] = [:]
    @State private var writers: [AppTotal] = []

    enum Span: CaseIterable, Hashable {
        case today, week, month, year

        var title: String {
            switch self {
            case .today: String(localized: "Today", bundle: .strings)
            case .week: String(localized: "7 days", bundle: .strings)
            case .month: String(localized: "30 days", bundle: .strings)
            case .year: String(localized: "Year", bundle: .strings, comment: "Disk totals over the last year")
            }
        }

        func start(now: Date, calendar: Calendar = .current) -> Date {
            switch self {
            case .today: calendar.startOfDay(for: now)
            case .week: now.addingTimeInterval(-7 * 86400)
            case .month: now.addingTimeInterval(-30 * 86400)
            case .year: now.addingTimeInterval(-365 * 86400)
            }
        }
    }

    var body: some View {
        let disk = services.metrics.snapshot?.system.disk
        HStack(alignment: .top, spacing: Tokens.Spacing.l) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                Grid(alignment: .trailing, horizontalSpacing: Tokens.Spacing.m, verticalSpacing: Tokens.Spacing.xxs) {
                    GridRow {
                        Text(verbatim: "")
                        Text("Since startup", bundle: .strings)
                        ForEach(Span.allCases, id: \.self) { Text($0.title) }
                    }
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    row(
                        String(localized: "Read", bundle: .strings, comment: "Disk totals row: data read"),
                        live: disk?.totals.map { Double($0.bytesRead) },
                        \.read,
                        tint: MetricTab.disk.tint
                    )
                    row(
                        String(localized: "Written", bundle: .strings, comment: "Disk totals row: data written"),
                        live: disk?.totals.map { Double($0.bytesWritten) },
                        \.written,
                        tint: .red
                    )
                }
                .monospacedDigit()
                Text(operationsLine(disk))
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(2)
            }
            .layoutPriority(1)
            Divider()
            VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                Text("Written today", bundle: .strings, comment: "Disk tab: apps that wrote the most today")
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                if writers.isEmpty {
                    Text("Nothing recorded yet.", bundle: .strings)
                        .foregroundStyle(.secondary)
                }
                ForEach(writers.prefix(4), id: \.app.id) { writer in
                    HStack(spacing: Tokens.Spacing.xs) {
                        AppIconView(writer.app, size: Tokens.IconSize.small)
                        Text(writer.app.name).lineLimit(1)
                        Spacer(minLength: Tokens.Spacing.xs)
                        Text(Formatters.bytes(writer.value))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    // As every app row that names a figure: a click opens its history (D-196).
                    .contentShape(.rect)
                    .onTapGesture { services.appHistory.open(writer.app) }
                    .accessibilityAddTraits(.isButton)
                    .help(Text(
                        "Show \(writer.app.name)’s history",
                        bundle: .strings,
                        comment: "Tooltip on a top app: opens its history page"
                    ))
                }
            }
            // Room for a name like "Claude Code" beside its figure: the totals grid is wider
            // than it needs to be and would otherwise take it all.
            .frame(minWidth: 220, maxWidth: 300, alignment: .leading)
        }
        .cardStyle()
        // Also when the first snapshot arrives: the totals need its startup counters, and a card
        // opened at launch otherwise showed history alone for five minutes (D-115).
        .task(id: LoadKey(generation: services.historyGeneration, hasSnapshot: services.metrics.hasSnapshot)) {
            // History moves by the minute; every five is plenty for totals this size.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private func row(
        _ title: String, live: Double?, _ path: KeyPath<(read: SpanTotal, written: SpanTotal), SpanTotal>, tint: Color
    ) -> some View {
        GridRow {
            HStack(spacing: Tokens.Spacing.xxs) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(title)
            }
            .gridColumnAlignment(.leading)
            Text(live.map { Formatters.bytes($0) } ?? "–")
                .font(Tokens.Typography.cardTitle)
            ForEach(Span.allCases, id: \.self) { span in
                let total = spans[span]?[keyPath: path]
                Text(total.map(Self.text) ?? "–")
                    .help(total?.isLowerBound == true ? Self.lowerBoundHelp : "")
            }
        }
    }

    /// "1.2 TB", or "≥ 1.2 TB" when history starts inside the span (D-112).
    nonisolated static func text(_ total: SpanTotal) -> String {
        total.isLowerBound ? "≥ \(Formatters.bytes(total.value))" : Formatters.bytes(total.value)
    }

    private static let lowerBoundHelp = String(
        localized: "At least this much. Mactivity started recording partway through, so earlier use isn't counted.",
        bundle: .strings, comment: "Disk totals: a figure shown with ≥"
    )

    /// Large counts the short way: "35M", "812K", "940" (D-112).
    nonisolated static func count(_ value: UInt64) -> String {
        value.formatted(.number.notation(.compactName).precision(.significantDigits(1 ... 3)))
    }

    /// "Since startup: 35M reads, 63M writes · Per second now: reads 1, writes 174 · about 9.8 GB
    /// written a day". Counts are short, and a count after a colon reads right for 1 too.
    private func operationsLine(_ disk: DiskStats?) -> String {
        var parts: [String] = []
        if let reads = disk?.totals?.reads, let writes = disk?.totals?.writes {
            parts.append(String(
                localized: "Since startup: \(Self.count(reads)) reads, \(Self.count(writes)) writes",
                bundle: .strings, comment: "Disk operation counts, short: 35M reads. Like Activity Monitor's Reads in and Writes out"
            ))
        }
        if let reads = disk?.readsPerSecond, let writes = disk?.writesPerSecond {
            parts.append(String(
                localized: "Per second now: reads \(Int(reads.rounded()).formatted()), writes \(Int(writes.rounded()).formatted())",
                bundle: .strings, comment: "Disk operations a second right now"
            ))
        }
        if let month = spans[.month]?.written, !month.isLowerBound, month.value > 0 {
            let month = month.value
            parts.append(String(
                localized: "about \(Formatters.bytes(month / 30)) written a day",
                bundle: .strings, comment: "Average data written a day over the last 30 days"
            ))
        }
        return parts.joined(separator: " · ")
    }

    private struct LoadKey: Hashable {
        let generation: Int
        let hasSnapshot: Bool
    }

    private func load() async {
        // Without the startup counters and uptime, every span would read as history alone.
        guard let store = services.history as? any DailyHistoryStore, services.metrics.snapshot != nil else {
            return
        }
        let now = Date()
        let system = services.metrics.snapshot?.system
        let boot = now.addingTimeInterval(-TimeInterval(system?.uptime.components.seconds ?? 0))
        let counters = system?.disk.totals
        let first = await (try? store.firstRecorded()).flatMap { $0 }
        var found: [Span: (read: SpanTotal, written: SpanTotal)] = [:]
        for span in Span.allCases {
            let start = span.start(now: now)
            func total(_ metric: Metric, sinceStartup: UInt64?) async -> SpanTotal {
                let before = start < boot ? await (try? store.systemTotal(metrics: [metric], from: start, to: boot)) ?? 0 : 0
                let since = await (try? store.systemTotal(metrics: [metric], from: start, to: now)) ?? 0
                return SpanTotal.combine(
                    spanStart: start, boot: boot, sinceStartup: sinceStartup,
                    historyBeforeBoot: before, historySinceStart: since, firstRecorded: first
                )
            }
            found[span] = await (
                total(.diskRead, sinceStartup: counters?.bytesRead),
                total(.diskWrite, sinceStartup: counters?.bytesWritten)
            )
        }
        let today = Span.today.start(now: now)
        let top = await (try? store.totals(metrics: [.diskWrite], from: today, to: now, limit: 4)) ?? []
        guard !Task.isCancelled else {
            return
        }
        spans = found
        writers = top
    }
}
