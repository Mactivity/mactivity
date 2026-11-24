import Foundation

/// What macOS itself flagged (D-212), from the reports it keeps in /Library/Logs/DiagnosticReports:
/// a process writing, computing or waking far past its limits, apps closed because memory ran
/// out, and restarts the Mac didn't choose.
public struct MacReport: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// Bytes written over `seconds`.
        case diskWrites(bytes: Double, seconds: Double)
        /// Seconds of processor time over `seconds`.
        case cpu(seconds: Double, over: Double)
        /// Wake-ups over `seconds`.
        case wakeups(count: Double, over: Double)
        /// macOS closed `process` because the whole Mac ran short of memory.
        case memoryKill
        /// A kernel panic: the Mac restarted on its own.
        case panic(summary: String)
        /// A shutdown that hung before the Mac turned off.
        case shutdownStall
    }

    public let id: String
    public let at: Date
    public let kind: Kind
    /// The process the report is about: "Google Chrome Helper", "Safari".
    public let process: String?
    /// The app it belongs to, as the report's coalition names it: "com.anthropic.claudefordesktop".
    public let ownerBundleID: String?
    public let path: String
    /// Reports of the same kind for the same process this one stands for (`collapsed`).
    public let repeats: Int

    public init(id: String, at: Date, kind: Kind, process: String?, ownerBundleID: String?, path: String, repeats: Int = 1) {
        self.id = id
        self.at = at
        self.kind = kind
        self.process = process
        self.ownerBundleID = ownerBundleID
        self.path = path
        self.repeats = repeats
    }

    /// Worth showing: macOS writes a disk-writes report for any process past 2 GB in a day, which
    /// is routine; only 8 GB or more, or a sustained megabyte a second, is news. A processor report
    /// always says 90 seconds (macOS's limit is half a core over 3 minutes), so one is routine and
    /// three or more for the same process is news. The others always are.
    public var isNotable: Bool {
        switch kind {
        case let .diskWrites(bytes, seconds):
            bytes >= 8e9 || (seconds > 0 && bytes / seconds >= 1e6)
        case .cpu:
            repeats >= 3
        case .wakeups, .memoryKill, .panic, .shutdownStall:
            true
        }
    }

    /// The Mac restarted on its own. Not a shutdown stall: that's a shutdown someone chose,
    /// slow to finish.
    public var isRestart: Bool {
        if case .panic = kind {
            return true
        }
        return false
    }

    /// Processor and wake-up reports folded into one per process, the latest standing for the
    /// rest with their count; panics written twice (`panic-base`, `panic-full`) counted once.
    /// Newest first.
    public static func collapsed(_ reports: [MacReport]) -> [MacReport] {
        var groups: [String: [MacReport]] = [:]
        var kept: [MacReport] = []
        var panics: [Date] = []
        for report in reports.sorted(by: { $0.at > $1.at }) {
            switch report.kind {
            case .cpu:
                groups["cpu\u{1F}\(report.process ?? "")", default: []].append(report)
            case .wakeups:
                groups["wakeups\u{1F}\(report.process ?? "")", default: []].append(report)
            case .panic:
                if !panics.contains(where: { abs($0.timeIntervalSince(report.at)) < 300 }) {
                    panics.append(report.at)
                    kept.append(report)
                }
            default:
                kept.append(report)
            }
        }
        for group in groups.values {
            guard let latest = group.first else {
                continue
            }
            kept.append(MacReport(
                id: latest.id, at: latest.at, kind: latest.kind, process: latest.process, ownerBundleID: latest.ownerBundleID,
                path: latest.path, repeats: group.count
            ))
        }
        return kept.sorted { $0.at > $1.at }
    }
}

public protocol MacReportSource: Sendable {
    /// Reports since `since`, newest first.
    func macReports(since: Date) async -> [MacReport]
}

