import AppKit
import Core
import Observation
import SwiftUI

/// Notifications by app's recording (D-289). macOS's own record lasts about a day, so Mactivity
/// copies it into History every three hours, on its own task; a tick only compares two dates. A
/// read is about 0.4 s of processor, which is about 0.003% of a core, plus one when the card opens
/// if the last is over five minutes old. Each read starts from the last good one, so what came in
/// while Mactivity was closed is filled in, as far as the log still has it.
@MainActor
@Observable
public final class NotificationsModel {
    /// The last read couldn't be understood. What's recorded stays, and the card says so.
    public private(set) var unreadable = false
    @ObservationIgnored private var source: any NotificationLogSource
    @ObservationIgnored private var started: Date?
    @ObservationIgnored private var lastAttempt: Date?
    /// Where the next read starts: the end of the last one that worked.
    @ObservationIgnored private var readThrough: Date?
    @ObservationIgnored private var reading = false

    nonisolated static let readEvery: TimeInterval = 3 * 3600
    /// Leaves launch alone: the log keeps a day of these, so nothing's lost by waiting.
    nonisolated static let firstReadAfter: TimeInterval = 300
    static let cardReadEvery: TimeInterval = 300
    /// Further back than the log has kept on any Mac seen.
    static let longestRead: TimeInterval = 2 * 86400
    /// Reads overlap, so a pair cut by a read's end is whole in the next; the store ignores repeats.
    static let overlap: TimeInterval = 120

    public init(source: any NotificationLogSource) {
        self.source = source
    }

    public func replaceSource(_ source: any NotificationLogSource) {
        self.source = source
        unreadable = false
        lastAttempt = nil
        readThrough = nil
    }

    /// Each snapshot. A read when one's due, never in the way of the loop that calls this.
    public func observe(at now: Date, store: (any NotificationHistoryStore)?) {
        guard let store else {
            return
        }
        let started = started ?? now
        self.started = started
        guard Self.isDue(started: started, lastAttempt: lastAttempt, now: now) else {
            return
        }
        Task { [weak self] in await self?.read(now: now, store: store) }
    }

    /// Pure: whether the recording read is due.
    nonisolated static func isDue(started: Date, lastAttempt: Date?, now: Date) -> Bool {
        if let lastAttempt {
            return now.timeIntervalSince(lastAttempt) >= readEvery
        }
        return now.timeIntervalSince(started) >= firstReadAfter
    }

    /// When the card shows: fresh figures, if the last read is old enough.
    func refresh(now: Date = Date(), store: any NotificationHistoryStore) async {
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < Self.cardReadEvery, now >= lastAttempt {
            return
        }
        await read(now: now, store: store)
    }

    func read(now: Date, store: any NotificationHistoryStore) async {
        guard !reading else {
            return
        }
        reading = true
        defer { reading = false }
        lastAttempt = now
        var from = readThrough
        if from == nil {
            from = try? await store.notificationSpan()?.upperBound
        }
        let start = max((from ?? .distantPast).addingTimeInterval(-Self.overlap), now.addingTimeInterval(-Self.longestRead))
        let source = source
        switch await source.deliveries(from: start, to: now) {
        case .unreadable:
            unreadable = true
        case let .read(events):
            unreadable = false
            if await (try? store.recordNotifications(events)) != nil {
                readThrough = now
            }
        }
    }
}

/// History → Notifications (D-289): which apps send the most, and when in the day. On History
/// because it's a look back over the page's range, with each app's row opening nothing new: the
/// answer is a comparison across apps, which one app's own history page couldn't show.
struct NotificationsCard: View {
    let model: NotificationsModel
    let store: any NotificationHistoryStore
    let range: HistoryRange
    let generation: Int

    @State private var rows: [NotificationStats.AppRow] = []
    @State private var total = 0
    @State private var since: Date?
    @State private var loaded = false

