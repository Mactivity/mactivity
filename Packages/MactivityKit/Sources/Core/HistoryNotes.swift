import Foundation

/// A note pinned to a moment in history (1.7, D-253): "Installed the new driver". Shown on Your
/// day and on History's charts. The person's own words, so they're kept until deleted, whatever
/// the history retention, and leave the Mac only in an export the person makes.
public struct HistoryNote: Hashable, Sendable, Identifiable, Codable {
    /// Longer than this is cut: a note marks a moment, it isn't a journal.
    public static let longest = 280

    public let id: UUID
    public let at: Date
    public let text: String

    public init(id: UUID = UUID(), at: Date, text: String) {
        self.id = id
        self.at = at
        self.text = Self.tidy(text)
    }

    /// Pure: one line, trimmed, at most `longest` characters.
    public static func tidy(_ text: String) -> String {
        let oneLine = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return String(oneLine.trimmingCharacters(in: .whitespaces).prefix(longest))
    }
}

/// Notes in History (D-253).
public protocol NoteStore: Sendable {
    /// Adds the note, or replaces the one with its ID.
    func saveNote(_ note: HistoryNote) async throws
    func deleteNote(id: UUID) async throws
    /// Notes in the span, oldest first.
    func notes(from: Date, to: Date) async throws -> [HistoryNote]
}
