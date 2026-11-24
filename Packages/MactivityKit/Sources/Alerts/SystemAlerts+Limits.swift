import Core
import Foundation

/// The agent limits (D-227) and the data budget (D-235).
extension SystemAlertRules {
    /// A session past either agent limit (D-227): "Claude Code has run 4 hours in mactivity",
    /// "Codex's processes hold 9.2 GB".
    static func agentAlerts(_ sessions: [AgentSession], settings: AlertSettings, now: Date) -> [Candidate] {
        let hours = settings.settings(for: .agentLongSession).threshold
        let memory = settings.settings(for: .agentMemory).threshold
        var alerts: [Candidate] = []
        for session in sessions {
            let app = agentIdentity(session)
            let up = now.timeIntervalSince(session.startedAt)
            let held = Formatters.memory(session.memoryBytes)
            let place = session.project.map {
                String(localized: "It works in \($0).", bundle: .strings, comment: "Agent alert: the project folder")
            } ?? ""
            let see = String(localized: "The Agents page shows it, with Stop.", bundle: .strings)
            if hours > 0, up >= hours * 3600 {
                let time = Formatters.duration(.seconds(up))
                alerts.append(Candidate(
                    rule: .agentLongSession, app: app,
                    title: String(
                        localized: "\(session.agent) has been running for \(time)",
                        bundle: .strings,
                        comment: "Alert title: an agent's name, then how long, e.g. Claude Code has been running for 4h 10m"
                    ),
                    body: [place, String(localized: "Its processes hold \(held) now.", bundle: .strings), see]
                        .filter { !$0.isEmpty }.joined(separator: " ")
                ))
            }
            if memory > 0, Double(session.memoryBytes) >= memory {
                let busiest = session.busiestChildren.isEmpty ? ""
                    : String(
                        localized: "Busiest: \(session.busiestChildren.formatted(.list(type: .and))).",
                        bundle: .strings,
                        comment: "Agent alert: the processes it started that work hardest, e.g. node and swift-frontend"
                    )
                alerts.append(Candidate(
                    rule: .agentMemory, app: app,
                    title: String(
                        localized: "\(session.agent)'s processes hold \(held)",
                        bundle: .strings,
                        comment: "Alert title: an agent's name, then the memory its session holds"
                    ),
                    body: [place, busiest, see].filter { !$0.isEmpty }.joined(separator: " ")
                ))
            }
        }
        return alerts
    }

    /// One per session, so its alerts fire once and the log names the agent.
    static func agentIdentity(_ session: AgentSession) -> AppIdentity {
        AppIdentity(
            id: "agent:\(session.pid)@\(Int(session.startedAt.timeIntervalSince1970))", name: session.agent, bundleID: nil,
            iconKey: "other", kind: .other
        )
    }

    /// The month's data at `warnAt` percent of the budget, then at all of it (D-235).
    static func budgetAlerts(_ status: DataBudgetStatus?, warnAt: Double) -> [Candidate] {
        guard let status, status.budget.allowance > 0 else {
            return []
        }
        let used = Formatters.bytes(status.used)
        let allowance = Formatters.bytes(status.budget.allowance)
        let resets = status.period.end.formatted(.dateTime.month(.abbreviated).day())
        if status.fraction >= 1 {
            return [Candidate(
                rule: .dataBudget,
                app: AppIdentity(id: status.periodKey + ":over", name: "Mac", bundleID: nil, iconKey: "other", kind: .other),
                title: String(localized: "You've used your data budget", bundle: .strings),
                body: String(
                    localized: "\(used) of \(allowance) this month. It resets on \(resets). The Network tab shows which apps used it.",
                    bundle: .strings,
                    comment: "Data budget alert: used, allowance, the reset date"
                )
            )]
        }
        guard status.fraction * 100 >= warnAt else {
            return []
        }
        let pace = status.projected.map { projected in
            String(
                localized: " At this pace, \(Formatters.bytes(projected)) by \(resets).",
                bundle: .strings,
                comment: "Data budget alert, after the figures: the projected total and the reset date"
            )
        } ?? ""
        return [Candidate(
            rule: .dataBudget,
            app: AppIdentity(id: status.periodKey + ":warn", name: "Mac", bundleID: nil, iconKey: "other", kind: .other),
            title: String(
                localized: "\(Int(status.fraction * 100))% of your data budget used",
                bundle: .strings,
                comment: "Data budget alert title, e.g. 82% of your data budget used"
            ),
            body: String(
                localized: "\(used) of \(allowance) this month.",
                bundle: .strings,
                comment: "Data budget alert: used, allowance"
            ) +
                pace
        )]
    }
}
