import Core
import Foundation

/// The metric tabs' search: an app matches by its name, or through one of its processes, by the
/// process's name or its exact PID. An app that matches only through processes shows expanded to
/// just those processes, so the reason it's in the list is on screen.
struct AppListSearch: Equatable {
    /// Every app that matches, by name or through a process.
    let appIDs: Set<AppIdentity.ID>
    /// Apps that match only through their processes, and those processes' PIDs.
    let processMatches: [AppIdentity.ID: Set<Int32>]

    /// Nil for an empty query: nothing is filtered.
    init?(_ query: String, apps: [AppAggregate], processesByApp: [AppIdentity.ID: [ProcessSample]]) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return nil
        }
        let pid = Int32(query)
        var appIDs: Set<AppIdentity.ID> = []
        var processMatches: [AppIdentity.ID: Set<Int32>] = [:]
        for app in apps {
            if app.app.name.localizedStandardContains(query) {
                appIDs.insert(app.id)
                continue
            }
            let matching = (processesByApp[app.id] ?? [])
                .filter { $0.pid == pid || $0.name.localizedStandardContains(query) }
                .map(\.pid)
            if !matching.isEmpty {
                appIDs.insert(app.id)
                processMatches[app.id] = Set(matching)
            }
        }
        self.appIDs = appIDs
        self.processMatches = processMatches
    }

    /// The processes an app's row shows: all of them, or only the matching ones when the app
    /// matched through them.
    func processes(_ processes: [ProcessSample], of app: AppIdentity.ID) -> [ProcessSample] {
        guard let pids = processMatches[app] else {
            return processes
        }
        return processes.filter { pids.contains($0.pid) }
    }

    /// Opened for the search: the app matched only through its processes.
    func expands(_ app: AppIdentity.ID) -> Bool {
        processMatches[app] != nil
    }
}
