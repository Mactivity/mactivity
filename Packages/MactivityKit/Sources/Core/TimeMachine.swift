import Foundation

/// Time Machine, watched (D-216): whether it's set up, and when it last backed up.
public struct TimeMachineStatus: Hashable, Sendable {
    /// Automatic backups are on.
    public let isAutomatic: Bool
    /// The newest backup on any destination; nil when none is known.
    public let lastBackup: Date?
    /// The backup disk's name, when the settings keep it.
    public let destination: String?

    public init(isAutomatic: Bool, lastBackup: Date?, destination: String?) {
        self.isAutomatic = isAutomatic
        self.lastBackup = lastBackup
        self.destination = destination
    }

    /// Backups have stopped: automatic, and nothing for `days` days.
    public func hasStopped(now: Date, days: Double = 7) -> Bool {
        guard isAutomatic, let lastBackup else {
            return false
        }
        return now.timeIntervalSince(lastBackup) >= days * 86400
    }

    /// From /Library/Preferences/com.apple.TimeMachine.plist. Pure: nil when no backup disk is
    /// set up (`Destinations` empty or missing).
    public static func parse(_ plist: [String: Any]) -> TimeMachineStatus? {
        let destinations = plist["Destinations"] as? [[String: Any]] ?? []
        guard !destinations.isEmpty else {
            return nil
        }
        let dates = destinations.flatMap { destination -> [Date] in
            (destination["SnapshotDates"] as? [Date] ?? []) + [destination["ReferenceLocalSnapshotDate"] as? Date].compactMap { $0 }
        }
        let name = destinations.lazy.compactMap { ($0["LastKnownVolumeName"] as? String) ?? ($0["VolumeName"] as? String) }.first
        return TimeMachineStatus(isAutomatic: plist["AutoBackup"] as? Bool ?? false, lastBackup: dates.max(), destination: name)
    }
}

extension Checkup {
    /// Time Machine's automatic backups stopped a week or more ago (D-216).
    static func timeMachine(_ inputs: CheckupInputs) -> [CheckupItem] {
        guard let stopped = inputs.timeMachineStopped else {
            return []
        }
        let since = stopped.last.formatted(date: .abbreviated, time: .omitted)
        return [CheckupItem(
            id: "timeMachine", area: .timeMachine, severity: .attention,
            title: String(localized: "Time Machine hasn't backed up in \(stopped.days) days", bundle: .strings),
            detail: String(
                localized: """
                Automatic backups are on, but none has finished since \(since). \
                Connect the backup disk, or open Time Machine settings to see why.
                """,
                bundle: .strings
            )
        )]
    }
}
