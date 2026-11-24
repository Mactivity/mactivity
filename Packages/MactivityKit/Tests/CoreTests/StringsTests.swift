@testable import Core
import Foundation
import Testing

/// Core's String Catalog is found without `Bundle.module`, which traps in the CLI
/// (docs/localization/README.md).
@Suite("Strings")
struct StringsTests {
    @Test("Core's catalog bundle is the compiled MactivityKit_Core.bundle")
    func findsTheBundle() {
        #expect(Bundle.strings.bundleURL.lastPathComponent == "MactivityKit_Core.bundle")
    }

    @Test("A missing target falls back to the main bundle instead of trapping")
    func fallsBack() {
        #expect(Bundle.mactivityStrings("NoSuchTarget", anchor: Anchor.self) == .main)
    }

    @Test("Lookups return the English source text")
    func english() {
        #expect(Formatters.metric(0, .fanSpeed) == "Off")
    }

    private final class Anchor {}
}
