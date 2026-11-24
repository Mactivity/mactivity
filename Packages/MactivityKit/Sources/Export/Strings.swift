import Core
import Foundation

private final class StringsAnchor {}

extension Bundle {
    /// Export's String Catalog. Every user-facing string in Export is looked up here:
    /// `String(localized: "…", bundle: .strings)`, `Text("…", bundle: .strings)` (docs/localization/README.md).
    static let strings = Bundle.mactivityStrings("Export", anchor: StringsAnchor.self)
}
