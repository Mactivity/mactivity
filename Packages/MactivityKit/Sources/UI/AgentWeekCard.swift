import Core
import SwiftUI

/// The Agents tab's last seven days (D-192): agent time day by day, and each agent's time,
/// processor and memory per project, from agent history.
struct AgentWeekCard: View {
    let services: AppServices
    /// A short window: the summary line alone, so the live sessions keep their room.
    var compact = false
    @State private var days: [DayTotal] = []
    @State private var totals: [AgentWeek.Total] = []
    @State private var loaded = false
    @State private var width: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("This week", bundle: .strings, comment: "Agents tab: the last seven days of agent sessions")
                    .font(Tokens.Typography.cardTitle)
                if !totals.isEmpty {
                    Text(summary)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                }
            }
            if loaded, totals.isEmpty, !compact {
                Text(
                    "Agent sessions are recorded as they run: what each worked on, for how long, and what it cost. Check back after one.",
                    bundle: .strings
                )
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.tertiary)
            } else if !totals.isEmpty, !compact {
                // By measured width, as every page's layout (D-174, D-176).
                if width >= Tokens.Layout.agentWeekSideBySideWidth {
                    HStack(alignment: .top, spacing: Tokens.Spacing.xl) {
                        chart.frame(width: Tokens.Layout.weekDaysChartMaxWidth)
                        list
                    }
                } else {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                        chart
                        list
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .cardStyle()
        .task(id: services.historyGeneration) {
            // This week includes today, which keeps changing: again every 5 minutes (D-219).
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private var chart: some View {
        WeekDaysChart(
            days: days,
            title: String(localized: "Agent time by day", bundle: .strings, comment: "Agents tab: chart of each day's agent time"),
            tint: Tokens.SidebarTint.agents
        )
    }

    /// "31h across 3 projects".
    private var summary: String {
        let minutes = days.reduce(0) { $0 + $1.seconds } / 60
        let names = Set(totals.map(\.project).filter { !$0.isEmpty })
        let projects = names.count
        let time = YourWeekContent.hours(minutes * 60)
        // One project is named rather than counted: "1 projects" isn't English.
        if projects == 1, let name = names.first {
            return String(
                localized: "\(time) of agent time, all in \(name)",
                bundle: .strings,
                comment: "Agents tab: this week's agent time, all in one project, e.g. 12h of agent time, all in mactivity"
            )
        }
        return projects > 1
            ? String(
                localized: "\(time) of agent time across \(projects) projects",
                bundle: .strings,
                comment: "Agents tab: this week's agent time and how many projects, e.g. 31h of agent time across 3 projects"
            )
            : String(localized: "\(time) of agent time", bundle: .strings, comment: "Agents tab: this week's agent time, e.g. 31h")
    }

    private var list: some View {
        Grid(alignment: .leading, horizontalSpacing: Tokens.Spacing.m, verticalSpacing: Tokens.Spacing.xs) {
            GridRow {
                Text("Agent", bundle: .strings)
                Text("Project", bundle: .strings)
                Text("Time", bundle: .strings, comment: "Agents tab: column of time each agent ran").gridColumnAlignment(.trailing)
                Text("Processor", bundle: .strings, comment: "Next Mac card").gridColumnAlignment(.trailing)
                Text("Peak memory", bundle: .strings, comment: "Agents tab: column of the most memory a session held")
                    .gridColumnAlignment(.trailing)
            }
            .font(Tokens.Typography.secondary)
            .foregroundStyle(.secondary)
            ForEach(totals.prefix(8)) { total in
                GridRow {
                    Text(total.agent).lineLimit(1)
                    Text(total.project.isEmpty ? "–" : total.project).lineLimit(1).foregroundStyle(.secondary)
                    Text(YourWeekContent.hours(Double(total.minutes) * 60)).monospacedDigit()
                    Text(Formatters.percent(total.averageCPU, fractionDigits: 1)).monospacedDigit()
                    Text(Formatters.memory(total.peakMemory)).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func load() async {
        guard let store = services.history as? any AgentHistoryStore else {
            loaded = true
            return
        }
        let now = Date()
        let span = WeeklyReport.days(ending: now)
        let rows = await (try? store.agentUsage(from: span.first?.start ?? now.addingTimeInterval(-7 * 86400), to: now)) ?? []
        days = AgentWeek.byDay(rows, days: span)
        totals = AgentWeek.totals(rows)
        loaded = true
    }
}
