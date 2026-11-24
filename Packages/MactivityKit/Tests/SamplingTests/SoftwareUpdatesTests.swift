import Core
import Foundation
@testable import Sampling
import Testing

@Suite("Pending software updates (D-120)")
struct SoftwareUpdatesTests {
    @Test("Software Update's recommended updates, by display name and version")
    func parse() {
        let plist: [String: Any] = [
            "LastSuccessfulDate": Date(),
            "RecommendedUpdates": [
                ["Display Name": "macOS Tahoe", "Display Version": "26.1", "Identifier": "MSU_UPDATE_25B78_patch_26.1"],
                ["Identifier": "Safari26.1TahoeAuto", "Display Name": "Safari", "Display Version": "26.1"],
            ],
        ]
        let found = LiveSoftwareUpdates.parse(plist)
        #expect(found.map(\.title) == ["macOS Tahoe 26.1", "Safari 26.1"])
        #expect(LiveSoftwareUpdates.parse(["RecommendedUpdates": [[String: Any]]()]).isEmpty)
        #expect(LiveSoftwareUpdates.parse([:]).isEmpty)
    }

    @Test("A version already in the name isn't repeated")
    func title() {
        #expect(PendingUpdate(name: "macOS Tahoe 26.1", version: "26.1").title == "macOS Tahoe 26.1")
        #expect(PendingUpdate(name: "Command Line Tools", version: nil).title == "Command Line Tools")
    }

    @Test("macOS updates from the install log, since a date (D-206)")
    func installLog() {
        let since = Date(timeIntervalSince1970: 1_790_000_000)
        let log: [[String: Any]] = [
            ["displayName": "macOS 27.0.1", "displayVersion": "27.0.1", "date": since.addingTimeInterval(86400)],
            ["displayName": "macOS 26.4", "displayVersion": "", "date": since.addingTimeInterval(-86400)],
            ["displayName": "XProtectPlistConfigData", "displayVersion": "5362", "date": since.addingTimeInterval(3600)],
            ["displayName": "macOS 27.1", "displayVersion": "", "date": since.addingTimeInterval(2 * 86400)],
        ]
        let found = LiveSoftwareUpdates.macOSUpdates(log, since: since)
        #expect(found.map(\.version) == ["27.0.1", "27.1"])
        #expect(found.allSatisfy { $0.app == nil && $0.name == "macOS" })
    }

    @Test("An app's version and when its Info.plist arrived; not before the date, not for non-apps")
    func appVersion() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("Demo-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: bundle) }
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleShortVersionString": "3.4.1"]
        try info.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let app = AppIdentity(id: "demo", name: "Demo", bundleID: "demo", iconKey: bundle.path, kind: .app)
        let update = try #require(LiveSoftwareUpdates.appUpdate(app, since: Date().addingTimeInterval(-60)))
        #expect(update.version == "3.4.1")
        #expect(LiveSoftwareUpdates.appUpdate(app, since: Date().addingTimeInterval(60)) == nil)
        let tool = AppIdentity(id: "t", name: "t", bundleID: nil, iconKey: bundle.path, kind: .terminal)
        #expect(LiveSoftwareUpdates.appUpdate(tool, since: .distantPast) == nil)
        let messages = AppIdentity(id: "m", name: "Messages", bundleID: nil, iconKey: "/System/Applications/Messages.app", kind: .app)
        #expect(LiveSoftwareUpdates.appUpdate(messages, since: .distantPast) == nil, "comes with macOS")
    }
}

/// What macOS flagged, read from files (D-212).
struct LiveMacReportsTests {
    @Test("A shutdown stall's date comes from its file name")
    func shutdownStall() throws {
        let report = try #require(LiveMacReports.shutdownStall(
            fileName: "shutdown_stall_2026-10-09-160145_M5Pro.shutdownStall",
            path: "/s"
        ))
        #expect(report.kind == .shutdownStall)
        #expect(Calendar.current.component(.hour, from: report.at) == 16)
    }
}
