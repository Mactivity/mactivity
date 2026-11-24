import Core
import Foundation
import Testing
@testable import UI

/// The metric tabs' search: app names, process names, exact PIDs.
@Suite("App list search")
struct AppListSearchTests {
    private static func app(_ id: String, _ name: String) -> AppAggregate {
        AppAggregate(
            app: AppIdentity(id: id, name: name, bundleID: id, iconKey: "", kind: .app),
            processCount: 2, cpuPercent: 1, memoryBytes: 1, energyMW: nil,
            diskReadBPS: 0, diskWriteBPS: 0, netInBPS: nil, netOutBPS: nil, gpuPercent: nil
        )
    }

    private static func process(_ pid: Int32, _ name: String, app: AppIdentity.ID) -> ProcessSample {
        ProcessSample(
            pid: pid, app: app, name: name, cpuPercent: 1, footprintBytes: 1,
            diskReadBPS: 0, diskWriteBPS: 0, energyMW: nil, netInBPS: nil, netOutBPS: nil, gpuPercent: nil
        )
    }

    private static let apps = [app("com.apple.Safari", "Safari"), app("com.microsoft.VSCode", "Visual Studio Code")]
    private static let processes: [AppIdentity.ID: [ProcessSample]] = [
        "com.apple.Safari": [process(900, "Safari", app: "com.apple.Safari"), process(901, "Safari Web Content", app: "com.apple.Safari")],
        "com.microsoft.VSCode": [
            process(1200, "Code Helper (Renderer)", app: "com.microsoft.VSCode"),
            process(1201, "node", app: "com.microsoft.VSCode"),
        ],
    ]

    private func search(_ query: String) -> AppListSearch? {
        AppListSearch(query, apps: Self.apps, processesByApp: Self.processes)
    }

    @Test("An empty or blank query filters nothing", arguments: ["", "   ", "\n"])
    func empty(query: String) {
        #expect(search(query) == nil)
    }

    @Test("An app name matches the app, which isn't opened and keeps every process")
    func appName() throws {
        let found = try #require(search("safari"))
        #expect(found.appIDs == ["com.apple.Safari"])
        #expect(!found.expands("com.apple.Safari"))
        let all = Self.processes["com.apple.Safari"] ?? []
        #expect(found.processes(all, of: "com.apple.Safari").count == 2)
    }

    @Test("A process name matches its app, opened to just that process")
    func processName() throws {
        let found = try #require(search("NODE"))
        #expect(found.appIDs == ["com.microsoft.VSCode"])
        #expect(found.expands("com.microsoft.VSCode"))
        let rows = found.processes(Self.processes["com.microsoft.VSCode"] ?? [], of: "com.microsoft.VSCode")
        #expect(rows.map(\.pid) == [1201])
    }

    @Test("A PID matches exactly, not as a prefix")
    func pid() throws {
        let found = try #require(search("901"))
        #expect(found.appIDs == ["com.apple.Safari"])
        #expect(found.processes(Self.processes["com.apple.Safari"] ?? [], of: "com.apple.Safari").map(\.pid) == [901])
        #expect(search("90")?.appIDs.isEmpty == true)
    }

    @Test("Diacritics and case don't matter")
    func folding() {
        #expect(search("SAFARÍ")?.appIDs == ["com.apple.Safari"])
    }

    @Test("Nothing matches: an empty result, which the list shows as No Results")
    func noMatch() throws {
        let found = try #require(search("zzz"))
        #expect(found.appIDs.isEmpty)
        #expect(found.processMatches.isEmpty)
    }
}
