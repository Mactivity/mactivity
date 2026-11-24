import Darwin
import Foundation

/// Space per project from the disk (D-223): projects in the usual code folders and every
/// workspace Xcode's DerivedData knows, each one's rebuildable folders found by
/// `ProjectSpaceRules` and sized as Storage sizes everything (allocated bytes). Reads only.
public struct LiveProjectSpaceScanner: ProjectSpaceScanning {
    private let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    public func scan(
        progress: @escaping @Sendable (Int, Int) -> Void,
        found: @escaping @Sendable (ProjectSpace) -> Void
    ) async -> [ProjectSpace] {
        let home = home
        return await Task.detached(priority: .utility) {
            Self.scan(home: home, progress: progress, found: found)
        }.value
    }

    /// Every project root to size, outermost only, and the DerivedData folders of each.
    static func roots(home: String) -> (ordered: [String], derived: [String: [String]]) {
        // Desktop, Documents and Downloads only with Full Disk Access: anything else there asks
        // macOS's permission, and a prompt for opening a view would be a surprise (D-229).
        let allowProtected = VolumeInfo.fullDiskAccess(home: home) == .granted
        func allowed(_ path: String) -> Bool {
            allowProtected || !ProjectSpaceRules.isProtected(path, home: home)
        }
        var roots = Set<String>()
        // One walk per folder on disk: APFS ignores case, so ~/Code and ~/code are one folder.
        var seen = Set<FileID>()
        for folder in ProjectSpaceRules.searchFolders.map({ home + "/" + $0 }) where allowed(folder) {
            if let id = FileID(folder), seen.insert(id).inserted {
                findProjects(in: folder, depth: 0, into: &roots)
            }
        }
        // Projects elsewhere still show through their DerivedData.
        var derived: [(project: String, folder: String)] = []
        for (project, folder) in derivedData(home: home) where project != home && project.count > 1 && allowed(project) {
            if isDirectory(project) {
                roots.insert(project)
                derived.append((project, folder))
            }
        }
        // Outermost roots only, so no folder counts in two projects; DerivedData joins its root.
        let ids = Dictionary(roots.map { ($0, FileID($0)) }, uniquingKeysWith: { first, _ in first })
        let ordered = ProjectSpaceRules.outermost(Array(roots)) { left, right in
            guard let left = ids[left].flatMap(\.self), let right = ids[right].flatMap(\.self) else {
                return false
            }
            return left == right
        }
        var byRoot: [String: [String]] = [:]
        for (project, folder) in derived {
            if let root = ordered.first(where: { project == $0 || project.hasPrefix($0 + "/") }) {
                byRoot[root, default: []].append(folder)
            }
        }
        return (ordered, byRoot)
    }

    static func scan(home: String, progress: (Int, Int) -> Void, found report: (ProjectSpace) -> Void = { _ in }) -> [ProjectSpace] {
        let (ordered, derivedByRoot) = roots(home: home)
        var spaces: [ProjectSpace] = []
        for (index, root) in ordered.enumerated() {
            if Task.isCancelled {
                break
            }
            progress(index, ordered.count)
            var found: [(ProjectArtifact.Kind, String)] = []
            findArtifacts(in: root, depth: 0, into: &found)
            found += (derivedByRoot[root] ?? []).map { (.derivedData, $0) }
            let artifacts = found.compactMap { kind, path -> ProjectArtifact? in
                guard let size = LiveStorageScanner.measure(path, home: home), size > 0 else {
                    return nil
                }
                return ProjectArtifact(kind: kind, path: path, size: size)
            }
            if !artifacts.isEmpty {
                let space = ProjectSpace(
                    root: root, name: (root as NSString).lastPathComponent, artifacts: artifacts, lastTouched: lastTouched(root)
                )
                spaces.append(space)
                report(space)
            }
        }
        progress(ordered.count, ordered.count)
        return spaces.sorted { $0.totalBytes != $1.totalBytes ? $0.totalBytes > $1.totalBytes : $0.root < $1.root }
    }

    /// A folder with a project marker is a project, and isn't looked inside for more.
    private static func findProjects(in folder: String, depth: Int, into roots: inout Set<String>) {
        let names = entries(folder)
        guard !names.isEmpty else {
            return
        }
        // A code folder that is itself a project (a monorepo at ~/dev) counts, but not for a
        // `.git` alone: a folder of repos can be one too.
        let markers = Set(names).intersection(ProjectSpaceRules.projectMarkers)
        let isProject = !markers.isEmpty || names.contains(where: isXcodeProject)
        if isProject, depth > 0 || markers != [".git"] {
            roots.insert(folder)
            return
        }
        guard depth < ProjectSpaceRules.searchDepth else {
            return
        }
        for name in names where !name.hasPrefix(".") && !ProjectSpaceRules.skipped.contains(name) {
            let path = folder + "/" + name
            if isDirectory(path), !isXcodeProject(name) {
                findProjects(in: path, depth: depth + 1, into: &roots)
            }
        }
    }

