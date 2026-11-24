import Core
import Projects
import Simulated
import SwiftUI

/// App list (spec 4.3 step 4): every app sorted by one metric, with process count and figure.
/// Expanding a row shows its processes.
public struct AppListView: View {
    private let apps: [AppAggregate]
    private let processesByApp: [AppIdentity.ID: [ProcessSample]]
    private let metric: Metric
    private let search: String
    private let highlightedAppID: AppIdentity.ID?
    private let services: AppServices?

    @State private var expanded: Set<AppIdentity.ID> = []
    /// Rows the search opened that the person closed again; cleared when the search changes.
    @State private var collapsedInSearch: Set<AppIdentity.ID> = []
    @State private var pulse: AppIdentity.ID?
    /// Without `services` (previews), selection and Get Info stay local.
    @State private var localSelection: AppListSelection?
    @State private var connections: ConnectionsTarget?
    @State private var argumentsCache = ProcessArgumentsCache()
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        data: AppListData?,
        metric: Metric,
        search: String = "",
        highlightedAppID: AppIdentity.ID? = nil,
        services: AppServices? = nil
    ) {
        self.services = services
        apps = data?.apps ?? []
        processesByApp = data?.processesByApp ?? [:]
        self.metric = metric
        self.search = search
        self.highlightedAppID = highlightedAppID
    }

    public var body: some View {
        // Worked out once per render: every row asks it.
        let found = AppListSearch(search, apps: apps, processesByApp: processesByApp)
        let shown = sortedApps(found)
        let total = Self.shareTotal(apps, metric: metric)
        ScrollViewReader { proxy in
            // Selectable, so the Process menu and the toolbar can act on a row from the keyboard.
            List(selection: selection) {
                ForEach(shown) { app in
                    DisclosureGroup(isExpanded: expansion(for: app.id, search: found)) {
                        // Built only while expanded: most rows never are.
                        if isExpanded(app.id, search: found) {
                            let split = browserSplit(app)
                            if let split {
                                BrowserSplitRow(groups: split.groups, metric: metric, total: total, isBrowser: split.isBrowser)
                            }
                            ForEach(processRows(for: app.id, search: found)) { process in
                                ProcessRow(process: process, metric: metric, total: total, kind: split.flatMap { split in
                                    BrowserProcessKind.classify(
                                        name: process.name, arguments: split.arguments[process.pid] ?? [], appName: split.mainName
                                    )?.rowTitle(isBrowser: split.isBrowser)
                                })
                                .contextMenu { processMenu(process, in: app.app) }
                                .tag(AppListSelection.process(pid: process.pid, app: app.id))
                            }
                        }
                    } label: {
                        AppRow(app: app, metric: metric, total: total)
                            .contextMenu { appMenu(app) }
                            .swipeActions(edge: .trailing) { appSwipe(app) }
                            .tag(AppListSelection.app(app.id))
                    }
                    .id(app.id)
                    .listRowBackground(pulse == app.id ? Tokens.Colors.pulse(contrast) : nil)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .overlay {
                if found != nil, shown.isEmpty {
                    ContentUnavailableView.search(text: search.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            // macOS's own processes are only in the snapshot while something needs them: the
            // expanded macOS row, or a search, which looks through their names too (D-063).
            .onChange(of: isExpanded(AppIdentity.system.id, search: found) || found != nil, initial: true) { _, needed in
                services?.metrics.showsSystemProcesses = needed
            }
            .onChange(of: search) { collapsedInSearch = [] }
            .onDisappear { services?.metrics.showsSystemProcesses = false }
            .sheet(item: inspected) { target in
                if let services {
                    ProcessInspectorView(pid: target.id, source: services.processDetails, services: services)
                        .onDone { services.navigation.inspectedPID = nil }
                }
            }
            .sheet(item: $connections) { target in
                if let services {
                    // A sheet draws confirmation items as its own bottom bar, trailing.
                    AppConnectionsView(appName: target.name, pids: target.pids, source: services.processDetails)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(String(localized: "Done", bundle: .strings)) { connections = nil }
                                    .keyboardShortcut(.defaultAction)
                            }
                        }
                }
            }
            .onChange(of: highlightedAppID, initial: true) { _, id in
                guard let id else {
                    return
                }
                withAnimation(Tokens.Motion.figure(reduced: reduceMotion)) {
                    proxy.scrollTo(id, anchor: .center)
                    pulse = id
                }
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    withAnimation(Tokens.Motion.figure(reduced: reduceMotion)) { pulse = nil }
                    // Done: the same app asked for again (a second click on one alert) pulses again.
                    if services?.navigation.highlightedAppID == id {
                        services?.navigation.highlightedAppID = nil
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func appMenu(_ app: AppAggregate) -> some View {
        if let services {
            if services.canTerminate(app.app) {
                let pids = (processesByApp[app.id] ?? []).map(\.pid)
                Button(String(localized: "Quit \(app.app.name)…", bundle: .strings, comment: "Menu item: app name")) {
                    services.requestQuit(app, pids: pids, mode: .quit)
                }
                Button(role: .destructive) {
                    services.requestQuit(app, pids: pids, mode: .forceQuit)
                } label: {
                    Text("Force Quit \(app.app.name)…", bundle: .strings, comment: "Menu item: app name")
                }
            } else {
                Button(app.app.kind == .system ? Self.cantQuit(app.app) : String(localized: "This is Mactivity", bundle: .strings)) {}
                    .disabled(true)
            }
            Divider()
            if AppListSelection.app(app.id).canGetInfo {
                Button(String(localized: "Get Info…", bundle: .strings, comment: "Menu item: process inspector")) {
                    services.navigation.inspectedPID = AppListSelection.app(app.id).infoPID(in: processesByApp)
                }
            }
            Button(String(localized: "History…", bundle: .strings, comment: "Menu item: the app's own history page")) {
                services.navigation.openMainWindow()
                services.appHistory.open(app.app)
            }
            Button(String(localized: "Connections…", bundle: .strings, comment: "Menu item: shows an app's network connections")) {
                connections = ConnectionsTarget(id: app.id, name: app.app.name, pids: (processesByApp[app.id] ?? []).map(\.pid))
            }
            if app.app.kind == .app || app.app.kind == .terminal {
                Button(String(localized: "Show in Finder", bundle: .strings)) { services.showInFinder(app.app) }
            }
            // macOS never alerts (spec 4.4), so there's nothing to mute.
            if app.app.kind != .system {
                Divider()
                muteButton(app.app, services: services)
            }
        }
    }

    /// Mute Alerts for the app, or Unmute: the same list as Settings → Alerts → Apps with muted alerts.
    private func muteButton(_ app: AppIdentity, services: AppServices) -> some View {
        let muted = services.alertSettings.mutedAppIDs.contains(app.id)
        return Button(
            muted
                ? String(localized: "Unmute Alerts for \(app.name)", bundle: .strings, comment: "Menu item: app name")
                : String(localized: "Mute Alerts for \(app.name)", bundle: .strings, comment: "Menu item: app name")
        ) {
            services.setAlertsMuted(!muted, for: app.id)
        }
    }

    @ViewBuilder
    private func appSwipe(_ app: AppAggregate) -> some View {
        if let services, services.canTerminate(app.app) {
            let pids = (processesByApp[app.id] ?? []).map(\.pid)
            Button(String(localized: "Force Quit", bundle: .strings, comment: "Swipe action"), role: .destructive) {
                services.requestQuit(app, pids: pids, mode: .forceQuit)
            }
            Button(String(localized: "Quit", bundle: .strings, comment: "Swipe action")) {
                services.requestQuit(app, pids: pids, mode: .quit)
            }
        }
    }

    @ViewBuilder
    private func processMenu(_ process: ProcessSample, in app: AppIdentity) -> some View {
        if let services {
            if app.kind == .system {
                Button(Self.cantQuit(app)) {}
                    .disabled(true)
            } else {
                Button(String(localized: "Quit “\(process.name)”…", bundle: .strings, comment: "Menu item: process name")) {
                    services.requestQuit(process, mode: .quit)
                }
                Button(role: .destructive) {
                    services.requestQuit(process, mode: .forceQuit)
                } label: {
                    Text("Force Quit “\(process.name)”…", bundle: .strings, comment: "Menu item: process name")
                }
            }
            Divider()
            Button(String(localized: "Get Info…", bundle: .strings, comment: "Menu item: process inspector")) {
                services.navigation.inspectedPID = process.pid
            }
        }
    }

    /// The helper is read-only by design (spec 6.9), so no setting changes this.
    /// Why the row's processes have no Quit: macOS's own, or another person's (D-221).
    static func cantQuit(_ app: AppIdentity) -> String {
        app.id == AppIdentity.otherUsers.id
            ? String(
                localized: "Other people's processes can't be quit from Mactivity.",
                bundle: .strings,
                comment: "Disabled menu item: processes of other people signed in to this Mac can't be quit"
            )
            : systemProcesses
    }

    static let systemProcesses = String(
        localized: "macOS processes can't be quit from Mactivity.",
        bundle: .strings,
        comment: "Disabled menu item and note: macOS's own processes can't be quit"
    )

    private var selection: Binding<AppListSelection?> {
        Binding {
            services?.navigation.appListSelection ?? localSelection
        } set: { selected in
            if let services {
                services.navigation.appListSelection = selected
            } else {
                localSelection = selected
            }
        }
    }

    private var inspected: Binding<InspectedProcess?> {
        Binding {
            services?.navigation.inspectedPID.map(InspectedProcess.init)
        } set: { target in
            services?.navigation.inspectedPID = target?.id
        }
    }

    /// Open by the person, or by a search that matched only its processes (unless closed again).
    private func isExpanded(_ id: AppIdentity.ID, search found: AppListSearch?) -> Bool {
        expanded.contains(id) || (found?.expands(id) == true && !collapsedInSearch.contains(id))
    }

    private func expansion(for id: AppIdentity.ID, search found: AppListSearch?) -> Binding<Bool> {
        Binding {
            isExpanded(id, search: found)
        } set: { isExpanded in
            if isExpanded {
                expanded.insert(id)
                collapsedInSearch.remove(id)
            } else {
                expanded.remove(id)
                collapsedInSearch.insert(id)
            }
        }
    }

    /// Highest first; apps with no figure for the metric last, then by name (`AppAggregate.ranked`).
    private func sortedApps(_ found: AppListSearch?) -> [AppAggregate] {
        let filtered = found.map { found in apps.filter { found.appIDs.contains($0.id) } } ?? apps
        return AppAggregate.ranked(filtered) { $0.value(for: metric) }
    }

    /// A browser's or Electron app's processes by role (D-154); nil for other apps.
    private func browserSplit(_ app: AppAggregate) -> BrowserSplit? {
        let processes = processesByApp[app.id] ?? []
        guard processes.count > 3, processes.contains(where: { BrowserProcessKind.classify(
            name: $0.name,
            arguments: [],
            appName: app.app.name
        ) == .pages }) else {
            return nil
        }
        let arguments = argumentsCache.arguments(for: processes, source: services?.processArguments ?? SimulatedProcessArguments())
        guard let groups = BrowserProcessKind.groups(processes, appName: app.app.name, metric: metric, arguments: arguments) else {
            return nil
        }
        return BrowserSplit(
            groups: groups,
            arguments: arguments,
            mainName: BrowserProcessKind.mainName(processes.map(\.name), appName: app.app.name),
            isBrowser: app.app.bundleID.map(BrowserProcessKind.browserBundleIDs.contains) ?? false
        )
    }

    private func processRows(for appID: AppIdentity.ID, search found: AppListSearch?) -> [ProcessSample] {
        let processes = processesByApp[appID] ?? []
        return (found?.processes(processes, of: appID) ?? processes)
            .sorted { ($0.value(for: metric) ?? -1) > ($1.value(for: metric) ?? -1) }
    }
}

struct BrowserSplit {
    let groups: [BrowserProcessKind.Group]
    let arguments: [Int32: [String]]
    let mainName: String
    let isBrowser: Bool
}

extension AppListView {
    /// Energy Impact is a unitless score ("96.8" says nothing on its own), so lists show each
    /// app's share of all apps' instead (D-112), like the Top apps panel (D-105). The total is
    /// every app's, whatever the search shows.
    nonisolated static func shareTotal(_ apps: [AppAggregate], metric: Metric) -> Double? {
        guard metric == .energyImpact else {
            return nil
        }
        return apps.reduce(0) { $0 + ($1.value(for: metric) ?? 0) }
    }

    /// A row's figure: its share of `total` when there is one, else the metric's own units.
    nonisolated static func valueText(_ value: Double?, metric: Metric, total: Double?) -> String {
        guard let total else {
            return Formatters.metric(value, metric)
        }
        guard let value else {
            return "–"
        }
        return Formatters.percent(total > 0 ? value / total * 100 : 0)
    }
}

private struct InspectedProcess: Identifiable {
    let id: Int32
}

private struct ConnectionsTarget: Identifiable {
    let id: AppIdentity.ID
    let name: String
    let pids: [Int32]
}
