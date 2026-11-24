import Core
import Darwin
import Foundation

/// Old app versions and leftovers (D-282): second copies of apps, and support files of apps that
/// are gone. A wrong row here sends someone's working data to the Trash, so every rule leans
/// towards not listing: a look-alike, a doubt, an unreadable corner or a recent change and it
/// stays off the list. Nothing here moves anything; the UI shows the rows and asks.
public struct OldAppCopy: Hashable, Sendable, Identifiable {
    public var id: String {
        path
    }

    public let path: String
    public let bundleID: String
    public let name: String
    public let version: String?
    /// The copy that stays, checked again right before the Trash.
    public let keptPath: String
    public let keptVersion: String?
    public let size: UInt64

    public init(path: String, bundleID: String, name: String, version: String?, keptPath: String, keptVersion: String?, size: UInt64) {
        self.path = path
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.keptPath = keptPath
        self.keptVersion = keptVersion
        self.size = size
    }

    public var isSameVersion: Bool {
        OldApps.compare(version, keptVersion) == .orderedSame
    }
}

/// A support file or folder of an app that's gone.
public struct AppSupportLeftover: Hashable, Sendable, Identifiable {
    public var id: String {
        path
    }

    public let path: String
    public let kind: UninstallItem.Kind
    /// The bundle ID it's named after, or the app's exact name.
    public let owner: String
    /// The app's name, when Mactivity saw it run.
    public let appName: String?
    /// Named after the app rather than its bundle ID: it may belong to something else.
    public let matchedByName: Bool
    public let size: UInt64
    /// The newest change to it or anything inside it.
    public let lastChanged: Date
    public let fileCount: Int
    /// A few of the names at its top.
    public let contents: [String]

    public init(
        path: String, kind: UninstallItem.Kind, owner: String, appName: String?, matchedByName: Bool, size: UInt64, lastChanged: Date,
        fileCount: Int, contents: [String]
    ) {
        self.path = path
        self.kind = kind
        self.owner = owner
        self.appName = appName
        self.matchedByName = matchedByName
        self.size = size
        self.lastChanged = lastChanged
        self.fileCount = fileCount
        self.contents = contents
    }
}

/// What the scan needs to know about this Mac; a fixture home and closures in tests.
public struct OldAppsEnvironment: Sendable {
    public var home: URL
    /// Where apps count as installed: whichever copy is there, its ID and vendor are claimed.
    public var installedFolders: [URL]
    /// Where a second copy may be offered for the Trash.
    public var copyFolders: [URL]
    /// Further places a copy that Launch Services knows of may be offered from: Downloads, Desktop.
    public var looseCopyFolders: [URL]
    /// Launch agents, daemons and privileged helpers: what's named there is still set up.
    public var backgroundFolders: [URL]
    /// Launch Services' copies of an app: apps anywhere, a build folder or a mounted drive.
    public var launchServicesCopies: @Sendable (String) -> [URL]
    /// Files and folders running programs have open, and those programs themselves.
    public var inUsePaths: @Sendable () -> [String]
    /// Apps Mactivity has seen run.
    public var recordedApps: [RecordedApp]
    public var now: Date
    /// Support files must be untouched this long.
    public var minimumAge: TimeInterval

    public static let defaultMinimumAge: TimeInterval = 180 * 86400

    public init(
        home: URL, installedFolders: [URL], copyFolders: [URL], looseCopyFolders: [URL], backgroundFolders: [URL],
        launchServicesCopies: @escaping @Sendable (String) -> [URL], inUsePaths: @escaping @Sendable () -> [String],
        recordedApps: [RecordedApp], now: Date, minimumAge: TimeInterval = OldAppsEnvironment.defaultMinimumAge
    ) {
        self.home = home
        self.installedFolders = installedFolders
        self.copyFolders = copyFolders
        self.looseCopyFolders = looseCopyFolders
        self.backgroundFolders = backgroundFolders
        self.launchServicesCopies = launchServicesCopies
        self.inUsePaths = inUsePaths
        self.recordedApps = recordedApps
        self.now = now
        self.minimumAge = minimumAge
    }

    /// This Mac. `launchServicesCopies` comes from AppKit, which this module doesn't link.
    public static func live(
        recordedApps: [RecordedApp], launchServicesCopies: @escaping @Sendable (String) -> [URL], now: Date = Date()
    ) -> OldAppsEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let applications = URL(fileURLWithPath: "/Applications")
        let homeApplications = home.appendingPathComponent("Applications")
        return OldAppsEnvironment(
            home: home,
            installedFolders: [
                applications, homeApplications, URL(fileURLWithPath: "/System/Applications"),
                URL(fileURLWithPath: "/opt/homebrew/Caskroom"),
            ],
            copyFolders: [applications, homeApplications],
            looseCopyFolders: [home.appendingPathComponent("Downloads"), home.appendingPathComponent("Desktop")],
            backgroundFolders: [
                home.appendingPathComponent("Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchAgents"),
                URL(fileURLWithPath: "/Library/LaunchDaemons"), URL(fileURLWithPath: "/Library/PrivilegedHelperTools"),
            ],
            launchServicesCopies: launchServicesCopies,
            inUsePaths: { OpenFiles.paths() },
            recordedApps: recordedApps,
            now: now
        )
    }
}

public enum OldApps {

    // MARK: Reading apps

    /// An app bundle's own words.
    struct AppBundle: Hashable {
        let path: String
        let bundleID: String
        let name: String
        let fileName: String
        let executable: String?
        let version: String?
        let build: String?
    }

