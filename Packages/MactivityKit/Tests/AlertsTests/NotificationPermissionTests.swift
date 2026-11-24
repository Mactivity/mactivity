@testable import Alerts
import Core
import Testing
import UserNotifications

@Suite("Notification permission")
struct NotificationPermissionTests {
    @Test("Authorized and provisional deliver; denied and never asked don't")
    func mapping() {
        #expect(UserNotificationPermission.permission(.authorized) == .allowed)
        #expect(UserNotificationPermission.permission(.provisional) == .allowed)
        #expect(UserNotificationPermission.permission(.denied) == .denied)
        #expect(UserNotificationPermission.permission(.notDetermined) == .notDetermined)
        #expect(!NotificationPermission.allowed.isOff)
        #expect(NotificationPermission.denied.isOff)
        #expect(NotificationPermission.notDetermined.isOff)
    }
}
