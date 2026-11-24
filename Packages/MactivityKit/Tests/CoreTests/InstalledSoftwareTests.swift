@testable import Core
import Foundation
import Testing

/// Outdated Software (D-252): release lines, end of life, and what each package needs.
struct InstalledSoftwareTests {
    let now = Date(timeIntervalSince1970: 1_792_627_200) // 2026-10-22

    @Test("Release lines: Node.js and PostgreSQL by major, the rest by major.minor")
    func cycles() {
        #expect(Runtime.cycle(of: "20.11.1", kind: .node) == "20")
        #expect(Runtime.cycle(of: "16.4", kind: .postgresql) == "16")
        #expect(Runtime.cycle(of: "3.9.6", kind: .python) == "3.9")
        #expect(Runtime.cycle(of: "8.1.34", kind: .php) == "8.1")
        #expect(Runtime.cycle(of: "3", kind: .python) == nil)
        #expect(Runtime.homebrew(formula: "python@3.11", version: "3.11.9") == Runtime(kind: .python, cycle: "3.11"))
        #expect(Runtime.homebrew(formula: "php", version: "8.5.1") == Runtime(kind: .php, cycle: "8.5"))
        #expect(Runtime.homebrew(formula: "postgresql@16", version: "16.4") == Runtime(kind: .postgresql, cycle: "16"))
        #expect(Runtime.homebrew(formula: "openssl@3", version: "3.5.9") == nil)
    }

    @Test("End of life from the table; an unknown line isn't judged")
    func endOfLife() throws {
        let php81 = try #require(RuntimeSupport.endOfLife(Runtime(kind: .php, cycle: "8.1")))
        #expect(php81 < now)
        let node26 = try #require(RuntimeSupport.endOfLife(Runtime(kind: .node, cycle: "26")))
        #expect(node26 > now)
        #expect(RuntimeSupport.endOfLife(Runtime(kind: .python, cycle: "4.0")) == nil)
    }

    func item(
        _ name: String, _ version: String, origin: InstalledSoftware.Origin = .homebrew, latest: String? = nil,
        runtime: Runtime? = nil, deprecation: InstalledSoftware.Deprecation? = nil, vulnerabilities: [Vulnerability.Severity] = []
    ) -> InstalledSoftware {
        InstalledSoftware(
            name: name, version: version, latest: latest, origin: origin, deprecation: deprecation, runtime: runtime,
            vulnerabilities: vulnerabilities.enumerated().map { Vulnerability(id: "CVE-\($0.offset)", severity: $0.element, summary: "") }
        )
    }

    @Test("What each needs: vulnerabilities first, then end of life, Homebrew's flags, newer versions")
    func concerns() throws {
        #expect(SoftwareAssessment.concern(item("openssl@3", "3.5.1", vulnerabilities: [.medium, .high]), now: now) == .vulnerable(.high))
        let php = item("php@8.1", "8.1.34", runtime: Runtime(kind: .php, cycle: "8.1"))
        #expect(SoftwareAssessment.concern(php, now: now) == .unsupported(since: RuntimeSupport.endOfLife(Runtime(
            kind: .php,
            cycle: "8.1"
        ))))
        // Python 3.10's support ends 2026-10-31: within 90 days.
        let python = item("python", "3.10.14", origin: .pyenv, runtime: Runtime(kind: .python, cycle: "3.10"))
        #expect(try SoftwareAssessment.concern(python, now: now) == .endingSoon(#require(RuntimeSupport.endOfLife(Runtime(
            kind: .python,
            cycle: "3.10"
        )))))
        #expect(SoftwareAssessment.concern(
            item("x", "1", deprecation: .init(disabled: true, reason: nil)), now: now
        ) == .unsupported(since: nil))
        #expect(SoftwareAssessment.concern(item("x", "1", deprecation: .init(disabled: false, reason: "unsupported")), now: now)
            == .unsupported(since: nil))
        #expect(SoftwareAssessment.concern(item("x", "1", deprecation: .init(disabled: false, reason: "discontinued")), now: now)
            == .deprecated)
        #expect(SoftwareAssessment.concern(item("gh", "2.1", latest: "2.3"), now: now) == .outdated)
        #expect(SoftwareAssessment.concern(item("gh", "2.3"), now: now) == nil)
    }

    @Test("Apple's Python and Ruby are only ever outdated, never urgent")
    func apple() {
        let python = item("python3", "3.9.6", origin: .apple, runtime: Runtime(kind: .python, cycle: "3.9"))
        #expect(SoftwareAssessment.concern(python, now: now) == .outdated)
        let current = item("python3", "3.13.1", origin: .apple, runtime: Runtime(kind: .python, cycle: "3.13"))
        #expect(SoftwareAssessment.concern(current, now: now) == nil)
    }

    @Test("Checkup: one item worth doing soon for the urgent ones, one worth knowing for the rest")
    func checkup() {
        var inputs = CheckupInputs()
        let urgent = item("openssl@3", "3.5.1", vulnerabilities: [.high])
        let later = item("llama.cpp", "0.4.1", vulnerabilities: [.unknown])
        let old = item("gh", "2.1", latest: "2.3")
        inputs.software = SoftwareAssessment.needingAttention([old, later, urgent], now: now).map { (item: $0.0, concern: $0.1) }
        let items = Checkup.software(inputs)
        #expect(items.map(\.severity) == [.attention, .suggestion])
        #expect(items.first?.title.contains("openssl@3") == true)
        #expect(items.last?.detail.contains("llama.cpp") == true)
        // Only newer versions: nothing to say.
        inputs.software = SoftwareAssessment.needingAttention([old], now: now).map { (item: $0.0, concern: $0.1) }
        #expect(Checkup.software(inputs).isEmpty)
    }

    @Test("A report of severities from OSV's words")
    func severities() {
        #expect(Vulnerability.Severity(osv: "CRITICAL") == .critical)
        #expect(Vulnerability.Severity(osv: "MODERATE") == .medium)
        #expect(Vulnerability.Severity(osv: "") == .unknown)
    }
}
