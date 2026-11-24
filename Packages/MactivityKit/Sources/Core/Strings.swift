import Foundation

extension Bundle {
    /// The compiled String Catalog of the MactivityKit target `target`, `MactivityKit_<target>.bundle`
    /// (docs/localization/README.md). Each target wraps this as its own internal `Bundle.strings`.
    ///
    /// Unlike SwiftPM's generated `Bundle.module`, it never traps. The `mactivity` CLI runs from
    /// `Contents/Helpers`, where `Bundle.module` finds no resource bundles and would crash; there it
    /// uses the app's `Contents/Resources`. With no bundle anywhere, it falls back to the main
    /// bundle, whose lookups return the English source text.
    public static func mactivityStrings(_ target: String, anchor: AnyClass) -> Bundle {
        let name = "MactivityKit_\(target).bundle"
        let owner = Bundle(for: anchor)
        let helpers = Bundle.main.executableURL?.deletingLastPathComponent()
        let candidates: [URL?] = [
            // The app, the widget extension, and the helper in Contents/MacOS.
            Bundle.main.resourceURL,
            // A framework.
            owner.resourceURL,
            // The CLI in Contents/Helpers: the app's Contents/Resources.
            helpers?.deletingLastPathComponent().appendingPathComponent("Resources", isDirectory: true),
            // `swift test`: beside the .xctest bundle.
            owner.bundleURL.deletingLastPathComponent(),
            // `swift run`: beside the executable.
            Bundle.main.bundleURL,
        ]
        for case let directory? in candidates {
            if let bundle = Bundle(url: directory.appendingPathComponent(name, isDirectory: true)) {
                return bundle
            }
        }
        return .main
    }
}

private final class StringsAnchor {}

extension Bundle {
    /// Core's String Catalog. Every user-facing string in Core is looked up here:
    /// `String(localized: "…", bundle: .strings)`.
    static let strings = Bundle.mactivityStrings("Core", anchor: StringsAnchor.self)
}
