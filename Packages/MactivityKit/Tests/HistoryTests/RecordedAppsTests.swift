import Core
import Foundation
@testable import History
import Testing

@Suite("Apps history has seen (D-282)")
struct RecordedAppsTests {
    @Test("Apps with a bundle ID, marked as apps or not; never one without")
    func recorded() async throws {
        let clock = TestClock(Build.date(600))
        let store = try SQLiteHistoryStore.inMemory(clock: clock)
        let tool = AppIdentity(id: "other:node", name: "node", bundleID: nil, iconKey: "node", kind: .other)
        let terminal = AppIdentity(id: "com.example.term", name: "Term", bundleID: "com.example.term", iconKey: "term", kind: .terminal)
        try await store.record(Build.snapshot(at: 0, apps: [
            Build.app("writer", cpu: 1), Build.app("node", cpu: 1, identity: tool), Build.app("term", cpu: 1, identity: terminal),
        ]))
        try await store.flush()
        let apps = try await store.recordedApps().sorted { $0.bundleID < $1.bundleID }
        #expect(apps == [
            RecordedApp(name: "Term", bundleID: "com.example.term", isApp: false),
            RecordedApp(name: "App writer", bundleID: "com.example.writer", isApp: true),
        ])
    }
}
