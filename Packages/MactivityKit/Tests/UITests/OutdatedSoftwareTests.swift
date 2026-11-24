import Core
import Foundation
import Testing
@testable import UI

/// Outdated Software's model (D-252): the last check's vulnerabilities, and upgrades only after
/// the confirmation.
@MainActor
struct OutdatedSoftwareTests {
    actor Source: InstalledSoftwareSource {
        var upgraded: [[String]] = []
        var checks = 0

        func installed() async -> [InstalledSoftware] {
            [
                InstalledSoftware(name: "c-ares", version: "1.34.6", origin: .homebrew),
                InstalledSoftware(name: "gh", version: "2.1", latest: "2.3", origin: .homebrew),
            ]
        }

        func vulnerabilities() async -> VulnerabilityScan? {
            checks += 1
            return VulnerabilityScan(found: ["c-ares": [Vulnerability(id: "CVE-1", severity: .high, summary: "")]], skipped: ["sqlite"])
        }

        func upgradePlan(_ formulae: [String]) async -> [String] {
            formulae.map { "\($0) 1 → 2" }
        }

        func upgrade(_ confirmation: UpgradeConfirmation) async -> UpgradeResult {
            upgraded.append(confirmation.formulae)
            return UpgradeResult(succeeded: true, output: "")
        }
    }

    func defaults() -> UserDefaults {
        let name = "software-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("With the check off, nothing is checked and only end of life and versions count")
    func checkOff() async {
        let source = Source()
        let model = OutdatedSoftwareModel(source: source, defaults: defaults())
        await model.refresh()
        #expect(await source.checks == 0)
        #expect(model.findings().map(\.concern) == [.outdated])
    }

    @Test("With the check on: once a day, kept across launches, merged by formula")
    func checkOn() async {
        let source = Source()
        let store = defaults()
        store.set(true, forKey: PreferenceKey.checksVulnerabilities)
        let now = Date()
        let model = OutdatedSoftwareModel(source: source, defaults: store)
        await model.refresh(now: now)
        await model.refresh(now: now.addingTimeInterval(3600))
        #expect(await source.checks == 1)
        #expect(model.findings(now: now).first?.concern == .vulnerable(.high))
        #expect(model.findings(now: now).first?.item.name == "c-ares")
        let relaunched = OutdatedSoftwareModel(source: source, defaults: store)
        #expect(relaunched.scan?.skipped == ["sqlite"])
    }

    @Test("Upgrade asks first, with Homebrew's plan; cancelling upgrades nothing")
    func upgrade() async {
        let source = Source()
        let model = OutdatedSoftwareModel(source: source, defaults: defaults())
        await model.askToUpgrade(["gh"])
        #expect(model.confirming == ["gh"])
        #expect(model.plan == ["gh 1 → 2"])
        model.cancelUpgrade()
        await model.confirmUpgrade()
        #expect(await source.upgraded.isEmpty)
        await model.askToUpgrade(["gh"])
        await model.confirmUpgrade()
        #expect(await source.upgraded == [["gh"]])
        #expect(model.outcome?.contains("gh") == true)
    }
}
