import Core
import Foundation
@testable import Projects
import Testing

/// Outdated Software (D-252): Homebrew's JSON, `brew vulns`, and the version managers' folders.
struct InstalledSoftwareParsingTests {
    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Fixtures.directory.appendingPathComponent(name))
    }

    @Test("brew info: the linked version, newer only when outdated, Homebrew's flags, runtimes")
    func homebrew() throws {
        let items = try InstalledSoftwareParsing.homebrew(fixture("brew-info-installed.json"))
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        #expect(items.count == 6)
        let openssl = try #require(byName["openssl@3"])
        #expect(openssl.version == "3.5.1")
        #expect(openssl.latest == "3.5.9")
        #expect(!openssl.onRequest)
        #expect(openssl.runtime == nil)
        let php = try #require(byName["php@8.1"])
        #expect(php.deprecation == InstalledSoftware.Deprecation(disabled: false, reason: "unsupported"))
        #expect(php.runtime == Runtime(kind: .php, cycle: "8.1"))
        #expect(php.latest == nil)
        #expect(byName["node"]?.version == "26.12.1")
        #expect(byName["node"]?.runtime == Runtime(kind: .node, cycle: "26"))
        #expect(byName["python@3.9"]?.deprecation?.disabled == true)
        // A cask that updates itself isn't outdated for Homebrew to fix; one that doesn't is.
        #expect(byName["firefox"]?.latest == nil)
        #expect(byName["visual-studio-code-old"]?.latest == "1.105.0")
        #expect(byName["visual-studio-code-old"]?.origin == .homebrewCask)
        #expect(byName["never-installed"] == nil && byName["not-installed"] == nil)
    }

    @Test("brew vulns: each formula's findings with OSV's severities, and what it skipped")
    func vulnerabilities() throws {
        let scan = try #require(InstalledSoftwareParsing.vulnerabilities(fixture("brew-vulns.json")))
        #expect(scan.found["c-ares"]?.map(\.severity) == [.high, .medium])
        #expect(scan.found["llama.cpp"]?.first?.severity == .unknown)
        #expect(scan.found["clean"] == nil)
        #expect(scan.skipped == ["mpdecimal", "python@3.14", "sqlite"])
        #expect(InstalledSoftwareParsing.vulnerabilities(Data("not json".utf8)) == nil)
    }

    @Test("brew upgrade --dry-run: the packages and versions it would change")
    func dryRun() {
        let text = """
        ==> Would upgrade 2 outdated packages:
        node 26.0.0 -> 26.12.1
        openssl@3 3.5.1 -> 3.5.9
        Warning: gh 2.103.0 already installed
        """
        #expect(InstalledSoftwareParsing.upgradePlan(text) == ["node 26.0.0 → 26.12.1", "openssl@3 3.5.1 → 3.5.9"])
    }

    @Test("Version managers' folders: versions, not aliases; each tool's runtime")
    func versionManagers() {
        #expect(InstalledSoftwareParsing.version(folder: "v20.11.1") == "20.11.1")
        #expect(InstalledSoftwareParsing.version(folder: "3.9.18") == "3.9.18")
        #expect(InstalledSoftwareParsing.version(folder: "miniconda3-latest") == nil)
        #expect(InstalledSoftwareParsing.version(folder: "lts") == nil)
        #expect(InstalledSoftwareParsing.version(folder: "20") == nil)
        let node = InstalledSoftwareParsing.runtime(folder: "v18.19.0", kind: .node, origin: .nvm)
        #expect(node?.runtime == Runtime(kind: .node, cycle: "18"))
        #expect(node?.title == "Node.js 18")
        #expect(InstalledSoftwareParsing.kind(tool: "nodejs") == .node)
        #expect(InstalledSoftwareParsing.kind(tool: "postgres") == .postgresql)
        #expect(InstalledSoftwareParsing.kind(tool: "terraform") == nil)
    }

    @Test("A runtime from version-manager folders on disk, aliases left out")
    func onDisk() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("software-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let files = FileManager.default
        for path in [".pyenv/versions/3.9.18", ".nvm/versions/node/v22.4.0", ".local/share/mise/installs/node/20.11.1"] {
            try files.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try files.createSymbolicLink(
            atPath: home.appendingPathComponent(".local/share/mise/installs/node/20.11").path,
            withDestinationPath: "20.11.1"
        )
        let found = LiveInstalledSoftware(home: home.path).versionManagers()
        #expect(Set(found.map(\.id)) == ["pyenv:python@3.9.18", "nvm:node@22.4.0", "mise:node@20.11.1"])
    }

    @Test("The command for each place it came from")
    func commands() {
        let brew = InstalledSoftware(name: "node", version: "26.0.0", origin: .homebrew)
        #expect(InstalledSoftwareParsing.command(for: brew) == "brew upgrade node")
        let mise = InstalledSoftware(name: "node", version: "20.1.0", origin: .mise, runtime: Runtime(kind: .node, cycle: "20"))
        #expect(InstalledSoftwareParsing.command(for: mise) == "mise use --global nodejs@latest")
        #expect(InstalledSoftwareParsing.command(for: InstalledSoftware(name: "python3", version: "3.9.6", origin: .apple)) == nil)
    }

    @Test("Apps carrying an old Sparkle are found; one with a current Sparkle or none isn't (D-257)")
    func oldUpdaters() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("updaters-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        func app(_ name: String, sparkle: String?) throws {
            let contents = home.appendingPathComponent("Applications/\(name).app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try (["CFBundleShortVersionString": "3.1"] as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
            if let sparkle {
                let resources = contents.appendingPathComponent("Frameworks/Sparkle.framework/Resources")
                try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
                try (["CFBundleShortVersionString": sparkle] as NSDictionary).write(to: resources.appendingPathComponent("Info.plist"))
            }
        }
        try app("Old", sparkle: "2.6.1")
        try app("Current", sparkle: "2.10.0")
        try app("Plain", sparkle: nil)
        let found = LiveInstalledSoftware(home: home.path).appsWithOldUpdaters(home: home.path)
            .filter { $0.path?.hasPrefix(home.path) == true }
        #expect(found.map(\.name) == ["Old"])
        #expect(found.first?.component == "Sparkle 2.6.1")
        #expect(found.first?.version == "3.1")
        #expect(LiveInstalledSoftware.homebrewVersion(Data("Homebrew 7.0.10-37-g1ef73bb\n".utf8)) == "7.0.10-37-g1ef73bb")
        #expect(LiveInstalledSoftware.homebrewVersion(Data("command not found".utf8)) == nil)
    }
}
