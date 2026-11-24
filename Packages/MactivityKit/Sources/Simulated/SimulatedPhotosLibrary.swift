import Core
import Foundation

/// A family's library, mostly in iCloud, for previews, tests and simulated data.
public struct SimulatedPhotosLibrary: PhotosLibrarySource {
    private let reports: [PhotosLibraryReport]

    public init(reports: [PhotosLibraryReport]? = nil) {
        self.reports = reports ?? [PhotosLibraryReport(
            path: "/Users/you/Pictures/Photos Library.photoslibrary",
            state: .measured(PhotosLibraryParts(
                originals: 84_000_000_000, edits: 3_100_000_000, thumbnails: 14_000_000_000, sharedAlbums: 2_400_000_000,
                database: 1_900_000_000, other: 1_200_000_000
            ))
        )]
    }

    public func libraries() async -> [PhotosLibraryReport] {
        reports
    }

    public func measure(path: String) async -> PhotosLibraryReport {
        reports.first { $0.path == path } ?? PhotosLibraryReport(path: path, state: .measured(PhotosLibraryParts()))
    }
}
