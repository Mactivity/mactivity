import Foundation

/// Checkup items for drives (D-157) and changes over time (D-160).
extension Checkup {
    /// What uses more than it used to (D-160): the two apps whose memory grew most, and a
    /// battery that drains faster.
    static func trends(_ inputs: CheckupInputs) -> [CheckupItem] {
        var items = inputs.memoryGrowth.prefix(2).map { growth in
            let now = Formatters.memory(growth.now)
            let before = Formatters.memory(growth.before)
            return CheckupItem(
                id: "trend:memory:\(growth.app.id)", area: .memory, severity: .suggestion,
                title: String(
                    localized: "\(growth.app.name) uses more memory than it used to",
                    bundle: .strings,
                    comment: "Checkup; an app's name"
                ),
                detail: String(
                    localized: """
                    \(now) on average this week, up from \(before) in the three weeks before. \
                    Quitting it now and then, or an update, may help.
                    """,
                    bundle: .strings
                )
            )
        }
        if let drain = inputs.drain, Trends.drainsFaster(now: drain.now, before: drain.before) {
            let now = Formatters.percent(drain.now, fractionDigits: 1)
            let before = Formatters.percent(drain.before, fractionDigits: 1)
            items.append(CheckupItem(
                id: "trend:drain", area: .battery, severity: .suggestion,
                title: String(localized: "Your battery empties faster than it used to", bundle: .strings),
                detail: String(
                    localized: """
                    \(now) an hour on battery this week, up from \(before) in the three weeks before. \
                    The Battery tab shows which apps used it.
                    """,
                    bundle: .strings
                )
            ))
        }
        return items
    }

    /// A drive that warns about itself is worth doing something about now: back up first.
    static func drives(_ inputs: CheckupInputs) -> [CheckupItem] {
        inputs.drives.compactMap { drive in
            guard drive.verdict != .good, let problem = drive.problem else {
                return nil
            }
            let failing = drive.verdict == .failing
            return CheckupItem(
                id: "drive:\(drive.id)", area: .disk, severity: failing ? .attention : .suggestion,
                title: failing
                    ? String(localized: "\(drive.model) reports a problem", bundle: .strings, comment: "Checkup; a drive's model name")
                    : String(localized: "\(drive.model) is wearing out", bundle: .strings, comment: "Checkup; a drive's model name"),
                detail: failing
                    ? problem + " " + String(localized: "Make sure your backups are current.", bundle: .strings)
                    : problem + " " + String(localized: "Plan to replace it; until then, keep backups current.", bundle: .strings)
            )
        }
    }
}
