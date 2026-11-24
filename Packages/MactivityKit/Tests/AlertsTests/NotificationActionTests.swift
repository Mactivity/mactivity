@testable import Alerts
import Core
import Foundation
import Testing
import UserNotifications

@Suite("Alert notification actions")
struct NotificationActionTests {
    @Test("A response maps to Show, Mute, or nothing", arguments: [
        (UNNotificationDefaultActionIdentifier, AlertNotificationAction.show),
        (AlertNotificationAction.showIdentifier, .show),
        (AlertNotificationAction.muteIdentifier, .mute),
        (UNNotificationDismissActionIdentifier, .ignore),
        ("app.mactivity.alert.quit", .ignore),
        ("", .ignore),
    ])
    func mapping(identifier: String, expected: AlertNotificationAction) {
        #expect(AlertNotificationAction(identifier: identifier) == expected)
    }

    @Test("Each app's category offers Show, then Mute Alerts for that app, and never Quit")
    func category() {
        let category = AlertNotificationAction.category(for: Fixture.app)
        #expect(category.identifier == "app.mactivity.alert.com.example.hog")
        #expect(category.actions.map(\.identifier) == [AlertNotificationAction.showIdentifier, AlertNotificationAction.muteIdentifier])
        #expect(category.actions.map(\.title) == ["Show", "Mute Alerts for Hog"])
        #expect(!category.actions.contains { $0.title.localizedCaseInsensitiveContains("quit") })
        // Show brings Mactivity forward; Mute doesn't need to.
        #expect(category.actions[0].options.contains(.foreground))
        #expect(!category.actions[1].options.contains(.foreground))
        #expect(!category.actions[1].options.contains(.destructive))
    }

    @Test("The request names its app's category; its title and body are the alert's own")
    func request() {
        let alert = Alert(rule: .highCPU, app: Fixture.app, firedAt: Fixture.now, title: "Hog is using a lot of CPU", body: "Body")
        let request = NotificationDeliverer.request(for: alert)
        #expect(request.content.categoryIdentifier == AlertNotificationAction.categoryIdentifier(for: Fixture.app.id))
        #expect(request.content.title == "Hog is using a lot of CPU")
        #expect(request.content.body == "Body")
    }

    @Test("Categories: the alerting app moves to the newest, the oldest drop past the limit")
    func registry() {
        let apps = (0 ..< 3).map { AppIdentity(id: "app\($0)", name: "App \($0)", bundleID: nil, iconKey: "", kind: .app) }
        #expect(AlertCategoryRegistry.updated([], adding: apps[0]) == [apps[0]])
        #expect(AlertCategoryRegistry.updated([apps[0], apps[1]], adding: apps[0]) == [apps[1], apps[0]])
        #expect(AlertCategoryRegistry.updated([apps[0], apps[1]], adding: apps[1]) == [apps[0], apps[1]])
        #expect(AlertCategoryRegistry.updated([apps[0], apps[1]], adding: apps[2], limit: 2) == [apps[1], apps[2]])
        // A renamed app gets its new name on the button.
        let renamed = AppIdentity(id: "app1", name: "Renamed", bundleID: nil, iconKey: "", kind: .app)
        #expect(AlertCategoryRegistry.updated([apps[0], apps[1]], adding: renamed) == [apps[0], renamed])
    }
}
