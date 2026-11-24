import Core
import CoreTransferable
import Export
import SwiftUI
import UniformTypeIdentifiers

/// Share (spec 5.9): the Overview's six headline cards as an image, sent through the Share menu,
/// copied, or saved to Downloads.
@MainActor
extension AppServices {
    /// The image as PNG, in `colorScheme`. Nil before the first sample: there's nothing to show.
    public func statusImagePNG(colorScheme: ColorScheme) -> Data? {
        guard metrics.snapshot != nil else {
            return nil
        }
        let view = StatusImageView(metrics: metrics, macModel: MacModel.name(), chip: MacModel.chip(), date: Date())
        return Customization.shared.atStandardSize {
            ImageExport.pngData(of: view, width: StatusImageView.width, colorScheme: colorScheme)
        }
    }

    /// Saves the image to Downloads, named like a screenshot, and shows it in Finder.
    public func saveStatusImage(colorScheme: ColorScheme) {
        guard let png = statusImagePNG(colorScheme: colorScheme) else {
            show(toast: String(localized: "Couldn't make the image.", bundle: .strings))
            return
        }
        do {
            let url = try ShareCard.save(png, at: Date())
            show(toast: String(localized: "Saved “\(url.lastPathComponent)” to Downloads.", bundle: .strings))
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            show(toast: String(localized: "Couldn't save the image to Downloads.", bundle: .strings))
        }
    }

    public func copyStatusImage(colorScheme: ColorScheme) {
        guard let png = statusImagePNG(colorScheme: colorScheme), ImageExport.copyToPasteboard(png) else {
            show(toast: String(localized: "Couldn't make the image.", bundle: .strings))
            return
        }
        show(toast: String(localized: "Image copied.", bundle: .strings))
    }

    /// For `ShareLink`: drawn when a destination is picked, not while the menu is open.
    public func statusImageItem(colorScheme: ColorScheme) -> StatusImageItem {
        StatusImageItem { [weak self] in
            self?.statusImagePNG(colorScheme: colorScheme)
        }
    }
}

/// The image as something to share. Renders on demand.
public struct StatusImageItem: Transferable {
    let render: @MainActor @Sendable () -> Data?

    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            guard let png = await item.render() else {
                throw CocoaError(.fileWriteUnknown)
            }
            return png
        }
        .suggestedFileName { _ in ShareCard.fileName(for: Date()) }
    }
}

/// Overview's headline cards, three by two, with a line saying what and when: the image Share makes.
struct StatusImageView: View {
    static let width = Tokens.Layout.statusImageWidth

    let metrics: LiveMetrics
    let macModel: String
    let chip: String
    let date: Date

    var body: some View {
        let tabs = MetricTab.allCases
        VStack(alignment: .leading, spacing: Tokens.Spacing.gridGutter) {
            Grid(horizontalSpacing: Tokens.Spacing.gridGutter, verticalSpacing: Tokens.Spacing.gridGutter) {
                ForEach(0 ..< (tabs.count + 2) / 3, id: \.self) { row in
                    GridRow(alignment: .top) {
                        ForEach(tabs[row * 3 ..< min(row * 3 + 3, tabs.count)]) { tab in
                            HeadlineCard(tab, metrics: metrics, compact: true)
                        }
                    }
                }
            }
            HStack(spacing: Tokens.Spacing.xs) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 22, height: 22)
                Text(verbatim: "Mactivity")
                    .font(Tokens.Typography.cardTitle)
                Text(verbatim: "\(macModel) · \(chip)")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(Tokens.Typography.secondary)
            .padding(.horizontal, Tokens.Spacing.xxs)
        }
        .padding(Tokens.Spacing.m)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Settings → History → Export History…: the CSV, written when the save panel is confirmed (D-093).
struct HistoryCSV: Transferable {
    let exporter: any HistoryExporting

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { item in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("csv")
            _ = try item.exporter.exportCSV(to: url)
            return SentTransferredFile(url)
        }
    }

    /// "Mactivity history 2026-09-28.csv".
    static func fileName(for date: Date) -> String {
        let day = Formatters.localDay(date)
        return String(
            localized: "Mactivity history \(day)",
            bundle: .strings,
            comment: "Exported history file name; the date is 2026-09-28"
        ) + ".csv"
    }
}
