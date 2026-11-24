import AppKit
import Core
import Docker
import Projects
import Simulated
import Storage
import SwiftUI
import Testing
@testable import UI

/// 1.4 and 1.5's views (D-223 on).
extension RoadmapRenderTests {
    @Test("Space per project (D-223)")
    func projectSpace() async throws {
        let docker = SimulatedContainerSource()
        let model = ProjectSpaceModel(scanner: SimulatedProjectSpaceScanner(), trasher: SimulatedStorageScanner().trasher) { docker }
        model.rescan()
        try await Task.sleep(for: .milliseconds(300))
        try await writeInWindow(
            ProjectSpaceView(model: model).padding(Tokens.Spacing.l),
            name: "project-space",
            size: CGSize(width: 900, height: 620)
        )
        model.staleOnly = true
        try await writeInWindow(
            ProjectSpaceView(model: model).padding(Tokens.Spacing.l),
            name: "project-space-stale",
            size: CGSize(width: 900, height: 620)
        )
    }

    @Test("Homebrew services (D-225)")
    func homebrewServices() async throws {
        let model = HomebrewServicesModel(source: SimulatedHomebrewServices())
        await model.load(history: nil)
        try await writeInWindow(
            HomebrewServicesView(model: model, history: nil).padding(Tokens.Spacing.l), name: "homebrew-services", size: CGSize(
                width: 980,
                height: 420
            )
        )
    }

    @Test("Simulators and emulators (D-226)")
    func devDevices() async throws {
        let model = DevDevicesModel(source: SimulatedDevDevices())
        await model.load()
        try await writeInWindow(
            DevDevicesView(model: model, services: .preview()).padding(Tokens.Spacing.l), name: "dev-devices", size: CGSize(
                width: 980,
                height: 420
            )
        )
    }

    @Test("Background dev tools (D-228)")
    func devTools() async throws {
        let model = DevToolsModel(source: SimulatedDevTools())
        await model.load()
        let action = ConfirmedAction(terminator: SimulatedContainerSource())
        try await writeInWindow(
            DevToolsView(model: model, confirmedAction: action).padding(Tokens.Spacing.l), name: "dev-tools", size: CGSize(
                width: 980,
                height: 420
            )
        )
    }

    @Test("Local databases (D-277)")
    func localDatabases() async throws {
        let model = LocalDatabasesModel(source: SimulatedLocalDatabases(), historySince: Date().addingTimeInterval(-90 * 86400))
        await model.load(history: nil)
        try await writeInWindow(
            LocalDatabasesView(model: model, history: nil).padding(Tokens.Spacing.l), name: "local-databases",
            size: CGSize(width: 900, height: 480)
        )
    }

    @Test("Remote sessions (D-280)")
    func remoteSessions() async throws {
        let model = RemoteSessionsModel(source: SimulatedRemoteSessions())
        await model.load()
        try await writeInWindow(
            RemoteSessionsView(model: model).padding(Tokens.Spacing.l), name: "remote-sessions", size: CGSize(width: 900, height: 480)
        )
    }

    @Test("Projects at a glance (D-279)")
    func projectGlance() async throws {
        let model = ProjectGlanceModel(source: SimulatedProjectGlance())
        model.rescan()
        try await Task.sleep(for: .milliseconds(300))
        let space = ProjectSpaceModel(scanner: SimulatedProjectSpaceScanner(), trasher: SimulatedStorageScanner().trasher)
        try await writeInWindow(
            ProjectFoldersView(glance: model, space: space).padding(Tokens.Spacing.l), name: "project-glance", size: CGSize(
                width: 900,
                height: 520
            )
        )
    }

    @Test("Test run times (D-278)")
    func testTimes() async throws {
        let now = Date()
        func run(
            _ seconds: Double,
            ago: Double,
            _ project: String,
            _ tool: String,
            outcome: TestOutcome = .passed,
            partial: Bool = false
        ) -> BuildRun {
            BuildRun(
                kind: .test, start: now - ago - seconds, end: now - ago, project: project, tool: tool, averageCPU: 0, peakMemory: 0,
                outcome: outcome, isPartial: partial
            )
        }
        let model = BuildsModel(projects: [], tests: [
            ProjectBuilds(
                project: "MactivityKit", tool: "swift test", count: 31, last: run(212, ago: 900, "MactivityKit", "swift test"),
                recentMedian: 208, earlierMedian: 140
            ),
            ProjectBuilds(
                project: "storefront-web", tool: "npm test", count: 12, last: run(
                    14,
                    ago: 7200,
                    "storefront-web",
                    "npm test",
                    outcome: .failed
                ),
                recentMedian: 44, earlierMedian: 46
            ),
            ProjectBuilds(
                project: "ingest", tool: "cargo test", count: 8, last: run(9, ago: 90000, "ingest", "cargo test", outcome: .cancelled),
                recentMedian: 61, earlierMedian: nil
            ),
            ProjectBuilds(
                project: "ml-notes", tool: "pytest", count: 0, last: run(6, ago: 200_000, "ml-notes", "pytest", partial: true),
                recentMedian: nil, earlierMedian: nil
            ),
        ])
        try await writeInWindow(
            TestTimesCard(services: .preview(), model: model).padding(Tokens.Spacing.l), name: "test-times", size: CGSize(
                width: 860,
                height: 300
            )
        )
    }

