import Core
import SwiftUI

/// Quick Search (D-137): a global shortcut's panel over apps, processes and ports. Return shows
/// the selection in Mactivity; ⌘⌫ asks to quit it, in the panel's own confirmation.
public struct QuickSearchView: View {
    private let services: AppServices
    private let close: () -> Void
    @State private var query = ""
    /// The selected result's ID, not its position: the list re-sorts by live CPU every second,
    /// and a position would slide onto another app between ↓ and ⌘⌫ (D-142).
    @State private var selectedID: String?
    @FocusState private var focused: Bool
    /// Apple Intelligence is on: read once as the panel opens (D-153).
    @State private var canAsk = false

    public init(services: AppServices, close: @escaping () -> Void) {
        self.services = services
        self.close = close
    }

    /// Already typed: render tests.
    init(services: AppServices, query: String, close: @escaping () -> Void) {
        self.init(services: services, close: close)
        _query = State(initialValue: query)
    }

    private var results: [QuickSearchResult] {
        QuickSearch.results(
            query, snapshot: services.metrics.snapshot, projects: services.projects.projects, canAsk: canAsk, pages: Self.pages(services),
            actionTitles: Self.actionTitles
        )
    }

    /// The actions' names in the Mac's language, to find them by: none in English, whose words
    /// Core already knows (D-221).
    static var actionTitles: [QuickSearchResult: String] {
        guard Bundle.strings.preferredLocalizations.first?.hasPrefix("en") == false else {
            return [:]
        }
        let actions: [QuickSearchResult] = [.diagnose, .record, .nextMac, .compare, .cleanKeyboard, .day(daysBack: 0), .day(daysBack: 1)]
        return Dictionary(uniqueKeysWithValues: actions.map { ($0, action($0).title) })
    }

    /// Where the selection is now; the first row when it's gone or nothing is selected.
    private func position(in results: [QuickSearchResult]) -> Int {
        selectedID.flatMap { id in results.firstIndex { $0.id == id } } ?? 0
    }

