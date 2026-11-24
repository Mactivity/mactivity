import Core
import Foundation

/// When this Mac was unlocked and how, from what loginwindow writes to the unified log (D-288).
///
/// - Symbol: not a function but log messages (subsystem `com.apple.loginwindow.logging`, category
///   `Standard`), read with `/usr/bin/log show`. None of it is documented. Lines read, as seen on
///   macOS 27.2 at real unlocks unless marked otherwise:
///   - `-[LWScreenLock handleUnlockResult:]_block_invoke | entered, lockResult: 1`: unlocked. A
///     `lockResult: 0` is a wake where the screen wasn't locked, which isn't an unlock.
///   - `… | username is provided elsewhere, LocalAuth 1, Continuity 0`: Touch ID.
///     `LocalAuth 0, Continuity 1` is the Apple Watch (not seen: no Watch on the Mac this was read
///     on; the format is from loginwindow's own strings).
///   - `… | The current user is trying to unlock the screen`: a password. Seen once, at the unlock
///     after a restart, next to `Password required to enable Touch ID`.
///   - `… | Screensaver authorization failed: %d, looking for auth error` and
///     `… | ======== APEventTouchIDNoMatch =========`: a failed attempt. **Neither has been seen
///     in a real log.** They're from loginwindow's strings, and nobody has tried a wrong password
///     on the Mac this was written on. So a failure found is reported, and none found is never
///     read as none happened.
/// - Framework: loginwindow.app (private).
/// - If Apple changes or removes it: `read` returns `.unreadable` (the command fails, or
///   authorizations with no unlocks), each unlock it can't explain reads as `.unknown`, and no
///   lines at all is shown as nothing found, with why that may not mean what it seems.
public enum UnlockLog {
    /// Narrow on purpose: loginwindow's other lines name the user and quote command lines.
    static let predicate = """
    subsystem == "com.apple.loginwindow.logging" AND category == "Standard" AND (\
    eventMessage CONTAINS "entered, lockResult:" OR \
    eventMessage CONTAINS "trying to unlock the screen" OR \
    eventMessage CONTAINS "username is provided elsewhere" OR \
    eventMessage CONTAINS "Screensaver authorization" OR \
    eventMessage CONTAINS "APEventTouchIDNoMatch")
    """

    /// How long before an unlock a method's line can be. A real one is under a second.
    static let methodLasts: TimeInterval = 30
    /// `errAuthorizationCanceled`: the person gave up. Not a failed attempt.
    static let canceled = -60006

    /// Pure: `log show --style ndjson` output as unlocks and failures.
    public static func reading(ndjson: Data) -> UnlockReading {
        let formatter = LogTimestamp.formatter()
        var lines: [(at: Date, message: String)] = []
        for line in ndjson.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = entry["eventMessage"] as? String,
                  let stamp = entry["timestamp"] as? String,
                  let at = formatter.date(from: stamp)
            else {
                continue
            }
            lines.append((at, message))
        }
        lines.sort { $0.at < $1.at }
        var tally = Tally()
        for (at, message) in lines {
            tally.add(message, at: at)
        }
        // Authorizations with no unlocks: the unlock's wording moved, and a count would be wrong.
        if tally.unlocks.isEmpty, tally.authorized > 0 {
            return .unreadable
        }
        return .read(UnlockLogReading(
            unlocks: tally.unlocks.reversed(), failures: tally.failures.reversed(), coveredFrom: lines.first?.at
        ))
    }

    /// What the lines add up to, read oldest first.
    private struct Tally {
        var unlocks: [UnlockEvent] = []
        var failures: [FailedUnlock] = []
        var authorized = 0
        /// The latest line saying how, until an unlock or a failure uses it.
        private var pending: (method: UnlockMethod, at: Date)?

        mutating func add(_ message: String, at: Date) {
            if message.contains("entered, lockResult: 1") {
                let method = pending.flatMap { at.timeIntervalSince($0.at) <= UnlockLog.methodLasts ? $0.method : nil }
                unlocks.append(UnlockEvent(at: at, method: method ?? .unknown))
                pending = nil
            } else if message.contains("The current user is trying to unlock the screen") {
                pending = (.password, at)
            } else if message.contains("username is provided elsewhere"), let method = UnlockLog.method(in: message) {
                pending = (method, at)
            } else if message.contains("Screensaver authorization succeeded") {
                authorized += 1
            } else if let code = UnlockLog.failureCode(in: message) {
                if code != UnlockLog.canceled {
                    failures.append(FailedUnlock(at: at, kind: pending?.method == .password ? .password : .other))
                }
                pending = nil
            } else if message.contains("APEventTouchIDNoMatch") {
                failures.append(FailedUnlock(at: at, kind: .touchID))
            }
        }
    }

    /// "… LocalAuth 1, Continuity 0". Touch ID when both say yes, as loginwindow tries it first.
    static func method(in message: String) -> UnlockMethod? {
        guard let local = message.range(of: "LocalAuth "), let continuity = message.range(of: ", Continuity ") else {
            return nil
        }
        let usesLocal = message[local.upperBound...].hasPrefix("1")
        let usesContinuity = message[continuity.upperBound...].hasPrefix("1")
        return usesLocal ? .touchID : usesContinuity ? .appleWatch : .unknown
    }

    /// The code in "Screensaver authorization failed: -60005, looking for auth error".
    static func failureCode(in message: String) -> Int? {
        guard let range = message.range(of: "Screensaver authorization failed: ") else {
            return nil
        }
        let digits = message[range.upperBound...].prefix { $0 == "-" || $0.isNumber }
        return Int(digits) ?? 0
    }

    /// What the log has, up to `days` back. Blocks for several seconds: call it off the main thread.
    public static func read(days: Int, now: Date) -> UnlockReading {
        let start = now.addingTimeInterval(-Double(days) * 86400)
        let arguments = [
            "show", "--style", "ndjson", "--start", LogTimestamp.argument(start), "--end", LogTimestamp.argument(now),
            "--predicate", predicate,
        ]
        guard let output = SensorIndicatorLog.run("/usr/bin/log", arguments, timeout: 60) else {
            return .unreadable
        }
        return reading(ndjson: output)
    }
}

/// `log show`'s dates, in and out.
enum LogTimestamp {
    static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return formatter
    }

    static func argument(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
        return formatter.string(from: date)
    }
}
