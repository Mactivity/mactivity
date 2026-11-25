import Core
import Testing

/// Who made what's running (D-232), from what the signatures on this Mac read.
struct SignerTests {
    @Test("Signers as this Mac's apps read")
    func signers() {
        #expect(Signer.from(platform: 26, adHoc: false, leaf: "macOS Software Signing", team: nil) == .apple)
        #expect(Signer.from(platform: nil, adHoc: false, leaf: "Apple Mac OS Application Signing", team: "59GAB85EFG") == .appStore)
        #expect(Signer.from(platform: nil, adHoc: false, leaf: "Developer ID Application: Google LLC (EQHXZ8M8AV)", team: "EQHXZ8M8AV")
            == .developer(name: "Google LLC", team: "EQHXZ8M8AV"))
        #expect(Signer.from(platform: nil, adHoc: false, leaf: "Apple Development: Robin Example (ABC123)", team: "XYZ")
            == .development(name: "Robin Example"))
        // Homebrew's node and Mactivity's own debug build.
        #expect(Signer.from(platform: nil, adHoc: true, leaf: nil, team: nil) == .adHoc)
        #expect(Signer.from(platform: nil, adHoc: false, leaf: nil, team: nil) == .unsigned)
        #expect(Signer.adHoc.isAnonymous && Signer.unsigned.isAnonymous && !Signer.apple.isAnonymous)
    }
}
