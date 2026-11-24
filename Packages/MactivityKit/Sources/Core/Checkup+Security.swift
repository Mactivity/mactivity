import Foundation

extension Checkup {
    /// A protection that's off (D-261): FileVault, System Integrity Protection, Gatekeeper and
    /// automatic security responses are worth turning on soon. The firewall isn't here: it's off
    /// on a new Mac, and the Security page shows it with what it would block.
    static func security(_ inputs: CheckupInputs) -> [CheckupItem] {
        guard let settings = inputs.security else {
            return []
        }
        var items: [CheckupItem] = []
        if settings.fileVault == false {
            items.append(CheckupItem(
                id: "security-filevault", area: .security, severity: .attention,
                title: String(localized: "FileVault is off", bundle: .strings, comment: "Checkup: disk encryption is off"),
                detail: String(
                    localized: """
                    Anyone who gets your Mac can read its disk. FileVault encrypts it; turn it on in System Settings → \
                    Privacy & Security.
                    """,
                    bundle: .strings
                )
            ))
        }
        if settings.systemIntegrity == false {
            items.append(CheckupItem(
                id: "security-sip", area: .security, severity: .attention,
                title: String(localized: "System Integrity Protection is off", bundle: .strings, comment: "Checkup"),
                detail: String(
                    localized: "macOS's own files aren't protected from changes. It's turned back on from Recovery, with csrutil enable.",
                    bundle: .strings
                )
            ))
        }
        if settings.gatekeeper == false {
            items.append(CheckupItem(
                id: "security-gatekeeper", area: .security, severity: .attention,
                title: String(localized: "Gatekeeper is off", bundle: .strings, comment: "Checkup: apps aren't checked before opening"),
                detail: String(
                    localized: "Apps open without macOS checking who made them or whether they're known malware.",
                    bundle: .strings
                )
            ))
        }
        if settings.securityResponses == false {
            items.append(CheckupItem(
                id: "security-responses", area: .security, severity: .attention,
                title: String(localized: "Security fixes don't install by themselves", bundle: .strings, comment: "Checkup"),
                detail: String(
                    localized: "Turn on security updates in System Settings → General → Software Update → Automatic Updates.",
                    bundle: .strings
                )
            ))
        }
        return items
    }
}
