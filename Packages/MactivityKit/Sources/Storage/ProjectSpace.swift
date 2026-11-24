import Foundation

/// Space per project (1.4, D-223): the folders a project's tools rebuild or download again
/// (node_modules, .build, target, a Python environment, Xcode's DerivedData), sized for each
/// project, with the projects you haven't touched in a while marked. Showing, not cleaning
/// (spec 3): a folder goes to the Trash only through the storage confirm step.
public struct ProjectSpace: Sendable, Hashable, Identifiable {
    public let root: String
    public let name: String
    /// Largest first.
    public let artifacts: [ProjectArtifact]
    /// The last sign of work in it: a commit, a `git status`, a file added at the top.
    public let lastTouched: Date?

    public var id: String {
        root
    }

    public var totalBytes: UInt64 {
        artifacts.reduce(0) { $0 &+ $1.size }
    }

    public init(root: String, name: String, artifacts: [ProjectArtifact], lastTouched: Date?) {
        self.root = root
        self.name = name
        self.artifacts = artifacts.sorted { $0.size != $1.size ? $0.size > $1.size : $0.path < $1.path }
        self.lastTouched = lastTouched
    }

    /// Untouched for `ProjectSpaceRules.staleAfter` or longer.
    public func isStale(now: Date) -> Bool {
        lastTouched.map { now.timeIntervalSince($0) >= ProjectSpaceRules.staleAfter } ?? false
    }
}

/// One rebuildable folder in a project.
public struct ProjectArtifact: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case nodeModules, frameworkCache, swiftBuild, rustTarget, mavenTarget, gradleBuild, gradleCache
        case pythonEnvironment, pythonCaches, pods, derivedData, elixirBuild, zigCache, dartTool, terraform, cmakeBuild
    }

    public let kind: Kind
    public let path: String
    public let size: UInt64

    public var id: String {
        path
    }

    /// The folder's own name, relative to the project: "node_modules", "packages/web/.next".
    public func relativePath(in root: String) -> String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : (path as NSString).lastPathComponent
    }

    public init(kind: Kind, path: String, size: UInt64) {
        self.kind = kind
        self.path = path
        self.size = size
    }
}

/// Pure rules: which folders are a project's rebuildable output, where projects are, and when
/// one is stale. The file system comes in as closures, so fixtures stand in for it.
public enum ProjectSpaceRules {
    /// Two months without a sign of work.
    public static let staleAfter: TimeInterval = 60 * 86400

    /// Folders in the home folder where people keep code. Projects elsewhere still come in
    /// through Xcode's DerivedData, which records each workspace's path.
    public static let searchFolders = [
        "Developer", "Projects", "projects", "Code", "code", "src", "dev", "Dev", "Sites", "GitHub", "github", "git", "repos",
        "Repos", "workspace", "Workspace", "work", "Documents/GitHub", "Documents/Projects", "Documents/Code",
    ]

    /// How deep below a search folder a project may sit: ~/Developer/client/app is two.
    public static let searchDepth = 3

    /// How deep inside a project rebuildable folders are looked for: a monorepo's
    /// packages/web/node_modules is three.
    public static let artifactDepth = 3

    /// Files or folders that make a folder a project.
    public static let projectMarkers = [
        ".git", "package.json", "Package.swift", "Cargo.toml", "go.mod", "pyproject.toml", "requirements.txt", "Gemfile", "pom.xml",
        "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "Podfile", "mix.exs", "pubspec.yaml",
        "build.zig", "CMakeLists.txt", "deno.json", "composer.json",
    ]

    /// Home folders macOS asks permission for, read only with Full Disk Access.
    static let protectedFolders = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"]

    public static func isProtected(_ path: String, home: String) -> Bool {
        protectedFolders.contains { path == home + "/" + $0 || path.hasPrefix(home + "/" + $0 + "/") }
    }

    /// Each root once, outermost only: a root inside another, or the same folder by another
    /// spelling, is dropped, so no folder is counted in two projects.
    public static func outermost(_ roots: [String], sameFolder: (String, String) -> Bool = { $0 == $1 }) -> [String] {
        var kept: [String] = []
        for root in roots.sorted(by: { ($0.count, $0) < ($1.count, $1) }) {
            let covered = kept.contains { root == $0 || root.hasPrefix($0 + "/") || sameFolder(root, $0) }
            if !covered {
                kept.append(root)
            }
        }
        return kept.sorted()
    }

    /// Folders never walked into while looking for projects or their output.
    static let skipped: Set<String> = [".git", "Library", ".Trash", "Applications", "Pictures", "Music", "Movies"]

