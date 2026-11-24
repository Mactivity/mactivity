import Core
import Observation
import SwiftUI

/// After an update (D-206): each macOS and app update of the last 30 days, its week before beside
/// the days after. Worked out at most every six hours: up to 45 day-sized reads.
@MainActor
@Observable
public final class UpdatesModel {
    public private(set) var impacts: [UpdateImpact] = []
    /// Updated, but not used two days on each side yet.
    public private(set) var waiting: [InstalledUpdate] = []
    public private(set) var isLoaded = false
    @ObservationIgnored private var loadedAt: Date?
    @ObservationIgnored private var loadedGeneration = -1
    /// A load under way: a second caller (Checkup while History loads) waits for it rather than
    /// reading the empty lists.
    @ObservationIgnored private var loading: Task<Void, Never>?
    static let freshFor: TimeInterval = 6 * 3600
    static let lookBack: TimeInterval = 30 * 86400

    public init() {}

    /// Already worked out: render tests.
    init(impacts: [UpdateImpact], waiting: [InstalledUpdate]) {
        self.impacts = impacts
        self.waiting = waiting
        isLoaded = true
        loadedAt = Date()
    }

    /// Heavier on a notable figure, for Checkup.
    public var heavier: [UpdateImpact] {
        impacts.filter(\.isHeavier)
    }

    func refresh(_ services: AppServices, now: Date = Date()) async {
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
            isLoaded = true
            return
        }
        loadedAt = now
        loadedGeneration = services.historyGeneration
        let since = now.addingTimeInterval(-Self.lookBack)
        var apps: [AppIdentity] = []
        for metric in [Metric.cpu, .memory] {
            for total in await (try? daily.topApps(metric: metric, from: since, to: now, limit: 40)) ?? []
                where total.app.kind == .app && !apps.contains(total.app) {
                apps.append(total.app)
            }
        }
        let updates = await services.softwareUpdates.installed(apps: apps, since: since)
        let firstRecorded = try? await daily.firstRecorded()
        var reader = DayReader(daily: daily)
        var found: [UpdateImpact] = []
        var notYet: [InstalledUpdate] = []
        for update in updates {
            guard let span = UpdateComparison.span(update, now: now) else {
                continue
            }
            let figures = await reader.figures(for: update.app, in: span)
            if let impact = UpdateComparison.impact(update, daily: figures, now: now) {
                found.append(impact)
            } else if UpdateComparison.mayCompare(update, firstRecorded: firstRecorded, now: now),
                      UpdateComparison.daysUsedBefore(update, daily: figures) >= UpdateComparison.minimumDays {
                // Used before it: a real update still collecting days after. Not a fresh install,
                // whose Info.plist is just as new.
                notYet.append(update)
            }
        }
        // Heavier first, then lighter, then about the same; newest first within each.
        impacts = found.sorted { lhs, rhs in
            let rank = { (impact: UpdateImpact) in impact.notable == nil ? 2 : impact.isHeavier ? 0 : 1 }
            return (rank(lhs), rhs.update.installedAt) < (rank(rhs), lhs.update.installedAt)
        }
        waiting = notYet
        isLoaded = true
    }

    /// Day-sized reads, each read once however many updates' spans share the day.
    private struct DayReader {
        let daily: any DailyHistoryStore
        var apps: [Date: [Metric: [AppTotal]]] = [:]
        var system: [Metric: [DayValue]]?

        init(daily: any DailyHistoryStore) {
            self.daily = daily
        }

        /// The app's figure on each day of `span` it was used; for macOS (nil), the whole Mac's.
        mutating func figures(for app: AppIdentity?, in span: DateInterval) async -> [Metric: [DayValue]] {
            let calendar = Calendar.current
            guard let app else {
                if system == nil {
                    var read: [Metric: [DayValue]] = [:]
                    for metric in UpdateComparison.metrics {
                        read[metric] = await (try? daily.dailyValues(metric: metric, days: 45)) ?? []
                    }
                    system = read
                }
                return (system ?? [:]).mapValues { $0.filter { span.contains($0.day) } }
            }
            var result: [Metric: [DayValue]] = [:]
            var day = calendar.startOfDay(for: span.start)
            while day < span.end, let next = calendar.date(byAdding: .day, value: 1, to: day) {
                for metric in UpdateComparison.metrics {
                    if apps[day]?[metric] == nil {
                        let tops = await (try? daily.topApps(metric: metric, from: day, to: next, limit: 200)) ?? []
                        apps[day, default: [:]][metric] = tops
                    }
                    if let value = apps[day]?[metric]?.first(where: { $0.app.id == app.id })?.value {
                        result[metric, default: []].append(DayValue(day: day, average: value, maximum: value))
                    }
                }
                day = next
            }
            return result
        }
    }
}

