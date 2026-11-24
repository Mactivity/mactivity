import Core
import Foundation

private final class StringsAnchor {}

extension Bundle {
    /// Startup's String Catalog. Every user-facing string in Startup is looked up here:
    /// `String(localized: "…", bundle: .strings)`, `Text("…", bundle: .strings)` (docs/localization/README.md).
    static let strings = Bundle.mactivityStrings("Startup", anchor: StringsAnchor.self)
}
