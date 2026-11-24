import Foundation
import Testing
@testable import UI

struct BuildInfoTests {
    @Test("Shown version: no build number, the channel for betas only; support version adds the build")
    func displayVersion() {
        #expect(BuildInfo(version: "0.9.0", build: "1", channel: "beta", feedbackEmail: nil).displayVersion == "0.9.0 beta")
        #expect(BuildInfo(version: "1.0.1", build: "11", channel: "", feedbackEmail: nil).displayVersion == "1.0.1")
        #expect(BuildInfo(version: "1.0.1", build: "11", channel: "", feedbackEmail: nil).supportVersion == "1.0.1 (11)")
    }

    @Test("Feedback is a mailto draft with the version and this Mac's details; none without an address")
    func feedbackDraft() throws {
        let info = BuildInfo(version: "0.9.0", build: "1", channel: "beta", feedbackEmail: "feedback@example.com")
        let url = try #require(info.feedbackURL(details: ["macOS 27.0.0", "MacBook Pro (Mac16,7) · Apple M5 Pro · 48 GB"]))
        #expect(url.scheme == "mailto")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "feedback@example.com")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["subject"] == "Mactivity 0.9.0 beta feedback")
        #expect(query["body"]?.contains("Mactivity 0.9.0 beta (1)") == true)
        #expect(query["body"]?.contains("macOS 27.0.0") == true)
        #expect(query["body"]?.contains("Apple M5 Pro · 48 GB") == true)
        #expect(BuildInfo(version: "1", build: "1", channel: "", feedbackEmail: nil).feedbackURL(details: []) == nil)
    }

    @Test("This Mac's details: macOS, the model and chip with memory, the language")
    func details() {
        let lines = FeedbackDraft.details(simulated: true)
        #expect(lines.first?.hasPrefix("macOS ") == true)
        #expect(lines.contains { $0.contains(" GB") && $0.contains("(") })
        #expect(lines.contains { $0.hasPrefix("Language: ") })
        #expect(lines.last == "Simulated data is on")
        #expect(!FeedbackDraft.details(simulated: false).contains("Simulated data is on"))
    }
}
