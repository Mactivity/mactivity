import Foundation
import Readouts

/// What the user asked for. Parsing is pure so it's tested without running anything.
///
/// There is deliberately no command that stops or kills anything: termination needs the
/// confirmation UI (CLAUDE.md rule 4, D-031).
enum Command: Equatable {
    struct TopOptions: Equatable {
        var ranking: AppRanking = .cpu
        var limit = 15
        var json = false
    }

    case top(TopOptions)
    case system(json: Bool)
    case projects(json: Bool)
    /// Agent history for the last `days` days (D-193).
    case agents(days: Int, json: Bool)
    /// A day's timeline (D-193).
    case day(DaySpec, json: Bool)
    /// What's out of the ordinary today, against each app's usual day (D-202).
    case unusual(json: Bool)
    /// Build times by project over the last `days` days (D-209).
    case builds(days: Int, json: Bool)
    /// A Model Context Protocol server on stdin and stdout (D-152).
    case mcp
    /// `nil` topic is the overview.
    case help(topic: String?)
    case version
}

/// A bad command line. Printed to stderr with a pointer to `--help`; exit code 64.
enum UsageError: Error, Equatable, CustomStringConvertible {
    case unknownCommand(String)
    case unknownOption(String, command: String)
    case missingValue(String)
    case invalidLimit(String)
    case conflictingMetrics([String])
    case unexpectedArgument(String, command: String)
    case invalidDays(String)
    case invalidDate(String)

    var description: String {
        switch self {
        case let .unknownCommand(name):
            "Unknown command '\(name)'."
        case let .unknownOption(option, command):
            "Unknown option '\(option)' for '\(command)'."
        case let .missingValue(option):
            "'\(option)' needs a value."
        case let .invalidLimit(value):
            "'--limit' takes a whole number from 1 to \(ArgumentParser.maxLimit); got '\(value)'."
        case let .conflictingMetrics(flags):
            "Pick one metric; got \(flags.joined(separator: " and "))."
        case let .unexpectedArgument(argument, command):
            "'\(command)' doesn't take '\(argument)'."
        case let .invalidDays(value):
            "'--days' takes a whole number from 1 to 365; got '\(value)'."
        case let .invalidDate(value):
            "A day is today, yesterday or a past date like 2026-10-14; got '\(value)'."
        }
    }
}

enum ArgumentParser {
    static let maxLimit = 500

    /// `arguments` excludes the program name.
    static func parse(_ arguments: [String]) throws(UsageError) -> Command {
        guard let first = arguments.first else {
            return .help(topic: nil)
        }
        let rest = Array(arguments.dropFirst())
        switch first {
        case "-h", "--help", "help":
            return .help(topic: rest.first)
        case "-V", "--version", "version":
            return .version
        case "top":
            return try parseTop(rest)
        case "system":
            return try parseJSONOnly(rest, command: first) { .system(json: $0) }
        case "projects":
            return try parseJSONOnly(rest, command: first) { .projects(json: $0) }
        case "agents":
            return try parseAgents(rest)
        case "day":
            return try parseDay(rest)
        case "unusual":
            return try parseJSONOnly(rest, command: first) { .unusual(json: $0) }
        case "builds":
            return try parseBuilds(rest)
        case "mcp":
            if rest.contains("-h") || rest.contains("--help") {
                return .help(topic: "mcp")
            }
            if let extra = rest.first {
                throw extra.hasPrefix("-") ? .unknownOption(extra, command: first) : .unexpectedArgument(extra, command: first)
            }
            return .mcp
        default:
            throw .unknownCommand(first)
        }
    }

    private static let metricFlags: [String: AppRanking] = [
        "--cpu": .cpu, "--memory": .memory, "--energy": .energy, "--disk": .disk, "--network": .network,
    ]

    private static func parseTop(_ arguments: [String]) throws(UsageError) -> Command {
        var options = Command.TopOptions()
        var metrics: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if let ranking = metricFlags[argument] {
                metrics.append(argument)
                options.ranking = ranking
                continue
            }
            switch argument {
            case "--json":
                options.json = true
            case "-h", "--help":
                return .help(topic: "top")
            case "-n", "--limit":
                guard index < arguments.count else {
                    throw .missingValue(argument)
                }
                options.limit = try limit(arguments[index])
                index += 1
            default:
                if argument.hasPrefix("--limit=") {
                    options.limit = try limit(String(argument.dropFirst("--limit=".count)))
                } else if argument.hasPrefix("-") {
                    throw .unknownOption(argument, command: "top")
                } else {
                    throw .unexpectedArgument(argument, command: "top")
                }
            }
        }
        if Set(metrics).count > 1 {
            throw .conflictingMetrics(metrics)
        }
        return .top(options)
    }

    private static func limit(_ value: String) throws(UsageError) -> Int {
        guard let number = Int(value), (1 ... maxLimit).contains(number) else {
            throw .invalidLimit(value)
        }
        return number
    }

    private static func parseJSONOnly(
        _ arguments: [String],
        command: String,
        make: (Bool) -> Command
    ) throws(UsageError) -> Command {
        var json = false
        for argument in arguments {
            switch argument {
            case "--json":
                json = true
            case "-h", "--help":
                return .help(topic: command)
            default:
                if argument.hasPrefix("-") {
                    throw .unknownOption(argument, command: command)
                }
                throw .unexpectedArgument(argument, command: command)
            }
        }
        return make(json)
    }
}
