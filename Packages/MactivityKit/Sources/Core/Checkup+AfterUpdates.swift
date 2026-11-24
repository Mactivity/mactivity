import Foundation

extension Checkup {
    /// One line for the updates that made an app, or macOS, notably heavier (D-206).
    static func afterUpdates(_ inputs: CheckupInputs) -> [CheckupItem] {
        guard !inputs.heavierUpdates.isEmpty else {
            return []
        }
        let names = inputs.heavierUpdates.prefix(3).map(\.update.name).formatted(.list(type: .and))
        return [CheckupItem(
            id: "afterUpdates", area: .afterUpdates, severity: .suggestion,
            title: String(localized: "Heavier since an update: \(names)", bundle: .strings),
            detail: String(
                localized: "Compared with the week before each update. History → After updates shows by how much.",
                bundle: .strings
            )
        )]
    }

    /// One line for the projects whose builds got slower this week (D-209).
    static func slowerBuilds(_ inputs: CheckupInputs) -> [CheckupItem] {
        guard !inputs.slowerBuilds.isEmpty else {
            return []
        }
        let names = inputs.slowerBuilds.prefix(3).map(\.project).formatted(.list(type: .and))
        return [CheckupItem(
            id: "slowerBuilds", area: .builds, severity: .suggestion,
            title: String(localized: "Builds got slower this week: \(names)", bundle: .strings),
            detail: String(
                localized: "Compared with the three weeks before. History → Build times shows each project's builds.",
                bundle: .strings
            )
        )]
    }
}
