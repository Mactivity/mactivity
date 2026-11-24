import Core
import Foundation

private final class StringsAnchor {}

extension Bundle {
    /// UI's String Catalog. Every user-facing string in UI is looked up here:
    /// `String(localized: "…", bundle: .strings)`, `Text("…", bundle: .strings)` (docs/localization/README.md).
    static let strings = Bundle.mactivityStrings("UI", anchor: StringsAnchor.self)
}
