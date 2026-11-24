import Core
import Foundation
import FoundationModels
import Testing
@testable import UI

@MainActor
@Suite("Ask Mactivity (D-153)")
struct AskMactivityTests {
    @Test("History periods: today from midnight, yesterday the whole day before")
    func periods() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = Date(timeIntervalSince1970: 1_800_000_000 + 15 * 3600)
        let midnight = calendar.startOfDay(for: now)
        #expect(AppHistoryTool.range("today", now: now, calendar: calendar) == (midnight, now))
        #expect(AppHistoryTool.range("yesterday", now: now, calendar: calendar) == (midnight - 86400, midnight))
        #expect(AppHistoryTool.range("last hour", now: now, calendar: calendar) == (now - 3600, now))
    }

    @Test("The tool's answer names the apps, or says there's no history")
    func describe() {
        let app = AppIdentity(id: "x", name: "Xcode", bundleID: nil, iconKey: "x", kind: .app)
        let text = AppHistoryTool.describe([AppTotal(app: app, value: 12.5)], period: "today", figure: "cpu") { "\($0)%" }
        #expect(text == "Top apps by cpu, today: Xcode 12.5%.")
        #expect(AppHistoryTool.describe([], period: "yesterday", figure: "disk") { "\($0)" }.contains("no disk history"))
    }

    @Test("Off until turned on in Settings (D-161)")
    func optIn() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: PreferenceKey.askMactivity)
        defer { defaults.set(saved, forKey: PreferenceKey.askMactivity) }
        defaults.removeObject(forKey: PreferenceKey.askMactivity)
        let model = AskModel()
        #expect(!model.isOffered)
        defaults.set(true, forKey: PreferenceKey.askMactivity)
        #expect(model.isOffered == model.isAvailable)
    }

    /// The real on-device model answers, where Apple Intelligence is on. Slow and not the same
    /// answer twice, so it runs only with `make test-live`.
    @Test(
        "The on-device model answers a question about the simulated Mac",
        .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_LIVE_TESTS"] != nil, "runs the on-device model: make test-live"),
        .enabled(if: SystemLanguageModel.default.isAvailable)
    )
    func answers() async throws {
        let services = AppServices.preview()
        let model = services.ask
        model.ask("Which app is using the most CPU?", services: services)
        for _ in 0 ..< 600 where model.state == .answering {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(model.state == .answered)
        #expect(!model.answer.isEmpty)
    }

    /// The day and agent tools (D-199): a question about yesterday and about agents gets an answer
    /// that uses them. Live only, as above.
    @Test(
        "The on-device model answers about a day and about agents",
        .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_LIVE_TESTS"] != nil, "runs the on-device model: make test-live"),
        .enabled(if: SystemLanguageModel.default.isAvailable)
    )
    func history() async throws {
        let services = AppServices.preview()
        let model = services.ask
        for question in ["What did my coding agents work on this week?", "What happened on my Mac yesterday?"] {
            model.ask(question, services: services)
            for _ in 0 ..< 900 where model.state == .answering {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(model.state == .answered)
            #expect(!model.answer.isEmpty)
        }
    }
}
