import Core
import Storage
import SwiftUI

/// Storage's What grew (D-208): one line under the summary, the folders that grew most since the
/// last scan of the same place. Each opens on the map.
struct FolderGrowthLine: View {
    let since: Date
    let folders: [FolderGrowth]
    let show: (FolderGrowth) -> Void

    var body: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .foregroundStyle(folders.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Tokens.Colors.strain))
                .accessibilityHidden(true)
            let date = since.formatted(date: .abbreviated, time: .omitted)
            if folders.isEmpty {
                Text("Nothing grew by more than half a gigabyte since the last scan, on \(date).", bundle: .strings)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Grew since \(date):", bundle: .strings, comment: "Storage: folders that grew since the last scan, on a date")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                // Three at most, their names shortening in a narrow window rather than the line
                // choosing a layout by its content (D-174).
                ForEach(folders.prefix(3)) { folder in
                    Button {
                        show(folder)
                    } label: {
                        Text(verbatim: "\(folder.name) +\(Formatters.bytes(folder.grew))")
                            .monospacedDigit()
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.link)
                    .help(Text(verbatim: folder.path))
                }
            }
            Spacer(minLength: 0)
        }
        .font(Tokens.Typography.secondary)
    }
}
