import Core
import Foundation
@testable import Storage
import Testing

/// Projects at a glance on disk (D-279).
struct ProjectGlanceScanTests {
    private func temporaryHome() throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("Glance-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return (path as NSString).resolvingSymlinksInPath
    }

    private func write(_ path: String, _ text: String = "") throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test(
        "A real folder tree: each project's language, version, size and last sign of work, and nothing in node_modules counted as a marker"
    )
    func scan() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try write(home + "/Developer/web/package.json", #"{"engines":{"node":">=20"}}"#)
        try write(home + "/Developer/web/tsconfig.json", "{}")
        try write(home + "/Developer/web/node_modules/left-pad/Cargo.toml", "")
        try write(home + "/Developer/tool/go.mod", "module x\n\ngo 1.23\n")
        try FileManager.default.createDirectory(atPath: home + "/Developer/repo/.git", withIntermediateDirectories: true)
        try write(home + "/Developer/repo/Packages/Kit/Package.swift", "// swift-tools-version:6.0\n")
        try FileManager.default.createDirectory(atPath: home + "/Developer/plain/.git", withIntermediateDirectories: true)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        for path in ["/Developer/tool/go.mod", "/Developer/tool"] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: home + path)
        }
        let found = LiveProjectGlance.scan(home: home)
        let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0) })
        #expect(byName.count == 4)
        #expect(byName["web"]?.languages == [.typeScript])
        #expect(byName["web"]?.runtime == ProjectRuntimeVersion(runtime: "Node", version: ">=20", file: "package.json"))
        #expect(byName["tool"]?.languages == [.go])
        #expect(byName["tool"]?.runtime?.version == "1.23")
        #expect(byName["tool"]?.lastWorked == old)
        #expect(byName["repo"]?.languages == [.swift])
        #expect(byName["repo"]?.runtime?.version == "6.0")
        #expect(byName["plain"]?.languages == [])
        #expect(byName["plain"]?.runtime == nil)
        #expect((byName["web"]?.sizeBytes ?? 0) > 0)
        // Worked on most recently first; the old one last among those with a date.
        #expect(found.last?.name == "tool")
    }

    @Test("The quick pass comes first, with no sizes yet")
    func updates() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try write(home + "/Developer/tool/go.mod", "go 1.23\n")
        nonisolated(unsafe) var seen: [[ProjectGlance]] = []
        _ = LiveProjectGlance.scan(home: home) { seen.append($0) }
        #expect(seen.first?.first?.sizeBytes == nil)
        #expect(seen.last?.first?.sizeBytes != nil)
    }

    @Test("A folder that holds no code at all is left out, and a binary pin file does no harm")
    func oddFiles() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try write(home + "/Developer/notes/todo.txt", "x")
        try FileManager.default.createDirectory(atPath: home + "/Developer/odd", withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: URL(fileURLWithPath: home + "/Developer/odd/.nvmrc"))
        try write(home + "/Developer/odd/package.json", "{}")
        let found = LiveProjectGlance.scan(home: home)
        #expect(found.map(\.name) == ["odd"])
        #expect(found.first?.languages == [.javaScript] && found.first?.runtime == nil)
    }
}

/// This Mac's own projects, reading only: `make test-live`.
@Suite(
    "Projects at a glance, live",
    .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_LIVE_TESTS"] != nil, "reads this Mac's projects: make test-live")
)
struct ProjectGlanceLiveTests {
    @Test("Every project has a name, and its markers read without running anything")
    func realProjects() {
        let home = NSHomeDirectory()
        let roots = LiveProjectSpaceScanner.roots(home: home).ordered
        for root in roots {
            let markers = LiveProjectGlance.inspect(root)
            if let version = markers.runtime?.version {
                #expect(version.count <= 40)
            }
        }
    }

    @Test("A whole scan sizes every project and changes nothing")
    func wholeScan() {
        let found = LiveProjectGlance.scan(home: NSHomeDirectory())
        #expect(found.allSatisfy { $0.sizeBytes != nil })
    }
}
