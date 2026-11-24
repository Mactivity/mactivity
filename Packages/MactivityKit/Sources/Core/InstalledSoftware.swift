import Foundation

/// A package or runtime installed on this Mac (1.6.5, D-252): a Homebrew formula or cask, a
/// runtime a version manager keeps, or Apple's own Python and Ruby.
public struct InstalledSoftware: Hashable, Sendable, Identifiable, Codable {
    public enum Origin: String, Hashable, Sendable, Codable, CaseIterable {
        case homebrew, homebrewCask, pyenv, nvm, fnm, volta, rbenv, asdf, mise, apple
        /// Homebrew itself (D-257).
        case homebrewItself
        /// An app whose built-in updater (Sparkle) has known vulnerabilities (D-257).
        case appUpdater
    }

    public var id: String {
        "\(origin.rawValue):\(name)@\(version)"
    }

    /// "openssl@3", "python", "node".
    public let name: String
    public let version: String
    /// The newest version Homebrew knows of, when it's newer than `version`.
    public let latest: String?
    public let origin: Origin
    /// Installed by the person, not pulled in by something else.
    public let onRequest: Bool
    /// Homebrew's flags: deprecated or disabled, with its reason ("unsupported").
    public let deprecation: Deprecation?
    /// What it is when it's a language or database: for its end of life.
    public let runtime: Runtime?
    /// Known vulnerabilities, when the check is on and found some.
    public var vulnerabilities: [Vulnerability]
    /// What inside it is affected: "Sparkle 2.6.1" (D-257).
    public var component: String?
    /// Where it is on disk, for an app.
    public var path: String?

    public struct Deprecation: Hashable, Sendable, Codable {
        public let disabled: Bool
        public let reason: String?

        public init(disabled: Bool, reason: String?) {
            self.disabled = disabled
            self.reason = reason
        }
    }

    /// "PHP 8.1" for a runtime, the package's own name otherwise.
    public var title: String {
        runtime.map { "\($0.kind.name) \($0.cycle)" } ?? name
    }

    /// "PHP 8.1.34", "openssl@3 3.5.1": for a list that shows the version.
    public var titleWithVersion: String {
        "\(runtime?.kind.name ?? name) \(version)"
    }

    /// Homebrew's versioned formula of a release line that's over ("php@8.1"): upgrading keeps
    /// it on that line, so the fix is the current formula ("php"), installed beside it.
    public var replacementFormula: String? {
        guard origin == .homebrew, runtime != nil, name.contains("@"),
              let base = name.split(separator: "@").first.map(String.init) else {
            return nil
        }
        return base
    }

    public init(
        name: String, version: String, latest: String? = nil, origin: Origin, onRequest: Bool = true,
        deprecation: Deprecation? = nil, runtime: Runtime? = nil, vulnerabilities: [Vulnerability] = [],
        component: String? = nil, path: String? = nil
    ) {
        self.name = name
        self.version = version
        self.latest = latest
        self.origin = origin
        self.onRequest = onRequest
        self.deprecation = deprecation
        self.runtime = runtime
        self.vulnerabilities = vulnerabilities
        self.component = component
        self.path = path
    }
}

/// One known vulnerability (OSV.dev, through `brew vulns`).
public struct Vulnerability: Hashable, Sendable, Codable, Identifiable {
    public enum Severity: Int, Hashable, Sendable, Codable, Comparable, CaseIterable {
        case unknown, low, medium, high, critical

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        /// From OSV's "CRITICAL", "HIGH", "MODERATE"/"MEDIUM", "LOW"; anything else is unknown.
        public init(osv text: String) {
            switch text.uppercased() {
            case "CRITICAL": self = .critical
            case "HIGH": self = .high
            case "MEDIUM", "MODERATE": self = .medium
            case "LOW": self = .low
            default: self = .unknown
            }
        }
    }

    /// "CVE-2026-54873".
    public let id: String
    public let severity: Severity
    public let summary: String

    public init(id: String, severity: Severity, summary: String) {
        self.id = id
        self.severity = severity
        self.summary = summary
    }
}

