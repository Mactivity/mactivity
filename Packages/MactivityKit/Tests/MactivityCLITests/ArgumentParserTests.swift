@testable import MactivityCLI
import Readouts
import Testing

@Suite("CLI arguments")
struct ArgumentParserTests {
    private func parse(_ line: String) throws(UsageError) -> Command {
        try ArgumentParser.parse(line.split(separator: " ").map(String.init))
    }

    @Test("No arguments shows help")
    func empty() throws {
        #expect(try ArgumentParser.parse([]) == .help(topic: nil))
    }

    @Test("top defaults: CPU, 15 apps, text")
    func topDefaults() throws {
        #expect(try parse("top") == .top(.init(ranking: .cpu, limit: 15, json: false)))
    }

    @Test("Metric, limit, and JSON in any order", arguments: [
        ("top --memory --limit 5 --json", Command.TopOptions(ranking: .memory, limit: 5, json: true)),
        ("top --json -n 3 --energy", Command.TopOptions(ranking: .energy, limit: 3, json: true)),
        ("top --limit=40 --disk", Command.TopOptions(ranking: .disk, limit: 40, json: false)),
        ("top --network", Command.TopOptions(ranking: .network, limit: 15, json: false)),
        ("top --cpu --cpu", Command.TopOptions(ranking: .cpu, limit: 15, json: false)),
    ])
    func topOptions(line: String, expected: Command.TopOptions) throws {
        #expect(try parse(line) == .top(expected))
    }

    @Test("system and projects take --json")
    func jsonOnly() throws {
        #expect(try parse("system") == .system(json: false))
        #expect(try parse("system --json") == .system(json: true))
        #expect(try parse("projects --json") == .projects(json: true))
    }

    @Test("Help and version spellings")
    func helpAndVersion() throws {
        #expect(try parse("--help") == .help(topic: nil))
        #expect(try parse("-h") == .help(topic: nil))
        #expect(try parse("help json") == .help(topic: "json"))
        #expect(try parse("top --help") == .help(topic: "top"))
        #expect(try parse("projects -h") == .help(topic: "projects"))
        #expect(try parse("--version") == .version)
        #expect(try parse("-V") == .version)
    }

    @Test("Usage errors", arguments: [
        ("kill 123", UsageError.unknownCommand("kill")),
        ("stop", UsageError.unknownCommand("stop")),
        ("top --bogus", UsageError.unknownOption("--bogus", command: "top")),
        ("top --limit", UsageError.missingValue("--limit")),
        ("top -n 0", UsageError.invalidLimit("0")),
        ("top --limit=lots", UsageError.invalidLimit("lots")),
        ("top --limit 501", UsageError.invalidLimit("501")),
        ("top --cpu --memory", UsageError.conflictingMetrics(["--cpu", "--memory"])),
        ("top safari", UsageError.unexpectedArgument("safari", command: "top")),
        ("system --memory", UsageError.unknownOption("--memory", command: "system")),
        ("projects stop", UsageError.unexpectedArgument("stop", command: "projects")),
    ])
    func errors(line: String, expected: UsageError) {
        #expect(throws: expected) { try parse(line) }
    }

    @Test("Error messages point at the problem")
    func messages() {
        #expect(UsageError.invalidLimit("0").description == "'--limit' takes a whole number from 1 to 500; got '0'.")
        #expect(UsageError.conflictingMetrics(["--cpu", "--disk"]).description == "Pick one metric; got --cpu and --disk.")
    }

    @Test("Help topics exist for every command and the JSON schema")
    func helpTopics() {
        for topic in [nil, "top", "system", "projects", "json"] {
            #expect(Help.text(for: topic) != nil)
        }
        #expect(Help.text(for: "kill") == nil)
        #expect(Help.overview.contains("64  bad command line"))
        #expect(Help.json.contains("schemaVersion 1"))
    }
}
