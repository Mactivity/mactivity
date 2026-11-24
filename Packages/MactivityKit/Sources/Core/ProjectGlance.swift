import Foundation

// Projects at a glance (D-279): each project folder with its language, the runtime version it
// asks for, its size and when it was last worked in. Language and version come from marker files
// only, read as text: no project's code or tools ever run.

public enum ProjectLanguage: String, CaseIterable, Hashable, Sendable {
    case swift, objectiveC, rust, go, typeScript, javaScript, python, ruby, java, kotlin, elixir, dart, zig, php, cAndCPP

    /// Language names, verbatim; only the one with an "and" in it translated.
    public var title: String {
        switch self {
        case .swift: "Swift"
        case .objectiveC: "Objective-C"
        case .rust: "Rust"
        case .go: "Go"
        case .typeScript: "TypeScript"
        case .javaScript: "JavaScript"
        case .python: "Python"
        case .ruby: "Ruby"
        case .java: "Java"
        case .kotlin: "Kotlin"
        case .elixir: "Elixir"
        case .dart: "Dart"
        case .zig: "Zig"
        case .php: "PHP"
        case .cAndCPP: String(localized: "C and C++", bundle: .strings, comment: "Build times: the tool family")
        }
    }
}

/// The runtime version a project asks for: what its files say, not what's installed.
public struct ProjectRuntimeVersion: Hashable, Sendable {
    /// "Node", "Python", "Swift tools".
    public let runtime: String
    /// As written: "20.11.0", ">=3.11", "lts/iron".
    public let version: String
    /// The file that says so: ".nvmrc", "go.mod".
    public let file: String

    public init(runtime: String, version: String, file: String) {
        self.runtime = runtime
        self.version = version
        self.file = file
    }
}

public struct ProjectGlance: Hashable, Sendable, Identifiable {
    public let root: String
    public let name: String
    /// Main language first; empty when no marker file says.
    public let languages: [ProjectLanguage]
    public let runtime: ProjectRuntimeVersion?
    /// The whole folder, as allocated on disk; nil until sized, or if it couldn't be.
    public let sizeBytes: UInt64?
    /// The last sign of work: `ProjectSpaceRules.lastTouched`'s, see `LiveProjectSpaceScanner`.
    public let lastWorked: Date?

    public var id: String {
        root
    }

    public init(
        root: String, name: String, languages: [ProjectLanguage], runtime: ProjectRuntimeVersion?, sizeBytes: UInt64?, lastWorked: Date?
    ) {
        self.root = root
        self.name = name
        self.languages = languages
        self.runtime = runtime
        self.sizeBytes = sizeBytes
        self.lastWorked = lastWorked
    }

    /// Most recently worked in first.
    public static func sorted(_ projects: [ProjectGlance]) -> [ProjectGlance] {
        projects.sorted { left, right in
            let (leftDate, rightDate) = (left.lastWorked ?? .distantPast, right.lastWorked ?? .distantPast)
            return leftDate != rightDate ? leftDate > rightDate : left.root < right.root
        }
    }
}

/// Live reads the disk; Simulated has a fixed set.
public protocol ProjectGlanceSource: Sendable {
    /// Every project. `update` gets the whole list as it fills in: first with no sizes, which is
    /// quick, then again as each folder is sized.
    func scan(update: @escaping @Sendable ([ProjectGlance]) -> Void) async -> [ProjectGlance]
}

/// One folder's file names, relative to the project: "" for the project itself.
public struct MarkerFolder: Hashable, Sendable {
    public let path: String
    public let names: Set<String>

    public init(path: String, names: Set<String>) {
        self.path = path
        self.names = names
    }

    func file(_ name: String) -> String {
        path.isEmpty ? name : path + "/" + name
    }
}

/// Pure: a project's language and runtime version from its marker files, with the file reader
/// passed in so fixtures stand in for the disk.
public enum ProjectMarkers {
    /// Folders never looked in for markers: what's inside them is someone else's project.
    public static let skippedFolders: Set<String> = [
        "node_modules", "Pods", "vendor", "target", "build", "dist", "out", "venv", "env", "__pycache__", "deps", "third_party", "Carthage",
    ]

