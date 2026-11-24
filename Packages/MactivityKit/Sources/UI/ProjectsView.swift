import AppKit
import Core
import SwiftUI

/// Projects tab (spec 5.5, 10.2): dev servers grouped by project, a one-line summary, Stop
/// per project, and Stop Idle / Stop All. Every stop goes through `ConfirmedAction`.
struct ProjectsView: View {
    let services: AppServices

    @State private var selection: Set<Project.ID> = []
    /// Seven segments take about 630 pt, and more in a long language: a window with less gets the
    /// same picker as a menu, so no view is ever pushed out of the toolbar (D-279).
    @State private var segmentsFit = true

    var body: some View {
        Group {
            switch services.navigation.projectsTab {
            case .servers: servers
            case .space: ProjectFoldersView(glance: services.projectGlance, space: services.projectSpace)
            case .databases: LocalDatabasesView(model: services.localDatabases, history: services.history)
            case .remote: RemoteSessionsView(model: services.remoteSessions)
            case .services: HomebrewServicesView(model: services.homebrewServices, history: services.history)
            case .simulators: DevDevicesView(model: services.devDevices, services: services)
            case .background: DevToolsView(model: services.devTools, confirmedAction: services.confirmedAction, services: services)
            }
        }
        .padding(Tokens.Spacing.l)
        .onGeometryChange(for: Bool.self) { $0.size.width >= ProjectsTab.widthForSegments } action: { segmentsFit = $0 }
        // Exactly the window's height: what still doesn't fit runs off the bottom, rather than
        // the page sliding up under the toolbar (D-072, D-175).
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .confirmedActionDialog(services.confirmedAction)
        // Switching views is navigation, so it lives in the toolbar, as on Storage (D-223).
        .toolbar {
            ToolbarItem(placement: .principal) {
                if segmentsFit {
                    viewPicker.pickerStyle(.segmented)
                } else {
                    viewPicker.pickerStyle(.menu)
                }
            }
        }
    }

    private var viewPicker: some View {
        Picker(
            String(localized: "View", bundle: .strings, comment: "Projects tab picker: servers, space…"),
            selection: Binding(get: { services.navigation.projectsTab }, set: { services.navigation.projectsTab = $0 })
        ) {
            ForEach(ProjectsTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .labelsHidden()
        .fixedSize()
        .help(Text("Projects view", bundle: .strings))
    }

    private var servers: some View {
        let model = services.projects
        return VStack(alignment: .leading, spacing: Tokens.Spacing.gridGutter) {
            header(model)
            if model.hasScanned, model.projects.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No dev servers running", bundle: .strings), systemImage: SidebarItem.projects.symbol)
                } description: {
                    Text(
                        """
                        A process that listens on a TCP port from inside a project folder shows up here. \
                        Docker containers show up below while Docker runs.
                        """,
                        bundle: .strings
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            } else {
                table(model)
                    .clipShape(Tokens.Shapes.card)
                    .fittedTable(TableFit.height(twoLineRows: model.projects.count))
                    .layoutPriority(1)
            }
            // Attaches only the restart dialog; stops use the view's own dialog below.
            ContainersSection(model: services.containers, confirmedAction: services.confirmedAction)
                .layoutPriority(1)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(text: toast)
            }
        }
        .animation(Tokens.Motion.figure, value: model.toast)
        .onAppear { model.appeared() }
        .onDisappear { model.disappeared() }
    }

    private func header(_ model: ProjectsModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
            Text(model.hasScanned ? ProjectText.summary(model.projects) : String(localized: "Looking for dev servers…", bundle: .strings))
                .font(Tokens.Typography.cardTitle)
                .monospacedDigit()
            Spacer()
            // Always there, disabled when there's nothing to stop, so the header keeps its size
            // and the table under it doesn't move when the first server starts.
            Button(String(localized: "Stop All…", bundle: .strings, comment: "Stops every dev server, after a confirmation")) {
                let servers = model.projects.flatMap(\.servers)
                model.stop(servers, scope: .all(servers.count), through: services.confirmedAction)
            }
            // Glass, to pair with Stop Idle's prominent glass (D-030).
            .buttonStyle(.glass)
            .disabled(model.projects.isEmpty)
            Button(String(
                localized: "Stop Idle…",
                bundle: .strings,
                comment: "Stops the idle dev servers (running but unused lately), after a confirmation"
            )) {
                let idle = model.idleServers
                model.stop(idle, scope: .idle(idle.count), through: services.confirmedAction)
            }
            .buttonStyle(.glassProminent)
            .disabled(model.idleServers.isEmpty)
            .help(
                model.idleServers.isEmpty
                    ? Text("No dev server is idle", bundle: .strings, comment: "Idle: running but unused lately")
                    : Text("Stop the dev servers nobody has used lately", bundle: .strings)
            )
        }
        .cardStyle()
    }

