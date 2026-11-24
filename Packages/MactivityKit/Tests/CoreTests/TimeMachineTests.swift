@testable import Core
import Foundation
import Testing

/// Time Machine, watched (D-216).
struct TimeMachineTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("The newest backup across destinations, the disk's name, and whether it's automatic")
    func parse() throws {
        let plist: [String: Any] = [
            "AutoBackup": true,
            "Destinations": [
                ["LastKnownVolumeName": "Backup", "SnapshotDates": [now - 3 * 86400, now - 86400]],
                ["SnapshotDates": [now - 10 * 86400]],
            ],
        ]
        let status = try #require(TimeMachineStatus.parse(plist))
        #expect(status.isAutomatic)
        #expect(status.lastBackup == now - 86400)
        #expect(status.destination == "Backup")
        #expect(!status.hasStopped(now: now))
        #expect(status.hasStopped(now: now + 7 * 86400))
    }

    @Test("Not set up: nothing; automatic off: never 'stopped'")
    func edges() {
        #expect(TimeMachineStatus.parse(["PreferencesVersion": 6]) == nil)
        let manual = TimeMachineStatus(isAutomatic: false, lastBackup: now - 30 * 86400, destination: nil)
        #expect(!manual.hasStopped(now: now))
    }
}
