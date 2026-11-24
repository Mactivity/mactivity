import Core
import Darwin
import Foundation

/// Projects at a glance from the disk (D-279): the same project roots as Space per project, each
/// one's marker files read as text, its whole folder sized as Storage sizes everything, and its
/// last sign of work from the same four modified times Space uses. Reads only; runs nothing.
public struct LiveProjectGlance: ProjectGlanceSource {
    private let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    public func scan(update: @escaping @Sendable ([ProjectGlance]) -> Void) async -> [ProjectGlance] {
        let home = home
        // Stops with the view: the scan checks for it before each folder.
        let scan = Task.detached(priority: .utility) {
            Self.scan(home: home, update: update)
        }
        return await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
    }

    static func scan(home: String, update: ([ProjectGlance]) -> Void = { _ in }) -> [ProjectGlance] {
        // The quick part first: names, marker files and modified times.
        var projects = LiveProjectSpaceScanner.roots(home: home).ordered.map { root in
            let markers = inspect(root)
            return ProjectGlance(
                root: root, name: (root as NSString).lastPathComponent, languages: markers.languages, runtime: markers.runtime,
                sizeBytes: nil, lastWorked: LiveProjectSpaceScanner.lastTouched(root)
            )
        }
        projects = ProjectGlance.sorted(projects)
        update(projects)
        var lastUpdate = Date()
        for index in projects.indices {
            if Task.isCancelled {
                break
            }
            let project = projects[index]
            projects[index] = ProjectGlance(
                root: project.root, name: project.name, languages: project.languages, runtime: project.runtime,
                sizeBytes: LiveStorageScanner.measure(project.root, home: home), lastWorked: project.lastWorked
            )
            if Date().timeIntervalSince(lastUpdate) >= 0.5 {
                update(projects)
                lastUpdate = Date()
            }
        }
        update(projects)
        return projects
    }

    /// Marker files in the project and two levels under it: a repository's `Packages/Kit` is two.
    static func inspect(_ root: String) -> (languages: [ProjectLanguage], runtime: ProjectRuntimeVersion?) {
        ProjectMarkers.inspect(folders: markerFolders(root)) { relative in
            readStart(root + "/" + relative)
        }
    }

    static func markerFolders(_ root: String) -> [MarkerFolder] {
        var folders: [MarkerFolder] = []
        // A project with thousands of folders at its top isn't helped by reading them all.
        var budget = 300
        func visit(_ path: String, depth: Int) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: path.isEmpty ? root : root + "/" + path)) ?? []
            folders.append(MarkerFolder(path: path, names: Set(names)))
            guard depth < 2 else {
                return
            }
            for name in names.sorted() where !name.hasPrefix(".") && !ProjectMarkers.skippedFolders.contains(name)
                && !name.hasSuffix(".xcodeproj") && !name.hasSuffix(".xcworkspace") && !name.hasSuffix(".app") {
                let child = path.isEmpty ? name : path + "/" + name
                var info = stat()
                guard budget > 0, lstat(root + "/" + child, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                    continue
                }
                budget -= 1
                visit(child, depth: depth + 1)
            }
        }
        visit("", depth: 0)
        return folders
    }

    /// The start of a file: marker files are small. An Xcode project's isn't, and its versions are
    /// near the end, so up to a megabyte.
    private static func readStart(_ path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let handle = FileHandle(forReadingAtPath: path), let data = try? handle.read(upToCount: 1 << 20) else {
            return nil
        }
        try? handle.close()
        return String(bytes: data, encoding: .utf8)
    }
}
