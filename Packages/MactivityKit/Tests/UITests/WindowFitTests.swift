import AppKit
import Core
import Simulated
import Storage
import SwiftUI
import Testing
@testable import UI

/// Every tab must fit the main window's minimum size. SwiftUI sizes the window's minimum by
/// measuring the content at zero size; a view that's tall there (a wrapped `Text` with
/// `.fixedSize(horizontal: false, vertical: true)`, a large `minHeight`) makes the page taller
/// than the window, and the split view pushes the page and the sidebar off screen. That was the
/// Storage tab's blank sidebar.
@MainActor
@Suite("Main window fits its minimum size")
struct WindowFitTests {
    init() {
        // Doubled strings under `make test-pseudo`; English otherwise.
        _ = PseudoLocalization.isOn
        // Bigger figures under `make test-larger` (D-276).
        _ = LargerFigures.isOn
    }

    /// Proof `make test-pseudo` lengthens what the tests below lay out.
    @Test("Pseudo-localization doubles localized strings", .enabled(if: PseudoLocalization.isOn))
    func pseudoLocalized() {
        #expect(SidebarItem.overview.title == "Overview Overview")
    }

    @Test("Minimum size of each tab, with live figures loaded", arguments: SidebarItem.allCases)
    func fits(_ item: SidebarItem) async {
        let services = AppServices.preview()
        // With real figures: an empty snapshot hid the CPU and Memory tabs' tall figure grids.
        await services.metrics.apply(SimulatedSnapshotSource().next())
        services.navigation.selection = item
        let controller = NSHostingController(rootView: MainWindowView(services: services, isSimulated: .constant(true)))
        let minimum = controller.sizeThatFits(in: .zero)
        let limit = Tokens.Layout.mainWindowMinimum
        #expect(minimum.width <= limit.width, "\(item.rawValue) needs \(minimum.width) pt of width")
        #expect(minimum.height <= limit.height, "\(item.rawValue) needs \(minimum.height) pt of height")
        // At real window sizes the page must fit too: a layout that switches to a taller
        // arrangement when narrow (the CPU and Memory tabs' figures) can overflow there even when
        // the zero-size measurement above is small.
        for size in [Tokens.Layout.mainWindowDefault, Tokens.Layout.mainWindowMinimum] {
            let fitted = controller.sizeThatFits(in: size)
            #expect(fitted.height <= size.height, "\(item.rawValue) is \(fitted.height) pt tall in a \(size) window")
        }
    }

    /// The real check for the sidebar bug (D-072): SwiftUI measures a real window differently from
    /// `sizeThatFits`. A page that needs more height grows the hosting window, and in the app,
    /// where the window can't grow, it pushes the page and the sidebar up under the title bar.
    @Test(
        "No tab makes a window grow, at the default, a short and the minimum size",
        arguments: SidebarItem.allCases,
        [Tokens.Layout.mainWindowDefault, CGSize(width: 1000, height: 640), Tokens.Layout.mainWindowMinimum]
    )
    func windowKeepsItsSize(_ item: SidebarItem, size: CGSize) async throws {
        _ = NSApplication.shared
        let services = AppServices.preview()
        let source = SimulatedSnapshotSource()
        for _ in 0 ..< 5 {
            await services.metrics.apply(source.next())
        }
        services.navigation.selection = item
        let hosting = NSHostingView(rootView: MainWindowView(services: services, isSimulated: .constant(true)))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        // Long enough for what loads after the first layout (Projects' servers and containers,
        // the Startup scan): 300 ms missed Projects growing the window to 843 pt (D-175).
        for _ in 0 ..< 12 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        let content = window.contentView?.frame.size ?? .zero
        window.close()
        #expect(content.height <= size.height, "\(item.rawValue) grew a \(size) window to \(content.height) pt tall")
        #expect(content.width <= size.width, "\(item.rawValue) grew a \(size) window to \(content.width) pt wide")
    }

