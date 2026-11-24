import AppKit
import Core
import Observation
import SwiftUI

/// The Agents tab (D-148): every AI coding agent session, with what it and everything it started
/// use, and Stop… through `ConfirmedAction` (CLAUDE.md rule 4).
@MainActor
@Observable
public final class AgentsModel {
    public private(set) var sessions: [AgentSession] = []
    public private(set) var hasScanned = false
    @ObservationIgnored private var source: any AgentSource
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var visibleViews = 0
    @ObservationIgnored private var sourceGeneration = 0

    /// Read every 3 s while the tab shows, like the app lists' refresh.
    static let interval: Duration = .seconds(3)

    public init(source: any AgentSource) {
        self.source = source
    }

    public func replaceSource(_ source: any AgentSource) {
        sourceGeneration += 1
        self.source = source
        sessions = []
        hasScanned = false
        if visibleViews > 0 {
            startLoop()
        }
    }

    public func appeared() {
        visibleViews += 1
        if visibleViews == 1 {
            startLoop()
        }
    }

    public func disappeared() {
        visibleViews = max(0, visibleViews - 1)
        if visibleViews == 0 {
            loop?.cancel()
            loop = nil
        }
    }

    public func refresh() async {
        let source = source
        let generation = sourceGeneration
        let found = await (try? source.sessions()) ?? []
        guard generation == sourceGeneration else {
            return
        }
        sessions = found
        hasScanned = true
    }

    private func startLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }
}

struct AgentsView: View {
    let services: AppServices
    @State private var height: CGFloat = 0

    var body: some View {
        let model = services.agents
        VStack(alignment: .leading, spacing: Tokens.Spacing.gridGutter) {
            Text(summary(model))
                .font(Tokens.Typography.cardTitle)
                .monospacedDigit()
            if model.hasScanned, model.sessions.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No AI agents running", bundle: .strings), systemImage: SidebarItem.agents.symbol)
                } description: {
                    Text(
                        """
                        Claude Code, Codex, Gemini CLI, Aider and other coding agents show up here while they run, \
                        with everything they start.
                        """,
                        bundle: .strings
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table(model.sessions)
                    .clipShape(Tokens.Shapes.card)
                    .fittedTable(TableFit.height(rows: model.sessions.reduce(0) {
                        $0 + ($1.busiestChildren.isEmpty ? TableFit.oneLineRow : TableFit.twoLineRow)
                    }))
                    .layoutPriority(1)
            }
            // The last seven days from agent history (D-192), under what's running now; one line
            // in a short window, by measured height (D-174).
            AgentWeekCard(services: services, compact: height > 0 && height < Tokens.Layout.agentWeekFullMinHeight)
        }
        // The page from the top, measured at the window's height, not its content's: a short
        // table leaves room for the week chart rather than shrinking it to a line (D-239).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(Tokens.Spacing.l)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .onAppear { model.appeared() }
        .onDisappear { model.disappeared() }
        .confirmedActionDialog(services.confirmedAction)
    }

    private func summary(_ model: AgentsModel) -> String {
        guard model.hasScanned else {
            return String(localized: "Looking for AI agents…", bundle: .strings)
        }
        let count = model.sessions.count
        let memory = Formatters.memory(model.sessions.reduce(0) { $0 + $1.memoryBytes })
        return String(localized: "Agent sessions: \(count) · \(memory)", bundle: .strings)
    }

    private func table(_ sessions: [AgentSession]) -> some View {
        Table(sessions) {
            TableColumn(String(localized: "Agent", bundle: .strings)) { session in
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.agent)
                    if !session.busiestChildren.isEmpty {
                        Text(session.busiestChildren.joined(separator: ", "))
                            .font(Tokens.Typography.secondary)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            TableColumn(String(localized: "Project", bundle: .strings)) { session in
                Text(session.project ?? "—").help(session.directory ?? "")
            }
            TableColumn(String(localized: "In", bundle: .strings, comment: "Agents table: the app an agent runs in")) { session in
                Text(session.host ?? "—").foregroundStyle(.secondary)
            }
            TableColumn(String(localized: "CPU", bundle: .strings)) { session in
                Text(Formatters.percent(session.cpuPercent, fractionDigits: 1)).monospacedDigit()
            }
            .width(min: 50, ideal: 60)
            .alignment(.numeric)
            TableColumn(String(localized: "Memory", bundle: .strings)) { session in
                Text(Formatters.memory(session.memoryBytes)).monospacedDigit()
            }
            .width(min: 60, ideal: 70)
            .alignment(.numeric)
            TableColumn(String(localized: "Processes", bundle: .strings)) { session in
                Text(session.processCount.formatted()).monospacedDigit()
            }
            .width(min: 50, ideal: 70)
            .alignment(.numeric)
            TableColumn(String(localized: "Running", bundle: .strings, comment: "Agents table: how long a session has run")) { session in
                Text(Formatters.duration(.seconds(Date().timeIntervalSince(session.startedAt)))).monospacedDigit()
            }
            .width(min: 60, ideal: 70)
            TableColumn("") { session in
                Button(String(localized: "Stop…", bundle: .strings)) { requestStop(session) }
            }
            .width(min: 60, ideal: 64)
        }
    }

    private func requestStop(_ session: AgentSession) {
        let place = session.project ?? session.agent
        let count = session.processCount
        services.confirmedAction.ask(ConfirmedAction.Request(
            title: String(localized: "Stop \(session.agent) in \(place)?", bundle: .strings, comment: "Confirmation title"),
            message: String(
                localized: """
                Processes it started: \(count). They're asked to stop, and stopped after 5 seconds if they don't. \
                Work it hasn't saved is lost.
                """,
                bundle: .strings
            ),
            confirmTitle: String(localized: "Stop", bundle: .strings, comment: "Confirmation button"),
            targets: session.stopTargets,
            mode: .quit
        ) { [services] results in
            services.show(toast: results.isEmpty
                ? String(localized: "\(session.agent) couldn't be stopped.", bundle: .strings)
                : String(localized: "Stopped \(session.agent) in \(place).", bundle: .strings))
            Task { await services.agents.refresh() }
        })
    }
}
