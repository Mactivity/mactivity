import Foundation

/// Quick Search (D-137): a global shortcut's search over apps, processes and listening ports,
/// plus "Why is my Mac slow?" and "Your next Mac". Pure ranking; the UI acts on the result.
public enum QuickSearchResult: Hashable, Sendable, Identifiable {
    case diagnose
    /// Start recording (D-151).
    case record
    /// What to look for in a new Mac (D-181).
    case nextMac
    /// A page of the main window, by its sidebar name (D-186).
    case page(QuickSearchPage)
    /// Your day for today (0) or yesterday (1) (D-191).
    case day(daysBack: Int)
    /// Lock the keyboard to clean it (D-203).
    case cleanKeyboard
    /// Today beside yesterday (D-207).
    case compare
    /// Ask the on-device model (D-153).
    case ask(String)
    case app(AppAggregate)
    case process(ProcessSample)
    case port(UInt16, DevServer, project: String)

    public var id: String {
        switch self {
        case .diagnose: "diagnose"
        case .record: "record"
        case .nextMac: "nextMac"
        case let .page(page): "page:" + page.id
        case let .day(daysBack): "day:\(daysBack)"
        case .cleanKeyboard: "cleanKeyboard"
        case .compare: "compare"
        case .ask: "ask"
        case let .app(app): "app:" + app.id
        case let .process(process): "pid:\(process.pid)"
        case let .port(port, server, _): "port:\(port):\(server.pid)"
        }
    }
}

/// A main-window page Quick Search can open: its sidebar ID and its title as the sidebar shows it.
public struct QuickSearchPage: Hashable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public enum QuickSearch {
    static let limit = 12
    /// What someone shopping for a Mac types: "upgrade", "new laptop", "which macbook".
    static let nextMacWords = ["your next mac", "new mac", "upgrade", "laptop", "macbook", "specs", "buy a mac"]

    /// What a query and a name are compared as: case, accents and full-width forms aside, so
    /// "resume" finds Résumé, "uber" Übersicht, and "ｓａｆａｒｉ" Safari (D-221).
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The actions a query names. From three letters: "s" alone shouldn't offer the diagnosis
    /// ahead of Safari. `titles` are the actions' names in the Mac's language, when it isn't
    /// English: "langsam" offers Warum ist mein Mac langsam? (D-221).
    static func actions(_ needle: String, titles: [QuickSearchResult: String] = [:]) -> [QuickSearchResult] {
        guard needle.count >= (AskContext.minimumLength(needle) == 3 ? 2 : 3) else {
            return []
        }
        var actions = englishActions(needle)
        for (action, title) in titles.sorted(by: { $0.key.id < $1.key.id }) where !actions.contains(action) {
            if Self.title(fold(title), names: needle, for: action) {
                actions.append(action)
            }
        }
        return actions
    }

    /// A localized title the query names. Clean Keyboard and Compare as strictly as in English;
    /// the rest from four letters into a word of five or more, so "ist" or "mein" offer nothing. In
    /// Chinese, Japanese and Korean, which don't split words with spaces, two characters inside.
    static func title(_ title: String, names needle: String, for action: QuickSearchResult) -> Bool {
        let title = title.trimmingCharacters(in: CharacterSet(charactersIn: "…?？"))
        let ideographic = AskContext.minimumLength(title) == 3
        switch action {
        case .cleanKeyboard:
            return ideographic ? needle.count >= 3 && title.hasPrefix(needle) : names(needle, [title], atLeast: 0, intoSecondWord: true)
        case .compare:
            return ideographic ? needle.count >= 2 && title.hasPrefix(needle) : names(needle, [title], atLeast: 6)
        default:
            if ideographic {
                return needle.count >= 2 && title.contains(needle)
            }
            let words = title.split { !$0.isLetter && !$0.isNumber }
            return needle.count >= 4 && words.contains { $0.count >= 5 && $0.hasPrefix(needle) }
        }
    }

    private static func englishActions(_ needle: String) -> [QuickSearchResult] {
        guard needle.count >= 3 else {
            return []
        }
        var actions: [QuickSearchResult] = []
        if "why is my mac slow".contains(needle) || needle.contains("slow") {
            actions.append(.diagnose)
        }
        if "record activity".contains(needle) || needle.hasPrefix("record") {
            actions.append(.record)
        }
        if nextMacWords.contains(where: { $0.contains(needle) || needle.contains($0) }) {
            actions.append(.nextMac)
        }
        // Only once the words can't be an app's name: actions come first, and Return on "clean"
        // (CleanShot, CleanMyMac) mustn't lock the keyboard (D-219).
        if Self.names(needle, ["compare days"], atLeast: 6) {
            actions.append(.compare)
        }
        if Self.names(needle, ["clean keyboard", "lock keyboard", "keyboard clean", "keyboard lock"], atLeast: 0, intoSecondWord: true) {
            actions.append(.cleanKeyboard)
        }
        // "today", "yesterday", "your day", "timeline": that day's story.
        if "yesterday".hasPrefix(needle) {
            actions.append(.day(daysBack: 1))
        } else if "today".hasPrefix(needle) || "your day".hasPrefix(needle) || "timeline".hasPrefix(needle) {
            actions.append(.day(daysBack: 0))
        }
        return actions
    }