    private func table(_ model: ProjectsModel) -> some View {
        Table(model.projects, selection: $selection) {
            TableColumn(Text("Project", bundle: .strings)) { project in
                VStack(alignment: .leading, spacing: Tokens.Spacing.lineGap) {
                    Text(project.name)
                        .font(Tokens.Typography.rowTitle)
                    Text(project.servers.map(\.command).joined(separator: " · "))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(project.rootPath)
                }
            }
            .width(min: 180, ideal: 220)
            TableColumn(Text("Runtime", bundle: .strings, comment: "Column: Node, Python, Ruby…")) { project in
                RuntimeTag(runtime: project.runtime)
            }
            .width(80)
            TableColumn(Text("Ports", bundle: .strings)) { project in
                Text(ProjectText.portList(project.ports, limit: 3))
                    .font(Tokens.Typography.code)
                    .lineLimit(1)
                    .help(ProjectText.allPorts(project.ports))
            }
            .width(min: 70, ideal: 110)
            TableColumn(Text("Memory", bundle: .strings)) { project in
                Text(Formatters.memory(project.memoryBytes))
                    .monospacedDigit()
            }
            .width(70)
            .alignment(.numeric)
            TableColumn(Text("Up", bundle: .strings, comment: "Column: how long it has been running")) { project in
                Text(Formatters.duration(.seconds(max(0, Date().timeIntervalSince(project.startedAt)))))
                    .monospacedDigit()
            }
            .width(70)
            .alignment(.numeric)
            TableColumn(Text("Activity", bundle: .strings, comment: "Column: working, idle, or barely used")) { project in
                Text(project.activity.title)
                    .foregroundStyle(project.activity == .barelyUsed ? AnyShapeStyle(Tokens.Colors.strainLabel) : AnyShapeStyle(.secondary))
            }
            .width(min: 90, ideal: 110)
            TableColumn(Text(verbatim: "")) { project in
                Button(String(localized: "Stop…", bundle: .strings, comment: "Stops it, after a confirmation")) {
                    model.stop(project.servers, scope: .named(project.name), through: services.confirmedAction)
                }
                .controlSize(.small)
            }
            .width(60)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: Project.ID.self) { ids in
            // The clicked row, or the first selected one: every item acts on one project.
            if let project = ids.first.flatMap({ id in model.projects.first { $0.id == id } }) {
                menu(for: project, model: model)
            }
        }
    }

    /// Open each port in the browser, Copy URL, Show in Finder, Open in Terminal, then Stop…
    /// (which, like the button, only asks: `ConfirmedAction` stops it).
    @ViewBuilder
    private func menu(for project: Project, model: ProjectsModel) -> some View {
        let links = ProjectLinks(project)
        ForEach(links.urls, id: \.self) { url in
            Button(String(
                localized: "Open \(ProjectLinks.hostAndPort(url)) in Browser",
                bundle: .strings,
                comment: "Menu item: a local address like localhost:3000"
            )) {
                NSWorkspace.shared.open(url)
            }
        }
        if links.urls.count == 1, let url = links.urls.first {
            Button(String(localized: "Copy URL", bundle: .strings)) { ProjectLinks.copy(url) }
        } else if links.urls.count > 1 {
            Menu(String(localized: "Copy URL", bundle: .strings)) {
                ForEach(links.urls, id: \.self) { url in
                    Button(url.absoluteString) { ProjectLinks.copy(url) }
                }
            }
        }
        if !links.urls.isEmpty {
            Divider()
        }
        Button(String(localized: "Show in Finder", bundle: .strings)) { ProjectLinks.showInFinder(links.folder) }
        Button(String(localized: "Open in Terminal", bundle: .strings)) { ProjectLinks.openInTerminal(links.folder) }
        Divider()
        Button(String(localized: "Stop…", bundle: .strings, comment: "Stops it, after a confirmation")) {
            model.stop(project.servers, scope: .named(project.name), through: services.confirmedAction)
        }
    }
}

/// Where a project's context menu goes: its servers' local addresses and its folder. Pure,
/// except the three actions at the end, which hand off to the browser, Finder, and Terminal.
struct ProjectLinks {
    /// http://localhost:PORT for each listening port, lowest first.
    let urls: [URL]
    let folder: URL

    init(_ project: Project) {
        urls = project.ports.compactMap(Self.url)
        folder = URL(fileURLWithPath: project.rootPath, isDirectory: true)
    }

    static func url(port: UInt16) -> URL? {
        URL(string: "http://localhost:\(port)")
    }

    /// "localhost:3000", for the menu item.
    static func hostAndPort(_ url: URL) -> String {
        [url.host(), url.port.map(String.init)].compactMap(\.self).joined(separator: ":")
    }

    static let terminalBundleID = "com.apple.Terminal"

