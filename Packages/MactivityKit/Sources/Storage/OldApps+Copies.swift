import Core
import Darwin
import Foundation

/// Which copies of an app could go (D-282).
extension OldApps {

    // MARK: Second copies

    /// By version number, then build: "2.10" is newer than "2.9". A missing version orders first,
    /// and never equals one that's there.
    static func compare(_ left: String?, _ right: String?) -> ComparisonResult {
        switch (left, right) {
        case let (left?, right?): left.compare(right, options: .numeric)
        case (nil, nil): .orderedSame
        case (nil, _): .orderedAscending
        case (_, nil): .orderedDescending
        }
    }

    private static func isNewer(_ left: AppBundle, than right: AppBundle) -> Bool {
        let versions = compare(left.version, right.version)
        return versions == .orderedSame ? compare(left.build, right.build) == .orderedDescending : versions == .orderedDescending
    }

    /// Inside one of `folders`, and not inside another app.
    static func isOffered(_ path: String, from folders: [URL]) -> Bool {
        guard !path.split(separator: "/").dropLast().contains(where: { $0.lowercased().hasSuffix(".app") }) else {
            return false
        }
        return folders.contains { path.hasPrefix($0.path + "/") }
    }

    /// Same ID, same name and same executable: two wrappers can share an ID and be different apps.
    private static func identity(_ bundle: AppBundle) -> String {
        "\(bundle.bundleID.lowercased())|\(bundle.name.lowercased())|\((bundle.executable ?? "").lowercased())"
    }

    /// Every copy that could go: what's in the app folders, and the same apps in Downloads or on
    /// the Desktop that Launch Services knows of. A build folder, a mounted drive or the Trash
    /// are someone's work or someone else's business, however old the copy there.
    public static func copies(_ env: OldAppsEnvironment) -> [OldAppCopy] {
        let inUse = env.inUsePaths()
        var bundles = env.copyFolders.flatMap { apps(in: $0) }
        for id in Set(bundles.map(\.bundleID)) {
            for url in env.launchServicesCopies(id) where isOffered(url.path, from: env.copyFolders + env.looseCopyFolders) {
                if let bundle = readBundle(at: url) {
                    bundles.append(bundle)
                }
            }
        }
        var seen = Set<String>()
        bundles = bundles.filter { seen.insert($0.path).inserted }
        let groups = Dictionary(grouping: bundles.filter { !isUntouchable($0.bundleID) && !isTemplateID($0.bundleID) }, by: identity)
        var found: [OldAppCopy] = []
        for group in groups.values where group.count > 1 {
            let running = group.filter { isInUse($0.path, inUse: inUse) }
            // What stays is always in an app folder: an installed app is never offered up in
            // favor of what's in Downloads or on the Desktop, however new.
            let installed = group.filter { isOffered($0.path, from: env.copyFolders) }
            guard let kept = running.max(by: { isNewer($1, than: $0) }) ?? best(of: installed, folders: env.copyFolders),
                  installed.contains(kept)
            else {
                continue
            }
            for copy in group where copy.path != kept.path && !running.contains(copy) && !isNewer(copy, than: kept) {
                found.append(OldAppCopy(
                    path: copy.path, bundleID: copy.bundleID, name: copy.name, version: copy.version, keptPath: kept.path,
                    keptVersion: kept.version, size: AppLeftovers.size(of: URL(fileURLWithPath: copy.path), fileManager: .default)
                ))
            }
        }
        return found.sorted { ($0.size, $1.path) > ($1.size, $0.path) }
    }

    /// The copy that stays when none is running: the newest; of equals, the one in the first app
    /// folder, under its plainest name.
    private static func best(of group: [AppBundle], folders: [URL]) -> AppBundle? {
        func rank(_ bundle: AppBundle) -> Int {
            folders.firstIndex { bundle.path.hasPrefix($0.path + "/") } ?? folders.count
        }
        return group.max { left, right in
            if isNewer(right, than: left) {
                return true
            }
            if isNewer(left, than: right) {
                return false
            }
            return (rank(right), right.path.count, right.path) < (rank(left), left.path.count, left.path)
        }
    }

    /// Right before the Trash: the copy that stays must still be there and be the same app, and
    /// this one must not have started running or become the newer of the two.
    public static func stillCopy(_ path: String, keeping kept: String, env: OldAppsEnvironment) -> Bool {
        guard path != kept, let copy = readBundle(at: URL(fileURLWithPath: path)), let keeper = readBundle(at: URL(fileURLWithPath: kept)),
              identity(copy) == identity(keeper), !isUntouchable(copy.bundleID), !isNewer(copy, than: keeper),
              isOffered(path, from: env.copyFolders + env.looseCopyFolders)
        else {
            return false
        }
        return !isInUse(path, inUse: env.inUsePaths())
    }
}
