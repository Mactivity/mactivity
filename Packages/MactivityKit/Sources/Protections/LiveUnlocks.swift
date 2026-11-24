import Core
import Foundation
import PrivateAPIs

/// Unlocks' real source (D-288): macOS's log, read on a background task while the card shows.
public struct LiveUnlocks: UnlockHistorySource {
    /// Further than the log has kept on any Mac seen, which is about a week.
    static let lookBackDays = 30

    public init() {}

    public func read(now: Date) async -> UnlockReading {
        await Task.detached(priority: .utility) {
            UnlockLog.read(days: Self.lookBackDays, now: now)
        }.value
    }
}