    private static func isXcodeProject(_ name: String) -> Bool {
        name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace")
    }

    /// Rebuildable folders, outermost only: nothing inside one is looked at.
    private static func findArtifacts(in folder: String, depth: Int, into found: inout [(ProjectArtifact.Kind, String)]) {
        let names = entries(folder)
        let siblings = Set(names)
        for name in names where name != ".git" && name != ".DS_Store" {
            let path = folder + "/" + name
            guard isDirectory(path) else {
                continue
            }
            if let kind = ProjectSpaceRules.kind(of: name, siblings: siblings, contains: { exists(path + "/" + $0) }) {
                found.append((kind, path))
            } else if depth < ProjectSpaceRules.artifactDepth, !["node_modules", "Pods", ".build"].contains(name), !isXcodeProject(name) {
                findArtifacts(in: path, depth: depth + 1, into: &found)
            }
        }
    }

    /// Each DerivedData folder's project, from the `WorkspacePath` Xcode writes in its info.plist.
    static func derivedData(home: String) -> [(project: String, folder: String)] {
        let root = home + "/Library/Developer/Xcode/DerivedData"
        return entries(root).compactMap { name in
            let folder = root + "/" + name
            guard let info = NSDictionary(contentsOfFile: folder + "/info.plist"),
                  let workspace = info["WorkspacePath"] as? String else {
                return nil
            }
            return (ProjectSpaceRules.derivedDataProject(workspacePath: workspace), folder)
        }
    }

    /// The newest of: the git index (a commit, a checkout, an editor's `git status`), git's
    /// HEAD log, and the project folder's own top-level entries.
    static func lastTouched(_ root: String) -> Date? {
        let top = entries(root).filter { $0 != ".DS_Store" && $0 != ".git" }.map { modified(root + "/" + $0) }
        return ProjectSpaceRules.lastTouched([modified(root + "/.git/index"), modified(root + "/.git/logs/HEAD"), modified(root)] + top)
    }

    /// A folder on disk, whatever the case or links in its path.
    struct FileID: Hashable {
        let device: Int32
        let inode: UInt64

        init?(_ path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else {
                return nil
            }
            device = info.st_dev
            inode = info.st_ino
        }
    }

    private static func entries(_ folder: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
    }

    /// A real folder, not a link to one: a symlinked folder is sized where it lives.
    private static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func modified(_ path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
    }
}

/// A fixed set of projects for previews, tests and Simulated data.
public struct SimulatedProjectSpaceScanner: ProjectSpaceScanning {
    private let now: Date

    public init(now: Date = Date()) {
        self.now = now
    }

    public func scan(
        progress: @escaping @Sendable (Int, Int) -> Void,
        found: @escaping @Sendable (ProjectSpace) -> Void
    ) async -> [ProjectSpace] {
        progress(4, 4)
        let home = "/Users/demo/Developer"
        let gb: UInt64 = 1_000_000_000
        return [
            ProjectSpace(root: home + "/storefront-web", name: "storefront-web", artifacts: [
                ProjectArtifact(kind: .nodeModules, path: home + "/storefront-web/node_modules", size: 1_840_000_000),
                ProjectArtifact(kind: .frameworkCache, path: home + "/storefront-web/.next", size: 610_000_000),
            ], lastTouched: now.addingTimeInterval(-3600)),
            ProjectSpace(root: home + "/ios-app", name: "ios-app", artifacts: [
                ProjectArtifact(kind: .derivedData, path: "/Users/demo/Library/Developer/Xcode/DerivedData/ios-app-abc", size: 6 * gb),
                ProjectArtifact(kind: .pods, path: home + "/ios-app/Pods", size: 820_000_000),
            ], lastTouched: now.addingTimeInterval(-95 * 86400)),
            ProjectSpace(root: home + "/ingest", name: "ingest", artifacts: [
                ProjectArtifact(kind: .rustTarget, path: home + "/ingest/target", size: 4_200_000_000),
            ], lastTouched: now.addingTimeInterval(-140 * 86400)),
            ProjectSpace(root: home + "/api", name: "api", artifacts: [
                ProjectArtifact(kind: .pythonEnvironment, path: home + "/api/.venv", size: 480_000_000),
                ProjectArtifact(kind: .pythonCaches, path: home + "/api/.mypy_cache", size: 62_000_000),
            ], lastTouched: now.addingTimeInterval(-2 * 86400)),
        ].sorted { $0.totalBytes > $1.totalBytes }
    }
}
