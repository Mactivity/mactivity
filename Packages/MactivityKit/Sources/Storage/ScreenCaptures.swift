import Darwin
import Foundation
import UniformTypeIdentifiers

/// Screenshots and screen recordings (D-122): the ones macOS saved to the screenshot folder and
/// the Desktop, recognized by the attribute macOS gives every capture
/// (`com.apple.metadata:kMDItemIsScreenCapture`), not by their names, which are in the Mac's
/// language. Only each folder's top level.
public struct ScreenCapture: Hashable, Sendable, Identifiable {
    public var id: String {
        path
    }

    public let path: String
    public let isRecording: Bool
    public let size: UInt64
    public let date: Date

    public init(path: String, isRecording: Bool, size: UInt64, date: Date) {
        self.path = path
        self.isRecording = isRecording
        self.size = size
        self.date = date
    }
}

public enum ScreenCaptures {
    static let attribute = "com.apple.metadata:kMDItemIsScreenCapture"

    /// Where screenshots go: Screenshot's Options → Save to, or the Desktop.
    public static func folders(home: String = NSHomeDirectory(), setting: String? = screenshotSetting()) -> [URL] {
        let desktop = URL(fileURLWithPath: home).appendingPathComponent("Desktop", isDirectory: true)
        guard let setting, !setting.isEmpty else {
            return [desktop]
        }
        let chosen = URL(fileURLWithPath: (setting as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        return chosen.path == desktop.standardizedFileURL.path ? [desktop] : [chosen, desktop]
    }

    /// `defaults read com.apple.screencapture location`.
    public static func screenshotSetting() -> String? {
        UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
    }

    /// Whether macOS marked the file as a capture.
    static func isScreenCapture(_ path: String) -> Bool {
        getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// Every capture in `folders`, largest first. A missing folder is skipped; one macOS won't let
    /// Mactivity list is `noAccess`.
    public static func scan(_ folders: [URL] = folders()) throws(ProtectedFolderError) -> [ScreenCapture] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey, .creationDateKey, .contentTypeKey]
        var found: [ScreenCapture] = []
        var seen: Set<String> = []
        for folder in folders where FileManager.default.fileExists(atPath: folder.path) {
            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles]
                )
            } catch {
                throw .noAccess
            }
            for url in entries where !seen.contains(url.path) && isScreenCapture(url.path) {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                    continue
                }
                seen.insert(url.path)
                let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)
                found.append(ScreenCapture(
                    path: url.path,
                    isRecording: type?.conforms(to: .movie) ?? false,
                    size: UInt64(values.totalFileAllocatedSize ?? values.fileSize ?? 0),
                    date: values.creationDate ?? .distantPast
                ))
            }
        }
        return found.sorted { ($0.size, $1.path) > ($1.size, $0.path) }
    }
}