    /// The kind of rebuildable folder `name` is, given the files beside it (`siblings`, the names
    /// in its parent) and what's inside it (`contains`). Nil for anything that may hold work:
    /// a plain `build` or `dist` can be checked in, so only ones their tool marks count.
    public static func kind(of name: String, siblings: Set<String>, contains: (String) -> Bool) -> ProjectArtifact.Kind? {
        let gradle = siblings.contains { $0.hasPrefix("build.gradle") || $0.hasPrefix("settings.gradle") }
        switch name {
        case "node_modules" where siblings.contains("package.json"):
            return .nodeModules
        // `where` binds to one pattern only, so lists of names check their condition inside.
        case ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".angular", ".expo", ".vite":
            return siblings.contains("package.json") ? .frameworkCache : nil
        case ".build" where siblings.contains("Package.swift"):
            return .swiftBuild
        case "target" where siblings.contains("Cargo.toml"):
            return .rustTarget
        case "target" where siblings.contains("pom.xml"):
            return .mavenTarget
        case "build" where gradle:
            return .gradleBuild
        case ".gradle" where gradle:
            return .gradleCache
        case "build" where siblings.contains("pubspec.yaml"):
            return .gradleBuild
        case ".dart_tool" where siblings.contains("pubspec.yaml"):
            return .dartTool
        case "build" where siblings.contains("CMakeLists.txt") && contains("CMakeCache.txt"):
            return .cmakeBuild
        case ".venv", "venv", "env", ".env":
            return contains("pyvenv.cfg") ? .pythonEnvironment : nil
        case ".tox", ".mypy_cache", ".pytest_cache", ".ruff_cache", ".nox":
            return siblings.contains { ["pyproject.toml", "setup.py", "requirements.txt", "tox.ini", "setup.cfg"].contains($0) }
                ? .pythonCaches : nil
        case "Pods" where siblings.contains("Podfile"):
            return .pods
        case "_build", "deps":
            return siblings.contains("mix.exs") ? .elixirBuild : nil
        case ".zig-cache", "zig-cache", "zig-out":
            return siblings.contains("build.zig") ? .zigCache : nil
        case ".terraform" where siblings.contains { $0.hasSuffix(".tf") }:
            return .terraform
        default:
            // An Xcode build folder of any name (`xcodebuild -derivedDataPath build/DerivedData`).
            return contains("ModuleCache.noindex") || contains("Index.noindex") ? .derivedData : nil
        }
    }