/// History's After updates: each update with what changed, or that nothing much did.
struct AfterUpdatesCard: View {
    let services: AppServices
    /// Render tests: this instead of the services' model.
    var model: UpdatesModel?

    var body: some View {
        let model = model ?? services.updates
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text("Each update's week before beside the days after, from your history.", bundle: .strings)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
            if model.isLoaded, model.impacts.isEmpty, model.waiting.isEmpty {
                Text("No updates to compare in the last 30 days.", bundle: .strings)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Tokens.Spacing.s)
            }
            ForEach(model.impacts) { impact in
                row(impact.update) {
                    Text(Self.verdict(impact))
                        .foregroundStyle(impact
                            .notable == nil ? AnyShapeStyle(.secondary) : impact
                            .isHeavier ? AnyShapeStyle(Tokens.Colors.strainLabel) :
                            AnyShapeStyle(Tokens.Colors.goodLabel))
                }
            }
            ForEach(model.waiting) { update in
                row(update) {
                    Text("Compared after two days of use", bundle: .strings, comment: "After updates: too recent to compare yet")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .task(id: services.historyGeneration) {
            if self.model == nil {
                await services.updates.refresh(services)
            }
        }
    }

    private func row(_ update: InstalledUpdate, @ViewBuilder verdict: () -> some View) -> some View {
        HStack(spacing: Tokens.Spacing.s) {
            if let app = update.app {
                AppIconView(app, size: Tokens.IconSize.small)
            } else {
                Image(systemName: "apple.logo")
                    .frame(width: Tokens.IconSize.small, height: Tokens.IconSize.small)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "\(update.name) \(update.version)").fontWeight(.medium).lineLimit(1)
                Text(update.installedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Tokens.Spacing.s)
            verdict()
                .font(Tokens.Typography.secondary)
                .monospacedDigit()
                .lineLimit(1)
            // Hidden for macOS, which has no history page, so every verdict lines up.
            Image(systemName: "chevron.right").foregroundStyle(.tertiary).opacity(update.app == nil ? 0 : 1)
        }
        .contentShape(.rect)
        .onTapGesture {
            if let app = update.app {
                services.appHistory.open(app)
            }
        }
    }

    /// "Memory 1.2 GB → 1.6 GB (+33%)", or "About the same as before".
    nonisolated static func verdict(_ impact: UpdateImpact) -> String {
        guard let change = impact.notable, let fraction = change.fraction else {
            return String(localized: "About the same as before", bundle: .strings, comment: "After updates: nothing changed much")
        }
        let what = switch change.metric {
        case .memory: String(localized: "Memory", bundle: .strings)
        case .energy: String(localized: "Power", bundle: .strings, comment: "App history: power drawn")
        default: String(localized: "Processor", bundle: .strings, comment: "App history tile: CPU")
        }
        let before = UnusualText.figure(change.metric, change.before)
        let after = UnusualText.figure(change.metric, change.after)
        let percent = fraction.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always()))
        return String(
            localized: "\(what) \(before) → \(after) (\(percent))",
            bundle: .strings,
            comment: "After updates: a figure before and after an update, and the change, e.g. Memory 1.2 GB → 1.6 GB (+33%)"
        )
    }
}
