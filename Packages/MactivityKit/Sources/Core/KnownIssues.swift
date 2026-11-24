import Foundation

/// Vulnerabilities in things apps and tools carry, known without asking anyone (1.7.1, D-257):
/// a table that ships with Mactivity and is updated with each release, from each project's own
/// advisories. Nothing is looked up online.
public enum KnownIssues {
    struct Issue {
        /// Versions before this one have it.
        let fixedIn: String
        let vulnerability: Vulnerability
    }

    /// Sparkle, the updater many Mac apps carry (OSV / GitHub advisories).
    static let sparkle: [Issue] = [
        Issue(fixedIn: "2.6.4", vulnerability: Vulnerability(
            id: "CVE-2025-0509", severity: .medium, summary: "Its signature checks can be bypassed"
        )),
        Issue(fixedIn: "2.7.2", vulnerability: Vulnerability(
            id: "CVE-2025-10016", severity: .high, summary: "Local privilege escalation through its update daemon"
        )),
        Issue(fixedIn: "2.7.2", vulnerability: Vulnerability(
            id: "CVE-2025-10015", severity: .medium, summary: "A privacy-permission bypass through its downloader"
        )),
        Issue(fixedIn: "2.9.2", vulnerability: Vulnerability(
            id: "CVE-2026-47121", severity: .medium, summary: "A crafted delta update can write outside the app"
        )),
        Issue(fixedIn: "2.9.2", vulnerability: Vulnerability(
            id: "CVE-2026-47122", severity: .medium, summary: "Its installer accepts connections it doesn't check"
        )),
    ]

    /// Homebrew itself (its 2026 advisories): seven fixed in 6.0.x, one in 7.0.0.
    static let homebrew: [Issue] = [
        Issue(fixedIn: "6.0.12", vulnerability: Vulnerability(
            id: "GHSA-rg9r-ppxp-87hm", severity: .high, summary: "A cask's removal steps could run commands with sudo"
        )),
        Issue(fixedIn: "7.0.0", vulnerability: Vulnerability(
            id: "GHSA-5263-whxq-77hp", severity: .medium, summary: "A cask could run code outside Homebrew's sandbox"
        )),
    ]

    /// Pure: the known vulnerabilities of this Sparkle version, most severe first.
    public static func sparkle(version: String) -> [Vulnerability] {
        affecting(version, sparkle)
    }

    /// Pure: the known vulnerabilities of this Homebrew version ("7.0.10-37-g1ef73bb").
    public static func homebrew(version: String) -> [Vulnerability] {
        affecting(version, homebrew)
    }

    static func affecting(_ version: String, _ issues: [Issue]) -> [Vulnerability] {
        guard !numbers(version).isEmpty else {
            return []
        }
        return issues.filter { isOlder(version, than: $0.fixedIn) }.map(\.vulnerability).sorted { $0.severity > $1.severity }
    }

    /// Pure: "2.6.1" before "2.6.4"; "2.10.0" after "2.9.2"; "7.0.10-37-g1ef73bb" reads as 7.0.10.
    public static func isOlder(_ version: String, than other: String) -> Bool {
        let lhs = numbers(version)
        let rhs = numbers(other)
        for index in 0 ..< max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }

    /// The leading dotted numbers: "2.6.1 Beta 2" is [2, 6, 1].
    static func numbers(_ version: String) -> [Int] {
        let head = version.prefix { $0.isNumber || $0 == "." }
        return head.split(separator: ".").compactMap { Int($0) }
    }
}
