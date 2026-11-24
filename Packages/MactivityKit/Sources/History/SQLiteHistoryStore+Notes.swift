import Core
import Foundation
import GRDB

/// Notes on history (D-253): a row each, never pruned by retention; Delete All History removes them.
extension SQLiteHistoryStore: NoteStore {
    public func saveNote(_ note: HistoryNote) throws {
        try database.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO note (id, t, text) VALUES (?, ?, ?)",
                arguments: [note.id.uuidString, Int64(note.at.timeIntervalSince1970), note.text]
            )
        }
    }

    public func deleteNote(id: UUID) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM note WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func notes(from: Date, to: Date) throws -> [HistoryNote] {
        try database.read { db in
            try Row.fetchAll(
                db, sql: "SELECT id, t, text FROM note WHERE t >= ? AND t < ? ORDER BY t",
                arguments: [Int64(from.timeIntervalSince1970), Int64(to.timeIntervalSince1970)]
            ).compactMap { row in
                guard let id = UUID(uuidString: row["id"]) else {
                    return nil
                }
                return HistoryNote(id: id, at: Date(timeIntervalSince1970: TimeInterval(row["t"] as Int64)), text: row["text"])
            }
        }
    }
}