    /// The project an Xcode DerivedData folder builds, from its info.plist's `WorkspacePath`:
    /// the folder holding the .xcodeproj or .xcworkspace, or the package itself.
    public static func derivedDataProject(workspacePath: String) -> String {
        let name = (workspacePath as NSString).lastPathComponent
        if name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace") {
            return (workspacePath as NSString).deletingLastPathComponent
        }
        return workspacePath
    }

    /// The latest of `dates`: the newest sign of work.
    public static func lastTouched(_ dates: [Date?]) -> Date? {
        dates.compactMap(\.self).max()
    }

    /// What the folder is, in a few words.
    public static func title(_ kind: ProjectArtifact.Kind) -> String {
        switch kind {
        case .nodeModules: String(localized: "JavaScript packages", bundle: .strings, comment: "Space per project: what node_modules is")
        case .frameworkCache: String(localized: "Framework cache", bundle: .strings, comment: "Space per project: .next, .nuxt, .turbo…")
        case .swiftBuild: String(localized: "SwiftPM build", bundle: .strings, comment: "Space per project: a .build folder")
        case .rustTarget: String(localized: "Cargo build", bundle: .strings, comment: "Space per project: a Rust target folder")
        case .mavenTarget: String(localized: "Maven build", bundle: .strings, comment: "Space per project: a Maven target folder")
        case .gradleBuild, .cmakeBuild: String(localized: "Build output", bundle: .strings, comment: "Space per project: a build folder")
        case .gradleCache: String(localized: "Gradle cache", bundle: .strings, comment: "Space per project: a .gradle folder")
        case .pythonEnvironment: String(localized: "Python environment", bundle: .strings, comment: "Space per project: a virtualenv")
        case .pythonCaches: String(localized: "Test and lint caches", bundle: .strings, comment: "Space per project: .tox, .mypy_cache…")
        case .pods: String(localized: "CocoaPods", bundle: .strings, comment: "Space per project: a Pods folder")
        case .derivedData: String(
                localized: "Xcode DerivedData",
                bundle: .strings,
                comment: "Developer lens row; DerivedData is a folder name"
            )
        case .elixirBuild: String(localized: "Mix build and deps", bundle: .strings, comment: "Space per project: Elixir's _build and deps")
        case .zigCache: String(localized: "Zig cache", bundle: .strings, comment: "Space per project: Zig's cache folders")
        case .dartTool: String(localized: "Dart tools", bundle: .strings, comment: "Space per project: a .dart_tool folder")
        case .terraform: String(localized: "Terraform providers", bundle: .strings, comment: "Space per project: a .terraform folder")
        }
    }

    /// What getting the folder back costs, for the confirm step and the row's help.
    public static func note(_ kind: ProjectArtifact.Kind) -> String {
        switch kind {
        case .nodeModules:
            DeveloperLens.nodeModulesNote
        case .frameworkCache:
            String(
                localized: "The framework's build cache. The next dev server start or build makes it again, more slowly.",
                bundle: .strings,
                comment: "Space per project: what trashing .next, .nuxt, .turbo and similar costs"
            )
        case .swiftBuild:
            String(
                localized: "SwiftPM's build folder. The next `swift build` fetches packages and compiles from scratch.",
                bundle: .strings,
                comment: "Space per project: what trashing .build costs. Keep text in backticks (commands) as is."
            )
        case .rustTarget:
            String(
                localized: "Cargo's build output. The next `cargo build` compiles everything again, often for minutes.",
                bundle: .strings,
                comment: "Space per project: what trashing a Rust target folder costs. Keep text in backticks (commands) as is."
            )
        case .mavenTarget, .gradleBuild, .cmakeBuild:
            String(
                localized: "Build output. The next build makes it again from the sources.",
                bundle: .strings,
                comment: "Space per project: what trashing a build or target folder costs"
            )
        case .gradleCache:
            String(
                localized: "Gradle's per-project cache. The next build makes it again.",
                bundle: .strings,
                comment: "Space per project: what trashing .gradle costs"
            )
        default:
            otherNote(kind)
        }
    }

    private static func otherNote(_ kind: ProjectArtifact.Kind) -> String {
        switch kind {
        case .pythonEnvironment:
            String(
                localized: """
                A Python environment. Recreate it and reinstall its packages, e.g. with `uv sync` or \
                `pip install -r requirements.txt`.
                """,
                bundle: .strings,
                comment: "Space per project: what trashing a virtual environment costs. Keep text in backticks (commands) as is."
            )
        case .pythonCaches:
            String(
                localized: "Caches of test and lint tools. They fill again on the next run.",
                bundle: .strings,
                comment: "Space per project: what trashing .tox, .mypy_cache and similar costs"
            )
        case .pods:
            String(
                localized: "CocoaPods' downloads. `pod install` restores them from the Podfile.lock.",
                bundle: .strings,
                comment: "Space per project: what trashing Pods costs. Keep text in backticks (commands) as is."
            )
        case .derivedData:
            String(
                localized: "Xcode's build products and index for this project. The next build and indexing are slower.",
                bundle: .strings,
                comment: "Space per project: what trashing a project's DerivedData costs"
            )
        case .elixirBuild:
            String(
                localized: "Mix's dependencies and build output. `mix deps.get` and the next compile restore them.",
                bundle: .strings,
                comment: "Space per project: what trashing _build or deps costs. Keep text in backticks (commands) as is."
            )
        case .zigCache:
            String(
                localized: "Zig's cache and output. The next `zig build` makes them again.",
                bundle: .strings,
                comment: "Space per project: what trashing Zig's cache costs. Keep text in backticks (commands) as is."
            )
        case .dartTool:
            String(
                localized: "Dart's tool cache. `flutter pub get` restores it.",
                bundle: .strings,
                comment: "Space per project: what trashing .dart_tool costs. Keep text in backticks (commands) as is."
            )
        case .terraform:
            String(
                localized: "Downloaded providers and modules. `terraform init` downloads them again.",
                bundle: .strings,
                comment: "Space per project: what trashing .terraform costs. Keep text in backticks (commands) as is."
            )
        default:
            DeveloperLens.nodeModulesNote
        }
    }
}

/// Finds projects and sizes their rebuildable folders. Live reads the disk; Simulated has a
/// fixed set for previews and tests.
public protocol ProjectSpaceScanning: Sendable {
    /// Every project with something to show, most space first. `progress` gets (done, total).
    /// `found` gets each project as it's sized, so a first scan can show them as they come.
    func scan(progress: @escaping @Sendable (Int, Int) -> Void, found: @escaping @Sendable (ProjectSpace) -> Void) async -> [ProjectSpace]
}
