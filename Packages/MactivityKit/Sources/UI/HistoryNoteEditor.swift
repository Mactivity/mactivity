import Core
import SwiftUI

/// Adding or changing a note on history (1.7, D-253): a line of text at a time on one day.
struct NoteDraft: Identifiable {
    let id = UUID()
    /// The note being changed; nil for a new one.
    let note: HistoryNote?
    let day: Date

    /// A new note's time: now on today, midday on another day.
    var startTime: Date {
        if let note {
            return note.at
        }
        let calendar = Calendar.current
        return calendar.isDateInToday(day) ? Date() : calendar.startOfDay(for: day).addingTimeInterval(12 * 3600)
    }
}

struct HistoryNoteEditor: View {
    let draft: NoteDraft
    let save: (HistoryNote) -> Void
    let delete: (HistoryNote) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var time = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            Text(
                draft.note == nil
                    ? String(localized: "Add a Note", bundle: .strings, comment: "History note editor title")
                    : String(localized: "Edit Note", bundle: .strings, comment: "History note editor title")
            )
            .font(Tokens.Typography.headline)
            Form {
                TextField(
                    String(localized: "Note", bundle: .strings, comment: "History note: the text field"),
                    text: $text,
                    prompt: Text("Installed the new driver", bundle: .strings, comment: "History note: an example")
                )
                DatePicker(
                    String(localized: "Time", bundle: .strings, comment: "History note: when it happened"),
                    selection: $time,
                    in: dayRange,
                    displayedComponents: .hourAndMinute
                )
            }
            .formStyle(.grouped)
            Text("Notes show on Your day and on History's charts. They stay on this Mac until you delete them.", bundle: .strings)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let note = draft.note {
                    Button(String(localized: "Delete Note", bundle: .strings), role: .destructive) {
                        delete(note)
                        dismiss()
                    }
                }
                Spacer()
                Button(String(localized: "Cancel", bundle: .strings), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Save", bundle: .strings)) {
                    save(HistoryNote(id: draft.note?.id ?? UUID(), at: time, text: text))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(HistoryNote.tidy(text).isEmpty)
            }
        }
        .padding(Tokens.Spacing.l)
        .frame(width: 420)
        .onAppear {
            text = draft.note?.text ?? ""
            time = draft.startTime
        }
    }

    /// The day the note is on: its time can move within the day, not to another.
    private var dayRange: ClosedRange<Date> {
        let start = Calendar.current.startOfDay(for: draft.day)
        return start ... start.addingTimeInterval(86400 - 60)
    }
}
