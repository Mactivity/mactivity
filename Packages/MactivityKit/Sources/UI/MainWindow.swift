import Core
import SwiftUI

/// Sidebar destinations (spec 4.3, 10.2).
public enum SidebarItem: String, CaseIterable, Identifiable, Hashable, Sendable {
    case overview, checkup, cpu, gpu, memory, disk, network, battery, projects, agents, storage, startup, security, volume, devices, alerts,
         history

    public enum Section: String, CaseIterable, Sendable {
        case top, metrics, more

        var title: String? {
            switch self {
            case .top: nil
            case .metrics: String(localized: "Metrics", bundle: .strings, comment: "Sidebar section header")
            case .more: String(localized: "More", bundle: .strings, comment: "Sidebar section header")
            }
        }
    }

    public var id: String {
        rawValue
    }

    public var section: Section {
        switch self {
        case .overview, .checkup: .top
        case .cpu, .gpu, .memory, .disk, .network, .battery: .metrics
        case .projects, .agents, .storage, .startup, .security, .volume, .devices, .alerts, .history: .more
        }
    }

    /// Looked up once: the menu bar redraws titles every tick.
    public var title: String {
        Self.titles[self] ?? rawValue
    }

    private static let titles = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.localizedTitle) })

    /// On a Mac without a battery (a desktop), the Battery tab is about power alone: "Energy".
    /// The raw value stays `battery`, so saved selections and preferences keep working.
    public func title(hasBattery: Bool) -> String {
        self == .battery && !hasBattery ? Self.energyTitle : title
    }

    public func symbol(hasBattery: Bool) -> String {
        self == .battery && !hasBattery ? Self.energySymbol : symbol
    }

    private static let energyTitle = String(
        localized: "Energy", bundle: .strings, comment: "Sidebar item and tab title: the Battery tab on a Mac without a battery"
    )
    private static let energySymbol = "bolt"

    private var localizedTitle: String {
        switch self {
        case .overview: String(localized: "Overview", bundle: .strings, comment: "Sidebar item and tab title")
        case .checkup: String(localized: "Checkup", bundle: .strings, comment: "Sidebar item and tab title: things worth doing")
        case .cpu: String(localized: "CPU", bundle: .strings, comment: "Sidebar item and tab title")
        case .memory: String(localized: "Memory", bundle: .strings, comment: "Sidebar item and tab title")
        case .disk: String(localized: "Disk", bundle: .strings, comment: "Sidebar item and tab title")
        case .network: String(localized: "Network", bundle: .strings, comment: "Sidebar item and tab title")
        case .gpu: String(localized: "GPU", bundle: .strings, comment: "Sidebar item and tab title")
        case .battery: String(localized: "Battery", bundle: .strings, comment: "Sidebar item and tab title")
        case .projects: String(localized: "Projects", bundle: .strings, comment: "Sidebar item and tab title")
        case .agents: String(localized: "Agents", bundle: .strings, comment: "Sidebar item and tab title: AI coding agents")
        case .storage: String(localized: "Storage", bundle: .strings, comment: "Sidebar item and tab title")
        case .startup: String(localized: "Startup", bundle: .strings, comment: "Sidebar item and tab title")
        case .security: String(
                localized: "Security",
                bundle: .strings,
                comment: "Sidebar item and tab title: security settings, app permissions, extensions"
            )
        case .volume: String(localized: "Sound", bundle: .strings, comment: "Sidebar item and tab title: per-app volume")
        case .devices: String(
                localized: "Devices",
                bundle: .strings,
                comment: "Sidebar item and tab title: displays, ports and what's plugged in"
            )
        case .alerts: String(localized: "Alerts", bundle: .strings, comment: "Sidebar item and tab title")
        case .history: String(localized: "History", bundle: .strings, comment: "Sidebar item and tab title")
        }
    }

    public var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .checkup: "checkmark.seal"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "network"
        case .gpu: "cube.transparent"
        case .battery: "battery.75percent"
        case .projects: "hammer"
        case .agents: "sparkles"
        case .storage: "chart.pie"
        case .startup: "power"
        case .security: "lock.shield"
        case .volume: "speaker.wave.2"
        case .devices: "display"
        case .alerts: "bell.badge"
        case .history: "clock.arrow.circlepath"
        }
    }

    public var tint: Color {
        switch self {
        case .overview: Tokens.SidebarTint.overview
        case .checkup: Tokens.SidebarTint.checkup
        case .cpu: Tokens.SidebarTint.cpu
        case .memory: Tokens.SidebarTint.memory
        case .disk: Tokens.SidebarTint.disk
        case .network: Tokens.SidebarTint.network
        case .gpu: Tokens.SidebarTint.gpu
        case .battery: Tokens.SidebarTint.battery
        case .projects: Tokens.SidebarTint.projects
        case .agents: Tokens.SidebarTint.agents
        case .storage: Tokens.SidebarTint.storage
        case .startup: Tokens.SidebarTint.startup
        case .security: Tokens.SidebarTint.security
        case .volume: Tokens.SidebarTint.volume
        case .devices: Tokens.SidebarTint.devices
        case .alerts: Tokens.SidebarTint.alerts
        case .history: Tokens.SidebarTint.history
        }
    }

    public var metricTab: MetricTab? {
        MetricTab.allCases.first { $0.sidebarItem == self }
    }

    /// Tabs with a history strip, the only ones the toolbar's range picker changes.
    var usesHistoryRange: Bool {
        metricTab != nil || self == .history
    }
}

