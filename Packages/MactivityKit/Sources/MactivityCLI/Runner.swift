import Core
import Foundation
import Readouts

/// Runs one command and returns the exit status (see `Help.overview`).
///
/// Output goes through `FileHandle`: writing results to stdout is this tool's whole job, so
/// the app's "no print, use os.Logger" rule (CLAUDE.md rule 10) doesn't apply to it, and
/// `FileHandle` keeps the `no_print` lint rule meaningful everywhere else.
enum CLI {
    enum ExitCode {
        static let success: Int32 = 0
        static let failure: Int32 = 1
        /// `EX_USAGE` from sysexits(3).
        static let usage: Int32 = 64
    }

    static func run(_ arguments: [String]) async -> Int32 {
        let command: Command
        do {
            command = try ArgumentParser.parse(arguments)
        } catch {
            writeError("mactivity: \(error)\nRun 'mactivity --help' for usage.")
            return ExitCode.usage
        }
        if case .mcp = command {
            return await MCPServer.run()
        }
        do {
            return try await execute(command)
        } catch {
            writeError("mactivity: \(error.localizedDescription)")
            return ExitCode.failure
        }
    }

    private static func execute(_ command: Command) async throws -> Int32 {
        switch command {
        case let .help(topic):
            guard let text = Help.text(for: topic) else {
                writeError("mactivity: No help for '\(topic ?? "")'. Topics: top, system, projects, json.")
                return ExitCode.usage
            }
            try write(text)
        case .version:
            try write("mactivity \(Version.string)")
        case let .top(options):
            let snapshot = await LiveSampling.snapshot()
            try write(options.json ? JSONOutput.encode(TopJSON(snapshot, options: options)) : TextOutput.top(snapshot, options: options))
        case let .system(json):
            let snapshot = await LiveSampling.snapshot()
            try write(json ? JSONOutput.encode(SystemJSON(snapshot)) : TextOutput.system(snapshot.system))
        case .mcp:
            break
        case let .agents(days, json):
            let week = try await HistoryReading.agents(days: days)
            try write(json ? JSONOutput.encode(week) : HistoryText.agents(week))
        case let .day(spec, json):
            let day = try await HistoryReading.day(spec)
            try write(json ? JSONOutput.encode(day) : HistoryText.day(day))
        case let .builds(days, json):
            let builds = try await HistoryReading.builds(days: days)
            try write(json ? JSONOutput.encode(builds) : HistoryText.builds(builds))
        case let .unusual(json):
            let unusual = try await HistoryReading.unusual()
            try write(json ? JSONOutput.encode(unusual) : HistoryText.unusual(unusual))
        case let .projects(json):
            let snapshot = await LiveSampling.snapshot()
            let projects = try await LiveSampling.projects(in: snapshot)
            let now = Date()
            if json {
                try write(JSONOutput.encode(ProjectsJSON(projects, scannedAt: now, activityWindow: LiveSampling.window)))
            } else {
                try write(TextOutput.projects(projects, now: now, home: FileManager.default.homeDirectoryForCurrentUser.path))
            }
        }
        return ExitCode.success
    }

    private static func write(_ text: String) throws {
        try FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
    }

    private static func writeError(_ text: String) {
        try? FileHandle.standardError.write(contentsOf: Data((text + "\n").utf8))
    }
}

/// The version of the Mactivity app this tool ships in.
enum Version {
    static var string: String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return version
        }
        if let version = enclosingApp?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return version
        }
        return "dev"
    }

    /// `Mactivity.app` when this binary is `Mactivity.app/Contents/Helpers/mactivity`, following
    /// the `/usr/local/bin` symlink.
    private static var enclosingApp: Bundle? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return nil
        }
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? Bundle(url: app) : nil
    }
}
