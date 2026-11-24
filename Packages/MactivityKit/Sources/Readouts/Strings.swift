import Core
import Foundation

private final class StringsAnchor {}

extension Bundle {
    /// Readouts's String Catalog. Every user-facing string in Readouts is looked up here:
    /// `String(localized: "…", bundle: .strings)`, `Text("…", bundle: .strings)` (docs/localization/README.md).
    static let strings = Bundle.mactivityStrings("Readouts", anchor: StringsAnchor.self)
}
