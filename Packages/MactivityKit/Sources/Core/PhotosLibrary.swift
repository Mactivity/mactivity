import Foundation

/// What a Photos library takes on this Mac (D-283), by the folders inside its package. Sizes only,
/// never a file opened: the package's layout is Photos' own and can change, so a folder that isn't
/// there counts as zero and anything unknown as "everything else".
///
/// What iCloud keeps only online isn't here. It's only in Photos' private database, whose columns
/// Apple doesn't document, so no figure for it can be stood behind.
public struct PhotosLibraryParts: Hashable, Sendable {
    public var originals: UInt64 = 0
    public var edits: UInt64 = 0
    public var thumbnails: UInt64 = 0
    public var sharedAlbums: UInt64 = 0
    public var database: UInt64 = 0
    public var other: UInt64 = 0

    public init(
        originals: UInt64 = 0, edits: UInt64 = 0, thumbnails: UInt64 = 0, sharedAlbums: UInt64 = 0, database: UInt64 = 0, other: UInt64 = 0
    ) {
        self.originals = originals
        self.edits = edits
        self.thumbnails = thumbnails
        self.sharedAlbums = sharedAlbums
        self.database = database
        self.other = other
    }

    public var total: UInt64 {
        originals + edits + thumbnails + sharedAlbums + database + other
    }

    /// Which part a path inside the package belongs to, relative to the package. Pure.
    public enum Part: Hashable, Sendable, CaseIterable {
        case originals, edits, thumbnails, sharedAlbums, database, other
    }

    /// `Masters` is what libraries not opened since macOS 10.15 still call their originals.
    public static func part(of relativePath: String) -> Part {
        let path = relativePath.hasPrefix("/") ? String(relativePath.dropFirst()) : relativePath
        func isIn(_ folder: String) -> Bool {
            path == folder || path.hasPrefix(folder + "/")
        }
        if isIn("originals") || isIn("Masters") {
            return .originals
        }
        if isIn("resources/renders") {
            return .edits
        }
        if isIn("resources/derivatives") {
            return .thumbnails
        }
        if isIn("scopes/cloudsharing") {
            return .sharedAlbums
        }
        if isIn("database") {
            return .database
        }
        return .other
    }

    public mutating func add(_ bytes: UInt64, to part: Part) {
        switch part {
        case .originals: originals += bytes
        case .edits: edits += bytes
        case .thumbnails: thumbnails += bytes
        case .sharedAlbums: sharedAlbums += bytes
        case .database: database += bytes
        case .other: other += bytes
        }
    }
}

/// One library found on this Mac.
public struct PhotosLibraryReport: Hashable, Sendable, Identifiable {
    public enum State: Hashable, Sendable {
        case measured(PhotosLibraryParts)
        /// macOS keeps Photos libraries from other apps until Full Disk Access is on.
        case noAccess
        /// On another drive: measured only when asked, since that means reading that drive.
        case notMeasured
    }

    public var id: String {
        path
    }

    public let path: String
    public let state: State

    public init(path: String, state: State) {
        self.path = path
        self.state = state
    }

    public var name: String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

public protocol PhotosLibrarySource: Sendable {
    /// Every library found, measured unless it's on another drive. Walks the libraries' folders:
    /// only while Storage shows, off the main thread.
    func libraries() async -> [PhotosLibraryReport]
    /// One library, asked for by the person.
    func measure(path: String) async -> PhotosLibraryReport
}