    static let appsShown = 8
    private static let nameWidth: CGFloat = 180
    private static let countWidth: CGFloat = 50

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            if model.unreadable {
                Text("Mactivity can't read notifications from macOS's log right now, so new ones aren't being counted.", bundle: .strings)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(Tokens.Colors.strainLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if loaded, rows.isEmpty {
                secondary(String(
                    localized: "No notifications recorded in this range. If apps did send some, macOS may have changed what its log says.",
                    bundle: .strings
                ))
            } else if !rows.isEmpty {
                secondary(NotificationText.summary(total, range: range.label))
                    .monospacedDigit()
                hourAxis
                ForEach(rows) { row in
                    rowView(row)
                }
            }
            secondary(NotificationText.note(since: since))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .task(id: "\(range.rawValue)-\(generation)") {
            await model.refresh(store: store)
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private func load() async {
        let end = Date()
        let start = end.addingTimeInterval(-TimeInterval(range.duration.components.seconds))
        let events = await (try? store.notifications(from: start, to: end)) ?? []
        let span = try? await store.notificationSpan()
        guard !Task.isCancelled else {
            return
        }
        total = events.count
        rows = Array(NotificationStats.apps(events).prefix(Self.appsShown))
        since = span?.lowerBound
        loaded = true
    }

    /// Four marks over the strips, lined up with their hours.
    private var hourAxis: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Color.clear.frame(width: Tokens.IconSize.small + Tokens.Spacing.xs + Self.nameWidth, height: 1)
            GeometryReader { proxy in
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text(NotificationText.hour(hour))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(x: proxy.size.width * CGFloat(hour) / 24)
                }
            }
            .frame(height: 14)
            Color.clear.frame(width: Self.countWidth, height: 1)
        }
        .accessibilityHidden(true)
    }

    private func rowView(_ row: NotificationStats.AppRow) -> some View {
        let name = NotificationText.name(row.app)
        return HStack(spacing: Tokens.Spacing.xs) {
            AppIconView(NotificationText.identity(row.app, name: name), size: Tokens.IconSize.small)
            Text(name)
                .lineLimit(1)
                .frame(width: Self.nameWidth, alignment: .leading)
            HourStrip(hours: row.byHour)
                .frame(height: 12)
            Text(row.count, format: .number)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: Self.countWidth, alignment: .trailing)
        }
        .help(NotificationText.busiest(row))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NotificationText.accessibility(row, name: name))
    }

    private func secondary(_ text: String) -> some View {
        Text(text)
            .font(Tokens.Typography.secondary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A day as 24 cells, darker for the hours with more, so each app shows its own pattern.
private struct HourStrip: View {
    let hours: [Int]

    var body: some View {
        Canvas { context, size in
            let peak = hours.max() ?? 0
            guard peak > 0, !hours.isEmpty else {
                return
            }
            let width = size.width / CGFloat(hours.count)
            for (hour, count) in hours.enumerated() {
                let rect = CGRect(x: CGFloat(hour) * width, y: 0, width: max(1, width - 1), height: size.height)
                let opacity = count == 0 ? 0.08 : 0.25 + 0.75 * Double(count) / Double(peak)
                context.fill(Path(rect), with: .color(count == 0 ? Color.secondary.opacity(opacity) : Color.accentColor.opacity(opacity)))
            }
        }
    }
}

/// Notifications' words (D-289). Pure, apart from asking macOS an app's name.
enum NotificationText {
    static func summary(_ total: Int, range: String) -> String {
        String(
            localized: "\(total) notifications · \(range)", bundle: .strings,
            comment: "Notifications card: how many over the history range"
        )
    }

    static func hour(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    static func name(_ app: String) -> String {
        if app == NotificationEvent.website {
            return String(
                localized: "Websites", bundle: .strings,
                comment: "Notifications card: notifications from websites, kept together"
            )
        }
        let name = MutedAppsSection.displayName(app)
        // macOS's own alerts have no app to name them by.
        if name == app, app.hasPrefix("com.apple.") {
            return "macOS (\(app.dropFirst("com.apple.".count)))"
        }
        return name
    }

    static func identity(_ app: String, name: String) -> AppIdentity {
        let path = app == NotificationEvent.website ? nil : NSWorkspace.shared.urlForApplication(withBundleIdentifier: app)?.path
        return AppIdentity(id: app, name: name, bundleID: app, iconKey: path ?? "other", kind: .app)
    }

    static func busiest(_ row: NotificationStats.AppRow) -> String {
        String(
            localized: "Most often around \(hour(row.busiestHour))", bundle: .strings,
            comment: "Notifications card: an app's busiest hour"
        )
    }

    static func accessibility(_ row: NotificationStats.AppRow, name: String) -> String {
        String(
            localized: "\(name), \(row.count) notifications, most often around \(hour(row.busiestHour))", bundle: .strings,
            comment: "Notifications card: VoiceOver text for an app's row"
        )
    }

    static func note(since: Date?) -> String {
        let base = String(
            localized: """
            What each app sent, even if its alerts are turned off in System Settings. Updates and removals don't count. Only \
            the app and the time are kept, never what a notification said.
            """,
            bundle: .strings
        )
        guard let since else {
            return base
        }
        let recorded = String(
            localized: """
            Recorded since \(since.formatted(date: .abbreviated, time: .omitted)). macOS's log keeps these about a day, so \
            some can be missing if Mactivity was closed for longer.
            """,
            bundle: .strings
        )
        return recorded + " " + base
    }
}
