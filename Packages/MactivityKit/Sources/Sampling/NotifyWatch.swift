import Darwin
import Foundation
import notify

/// A notifyd name polled for posts: `posted()` is true when the name was posted since the last
/// call, and on the first call. `notify_check` reads shared memory, so a poll every tick costs no
/// IPC, where the value it guards (the network's primary interface, the power sources) is an XPC
/// round trip to configd or powerd (D-086). Public API (`notify(3)`).
final class NotifyWatch {
    private var token: Int32 = -1
    private let registered: Bool

    init(_ name: String) {
        registered = notify_register_check(name, &token) == NOTIFY_STATUS_OK
    }

    deinit {
        if registered {
            notify_cancel(token)
        }
    }

    /// True when posted since the last call. Always true if registration failed, so the caller
    /// falls back to reading every time.
    func posted() -> Bool {
        guard registered else {
            return true
        }
        var check: Int32 = 0
        guard notify_check(token, &check) == NOTIFY_STATUS_OK else {
            return true
        }
        return check != 0
    }

    /// Pure: read again when the name was posted, nothing was read yet, or the last read is older
    /// than `maxAge` (a safety net for a missed post).
    static func needsRead<Instant: InstantProtocol>(
        posted: Bool, lastRead: Instant?, now: Instant, maxAge: Duration
    ) -> Bool where Instant.Duration == Duration {
        guard !posted, let lastRead else {
            return true
        }
        return lastRead.duration(to: now) >= maxAge
    }
}
