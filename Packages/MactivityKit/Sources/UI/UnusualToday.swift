import Core
import Observation
import SwiftUI

/// What's out of the ordinary today (D-198), worked out from History at most every half hour.
/// The 14 days before today don't change, so they're read once a day and kept: a refresh is
/// three reads of today, cheap enough for the hourly alert check with no window open (D-201).
@MainActor
@Observable
public final class UnusualModel {
    public private(set) var found: [UnusualUsage] = []
    @ObservationIgnored private var loadedAt: Date?
    @ObservationIgnored private var loadedGeneration = -1
    /// Each metric's days before `pastFor`, oldest first.
    @ObservationIgnored private var past: [Metric: [[AppTotal]]] = [:]
    @ObservationIgnored private var pastFor: (day: Date, generation: Int)?
    /// A load under way, so a second caller waits for it rather than reading what's there.
    @ObservationIgnored private var loading: Task<Void, Never>?
    static let freshFor: TimeInterval = 30 * 60

    public init() {}

    /// Already worked out: render tests.
    init(found: [UnusualUsage]) {
        self.found = found
        loadedAt = Date()
    }

    public func refresh(_ services: AppServices, now: Date = Date()) async {
        if let loading {
            await loading.value
            return
        }
        if let loadedAt, now.timeIntervalSince(loadedAt) < Self.freshFor, loadedGeneration == services.historyGeneration {
            return
        }
        let task = Task { await load(services, now: now) }
        loading = task
        await task.value
        loading = nil
    }

    private func load(_ services: AppServices, now: Date) async {
        guard let daily = services.history as? any DailyHistoryStore else {
            return
        }
        loadedAt = now
        loadedGeneration = services.historyGeneration
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        if pastFor?.day != today || pastFor?.generation != services.historyGeneration {
            past = await Baselines.readPast(daily, before: today, calendar: calendar)
            pastFor = (today, services.historyGeneration)
        }
        found = await Baselines.readToday(daily, past: past, today: today, now: now)
    }

    /// An app's usual day for `metric`, from the days already read; nil before anything's read
    /// or while still learning (D-201).
    public func usual(_ appID: AppIdentity.ID, metric: Metric) -> Double? {
        guard Baselines.daysLearned(past) >= Baselines.minimumDays, let days = past[metric] else {
            return nil
        }
        return Baselines.usual(appID, in: days.filter { !$0.isEmpty })
    }
}

/// Overview's Out of the ordinary: shown only when something is (D-198).
struct UnusualCard: View {
    let services: AppServices
    /// Render tests: these instead of what History says.
    var sample: [UnusualUsage]?

    var body: some View {
        let found = sample ?? services.unusual.found
        Group {
            if !found.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
                        Label {
                            Text(
                                "Out of the ordinary today",
                                bundle: .strings,
                                comment: "Overview: apps doing much more than they usually do"
                            )
                        } icon: {
                            Image(systemName: "sparkle.magnifyingglass").foregroundStyle(Tokens.Colors.strain)
                        }
                        .font(Tokens.Typography.cardTitle)
                        Text("Compared with each app's usual day on this Mac", bundle: .strings)
                            .font(Tokens.Typography.secondary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    ForEach(found) { usage in
                        Button {
                            services.appHistory.open(usage.app)
                        } label: {
                            HStack(spacing: Tokens.Spacing.s) {
                                AppIconView(usage.app, size: Tokens.IconSize.small)
                                Text(usage.app.name).fontWeight(.medium)
                                Text(UnusualText.detail(usage))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: Tokens.Spacing.xs)
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help(Text(
                            "Show \(usage.app.name)’s history",
                            bundle: .strings,
                            comment: "Tooltip on a top app: opens its history page"
                        ))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()
            }
        }
        .task(id: services.historyGeneration) { await services.unusual.refresh(services) }
    }
}
