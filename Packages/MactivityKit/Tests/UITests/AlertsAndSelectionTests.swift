import Core
import Foundation
import Simulated
import Testing
@testable import UI

@MainActor
@Suite("Notifications off")
struct NotificationPermissionTests {
    @Test("The Alerts tab's notice follows the permission read, which starts as allowed")
    func refresh() async {
        let services = AppServices.preview()
        #expect(services.notificationPermission == .allowed)
        #expect(!services.notificationPermission.isOff)
        services.notificationPermissionSource = SimulatedNotificationPermission(.denied)
        await services.refreshNotificationPermission()
        #expect(services.notificationPermission == .denied)
        #expect(services.notificationPermission.isOff)
        services.notificationPermissionSource = SimulatedNotificationPermission(.notDetermined)
        await services.refreshNotificationPermission()
        #expect(services.notificationPermission.isOff)
        services.notificationPermissionSource = SimulatedNotificationPermission(.allowed)
        await services.refreshNotificationPermission()
        #expect(!services.notificationPermission.isOff)
    }

    @Test("Open Notification Settings opens Mactivity's page, or the pane without a bundle ID")
    func settingsURL() {
        let pane = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        #expect(NotificationSettings.url(bundleID: "app.mactivity.app")?.absoluteString == "\(pane)?id=app.mactivity.app")
        #expect(NotificationSettings.url(bundleID: nil)?.absoluteString == pane)
        #expect(NotificationSettings.url(bundleID: "")?.absoluteString == pane)
    }
}

@MainActor
@Suite("App list selection: the Process menu and toolbar")
struct AppListSelectionTests {
    private static let safari = AppIdentity(id: "com.apple.Safari", name: "Safari", bundleID: "com.apple.Safari", iconKey: "", kind: .app)

    private static func process(_ pid: Int32, app: AppIdentity.ID) -> ProcessSample {
        ProcessSample(
            pid: pid, app: app, name: "p\(pid)", cpuPercent: 1, footprintBytes: 1,
            diskReadBPS: 0, diskWriteBPS: 0, energyMW: nil, netInBPS: nil, netOutBPS: nil, gpuPercent: nil
        )
    }

    private static func snapshot() -> Snapshot {
        let apps = [safari, AppIdentity.system].map {
            AppAggregate(
                app: $0, processCount: 2, cpuPercent: 1, memoryBytes: 1, energyMW: nil,
                diskReadBPS: 0, diskWriteBPS: 0, netInBPS: nil, netOutBPS: nil, gpuPercent: nil
            )
        }
        let processes = [process(900, app: safari.id), process(412, app: safari.id), process(1, app: AppIdentity.system.id)]
        return Snapshot(
            at: Date(timeIntervalSince1970: 1_000_000), interval: .seconds(1), system: FigureFixture.system(),
            apps: apps, processes: processes
        )
    }

    @Test("macOS's rows can't be quit; Get Info and Show in Finder only where they mean something")
    func whatApplies() {
        let app = AppListSelection.app(Self.safari.id)
        #expect(app.canQuit && app.canGetInfo && app.canShowInFinder)
        let system = AppListSelection.app(AppIdentity.system.id)
        #expect(!system.canQuit && !system.canGetInfo && !system.canShowInFinder)
        let process = AppListSelection.process(pid: 412, app: Self.safari.id)
        #expect(process.canQuit && process.canGetInfo && !process.canShowInFinder)
        let systemProcess = AppListSelection.process(pid: 1, app: AppIdentity.system.id)
        #expect(!systemProcess.canQuit && systemProcess.canGetInfo)
    }

    @Test("Get Info on an app opens its oldest process")
    func infoPID() {
        let byApp = AppListData(Self.snapshot()).processesByApp
        #expect(AppListSelection.app(Self.safari.id).infoPID(in: byApp) == 412)
        #expect(AppListSelection.process(pid: 900, app: Self.safari.id).infoPID(in: byApp) == 900)
        #expect(AppListSelection.app("gone").infoPID(in: byApp) == nil)
    }

    @Test("Acts only on a metric tab, and a quit only asks, through ConfirmedAction")
    func actions() {
        let services = AppServices.preview()
        services.metrics.setVisible(true, surface: .mainWindow)
        services.metrics.apply(Self.snapshot())
        services.navigation.appListSelection = .app(Self.safari.id)
        services.navigation.selection = .overview
        #expect(services.actionableSelection == nil)
        services.quitSelection(mode: .quit)
        #expect(services.confirmedAction.pending == nil)

        services.navigation.selection = .cpu
        #expect(services.actionableSelection == .app(Self.safari.id))
        services.getInfoOnSelection()
        #expect(services.navigation.inspectedPID == 412)
        services.quitSelection(mode: .forceQuit)
        #expect(services.confirmedAction.pending?.mode == .forceQuit)
        services.confirmedAction.cancel()

        services.navigation.appListSelection = .app(AppIdentity.system.id)
        services.quitSelection(mode: .quit)
        #expect(services.confirmedAction.pending == nil)
        services.metrics.setVisible(false, surface: .mainWindow)
    }
}
