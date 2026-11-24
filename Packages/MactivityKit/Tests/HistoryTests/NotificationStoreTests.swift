import Core
import Foundation
@testable import History
import Testing

/// Notifications by app (D-289).
struct NotificationStoreTests {
    @Test("Saved once however often it's read, found by span, and gone with Delete All History")
    func roundTrip() async throws {
        let store = try SQLiteHistoryStore(url: nil)
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let first = NotificationEvent(at: at, app: "com.apple.mail")
        let second = NotificationEvent(at: at.addingTimeInterval(600), app: "com.apple.MobileSMS")
        let late = NotificationEvent(at: at.addingTimeInterval(7200), app: "com.apple.mail")
        try await store.recordNotifications([first, second, late])
        // A read that overlaps the one before.
        try await store.recordNotifications([second, late])
        // The same moment from another app is another row.
        try await store.recordNotifications([NotificationEvent(at: at, app: "com.apple.iCal")])

        let read = try await store.notifications(from: at.addingTimeInterval(60), to: at.addingTimeInterval(3600))
        #expect(read == [second])
        #expect(try await store.notifications(from: at, to: at.addingTimeInterval(7201)).count == 4)
        #expect(try await store.notificationSpan() == at ... late.at)

        try await store.deleteAll()
        #expect(try await store.notifications(from: at, to: at.addingTimeInterval(7201)).isEmpty)
        #expect(try await store.notificationSpan() == nil)
    }

    @Test("Nothing recorded, nothing written, and no span")
    func empty() async throws {
        let store = try SQLiteHistoryStore(url: nil)
        try await store.recordNotifications([])
        #expect(try await store.notificationSpan() == nil)
    }
}
