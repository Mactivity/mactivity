import AppKit
import Core
import Foundation
import Testing
@testable import UI

/// The shipped translations, read from each target's compiled `<lang>.lproj` (the same bundles the
/// app looks strings up in), so a broken import or a bad plural fails here rather than on a
/// customer's Mac (docs/localization/README.md).
@Suite("Shipped translations")
struct TranslationTests {
    static let languages = ["de", "fr", "es", "it", "pt-BR", "nl", "ja", "ko", "zh-Hans", "zh-Hant"]

    /// Package targets with a String Catalog.
    private static let targets = ["Alerts", "Audio", "Core", "Export", "Projects", "Readouts", "Startup", "Storage", "UI"]

    /// A key in each of a few catalogs that every language translates to something other than
    /// the English.
    private static let translatedKeys: [(target: String, key: String)] = [
        ("UI", "Memory"), ("UI", "Network"), ("UI", "Overview"), ("UI", "Force Quit"),
        ("Core", "Charging"), ("Startup", "At login"),
    ]

    /// The menu bar's stacked-mode labels, by the metric they name.
    private static let menuBarLabels: [(key: String, metric: MenuBarMetric)] = [
        ("menubar.cpu", .cpu), ("MEM", .memory), ("menubar.gpu", .gpu),
        ("NET", .network), ("TMP", .temperature), ("BAT", .battery),
    ]

    private final class Anchor {}

    private static func catalog(_ target: String) -> Bundle {
        target == "UI" ? .strings : Bundle.mactivityStrings(target, anchor: Anchor.self)
    }

    private static func lproj(_ target: String, _ language: String) -> Bundle? {
        catalog(target).path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
    }

    private static func lookUp(_ key: String, target: String, language: String) -> String? {
        guard let bundle = lproj(target, language) else {
            return nil
        }
        let missing = "\u{1}missing"
        let text = bundle.localizedString(forKey: key, value: missing, table: nil)
        return text == missing ? nil : text
    }

    @Test("Each language's strings are in every catalog's bundle", arguments: languages)
    func bundlesExist(language: String) {
        for target in Self.targets {
            #expect(Self.lproj(target, language) != nil, "\(target) has no \(language).lproj")
        }
    }

    @Test("Key strings are translated, not left in English", arguments: languages)
    func translated(language: String) throws {
        for (target, key) in Self.translatedKeys {
            let text = try #require(Self.lookUp(key, target: target, language: language), "\(target) \(key) in \(language)")
            let english = Self.lookUp(key, target: target, language: "en") ?? key
            #expect(!text.isEmpty)
            #expect(text != english, "\(target) \(key) is still English in \(language)")
        }
    }

    /// A translated label may be longer than the English, but not so long that it, rather than
    /// the widest value, sets the column's width.
    @Test("Menu bar labels fit their stacked column", arguments: languages)
    func menuBarLabelsFit(language: String) throws {
        let locale = Locale(identifier: language)
        for (key, metric) in Self.menuBarLabels {
            let label = try #require(Self.lookUp(key, target: "UI", language: language), "\(key) in \(language)")
            #expect(!label.isEmpty)
            let labelWidth = MenuBarLayout.width(of: label, .label)
            let values = MenuBarLayout.valueWidth(metric, .value, locale: locale)
            #expect(labelWidth <= values, "\(language) \(key) “\(label)” is \(labelWidth) pt, values \(values) pt")
            #expect(labelWidth <= MenuBarLayout.columnWidth(metric, locale: locale))
        }
    }

    @Test("Every plural resolves for 1 and 5", arguments: languages)
    func plurals(language: String) {
        let locale = Locale(identifier: language)
        var checked = 0
        for target in Self.targets {
            guard let bundle = Self.lproj(target, language),
                  let path = bundle.path(forResource: "Localizable", ofType: "stringsdict"),
                  let plurals = NSDictionary(contentsOfFile: path) as? [String: Any]
            else {
                continue
            }
            for key in plurals.keys {
                let format = bundle.localizedString(forKey: key, value: nil, table: nil)
                for count in [1, 5] {
                    let text = String(format: format, locale: locale, arguments: Self.arguments(for: key, count: count))
                    #expect(!text.isEmpty, "\(target) \(key) for \(count) in \(language)")
                    #expect(!text.contains("%#@") && !text.contains("%lld"), "\(target) \(key) for \(count) in \(language): \(text)")
                }
                checked += 1
            }
        }
        #expect(checked > 20, "only \(checked) plural keys in \(language)")
    }

    /// The key's placeholders in argument order: counts get `count`, objects a word.
    private static func arguments(for key: String, count: Int) -> [CVarArg] {
        let pattern = /%(?:(\d+)\$)?(lld|llu|ld|lu|d|u|@)/
        var slots: [Int: CVarArg] = [:]
        var next = 1
        for match in key.matches(of: pattern) {
            let position = match.output.1.flatMap { Int($0) } ?? next
            next = position + 1
            slots[position] = match.output.2 == "@" ? "x" as NSString : count
        }
        return slots.keys.sorted().compactMap { slots[$0] }
    }
}
