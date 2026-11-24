import Core
import Foundation
import Testing
@testable import UI

@MainActor
@Suite("Hotspot sessions (D-136)")
struct HotspotModelTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A session starts when the connection turns expensive")
    func starts() {
        let model = HotspotModel()
        #expect(model.session == nil)
        model.update(isExpensive: true, isConstrained: false, now: start)
        #expect(model.session?.start == start)
    }

    @Test("A short drop (a sleep, the hotspot reconnecting) continues the session; a long one starts over")
    func reconnect() {
        let model = HotspotModel()
        model.update(isExpensive: true, isConstrained: false, now: start)
        model.update(isExpensive: false, isConstrained: false, now: start + 600)
        model.update(isExpensive: true, isConstrained: false, now: start + 900)
        #expect(model.session?.start == start)
        model.update(isExpensive: false, isConstrained: false, now: start + 1000)
        model.update(isExpensive: true, isConstrained: false, now: start + 1000 + 3600)
        #expect(model.session?.start == start + 1000 + 3600)
    }

    @Test("Off a hotspot nothing is recorded or handed to the alert check")
    func offHotspot() {
        let model = HotspotModel()
        #expect(model.takeRecent().isEmpty)
    }
}
