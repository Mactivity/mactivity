import AppKit
import Core
import Simulated
import SwiftUI
import Testing
@testable import UI

@MainActor
@Suite("Share image")
struct StatusImageTests {
    /// Simulated services with a few ticks in hand, so the sparklines have bars.
    private func services() async -> AppServices {
        let services = AppServices.preview()
        let source = SimulatedSnapshotSource()
        for _ in 0 ..< 40 {
            await services.metrics.apply(source.next())
        }
        return services
    }

    @Test("Nothing to share before the first sample")
    func noSnapshot() {
        let services = AppServices(
            metrics: LiveMetrics(source: SimulatedSnapshotSource(), isSimulated: true),
            history: SimulatedHistoryStore(),
            alertLog: SimulatedAlertStateStore(),
            alertSettings: AlertSettings.decode(""),
            projects: SimulatedDevServers(),
            terminator: SimulatedDevServers()
        ) { _ in }
        #expect(services.statusImagePNG(colorScheme: .dark) == nil)
    }

    @Test("900 pt wide at @2x, as tall as its cards, in both appearances", arguments: [ColorScheme.light, .dark])
    func size(scheme: ColorScheme) async throws {
        let png = try #require(await services().statusImagePNG(colorScheme: scheme))
        let bitmap = try #require(NSBitmapImageRep(data: png))
        #expect(bitmap.pixelsWide == 1800)
        #expect(bitmap.pixelsHigh > 700 && bitmap.pixelsHigh < 1200)
        if let directory = ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] {
            try png
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("share-image-\(scheme == .dark ? "dark" : "light").png"))
        }
    }
}