    @Test("Projects page with its views in the toolbar (D-223)")
    func projectsPage() async throws {
        let services = AppServices.preview()
        services.navigation.projectsTab = .space
        try await writeInWindow(
            NavigationStack { ProjectsView(services: services) },
            name: "projects-space-page",
            size: CGSize(width: 1000, height: 640)
        )
        // The narrowest the detail column gets: every view still has to be in the picker.
        try await writeInWindow(
            NavigationStack { ProjectsView(services: services) },
            name: "projects-narrow-page",
            size: CGSize(width: Tokens.Layout.mainWindowMinimum.width - Tokens.Layout.sidebarWidth, height: 520)
        )
        for tab in [ProjectsTab.databases, .remote] {
            services.navigation.projectsTab = tab
            try await writeInWindow(
                NavigationStack { ProjectsView(services: services) },
                name: "projects-narrow-\(tab.rawValue)",
                size: CGSize(width: Tokens.Layout.mainWindowMinimum.width - Tokens.Layout.sidebarWidth, height: 520)
            )
        }
    }

    @Test("Open to the network (D-230)")
    func openPorts() async throws {
        let model = OpenPortsModel(source: SimulatedOpenPorts())
        await model.load(firewall: true)
        try await writeInWindow(
            OpenPortsCard(model: model, services: .preview()).padding(Tokens.Spacing.l), name: "open-ports", size: CGSize(
                width: 820,
                height: 380
            )
        )
    }

    @Test("Who made what's running (D-232)")
    func signatures() async throws {
        let services = AppServices.preview()
        for _ in 0 ..< 40 where services.metrics.snapshot == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        let model = SignaturesModel(source: SimulatedCodeSignatures())
        await model.load(services.metrics.snapshot)
        try await writeInWindow(
            SignaturesCard(model: model, metrics: services.metrics).padding(Tokens.Spacing.l), name: "signatures", size: CGSize(
                width: 820,
                height: 360
            )
        )
    }

    @Test("Wi-Fi and networks (D-233, D-234)")
    func networkHistory() async throws {
        let services = AppServices.preview()
        let model = NetworkHistoryModel()
        await model.load(services.history)
        try await writeInWindow(
            NetworkHistoryCard(model: model, services: services).padding(Tokens.Spacing.l), name: "network-history", size: CGSize(
                width: 900,
                height: 520
            )
        )
    }

    @Test("Data this month (D-235)")
    func dataBudget() async throws {
        let defaults = try #require(UserDefaults(suiteName: "budget-render-\(UUID().uuidString)"))
        let model = DataBudgetModel(defaults: defaults)
        model.set(DataBudget(allowance: 150e9, resetDay: 1))
        let services = AppServices(
            metrics: .preview(), history: SimulatedThirtyDayHistory(apps: SimulatedHistoryStore()), alertLog: SimulatedAlertStateStore(),
            alertSettings: .defaults, projects: SimulatedDevServers(), terminator: SimulatedDevServers()
        )
        await model.load(services.history)
        try await writeInWindow(
            DataBudgetCard(model: model, services: services).padding(Tokens.Spacing.l), name: "data-budget", size: CGSize(
                width: 820,
                height: 360
            )
        )
        model.set(nil)
        try await writeInWindow(
            DataBudgetCard(model: model, services: services).padding(Tokens.Spacing.l), name: "data-budget-unset", size: CGSize(
                width: 820,
                height: 220
            )
        )
    }

    @Test("Devices (D-237)")
    func devices() async throws {
        let services = AppServices.preview()
        await services.devices.load()
        await services.devices.loadMonth(services.history)
        try await writeInWindow(DevicesView(services: services), name: "devices", size: CGSize(width: 980, height: 720))
    }

    @Test("Alerts opens on what fired, by day, each with its rule's badge (D-238, D-239)")
    func alertsRecent() async throws {
        let services = AppServices.preview()
        for alert in SimulatedAlerts.recent() {
            try await services.alertLog.recordAlert(alert)
        }
        await services.reloadAlerts()
        try await writeInWindow(
            NavigationStack { AlertsView(services: services) },
            name: "alerts-recent",
            size: CGSize(width: 900, height: 620)
        )
    }

    @Test("Alerts' rules, grouped by what they watch (D-239)")
    func alertsRules() async throws {
        let services = AppServices.preview()
        services.navigation.alertsTab = .rules
        try await writeInWindow(
            NavigationStack { AlertsView(services: services) },
            name: "alerts-rules",
            size: CGSize(width: 900, height: 900)
        )
    }

    @Test("Alerts with nothing yet (D-239)")
    func alertsEmpty() async throws {
        let services = AppServices.preview()
        try await writeInWindow(
            NavigationStack { AlertsView(services: services) },
            name: "alerts-empty",
            size: CGSize(width: 900, height: 520)
        )
    }
}
