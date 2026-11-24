import Core
import Foundation

private final class StringsAnchor {}

extension Bundle {
    /// Alerts's String Catalog. Every user-facing string in Alerts is looked up here:
    /// `String(localized: "…", bundle: .strings)`, `Text("…", bundle: .strings)` (docs/localization/README.md).
    static let strings = Bundle.mactivityStrings("Alerts", anchor: StringsAnchor.self)
}
