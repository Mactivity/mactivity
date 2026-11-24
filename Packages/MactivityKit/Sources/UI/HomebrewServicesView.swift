import Core
import Observation
import Projects
import SwiftUI

/// Projects → Homebrew's state (D-225): services read when the view shows, then every 30
/// seconds while it does; when each was last busy comes from History, once an hour.
@MainActor
@Observable
final class HomebrewServicesModel {
    private let source: any HomebrewServiceSource
    private(set) var services: [HomebrewService] = []
    /// Formula → the newest hour History saw it busy; missing when it never was.
    private(set) var lastBusy: [String: Date] = [:]
    /// How far back History goes, so "not busy in two weeks" is only said with two weeks of it.
    private(set) var historySince: Date?
    private(set) var loaded = false
    /// History's hours change hourly: read again only then, or for a service not read yet.
    @ObservationIgnored private var historyReadAt: Date?
    @ObservationIgnored private var historyRead: Set<String> = []

    init(source: any HomebrewServiceSource) {
        self.source = source
    }

    func load(history: (any HistoryStore)?, now: Date = Date()) async {
        let found = await source.services()
        let stale = historyReadAt.map { now.timeIntervalSince($0) >= 3600 || now < $0 } ?? true
        let unread = found.filter { !historyRead.contains(Self.historyKey($0)) }
        if let daily = history as? any DailyHistoryStore, stale || !unread.isEmpty {
            var busy = stale ? [:] : lastBusy
            if stale {
                historySince = await (try? daily.firstRecorded()).flatMap(\.self)
                historyRead = []
                historyReadAt = now
            }
            for service in stale ? found : unread {
                let points = await (try? daily.series(
                    metric: .cpu, app: "other:" + service.executableName, from: now.addingTimeInterval(-60 * 86400), to: now
                )) ?? []
                busy[service.formula] = HomebrewServiceRules.lastBusy(points)
                historyRead.insert(Self.historyKey(service))
            }
            lastBusy = busy
        }
        services = found
        loaded = true
    }

    private static func historyKey(_ service: HomebrewService) -> String {
        service.formula + "/" + service.executableName
    }

    /// Running, and not busy for two weeks of History. Not for one whose figures can't be read
    /// (a root service): History has none for it either.
    func isQuiet(_ service: HomebrewService, now: Date = Date()) -> Bool {
        guard service.isRunning, service.isReadable, let since = historySince,
              now.timeIntervalSince(since) >= HomebrewServiceRules.quietAfter else {
            return false
        }
        return lastBusy[service.formula].map { now.timeIntervalSince($0) >= HomebrewServiceRules.quietAfter } ?? true
    }
}

