import Foundation
import os

/// The user said yes to moving one item to the Trash. Only the storage view's confirm step
/// creates these (`package` init), the way only `ConfirmedAction` creates a
/// `ConfirmedTermination` (CLAUDE.md rule 4, D-031).
public struct TrashConfirmation: Sendable, Hashable {
    public let path: String
    public let confirmedAt: Date

    package init(path: String, confirmedAt: Date) {
        self.path = path
        self.confirmedAt = confirmedAt
    }
}

public enum StorageTrashError: Error, Sendable, Equatable {
    /// A folder the Mac needs, or one that holds everything: "/", the home folder, /System.
    case protectedLocation(String)
    case notFound(String)
    case failed(String)
}

public protocol StorageTrashing: Sendable {
    /// Moves the item to the Trash and returns where it went. Never deletes.
    func moveToTrash(_ confirmation: TrashConfirmation) async throws -> URL?
}

/// Moves items to the Trash with `FileManager.trashItem`, so everything can be put back.
/// There is no delete: Mactivity isn't a cleaner (spec 3), and permanent deletes are
/// prohibited outright.
public struct StorageTrasher: StorageTrashing {
    private static let log = Logger(subsystem: "app.mactivity.storage", category: "trash")

    private let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    public func moveToTrash(_ confirmation: TrashConfirmation) async throws -> URL? {
        let path = confirmation.path
        try check(path)
        let url = URL(fileURLWithPath: path)
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        } catch {
            Self.log.error("Couldn't move \(path, privacy: .private) to the Trash: \(error.localizedDescription)")
            throw StorageTrashError.failed(error.localizedDescription)
        }
        Self.log.info("Moved \(path, privacy: .private) to the Trash")
        return resulting as URL?
    }

    /// Refuses the places no storage map should ever offer to trash.
    func check(_ path: String) throws(StorageTrashError) {
        let standardized = (path as NSString).standardizingPath
        guard standardized.hasPrefix("/"), standardized.count > 1 else {
            throw .protectedLocation(path)
        }
        // A startup-disk map reaches the user's files through the data volume's own path
        // (/System/Volumes/Data/Users/…). Judge that as the path it really is, so the home,
        // /Users and /Applications stay protected and "System" doesn't refuse everything (D-140).
        let dataVolume = "/System/Volumes/Data"
        let judged = standardized.hasPrefix(dataVolume + "/") ? String(standardized.dropFirst(dataVolume.count)) : standardized
        let components = judged.split(separator: "/")
        let homeComponents = home.split(separator: "/")
        let isTopLevel = components.count <= 1
        let isHomeOrTopOfHome = components.starts(with: homeComponents) && components.count <= homeComponents.count + 1
        let isSystem = components.first == "System" || standardized == dataVolume || judged == "/Users" || judged == "/Applications"
        if isTopLevel || isHomeOrTopOfHome || isSystem {
            throw .protectedLocation(path)
        }
        var info = stat()
        guard lstat(standardized, &info) == 0 else {
            throw .notFound(path)
        }
    }
}
