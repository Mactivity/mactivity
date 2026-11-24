import Foundation

extension Checkup {
    /// Software that needs updating for security (D-252): worth doing soon for a high or
    /// critical vulnerability or a runtime past its end of life; worth knowing for the rest.
    /// Only newer versions, with nothing known against the old one, aren't worth a Checkup line.
    static func software(_ inputs: CheckupInputs) -> [CheckupItem] {
        let urgent = inputs.software.filter(\.concern.isUrgent)
        let later = inputs.software.filter { finding in
            switch finding.concern {
            case .vulnerable, .endingSoon, .deprecated: !finding.concern.isUrgent
            case .unsupported, .outdated: false
            }
        }
        var items: [CheckupItem] = []
        if let first = urgent.first {
            let title = if urgent.count > 1 {
                String(localized: "\(urgent.count) packages need updating for security", bundle: .strings, comment: "Checkup")
            } else {
                switch first.concern {
                case .unsupported:
                    String(
                        localized: "\(first.item.title) no longer gets security fixes",
                        bundle: .strings,
                        comment: "Checkup: a runtime or package past its end of life, e.g. PHP 8.1"
                    )
                default:
                    String(
                        localized: "\(first.item.title) has known vulnerabilities",
                        bundle: .strings,
                        comment: "Checkup: a package with security holes, e.g. openssl@3"
                    )
                }
            }
            items.append(CheckupItem(id: "software", area: .software, severity: .attention, title: title, detail: detail(urgent)))
        }
        if !later.isEmpty {
            items.append(CheckupItem(
                id: "software-later", area: .software, severity: .suggestion,
                title: String(localized: "Worth updating soon: \(later.count)", bundle: .strings, comment: "Checkup: packages"),
                detail: detail(later)
            ))
        }
        return items
    }

    /// "openssl@3, PHP 8.1 and Node.js 20. Outdated Software shows them, with how to update."
    private static func detail(_ findings: [(item: InstalledSoftware, concern: SoftwareConcern)]) -> String {
        let names = findings.prefix(3).map(\.item.title)
        let list = findings.count > 3
            ? String(
                localized: "\(names.joined(separator: ", ")) and \(findings.count - 3) more",
                bundle: .strings,
                comment: "Checkup: three package names, then how many others"
            )
            : names.formatted(.list(type: .and))
        return String(
            localized: "\(list). Outdated Software shows them, with how to update each.",
            bundle: .strings,
            comment: "Checkup: the packages' names"
        )
    }
}
