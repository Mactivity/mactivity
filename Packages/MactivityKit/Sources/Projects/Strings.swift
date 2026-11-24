import Core
import Foundation

private final class StringsAnchor {}

extension Bundle {
    /// Projects's String Catalog. Every user-facing string in Projects is looked up here:
    /// `String(localized: "…", bundle: .strings)`, `Text("…", bundle: .strings)` (docs/localization/README.md).
    static let strings = Bundle.mactivityStrings("Projects", anchor: StringsAnchor.self)
}
