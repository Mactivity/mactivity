import Core
import Foundation
@testable import History
import Testing

@Suite("Time in front (D-098)")
struct FocusStoreTests {
    @Test("Totals per app, clipped to the span; active time adds every app")
    func totals() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock, retentionDays: 365)
        let xcode = Build.identity("xcode")
        let safari = Build.identity("safari")
        try await store.recordFocus(xcode, from: Build.date(0), to: Build.date(3600))
        try await store.recordFocus(safari, from: Build.date(3600), to: Build.date(5400))
        try await store.recordFocus(xcode, from: Build.date(5400), to: Build.date(7200))
        clock.set(offset: 3 * hour)

        let all = try await store.focusTotals(from: Build.date(0), to: Build.date(10000), limit: 5)
        #expect(all.map(\.app.id) == ["xcode", "safari"])
        #expect(all.first?.value == 5400)
        // From the half hour: Xcode's first stretch counts only its second half.
        let clipped = try await store.focusTotals(from: Build.date(1800), to: Build.date(10000), limit: 5)
        #expect(clipped.first?.value == 3600)
        #expect(try await store.activeSeconds(from: Build.date(0), to: Build.date(7200)) == 7200)
    }

    @Test("The first stretch recorded, for Your week's partial-week note (D-108)")
    func first() async throws {
        let store = try SQLiteHistoryStore.inMemory(clock: TestClock(), retentionDays: 365)
        #expect(try await store.firstFocus() == nil)
        try await store.recordFocus(Build.identity("safari"), from: Build.date(3600), to: Build.date(5400))
        try await store.recordFocus(Build.identity("xcode"), from: Build.date(600), to: Build.date(1200))
        #expect(try await store.firstFocus() == Build.date(600))
    }
}
