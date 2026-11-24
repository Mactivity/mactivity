import Foundation
@testable import Sensors
import Testing

@Suite("SMC key cache (D-086)")
struct SensorKeyCacheTests {
    @Test("Groups round-trip for the same Mac model, macOS build and chip, and not for another")
    func roundTrip() throws {
        // One fixed name: a new name each run left an empty plist in ~/Library/Preferences every time.
        let suite = "app.mactivity.tests.sensor-key-cache"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = SensorKeyCache(defaults: defaults)
        let identity = SensorKeyCache.Identity(model: "Mac17,1", osBuild: "27A100", chip: "Apple M5 Pro")
        let groups = [SensorKeys.Group(id: "cpu", name: "CPU", keys: ["Tp01", "Tp05"])]
        #expect(cache.groups(for: identity) == nil)
        cache.store(groups, for: identity)
        #expect(cache.groups(for: identity) == groups)
        #expect(cache.groups(for: SensorKeyCache.Identity(model: "Mac17,1", osBuild: "27A101", chip: "Apple M5 Pro")) == nil)
        #expect(cache.groups(for: SensorKeyCache.Identity(model: "Mac17,2", osBuild: "27A100", chip: "Apple M5 Pro")) == nil)
        cache.store([], for: identity)
        #expect(cache.groups(for: identity) == [])
    }
}
