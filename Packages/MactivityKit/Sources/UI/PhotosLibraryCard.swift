import AppKit
import Core
import Observation
import Storage
import SwiftUI

/// What the Photos library takes, for the Storage page (D-283). Walking a large library takes
/// seconds, so a measurement is kept an hour, here rather than in the view.
@MainActor
@Observable
public final class PhotosLibraryModel {
    private(set) var reports: [PhotosLibraryReport]?
    @ObservationIgnored private var source: any PhotosLibrarySource
    @ObservationIgnored private var measuredAt: Date?
    @ObservationIgnored private var isLoading = false

    static let lifetime: TimeInterval = 3600

    public init(source: any PhotosLibrarySource) {
        self.source = source
    }

    public func replaceSource(_ source: any PhotosLibrarySource) {
        self.source = source
        reports = nil
        measuredAt = nil
    }

    func refresh(now: Date = Date()) async {
        if isLoading || measuredAt.map({ now.timeIntervalSince($0) < Self.lifetime && now >= $0 }) == true {
            return
        }
        isLoading = true
        defer { isLoading = false }
        reports = await source.libraries()
        measuredAt = now
    }

    /// The person asked, or has just turned on access.
    func measure(_ path: String) async {
        let report = await source.measure(path: path)
        reports = reports?.map { $0.path == path ? report : $0 }
    }
}

/// One line, "Photos library: 106 GB on this Mac", opening to what's in it. Nothing shows without
/// a library: the card's about one, and the map below needs the room in a small window (D-121).
struct PhotosLibraryCard: View {
    let model: PhotosLibraryModel
    @AppStorage(PreferenceKey.photosLibraryExpanded) private var expanded = false

    var body: some View {
        Group {
            if let reports = model.reports, !reports.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                        ForEach(reports) { report in
                            PhotosLibraryDetails(report: report, showsName: reports.count > 1) {
                                Task { await model.measure(report.path) }
                            }
                        }
                        Text(
                            """
                            Sizes of what's on this Mac, from the library's folders. What iCloud keeps only online isn't shown: \
                            that figure is only in Photos' private database, which Mactivity doesn't read. With Optimize Mac \
                            Storage on, originals here are just the ones downloaded.
                            """,
                            bundle: .strings
                        )
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, Tokens.Spacing.xs)
                } label: {
                    Text(Self.summary(reports))
                        .font(Tokens.Typography.cardTitle)
                        .monospacedDigit()
                }
                .cardStyle()
            }
        }
        .task { await model.refresh() }
    }

    /// "Photos library: 106 GB on this Mac", the total of what could be measured.
    nonisolated static func summary(_ reports: [PhotosLibraryReport]) -> String {
        let measured = reports.compactMap { report -> UInt64? in
            if case let .measured(parts) = report.state {
                return parts.total
            }
            return nil
        }
        guard !measured.isEmpty else {
            return reports.contains { $0.state == .noAccess }
                ? String(localized: "Photos library: Mactivity needs Full Disk Access to measure it", bundle: .strings)
                : String(localized: "Photos library: on another drive, not measured yet", bundle: .strings)
        }
        let size = Formatters.bytes(measured.reduce(0, +))
        return String(
            localized: "Photos library: \(size) on this Mac",
            bundle: .strings,
            comment: "Storage page: what the Photos library takes"
        )
    }

    struct Row: Hashable {
        let title: String
        let help: String
        let bytes: UInt64
    }

    /// Pure: largest first, and only what's there.
    nonisolated static func rows(_ parts: PhotosLibraryParts) -> [Row] {
        [
            Row(
                title: String(localized: "Originals", bundle: .strings, comment: "Photos library: the original photos and videos"),
                help: String(localized: "The photos and videos as they were taken or imported, those on this Mac.", bundle: .strings),
                bytes: parts.originals
            ),
            Row(
                title: String(localized: "Edits", bundle: .strings, comment: "Photos library: edited versions"),
                help: String(localized: "The edited versions Photos has saved of what you've changed.", bundle: .strings),
                bytes: parts.edits
            ),
            Row(
                title: String(localized: "Thumbnails and previews", bundle: .strings),
                help: String(localized: "Smaller copies Photos makes itself and can make again.", bundle: .strings),
                bytes: parts.thumbnails
            ),
            Row(
                title: String(localized: "Shared albums", bundle: .strings),
                help: String(localized: "The folder Photos keeps shared albums in, as far as they're on this Mac.", bundle: .strings),
                bytes: parts.sharedAlbums
            ),
            Row(
                title: String(localized: "Database", bundle: .strings, comment: "Photos library: its database folder"),
                help: String(localized: "What Photos knows about your library: albums, faces, places, searches.", bundle: .strings),
                bytes: parts.database
            ),
            Row(
                title: String(localized: "Everything else", bundle: .strings),
                help: String(localized: "The rest of the library's folders: caches, analysis and sync records.", bundle: .strings),
                bytes: parts.other
            ),
        ]
        .filter { $0.bytes > 0 }
        .sorted { $0.bytes > $1.bytes }
    }
}

private struct PhotosLibraryDetails: View {
    let report: PhotosLibraryReport
    let showsName: Bool
    let measure: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
            if showsName || report.state == .notMeasured {
                Text(report.name)
                    .fontWeight(.medium)
                    .help(Text(verbatim: Formatters.displayPath(report.path, home: NSHomeDirectory())))
            }
            switch report.state {
            case let .measured(parts):
                let rows = PhotosLibraryCard.rows(parts)
                if rows.isEmpty {
                    Text("This library is empty.", bundle: .strings)
                        .foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: Tokens.Spacing.m, verticalSpacing: Tokens.Spacing.xxs) {
                    ForEach(rows, id: \.self) { row in
                        GridRow {
                            Text(row.title)
                                .help(Text(row.help))
                            Text(Formatters.bytes(row.bytes))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
            case .noAccess:
                HStack(spacing: Tokens.Spacing.s) {
                    Text("macOS keeps Photos libraries private until Mactivity has Full Disk Access.", bundle: .strings)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button(String(localized: "Open Privacy & Security…", bundle: .strings)) {
                        if let url = VolumeInfo.fullDiskAccessSettingsURL {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                    Button(String(localized: "Check Again", bundle: .strings), action: measure)
                        .controlSize(.small)
                }
            case .notMeasured:
                HStack(spacing: Tokens.Spacing.s) {
                    Text("On another drive. Measuring it reads the whole library's folders there.", bundle: .strings)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button(
                        String(localized: "Measure", bundle: .strings, comment: "Photos library on another drive: size it now"),
                        action: measure
                    )
                    .controlSize(.small)
                }
            }
        }
    }
}
