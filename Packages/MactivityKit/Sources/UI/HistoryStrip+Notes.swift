import Charts
import Core
import SwiftUI

/// The person's notes on History's charts (1.7, D-253): a thin line at the moment, with the
/// note's symbol on top and its words for VoiceOver and on hover.
extension HistoryStrip {
    static func notes(in store: any HistoryStore, from start: Date) async -> [HistoryNote] {
        await (try? (store as? any NoteStore)?.notes(from: start, to: Date())) ?? []
    }

    @ChartContentBuilder
    func noteMarks(_ notes: [HistoryNote]) -> some ChartContent {
        ForEach(notes) { note in
            RuleMark(x: .value(Self.noteAxis, note.at))
                .foregroundStyle(.purple.opacity(0.55))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, alignment: .center, spacing: 0) {
                    Image(systemName: "note.text")
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.purple)
                        .help(Text(verbatim: note.text))
                        .accessibilityLabel(Text(verbatim: note.text))
                }
        }
    }

    static let noteAxis = String(localized: "Note", bundle: .strings, comment: "Chart: the time of a note on history")
}
