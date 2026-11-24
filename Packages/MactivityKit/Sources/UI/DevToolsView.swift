import Core
import Observation
import Projects
import SwiftUI

/// Projects → Background's state (D-228): dev tools every 10 seconds while the tab shows.
@MainActor
@Observable
final class DevToolsModel {
    private let source: any DevToolSource
    private(set) var tools: [DevTool] = []
    private(set) var loaded = false

    init(source: any DevToolSource) {
        self.source = source
    }

    func load() async {
        tools = await source.tools()
        loaded = true
    }

    var leftBehind: [DevTool] {
        tools.filter(\.isLeftBehind)
    }

    /// Asks before quitting: one tool, or every one left behind.
    func quit(_ tools: [DevTool], through action: ConfirmedAction) {
        guard let first = tools.first else {
            return
        }
        let memory = Formatters.memory(tools.reduce(0) { $0 &+ $1.memoryBytes })
        let title = tools.count == 1
            ? String(localized: "Quit \(first.name)?", bundle: .strings, comment: "Confirmation title: a dev tool's name")
            : String(localized: "Quit \(tools.count) dev tools left behind?", bundle: .strings, comment: "Confirmation title")
        var lines = tools.prefix(6).map { tool in tool.project.map { "\(tool.name) (\($0))" } ?? tool.name }
        if tools.count > 6 {
            lines.append(String(localized: "and \(tools.count - 6) more", bundle: .strings, comment: "After a list of dev servers"))
        }
        // An editor starts its language servers again; a watcher or test runner stays stopped.
        let frees = tools.allSatisfy { $0.kind == .languageServer }
            ? String(
                localized: "Frees \(memory). Your editor starts them again when it needs them.",
                bundle: .strings,
                comment: "Quit dev tools confirmation: the memory they hold"
            )
            : String(
                localized: "Frees \(memory). A watcher or test runner stays stopped until you start it again.",
                bundle: .strings,
                comment: "Quit dev tools confirmation, with watchers or test runners among them: the memory they hold"
            )
        action.ask(ConfirmedAction.Request(
            title: title,
            message: lines.joined(separator: "\n") + "\n\n" + frees,
            confirmTitle: tools.count == 1
                ? String(localized: "Quit", bundle: .strings, comment: "Button: quits an app or a process")
                : String(localized: "Quit \(tools.count)", bundle: .strings, comment: "Button: quits this many dev tools"),
            targets: tools.map { .process($0.pid) },
            mode: .quit
        ) { [weak self] _ in
            Task { await self?.load() }
        })
    }
}

struct DevToolsView: View {
    let model: DevToolsModel
    let confirmedAction: ConfirmedAction
    /// For test run times under the table (D-278); nil in tests of the table alone.
    var services: AppServices?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.gridGutter) {
            header
            if !model.loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.tools.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No background dev tools", bundle: .strings), systemImage: "gearshape.2")
                } description: {
                    Text(
                        """
                        Language servers, file watchers and test runners show here while they run, with the project each \
                        works for, and the ones their editor or terminal left behind.
                        """,
                        bundle: .strings
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
                    .clipShape(Tokens.Shapes.card)
                    .fittedTable(TableFit.height(twoLineRows: model.tools.count))
                    .layoutPriority(1)
            }
            if let services {
                TestTimesCard(services: services, limit: 3)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .task {
            while !Task.isCancelled {
                await model.load()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
            Text(summary)
                .font(Tokens.Typography.cardTitle)
                .monospacedDigit()
            let behind = model.leftBehind
            if !behind.isEmpty {
                Text(
                    "\(behind.count) left behind, \(Formatters.memory(behind.reduce(0) { $0 &+ $1.memoryBytes }))",
                    bundle: .strings,
                    comment: "Dev tools: how many outlived their editor or terminal, and their memory"
                )
                .font(Tokens.Typography.secondary)
                .foregroundStyle(Tokens.Colors.strainLabel)
                .monospacedDigit()
            }
            Spacer()
            Button(String(
                localized: "Quit Left Behind…",
                bundle: .strings,
                comment: "Quits the dev tools whose editor or terminal is gone"
            )) {
                model.quit(model.leftBehind, through: confirmedAction)
            }
            .buttonStyle(.glassProminent)
            .disabled(model.leftBehind.isEmpty)
        }
        .cardStyle()
    }

    private var summary: String {
        guard model.loaded, !model.tools.isEmpty else {
            return String(localized: "Background dev tools", bundle: .strings)
        }
        let memory = Formatters.memory(model.tools.reduce(0) { $0 &+ $1.memoryBytes })
        return model.tools.count == 1
            ? String(localized: "1 dev tool running, \(memory)", bundle: .strings, comment: "Dev tools summary: one, its memory")
            : String(localized: "\(model.tools.count) dev tools running, \(memory)", bundle: .strings, comment: "Dev tools summary")
    }

    private var table: some View {
        Table(model.tools) {
            TableColumn(Text("Tool", bundle: .strings, comment: "Dev tools column")) { tool in
                VStack(alignment: .leading, spacing: Tokens.Spacing.lineGap) {
                    Text(tool.name).font(Tokens.Typography.rowTitle)
                    Text(Self.kind(tool.kind))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 160, ideal: 200)
            TableColumn(Text("Project", bundle: .strings)) { tool in
                Text(tool.project ?? "–")
                    .lineLimit(1)
                    .help(tool.directory ?? "")
            }
            .width(min: 90, ideal: 120)
            TableColumn(Text("Started by", bundle: .strings, comment: "Dev tools column: the editor or terminal that started it")) { tool in
                Text(tool.parent ?? String(
                    localized: "Left behind: its editor or terminal quit",
                    bundle: .strings,
                    comment: "Dev tools: the process that started it is gone"
                ))
                .foregroundStyle(tool.isLeftBehind ? AnyShapeStyle(Tokens.Colors.strainLabel) : AnyShapeStyle(.secondary))
                .lineLimit(2)
            }
            .width(min: 130, ideal: 180)
            TableColumn(Text("Up", bundle: .strings, comment: "Column: how long it has been running")) { tool in
                Text(tool.startedAt.map { Formatters.duration(.seconds(max(0, Date().timeIntervalSince($0)))) } ?? "–")
                    .monospacedDigit()
            }
            .width(70)
            .alignment(.numeric)
            TableColumn(Text("Memory", bundle: .strings)) { tool in
                Text(tool.memoryBytes > 0 ? Formatters.memory(tool.memoryBytes) : "–").monospacedDigit()
            }
            .width(70)
            .alignment(.numeric)
            TableColumn(Text(verbatim: "")) { tool in
                Button(String(localized: "Quit…", bundle: .strings, comment: "Quits it, after a confirmation")) {
                    model.quit([tool], through: confirmedAction)
                }
                .controlSize(.small)
            }
            .width(60)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    static func kind(_ kind: DevTool.Kind) -> String {
        switch kind {
        case .languageServer: String(localized: "Language server", bundle: .strings, comment: "Dev tool kind")
        case .watcher: String(localized: "File watcher", bundle: .strings, comment: "Dev tool kind")
        case .testRunner: String(localized: "Test runner, watching", bundle: .strings, comment: "Dev tool kind")
        }
    }
}
