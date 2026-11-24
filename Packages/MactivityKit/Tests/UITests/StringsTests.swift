import Foundation
import Testing
@testable import UI

/// English plural variations in UI's String Catalog apply (docs/localization/README.md).
@Suite("UI strings")
struct UIStringsTests {
    @Test("The catalog's English plurals give the singular for one")
    func plurals() {
        #expect(String(localized: "\(1) processes", bundle: .strings) == "1 process")
        #expect(String(localized: "\(3) processes", bundle: .strings) == "3 processes")
        #expect(String(localized: "\(1) dev servers", bundle: .strings) == "1 dev server")
    }
}
