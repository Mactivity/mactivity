import Core
import SwiftUI

/// Your day (D-191): one day of History told as what happened, under the year calendar's
/// day. Everything comes from what Mactivity already recorded; nothing new is sampled.
@MainActor
enum DayStoryLoader {
    static func load(_ services: AppServices, day: Date, now: Date = Date()) async -> DayStoryResult {
        let start = Calendar.current.startOfDay(for: day)
        return await DayStoryReader.read(
            day: day, now: now, history: services.history, hasBattery: services.metrics.hardware.hasBattery,
            alerts: services.alertLog, crashes: CrashFilter.relevant(services.crashReports.reports(since: start))
        )
    }
}

/// The day's events as a timeline: the time, a symbol, what happened, the apps behind it.
struct DayTimeline: View {
    /// What History scrolls to when asked for a day (D-194).
    static let anchor = "yourDay"
    let services: AppServices
    let day: Date
    let generation: Int
    @State private var result: DayStoryResult?
    @State private var noteDraft: NoteDraft?
    @State private var shownDay: Date?
    /// Bumped after a note is saved or deleted, to read the day again.
    @State private var notesChanged = 0

    private var notes: (any NoteStore)? {
        services.history as? any NoteStore
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your day", bundle: .strings, comment: "Year calendar: the selected day told as a timeline")
                    .font(Tokens.Typography.cardTitle)
                if let result, result.activeSeconds >= 60 {
                    Text(
                        "\(YourWeekContent.hours(result.activeSeconds)) in use",
                        bundle: .strings,
                        comment: "Your day: time in use, e.g. 5h 12m in use"
                    )
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if notes != nil {
                    Button(String(localized: "Add Note…", bundle: .strings, comment: "Your day: pins a note to a time that day")) {
                        noteDraft = NoteDraft(note: nil, day: day)
                    }
                    .controlSize(.small)
                }
                Button(String(localized: "Compare…", bundle: .strings, comment: "Opens two days side by side")) {
                    services.compare.open(day: day)
                }
                .controlSize(.small)
            }
            if let result {
                if result.events.isEmpty {
                    Text("A quiet day: no slowdowns, busy stretches, alerts or crashes.", bundle: .strings)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(result.events.enumerated()), id: \.element.id) { index, event in
                            DayEventRow(event: event, apps: result.apps[event.id] ?? [], isLast: index == result.events.count - 1) { app in
                                services.appHistory.open(app)
                            }
                            .contextMenu {
                                if case let .note(id, text) = event.kind {
                                    Button(String(localized: "Edit Note…", bundle: .strings)) {
                                        noteDraft = NoteDraft(note: HistoryNote(id: id, at: event.start, text: text), day: day)
                                    }
                                }
                            }
                            .onTapGesture {
                                if case let .note(id, text) = event.kind {
                                    noteDraft = NoteDraft(note: HistoryNote(id: id, at: event.start, text: text), day: day)
                                }
                            }
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(Self.anchor)
        .sheet(item: $noteDraft) { draft in
            HistoryNoteEditor(draft: draft) { note in
                Task {
                    try? await notes?.saveNote(note)
                    notesChanged += 1
                }
            } delete: { note in
                Task {
                    try? await notes?.deleteNote(id: note.id)
                    notesChanged += 1
                }
            }
        }
        .task(id: DayKey(day: day, generation: generation, notes: notesChanged)) {
            // Another day starts empty; the same day, read again after a note, doesn't flash.
            if shownDay != day {
                result = nil
                shownDay = day
            }
            result = await DayStoryLoader.load(services, day: day)
            // Today keeps happening: read again every 5 minutes while it shows (D-219).
            while Calendar.current.isDateInToday(day), !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else {
                    return
                }
                result = await DayStoryLoader.load(services, day: day)
            }
        }
    }

    private struct DayKey: Hashable {
        let day: Date
        let generation: Int
        let notes: Int
    }
}

private struct DayEventRow: View {
    let event: DayEvent
    let apps: [AppIdentity]
    let isLast: Bool
    let showHistory: (AppIdentity) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.s) {
            Text(time)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: Tokens.Layout.dayTimelineTimeWidth, alignment: .trailing)
            // A dot per event, colored by what it was; the thread joining them is the row's
            // background, so it's exactly as tall as the row and never makes it taller.
            Image(systemName: DayEventText.symbol(event.kind))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DayEventText.tint(event.kind))
                .frame(width: Self.dot, height: Self.dot)
                .background(DayEventText.tint(event.kind).opacity(0.15), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(DayEventText.title(event))
                if !apps.isEmpty {
                    FlowLayout(spacing: Tokens.Spacing.s, lineSpacing: 2) {
                        ForEach(apps) { app in
                            HStack(spacing: Tokens.Spacing.xxs) {
                                AppIconView(app, size: Tokens.IconSize.small)
                                Text(app.name)
                            }
                            .font(Tokens.Typography.secondary)
                            .foregroundStyle(.secondary)
                            .contentShape(.rect)
                            .onTapGesture { showHistory(app) }
                            .help(Text(
                                "Show \(app.name)’s history",
                                bundle: .strings,
                                comment: "Tooltip on a top app: opens its history page"
                            ))
                        }
                    }
                }
            }
            .padding(.top, 2)
            .padding(.bottom, isLast ? 0 : Tokens.Spacing.s)
            Spacer(minLength: 0)
        }
        .background(alignment: .topLeading) {
            if !isLast {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1.5)
                    .padding(.top, Self.dot)
                    .padding(.leading, Tokens.Layout.dayTimelineTimeWidth + Tokens.Spacing.s + Self.dot / 2 - 0.75)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private static let dot: CGFloat = 22

    /// "9:00 AM", or "9:00 – 10:30 AM" for a stretch; times only for one that runs to midnight,
    /// where the interval style would add both dates.
    private var time: String {
        let start = event.start.formatted(date: .omitted, time: .shortened)
        guard let end = event.end else {
            return start
        }
        guard Calendar.current.isDate(event.start, inSameDayAs: end) else {
            return "\(start) – \(end.formatted(date: .omitted, time: .shortened))"
        }
        return (event.start ..< end).formatted(.interval.hour().minute())
    }
}
