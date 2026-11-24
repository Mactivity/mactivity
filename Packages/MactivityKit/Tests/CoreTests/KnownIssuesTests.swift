@testable import Core
import Foundation
import Testing

/// Known issues in Sparkle and Homebrew (D-257).
struct KnownIssuesTests {
    @Test("Versions compare by number: 2.10 after 2.9, a git suffix ignored")
    func versions() {
        #expect(KnownIssues.isOlder("2.6.1", than: "2.6.4"))
        #expect(!KnownIssues.isOlder("2.10.0", than: "2.9.2"))
        #expect(!KnownIssues.isOlder("2.9.2", than: "2.9.2"))
        #expect(KnownIssues.isOlder("1.27.3", than: "2.6.4"))
        #expect(!KnownIssues.isOlder("7.0.10-37-g1ef73bb", than: "7.0.0"))
        #expect(KnownIssues.isOlder("6.0.11", than: "6.0.12"))
    }

    @Test("Sparkle: each version's known issues, the most severe first; current ones clean")
    func sparkle() {
        #expect(KnownIssues.sparkle(version: "2.6.1").map(\.id) == [
            "CVE-2025-10016", "CVE-2025-0509", "CVE-2025-10015", "CVE-2026-47121", "CVE-2026-47122",
        ])
        #expect(KnownIssues.sparkle(version: "2.8.0").map(\.id) == ["CVE-2026-47121", "CVE-2026-47122"])
        #expect(KnownIssues.sparkle(version: "2.9.2").isEmpty)
        #expect(KnownIssues.sparkle(version: "2.10.0").isEmpty)
        #expect(KnownIssues.sparkle(version: "").isEmpty)
        let app = InstalledSoftware(
            name: "Old App", version: "3.1", origin: .appUpdater, vulnerabilities: KnownIssues.sparkle(version: "2.6.1"),
            component: "Sparkle 2.6.1"
        )
        #expect(SoftwareAssessment.concern(app, now: Date()) == .vulnerable(.high))
    }

    @Test("Homebrew: the sudo advisory before 6.0.12, the sandbox one before 7.0.0")
    func homebrew() {
        #expect(KnownIssues.homebrew(version: "6.0.5").map(\.id) == ["GHSA-rg9r-ppxp-87hm", "GHSA-5263-whxq-77hp"])
        #expect(KnownIssues.homebrew(version: "6.0.14").map(\.id) == ["GHSA-5263-whxq-77hp"])
        #expect(KnownIssues.homebrew(version: "7.0.10-37-g1ef73bb").isEmpty)
    }
}
