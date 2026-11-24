import Core
import Foundation

private final class StringsAnchor {}

extension Bundle {
    /// Audio's String Catalog. Every user-facing string in Audio is looked up here:
    /// `String(localized: "…", bundle: .strings)`, `Text("…", bundle: .strings)` (docs/localization/README.md).
    static let strings = Bundle.mactivityStrings("Audio", anchor: StringsAnchor.self)
}
