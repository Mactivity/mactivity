@testable import Alerts
import Core
import Foundation
import Testing

/// Quiet while you present (1.6).
struct HoldingDelivererTests {
    actor Inbox: AlertDeliverer {
        private(set) var delivered: [Alert] = []
        private(set) var summaries: [(title: String, body: String)] = []

        func deliver(_ alert: Alert) async throws {
            delivered.append(alert)
        }

        func summarize(_ title: String, _ body: String) {
            summaries.append((title, body))
        }
    }

    actor Presenting: PresentingSource {
        var reason: PresentingReason?

        init(_ reason: PresentingReason?) {
            self.reason = reason
        }

        func set(_ reason: PresentingReason?) {
            self.reason = reason
        }

        func current() async -> PresentingReason? {
            reason
        }
    }

    func alert(_ title: String, at seconds: TimeInterval = 0, rule: AlertRule = .highCPU) -> Alert {
        Alert(
            rule: rule,
            app: AppIdentity(id: title, name: title, bundleID: nil, iconKey: "other", kind: .app),
            firedAt: Date(timeIntervalSince1970: 1_790_000_000 + seconds), title: title, body: ""
        )
    }

    func holding(
        _ inbox: Inbox, _ presenting: Presenting, enabled: Bool = true, longest: Duration = .seconds(3600)
    ) -> HoldingDeliverer {
        HoldingDeliverer(
            inner: inbox, presenting: presenting, isEnabled: { enabled }, checkEvery: .milliseconds(10), longest: longest,
            summary: { await inbox.summarize($0, $1) }
        )
    }

    @Test("Not presenting, or turned off: delivered at once")
    func immediate() async throws {
        let inbox = Inbox()
        try await holding(inbox, Presenting(nil)).deliver(alert("A"))
        try await holding(inbox, Presenting(.call), enabled: false).deliver(alert("B"))
        #expect(await inbox.delivered.map(\.title) == ["A", "B"])
    }

    @Test("On a call: held, then one summary when it's over")
    func heldThenSummarized() async throws {
        let inbox = Inbox()
        let presenting = Presenting(.call)
        let deliverer = holding(inbox, presenting)
        try await deliverer.deliver(alert("Slack", at: 1))
        try await deliverer.deliver(alert("Xcode", at: 2))
        #expect(await inbox.delivered.isEmpty)
        #expect(await deliverer.held.count == 2)
        await presenting.set(nil)
        for _ in 0 ..< 100 where await inbox.summaries.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let summaries = await inbox.summaries
        #expect(summaries.count == 1)
        #expect(summaries.first?.title.contains("2") == true)
        #expect(summaries.first?.body == "Xcode\nSlack")
        #expect(await deliverer.held.isEmpty)
    }

    @Test("One held alert comes as itself")
    func single() async throws {
        let inbox = Inbox()
        let presenting = Presenting(.presenting)
        let deliverer = holding(inbox, presenting)
        try await deliverer.deliver(alert("Only"))
        await presenting.set(nil)
        for _ in 0 ..< 100 where await inbox.delivered.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await inbox.delivered.map(\.title) == ["Only"])
        #expect(await inbox.summaries.isEmpty)
    }

    @Test("The summary lists four, then how many more")
    func summaryText() {
        let alerts = (0 ..< 6).map { alert("A\($0)", at: Double($0)) }
        let text = HoldingDeliverer.summaryText(alerts, reason: .presenting)
        #expect(text.body.split(separator: "\n").count == 5)
        #expect(text.body.hasPrefix("A5\nA4"))
    }

    @Test("A new startup item is never held (D-251)")
    func startupItemsComeThrough() async throws {
        let inbox = Inbox()
        let deliverer = holding(inbox, Presenting(.call))
        try await deliverer.deliver(alert("Updater", rule: .newStartupItem))
        #expect(await inbox.delivered.map(\.title) == ["Updater"])
        #expect(await deliverer.held.isEmpty)
    }

    @Test("A call that never ends doesn't hold alerts for good (D-251)")
    func givesUp() async throws {
        let inbox = Inbox()
        let deliverer = holding(inbox, Presenting(.call), longest: .milliseconds(50))
        try await deliverer.deliver(alert("Held"))
        for _ in 0 ..< 200 where await inbox.delivered.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await inbox.delivered.map(\.title) == ["Held"])
        // Still on the call: from now on, straight through.
        try await deliverer.deliver(alert("Next"))
        #expect(await inbox.delivered.map(\.title) == ["Held", "Next"])
    }
}
