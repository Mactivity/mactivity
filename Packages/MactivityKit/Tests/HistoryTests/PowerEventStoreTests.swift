import Core
import Foundation
@testable import History
import Testing

@Suite("Sleep and wake store")
struct PowerEventStoreTests {
    @Test("Events come back oldest first, with their wake reasons")
    func roundTrip() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock, retentionDays: 365)
        try await store.recordPowerEvent(PowerEvent(at: Build.date(3600), kind: .wake, reason: "lid"))
        try await store.recordPowerEvent(PowerEvent(at: Build.date(0), kind: .sleep))
        clock.set(offset: 2 * hour)
        let events = try await store.powerEvents(days: 1)
        #expect(events.map(\.kind) == [.sleep, .wake])
        #expect(events.last?.reason == "lid")
    }
}