    /// Reads one app's Info.plist, directly so Foundation's bundle cache can't answer for a moved app. Nil
    /// for a link, which is another name for a copy somewhere else, and for anything that isn't
    /// an app with a usable bundle ID.
    static func readBundle(at url: URL) -> AppBundle? {
        guard url.pathExtension.lowercased() == "app", !isLink(url.path), let info = infoPlist(of: url),
              let bundleID = info["CFBundleIdentifier"] as? String, AppLeftovers.isSafeBundleID(bundleID)
        else {
            return nil
        }
        let fileName = url.deletingPathExtension().lastPathComponent
        return AppBundle(
            path: url.path, bundleID: bundleID,
            name: (info["CFBundleName"] as? String) ?? (info["CFBundleDisplayName"] as? String) ?? fileName,
            fileName: fileName,
            executable: info["CFBundleExecutable"] as? String,
            version: info["CFBundleShortVersionString"] as? String,
            build: info["CFBundleVersion"] as? String
        )
    }

    static func infoPlist(of bundle: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else {
            return nil
        }
        return plist as? [String: Any]
    }

    static func isLink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Apps in a folder and its plain subfolders, never inside an app or through a link.
    static func apps(in folder: URL, depth: Int = 3) -> [AppBundle] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var found: [AppBundle] = []
        for name in names where !name.hasPrefix(".") {
            let url = folder.appendingPathComponent(name)
            if url.pathExtension.lowercased() == "app" {
                if let bundle = readBundle(at: url) {
                    found.append(bundle)
                }
            } else if depth > 0, url.pathExtension.isEmpty || !packageExtensions.contains(url.pathExtension.lowercased()),
                      isDirectory(url.path) {
                found += apps(in: url, depth: depth - 1)
            }
        }
        return found
    }

    private static let packageExtensions: Set<String> = ["framework", "bundle", "plugin", "appex", "xpc", "kext"]

    /// The bundle IDs of what an app carries inside it: login items, helpers, services, plug-ins.
    /// These write under their own IDs, and aren't always named after the app's vendor.
    static func nestedBundleIDs(of app: String) -> [String] {
        let contents = URL(fileURLWithPath: app).appendingPathComponent("Contents")
        var ids: [String] = []
        for place in ["Library/LoginItems", "Library/LaunchServices", "Helpers", "XPCServices", "PlugIns", "Frameworks", "MacOS"] {
            let folder = contents.appendingPathComponent(place)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where ["app", "xpc", "appex", "bundle", "plugin"].contains((name as NSString).pathExtension.lowercased()) {
                if let id = infoPlist(of: folder.appendingPathComponent(name))?["CFBundleIdentifier"] as? String {
                    ids.append(id)
                }
            }
        }
        return ids
    }

    // MARK: Who owns what

    /// Everything on this Mac that lays a claim to a support file.
    struct Claims {
        var bundleIDs: Set<String> = []
        var vendors: Set<String> = []
        var names: Set<String> = []

        mutating func claim(bundleID: String) {
            let id = bundleID.lowercased()
            bundleIDs.insert(id)
            if let vendor = OldApps.vendor(of: id) {
                vendors.insert(vendor)
            }
        }

        mutating func claim(_ bundle: AppBundle) {
            claim(bundleID: bundle.bundleID)
            names.insert(bundle.name.lowercased())
            names.insert(bundle.fileName.lowercased())
        }

        /// By the whole ID, by the vendor: `com.foo.Helper` may well be `com.foo.App`'s. Losing a
        /// real leftover to this costs a few files on disk; the other way costs someone's data.
        func covers(bundleID: String) -> Bool {
            let id = bundleID.lowercased()
            if bundleIDs.contains(id) {
                return true
            }
            return OldApps.vendor(of: id).map(vendors.contains) ?? true
        }
    }

    /// "com.foo" of "com.foo.App".
    static func vendor(of bundleID: String) -> String? {
        let parts = bundleID.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 ? "\(parts[0]).\(parts[1])".lowercased() : nil
    }

    static func claims(_ env: OldAppsEnvironment, inUse: [String]) -> Claims {
        var claims = Claims()
        for folder in env.installedFolders {
            for bundle in apps(in: folder) {
                claims.claim(bundle)
                nestedBundleIDs(of: bundle.path).forEach { claims.claim(bundleID: $0) }
            }
        }
        // What's set to run in the background: "com.foo.agent.plist", or a helper named its ID.
        for folder in env.backgroundFolders {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                let label = name.hasSuffix(".plist") ? String(name.dropLast(6)) : name
                if label.contains(".") {
                    claims.claim(bundleID: label)
                }
            }
        }
        // Apps running from anywhere: a build folder, a disk image.
        for path in inUse {
            if let range = path.range(of: ".app/", options: .caseInsensitive),
               let bundle = readBundle(at: URL(fileURLWithPath: String(path[..<range.upperBound]))) {
                claims.claim(bundle)
            }
        }
        return claims
    }
}

extension CleanupScope {
    /// Old apps and leftovers: the top of the Library folders they're found in, Containers and
    /// Group Containers left out; an app anywhere in the app folders; the top of Downloads and
    /// the Desktop. `OldApps.stillCopy` and `stillLeftover` then judge the row itself.
    public static func oldApps(home: String = NSHomeDirectory()) -> CleanupScope {
        let homeURL = URL(fileURLWithPath: home)
        let library = homeURL.appendingPathComponent("Library")
        var scope = CleanupScope(roots: OldApps.Place.allCases.map { library.appendingPathComponent($0.rawValue) }, depth: .topLevel)
        scope.alternatives = [
            CleanupScope(
                roots: [URL(fileURLWithPath: "/Applications"), homeURL.appendingPathComponent("Applications")], depth: .anywhere
            ),
            CleanupScope(
                roots: [homeURL.appendingPathComponent("Downloads"), homeURL.appendingPathComponent("Desktop")], depth: .anywhere
            ),
        ]
        return scope
    }
}
