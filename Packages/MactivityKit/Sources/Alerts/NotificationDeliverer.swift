import Core
import Foundation
import os
import UserNotifications

/// Posts alerts with UNUserNotificationCenter (spec 4.4). Silent by default.
///
/// Doesn't ask for permission: the app calls `requestAuthorization()` once, when alerts are
/// first turned on. Posting without permission throws, and `AlertMonitor` logs and carries on.
public final class NotificationDeliverer: AlertDeliverer, Sendable {
    private static let logger = Logger(subsystem: "app.mactivity.alerts", category: "notifications")

    private let categories = AlertCategoryRegistry()

    public init() {}

    public func deliver(_ alert: Alert) async throws {
        await categories.register(alert.app)
        try await UNUserNotificationCenter.current().add(Self.request(for: alert))
    }

    /// Asks for permission to show alerts. False when the user declines or the request fails.
    public static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
        } catch {
            logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// One notification per alert, grouped by app, carrying the deep link.
    static func request(for alert: Alert) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.threadIdentifier = alert.app.id
        content.categoryIdentifier = AlertNotificationAction.categoryIdentifier(for: alert.app.id)
        content.userInfo = AlertDeepLink.userInfo(for: alert)
        content.sound = nil
        return UNNotificationRequest(identifier: alert.id.uuidString, content: content, trigger: nil)
    }
}

/// Reads UNUserNotificationCenter's authorization for Mactivity. Never prompts.
public struct UserNotificationPermission: NotificationPermissionSource {
    public init() {}

    public func permission() async -> NotificationPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Self.permission(settings.authorizationStatus)
    }

    /// Provisional authorization delivers, quietly; it counts as allowed.
    static func permission(_ status: UNAuthorizationStatus) -> NotificationPermission {
        switch status {
        case .authorized, .provisional: .allowed
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .allowed
        }
    }
}

/// The notification payload that takes a click back to the right tab and app (spec 4.4).
public enum AlertDeepLink {
    public static let appIDKey = "appID"
    public static let metricKey = "metric"
    public static let ruleKey = "rule"
    /// A notification about no one app: which page it opens (the held alerts' summary opens Alerts).
    public static let pageKey = "page"
    public static let alertsPage = "alerts"

    /// The `userInfo` a notification for `alert` carries.
    public static func userInfo(for alert: Alert) -> [AnyHashable: Any] {
        [
            appIDKey: alert.app.id,
            metricKey: alert.rule.metric.rawValue,
            ruleKey: alert.rule.rawValue,
        ]
    }

    /// Parses a notification's userInfo back into (app ID, metric, rule) for deep-linking. The
    /// rule is nil for notifications from a version that didn't send one it knows.
    public static func parse(_ userInfo: [AnyHashable: Any]) -> (appID: AppIdentity.ID, metric: Metric, rule: AlertRule?)? {
        guard
            let appID = userInfo[appIDKey] as? String,
            !appID.isEmpty,
            let rawMetric = userInfo[metricKey] as? String,
            let metric = Metric(rawValue: rawMetric)
        else {
            return nil
        }
        return (appID, metric, (userInfo[ruleKey] as? String).flatMap(AlertRule.init(rawValue:)))
    }
}

/// The buttons on an alert notification, and what a response to one means. Show opens the
/// metric's tab with the app highlighted, like clicking the notification; Mute Alerts for <App>
/// adds the app to the muted apps. There's no Quit: quitting only happens in Mactivity, through
/// its confirmation (CLAUDE.md rule 4).
public enum AlertNotificationAction: Equatable, Sendable {
    /// The notification itself, or its Show button.
    case show
    /// Mute Alerts for the notification's app.
    case mute
    /// Dismissed, or a button this version doesn't know.
    case ignore

    public static let showIdentifier = "app.mactivity.alert.show"
    public static let muteIdentifier = "app.mactivity.alert.mute"
    /// Every alert category starts with this; the rest is the app's ID.
    static let categoryPrefix = "app.mactivity.alert."

    /// What a `UNNotificationResponse.actionIdentifier` asks for.
    public init(identifier: String) {
        switch identifier {
        case UNNotificationDefaultActionIdentifier, Self.showIdentifier: self = .show
        case Self.muteIdentifier: self = .mute
        default: self = .ignore
        }
    }

    /// One category per app, so the Mute button can name the app.
    static func categoryIdentifier(for appID: AppIdentity.ID) -> String {
        categoryPrefix + appID
    }

    /// Show, then Mute Alerts for <App>. Show brings Mactivity forward; Mute doesn't.
    static func category(for app: AppIdentity) -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryIdentifier(for: app.id),
            actions: [
                UNNotificationAction(
                    identifier: showIdentifier,
                    title: String(localized: "Show", bundle: .strings, comment: "Notification button: opens Mactivity on the alert"),
                    options: [.foreground]
                ),
                UNNotificationAction(
                    identifier: muteIdentifier,
                    title: String(
                        localized: "Mute Alerts for \(app.name)",
                        bundle: .strings,
                        comment: "Notification button: stops alerts about this app (an app name)"
                    ),
                    options: []
                ),
            ],
            intentIdentifiers: [],
            options: []
        )
    }
}

/// The alert categories macOS knows about: one per app alerted about lately, newest kept.
/// `setNotificationCategories` replaces the whole set, so the set is kept here.
actor AlertCategoryRegistry {
    /// Enough for every app a person sees alerts about in a while; an older notification still
    /// in Notification Center loses its buttons when its app drops off.
    static let limit = 32

    private var apps: [AppIdentity] = []

    func register(_ app: AppIdentity) async {
        let updated = Self.updated(apps, adding: app)
        guard updated != apps else {
            return
        }
        apps = updated
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories(Set(updated.map(AlertNotificationAction.category)))
        // Reading the set back waits for the notification server to take it, so the
        // notification posted next already has its buttons.
        _ = await center.notificationCategories()
    }

    /// The apps with a category after `app` alerts: it moves to the end (newest), the oldest
    /// drop past `limit`. Unchanged when the app is already newest under the same name.
    static func updated(_ apps: [AppIdentity], adding app: AppIdentity, limit: Int = limit) -> [AppIdentity] {
        if apps.last == app {
            return apps
        }
        let others = apps.filter { $0.id != app.id }
        return Array((others + [app]).suffix(limit))
    }
}
