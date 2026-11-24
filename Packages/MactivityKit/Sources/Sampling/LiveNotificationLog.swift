import Core
import Foundation
import PrivateAPIs

/// Notifications by app's real source (D-289): macOS's log, read on a background task.
public struct LiveNotificationLog: NotificationLogSource {
    public init() {}

    public func deliveries(from: Date, to: Date) async -> NotificationLogReading {
        await Task.detached(priority: .utility) {
            NotificationLog.read(from: from, to: to)
        }.value
    }
}
