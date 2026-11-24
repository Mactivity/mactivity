import Core
import Testing

@Suite("Checkup: protections that are off (D-261)")
struct CheckupSecurityTests {
    @Test("FileVault, SIP, Gatekeeper and security fixes off are worth doing soon; the firewall and unknowns aren't named")
    func items() {
        var inputs = CheckupInputs()
        inputs.security = SecuritySettings(
            fileVault: false,
            firewall: false,
            gatekeeper: true,
            systemIntegrity: nil,
            securityResponses: false
        )
        let items = Checkup.items(inputs).filter { $0.area == .security }
        #expect(items.map(\.id) == ["security-filevault", "security-responses"])
        #expect(items.allSatisfy { $0.severity == .attention })
        inputs.security = SecuritySettings(
            fileVault: true,
            firewall: false,
            gatekeeper: true,
            systemIntegrity: true,
            securityResponses: true
        )
        #expect(Checkup.items(inputs).filter { $0.area == .security }.isEmpty)
    }
}
