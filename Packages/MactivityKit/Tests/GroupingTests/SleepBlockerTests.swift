import Core
import Foundation
@testable import Grouping
import Testing

@Suite("Sleep blockers (D-096)")
struct SleepBlockerTests {
    /// As `IOPMCopyAssertionsByProcess` returned them on a real Mac, trimmed.
    private let raw: [Int32: [[String: Any]]] = [
        29287: [[
            "AssertType": "NoIdleSleepAssertion",
            "AssertName": "Electron",
            "AssertLevel": 255,
            "Process Name": "Claude",
            "AssertionId": NSNumber(value: 7),
        ]],
        354: [[
            "AssertType": "PreventUserIdleSystemSleep",
            "AssertName": "Powerd - Prevent sleep while display is on",
            "AssertLevel": 255,
            "Process Name": "powerd",
        ]],
        731: [["AssertType": "SystemIsActive", "AssertName": "Background transfer", "AssertLevel": 255, "Process Name": "nsurlsessiond"]],
        690: [[
            "AssertType": "PreventUserIdleSystemSleep",
            "AssertName": "BTLEAdvertisement",
            "AssertLevel": 255,
            "Process Name": "sharingd",
            "TimeoutSeconds": 30.0,
        ]],
        812: [["AssertType": "PreventUserIdleDisplaySleep", "AssertName": "Video playing", "AssertLevel": 255, "Process Name": "IINA"]],
        900: [["AssertType": "PreventUserIdleSystemSleep", "AssertName": "Released", "AssertLevel": 0, "Process Name": "Old"]],
    ]

    @Test("Only lasting assertions that stop sleep, never powerd's own")
    func filter() {
        let found = LiveSleepBlockers.blockers(from: raw) { _, name in AppIdentity.other(executableName: name) }
        #expect(found.map(\.app.name) == ["Claude", "IINA"])
        #expect(found.first?.keeps == .system)
        #expect(found.last?.keeps == .display)
        #expect(found.first?.reason == "Electron")
    }

    @Test("macOS's daemons are system; its apps and the user's tools aren't (D-108)")
    func systemDaemons() {
        #expect(LiveSleepBlockers.isSystemDaemon("/usr/libexec/sharingd"))
        #expect(LiveSleepBlockers.isSystemDaemon("/System/Library/CoreServices/powerd.bundle/powerd"))
        #expect(!LiveSleepBlockers.isSystemDaemon("/System/Applications/Music.app/Contents/MacOS/Music"))
        #expect(!LiveSleepBlockers.isSystemDaemon("/usr/bin/caffeinate"))
        #expect(!LiveSleepBlockers.isSystemDaemon("/Applications/Claude.app/Contents/MacOS/Claude"))
    }
}