/// A language or database whose versions stop getting security fixes on a known date.
public struct Runtime: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        case python, node, ruby, php, postgresql, mysql

        /// "Python", "Node.js".
        public var name: String {
            switch self {
            case .python: "Python"
            case .node: "Node.js"
            case .ruby: "Ruby"
            case .php: "PHP"
            case .postgresql: "PostgreSQL"
            case .mysql: "MySQL"
            }
        }
    }

    public let kind: Kind
    /// The release line end of life is about: "3.9", "20", "8.1", "16".
    public let cycle: String

    public init(kind: Kind, cycle: String) {
        self.kind = kind
        self.cycle = cycle
    }

    /// Pure: the release line of a version. Node.js and PostgreSQL go by their first number
    /// ("20.11.1" is 20, "16.4" is 16); the others by the first two ("3.9.6" is 3.9).
    public static func cycle(of version: String, kind: Kind) -> String? {
        let parts = version.split(whereSeparator: { !$0.isNumber }).prefix(2).map(String.init)
        guard let first = parts.first, !first.isEmpty else {
            return nil
        }
        switch kind {
        case .node, .postgresql: return first
        case .python, .ruby, .php, .mysql: return parts.count > 1 ? "\(first).\(parts[1])" : nil
        }
    }

    /// Pure: a Homebrew formula's runtime: "python@3.11", "php", "node@20", "postgresql@16".
    /// `version` gives the line for an unversioned formula ("php" at 8.5.1 is 8.5).
    public static func homebrew(formula: String, version: String) -> Runtime? {
        let parts = formula.split(separator: "@", maxSplits: 1).map(String.init)
        let base = parts.first ?? formula
        let kind: Kind? = switch base {
        case "python", "python3": .python
        case "node": .node
        case "ruby": .ruby
        case "php": .php
        case "postgresql": .postgresql
        case "mysql": .mysql
        default: nil
        }
        guard let kind, let line = cycle(of: version, kind: kind) else {
            return nil
        }
        return Runtime(kind: kind, cycle: line)
    }
}

/// When each release line stops getting security fixes, from each project's own schedule
/// (D-252). Updated with each Mactivity release; a line not listed isn't judged.
public enum RuntimeSupport {
    /// The day, at the start of it on this Mac's calendar, so it reads as the same date here.
    static func day(_ text: String, calendar: Calendar = .current) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else {
            return nil
        }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Release line → last day of security fixes. As of 2026-10.
    static let schedule: [Runtime.Kind: [String: String]] = [
        .python: [
            "2.7": "2020-01-01", "3.6": "2021-12-23", "3.7": "2023-06-27", "3.8": "2024-10-07", "3.9": "2025-10-31",
            "3.10": "2026-10-31", "3.11": "2027-10-31", "3.12": "2028-10-31", "3.13": "2029-10-31", "3.14": "2030-10-31",
        ],
        .node: [
            "12": "2022-04-30", "14": "2023-04-30", "16": "2023-09-11", "17": "2022-06-01", "18": "2025-04-30",
            "19": "2023-06-01", "20": "2026-04-30", "21": "2024-06-01", "22": "2027-04-30", "23": "2025-06-01",
            "24": "2028-04-30", "25": "2026-06-01", "26": "2029-04-30",
        ],
        .ruby: [
            "2.6": "2022-03-31", "2.7": "2023-03-31", "3.0": "2024-04-23", "3.1": "2025-03-31", "3.2": "2026-03-31",
            "3.3": "2027-03-31", "3.4": "2028-03-31",
        ],
        .php: [
            "7.4": "2022-11-28", "8.0": "2023-11-26", "8.1": "2025-12-31", "8.2": "2026-12-31", "8.3": "2027-12-31",
            "8.4": "2028-12-31", "8.5": "2029-12-31",
        ],
        .postgresql: [
            "11": "2023-11-09", "12": "2024-11-21", "13": "2025-11-13", "14": "2026-11-12", "15": "2027-11-11",
            "16": "2028-11-09", "17": "2029-11-08", "18": "2030-11-14",
        ],
        .mysql: ["5.7": "2023-10-31", "8.0": "2026-04-30", "8.4": "2032-04-30"],
    ]

    /// Pure: the last day of security fixes for `runtime`'s line, when it's known.
    public static func endOfLife(_ runtime: Runtime) -> Date? {
        schedule[runtime.kind]?[runtime.cycle].flatMap { day($0) }
    }
}

/// What a package needs, most urgent first (D-252).
public enum SoftwareConcern: Hashable, Sendable, Comparable {
    /// Known vulnerabilities, at their highest severity.
    case vulnerable(Vulnerability.Severity)
    /// Past its end of life, or disabled by Homebrew: no more security fixes.
    case unsupported(since: Date?)
    /// End of life within 90 days.
    case endingSoon(Date)
    /// Homebrew has deprecated it.
    case deprecated
    /// A newer version is out.
    case outdated

