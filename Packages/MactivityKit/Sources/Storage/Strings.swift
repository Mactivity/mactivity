import Core
import Foundation

private final class StringsAnchor {}

extension Bundle {
    /// Storage's String Catalog. Every user-facing string in Storage is looked up here:
    /// `String(localized: "…", bundle: .strings)`, `Text("…", bundle: .strings)` (docs/localization/README.md).
    static let strings = Bundle.mactivityStrings("Storage", anchor: StringsAnchor.self)
}
