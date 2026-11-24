import Core
import Foundation

/// Each compiler process in a snapshot with the project it runs in (D-209), for build times. A
/// process's folder is read once, when it's first seen, and each folder's project once: an Xcode
/// build runs its compilers in the project (`…/Mactivity/Mactivity.xcodeproj`), cargo and go in
/// the crate or module.
public struct CompilerLocator {
    private var projects: [Int32: String?] = [:]
    private var folders: [String: String] = [:]

    public init() {}

    public mutating func compilers(in snapshot: Snapshot) -> [CompilerProcess] {
        let found = snapshot.processes.filter { BuildTracker.family($0.name) != nil }
        let running = Set(found.map(\.pid))
        projects = projects.filter { running.contains($0.key) }
        return found.map { process in
            CompilerProcess(
                pid: process.pid, name: process.name, project: project(of: process.pid),
                cpuPercent: process.cpuPercent, memory: process.footprintBytes
            )
        }
    }

    /// A dependency being compiled for a build, not a project: cargo runs rustc inside each
    /// crate's own folder, Go its compiler in the module cache, and both folders have a manifest.
    /// Their compilers join the build that's running instead.
    static func isDependency(_ directory: String, home: String) -> Bool {
        let caches = [home + "/.cargo/registry/", home + "/.cargo/git/", home + "/go/pkg/mod/", "/usr/local/go/", "/opt/homebrew/"]
        let parts = ["/node_modules/", "/SourcePackages/checkouts/", "/pkg/mod/"]
        let path = directory.hasSuffix("/") ? directory : directory + "/"
        return caches.contains { path.hasPrefix($0) } || parts.contains { path.contains($0) }
    }

    private mutating func project(of pid: Int32) -> String? {
        if let known = projects[pid] {
            return known
        }
        let home = NSHomeDirectory()
        let project = ProcessInspector.workingDirectory(pid).flatMap { directory -> String? in
            guard directory != home, directory != "/", !Self.isDependency(directory, home: home) else {
                return nil
            }
            if let name = folders[directory] {
                return name
            }
            let name = LiveAgentSource.projectName(directory)
            if folders.count > 500 {
                folders = [:]
            }
            folders[directory] = name
            return name
        }
        projects[pid] = project
        return project
    }
}
