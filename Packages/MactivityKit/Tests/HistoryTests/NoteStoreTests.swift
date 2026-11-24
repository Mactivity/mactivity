import Core
import Foundation
@testable import History
import Testing

/// Notes on history (D-253).
struct NoteStoreTests {
    @Test("Saved, changed, read by span, deleted, and gone with Delete All History")
    func roundTrip() async throws {
        let store = try SQLiteHistoryStore(url: nil)
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let note = HistoryNote(at: at, text: "Installed the new driver")
        try await store.saveNote(note)
        try await store.saveNote(HistoryNote(at: at.addingTimeInterval(86400), text: "Next day"))
        #expect(try await store.notes(from: at, to: at.addingTimeInterval(3600)).map(\.text) == ["Installed the new driver"])
        try await store.saveNote(HistoryNote(id: note.id, at: at, text: "Installed the driver, then rolled back"))
        #expect(try await store.notes(from: at, to: at.addingTimeInterval(3600)).first?.text == "Installed the driver, then rolled back")
        try await store.deleteNote(id: note.id)
        #expect(try await store.notes(from: at, to: at.addingTimeInterval(3600)).isEmpty)
        try await store.deleteAll()
        #expect(try await store.notes(from: .distantPast, to: .distantFuture).isEmpty)
    }
}
