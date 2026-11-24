import Core
import SwiftUI
import UniformTypeIdentifiers

/// Settings → History: how long to keep it, what to record, its size, export, delete.
struct HistorySettings: View {
    let services: AppServices

    @AppStorage(PreferenceKey.historyRetentionDays) private var retentionDays = HistoryRetention.defaultDays
    @State private var sizeBytes: UInt64 = 0
    @State private var confirmsDelete = false
    @State private var exporting = false
    @AppStorage(PreferenceKey.recordsTimeInFront) private var recordsTimeInFront = true
    /// A shorter period waits here until confirmed: it deletes what's older (D-197).
    @State private var pendingRetention: Int?
    /// Settings shows no toasts: an export's outcome is an alert here.
    @State private var exportMessage: String?

    /// Longer applies at once; shorter asks first.
    private var retentionSelection: Binding<Int> {
        Binding {
            retentionDays
        } set: { days in
            if days < retentionDays {
                pendingRetention = days
            } else {
                retentionDays = days
            }
        }
    }

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Keep history for", bundle: .strings), selection: retentionSelection) {
                    ForEach(HistoryRetention.choices, id: \.self) { days in
                        if days == 365 {
                            Text("1 year", bundle: .strings, comment: "Keep history for: one year").tag(days)
                        } else {
                            Text("\(days) days", bundle: .strings).tag(days)
                        }
                    }
                }
                Toggle(String(localized: "Record which app is in front", bundle: .strings), isOn: $recordsTimeInFront)
            } footer: {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    Text(
                        """
                        Detail by the minute for 48 hours, by the quarter-hour for 30 days, then by the hour. \
                        A year takes about 40 to 60 MB.
                        """,
                        bundle: .strings
                    )
                    // What goes quiet without it (D-197).
                    Text(
                        "Which app is in front gives time in use, Time in front and apps open but unused; off, those stay empty.",
                        bundle: .strings
                    )
                }
                .foregroundStyle(.secondary)
            }
            .confirmationDialog(
                String(localized: "Delete history older than \(pendingRetention ?? retentionDays) days?", bundle: .strings),
                isPresented: Binding { pendingRetention != nil } set: {
                    if !$0 {
                        pendingRetention = nil
                    }
                }
            ) {
                Button(
                    String(localized: "Keep Less History", bundle: .strings, comment: "Confirms a shorter history period"),
                    role: .destructive
                ) {
                    if let days = pendingRetention {
                        retentionDays = days
                    }
                    pendingRetention = nil
                }
            } message: {
                Text("What's older is removed for good the next time Mactivity records. Live figures keep working.", bundle: .strings)
            }
            Section {
                LabeledContent(String(localized: "Database size", bundle: .strings), value: Formatters.bytes(sizeBytes))
                LabeledContent(String(localized: "Location", bundle: .strings, comment: "Where the history database is on disk")) {
                    Text(verbatim: "~/Library/Application Support/Mactivity")
                        .font(Tokens.Typography.code)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let exporter = services.history as? any HistoryExporting {
                    Button(String(localized: "Export History…", bundle: .strings)) { exporting = true }
                        .help(Text("Every hour kept, for every app, as a CSV file for a spreadsheet", bundle: .strings))
                        .fileExporter(
                            isPresented: $exporting,
                            item: HistoryCSV(exporter: exporter),
                            contentTypes: [.commaSeparatedText],
                            defaultFilename: HistoryCSV.fileName(for: Date())
                        ) { result in
                            switch result {
                            case let .success(url):
                                // Finder shows where it went.
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            case .failure:
                                exportMessage = String(localized: "Couldn't export the history.", bundle: .strings)
                            }
                        }
                }
                Button(String(localized: "Delete History…", bundle: .strings), role: .destructive) {
                    confirmsDelete = true
                }
                .confirmationDialog(String(localized: "Delete all history?", bundle: .strings), isPresented: $confirmsDelete) {
                    Button(String(localized: "Delete History", bundle: .strings), role: .destructive) {
                        Task {
                            try? await services.history.deleteAll()
                            services.historyDidChange()
                            await refreshSize()
                        }
                    }
                } message: {
                    Text("Every recorded minute and alert is removed. Live figures keep working.", bundle: .strings)
                }
            }
        }
        .formStyle(.grouped)
        .alert(exportMessage ?? "", isPresented: Binding { exportMessage != nil } set: {
            if !$0 {
                exportMessage = nil
            }
        }) {}
        .task(id: services.historyGeneration) {
            await refreshSize()
        }
        .onChange(of: retentionDays) { _, days in
            Task { await services.history.setRetention(days: days) }
        }
    }

    private func refreshSize() async {
        sizeBytes = await services.history.storageSizeBytes()
    }
}
