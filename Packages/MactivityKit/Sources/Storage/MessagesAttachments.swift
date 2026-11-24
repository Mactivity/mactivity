import Foundation
import UniformTypeIdentifiers

/// Messages attachments on this Mac (D-116): the photos, videos and files Messages keeps in
/// ~/Library/Messages/Attachments, one folder per attachment. They're this Mac's copies. Moving
/// one to the Trash leaves the message, and every other device's copy, alone. Nothing here moves
/// anything: the UI shows what matches, asks, and moves them through `StorageTrashing`.
public struct MessageAttachment: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case photo, video, audio, document, other
    }

    public var id: String {
        path
    }

    public let path: String
    public let size: UInt64
    /// When Messages saved it, from the file.
    public let date: Date
    public let kind: Kind

    public var name: String {
        (path as NSString).lastPathComponent
    }

    public init(path: String, size: UInt64, date: Date, kind: Kind) {
        self.path = path
        self.size = size
        self.date = date
        self.kind = kind
    }
}

public enum MessagesAttachmentsError: Error, Sendable, Equatable {
    /// macOS privacy protection: Messages' folder needs Full Disk Access.
    case noAccess
    /// No Messages attachments on this Mac.
    case notFound
}

/// Which attachments to move: older than an age, of a kind, at least a size.
public struct MessageAttachmentFilter: Hashable, Sendable {
    public var olderThanDays: Int?
    public var kind: MessageAttachment.Kind?
    public var minimumBytes: UInt64

    public init(olderThanDays: Int? = 365, kind: MessageAttachment.Kind? = nil, minimumBytes: UInt64 = 0) {
        self.olderThanDays = olderThanDays
        self.kind = kind
        self.minimumBytes = minimumBytes
    }
}

public enum MessagesAttachments {
    public static func folder(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Messages/Attachments", isDirectory: true)
    }

    /// Every attachment file under `folder`, largest first. Reads sizes and dates only.
    public static func scan(_ folder: URL = folder()) throws(MessagesAttachmentsError) -> [MessageAttachment] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw .notFound
        }
        // Listing the folder fails outright without Full Disk Access.
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            throw .noAccess
        }
        // When the file arrived, not when it was last edited: a copy keeps its source's
        // modification date, so a video edited two years ago and sent yesterday read as two
        // years old (D-140).
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey, .addedToDirectoryDateKey, .creationDateKey,
            .contentModificationDateKey,
        ]
        guard let files = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw .noAccess
        }
        var found: [MessageAttachment] = []
        for case let url as URL in files {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            let size = UInt64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            found.append(MessageAttachment(
                path: url.path, size: size,
                date: values.addedToDirectoryDate ?? values.creationDate ?? values.contentModificationDate ?? .distantPast,
                kind: kind(pathExtension: url.pathExtension)
            ))
        }
        return found.sorted { ($0.size, $1.path) > ($1.size, $0.path) }
    }

    /// Pure: what kind of attachment a file is, by its extension. HEIC, JPEG, PNG and GIF are
    /// photos, MOV and MP4 videos, CAF and M4A (voice messages) audio.
    public static func kind(pathExtension: String) -> MessageAttachment.Kind {
        guard let type = UTType(filenameExtension: pathExtension.lowercased()) else {
            return .other
        }
        if type.conforms(to: .image) {
            return .photo
        }
        if type.conforms(to: .movie) || type.conforms(to: .video) {
            return .video
        }
        if type.conforms(to: .audio) {
            return .audio
        }
        if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .presentation)
            || type.conforms(to: .spreadsheet) || type.conforms(to: .archive) {
            return .document
        }
        return .other
    }

    /// Pure: the attachments the filter picks, largest first.
    public static func matching(_ attachments: [MessageAttachment], _ filter: MessageAttachmentFilter, now: Date) -> [MessageAttachment] {
        let cutoff = filter.olderThanDays.map { now.addingTimeInterval(-TimeInterval($0) * 86400) }
        return attachments.filter { attachment in
            (cutoff.map { attachment.date < $0 } ?? true)
                && (filter.kind.map { attachment.kind == $0 } ?? true)
                && attachment.size >= filter.minimumBytes
        }
    }

    /// Pure: how many there are of each kind, and their size.
    public static func totals(_ attachments: [MessageAttachment]) -> [MessageAttachment.Kind: (count: Int, bytes: UInt64)] {
        var totals: [MessageAttachment.Kind: (count: Int, bytes: UInt64)] = [:]
        for attachment in attachments {
            let current = totals[attachment.kind] ?? (0, 0)
            totals[attachment.kind] = (current.count + 1, current.bytes + attachment.size)
        }
        return totals
    }
}
