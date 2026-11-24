import Core
import Foundation

/// A fixed set for previews, tests and Simulated data: an old Python, an unsupported Node.js, an
/// OpenSSL with known vulnerabilities.
public struct SimulatedInstalledSoftware: InstalledSoftwareSource {
    public init() {}

    public func installed() async -> [InstalledSoftware] {
        [
            InstalledSoftware(
                name: "openssl@3", version: "3.5.1", latest: "3.5.9", origin: .homebrew, onRequest: false
            ),
            InstalledSoftware(
                name: "php@8.1", version: "8.1.34", origin: .homebrew,
                deprecation: InstalledSoftware.Deprecation(disabled: false, reason: "unsupported"),
                runtime: Runtime(kind: .php, cycle: "8.1")
            ),
            InstalledSoftware(name: "node", version: "20.11.1", origin: .nvm, runtime: Runtime(kind: .node, cycle: "20")),
            InstalledSoftware(name: "python", version: "3.10.14", origin: .pyenv, runtime: Runtime(kind: .python, cycle: "3.10")),
            InstalledSoftware(name: "gh", version: "2.101.0", latest: "2.103.0", origin: .homebrew),
            InstalledSoftware(name: "python3", version: "3.9.6", origin: .apple, runtime: Runtime(kind: .python, cycle: "3.9")),
        ]
    }

    public func vulnerabilities() async -> VulnerabilityScan? {
        VulnerabilityScan(found: ["openssl@3": [
            Vulnerability(id: "CVE-2026-54873", severity: .high, summary: "Out-of-bounds read in the TLS 1.3 key share"),
            Vulnerability(id: "CVE-2026-35189", severity: .medium, summary: "Timing side channel in RSA decryption"),
        ]], skipped: ["sqlite"])
    }

    public func upgradePlan(_ formulae: [String]) async -> [String] {
        formulae.map { "\($0) → newest" }
    }

    public func upgrade(_: UpgradeConfirmation) async -> UpgradeResult {
        UpgradeResult(succeeded: true, output: "")
    }
}
