import AppKit
import Core
import Simulated
import SwiftUI
import Testing
@testable import UI

/// The Battery tab following the page's range (D-258), in the same suite and folder as the others.
extension NewFeaturesRenderTests {
    @Test("The Battery tab over 7 days: the whole Mac's watts and each app's (D-258)")
    func batteryRange() async throws {
        let servers = SimulatedDevServers()
        let metrics = LiveMetrics(source: SimulatedSnapshotSource(hasBattery: true), isSimulated: true)
        let apps = SimulatedHistoryStore()
        let services = AppServices(
            metrics: metrics, history: SimulatedThirtyDayHistory(apps: apps), alertLog: SimulatedAlertStateStore(),
            alertSettings: .defaults, projects: servers, terminator: servers
        )
        let source = SimulatedSnapshotSource(hasBattery: true)
        for _ in 0 ..< 3 {
            let snapshot = await source.next()
            await metrics.apply(snapshot)
            try await apps.record(snapshot)
        }
        let view = MetricDetailView(tab: .battery, services: services, range: .d7, search: "", batterySpan: .range)
        try await write(view, name: "battery-tab-7d", size: CGSize(width: 1100, height: 700))
    }
}
