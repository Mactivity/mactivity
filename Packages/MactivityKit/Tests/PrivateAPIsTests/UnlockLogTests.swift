import Core
import Foundation
@testable import PrivateAPIs
import Testing

/// Unlocks from loginwindow's log lines (D-288). `unified-log-unlocks.ndjson` is real output from
/// macOS 27.2, with the times changed. The failure and Apple Watch lines below are NOT: no failed attempt and no Watch were
/// available, so they're built from the format strings in loginwindow's own binary.
struct UnlockLogTests {
    private func fixture() throws -> Data {
        try Data(contentsOf: Fixtures.directory.appendingPathComponent("unified-log-unlocks.ndjson"))
    }

    private func line(_ stamp: String, _ message: String) -> String {
        let entry = ["timestamp": "2026-11-04 \(stamp).000000-0700", "eventMessage": message]
        let data = (try? JSONSerialization.data(withJSONObject: entry)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private func reading(_ lines: String...) -> UnlockReading {
        UnlockLog.reading(ndjson: Data(lines.joined(separator: "\n").utf8))
    }

    private let unlocked = "-[LWScreenLock handleUnlockResult:]_block_invoke | entered, lockResult: 1"
    private let succeeded = "-[LWScreenLockAuthentication x] | Screensaver authorization succeeded"
    private let password = "-[LWScreenLockAuthentication x] | The current user is trying to unlock the screen"

    @Test("Real unlocks: Touch ID and the password told apart, and one with nothing around it unknown")
    func realLines() throws {
        guard case let .read(found) = try UnlockLog.reading(ndjson: fixture()) else {
            Issue.record("Should read")
            return
        }
        #expect(found.unlocks.map(\.method) == [.touchID, .password, .touchID, .touchID, .unknown])
        #expect(found.byMethod.first?.method == .touchID)
        #expect(found.byMethod.first?.count == 3)
        // Newest first, and the span is the earliest line's.
        #expect(found.unlocks[0].at > found.unlocks[1].at)
        #expect(found.coveredFrom == found.unlocks.last?.at)
        // No failure in these lines, which the card never turns into "0 failed".
        #expect(found.failures.isEmpty)
    }

    @Test("A wake with the screen not locked isn't an unlock")
    func notLocked() {
        let found = reading(line("10:00:00", "-[LWScreenLock handleUnlockResult:]_block_invoke | entered, lockResult: 0"))
        #expect(found == .read(UnlockLogReading(unlocks: [], failures: [], coveredFrom: found.coveredFromForTest)))
    }

    @Test("From loginwindow's strings: the Apple Watch's hints")
    func watch() {
        let found = reading(
            line("10:00:00", "-[LWScreenLockAuthentication x] | username is provided elsewhere, LocalAuth 0, Continuity 1"),
            line("10:00:01", succeeded),
            line("10:00:01", unlocked)
        )
        #expect(found.unlocksForTest.map(\.method) == [.appleWatch])
        #expect(UnlockLog.method(in: "LocalAuth 0, Continuity 0") == .unknown)
        #expect(UnlockLog.method(in: "LocalAuth 1, Continuity 1") == .touchID)
        #expect(UnlockLog.method(in: "wording moved") == nil)
    }

    @Test("From loginwindow's strings: a wrong password and an unknown finger are failures; giving up isn't")
    func failures() {
        let found = reading(
            line("10:00:00", password),
            line("10:00:01", "-[LWScreenLockAuthentication x] | Screensaver authorization failed: -60005, looking for auth error"),
            line("10:00:05", "-[LWAuthServiceManager event:eventHints:reply:] | ======== APEventTouchIDNoMatch ========="),
            line("10:00:06", "-[LWScreenLockAuthentication x] | Screensaver authorization failed: -60006, looking for auth error"),
            line("10:00:09", "-[LWScreenLockAuthentication x] | Screensaver authorization failed: -60005, looking for auth error"),
            line("10:00:20", password),
            line("10:00:21", succeeded),
            line("10:00:21", unlocked)
        )
        #expect(found.failuresForTest.map(\.kind) == [.other, .touchID, .password])
        #expect(found.unlocksForTest.map(\.method) == [.password])
    }

    @Test("A method's line too long before the unlock doesn't explain it")
    func stale() {
        let found = reading(line("10:00:00", password), line("10:05:00", unlocked))
        #expect(found.unlocksForTest.map(\.method) == [.unknown])
    }

    @Test("Authorizations with no unlocks: the wording moved, so it can't be read")
    func wordingMoved() {
        #expect(reading(line("10:00:00", succeeded), line("10:00:01", "unlock finished")) == .unreadable)
    }

    @Test("Nothing in the log, or lines that aren't JSON, is nothing found, not a count")
    func nothing() {
        #expect(reading() == .read(UnlockLogReading(unlocks: [], failures: [], coveredFrom: nil)))
        #expect(reading("not json", "{\"count\":0}") == .read(UnlockLogReading(unlocks: [], failures: [], coveredFrom: nil)))
    }

    @Test(
        "Live: this Mac's log reads, with unlocks found",
        .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_LIVE_TESTS"] != nil)
    )
    func live() {
        guard case let .read(found) = UnlockLog.read(days: 30, now: Date()) else {
            Issue.record("The log should read")
            return
        }
        #expect(!found.unlocks.isEmpty)
    }
}

private extension UnlockReading {
    var unlocksForTest: [UnlockEvent] {
        if case let .read(found) = self {
            return found.unlocks
        }
        return []
    }

    var failuresForTest: [FailedUnlock] {
        if case let .read(found) = self {
            return found.failures
        }
        return []
    }

    var coveredFromForTest: Date? {
        if case let .read(found) = self {
            return found.coveredFrom
        }
        return nil
    }
}
