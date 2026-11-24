import Core
import Foundation

extension SimulatedHistoryStore: NoteStore {
    public func saveNote(_ note: HistoryNote) async throws {
        var notes = current()
        notes[note.id] = note
        savedNotes = notes
    }

    public func deleteNote(id: UUID) async throws {
        var notes = current()
        notes[id] = nil
        savedNotes = notes
    }

    public func notes(from: Date, to: Date) async throws -> [HistoryNote] {
        current().values.filter { $0.at >= from && $0.at < to }.sorted { $0.at < $1.at }
    }

    /// The saved notes; at first, yesterday afternoon's and this morning's.
    private func current() -> [UUID: HistoryNote] {
        if let savedNotes {
            return savedNotes
        }
        let today = Calendar.current.startOfDay(for: Date())
        let seeded = [
            HistoryNote(at: today.addingTimeInterval(-86400 + 15 * 3600), text: "Updated Xcode"),
            HistoryNote(at: today.addingTimeInterval(9.5 * 3600), text: "New dock on the desk"),
        ]
        let notes = Dictionary(uniqueKeysWithValues: seeded.map { ($0.id, $0) })
        savedNotes = notes
        return notes
    }
}
