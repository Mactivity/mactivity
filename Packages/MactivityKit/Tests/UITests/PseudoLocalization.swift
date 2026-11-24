import Foundation

/// `make test-pseudo` runs the layout suites with every localized string doubled ("Memory" →
/// "Memory Memory"), Apple's `NSDoubleLocalizedStrings`, to catch text a longer language would
/// clip or push out of the window (docs/localization/README.md).
///
/// Foundation reads the setting at the first lookup and keeps it for the process, so it goes in
/// the registration domain (in memory, never saved) before any suite looks anything up, and only
/// in a run filtered to these suites: others compare English text exactly.
enum PseudoLocalization {
    static let isOn: Bool = {
        guard ProcessInfo.processInfo.environment["MACTIVITY_PSEUDO_LOCALIZATION"] == "1" else {
            return false
        }
        UserDefaults.standard.register(defaults: ["NSDoubleLocalizedStrings": true])
        return true
    }()
}
