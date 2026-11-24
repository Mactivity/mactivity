import AppKit
import Core
import CoreTransferable
import Export
import SwiftUI

/// History → Looking back (1.7, D-254): Your month and Your year, one span at a time, with
/// the arrows to go back, and a Share button for its image.
struct LookingBackCard: View {
    let services: AppServices
    @Environment(\.colorScheme) private var colorScheme
    @State private var span: PeriodRecap.Span
    /// A date inside the month or year shown.
    @State private var anchor: Date
    @State private var recap: PeriodRecap?
    @State private var first: Date?

    init(services: AppServices, now: Date = Date()) {
        self.services = services
        let opening = Self.opening(now: now)
        _span = State(initialValue: opening.span)
        _anchor = State(initialValue: opening.anchor)
    }

    /// Your year in December, and last year's until mid-January (D-254); the month otherwise.
    static func opening(now: Date, calendar: Calendar = .current) -> (span: PeriodRecap.Span, anchor: Date) {
        let parts = calendar.dateComponents([.month, .day], from: now)
        if parts.month == 12 {
            return (.year, now)
        }
        if parts.month == 1, (parts.day ?? 99) <= 15, let lastYear = calendar.date(byAdding: .year, value: -1, to: now) {
            return (.year, lastYear)
        }
        return (.month, now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            HStack(spacing: Tokens.Spacing.s) {
                Picker(String(localized: "Span", bundle: .strings, comment: "Looking back: month or year"), selection: $span) {
                    Text("Month", bundle: .strings, comment: "Looking back: one month").tag(PeriodRecap.Span.month)
                    Text("Year", bundle: .strings, comment: "Looking back: one year").tag(PeriodRecap.Span.year)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button { move(-1) } label: {
                    Image(systemName: "chevron.left")
                        .accessibilityLabel(Text("Earlier", bundle: .strings, comment: "Looking back: the month or year before"))
                }
                .disabled(!canMove(-1))
                Text(LookingBackContent.title(span, anchor))
                    .font(Tokens.Typography.rowTitle)
                    .monospacedDigit()
                    .frame(minWidth: 110)
                Button { move(1) } label: {
                    Image(systemName: "chevron.right")
                        .accessibilityLabel(Text("Later", bundle: .strings, comment: "Looking back: the month or year after"))
                }
                .disabled(!canMove(1))
            }
            .buttonStyle(.borderless)
            if let recap {
                if recap.isEmpty {
                    Text("Nothing recorded then.", bundle: .strings, comment: "Looking back: a month or year with no history")
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    LookingBackContent(recap: recap)
                    HStack {
                        Spacer()
                        ShareLink(
                            item: RecapImageItem(recap: recap, colorScheme: colorScheme),
                            preview: SharePreview(
                                Text(LookingBackContent.imageTitle(recap)),
                                image: Image(nsImage: NSApplication.shared.applicationIconImage)
                            )
                        ) {
                            Label(LookingBackContent.shareTitle(recap.span), systemImage: "square.and.arrow.up")
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .cardStyle()
        .task(id: Key(span: span, anchor: anchor, generation: services.historyGeneration)) {
            recap = nil
            first = await (try? (services.history as? any FocusStore)?.firstFocus()).flatMap(\.self)
            recap = await LookingBackLoader.load(services, span: span, containing: anchor)
        }
    }

    private struct Key: Hashable {
        let span: PeriodRecap.Span
        let anchor: Date
        let generation: Int
    }

    private func moved(_ step: Int) -> Date? {
        Calendar.current.date(byAdding: span == .month ? .month : .year, value: step, to: anchor)
    }

    /// Not past now, and not before the month or year History starts in.
    private func canMove(_ step: Int) -> Bool {
        guard let target = moved(step) else {
            return false
        }
        let interval = LookingBack.interval(span, containing: target, now: .distantFuture)
        if step > 0 {
            return interval.start <= Date()
        }
        return first.map { interval.end > $0 } ?? false
    }

    private func move(_ step: Int) {
        if let target = moved(step) {
            anchor = target
        }
    }
}

/// The figures, shared by the card and the image.
struct LookingBackContent: View {
    let recap: PeriodRecap

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            if let since = recap.recordingSince {
                Text(
                    "Recorded since \(since.formatted(date: .abbreviated, time: .omitted))",
                    bundle: .strings,
                    comment: "Looking back: History started during this month or year"
                )
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: Tokens.Spacing.l, verticalSpacing: Tokens.Spacing.m) {
                GridRow(alignment: .top) {
                    tile(String(localized: "In use", bundle: .strings), YourWeekContent.hours(recap.activeSeconds), note: change)
                    tile(String(localized: "Busiest day", bundle: .strings), busiestDay, note: busiestDayHours)
                    if let month = recap.busiestMonth {
                        tile(
                            String(localized: "Busiest month", bundle: .strings),
                            month.day.formatted(.dateTime.month(.wide)),
                            note: YourWeekContent.hours(month.seconds, units: 1)
                        )
                    } else {
                        tile(String(localized: "Slowdowns", bundle: .strings), recap.slowdowns.formatted())
                    }
                }
                GridRow(alignment: .top) {
                    tile(String(localized: "Data used", bundle: .strings), Formatters.bytes(recap.dataBytes))
                    tile(String(localized: "Written to disk", bundle: .strings), Formatters.bytes(recap.writtenBytes))
                    if recap.agentSeconds >= 60 {
                        tile(
                            String(localized: "Agents worked", bundle: .strings, comment: "Looking back: coding agents' time"),
                            YourWeekContent.hours(recap.agentSeconds, units: 1),
                            note: recap.topAgentProject
                        )
                    } else if let crashes = recap.crashes {
                        tile(String(localized: "Crashes", bundle: .strings, comment: "Your week: crash count"), crashes.formatted())
                    } else {
                        tile(String(localized: "Slowdowns", bundle: .strings), recap.slowdowns.formatted())
                    }
                }
            }
            if !recap.topApps.isEmpty {
                apps(String(localized: "Most used", bundle: .strings, comment: "Looking back: apps by time in front"), recap.topApps)
            }
            if !recap.came.isEmpty {
                apps(
                    recap.span == .month
                        ? String(localized: "New this month", bundle: .strings, comment: "Looking back: apps not used the month before")
                        : String(localized: "New this year", bundle: .strings, comment: "Looking back: apps not used the year before"),
                    recap.came
                )
            }
            if !recap.went.isEmpty {
                apps(
                    recap.span == .month
                        ? String(
                            localized: "Not used this month",
                            bundle: .strings,
                            comment: "Looking back: apps used the month before only"
                        )
                        : String(
                            localized: "Not used this year",
                            bundle: .strings,
                            comment: "Looking back: apps used the year before only"
                        ),
                    recap.went,
                    hours: false
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var change: String? {
        recap.activeChange.map { value in
            let percent = Formatters.percent(abs(value) * 100)
            return switch (recap.span, value >= 0) {
            case (.month, true): String(localized: "\(percent) more than the month before", bundle: .strings)
            case (.month, false): String(localized: "\(percent) less than the month before", bundle: .strings)
            case (.year, true): String(localized: "\(percent) more than the year before", bundle: .strings)
            case (.year, false): String(localized: "\(percent) less than the year before", bundle: .strings)
            }
        }
    }

    private var busiestDay: String {
        recap.busiestDays.first.map { $0.day.formatted(.dateTime.month(.abbreviated).day()) } ?? "–"
    }

    private var busiestDayHours: String? {
        recap.busiestDays.first.map { YourWeekContent.hours($0.seconds) }
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
                    .lineLimit(1)
            }
        }
    }

    private func apps(_ title: String, _ apps: [AppTotal], hours: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
            Text(title)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
            FlowLayout {
                ForEach(apps) { app in
                    HStack(spacing: Tokens.Spacing.xxs) {
                        AppIconView(app.app, size: Tokens.IconSize.small)
                        Text(app.app.name).lineLimit(1)
                        if hours {
                            Text(YourWeekContent.hours(app.value, units: 1))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .font(Tokens.Typography.secondary)
        }
    }

    /// "October 2026", "2026".
    static func title(_ span: PeriodRecap.Span, _ date: Date) -> String {
        span == .month ? date.formatted(.dateTime.month(.wide).year()) : date.formatted(.dateTime.year())
    }

    /// "My Mac in October", "My Mac in 2026".
    static func imageTitle(_ recap: PeriodRecap) -> String {
        let when = recap.span == .month
            ? recap.interval.start.formatted(.dateTime.month(.wide))
            : recap.interval.start.formatted(.dateTime.year())
        return String(
            localized: "My Mac in \(when)",
            bundle: .strings,
            comment: "Title of the shared Looking back image: a month (October) or a year (2026)"
        )
    }

    static func shareTitle(_ span: PeriodRecap.Span) -> String {
        span == .month
            ? String(localized: "Share Your Month", bundle: .strings)
            : String(localized: "Share Your Year", bundle: .strings)
    }
}

/// The shared image: the figures, with the app's name and the month or year.
struct RecapImageView: View {
    static let width: CGFloat = 720
    let recap: PeriodRecap

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            HStack(spacing: Tokens.Spacing.xs) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 28, height: 28)
                Text(LookingBackContent.imageTitle(recap))
                    .font(Tokens.Typography.headline)
            }
            LookingBackContent(recap: recap)
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
struct RecapImageItem: Transferable {
    let recap: PeriodRecap
    let colorScheme: ColorScheme

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            let png = await MainActor.run {
                Customization.shared.atStandardSize {
                    ImageExport.pngData(of: RecapImageView(recap: item.recap), width: RecapImageView.width, colorScheme: item.colorScheme)
                }
            }
            guard let png else {
                throw CocoaError(.fileWriteUnknown)
            }
            return png
        }
        .suggestedFileName { item in LookingBackContent.imageTitle(item.recap) + ".png" }
    }
}