    @MainActor
    static func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @MainActor
    static func showInFinder(_ folder: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// A new Terminal window at the folder.
    @MainActor
    static func openInTerminal(_ folder: URL) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminalBundleID) else {
            return
        }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Runtime as a small capsule tag (spec 10.2).
struct RuntimeTag: View {
    let runtime: DevRuntime

    var body: some View {
        Text(runtime.title)
            .tagStyle()
    }
}

/// Projects in the menu bar window: the count, what's idle, and the top five (spec 4.2).
struct CompactProjectsView: View {
    let services: AppServices

    var body: some View {
        let model = services.projects
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                CardHeader(
                    title: String(localized: "Projects", bundle: .strings),
                    symbol: SidebarItem.projects.symbol,
                    status: nil,
                    tint: SidebarItem.projects.tint
                )
                FigureText(
                    "\(model.projects.flatMap(\.servers).count)",
                    value: Double(model.projects.count),
                    font: Tokens.Typography.headline
                )
                let summary = model.hasScanned
                    ? ProjectText.summary(model.projects)
                    : String(localized: "Looking for dev servers…", bundle: .strings)
                // Two lines, always reserved: the card is the same height whether the summary is
                // "Looking…" or names what stopping the idle ones frees.
                Text(summary)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .help(summary)
            }
            .cardStyle()
            if !model.projects.isEmpty {
                // A grid, so the ports and the statuses line up row to row: in an HStack each
                // status's own width pushed its ports left or right.
                Grid(alignment: .leading, horizontalSpacing: Tokens.Spacing.xs, verticalSpacing: Tokens.Spacing.xs) {
                    ForEach(model.projects.prefix(5)) { project in
                        GridRow {
                            // The grid sizes this column to the widest tag, not a fixed 58 pt.
                            RuntimeTag(runtime: project.runtime)
                            // The name truncates last; the status gives way first (D-175: in a long
                            // language "storefront-web" was down to "…").
                            Text(project.name)
                                .lineLimit(1)
                                .layoutPriority(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(project.name)
                            // At the status's size: body-size digits left "storefront-web" no room.
                            Text(ProjectText.portList(project.ports, limit: 1))
                                .font(Tokens.Typography.codeSecondary)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                                .gridColumnAlignment(.trailing)
                                .help(ProjectText.allPorts(project.ports))
                            Text(project.activity.shortTitle)
                                .font(Tokens.Typography.secondary)
                                .foregroundStyle(project
                                    .activity == .barelyUsed ? AnyShapeStyle(Tokens.Colors.strainLabel) : AnyShapeStyle(.secondary))
                                .lineLimit(1)
                                .help(project.activity.title)
                        }
                    }
                }
                .cardStyle()
            }
        }
        .onAppear { model.appeared() }
        .onDisappear { model.disappeared() }
    }
}

#Preview("Projects") {
    ProjectsView(services: .preview())
        .frame(width: 1000, height: 600)
}

/// The Projects page's views (D-223).
public enum ProjectsTab: String, CaseIterable, Identifiable, Sendable {
    case servers, space, databases, remote, services, simulators, background

    public var id: String {
        rawValue
    }

    /// How wide the page must be for every view as a segment. Segments are all as wide as the
    /// widest title plus about 28 pt (measured), and Share needs the room beside them.
    static var widthForSegments: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let widest = allCases.map { ($0.title as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return (widest + 28) * CGFloat(allCases.count) + 110
    }

    var title: String {
        switch self {
        case .servers: String(localized: "Servers", bundle: .strings, comment: "Projects view: dev servers and containers")
        // Was "Space"; the case keeps its name so a saved choice still opens it (D-279).
        case .space: String(localized: "Folders", bundle: .strings, comment: "Projects view: project folders and build folders")
        case .databases: String(localized: "Databases", bundle: .strings, comment: "Projects view: databases running on this Mac")
        // The tool's name, verbatim.
        case .remote: "SSH"
        // Not "Services": it sat beside "Servers" (D-229).
        case .services: String(localized: "Homebrew", bundle: .strings, comment: "Projects view: Homebrew services")
        case .simulators: String(
                localized: "Simulators",
                bundle: .strings,
                comment: "Projects view: Simulator devices and Android emulators"
            )
        case .background: String(
                localized: "Dev Tools",
                bundle: .strings,
                comment: "Projects view: language servers, watchers and test runners"
            )
        }
    }
}

/// A short confirmation floating over content. Chrome, so it's glass (spec 10.1).
struct ToastView: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .padding(.horizontal, Tokens.Spacing.m)
            .padding(.vertical, Tokens.Spacing.s)
            .glassEffect(.regular, in: Tokens.Shapes.tag)
            .padding(.bottom, Tokens.Spacing.l)
            // Fades in place with Reduce Motion on, rather than sliding up (D-221).
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            // VoiceOver says it: the toast appears away from the focus and leaves on its own.
            .onChange(of: text, initial: true) { _, text in
                AccessibilityNotification.Announcement(text).post()
            }
    }
}
