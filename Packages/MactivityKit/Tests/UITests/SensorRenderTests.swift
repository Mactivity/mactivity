import AppKit
import Core
import Simulated
import SwiftUI
import Testing
@testable import UI

/// Camera and microphone on the Devices page (D-259), from the simulated week.
extension NewFeaturesRenderTests {
    @Test("Camera and microphone history")
    func sensorHistory() async throws {
        let services = AppServices.preview()
        let view = SensorHistoryCard(services: services)
            .padding(Tokens.Spacing.l)
        try await write(view, name: "sensor-history", size: CGSize(width: 760, height: 520))
    }
}