struct HomebrewServicesView: View {
    let model: HomebrewServicesModel
    let history: (any HistoryStore)?
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.gridGutter) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
                Text(summary)
                    .font(Tokens.Typography.cardTitle)
                    .monospacedDigit()
                if let quiet = quietSummary {
                    Text(quiet)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(Tokens.Colors.strainLabel)
                }
                Spacer()
            }
            .cardStyle()
            if !model.loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.services.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No Homebrew services", bundle: .strings), systemImage: "mug")
                } description: {
                    Text("What you start with `brew services start` shows here: Postgres, Redis, Ollama…", bundle: .strings)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
                    .clipShape(Tokens.Shapes.card)
                    .fittedTable(TableFit.height(twoLineRows: model.services.count))
                    .layoutPriority(1)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .task {
            while !Task.isCancelled {
                await model.load(history: history)
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var table: some View {
        Table(model.services) {
            TableColumn(Text("Service", bundle: .strings)) { service in
                VStack(alignment: .leading, spacing: Tokens.Spacing.lineGap) {
                    Text(service.formula).font(Tokens.Typography.rowTitle)
                    Text(state(service))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(model.isQuiet(service) ? AnyShapeStyle(Tokens.Colors.strainLabel) : AnyShapeStyle(.secondary))
                }
            }
            .width(min: 180, ideal: 240)
            TableColumn(Text("Ports", bundle: .strings)) { service in
                Text(service.ports.isEmpty ? "–" : service.ports.map { ":\($0)" }.joined(separator: " "))
                    .font(Tokens.Typography.code)
                    .lineLimit(1)
            }
            .width(min: 60, ideal: 90)
            TableColumn(Text("Memory", bundle: .strings)) { service in
                Text(service.isRunning && service.memoryBytes > 0 ? Formatters.memory(service.memoryBytes) : "–")
                    .monospacedDigit()
                    .help(service.isReadable ? Text(verbatim: "") : Self.rootHelp)
            }
            .width(70)
            .alignment(.numeric)
            TableColumn(Text("Processor", bundle: .strings, comment: "Next Mac card")) { service in
                Text(processor(service))
                    .monospacedDigit()
                    .help(service.isReadable ? Text("Average since it started, of one core", bundle: .strings) : Self.rootHelp)
            }
            .width(80)
            .alignment(.numeric)
            TableColumn(Text("Stop it with", bundle: .strings, comment: "Services column: the command that stops it")) { service in
                if service.isRunning {
                    stopCommand(service)
                } else {
                    Text(verbatim: "–").foregroundStyle(.secondary)
                }
            }
            .width(min: 220, ideal: 280)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    private func processor(_ service: HomebrewService) -> String {
        guard service.isReadable, let average = service.averageCPU(now: Date()) else {
            return "–"
        }
        return Formatters.percent(average, fractionDigits: 2)
    }

    private func stopCommand(_ service: HomebrewService) -> some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Text(verbatim: service.stopCommand)
                .font(Tokens.Typography.codeSecondary)
                .lineLimit(1)
                .textSelection(.enabled)
            Button {
                InspectorText.copy(service.stopCommand)
                copied = service.id
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    if copied == service.id {
                        copied = nil
                    }
                }
            } label: {
                Image(systemName: copied == service.id ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(Text("Copy the command", bundle: .strings))
            .accessibilityLabel(Text("Copy the command", bundle: .strings))
        }
    }

    /// Root services (`sudo brew services`): their figures need the privileged helper.
    static let rootHelp = Text("Runs as root: its memory and processor need Mactivity's helper", bundle: .strings)

    /// "Running 19d · busy 2 hours ago", "Running 19d · not busy in two weeks", "Not running".
    private func state(_ service: HomebrewService) -> String {
        guard service.isRunning else {
            return String(localized: "Not running", bundle: .strings, comment: "Homebrew service state")
        }
        var parts: [String] = []
        if let startedAt = service.startedAt {
            let up = Formatters.duration(.seconds(max(0, Date().timeIntervalSince(startedAt))))
            parts.append(String(
                localized: "Running \(up)",
                bundle: .strings,
                comment: "Homebrew service: how long it has run, e.g. Running 19d 4h"
            ))
        } else {
            parts.append(String(localized: "Running", bundle: .strings, comment: "Homebrew service or device state: running now"))
        }
        if let busy = model.lastBusy[service.formula] {
            parts.append(String(
                localized: "busy \(busy.formatted(.relative(presentation: .named)))",
                bundle: .strings,
                comment: "Homebrew service: last hour it used the processor, e.g. busy 2 hours ago"
            ))
        } else if model.isQuiet(service) {
            parts.append(String(localized: "not busy in two weeks", bundle: .strings, comment: "Homebrew service: no busy hour in History"))
        }
        return parts.joined(separator: " · ")
    }

    private var summary: String {
        let running = model.services.filter(\.isRunning)
        guard model.loaded, !model.services.isEmpty else {
            return String(localized: "Homebrew services", bundle: .strings)
        }
        guard !running.isEmpty else {
            return String(
                localized: "None of \(model.services.count) Homebrew services running",
                bundle: .strings,
                comment: "Services summary: none running, how many there are"
            )
        }
        let memory = Formatters.memory(running.reduce(0) { $0 &+ $1.memoryBytes })
        return String(
            localized: "\(running.count) of \(model.services.count) Homebrew services running, \(memory)",
            bundle: .strings,
            comment: "Services summary: running, all, memory they hold"
        )
    }

    private var quietSummary: String? {
        let quiet = model.services.filter { model.isQuiet($0) }
        guard !quiet.isEmpty else {
            return nil
        }
        return String(
            localized: "Not busy in two weeks: \(quiet.map(\.formula).formatted(.list(type: .and)))",
            bundle: .strings,
            comment: "Services: the running services with no busy hour in two weeks"
        )
    }
}
