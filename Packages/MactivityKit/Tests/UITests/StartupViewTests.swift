import AppKit
import Core
import Startup
import SwiftUI
import Testing
@testable import UI

/// Renders the Startup tab with simulated data, light and dark, for docs/screenshots/E4.
/// Runs only when `MACTIVITY_SNAPSHOT_DIR` is set:
/// `MACTIVITY_SNAPSHOT_DIR=$PWD/docs/screenshots/E4 swift test --filter StartupRenderTests` from the package.
///
/// `Table` is AppKit underneath, which `ImageRenderer` can't draw, so this hosts the view in an
/// offscreen window and caches its display instead.
@MainActor
@Suite("Startup renders", .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] != nil))
struct StartupRenderTests {
    private var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] ?? "/tmp")
    }

    /// The main window's detail area at the default window size, minus the sidebar.
    private let size = CGSize(width: Tokens.Layout.mainWindowDefault.width - Tokens.Layout.sidebarWidth, height: 680)

    private func model(selecting label: String?) async -> StartupModel {
        let model = StartupModel.preview()
        await model.refresh()
        model.selection = model.items.first { $0.label == label }?.id
        return model
    }

    private func write(_ model: StartupModel, name: String, report: StartupReport? = nil) throws {
        for dark in [false, true] {
            let view = StartupView(model: model, services: nil, report: report)
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingView(rootView: view)
            hosting.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = hosting
            window.orderBack(nil)
            for _ in 0 ..< 6 {
                hosting.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            let rep = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ))
            rep.size = size
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            window.orderOut(nil)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        }
    }

    @Test("After the last startup (D-171)")
    func afterStartup() async throws {
        let login = Calendar.current.date(bySettingHour: 9, minute: 2, second: 0, of: Date()) ?? Date()
        func app(_ name: String, _ id: String) -> AppIdentity {
            AppIdentity(id: id, name: name, bundleID: id, iconKey: "other", kind: .app)
        }
        let report = StartupReport(
            cost: StartupCost(bootedAt: login.addingTimeInterval(-40), loginAt: login, settledAfter: 6 * 60, averageCPU: 41),
            apps: [
                AppTotal(app: app("Adobe Creative Cloud", "com.adobe.acc.AdobeCreativeCloud"), value: 84),
                AppTotal(app: app("Dropbox", "com.getdropbox.dropbox"), value: 52),
                AppTotal(app: app("Spotlight", "com.apple.Spotlight"), value: 31),
            ]
        )
        try await write(model(selecting: nil), name: "startup-after-login", report: report)
    }

    @Test("Startup tab with an unusual user agent selected")
    func selectedAgent() async throws {
        try await write(model(selecting: "com.google.GoogleUpdater.wake"), name: "startup")
    }

    @Test("Startup tab with a broken agent selected")
    func selectedBroken() async throws {
        try await write(model(selecting: "com.google.keystone.agent"), name: "startup-broken")
    }

    @Test("Startup tab with a system daemon selected")
    func selectedDaemon() async throws {
        try await write(model(selecting: "com.docker.vmnetd"), name: "startup-daemon")
    }

    @Test("Startup tab after disabling a user agent")
    func disabled() async throws {
        let model = await model(selecting: "com.google.GoogleUpdater.wake")
        let item = try #require(model.selectedItem)
        model.askToDisable(item)
        await model.confirmDisable()
        // The toast is glass, which an offscreen window doesn't draw.
        model.dismissToast()
        try write(model, name: "startup-disabled")
    }

    @Test("Startup tab with nothing selected")
    func nothingSelected() async throws {
        try await write(model(selecting: nil), name: "startup-no-selection")
    }
}

/// The Startup model's one change goes through the confirmation first.
@MainActor
@Suite("Startup model")
struct StartupModelTests {
    @Test("Disable waits for confirmation, then Enable puts it back")
    func disableFlow() async throws {
        let model = StartupModel.preview()
        await model.refresh()
        #expect(model.summary.starting == 13)
        let agent = try #require(model.items.first { $0.label == "com.google.GoogleUpdater.wake" })

        model.askToDisable(agent)
        #expect(model.pendingDisable == agent)
        await model.refresh()
        #expect(model.items.first { $0.label == agent.label }?.state == .on, "nothing moves before the confirm")

        await model.confirmDisable()
        #expect(model.pendingDisable == nil)
        let disabled = try #require(model.items.first { $0.label == agent.label })
        #expect(disabled.state == .disabledByMactivity)
        #expect(model.selection == disabled.id)
        #expect(model.summary.starting == 12)
        #expect(model.toast?.contains("next login") == true)

        await model.enable(disabled)
        #expect(model.items.first { $0.label == agent.label }?.state == .on)
        #expect(model.summary.starting == 13)
    }

    @Test("Items outside ~/Library/LaunchAgents never get a Disable confirmation")
    func onlyUserAgents() async throws {
        let model = StartupModel.preview()
        await model.refresh()
        let daemon = try #require(model.items.first { $0.kind == .daemon })
        model.askToDisable(daemon)
        #expect(model.pendingDisable == nil)
    }

    @Test("Cancel leaves everything where it was")
    func cancel() async throws {
        let model = StartupModel.preview()
        await model.refresh()
        let agent = try #require(model.items.first { $0.canDisable })
        model.askToDisable(agent)
        model.pendingDisable = nil
        await model.confirmDisable()
        #expect(model.items.first { $0.id == agent.id }?.state == agent.state)
    }
}

/// Counts scans, so a test can tell whether setting the source started one.
private actor CountingStartupSource: StartupSource, StartupItemToggling {
    private(set) var scans = 0

    func items() async throws -> [StartupItem] {
        scans += 1
        return []
    }

    func macOSItemCount() async throws -> Int {
        0
    }

    func disable(_: StartupItem) async throws {}
    func enable(_: StartupItem) async throws {}
}

@MainActor
struct StartupModelLaunchTests {
    @Test("Setting the real source at launch doesn't scan; once the tab has loaded, it rescans")
    func lazyScan() async throws {
        let model = StartupModel.preview()
        let launch = CountingStartupSource()
        model.replace(source: launch, toggle: launch)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await launch.scans == 0)

        await model.refresh()
        #expect(await launch.scans == 1)
        let swapped = CountingStartupSource()
        model.replace(source: swapped, toggle: swapped)
        for _ in 0 ..< 50 where await swapped.scans == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await swapped.scans == 1)
    }
}
