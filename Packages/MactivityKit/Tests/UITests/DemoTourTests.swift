import Core
import Foundation
import Simulated
import Testing
@testable import UI

@Suite("Demo tour")
struct DemoTourTests {
    @Test("The demo's busy moment shows the diagnosis at work: processor, Xcode, memory, Spotlight")
    func busyMoment() async {
        let base = await SimulatedSnapshotSource().next()
        let kinds = Slowdown.diagnose(DemoTour.busyMoment(base), lowPowerMode: false).map(\.kind)
        #expect(kinds.contains(.busyCPU))
        #expect(kinds.contains(.busyApp))
        #expect(kinds.contains(.memory))
        #expect(kinds.contains(.spotlight))
    }
}
