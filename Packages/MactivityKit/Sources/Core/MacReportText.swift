import Foundation

/// The words for what macOS flagged (D-212), for History and Checkup.
public enum MacReportText {
    /// "Google Chrome Helper, in Claude", or the process alone when the app is itself.
    public static func who(_ report: MacReport, owner: String?) -> String {
        let process = report.process ?? owner ?? ""
        guard let owner, !owner.isEmpty, owner != process else {
            // One of macOS's own: say what it does, "mds_stores (Spotlight indexing)" (D-214).
            return SystemProcesses.describe(process).map { "\(process) (\($0))" } ?? process
        }
        return String(localized: "\(process), in \(owner)", bundle: .strings, comment: "A process and the app it belongs to")
    }

    public static func describe(_ report: MacReport, owner: String?) -> String {
        let who = who(report, owner: owner)
        switch report.kind {
        case let .diskWrites(bytes, seconds):
            let amount = Formatters.bytes(bytes)
            let span = duration(seconds)
            let rate = Formatters.bytes(seconds > 0 ? bytes / seconds : 0)
            return String(
                localized: "\(who) wrote \(amount) to disk in \(span), \(rate) a second",
                bundle: .strings,
                comment: "macOS flagged heavy disk writes: who, how much, how long, the rate"
            )
        case .cpu where report.repeats > 1:
            return String(
                localized: "\(who) went past macOS's limit for processor use \(report.repeats) times",
                bundle: .strings,
                comment: "macOS flagged a process for heavy CPU use, repeatedly"
            )
        case .wakeups where report.repeats > 1:
            return String(
                localized: "\(who) went past macOS's limit for waking the processor \(report.repeats) times",
                bundle: .strings,
                comment: "macOS flagged a process for too many wake-ups, repeatedly"
            )
        case let .cpu(seconds, over):
            let busy = duration(seconds)
            let span = duration(over)
            return String(
                localized: "\(who) kept the processor busy for \(busy) of \(span)",
                bundle: .strings,
                comment: "macOS flagged heavy CPU use: who, CPU time, over how long"
            )
        case let .wakeups(count, over):
            let times = Int(count).formatted()
            let span = duration(over)
            return String(
                localized: "\(who) woke the processor \(times) times in \(span)",
                bundle: .strings,
                comment: "macOS flagged too many wake-ups"
            )
        case .memoryKill:
            return String(
                localized: "macOS closed \(who) because memory ran out",
                bundle: .strings,
                comment: "An app closed by macOS for lack of memory"
            )
        case .panic:
            return String(localized: "Your Mac restarted on its own (a kernel panic)", bundle: .strings)
        case .shutdownStall:
            return String(localized: "A shutdown hung before your Mac turned off", bundle: .strings)
        }
    }

    static func duration(_ seconds: Double) -> String {
        Duration.seconds(max(1, seconds.rounded())).formatted(.units(
            allowed: [.hours, .minutes, .seconds],
            width: .narrow,
            maximumUnitCount: 2
        ))
    }
}

extension Checkup {
    /// Up to three processes, each once, macOS's own saying what they do.
    static func processNames(_ reports: [MacReport]) -> String {
        var seen = Set<String>()
        return reports.compactMap(\.process).filter { seen.insert($0).inserted }.prefix(3)
            .map { process in SystemProcesses.describe(process).map { "\(process) (\($0))" } ?? process }
            .formatted(.list(type: .and))
    }

    /// What macOS flagged in the last week (D-212): heavy writers, apps closed for memory,
    /// restarts; and apps beachballing more than they used to.
    static func flagged(_ inputs: CheckupInputs) -> [CheckupItem] {
        var items: [CheckupItem] = []
        let notable = MacReport.collapsed(inputs.flagged).filter(\.isNotable)
        if notable.contains(where: \.isRestart) {
            items.append(CheckupItem(
                id: "restarts", area: .flagged, severity: .attention,
                title: String(localized: "Your Mac restarted on its own this week", bundle: .strings),
                detail: String(localized: "History → Flagged by macOS shows when, and what was running just before.", bundle: .strings)
            ))
        }
        let writers = notable.filter {
            if case .diskWrites = $0.kind {
                true
            } else {
                false
            }
        }
        if !writers.isEmpty {
            var seen = Set<String>()
            let names = writers.compactMap(\.process).filter { seen.insert($0).inserted }.prefix(3)
                .map { process in SystemProcesses.describe(process).map { "\(process) (\($0))" } ?? process }
                .formatted(.list(type: .and))
            items.append(CheckupItem(
                id: "diskWrites", area: .flagged, severity: .suggestion,
                title: String(localized: "Heavy disk writing: \(names)", bundle: .strings),
                detail: String(
                    localized: """
                    macOS flagged them for writing far more than usual, which wears the SSD. \
                    History → Flagged by macOS shows how much.
                    """,
                    bundle: .strings
                )
            ))
        }
        let closed = notable.filter { $0.kind == .memoryKill }
        if !closed.isEmpty {
            let names = processNames(closed)
            items.append(CheckupItem(
                id: "memoryKills", area: .flagged, severity: .attention,
                title: String(localized: "macOS closed apps because memory ran out: \(names)", bundle: .strings),
                detail: String(
                    localized: """
                    Quitting apps you aren't using leaves more for the rest. \
                    Your next Mac says how much memory your work needs.
                    """,
                    bundle: .strings
                )
            ))
        }
        items += worseHangs(inputs)
        return items
    }

    /// Apps beachballing more this week than before (D-212).
    static func worseHangs(_ inputs: CheckupInputs) -> [CheckupItem] {
        var items: [CheckupItem] = []
        if let worst = inputs.worseHangs.first {
            let names = inputs.worseHangs.prefix(3).map(\.appName).formatted(.list(type: .and))
            let before = Int(worst.before.rounded())
            items.append(CheckupItem(
                id: "hangs", area: .crashes, severity: .suggestion,
                title: String(localized: "Beachballing more this week: \(names)", bundle: .strings),
                detail: String(
                    localized: "\(worst.appName) stopped responding \(worst.thisWeek) times this week, about \(before) a week before.",
                    bundle: .strings
                )
            ))
        }
        return items
    }
}