    /// The query starts one of `phrases`, with at least `atLeast` characters, or with a character
    /// of the phrase's second word.
    static func names(_ needle: String, _ phrases: [String], atLeast: Int, intoSecondWord: Bool = false) -> Bool {
        phrases.contains { phrase in
            guard phrase.hasPrefix(needle), needle.count >= atLeast else {
                return false
            }
            guard intoSecondWord, let space = phrase.firstIndex(of: " ") else {
                return true
            }
            return needle.count > phrase.distance(from: phrase.startIndex, to: space) + 1
        }
    }

    /// Pages whose name starts with the query or has a word that does. From two letters: "s"
    /// alone keeps Safari ahead of Storage, Startup and Sound.
    static func matching(_ pages: [QuickSearchPage], _ needle: String) -> [QuickSearchPage] {
        guard needle.count >= 2 else {
            return []
        }
        return pages.filter { page in
            let title = fold(page.title)
            return title.hasPrefix(needle) || title.split(separator: " ").contains { $0.hasPrefix(needle) }
        }
    }

    /// Most relevant first: a port match, then names that start with the query, then names that
    /// contain it; within each, the busiest first. An empty query lists the diagnosis and the
    /// apps using the most CPU.
    /// `canAsk`: Apple Intelligence is available, so a question offers Ask Mactivity first (D-153).
    /// `pages`: the main window's pages; a name that starts with the query, or has a word that
    /// does, comes right after the actions ("stor" opens Storage).
    public static func results(
        _ query: String, snapshot: Snapshot?, projects: [Project], canAsk: Bool = false, pages: [QuickSearchPage] = [],
        actionTitles: [QuickSearchResult: String] = [:]
    ) -> [QuickSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let needle = fold(trimmed)
        let apps = snapshot?.apps.filter { $0.app.kind != .system } ?? []
        guard !needle.isEmpty else {
            let busiest = apps.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(limit - 1)
            return [.diagnose] + busiest.map(QuickSearchResult.app)
        }
        var results: [QuickSearchResult] = []
        let asks = canAsk && AskContext.looksLikeQuestion(trimmed)
        if asks, AskContext.isPlainQuestion(trimmed) {
            results.append(.ask(trimmed))
        }

        // ":3000" or "3000": a port.
        let digits = needle.hasPrefix(":") ? String(needle.dropFirst()) : needle
        if let port = UInt16(digits) {
            for project in projects {
                for server in project.servers where server.ports.contains(where: { String($0).hasPrefix(digits) }) {
                    let matched = server.ports.first { String($0).hasPrefix(digits) } ?? port
                    results.append(.port(matched, server, project: project.name))
                }
            }
        }

        results += actions(needle, titles: actionTitles)
        results += matching(pages, needle).map(QuickSearchResult.page)

        func rank(_ name: String) -> Int? {
            let name = fold(name)
            if name.hasPrefix(needle) {
                return 0
            }
            if name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" }).contains(where: { $0.hasPrefix(needle) }) {
                return 1
            }
            return name.contains(needle) ? 2 : nil
        }
        let matchedApps = apps.compactMap { app in rank(app.app.name).map { (app, $0) } }
            .sorted { ($0.1, -$0.0.cpuPercent, $0.0.app.name) < ($1.1, -$1.0.cpuPercent, $1.0.app.name) }
        results += matchedApps.map { .app($0.0) }

        // Processes by name or PID, not ones whose app already matched (the app row covers them).
        let appIDs = Set(matchedApps.map(\.0.id))
        let processes = (snapshot?.processes ?? []).compactMap { process -> (ProcessSample, Int)? in
            if String(process.pid) == needle {
                return (process, 0)
            }
            guard !appIDs.contains(process.app), let rank = rank(process.name) else {
                return nil
            }
            return (process, rank)
        }
        .sorted { ($0.1, -$0.0.cpuPercent, $0.0.pid) < ($1.1, -$1.0.cpuPercent, $1.0.pid) }
        results += processes.map { .process($0.0) }

        var seen = Set<String>()
        var unique = Array(results.filter { seen.insert($0.id).inserted }.prefix(limit))
        // Maybe a question, maybe a name: Ask after what matched, never pushed off the list.
        if asks, !unique.contains(.ask(trimmed)) {
            unique = Array(unique.prefix(limit - 1)) + [.ask(trimmed)]
        }
        return unique
    }
}
