import AppKit
import Core
import Simulated
import SwiftUI
import Testing
@testable import UI

/// Every page and the menu bar window with figures at their extremes: a hot, full, nearly flat Mac
/// with huge transfer rates, a long app name and six accessories (D-176). For text that grows past
/// its space, the way the Overview ring's total did. Renders into `MACTIVITY_SNAPSHOT_DIR`.
@MainActor
@Suite("Extreme figures render", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] != nil))
struct StressRenderTests {
    init() {
        _ = PseudoLocalization.isOn
    }

    private var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] ?? "/tmp")
    }

    static let longName = "Some Extremely Long Application Name Helper (Renderer)"

    /// A simulated snapshot pushed to the limits through its JSON, so no initializer is involved.
    static func extreme(_ snapshot: Snapshot) throws -> Snapshot {
        var root = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var system = try #require(root["system"] as? [String: Any])
        system["network"] = ["inBPS": 987_654_321.0, "outBPS": 456_789_012.0, "primaryInterface": "bridge100"]
        var cpu = try #require(system["cpu"] as? [String: Any])
        cpu["totalPercent"] = 100.0
        cpu["userPercent"] = 88.8
        cpu["systemPercent"] = 11.2
        cpu["loadAverage"] = ["one": 123.45, "five": 98.76, "fifteen": 87.65]
        system["cpu"] = cpu
        var disk = try #require(system["disk"] as? [String: Any])
        disk["readBPS"] = 3_456_789_012.0
        disk["writeBPS"] = 2_987_654_321.0
        disk["volumes"] = [
            ["id": "/", "name": "Macintosh HD", "freeBytes": 1_000_000_000, "totalBytes": 8_000_000_000_000],
            [
                "id": "/Volumes/Backups",
                "name": "Backups for the Whole Family (Time Machine)",
                "freeBytes": 12_345_678_901_234,
                "totalBytes": 16_000_000_000_000,
            ],
        ]
        system["disk"] = disk
        system["gpu"] = ["name": "Apple M5 Max", "utilizationPercent": 100.0, "memoryInUseBytes": 96_000_000_000]
        try extremePowerAndMemory(&system)
        system["uptime"] = [8_640_000, 0]
        root["system"] = system
        var apps = try #require(root["apps"] as? [[String: Any]])
        var first = apps[0]
        var identity = try #require(first["app"] as? [String: Any])
        identity["name"] = longName
        first["app"] = identity
        first["cpuPercent"] = 1234.5
        first["memoryBytes"] = 120_000_000_000
        first["energyMW"] = 25000.0
        first["energyImpact"] = 9999.0
        first["netInBPS"] = 500_000_000.0
        first["netOutBPS"] = 250_000_000.0
        first["diskReadBPS"] = 2_000_000_000.0
        first["diskWriteBPS"] = 1_500_000_000.0
        first["processCount"] = 1234
        apps[0] = first
        root["apps"] = apps
        return try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: root))
    }

    /// Heat, accessories, a nearly flat battery and memory all but full.
    private static func extremePowerAndMemory(_ system: inout [String: Any]) throws {
        system["thermal"] = "critical"
        system["sensors"] = [
            "temperatures": [["id": "cpu", "name": "CPU", "celsius": 109.4], ["id": "gpu", "name": "GPU", "celsius": 104.9]],
            "fans": [["id": 0, "rpm": 6543.0, "minRPM": 1200.0, "maxRPM": 6550.0]],
            "peripherals": [
                ["id": "a", "name": "Kade’s Magic Keyboard with Touch ID and Numeric Keypad", "kind": "keyboard", "percent": 3],
                ["id": "b", "name": "AirPods Pro", "kind": "airPods", "percent": 100],
                ["id": "c", "name": "Magic Trackpad", "kind": "trackpad", "percent": 45],
                ["id": "d", "name": "MX Master 3S for Mac", "kind": "mouse", "percent": 12],
                ["id": "e", "name": "AirPods Max", "kind": "airPods", "percent": 61],
                ["id": "f", "name": "Beats Studio Buds +", "kind": "airPods", "percent": 8],
            ],
        ]
        var battery = try #require(system["battery"] as? [String: Any])
        battery["percent"] = 3.0
        battery["powerDrawWatts"] = 140.5
        battery["cycleCount"] = 1234
        battery["maxCapacityPercent"] = 61.0
        battery["timeRemaining"] = [359_999, 0]
        system["battery"] = battery
        var memory = try #require(system["memory"] as? [String: Any])
        memory["totalBytes"] = 137_438_953_472
        memory["usedBytes"] = 136_000_000_000
        memory["appBytes"] = 90_000_000_000
        memory["wiredBytes"] = 20_000_000_000
        memory["compressedBytes"] = 26_000_000_000
        memory["cachedFilesBytes"] = 1_000_000_000
        memory["swapUsedBytes"] = 64_000_000_000
        memory["availableLevel"] = 2
        memory["pressure"] = "critical"
        system["memory"] = memory
    }

    private func services() async throws -> AppServices {
        let services = AppServices.preview()
        let source = SimulatedSnapshotSource()
        for _ in 0 ..< 30 {
            try await services.metrics.apply(Self.extreme(source.next()))
        }
        return services
    }

    @Test("Every page with extreme figures", arguments: [SidebarItem.overview, .cpu, .gpu, .memory, .disk, .network, .battery])
    func page(_ item: SidebarItem) async throws {
        _ = NSApplication.shared
        let services = try await services()
        services.navigation.selection = item
        let size = Tokens.Layout.mainWindowDefault
        let hosting = NSHostingView(rootView: MainWindowView(services: services, isSimulated: .constant(true)))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        try await settle(hosting)
        try write(hosting, name: "extreme-\(item.rawValue)")
        window.close()
    }

    @Test("Every menu bar window tab with extreme figures")
    func menuBarWindow() async throws {
        _ = NSApplication.shared
        let services = try await services()
        for tab in CompactTab.allCases {
            let view = MenuBarContent(services: services, isSimulated: .constant(true), mainWindowID: "main", tab: tab)
                .frame(width: Tokens.Layout.menuBarWindowWidth, height: 720, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = CGRect(x: 0, y: 0, width: Tokens.Layout.menuBarWindowWidth, height: 720)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = hosting
            try await settle(hosting)
            try write(hosting, name: "extreme-menubar-\(tab.rawValue)")
            window.close()
        }
    }

    /// A Mac without a battery (a Mac mini, Studio or iMac): Battery is Energy there.
    static func desktop(_ snapshot: Snapshot) throws -> Snapshot {
        var root = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var system = try #require(root["system"] as? [String: Any])
        system.removeValue(forKey: "battery")
        root["system"] = system
        return try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: root))
    }

    @Test("A desktop Mac: Energy, Overview and the menu bar window")
    func desktopMac() async throws {
        _ = NSApplication.shared
        let services = AppServices.preview()
        let source = SimulatedSnapshotSource()
        // A source that never has a battery: once one is seen, a Mac keeps its Battery tab.
        services.metrics.replaceSource(DesktopSource(), isSimulated: true)
        for _ in 0 ..< 30 {
            try await services.metrics.apply(Self.desktop(source.next()))
        }
        for (item, size) in [
            (SidebarItem.battery, Tokens.Layout.mainWindowDefault),
            (.battery, Tokens.Layout.mainWindowMinimum),
            (.overview, Tokens.Layout.mainWindowDefault),
        ] {
            services.navigation.selection = item
            let hosting = NSHostingView(rootView: MainWindowView(services: services, isSimulated: .constant(true)))
            let window = NSWindow(
                contentRect: CGRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = hosting
            try await settle(hosting)
            try write(hosting, name: "desktop-\(item.rawValue)-\(Int(size.width))")
            window.close()
        }
        for tab in [CompactTab.overview, .battery] {
            let view = MenuBarContent(services: services, isSimulated: .constant(true), mainWindowID: "main", tab: tab)
                .frame(width: Tokens.Layout.menuBarWindowWidth, height: 720, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = CGRect(x: 0, y: 0, width: Tokens.Layout.menuBarWindowWidth, height: 720)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = hosting
            try await settle(hosting)
            try write(hosting, name: "desktop-menubar-\(tab.rawValue)")
            window.close()
        }
    }

    private func settle(_ hosting: NSView) async throws {
        for _ in 0 ..< 6 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func write(_ hosting: NSView, name: String) throws {
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }
}

/// Simulated snapshots without a battery.
private struct DesktopSource: SnapshotSource {
    func snapshots() async -> AsyncStream<Snapshot> {
        AsyncStream { _ in }
    }

    func setCadence(_: SamplingCadence) async {}
    func setSensorDemand(_: Bool) async {}
    func setSystemDetail(_: Bool) async {}
}
