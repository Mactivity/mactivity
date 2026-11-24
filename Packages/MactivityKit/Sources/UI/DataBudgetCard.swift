import Core
import Observation
import SwiftUI

/// The monthly data budget's state (D-235): the budget, kept in the app's defaults, and where it
/// stands, read when the Network tab shows and every 5 minutes while it does.
@MainActor
@Observable
public final class DataBudgetModel {
    public private(set) var budget: DataBudget?
    private(set) var status: DataBudgetStatus?
    private(set) var apps: [AppTotal] = []
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        budget = Self.saved(in: defaults)
    }

    /// The saved budget, for the app's 10-minute alert check.
    public nonisolated static func saved(in defaults: UserDefaults = .standard) -> DataBudget? {
        defaults.data(forKey: PreferenceKey.dataBudget).flatMap { try? JSONDecoder().decode(DataBudget.self, from: $0) }
    }

    func set(_ budget: DataBudget?) {
        self.budget = budget
        if let budget, let data = try? JSONEncoder().encode(budget) {
            defaults.set(data, forKey: PreferenceKey.dataBudget)
        } else {
            defaults.removeObject(forKey: PreferenceKey.dataBudget)
        }
        status = nil
        apps = []
    }

    func load(_ history: any HistoryStore, now: Date = Date()) async {
        guard let budget else {
            status = nil
            return
        }
        let period = budget.period(containing: now)
        let daily = history as? any DailyHistoryStore
        let used = await (try? daily?.systemTotal(metrics: [.netIn, .netOut], from: period.start, to: now)) ?? 0
        apps = await ((try? daily?.totals(metrics: [.netIn, .netOut], from: period.start, to: now, limit: 5)) ?? []).filter { $0.value > 0 }
        status = DataBudgetStatus(budget: budget, period: period, used: used, now: now)
    }
}

/// On the Network tab: the month's data against the budget, the pace, and each app's share.
struct DataBudgetCard: View {
    let model: DataBudgetModel
    let services: AppServices
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
                Text("Data this month", bundle: .strings, comment: "Network tab card: the monthly data budget")
                    .font(Tokens.Typography.cardTitle)
                Spacer()
                Button(model.budget == nil
                    ? String(localized: "Set Budget…", bundle: .strings, comment: "Sets a monthly data allowance")
                    : String(localized: "Edit Budget…", bundle: .strings, comment: "Changes the monthly data allowance")) {
                        editing = true
                    }
                    .controlSize(.small)
                    .popover(isPresented: $editing, arrowEdge: .bottom) {
                        DataBudgetEditor(budget: model.budget) { model.set($0)
                            editing = false
                            Task { await model.load(services.history) }
                        }
                    }
            }
            if model.budget == nil {
                Text(
                    """
                    Set a monthly allowance, for a capped plan or a hotspot, to see what's left, each app's share, \
                    and get an alert before you go over.
                    """,
                    bundle: .strings
                )
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else if let status = model.status {
                standing(status)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .task(id: model.budget) {
            while !Task.isCancelled {
                await model.load(services.history)
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private func standing(_ status: DataBudgetStatus) -> some View {
        let warnAt = services.alertSettings.settings(for: .dataBudget).threshold / 100
        let resets = status.period.end.formatted(.dateTime.month(.abbreviated).day())
        return VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            ProgressView(value: min(1, status.fraction))
                .tint(status.fraction >= warnAt ? Tokens.Colors.strain : Tokens.SidebarTint.network)
                .accessibilityLabel(Text("Data budget used", bundle: .strings))
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
                Text(
                    "\(Formatters.bytes(status.used)) of \(Formatters.bytes(status.budget.allowance))",
                    bundle: .strings,
                    comment: "Data budget: used of allowance"
                )
                .monospacedDigit()
                Text("Resets \(resets)", bundle: .strings, comment: "Data budget: the next reset date, e.g. Resets Nov 1")
                    .foregroundStyle(.secondary)
                if let projected = status.projected {
                    Text(
                        "On pace for \(Formatters.bytes(projected))",
                        bundle: .strings,
                        comment: "Data budget: the month's projected total"
                    )
                    .foregroundStyle(projected > status.budget
                        .allowance ? AnyShapeStyle(Tokens.Colors.strainLabel) : AnyShapeStyle(.secondary))
                    .monospacedDigit()
                }
                Spacer()
            }
            .font(Tokens.Typography.secondary)
            if !model.apps.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: Tokens.Spacing.m, verticalSpacing: Tokens.Spacing.xs) {
                    ForEach(model.apps) { total in
                        GridRow {
                            HStack(spacing: Tokens.Spacing.xs) {
                                AppIconView(total.app, size: Tokens.IconSize.small)
                                Text(total.app.name)
                            }
                            Text(Formatters.bytes(total.value)).monospacedDigit().gridColumnAlignment(.trailing)
                            Text(Formatters.percent(status.used > 0 ? total.value / status.used * 100 : 0))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .gridColumnAlignment(.trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    // The rest: macOS's own and smaller apps, so the shares add up.
                    let rest = status.used - model.apps.reduce(0) { $0 + $1.value }
                    if rest > status.used * 0.01 {
                        GridRow {
                            Text("Everything else", bundle: .strings, comment: "Data budget: macOS and the smaller apps together")
                                .foregroundStyle(.secondary)
                            Text(Formatters.bytes(rest)).monospacedDigit().foregroundStyle(.secondary)
                            Text(Formatters.percent(rest / status.used * 100)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                .font(Tokens.Typography.secondary)
            }
            Text("Counts everything the Mac downloads and uploads, files shared on your own network too.", bundle: .strings)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.tertiary)
        }
    }
}

/// The allowance and reset day, or no budget.
private struct DataBudgetEditor: View {
    let budget: DataBudget?
    let done: (DataBudget?) -> Void
    /// Text, read when Save is pressed: a number field commits only on Return or leaving it,
    /// so Save could have kept the old figure (D-236).
    @State private var gigabytes: String
    @State private var resetDay: Int

    init(budget: DataBudget?, done: @escaping (DataBudget?) -> Void) {
        self.budget = budget
        self.done = done
        _gigabytes = State(initialValue: ((budget?.allowance ?? 100e9) / 1e9).formatted(.number.precision(.fractionLength(0 ... 1))))
        _resetDay = State(initialValue: budget?.resetDay ?? 1)
    }

    var body: some View {
        Form {
            TextField(text: $gigabytes) {
                Text("Allowance, GB", bundle: .strings, comment: "Data budget editor: the monthly allowance in gigabytes")
            }
            Picker(selection: $resetDay) {
                ForEach(1 ... 31, id: \.self) { Text(verbatim: "\($0)").tag($0) }
            } label: {
                Text("Resets on day", bundle: .strings, comment: "Data budget editor: the day of the month it starts again")
            }
            HStack {
                if budget != nil {
                    Button(String(localized: "Remove Budget", bundle: .strings), role: .destructive) { done(nil) }
                }
                Spacer()
                Button(String(localized: "Save", bundle: .strings)) {
                    let value = (try? Double(gigabytes, format: .number)) ?? Double(gigabytes) ?? 100
                    done(DataBudget(allowance: max(0.1, value) * 1e9, resetDay: resetDay))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 300)
    }
}
