import AppKit
import Core
import Simulated
import SwiftUI
import Testing
@testable import UI

/// "Your next Mac" from made-up months of use, as the page and as the PDF (D-181). Renders into
/// `MACTIVITY_SNAPSHOT_DIR`.
@MainActor
@Suite("Next Mac renders", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] != nil))
struct NextMacRenderTests {
    init() {
        // Doubled strings with MACTIVITY_PSEUDO_LOCALIZATION=1: does a long language still fit the page?
        _ = PseudoLocalization.isOn
    }

    private static let gib = 1_073_741_824.0

    private var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] ?? "/tmp")
    }

    /// Quarter-hours over 30 days: weekdays follow `value`, weekends are quiet.
    static func series(noisy: Bool = true, _ value: @escaping (Int, Bool) -> Double) -> [SeriesPoint] {
        let calendar = Calendar.current
        // One start for every series, on a quarter-hour, so their points line up as History's do.
        let start = calendar.startOfDay(for: Date().addingTimeInterval(-30 * 86400))
        return (0 ..< 30 * 96).compactMap { index in
            let at = start.addingTimeInterval(Double(index) * 900)
            let hour = calendar.component(.hour, from: at)
            let weekend = calendar.isDateInWeekend(at)
            // Asleep at night: no points, as History has none.
            guard (7 ..< 24).contains(hour) else {
                return nil
            }
            let wobble = noisy ? Double((index * 7919) % 13) - 6 : 0
            let average = max(0, value(hour, weekend) + wobble)
            return SeriesPoint(at: at, average: average, maximum: average * 1.18)
        }
    }

    /// A developer's month: builds late morning and afternoon, a browser and Docker all day.
    static func developer(desktop: Bool = false, desk: Bool = false) -> NextMacReport {
        var inputs = UpgradeInputs(
            days: 30, installedMemory: UInt64(36 * gib), performanceCores: 14, diskCapacity: 1_000_000_000_000, hasBattery: !desktop
        )
        inputs.cpu = series { hour, weekend in weekend ? 12 : [10, 11, 14, 15].contains(hour) ? 82 : (9 ..< 18).contains(hour) ? 34 : 14 }
        inputs
            .memoryUsed = series { hour, weekend in (weekend ? 16 : (9 ..< 18).contains(hour) ? 29 : 21) * gib + Double(hour) * 0.05 * gib }
        inputs.memoryPressure = series { hour, weekend in !weekend && [11, 15].contains(hour) ? 66 : 32 }
        inputs.swap = series { hour, weekend in !weekend && [11, 15].contains(hour) ? 4 * gib : 0.5 * gib }
        inputs.gpu = series { hour, _ in (20 ..< 22).contains(hour) ? 48 : 14 }
        inputs.thermal = series { _, _ in 0 }
        inputs.onBattery = series(noisy: false) { hour, _ in (7 ..< 9).contains(hour) || (19 ..< 23).contains(hour) ? 1 : 0 }
        inputs.batteryLevel = series(noisy: false) { hour, _ in max(20, 100 - Double(hour - 7) * 6) }
        let first = Calendar.current.startOfDay(for: Date().addingTimeInterval(-29 * 86400))
        inputs.diskFree = (0 ..< 30).map { day in
            DayValue(day: first.addingTimeInterval(Double(day) * 86400), average: 290e9 - Double(day) * 0.9e9, maximum: 290e9)
        }
        inputs.cpuApps = ["Xcode"]
        inputs.memoryApps = ["Google Chrome"]
        inputs.gpuApps = ["WindowServer"]
        if desk {
            // A desk setup: two 4K displays, the lid closed, hardly ever on battery (D-237).
            inputs.onBattery = series(noisy: false) { _, _ in 0 }
            inputs.desk = DeskUsage(
                samples: 4000, dockedShare: 0.86, closedShare: 0.81, externalDisplays: 2, largestWidth: 3840, largestHeight: 2160
            )
        }
        return NextMacReport(
            advice: UpgradeAdvisor.advise(inputs), days: 30, start: Date().addingTimeInterval(-30 * 86400), end: Date(),
            macName: desktop ? "Mac mini" : "MacBook Pro", chip: "Apple M3 Pro", installedMemory: UInt64(36 * gib),
            diskCapacity: 1_000_000_000_000, cores: 14
        )
    }

    /// A student's month on a MacBook Air: notes, a browser, video in the evening, out all day.
    static func student() -> NextMacReport {
        var inputs = UpgradeInputs(
            days: 30, installedMemory: UInt64(16 * gib), performanceCores: 8, diskCapacity: 512_000_000_000, hasBattery: true
        )
        inputs.cpu = series { hour, _ in (9 ..< 17).contains(hour) ? 18 : (19 ..< 23).contains(hour) ? 24 : 8 }
        inputs.memoryUsed = series(noisy: false) { hour, _ in ((9 ..< 23).contains(hour) ? 9.5 : 7) * gib }
        inputs.memoryPressure = series { _, _ in 24 }
        inputs.gpu = series { hour, _ in (19 ..< 23).contains(hour) ? 22 : 6 }
        inputs.onBattery = series(noisy: false) { hour, _ in (8 ..< 16).contains(hour) ? 1 : 0 }
        inputs.batteryLevel = series(noisy: false) { hour, _ in (8 ..< 16).contains(hour) ? 100 - Double(hour - 8) * 9 : 100 }
        let first = Calendar.current.startOfDay(for: Date().addingTimeInterval(-29 * 86400))
        inputs.diskFree = (0 ..< 30).map { day in
            DayValue(day: first.addingTimeInterval(Double(day) * 86400), average: 210e9 - Double(day) * 0.2e9, maximum: 210e9)
        }
        inputs.cpuApps = ["Safari"]
        inputs.memoryApps = ["Safari"]
        inputs.gpuApps = ["TV"]
        return NextMacReport(
            advice: UpgradeAdvisor.advise(inputs), days: 30, start: Date().addingTimeInterval(-30 * 86400), end: Date(),
            macName: "MacBook Air", chip: "Apple M2", installedMemory: UInt64(16 * gib), diskCapacity: 512_000_000_000, cores: 8
        )
    }

    @Test("The page, from a student's month")
    func studentPage() throws {
        _ = NSApplication.shared
        let renderer = ImageRenderer(content: NextMacPage(report: Self.student()))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("next-mac-student.png"))
    }

    @Test("The sheet in the main window, from the simulated Mac's history")
    func sheet() async throws {
        _ = NSApplication.shared
        let services = AppServices.preview()
        let source = SimulatedSnapshotSource()
        for _ in 0 ..< 5 {
            await services.metrics.apply(source.next())
        }
        let size = CGSize(width: 700, height: 760)
        let hosting = NSHostingView(rootView: NextMacSheet(services: services, model: services.nextMac)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        for _ in 0 ..< 15 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("next-mac-sheet.png"))
        window.close()
    }

    @Test("The page, from a developer's month")
    func page() throws {
        _ = NSApplication.shared
        let renderer = ImageRenderer(content: NextMacPage(report: Self.developer()))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("next-mac-page.png"))
        let pdf = try #require(NextMacPDF.data(Self.developer()))
        try pdf.write(to: directory.appendingPathComponent("next-mac.pdf"))
    }

    @Test("The page on a desktop: a desktop recommended, no battery strip (D-187)")
    func desktopPage() throws {
        _ = NSApplication.shared
        let renderer = ImageRenderer(content: NextMacPage(report: Self.developer(desktop: true)))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("next-mac-desktop.png"))
    }

    @Test("The page for a laptop closed on a desk with two displays: a desktop, the laptop as the alternative (D-237)")
    func deskPage() throws {
        _ = NSApplication.shared
        let renderer = ImageRenderer(content: NextMacPage(report: Self.developer(desk: true)))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("next-mac-desk.png"))
    }
}
