import Core
import Foundation

/// Software needing security updates (D-252).
extension SystemAlertRules {
    /// One alert per package and version: "openssl@3 has a high-severity vulnerability", "PHP 8.1
    /// no longer gets security fixes". Keyed by version, so an upgrade that's still behind alerts
    /// again, and the same old version doesn't, for a month.
    static func softwareAlerts(_ urgent: [(item: InstalledSoftware, concern: SoftwareConcern)]) -> [Candidate] {
        let see = String(localized: "Checkup shows how to update it.", bundle: .strings)
        return urgent.compactMap { finding -> Candidate? in
            let item = finding.item
            let app = AppIdentity(id: "software:\(item.id)", name: item.title, bundleID: nil, iconKey: "other", kind: .other)
            switch finding.concern {
            case let .vulnerable(severity):
                let count = item.vulnerabilities.count { $0.severity == severity }
                let title = severity == .critical
                    ? String(localized: "\(item.title) has a critical vulnerability", bundle: .strings, comment: "Alert title; a package")
                    : String(
                        localized: "\(item.title) has a high-severity vulnerability",
                        bundle: .strings,
                        comment: "Alert title; a package"
                    )
                let worst = item.vulnerabilities.filter { $0.severity == severity }.map(\.id).prefix(2).joined(separator: ", ")
                let body = String(
                    localized: "Version \(item.version): \(count) known (\(worst)). \(see)",
                    bundle: .strings,
                    comment: "Alert body: the installed version, how many vulnerabilities at that severity, their IDs"
                )
                return Candidate(rule: .vulnerableSoftware, app: app, title: title, body: body)
            case let .unsupported(since):
                let title = String(
                    localized: "\(item.title) no longer gets security fixes",
                    bundle: .strings,
                    comment: "Alert title; a runtime, e.g. PHP 8.1"
                )
                let body = since.map {
                    String(
                        localized: "Its support ended \($0.formatted(date: .abbreviated, time: .omitted)). \(see)",
                        bundle: .strings,
                        comment: "Alert body: the date support ended"
                    )
                } ?? String(localized: "Homebrew no longer supports it. \(see)", bundle: .strings)
                return Candidate(rule: .vulnerableSoftware, app: app, title: title, body: body)
            case .endingSoon, .deprecated, .outdated:
                return nil
            }
        }
    }
}
