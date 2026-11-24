import Core
import Darwin
import Foundation

/// Background dev tools (1.4, D-228): language servers, file watchers and test runners, with the
/// project each works for, and the ones left behind: their editor or terminal is gone, so
/// nothing will stop them. Quitting one goes through `ConfirmedAction`.
public struct DevTool: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case languageServer, watcher, testRunner
    }

    public let pid: Int32
    /// "rust-analyzer", "TypeScript server".
    public let name: String
    public let kind: Kind
    /// The project folder's name, and its path.
    public let project: String?
    public let directory: String?
    public let startedAt: Date?
    public let memoryBytes: UInt64
    public let cpuSeconds: Double
    /// What started it: "Code Helper (Plugin)", "zsh"; nil once that's gone.
    public let parent: String?

    public var id: Int32 {
        pid
    }

    /// Its editor or terminal quit: launchd took it over, and nothing will stop it. Daemons that
    /// detach on purpose, serving every project (watchman, eslint_d, prettierd), aren't.
    public var isLeftBehind: Bool {
        parent == nil && !DevToolRules.daemons.contains(name)
    }

    public init(
        pid: Int32, name: String, kind: Kind, project: String?, directory: String?, startedAt: Date?, memoryBytes: UInt64,
        cpuSeconds: Double, parent: String?
    ) {
        self.pid = pid
        self.name = name
        self.kind = kind
        self.project = project
        self.directory = directory
        self.startedAt = startedAt
        self.memoryBytes = memoryBytes
        self.cpuSeconds = cpuSeconds
        self.parent = parent
    }
}

public protocol DevToolSource: Sendable {
    func tools() async -> [DevTool]
}

/// Pure: which processes are dev tools, from their names and arguments.
public enum DevToolRules {
    /// Executables that are dev tools by name alone.
    static let byName: [String: (String, DevTool.Kind)] = [
        "sourcekit-lsp": ("sourcekit-lsp", .languageServer), "rust-analyzer": ("rust-analyzer", .languageServer),
        "gopls": ("gopls", .languageServer), "clangd": ("clangd", .languageServer), "zls": ("zls", .languageServer),
        "lua-language-server": ("lua-language-server", .languageServer), "terraform-ls": ("terraform-ls", .languageServer),
        "elixir-ls": ("elixir-ls", .languageServer), "haskell-language-server": ("haskell-language-server", .languageServer),
        "kotlin-language-server": ("kotlin-language-server", .languageServer), "marksman": ("marksman", .languageServer),
        "taplo": ("taplo", .languageServer), "jdtls": ("jdtls", .languageServer),
        "watchman": ("watchman", .watcher), "fswatch": ("fswatch", .watcher), "entr": ("entr", .watcher),
        "watchexec": ("watchexec", .watcher), "air": ("air", .watcher), "cargo-watch": ("cargo watch", .watcher),
    ]

    /// Inside a node, bun, python, ruby or java process's arguments: the script it runs.
    static let byArgument: [(fragment: String, name: String, kind: DevTool.Kind)] = [
        ("tsserver", "TypeScript server", .languageServer), ("typescript-language-server", "TypeScript server", .languageServer),
        ("vtsls", "TypeScript server", .languageServer), ("basedpyright", "basedpyright", .languageServer),
        ("pyright", "Pyright", .languageServer), ("pylance", "Pylance", .languageServer),
        ("eslintServer", "ESLint server", .languageServer), ("eslint_d", "eslint_d", .languageServer),
        ("tailwindcss-language-server", "Tailwind CSS server", .languageServer), ("tailwindServer", "Tailwind CSS server", .languageServer),
        ("yaml-language-server", "YAML server", .languageServer), ("vscode-json-language", "JSON server", .languageServer),
        ("svelte-language-server", "Svelte server", .languageServer), ("vue-language-server", "Vue server", .languageServer),
        ("jedi-language-server", "Jedi server", .languageServer), ("pylsp", "Python LSP server", .languageServer),
        ("ruby-lsp", "Ruby LSP", .languageServer), ("solargraph", "Solargraph", .languageServer),
        ("jdt.ls", "Java server", .languageServer), ("prettierd", "prettierd", .languageServer),
        ("nodemon", "nodemon", .watcher), ("chokidar", "chokidar", .watcher), ("ptw", "pytest-watch", .watcher),
        ("jest", "Jest", .testRunner), ("vitest", "Vitest", .testRunner), ("karma", "Karma", .testRunner),
    ]

    static let interpreters = ["node", "bun", "deno", "python", "ruby", "java"]

    /// Tools that run as their own launchd daemon by design.
    static let daemons: Set<String> = ["watchman", "eslint_d", "prettierd"]

    /// Any Jest or Vitest process, watching or not: its workers are its, not tools of their own.
    static func isTestRunner(_ arguments: [String]) -> Bool {
        let words = Array(arguments.dropFirst())
        return names(words, "vitest") || names(words, "jest")
    }

    /// An argument names `fragment`: a path component that is it, or starts with it and then
    /// ".", "-", "_" or "@" ("tsserver.js", "pyright-langserver"). A long, distinctive one may
    /// sit inside a component ("ms-python.vscode-pylance-2025.1"). So "jest" isn't in
    /// "majestic", and "ptw" isn't in "scriptwriter".
    static func names(_ words: [String], _ fragment: String) -> Bool {
        words.contains { word in
            word.split(separator: "/").contains { component in
                component == fragment
                    || (component.hasPrefix(fragment) && component.dropFirst(fragment.count).first.map { ".-_@".contains($0) } == true)
                    || (fragment.count >= 7 && component.contains(fragment))
            }
        }
    }

    /// `--watch` or `-w` makes these a watcher: tsc, webpack, esbuild, rollup, tailwindcss.
    static let watchable = ["tsc", "webpack", "esbuild", "rollup", "tailwindcss", "sass", "babel"]