    var rank: Int {
        switch self {
        case let .vulnerable(severity): severity >= .high ? 0 : 3
        case .unsupported: 1
        case .endingSoon: 4
        case .deprecated: 5
        case .outdated: 6
        }
    }

    public static func < (lhs: SoftwareConcern, rhs: SoftwareConcern) -> Bool {
        lhs.rank < rhs.rank
    }

    /// Worth doing soon: a high or critical vulnerability, or no more security fixes.
    public var isUrgent: Bool {
        rank <= 1
    }
}

public enum SoftwareAssessment {
    public static let endingSoonWithin: TimeInterval = 90 * 86400

    /// Pure: what `item` needs, if anything. Apple's copies are only ever outdated, since Apple
    /// patches its own builds and updates them with Xcode and macOS.
    public static func concern(_ item: InstalledSoftware, now: Date) -> SoftwareConcern? {
        if let worst = item.vulnerabilities.map(\.severity).max() {
            return .vulnerable(worst)
        }
        let endOfLife = item.runtime.flatMap(RuntimeSupport.endOfLife)
        if item.origin == .apple {
            return endOfLife.map { $0 <= now } == true ? .outdated : nil
        }
        if item.deprecation?.disabled == true {
            return .unsupported(since: endOfLife)
        }
        if let endOfLife {
            if endOfLife <= now {
                return .unsupported(since: endOfLife)
            }
            if endOfLife.timeIntervalSince(now) <= endingSoonWithin {
                return .endingSoon(endOfLife)
            }
        }
        if item.deprecation?.reason == "unsupported" {
            return .unsupported(since: nil)
        }
        if item.deprecation != nil {
            return .deprecated
        }
        return item.latest == nil ? nil : .outdated
    }

    /// Pure: everything with a concern, most urgent first, then by name.
    public static func needingAttention(_ items: [InstalledSoftware], now: Date) -> [(InstalledSoftware, SoftwareConcern)] {
        items.compactMap { item in concern(item, now: now).map { (item, $0) } }
            .sorted { ($0.1.rank, $0.0.name) < ($1.1.rank, $1.0.name) }
    }
}

/// What's installed, and the vulnerability check's last result.
public struct SoftwareInventory: Sendable, Equatable, Codable {
    public var items: [InstalledSoftware]
    /// When `brew vulns` last ran, nil when the check is off or hasn't run.
    public var checkedAt: Date?
    /// Formulae `brew vulns` couldn't check (no supported source address).
    public var unchecked: [String]

    public init(items: [InstalledSoftware] = [], checkedAt: Date? = nil, unchecked: [String] = []) {
        self.items = items
        self.checkedAt = checkedAt
        self.unchecked = unchecked
    }
}

/// The confirmed "Upgrade" (D-252): only the confirmation in the Outdated Software sheet makes
/// one, and the upgrader takes nothing else, like `TrashConfirmation` and rule 4's termination.
public struct UpgradeConfirmation: Sendable, Hashable {
    /// Homebrew formulae, by name.
    public let formulae: [String]
    public let confirmedAt: Date

    package init(formulae: [String], confirmedAt: Date) {
        self.formulae = formulae
        self.confirmedAt = confirmedAt
    }
}

public struct UpgradeResult: Sendable, Equatable {
    public let succeeded: Bool
    /// The end of Homebrew's output, for when it didn't work.
    public let output: String

    public init(succeeded: Bool, output: String) {
        self.succeeded = succeeded
        self.output = output
    }
}

/// Installed software and its vulnerabilities (D-252). Live reads Homebrew and the version
/// managers' folders; Simulated has a fixed set.
public protocol InstalledSoftwareSource: Sendable {
    /// Everything installed, read from this Mac only.
    func installed() async -> [InstalledSoftware]
    /// Homebrew's vulnerability check (`brew vulns`), which asks OSV.dev; nil when it couldn't run.
    func vulnerabilities() async -> VulnerabilityScan?
    /// What `brew upgrade` would change for these formulae: "node 26.0.0 → 26.12.0".
    func upgradePlan(_ formulae: [String]) async -> [String]
    func upgrade(_ confirmation: UpgradeConfirmation) async -> UpgradeResult
}

/// `brew vulns` findings: each formula's vulnerabilities, and the ones it couldn't check.
public struct VulnerabilityScan: Sendable, Equatable {
    public var found: [String: [Vulnerability]]
    public var skipped: [String]

    public init(found: [String: [Vulnerability]], skipped: [String]) {
        self.found = found
        self.skipped = skipped
    }
}