    /// The languages a folder's names say, strongest evidence first: a compiled manifest over a
    /// `package.json`, which many projects have only for their tooling.
    public static func languages(in names: Set<String>) -> [ProjectLanguage] {
        var found: [ProjectLanguage] = []
        func add(_ language: ProjectLanguage, _ markers: String...) {
            if !found.contains(language), markers.contains(where: names.contains) {
                found.append(language)
            }
        }
        add(.swift, "Package.swift")
        if names.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
            // Either language builds with Xcode; its sources say which, if they're beside it.
            let objectiveC = names.contains { $0.hasSuffix(".m") || $0.hasSuffix(".mm") } && !names.contains { $0.hasSuffix(".swift") }
            let language: ProjectLanguage = objectiveC ? .objectiveC : .swift
            if !found.contains(language) {
                found.append(language)
            }
        }
        add(.rust, "Cargo.toml")
        add(.go, "go.mod")
        add(.elixir, "mix.exs")
        add(.dart, "pubspec.yaml")
        add(.zig, "build.zig")
        add(.java, "pom.xml", "build.gradle", "settings.gradle")
        add(.kotlin, "build.gradle.kts", "settings.gradle.kts")
        add(.python, "pyproject.toml", "setup.py", "requirements.txt", "Pipfile", ".python-version")
        add(.ruby, "Gemfile", ".ruby-version")
        add(.php, "composer.json")
        add(.typeScript, "tsconfig.json", "deno.json")
        if names.contains("package.json") || names.contains(".nvmrc") || names.contains(".node-version"), !found.contains(.typeScript) {
            found.append(.javaScript)
        }
        add(.cAndCPP, "CMakeLists.txt")
        return found
    }

    /// The project's languages and the runtime version of the first that states one. Folders come
    /// outermost first: the project's own markers win, and those deeper down count only when it
    /// has none (a repository with `Packages/Kit/Package.swift`, or a `website/package.json`).
    public static func inspect(
        folders: [MarkerFolder], read: (String) -> String?
    ) -> (languages: [ProjectLanguage], runtime: ProjectRuntimeVersion?) {
        let top = folders.first { $0.path.isEmpty }
        let own = top.map { languages(in: $0.names) } ?? []
        var ordered = own
        if ordered.isEmpty {
            func depth(_ folder: MarkerFolder) -> Int {
                folder.path.split(separator: "/").count
            }
            let nested = folders.filter { !$0.path.isEmpty }.sorted { (depth($0), $0.path) < (depth($1), $1.path) }
            for folder in nested {
                for language in languages(in: folder.names) where !ordered.contains(language) {
                    ordered.append(language)
                }
            }
        }
        for language in ordered {
            for folder in folders where folder.path.isEmpty || languages(in: folder.names).contains(language) {
                if let runtime = runtime(for: language, in: folder, read: read) {
                    return (ordered, runtime)
                }
            }
        }
        return (ordered, nil)
    }

    private static func runtime(
        for language: ProjectLanguage, in folder: MarkerFolder, read: (String) -> String?
    ) -> ProjectRuntimeVersion? {
        func text(_ name: String) -> String? {
            folder.names.contains(name) ? read(folder.file(name)) : nil
        }
        func result(_ runtime: String, _ version: String?, _ file: String) -> ProjectRuntimeVersion? {
            clean(version).map { ProjectRuntimeVersion(runtime: runtime, version: $0, file: file) }
        }
        func pinned(_ runtime: String, _ file: String) -> ProjectRuntimeVersion? {
            result(runtime, text(file).flatMap(Self.firstLine), file)
        }
        func managed(_ runtime: String, _ names: String...) -> ProjectRuntimeVersion? {
            for (file, parse) in [(".tool-versions", toolVersions), (".mise.toml", miseTools), ("mise.toml", miseTools)] {
                if let found = text(file).map(parse), let name = names.first(where: { found[$0] != nil }),
                   let runtime = result(runtime, found[name], file) {
                    return runtime
                }
            }
            return nil
        }
        switch language {
        case .swift, .objectiveC:
            return pinned("Swift", ".swift-version") ?? managed("Swift", "swift")
                ?? result("Swift tools", text("Package.swift").flatMap(swiftToolsVersion), "Package.swift")
                ?? folder.names.first { $0.hasSuffix(".xcodeproj") }.flatMap { project in
                    result("Swift", read(folder.file(project + "/project.pbxproj")).flatMap(xcodeSwiftVersion), project)
                }
        case .rust:
            return result("Rust", text("rust-toolchain").flatMap(rustToolchain), "rust-toolchain")
                ?? result("Rust", text("rust-toolchain.toml").flatMap(rustToolchain), "rust-toolchain.toml")
                ?? managed("Rust", "rust")
                ?? result("Rust", text("Cargo.toml").flatMap { tomlValue($0, key: "rust-version") }, "Cargo.toml")
        case .go:
            return pinned("Go", ".go-version") ?? managed("Go", "golang", "go")
                ?? result("Go", text("go.mod").flatMap(goVersion), "go.mod")
        case .typeScript, .javaScript:
            return pinned("Node", ".nvmrc") ?? pinned("Node", ".node-version") ?? managed("Node", "nodejs", "node")
                ?? result("Node", text("package.json").flatMap(nodeVersion), "package.json")
        case .python:
            return pinned("Python", ".python-version") ?? managed("Python", "python")
                ?? result("Python", text("pyproject.toml").flatMap { tomlValue($0, key: "requires-python") }, "pyproject.toml")
                ?? result("Python", text("Pipfile").flatMap { tomlValue($0, key: "python_version") }, "Pipfile")
                ?? result("Python", text("runtime.txt").flatMap(herokuPython), "runtime.txt")
        case .ruby:
            return pinned("Ruby", ".ruby-version") ?? managed("Ruby", "ruby")
                ?? result("Ruby", text("Gemfile").flatMap(gemfileRuby), "Gemfile")
        case .java, .kotlin:
            return pinned("Java", ".java-version") ?? managed("Java", "java")
                ?? result("Java", text(".sdkmanrc").flatMap { keyValue($0, key: "java") }, ".sdkmanrc")
                ?? result("Java", text("pom.xml").flatMap(pomJava), "pom.xml")
        case .elixir:
            return managed("Elixir", "elixir") ?? result("Elixir", text("mix.exs").flatMap(mixElixir), "mix.exs")
        case .dart:
            return result("Dart", text("pubspec.yaml").flatMap(pubspecSDK), "pubspec.yaml")
        case .zig:
            return pinned("Zig", ".zig-version") ?? managed("Zig", "zig")
        case .php:
            return pinned("PHP", ".php-version") ?? managed("PHP", "php")
                ?? result("PHP", text("composer.json").flatMap(composerPHP), "composer.json")
        case .cAndCPP:
            return nil
        }
    }

    // MARK: Parsers

    private static let versionCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-+*~^<>=|, _/!"))

    /// A version as it's written, or nil for anything that couldn't be one (a file holding
    /// something else shouldn't end up in a table).
    static func clean(_ version: String?) -> String? {
        guard let text = version?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= 40,
              text.unicodeScalars.allSatisfy(versionCharacters.contains),
              text.contains(where: \.isNumber) || text.hasPrefix("lts") || text.hasPrefix("stable")
              || text.hasPrefix("nightly") || text.hasPrefix("latest") || text.hasPrefix("beta") else {
            return nil
        }
        return text
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The first line with something on it, without a comment.
    static func firstLine(_ text: String) -> String? {
        lines(text).first { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { $0.split(separator: "#").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? $0 }
    }

    /// runtime.txt, as Heroku has it: "python-3.11.4".
    private static func herokuPython(_ text: String) -> String? {
        firstLine(text)?.replacingOccurrences(of: "python-", with: "")
    }

    /// `.tool-versions`: "nodejs 20.11.0", its first version when it names several.
    static func toolVersions(_ text: String) -> [String: String] {
        var tools: [String: String] = [:]
        for line in lines(text) where !line.hasPrefix("#") {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if words.count >= 2 {
                tools[String(words[0])] = tools[String(words[0])] ?? String(words[1])
            }
        }
        return tools
    }

    /// `mise.toml`'s `[tools]` table: `node = "20"`.
    static func miseTools(_ text: String) -> [String: String] {
        var tools: [String: String] = [:]
        var inTools = false
        for line in lines(text) {
            if line.hasPrefix("[") {
                inTools = line == "[tools]"
            } else if inTools, let equals = line.firstIndex(of: "=") {
                let value = line[line.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                tools[line[..<equals].trimmingCharacters(in: .whitespaces)] = value
            }
        }
        return tools
    }

    /// `key = "value"` in TOML, at any table: requires-python, rust-version, python_version.
    static func tomlValue(_ text: String, key: String) -> String? {
        for line in lines(text) where line.hasPrefix(key) {
            let rest = line.dropFirst(key.count).drop { $0 == " " || $0 == "\t" }
            guard rest.first == "=" else {
                continue
            }
            let value = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'" {
                return value.dropFirst().prefix { $0 != quote }.description
            }
        }
        return nil
    }

    private static func keyValue(_ text: String, key: String) -> String? {
        for line in lines(text) where line.hasPrefix(key + "=") {
            return String(line.dropFirst(key.count + 1))
        }
        return nil
    }

    /// `// swift-tools-version:6.0`, `// swift-tools-version: 5.9`, on the file's first line.
    static func swiftToolsVersion(_ text: String) -> String? {
        guard let first = lines(text).first, first.hasPrefix("//"), first.lowercased().contains("swift-tools-version"),
              let colon = first.firstIndex(of: ":") else {
            return nil
        }
        return first[first.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            .split(separator: ";").first.map(String.init)
    }

    /// An Xcode project's `SWIFT_VERSION = 6.0;`, the newest it names: a target left on an old one
    /// doesn't say what the project is on.
    static func xcodeSwiftVersion(_ text: String) -> String? {
        let versions = lines(text).compactMap { line -> String? in
            guard line.hasPrefix("SWIFT_VERSION = ") else {
                return nil
            }
            return String(line.dropFirst("SWIFT_VERSION = ".count)).trimmingCharacters(in: CharacterSet(charactersIn: "; \""))
        }
        return versions.max { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    /// go.mod's `toolchain go1.22.1` if it has one, else `go 1.22`.
    static func goVersion(_ text: String) -> String? {
        let all = lines(text)
        if let toolchain = all.first(where: { $0.hasPrefix("toolchain ") }) {
            let name = toolchain.dropFirst("toolchain ".count).trimmingCharacters(in: .whitespaces)
            return name.hasPrefix("go") ? String(name.dropFirst(2)) : name
        }
        return all.first { $0.hasPrefix("go ") }.map { $0.dropFirst(3).trimmingCharacters(in: .whitespaces) }
    }

    /// `rust-toolchain`: a bare channel, or TOML's `channel = "1.76"`.
    static func rustToolchain(_ text: String) -> String? {
        tomlValue(text, key: "channel") ?? (text.contains("[") ? nil : firstLine(text))
    }

    private static func json(_ text: String) -> [String: Any]? {
        text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    }

    /// package.json: Volta's pin, else `engines.node`.
    static func nodeVersion(_ text: String) -> String? {
        let object = json(text)
        return (object?["volta"] as? [String: Any])?["node"] as? String ?? (object?["engines"] as? [String: Any])?["node"] as? String
    }

    static func composerPHP(_ text: String) -> String? {
        (json(text)?["require"] as? [String: Any])?["php"] as? String
    }

    /// The text inside the quotes after `prefix` on a line: `ruby "3.2.2"`, `elixir: "~> 1.15"`.
    private static func quoted(after prefix: String, in text: String) -> String? {
        for line in lines(text) where line.hasPrefix(prefix) {
            let rest = line.dropFirst(prefix.count)
            guard let quote = rest.first(where: { $0 == "\"" || $0 == "'" }), let open = rest.firstIndex(of: quote) else {
                continue
            }
            return rest[rest.index(after: open)...].prefix { $0 != quote }.description
        }
        return nil
    }

    static func gemfileRuby(_ text: String) -> String? {
        quoted(after: "ruby ", in: text) ?? quoted(after: "ruby(", in: text)
    }

    static func mixElixir(_ text: String) -> String? {
        quoted(after: "elixir:", in: text)
    }

    /// pubspec.yaml's `environment: sdk:`.
    static func pubspecSDK(_ text: String) -> String? {
        quoted(after: "sdk:", in: text)
    }

    /// pom.xml's `<java.version>` or a compiler release, whichever comes first.
    static func pomJava(_ text: String) -> String? {
        for tag in ["java.version", "maven.compiler.release", "maven.compiler.source"] {
            if let open = text.range(of: "<\(tag)>"), let close = text.range(of: "</\(tag)>", range: open.upperBound ..< text.endIndex) {
                return String(text[open.upperBound ..< close.lowerBound])
            }
        }
        return nil
    }
}
