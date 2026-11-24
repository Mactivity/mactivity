import Foundation
import UniformTypeIdentifiers

/// Decides a file's category (spec E10). A folder can set the category for everything inside it
/// (an app bundle is Apps, `~/Library` is System & library, `node_modules` is Developer);
/// otherwise the file's UTType decides.
public enum CategoryRules {
    /// Folder names that make everything inside them Developer, wherever they are.
    static let developerFolderNames: Set<String> = [
        "node_modules", "DerivedData", ".git", ".build", "Pods", ".gradle", ".cargo", ".npm",
        ".venv", "venv", "__pycache__", ".swiftpm", "CoreSimulator", "Carthage", "com.docker.docker",
    ]

    /// Top-level folders of a volume that hold the system and shared libraries.
    static let systemRoots: Set<String> = [
        "/System", "/Library", "/private", "/usr", "/bin", "/sbin", "/opt", "/cores",
        "/System/Volumes/Data/Library", "/System/Volumes/Data/private", "/System/Volumes/Data/usr",
        "/System/Volumes/Data/opt", "/System/Volumes/Data/cores",
    ]

    /// The category a folder imposes on its contents, or its parent's.
    ///
    /// - Parameters:
    ///   - name: the folder's name.
    ///   - path: its absolute path.
    ///   - home: the home folder, for `~/Library`.
    ///   - inherited: the parent folder's context.
    public static func context(forFolder name: String, path: String, home: String, inherited: StorageCategory?) -> StorageCategory? {
        let lowered = name.lowercased()
        if lowered.hasSuffix(".app") {
            return .apps
        }
        if lowered.hasSuffix(".photoslibrary") || lowered.hasSuffix(".photolibrary") {
            return .photosAndVideo
        }
        if lowered.hasSuffix(".musiclibrary") || lowered.hasSuffix(".logicx") || lowered.hasSuffix(".band") {
            return .audio
        }
        // An app bundle or a media library is what it is, even inside a Library.
        if inherited == .apps || inherited == .photosAndVideo || inherited == .audio {
            return inherited
        }
        if developerFolderNames.contains(name) || lowered.hasSuffix(".xcodeproj") || lowered.hasSuffix(".xcworkspace") {
            return .developer
        }
        // ~/Library/Developer is Developer, not Library.
        if name == "Developer", inherited == .systemAndLibrary {
            return .developer
        }
        if inherited != nil {
            return inherited
        }
        if path == home + "/Library" || systemRoots.contains(path) || isOtherHomeLibrary(path) {
            return .systemAndLibrary
        }
        return nil
    }

    /// `/Users/<someone>/Library`, with or without the Data volume prefix.
    private static func isOtherHomeLibrary(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        let trimmed = parts.starts(with: ["System", "Volumes", "Data"]) ? Array(parts.dropFirst(3)) : Array(parts)
        return trimmed.count == 3 && trimmed[0] == "Users" && trimmed[2] == "Library"
    }

    /// A file's category from its extension. Callers cache by extension.
    public static func category(forExtension fileExtension: String) -> StorageCategory {
        guard !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension) else {
            return .other
        }
        return category(for: type)
    }

    public static func category(for type: UTType) -> StorageCategory {
        // Order matters: a disk image is data, an app is a bundle, source code is text.
        if type.conforms(to: .application) || type.conforms(to: .applicationBundle) || type.conforms(to: .applicationExtension) {
            return .apps
        }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) || type.conforms(to: .zip) {
            return .archives
        }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .propertyList) ||
            type.conforms(to: .json) || type.conforms(to: .yaml) ||
            type.conforms(to: .unixExecutable) || type.conforms(to: .database) {
            return .developer
        }
        if type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .video) {
            return .photosAndVideo
        }
        if type.conforms(to: .audio) {
            return .audio
        }
        if type.conforms(to: .pdf) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet) ||
            type.conforms(to: .text) || type.conforms(to: .compositeContent) || type.conforms(to: .content) {
            return .documents
        }
        return .other
    }
}

/// Per-scan cache of extension → category. Not shared between threads.
struct CategoryCache: Sendable {
    private var byExtension: [String: StorageCategory] = [:]

    mutating func category(forFileNamed name: String) -> StorageCategory {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return .other
        }
        let fileExtension = name[name.index(after: dot)...].lowercased()
        if let cached = byExtension[fileExtension] {
            return cached
        }
        let category = CategoryRules.category(forExtension: fileExtension)
        byExtension[fileExtension] = category
        return category
    }
}
