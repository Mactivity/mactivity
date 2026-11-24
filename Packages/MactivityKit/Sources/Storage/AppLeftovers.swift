import Foundation

/// App uninstaller (D-104): an app and the files it left in ~/Library, found by its bundle ID.
/// Nothing here moves anything: the UI shows the plan, asks, and moves the ticked items to the
/// Trash through `StorageTrashing`.
public struct UninstallItem: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case app, applicationSupport, caches, preferences, containers, groupContainers, savedState,
             webData, logs, launchAgents, scripts
    }

    public var id: String {
        path
    }

    public let path: String
    public let kind: Kind
    public let size: UInt64
    /// Found by the app's name rather than its bundle ID: it may belong to something else, so
    /// it starts unticked.
    public let matchedByName: Bool

    public init(path: String, kind: Kind, size: UInt64, matchedByName: Bool) {
        self.path = path
        self.kind = kind
        self.size = size
        self.matchedByName = matchedByName
    }
}

public struct UninstallPlan: Hashable, Sendable {
    public let appName: String
    public let bundleID: String
    public let appPath: String
    /// The app first, then its leftovers, largest first.
    public let items: [UninstallItem]

    public init(appName: String, bundleID: String, appPath: String, items: [UninstallItem]) {
        self.appName = appName
        self.bundleID = bundleID
        self.appPath = appPath
        self.items = items
    }
}

public enum UninstallError: Error, Sendable, Equatable {
    /// macOS's own apps live on the read-only system volume.
    case systemApp
    /// Not an app bundle with a bundle ID.
    case notAnApp
}

public enum AppLeftovers {
    /// Where apps leave things in ~/Library, by bundle ID ("com.example.App") and, for a few
    /// folders apps name after themselves, by name. Pure: the caller checks what exists.
    static func candidates(bundleID: String, name: String, library: URL) -> [(URL, UninstallItem.Kind, byName: Bool)] {
        func path(_ components: String...) -> URL {
            components.reduce(library) { $0.appendingPathComponent($1) }
        }
        var found: [(URL, UninstallItem.Kind, byName: Bool)] = [
            (path("Application Support", bundleID), .applicationSupport, false),
            (path("Caches", bundleID), .caches, false),
            (path("Preferences", "\(bundleID).plist"), .preferences, false),
            (path("Containers", bundleID), .containers, false),
            (path("Saved Application State", "\(bundleID).savedState"), .savedState, false),
            (path("HTTPStorages", bundleID), .webData, false),
            (path("HTTPStorages", "\(bundleID).binarycookies"), .webData, false),
            (path("WebKit", bundleID), .webData, false),
            (path("Cookies", "\(bundleID).binarycookies"), .webData, false),
            (path("Logs", bundleID), .logs, false),
            (path("Application Scripts", bundleID), .scripts, false),
        ]
        // Folders named after the app, only for names too specific to belong to others.
        if isSpecificName(name) {
            found += [
                (path("Application Support", name), .applicationSupport, true),
                (path("Caches", name), .caches, true),
                (path("Logs", name), .logs, true),
            ]
        }
        return found
    }

    /// Names like "Code" or "Notes" could be anyone's folder; "Visual Studio Code" can't. Never
    /// one that's a path: "../Mail" would name ~/Library/Mail (D-140).
    static func isSpecificName(_ name: String) -> Bool {
        name.count >= 5 && !["Utilities", "Support", "Library", "Application", "Documents"].contains(name)
            && !name.contains("/") && !name.hasPrefix(".")
    }

    /// A bundle ID that's safe to put in a path: reverse-DNS letters, digits, hyphens and
    /// underscores. It comes from the app's own Info.plist, so "../Mail" or "" is possible, and
    /// would have named ~/Library/Mail or the whole Application Support folder (D-140).
    static func isSafeBundleID(_ bundleID: String) -> Bool {
        bundleID.range(of: #"^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+$"#, options: .regularExpression) != nil
    }

    /// Where leftovers may be moved from: the top of each ~/Library folder `plan` looks in.
    public static func leftoverScope(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> CleanupScope {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let folders = [
            "Application Support", "Caches", "Preferences", "Preferences/ByHost", "Containers", "Saved Application State",
            "HTTPStorages", "WebKit", "Cookies", "Logs", "Application Scripts", "LaunchAgents", "Group Containers",
        ]
        return CleanupScope(roots: folders.map { library.appendingPathComponent($0) }, depth: .topLevel)
    }

    /// Items in a folder whose names start with the bundle ID or end with ".<bundle ID>": the
    /// ByHost preferences, launch agents, and group containers ("<team>.<bundle ID>").
    static func prefixed(in folder: URL, bundleID: String, kind: UninstallItem.Kind, fileManager: FileManager) -> [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .filter { $0.hasPrefix(bundleID + ".") || $0 == bundleID || $0.hasSuffix("." + bundleID) }
            .map { folder.appendingPathComponent($0) }
    }

    /// The plan for the app at `appURL`: the app and every leftover that exists, with sizes.
    public static func plan(
        appURL: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws(UninstallError) -> UninstallPlan {
        let path = appURL.resolvingSymlinksInPath().path
        guard !path.hasPrefix("/System/") else {
            throw .systemApp
        }
        guard let bundle = Bundle(url: appURL), let bundleID = bundle.bundleIdentifier, isSafeBundleID(bundleID),
              appURL.pathExtension == "app"
        else {
            throw .notAnApp
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        let fileManager = FileManager.default
        let library = home.appendingPathComponent("Library", isDirectory: true)
        var urls = candidates(bundleID: bundleID, name: name, library: library)
        urls += prefixed(
            in: library.appendingPathComponent("Preferences/ByHost"),
            bundleID: bundleID,
            kind: .preferences,
            fileManager: fileManager
        )
        .map { ($0, .preferences, false) }
        urls += prefixed(
            in: library.appendingPathComponent("LaunchAgents"),
            bundleID: bundleID,
            kind: .launchAgents,
            fileManager: fileManager
        )
        .map { ($0, .launchAgents, false) }
        urls += prefixed(
            in: library.appendingPathComponent("Group Containers"),
            bundleID: bundleID,
            kind: .groupContainers,
            fileManager: fileManager
        )
        .map { ($0, .groupContainers, false) }
        var seen: Set<String> = []
        var items: [UninstallItem] = []
        for (url, kind, byName) in urls where fileManager.fileExists(atPath: url.path) && seen.insert(url.path).inserted {
            items.append(UninstallItem(path: url.path, kind: kind, size: size(of: url, fileManager: fileManager), matchedByName: byName))
        }
        items.sort { $0.size > $1.size }
        let app = UninstallItem(path: appURL.path, kind: .app, size: size(of: appURL, fileManager: fileManager), matchedByName: false)
        return UninstallPlan(appName: name, bundleID: bundleID, appPath: appURL.path, items: [app] + items)
    }

    /// Allocated size of a file or folder, summed without following links.
    static func size(of url: URL, fileManager: FileManager) -> UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
            return UInt64(values.totalFileAllocatedSize ?? 0)
        }
        var total: UInt64 = 0
        let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        while let file = enumerator?.nextObject() as? URL {
            if let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
                total += UInt64(values.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