    /// A scan's results (every view of them) and a rescan's progress row only show after a scan,
    /// so the checks above, which open Storage empty, never saw them: the map's minimum height
    /// overflowed any window under about 700 pt, and the page slid up under the toolbar.
    @Test(
        "Storage fits with a scan's results, during a rescan, in every view",
        arguments: StorageModel.Tab.allCases, [CGSize(width: 1000, height: 640), Tokens.Layout.mainWindowMinimum]
    )
    func storageWithResultsFits(_ tab: StorageModel.Tab, size: CGSize) async throws {
        _ = NSApplication.shared
        let services = AppServices.preview()
        services.navigation.selection = .storage
        services.storage.start(.home)
        for _ in 0 ..< 50 where services.storage.scan == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = try #require(services.storage.scan)
        services.storage.tab = tab
        let hosting = NSHostingView(rootView: MainWindowView(services: services, isSimulated: .constant(true)))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        func check(_ when: String) async throws {
            for _ in 0 ..< 10 {
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(60))
            }
            let content = window.contentView?.frame.size ?? .zero
            #expect(content.height <= size.height, "\(tab) \(when) in \(size): the window grew to \(content.height) pt tall")
            #expect(hosting.fittingSize.height <= size.height, "\(when): the page needs \(hosting.fittingSize.height) pt")
            #expect(content.width <= size.width, "\(tab) \(when) in \(size): the window grew to \(content.width) pt wide")
        }
        try await check("results")
        // A rescan keeps the old results under the progress row.
        services.storage.start(.home)
        try await check("rescanning")
    }

    /// Projects' views (D-223), each with its simulated figures loaded: Space's Docker card and
    /// list, the tables. None may grow the window or need more than it has.
    @Test(
        "Projects fits in every view",
        arguments: ProjectsTab.allCases, [CGSize(width: 1000, height: 640), Tokens.Layout.mainWindowMinimum]
    )
    func projectsFits(_ tab: ProjectsTab, size: CGSize) async throws {
        _ = NSApplication.shared
        let services = AppServices.preview()
        services.navigation.selection = .projects
        services.navigation.projectsTab = tab
        let hosting = NSHostingView(rootView: MainWindowView(services: services, isSimulated: .constant(true)))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0 ..< 20 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
        }
        let content = window.contentView?.frame.size ?? .zero
        #expect(content.height <= size.height, "\(tab) in \(size): the window grew to \(content.height) pt tall")
        #expect(hosting.fittingSize.height <= size.height, "\(tab): the page needs \(hosting.fittingSize.height) pt")
        #expect(content.width <= size.width, "\(tab) in \(size): the window grew to \(content.width) pt wide")
    }

    /// The Startup inspector opens when a row is selected. A minimum width on the table beside it
    /// made SwiftUI widen a default-size window by 118 pt, even with its maximum size pinned. The
    /// inspector slides in, so this waits for it rather than measuring the first layout.
    @Test("Opening the Startup inspector doesn't grow a default-size window")
    func startupInspectorFits() async throws {
        _ = NSApplication.shared
        let services = AppServices.preview()
        await services.startup.refresh()
        services.startup.selection = try #require(services.startup.items.first).id
        services.navigation.selection = .startup
        let size = Tokens.Layout.mainWindowDefault
        let hosting = NSHostingView(rootView: MainWindowView(services: services, isSimulated: .constant(true)))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        for _ in 0 ..< 25 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        let content = window.contentView?.frame.size ?? .zero
        window.close()
        #expect(content.width <= size.width, "the Startup inspector grew the window to \(content.width) pt wide")
        #expect(content.height <= size.height, "the Startup inspector grew the window to \(content.height) pt tall")
    }

    /// Real Macs have apps and processes with very long names ("com.apple.CoreSimulator.
    /// CoreSimulatorService"), which simulated data doesn't; a view that won't truncate them
    /// widens the page (and the window) instead.
    static func withLongNames(_ snapshot: Snapshot) -> Snapshot {
        let name = "com.apple.CoreSimulator.CoreSimulatorService.SomethingEvenLongerThanThat"
        let identity = AppIdentity(id: name, name: name, bundleID: name, iconKey: name, kind: .app)
        let process = ProcessSample(
            pid: 99999, app: identity.id, name: name, cpuPercent: 3, footprintBytes: 400_000_000,
            diskReadBPS: 1000, diskWriteBPS: 1000, energyMW: 10, netInBPS: 1000, netOutBPS: 1000, gpuPercent: 0
        )
        let app = AppAggregate(
            app: identity, processCount: 1, cpuPercent: 3, memoryBytes: 400_000_000, energyMW: 10,
            diskReadBPS: 1000, diskWriteBPS: 1000, netInBPS: 1000, netOutBPS: 1000, gpuPercent: 0, energyImpact: 1
        )
        return Snapshot(
            at: snapshot.at, interval: snapshot.interval, system: snapshot.system,
            apps: snapshot.apps + [app], processes: snapshot.processes + [process]
        )
    }

    /// The view behind the Storage bug: it only shows once the page has checked Full Disk Access,
    /// so the whole-window check above never sees it.
    @Test("The Full Disk Access explainer has a small minimum height")
    func explainerFits() {
        let model = StorageModel(scanner: SimulatedStorageScanner(fullDiskAccess: .denied))
        let controller = NSHostingController(rootView: FullDiskAccessExplainer(model: model))
        let minimum = controller.sizeThatFits(in: .zero)
        #expect(minimum.height <= 200, "explainer needs \(minimum.height) pt of height")
    }

    /// Space you can get back (D-121) only shows with real data, so the whole-window check never
    /// sees it either. Collapsed, it's one line; open, it must still leave the map some room.
    @Test("Space you can get back is one line collapsed, and fits open")
    func reclaimableFits() {
        let value = Reclaimable(
            messages: 6_200_000_000, backups: Reclaimable.Backups(bytes: 23_000_000_000, oldest: Date()),
            downloads: 12_100_000_000, mail: 480_000_000, developer: 6_400_000_000, trash: 14_000_000_000
        )
        let defaults = UserDefaults.standard
        defer { defaults.removeObject(forKey: PreferenceKey.reclaimableExpanded) }
        // Open, its smallest height (the list scrolling inside) still leaves the map room.
        for (open, limit) in [(false, 70.0), (true, 190.0)] {
            defaults.set(open, forKey: PreferenceKey.reclaimableExpanded)
            let card = ReclaimableCard(cleanups: StorageCleanups(measured: value))
                .frame(width: Tokens.Layout.mainWindowMinimum.width - 200)
            let height = NSHostingController(rootView: card).sizeThatFits(in: .zero).height
            #expect(height <= limit, "\(open ? "open" : "collapsed") card needs \(height) pt")
        }
    }
}
