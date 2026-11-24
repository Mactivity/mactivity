import Core
import Projects
import SwiftUI

/// The Open Files tab: every vnode descriptor, filterable, with Show in Finder and Copy Path.
struct InspectorFiles: View {
    let details: ProcessDetails

    @State private var query = ""
    @State private var selection: Set<Int32> = []

    var body: some View {
        if !details.isReadable {
            UnreadableNotice(details: details, what: .openFiles)
        } else {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                HStack(spacing: Tokens.Spacing.s) {
                    TextField(String(localized: "Filter", bundle: .strings), text: $query, prompt: Text("Filter by path", bundle: .strings))
                        .textFieldStyle(.roundedBorder)
                    Text(InspectorText.descriptorSummary(details))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
                Table(files, selection: $selection) {
                    TableColumn(Text("FD", bundle: .strings, comment: "Column: file descriptor number")) { file in
                        Text(String(file.fd))
                            .font(Tokens.Typography.code)
                            .foregroundStyle(.secondary)
                    }
                    .width(InspectorLayout.fdColumn)
                    TableColumn(Text("Mode", bundle: .strings, comment: "Column: read, write, or both")) { file in
                        Text(file.access.title)
                    }
                    .width(InspectorLayout.modeColumn)
                    TableColumn(Text("Path", bundle: .strings)) { file in
                        Text(InspectorText.abbreviated(file.path))
                            .font(Tokens.Typography.code)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(file.path)
                    }
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: Int32.self) { ids in
                    let paths = paths(for: ids)
                    Button(String(localized: "Show in Finder", bundle: .strings)) {
                        paths.filter(InspectorText.canReveal).forEach(InspectorText.reveal)
                    }
                    .disabled(!paths.contains(where: InspectorText.canReveal))
                    Button(
                        paths.count == 1
                            ? String(localized: "Copy Path", bundle: .strings)
                            : String(localized: "Copy Paths", bundle: .strings)
                    ) {
                        InspectorText.copy(paths.joined(separator: "\n"))
                    }
                    .disabled(paths.isEmpty)
                } primaryAction: { ids in
                    paths(for: ids).filter(InspectorText.canReveal).forEach(InspectorText.reveal)
                }
                .overlay {
                    if files.isEmpty {
                        ContentUnavailableView.search(
                            text: query.isEmpty
                                ? String(localized: "files", bundle: .strings, comment: "Shown as No Results for “files”")
                                : query
                        )
                    }
                }
            }
            .padding([.horizontal, .bottom], Tokens.Spacing.m)
        }
    }

    private var files: [ProcessDetails.OpenFile] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return details.openFiles
        }
        return details.openFiles.filter { $0.path.localizedCaseInsensitiveContains(trimmed) }
    }

    private func paths(for ids: Set<Int32>) -> [String] {
        details.openFiles.filter { ids.contains($0.fd) }.map(\.path)
    }
}

struct UnreadableNotice: View {
    /// What couldn't be read. One case per sentence, so each translates whole.
    enum What {
        case openFiles, sockets
    }

    let details: ProcessDetails
    let what: What

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "lock.fill")
        } description: {
            Text(detail)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch what {
        case .openFiles: String(localized: "Can't read open files", bundle: .strings)
        case .sockets: String(localized: "Can't read sockets", bundle: .strings)
        }
    }

    private var detail: String {
        switch what {
        case .openFiles: String(localized: "macOS shows another user's open files only to the privileged helper.", bundle: .strings)
        case .sockets: String(localized: "macOS shows another user's sockets only to the privileged helper.", bundle: .strings)
        }
    }
}
