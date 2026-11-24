import Foundation
@testable import Storage
import Testing

/// Space per project (D-223).
struct ProjectSpaceTests {
    @Test("A folder counts only when its tool marks it")
    func kinds() {
        func kind(_ name: String, _ siblings: Set<String>, inside: Set<String> = []) -> ProjectArtifact.Kind? {
            ProjectSpaceRules.kind(of: name, siblings: siblings, contains: inside.contains)
        }
        #expect(kind("node_modules", ["package.json"]) == .nodeModules)
        #expect(kind("node_modules", ["README.md"]) == nil)
        #expect(kind(".next", ["package.json"]) == .frameworkCache)
        #expect(kind(".next", []) == nil)
        #expect(kind(".build", ["Package.swift"]) == .swiftBuild)
        #expect(kind("target", ["Cargo.toml"]) == .rustTarget)
        #expect(kind("target", ["pom.xml"]) == .mavenTarget)
        #expect(kind("target", []) == nil)
        #expect(kind("build", ["build.gradle.kts"]) == .gradleBuild)
        // A plain build or dist folder may be checked in: never offered.
        #expect(kind("build", ["package.json"]) == nil)
        #expect(kind("dist", ["package.json"]) == nil)
        #expect(kind("build", ["CMakeLists.txt"]) == nil)
        #expect(kind("build", ["CMakeLists.txt"], inside: ["CMakeCache.txt"]) == .cmakeBuild)
        // A virtual environment has pyvenv.cfg; a .env file or folder of secrets doesn't.
        #expect(kind(".venv", [], inside: ["pyvenv.cfg"]) == .pythonEnvironment)
        #expect(kind(".env", ["package.json"]) == nil)
        #expect(kind("deps", ["mix.exs"]) == .elixirBuild)
        #expect(kind("deps", ["package.json"]) == nil)
        #expect(kind("zig-out", ["build.zig"]) == .zigCache)
        #expect(kind(".terraform", ["main.tf"]) == .terraform)
        #expect(kind("DerivedData.noindex", [], inside: ["ModuleCache.noindex"]) == .derivedData)
    }

    @Test("Outermost roots only, each folder once")
    func outermost() {
        #expect(ProjectSpaceRules.outermost(["/a/sub", "/a", "/b", "/ab"]) == ["/a", "/ab", "/b"])
        #expect(ProjectSpaceRules.outermost(["/x/Code/app", "/x/code/app"]) { $0.lowercased() == $1.lowercased() }.count == 1)
        #expect(ProjectSpaceRules.isProtected("/Users/a/Documents/GitHub/x", home: "/Users/a"))
        #expect(!ProjectSpaceRules.isProtected("/Users/a/DocumentsArchive", home: "/Users/a"))
    }

    @Test("DerivedData's workspace path gives the project folder")
    func derivedDataProject() {
        #expect(ProjectSpaceRules.derivedDataProject(workspacePath: "/Users/a/Developer/App/App.xcodeproj") == "/Users/a/Developer/App")
        #expect(ProjectSpaceRules.derivedDataProject(workspacePath: "/Users/a/Developer/Kit") == "/Users/a/Developer/Kit")
    }

    @Test("Stale after two months without a sign of work")
    func stale() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let space = { (days: Double) in
            ProjectSpace(root: "/p", name: "p", artifacts: [], lastTouched: now.addingTimeInterval(-days * 86400))
        }
        #expect(!space(59).isStale(now: now))
        #expect(space(60).isStale(now: now))
        #expect(!ProjectSpace(root: "/p", name: "p", artifacts: [], lastTouched: nil).isStale(now: now))
    }

    @Test("The scanner finds projects in code folders and their outermost output, and no more")
    func scan() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectSpace-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        func file(_ path: String, bytes: Int = 10) throws {
            let full = home + "/" + path
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(repeating: 1, count: bytes).write(to: URL(fileURLWithPath: full))
        }
        try file("Developer/web/package.json")
        try file("Developer/web/node_modules/react/index.js", bytes: 50000)
        try file("Developer/web/node_modules/react/node_modules/x/index.js", bytes: 50000)
        try file("Developer/web/packages/ui/package.json")
        try file("Developer/web/packages/ui/node_modules/y/index.js", bytes: 50000)
        try file("Developer/web/dist/app.js", bytes: 50000)
        try file("Developer/client/tool/Cargo.toml")
        try file("Developer/client/tool/target/debug/tool", bytes: 90000)
        try file("Developer/notes/README.md")
        try file("Developer/elsewhere/App.xcodeproj/project.pbxproj")
        // Found through both ~/Code and ~/code: one folder on a disk that ignores case.
        try file("Code/app/package.json")
        try file("Code/app/node_modules/x/index.js", bytes: 20000)
        // Behind macOS's permission without Full Disk Access: left alone.
        try file("Documents/GitHub/private/package.json")
        try file("Documents/GitHub/private/node_modules/x/index.js", bytes: 20000)
        let derived = home + "/Library/Developer/Xcode/DerivedData/App-abc"
        try file("Library/Developer/Xcode/DerivedData/App-abc/Build/x", bytes: 70000)
        let info: NSDictionary = ["WorkspacePath": home + "/Developer/elsewhere/App.xcodeproj"]
        info.write(toFile: derived + "/info.plist", atomically: true)

        let spaces = LiveProjectSpaceScanner.scan(home: home) { _, _ in }
        let byName = Dictionary(uniqueKeysWithValues: spaces.map { ($0.name, $0) })
        #expect(spaces.map(\.name).sorted() == ["app", "elsewhere", "tool", "web"])
        let web = try #require(byName["web"])
        #expect(Set(web.artifacts.map { $0.relativePath(in: web.root) }) == ["node_modules", "packages/ui/node_modules"])
        #expect(byName["tool"]?.artifacts.map(\.kind) == [.rustTarget])
        #expect(byName["elsewhere"]?.artifacts.map(\.path) == [derived])
        #expect(web.lastTouched != nil)
    }
}
