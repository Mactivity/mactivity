import Core
import Foundation
@testable import History
import Testing

/// App launch times in SQLite (D-215).
struct AppLaunchStoreTests {
    @Test("Launches read back by span; deleting history deletes them")
    func roundTrip() async throws {
        let store = try SQLiteHistoryStore(url: nil)
        let at = Date(timeIntervalSince1970: 1_790_000_000.25)
        let launch = AppLaunch(at: at, appID: "com.apple.dt.Xcode", name: "Xcode", seconds: 3.4)
        try await store.recordLaunch(launch)
        #expect(try await store.launches(from: at - 1, to: at + 1) == [launch])
        try await store.deleteAll()
        #expect(try await store.launches(from: at - 1, to: at + 1).isEmpty)
    }
}