/// The main window: sidebar, unified toolbar, one detail view per tab.
public struct MainWindowView: View {
    private let services: AppServices
    @Binding private var isSimulated: Bool

    @State private var range: HistoryRange = .h24
    @State private var search = ""
    @AppStorage(PreferenceKey.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @State private var showsOnboarding = false
    @AppStorage(PreferenceKey.perAppVolume) private var perAppVolume = false
    @Environment(\.colorScheme) private var colorScheme

    public init(services: AppServices, isSimulated: Binding<Bool>) {
        self.services = services
        _isSimulated = isSimulated
    }

    public var body: some View {
        window
            .font(Tokens.Typography.windowDefault)
            .modifier(DemoTourModifier(services: services))
            .onDisappear {
                services.releaseStorage()
                // Nothing to act on with the window gone: the Process menu turns off.
                services.navigation.appListSelection = nil
            }
    }

    @ViewBuilder private var window: some View {
        @Bindable var navigation = services.navigation
        NavigationSplitView {
            List(selection: Binding($navigation.selection)) {
                ForEach(SidebarItem.Section.allCases, id: \.self) { section in
                    Section {
                        ForEach(SidebarItem.allCases.filter { $0.section == section && (perAppVolume || $0 != .volume) }) { item in
                            // `.listItemTint` is ignored by macOS 27 sidebars; color the symbol itself.
                            Label {
                                Text(item.title(hasBattery: hasBattery))
                            } icon: {
                                Image(systemName: item.symbol(hasBattery: hasBattery))
                                    .foregroundStyle(item.tint)
                            }
                            .badge(item == .alerts ? services.recentAlerts.count(where: isToday) : 0)
                            .tag(item)
                        }
                    } header: {
                        if let title = section.title {
                            Text(title)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: Tokens.Layout.sidebarMinWidth, ideal: Tokens.Layout.sidebarWidth)
        } detail: {
            // The subtitle changes with every snapshot; its own view reads it, so this one (the
            // sidebar, the toolbar) isn't rebuilt every second (D-086).
            LiveSubtitle(metrics: services.metrics) {
                detail
                    .navigationTitle(navigation.selection.title(hasBattery: hasBattery))
            }
        }
        .toolbar {
            // Act on the app list's selected row, as the Process menu does (⌥⌘Q, ⌘I).
            if navigation.selection.metricTab != nil {
                ToolbarItemGroup(placement: .primaryAction) {
                    let selected = navigation.appListSelection
                    Button {
                        services.quitSelection(mode: .quit)
                    } label: {
                        Label(String(localized: "Quit…", bundle: .strings), systemImage: "xmark.circle")
                    }
                    .help(Text("Quit the selected app or process", bundle: .strings))
                    .disabled(selected?.canQuit != true)
                    Button {
                        services.getInfoOnSelection()
                    } label: {
                        Label(
                            String(localized: "Get Info", bundle: .strings, comment: "Toolbar button: process inspector"),
                            systemImage: "info.circle"
                        )
                    }
                    .help(Text("Show details of the selected app or process", bundle: .strings))
                    .disabled(selected?.canGetInfo != true)
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            if services.recording.isRecording {
                ToolbarItem(placement: .primaryAction) {
                    RecordingIndicator(model: services.recording)
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    services.slowdown.open(services)
                } label: {
                    Label(
                        String(localized: "Diagnose", bundle: .strings, comment: "Toolbar button: finds what's slowing the Mac down"),
                        systemImage: "gauge.with.needle"
                    )
                }
                .help(Text("Why is my Mac slow?", bundle: .strings))
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            // Only where a history strip reads it; elsewhere the picker would do nothing.
            if navigation.selection.usesHistoryRange {
                ToolbarItem(placement: .primaryAction) {
                    Picker(String(localized: "Range", bundle: .strings, comment: "History range picker"), selection: $range) {
                        ForEach(HistoryRange.allCases) { range in
                            Text(range.label).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .help(Text("History range", bundle: .strings))
                }
                // Its own glass group: a view setting, apart from the Share action.
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            // The image is Overview's live cards: offered there and on the metric tabs.
            if navigation.selection == .overview || navigation.selection.metricTab != nil {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        // The system Share menu (Messages, Mail, AirDrop…); drawn when one is picked.
                        ShareLink(
                            item: services.statusImageItem(colorScheme: colorScheme),
                            preview: SharePreview(
                                Text(verbatim: "Mactivity"),
                                image: Image(nsImage: NSApplication.shared.applicationIconImage)
                            )
                        ) {
                            Label(String(localized: "Share Image", bundle: .strings), systemImage: "square.and.arrow.up")
                        }
                        Button(String(localized: "Copy Image", bundle: .strings)) { services.copyStatusImage(colorScheme: colorScheme) }
                        Button(String(localized: "Save Image to Downloads", bundle: .strings)) {
                            services.saveStatusImage(colorScheme: colorScheme)
                        }
                    } label: {
                        Label(String(localized: "Share", bundle: .strings, comment: "Toolbar menu"), systemImage: "square.and.arrow.up")
                    }
                    .help(Text("Share an image of your Mac's figures", bundle: .strings))
                    .disabled(!services.metrics.hasSnapshot)
                }
            }
            #if DEBUG
                // Keeps the debug-only toggle out of Share's group.
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    Toggle(String(localized: "Simulated data", bundle: .strings), systemImage: "wand.and.stars", isOn: $isSimulated)
                        .help(Text("Use simulated data (debug builds only)", bundle: .strings))
                }
            #endif
        }
        .onAppear {
            services.metrics.setVisible(true, surface: .mainWindow)
            showsOnboarding = !hasCompletedOnboarding
        }
        .onDisappear { services.metrics.setVisible(false, surface: .mainWindow) }
        // Open but completely covered, minimized, or hidden: nobody can see the figures, so
        // sample at the idle cadence until the window shows again (D-061).
        .background(WindowOcclusionReader { visible in
            services.metrics.setVisible(visible, surface: .mainWindow)
        })
        .overlay(alignment: .bottom) {
            if let toast = services.toast, services.navigation.selection.metricTab == nil {
                ToastView(text: toast)
            }
        }
        .animation(Tokens.Motion.figure, value: services.toast)
        .sheet(isPresented: Bindable(services.appHistory).isPresented) {
            AppHistorySheet(services: services, model: services.appHistory)
        }
        .sheet(isPresented: Bindable(services.whatsNew).isPresented) {
            WhatsNewSheet(model: services.whatsNew)
        }
        .sheet(isPresented: Bindable(services.compare).isPresented) {
            CompareSheet(services: services, model: services.compare)
        }
        .sheet(isPresented: Bindable(services.nextMac).isPresented) {
            NextMacSheet(services: services, model: services.nextMac)
        }
        .sheet(isPresented: Bindable(services.slowdown).isPresented) {
            SlowdownSheet(services: services, model: services.slowdown)
        }
        .sheet(isPresented: Bindable(services.unusedApps).isPresented) {
            UnusedAppsSheet(services: services, model: services.unusedApps)
        }
        .sheet(isPresented: Bindable(services.software).isPresented) {
            OutdatedSoftwareSheet(model: services.software)
        }
        .sheet(isPresented: $showsOnboarding) {
            OnboardingView(services: services) {
                hasCompletedOnboarding = true
                showsOnboarding = false
            }
        }
    }

    @ViewBuilder private var detail: some View {
        let selection = services.navigation.selection
        if let tab = selection.metricTab {
            // Search filters the metric tabs' app lists and nothing else, so only they get the
            // field. On the detail column it still sits in the toolbar.
            MetricDetailView(tab: tab, services: services, range: range, search: search)
                .searchable(text: $search, placement: .toolbar, prompt: Text("Search apps", bundle: .strings))
                // A link to an app (a notification, a top app, Quick Search) clears the search
                // first: a filter left from another tab could hide the very app it shows (D-196).
                .onChange(of: services.navigation.highlightedAppID, initial: true) { _, app in
                    if app != nil, !search.isEmpty {
                        search = ""
                    }
                }
        } else {
            switch selection {
            case .overview:
                OverviewView(services: services)
            case .checkup:
                CheckupView(services: services)
            case .alerts:
                AlertsView(services: services)
            case .history:
                HistoryView(services: services, range: range)
            case .volume:
                VolumeView(services: services)
            case .storage:
                StorageView(
                    model: services.storage, confirmedAction: services.confirmedAction, navigation: services.navigation,
                    recordedApps: services.history as? any RecordedAppsStore, photos: services.photosLibrary
                )
            case .startup:
                StartupView(model: services.startup, services: services)
            case .agents:
                AgentsView(services: services)
            case .devices:
                DevicesView(services: services)
            case .security:
                SecurityView(services: services)
            default:
                ProjectsView(services: services)
            }
        }
    }

    private var hasBattery: Bool {
        services.metrics.hardware.hasBattery
    }

    private func isToday(_ alert: Core.Alert) -> Bool {
        Calendar.current.isDateInToday(alert.firedAt)
    }
}

/// The main window's subtitle ("112 apps · 1,104 processes · Up 3 days"), in a view of its own:
/// it reads the snapshot, so only this view re-evaluates every tick, not the window around it.
private struct LiveSubtitle<Content: View>: View {
    let metrics: LiveMetrics
    @ViewBuilder let content: Content

    var body: some View {
        content.navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        let labelsSimulated = metrics.isSimulated && !LaunchOverrides.isScreenshotMode
        guard let snapshot = metrics.snapshot else {
            return labelsSimulated ? String(localized: "Simulated data", bundle: .strings) : ""
        }
        // Separate items joined by " · ", one key each so each count gets its own plural.
        let apps = String(localized: "\(snapshot.apps.count) apps", bundle: .strings)
        let processes = String(localized: "\(snapshot.processCount) processes", bundle: .strings)
        let counts = "\(apps) · \(processes)"
        let uptime = String(
            localized: "Up \(Formatters.duration(snapshot.system.uptime))",
            bundle: .strings,
            comment: "Main window subtitle: system uptime"
        )
        return labelsSimulated
            ? "\(String(localized: "Simulated data", bundle: .strings)) · \(counts)"
            : "\(counts) · \(uptime)"
    }
}

#Preview("Main window") {
    MainWindowView(services: .preview(), isSimulated: .constant(true))
        .frame(width: Tokens.Layout.mainWindowDefault.width, height: Tokens.Layout.mainWindowDefault.height)
}