    static func isInterpreter(_ name: String) -> Bool {
        interpreters.contains { name.hasPrefix($0) } || isEditorHelper(name)
    }

    /// VS Code, Cursor and the other Electron editors run their language servers as their own
    /// helper process in Node mode: "Code Helper (Plugin)", "Cursor Helper (Plugin)".
    static func isEditorHelper(_ name: String) -> Bool {
        name.hasSuffix("Helper (Plugin)") || name.hasSuffix(" Helper")
    }

    /// The tool a process is, or nil. `arguments` matter only for interpreters.
    public static func identify(name: String, arguments: [String]) -> (name: String, kind: DevTool.Kind)? {
        if let known = byName[name] {
            return known
        }
        guard isInterpreter(name) || watchable.contains(name) else {
            return nil
        }
        let words = arguments.dropFirst()
        let watching = words.contains("--watch") || words.contains("-w") || words.contains("watch")
        // `jest` and `vitest` count only watching (a one-off run ends by itself); vitest
        // watches unless told `run`.
        for entry in byArgument where names(Array(words), entry.fragment) {
            if entry.kind == .testRunner {
                let vitestWatches = entry.name == "Vitest" && !words.contains("run")
                return watching || vitestWatches ? (entry.name, .testRunner) : nil
            }
            return (entry.name, entry.kind)
        }
        if watching,
           let tool = (watchable + ["tsc"])
               .first(where: { tool in name == tool || words.contains { ($0 as NSString).lastPathComponent == tool } }) {
            return ("\(tool) --watch", .watcher)
        }
        return nil
    }
}

public struct LiveDevTools: DevToolSource {
    private let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    public func tools() async -> [DevTool] {
        let home = home
        return await Task.detached(priority: .utility) { () -> [DevTool] in
            Self.read(home: home)
        }.value
    }

    private struct Found {
        let pid: Int32
        let parent: Int32
        let tool: (name: String, kind: DevTool.Kind)
        let startedAt: Date
    }

    static func read(home: String) -> [DevTool] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: max(capacity, 64))
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else {
            return []
        }
        let me = getuid()
        var names: [Int32: String] = [:]
        var runners = Set<Int32>()
        var found: [Found] = []
        for pid in pids.prefix(Int(count)) where pid > 1 {
            guard let identity = ProcessInspector.identity(pid) else {
                continue
            }
            names[pid] = identity.name
            // This user's only, as the Agents tab (D-221).
            guard identity.uid == me else {
                continue
            }
            let needsArguments = DevToolRules.isInterpreter(identity.name) || DevToolRules.watchable.contains(identity.name)
            let arguments = needsArguments ? ProcessInspector.arguments(pid) : []
            if DevToolRules.isTestRunner(arguments) {
                runners.insert(pid)
            }
            if let tool = DevToolRules.identify(name: identity.name, arguments: arguments) {
                found.append(Found(pid: pid, parent: identity.parentPID, tool: tool, startedAt: identity.startedAt))
            }
        }
        // A tool's own helpers (tsserver's typings installer, a test runner's workers) are part
        // of it, and a one-off `vitest run`'s workers end with it.
        let parents = Set(found.map(\.pid)).union(runners)
        return found
            .filter { !parents.contains($0.parent) }
            .map { entry in
                let directory = ProcessInspector.workingDirectory(entry.pid)
                let root = directory.flatMap { directory in
                    ProjectDetection.projectRoot(from: directory, home: home) { FileManager.default.fileExists(atPath: $0) }?.root
                }
                let usage = ProcessInspector.usage(entry.pid)
                return DevTool(
                    pid: entry.pid, name: entry.tool.name, kind: entry.tool.kind,
                    project: root.map { ($0 as NSString).lastPathComponent }, directory: root ?? directory, startedAt: entry.startedAt,
                    memoryBytes: usage?.footprint ?? 0, cpuSeconds: usage?.cpu.seconds ?? 0,
                    parent: entry.parent > 1 ? names[entry.parent] : nil
                )
            }
            .sorted { ($0.isLeftBehind ? 0 : 1, -Int64($0.memoryBytes)) < ($1.isLeftBehind ? 0 : 1, -Int64($1.memoryBytes)) }
    }
}

public struct SimulatedDevTools: DevToolSource {
    private let now: Date

    public init(now: Date = Date()) {
        self.now = now
    }

    public func tools() async -> [DevTool] {
        let dev = "/Users/demo/Developer/"
        return [
            DevTool(
                pid: 4410, name: "TypeScript server", kind: .languageServer, project: "storefront-web", directory: dev + "storefront-web",
                startedAt: now.addingTimeInterval(-26 * 3600), memoryBytes: 1_300_000_000, cpuSeconds: 900, parent: nil
            ),
            DevTool(
                pid: 4502, name: "rust-analyzer", kind: .languageServer, project: "ingest", directory: dev + "ingest",
                startedAt: now.addingTimeInterval(-9 * 3600), memoryBytes: 2_100_000_000, cpuSeconds: 1500, parent: nil
            ),
            DevTool(
                pid: 4630, name: "tsc --watch", kind: .watcher, project: "storefront-web", directory: dev + "storefront-web",
                startedAt: now.addingTimeInterval(-3 * 3600), memoryBytes: 310_000_000, cpuSeconds: 60, parent: "zsh"
            ),
            DevTool(
                pid: 4711, name: "sourcekit-lsp", kind: .languageServer, project: "ios-app", directory: dev + "ios-app",
                startedAt: now.addingTimeInterval(-2 * 3600), memoryBytes: 640_000_000, cpuSeconds: 210, parent: "Code Helper (Plugin)"
            ),
        ]
    }
}