    public var body: some View {
        let results = results
        let selected = position(in: results)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Tokens.Spacing.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(
                    canAsk
                        ? String(localized: "Apps, pages, processes, ports, or ask a question…", bundle: .strings)
                        : String(localized: "Apps, pages, processes, ports…", bundle: .strings),
                    text: $query
                )
                .textFieldStyle(.plain)
                .font(.title2)
                .focused($focused)
                .onSubmit { perform(self.results, at: position(in: self.results)) }
            }
            .padding(Tokens.Spacing.m)
            Divider()
            if services.ask.state != .idle {
                AskAnswerView(model: services.ask)
                    .frame(height: 320)
            } else {
                resultsList(results, selected: selected)
            }
            Divider()
            Text(footer)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Tokens.Spacing.m)
                .padding(.vertical, Tokens.Spacing.xs)
        }
        .frame(width: 560)
        .onAppear {
            focused = true
            canAsk = services.ask.isOffered
            services.metrics.setVisible(true, surface: .quickSearch)
            // Ports come from the dev-server list, which only refreshes while Projects shows.
            services.projects.appeared()
        }
        .onDisappear {
            services.metrics.setVisible(false, surface: .quickSearch)
            services.projects.disappeared()
            services.ask.reset()
        }
        .onChange(of: query) {
            selectedID = nil
            services.ask.reset()
        }
        .onKeyPress(.downArrow) {
            let results = self.results
            let next = min(position(in: results) + 1, max(0, results.count - 1))
            selectedID = results.indices.contains(next) ? results[next].id : nil
            return .handled
        }
        .onKeyPress(.upArrow) {
            let results = self.results
            let previous = max(position(in: results) - 1, 0)
            selectedID = results.indices.contains(previous) ? results[previous].id : nil
            return .handled
        }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .background {
            // ⌘⌫, like Finder's Move to Trash: quit the selection after confirming.
            Button("") { quit(self.results, at: position(in: self.results)) }
                .keyboardShortcut(.delete, modifiers: .command)
                .hidden()
        }
        .confirmedActionDialog(services.confirmedAction, presenter: .panel)
    }

    private var footer: String {
        services.ask.state == .idle
            ? String(localized: "Return shows it in Mactivity · ⌘⌫ quits it · Esc closes", bundle: .strings)
            : String(localized: "Written by Apple Intelligence on your Mac. Check it against the figures.", bundle: .strings)
    }

    private func resultsList(_ results: [QuickSearchResult], selected: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        row(result, isSelected: index == selected)
                            .id(index)
                            .contentShape(.rect)
                            .onTapGesture { perform(results, at: index) }
                    }
                    if results.isEmpty {
                        Text("Nothing matches.", bundle: .strings)
                            .foregroundStyle(.secondary)
                            .padding(Tokens.Spacing.m)
                    }
                }
                .padding(Tokens.Spacing.xs)
            }
            .frame(height: 320)
            .onChange(of: selectedID) { proxy.scrollTo(position(in: self.results)) }
        }
    }

    private func row(_ result: QuickSearchResult, isSelected: Bool) -> some View {
        HStack(spacing: Tokens.Spacing.s) {
            switch result {
            case .diagnose, .record, .nextMac, .day, .cleanKeyboard, .compare:
                actionLabel(result)
            case let .ask(question):
                Image(systemName: "apple.intelligence")
                    .frame(width: Tokens.IconSize.row, height: Tokens.IconSize.row)
                Text("Ask Mactivity: “\(question)”", bundle: .strings)
                    .lineLimit(1)
                Spacer()
            case let .page(page):
                Image(systemName: SidebarItem(rawValue: page.id)?.symbol ?? "sidebar.left")
                    .frame(width: Tokens.IconSize.row, height: Tokens.IconSize.row)
                Text(page.title)
                Spacer()
                Text("Page", bundle: .strings, comment: "Quick Search: the result is a page of the main window")
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
            case let .app(app):
                AppIconView(app.app)
                Text(app.app.name)
                Spacer()
                figures(cpu: app.cpuPercent, memory: app.memoryBytes)
            case let .process(process):
                Image(systemName: "gearshape")
                    .frame(width: Tokens.IconSize.row, height: Tokens.IconSize.row)
                Text(process.name)
                Text(verbatim: "PID \(process.pid)").foregroundStyle(.secondary)
                Spacer()
                figures(cpu: process.cpuPercent, memory: process.footprintBytes)
            case let .port(port, server, project):
                Image(systemName: "network")
                    .frame(width: Tokens.IconSize.row, height: Tokens.IconSize.row)
                Text(verbatim: ":\(port)").monospacedDigit()
                Text(verbatim: "\(project) · \(server.name)").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, Tokens.Spacing.s)
        .padding(.vertical, Tokens.Spacing.xs)
        .background(isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The actions' rows: a symbol and what it does.
    @ViewBuilder private func actionLabel(_ result: QuickSearchResult) -> some View {
        let (symbol, title) = Self.action(result)
        Image(systemName: symbol)
            .frame(width: Tokens.IconSize.row, height: Tokens.IconSize.row)
        Text(title)
        Spacer()
    }

    static func action(_ result: QuickSearchResult) -> (symbol: String, title: String) {
        switch result {
        case .diagnose:
            ("gauge.with.needle", String(localized: "Why is my Mac slow?", bundle: .strings))
        case .record:
            ("record.circle", String(localized: "Record Activity…", bundle: .strings))
        case .nextMac:
            ("laptopcomputer", String(localized: "Your Next Mac…", bundle: .strings))
        case .compare:
            (
                "rectangle.split.2x1",
                String(localized: "Compare Days…", bundle: .strings, comment: "Quick Search: opens two days side by side")
            )
        case .cleanKeyboard:
            (
                "keyboard",
                String(localized: "Clean Keyboard", bundle: .strings, comment: "Quick Search: locks the keyboard so it can be wiped")
            )
        case let .day(daysBack):
            (
                "clock.arrow.circlepath",
                daysBack == 0
                    ? String(localized: "Your Day: Today", bundle: .strings, comment: "Quick Search: opens today's timeline")
                    : String(localized: "Your Day: Yesterday", bundle: .strings, comment: "Quick Search: opens yesterday's timeline")
            )
        default:
            ("magnifyingglass", "")
        }
    }

    /// Every page of the main window, named as the sidebar names it.
    static func pages(_ services: AppServices) -> [QuickSearchPage] {
        let hasBattery = services.metrics.hardware.hasBattery
        return SidebarItem.allCases.map { QuickSearchPage(id: $0.rawValue, title: $0.title(hasBattery: hasBattery)) }
    }

    private func figures(cpu: Double, memory: UInt64) -> some View {
        HStack(spacing: Tokens.Spacing.s) {
            Text(Formatters.percent(cpu, fractionDigits: 1))
            Text(Formatters.memory(memory))
        }
        .font(Tokens.Typography.secondary)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

    private func perform(_ results: [QuickSearchResult], at index: Int) {
        guard results.indices.contains(index) else {
            return
        }
        if case let .ask(question) = results[index] {
            services.ask.ask(question, services: services)
            return
        }
        close()
        switch results[index] {
        case .ask:
            break
        case .diagnose:
            services.navigation.openMainWindow()
            services.slowdown.open(services)
        case .record:
            services.recording.chooseFileAndStart(metrics: services.metrics)
        case .nextMac:
            services.navigation.openMainWindow()
            services.nextMac.open()
        case .cleanKeyboard:
            services.controls.cleanKeyboard()
        case .compare:
            services.navigation.openMainWindow()
            services.compare.open(day: Date())
        case let .day(daysBack):
            let day = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
            services.navigation.openMainWindow()
            services.navigation.showDay(day)
        case let .page(page):
            if let item = SidebarItem(rawValue: page.id) {
                services.navigation.openMainWindow()
                services.navigation.show(item)
            }
        case let .app(app):
            services.navigation.show(.cpu, highlighting: app.id)
        case let .process(process):
            services.navigation.show(.cpu, highlighting: process.app)
        case .port:
            services.navigation.show(.projects)
        }
    }

    private func quit(_ results: [QuickSearchResult], at index: Int) {
        guard results.indices.contains(index) else {
            return
        }
        switch results[index] {
        case let .app(app):
            let pids = services.metrics.snapshot?.processes.filter { $0.app == app.id }.map(\.pid) ?? []
            services.requestQuit(app, pids: pids, mode: .quit, presenter: .panel)
        case let .process(process):
            services.requestQuit(process, mode: .quit, presenter: .panel)
        case .diagnose, .record, .nextMac, .page, .day, .ask, .port, .cleanKeyboard, .compare:
            break
        }
    }
}

/// The question and the model's answer as it streams in (D-153).
struct AskAnswerView: View {
    let model: AskModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                Label {
                    Text(model.question).font(Tokens.Typography.cardTitle)
                } icon: {
                    Image(systemName: "apple.intelligence")
                }
                switch model.state {
                case let .failed(message):
                    Text(message).foregroundStyle(.secondary)
                default:
                    if model.answer.isEmpty {
                        ProgressView().controlSize(.small)
                    } else {
                        // The model writes **bold** names; shown as bold, not asterisks (D-199).
                        Text((try? AttributedString(
                            markdown: model.answer, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                        )) ?? AttributedString(model.answer))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Tokens.Spacing.m)
        }
    }
}