/// Reading the reports' text (D-212). Pure.
public enum MacReportParser {
    /// A resource report (`.diag`): `Key: value` lines, the event, and its figures.
    public static func resource(_ text: String, path: String) -> MacReport? {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(80) {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            if fields[key] == nil {
                fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        guard let event = fields["Event"], let stamp = fields["Date/Time"], let date = reportDate(stamp) else {
            return nil
        }
        let kind: MacReport.Kind
        switch event {
        case "disk writes":
            guard let bytes = fields["Writes caused"].flatMap(byteCount),
                  let seconds = fields["Writes duration"].flatMap({ Double($0.trimmingCharacters(in: CharacterSet(charactersIn: "s"))) })
            else {
                return nil
            }
            kind = .diskWrites(bytes: bytes, seconds: seconds)
        case "cpu usage":
            // "90 seconds cpu time over 105 seconds (86% cpu average), exceeding limit of …"
            guard let numbers = fields["CPU"].map(leadingNumbers), numbers.count >= 2 else {
                return nil
            }
            kind = .cpu(seconds: numbers[0], over: numbers[1])
        case "wakeups":
            // "45001 wakeups over the last 199 seconds (226 wakeups per second average), …"
            guard let numbers = fields["Wakeups"].map(leadingNumbers), numbers.count >= 2 else {
                return nil
            }
            kind = .wakeups(count: numbers[0], over: numbers[1])
        default:
            return nil
        }
        return MacReport(
            id: path, at: date, kind: kind, process: fields["Command"], ownerBundleID: fields["Resource Coalition"].flatMap(coalition),
            path: path
        )
    }

    /// A JetsamEvent (`bug_type` 298): the apps macOS closed because the whole Mac ran short of
    /// memory. Processes over their own limit (`per-process-limit`) or closed when idle are left out.
    public static func memoryKills(header: [String: Any], body: [String: Any], path: String) -> [MacReport] {
        guard header["bug_type"] as? String == "298",
              let stamp = (header["timestamp"] as? String) ?? (body["date"] as? String),
              let date = reportDate(stamp) else {
            return []
        }
        let shortage: Set = ["vm-pageshortage", "vnode-limit", "fc-thrashing", "vm-compressor-thrashing", "vm-compressor-space-shortage"]
        let processes = body["processes"] as? [[String: Any]] ?? []
        return processes.compactMap { process in
            // Above the idle band: macOS closes idle background processes first, routinely, with
            // the same reasons.
            guard let reason = process["reason"] as? String, shortage.contains(reason), let name = process["name"] as? String,
                  (process["priority"] as? Int ?? 0) > 0 else {
                return nil
            }
            let pid = process["pid"] as? Int ?? 0
            return MacReport(id: "\(path)#\(pid)", at: date, kind: .memoryKill, process: name, ownerBundleID: nil, path: path)
        }
    }

    /// A kernel panic (`bug_type` 210, or a `.panic` file): its first line of explanation.
    public static func panic(header: [String: Any], body: String, path: String) -> MacReport? {
        guard header["bug_type"] as? String == "210" || path.hasSuffix(".panic"),
              let stamp = header["timestamp"] as? String, let date = reportDate(stamp) else {
            return nil
        }
        // The body is JSON with a "panicString"; older files are plain text.
        let json = body.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let text = (json?["panicString"] as? String) ?? body
        let summary = text.split(separator: "\n").first { $0.contains("panic(") }.map { String($0.prefix(160)) } ?? ""
        return MacReport(id: path, at: date, kind: .panic(summary: summary), process: nil, ownerBundleID: nil, path: path)
    }

    /// "2147.52 MB", "137.44 GB", "512 KB" → bytes.
    static func byteCount(_ text: String) -> Double? {
        let parts = text.split(separator: " ")
        guard parts.count >= 2, let value = Double(parts[0]) else {
            return nil
        }
        let scale: Double = switch parts[1] {
        case "KB": 1e3
        case "MB": 1e6
        case "GB": 1e9
        case "TB": 1e12
        default: 1
        }
        return value * scale
    }

    /// The numbers at the start of a figure line, before its parenthesis.
    static func leadingNumbers(_ text: String) -> [Double] {
        let before = text.split(separator: "(").first.map(String.init) ?? text
        return before.split(whereSeparator: { !$0.isNumber && $0 != "." }).compactMap { Double($0) }
    }

    /// `"com.anthropic.claudefordesktop"(992)` → the bundle ID.
    static func coalition(_ text: String) -> String? {
        let parts = text.split(separator: "\"")
        return parts.count >= 2 ? String(parts[parts.count >= 3 ? 1 : 0]) : nil
    }

    /// "2026-10-11 17:37:37.289 -0700" or "2026-10-14 17:51:26.00 -0700".
    public static func reportDate(_ text: String) -> Date? {
        for format in ["yyyy-MM-dd HH:mm:ss.SSS Z", "yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss Z"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                return date
            }
        }
        return nil
    }
}

/// Beachballs, counted (D-212): an app hanging more this week than it used to. Pure.
public enum HangTrend {
    public struct Worse: Hashable, Sendable {
        public let appName: String
        public let thisWeek: Int
        /// Hangs a week, on average, in the three weeks before.
        public let before: Double
    }

    /// Apps with 3 or more hangs in the last 7 days, and at least twice their weekly average of
    /// the three weeks before. Only once the reports go back two weeks or more: with none older
    /// (macOS just installed, old reports pruned), every app would read "more than before".
    public static func worse(_ reports: [CrashReport], now: Date) -> [Worse] {
        guard reports.contains(where: { $0.at < now.addingTimeInterval(-14 * 86400) }) else {
            return []
        }
        let hangs = reports.filter { $0.kind == .hang }
        let weekStart = now.addingTimeInterval(-7 * 86400)
        let earlierStart = now.addingTimeInterval(-28 * 86400)
        return Dictionary(grouping: hangs, by: \.appName).compactMap { app, hangs in
            let recent = hangs.count { $0.at >= weekStart }
            let earlier = Double(hangs.count { $0.at >= earlierStart && $0.at < weekStart }) / 3
            guard recent >= 3, Double(recent) >= 2 * earlier else {
                return nil
            }
            return Worse(appName: app, thisWeek: recent, before: earlier)
        }
        .sorted { $0.thisWeek > $1.thisWeek }
    }
}
