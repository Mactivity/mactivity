import Core
import Docker
import Foundation
import Observation
import Projects
import Simulated
import Storage

extension AppServices {
    /// Simulated everything, already sampling. For SwiftUI previews.
    public static func preview() -> AppServices {
        let servers = SimulatedDevServers()
        return AppServices(
            metrics: .preview(),
            history: SimulatedHistoryStore(),
            alertLog: SimulatedAlertStateStore(),
            alertSettings: .defaults,
            projects: servers,
            terminator: servers
        )
    }
}
