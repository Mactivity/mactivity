@testable import Alerts
import Core
import Foundation
import Testing

@Suite("Alert deep links")
struct AlertDeepLinkTests {
    func alert(_ rule: AlertRule) -> Alert {
        Alert(rule: rule, app: Fixture.app, firedAt: Fixture.now, title: "Title", body: "Body")
    }

    @Test("userInfo round-trips to the app and the rule's tab", arguments: AlertRule.allCases)
    func roundTrip(rule: AlertRule) throws {
        let userInfo = AlertDeepLink.userInfo(for: alert(rule))
        let parsed = try #require(AlertDeepLink.parse(userInfo))
        #expect(parsed.appID == Fixture.app.id)
        #expect(parsed.metric == rule.metric)
        #expect(userInfo[AlertDeepLink.ruleKey] as? String == rule.rawValue)
    }

    @Test("Keys are the documented strings")
    func keys() {
        #expect(AlertDeepLink.appIDKey == "appID")
        #expect(AlertDeepLink.metricKey == "metric")
        #expect(AlertDeepLink.ruleKey == "rule")
    }

    @Test("Malformed payloads don't parse")
    func malformed() {
        #expect(AlertDeepLink.parse([:]) == nil)
        #expect(AlertDeepLink.parse(["appID": "com.example.hog"]) == nil)
        #expect(AlertDeepLink.parse(["appID": "com.example.hog", "metric": "bogus"]) == nil)
        #expect(AlertDeepLink.parse(["appID": 42, "metric": "cpu"]) == nil)
        #expect(AlertDeepLink.parse(["appID": "", "metric": "cpu"]) == nil)
    }

    @Test("The notification request carries the alert (built, never posted)")
    func request() {
        let alert = alert(.growingMemory)
        let request = NotificationDeliverer.request(for: alert)
        #expect(request.identifier == alert.id.uuidString)
        #expect(request.content.title == "Title")
        #expect(request.content.body == "Body")
        #expect(request.content.threadIdentifier == Fixture.app.id)
        #expect(request.content.sound == nil)
        #expect(request.trigger == nil)
        let parsed = AlertDeepLink.parse(request.content.userInfo)
        #expect(parsed?.appID == Fixture.app.id)
        #expect(parsed?.metric == .memory)
        #expect(request.content.userInfo[AlertDeepLink.ruleKey] as? String == "growingMemory")
    }
}
