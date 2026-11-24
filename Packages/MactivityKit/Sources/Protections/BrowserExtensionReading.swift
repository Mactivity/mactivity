import Core
import Foundation

/// Browser extensions from each browser's own files (1.9, D-261): Safari's through `pluginkit`,
/// Chrome's, Edge's, Brave's and Arc's from their profiles' `Extensions` folders, Firefox's from
/// each profile's `extensions.json`. Reading other apps' folders needs Full Disk Access on
/// macOS 26; a browser whose folder can't be read is reported as blocked.
public enum BrowserExtensionReading {

    // MARK: Chrome and the browsers built on it

    /// Where each Chromium browser keeps its profiles, under the home folder.
    public static let chromiumRoots: [(Browser, String)] = [
        (.chrome, "Library/Application Support/Google/Chrome"),
        (.edge, "Library/Application Support/Microsoft Edge"),
        (.brave, "Library/Application Support/BraveSoftware/Brave-Browser"),
        (.arc, "Library/Application Support/Arc/User Data"),
    ]

    /// Pure: one extension from its `manifest.json`, its default language's `messages.json`
    /// (for names like "__MSG_appName__") and its entry in the profile's preferences.
    public static func chromium(
        browser: Browser, identifier: String, manifest: [String: Any], messages: [String: Any]?, settings: [String: Any]?
    ) -> BrowserExtension? {
        guard let rawName = manifest["name"] as? String else {
            return nil
        }
        // Built into the browser (location 5, "component"): part of it, not something installed.
        if settings?["location"] as? Int == 5 {
            return nil
        }
        return BrowserExtension(
            browser: browser, identifier: identifier, name: localized(rawName, messages: messages),
            version: manifest["version"] as? String ?? "", isOn: settings.flatMap(isOn), permissions: permissions(manifest)
        )
    }

    /// Pure: what a manifest asks for: its permissions, its host permissions, and the sites its
    /// content scripts run on.
    public static func permissions(_ manifest: [String: Any]) -> [String] {
        var all = (manifest["permissions"] as? [Any] ?? []).compactMap { $0 as? String }
        all += (manifest["host_permissions"] as? [String] ?? [])
        for script in manifest["content_scripts"] as? [[String: Any]] ?? [] {
            all += script["matches"] as? [String] ?? []
        }
        var seen: Set<String> = []
        return all.filter { seen.insert($0).inserted }
    }

    /// Pure: "__MSG_appName__" from `messages.json`, whose keys are matched without case.
    public static func localized(_ name: String, messages: [String: Any]?) -> String {
        guard name.hasPrefix("__MSG_"), name.hasSuffix("__"), let messages else {
            return name
        }
        let key = String(name.dropFirst(6).dropLast(2)).lowercased()
        let entry = messages.first { $0.key.lowercased() == key }?.value as? [String: Any]
        return entry?["message"] as? String ?? name
    }

    /// Pure: whether a profile's settings for an extension say it's on. Turned off is a non-empty
    /// `disable_reasons`, or an older `state` of 0.
    static func isOn(_ settings: [String: Any]) -> Bool? {
        if let reasons = settings["disable_reasons"] as? [Any] {
            return reasons.isEmpty
        }
        if let reasons = settings["disable_reasons"] as? Int {
            return reasons == 0
        }
        if let state = settings["state"] as? Int {
            return state != 0
        }
        return nil
    }

    // MARK: Firefox

    /// Pure: a profile's `extensions.json`: the extensions the person installed (not Firefox's
    /// own built-ins, themes or language packs).
    public static func firefox(_ data: Data) -> [BrowserExtension] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let addons = root["addons"] as? [[String: Any]]
        else {
            return []
        }
        return addons.compactMap { addon in
            guard addon["type"] as? String == "extension", addon["location"] as? String == "app-profile",
                  let identifier = addon["id"] as? String
            else {
                return nil
            }
            let locale = addon["defaultLocale"] as? [String: Any]
            let granted = addon["userPermissions"] as? [String: Any]
            return BrowserExtension(
                browser: .firefox, identifier: identifier, name: locale?["name"] as? String ?? identifier,
                version: addon["version"] as? String ?? "", isOn: addon["active"] as? Bool,
                permissions: (granted?["permissions"] as? [String] ?? []) + (granted?["origins"] as? [String] ?? [])
            )
        }
    }

    // MARK: Safari

    /// One Safari web extension as `pluginkit -mAvvv -p com.apple.Safari.web-extension` lists it.
    public struct SafariListing: Equatable, Sendable {
        public let identifier: String
        public let version: String
        public let name: String
        public let path: String
    }

    /// Pure: `pluginkit`'s verbose listing: an identifier line, `com.1password.safari.extension(8.12.42)`,
    /// then indented `Path = …` and `Display Name = …` lines.
    public static func safari(_ output: String) -> [SafariListing] {
        var found: [SafariListing] = []
        var current: (identifier: String, version: String)?
        var path: String?
        var name: String?
        func finish() {
            if let current, let path {
                found.append(SafariListing(
                    identifier: current.identifier,
                    version: current.version,
                    name: name ?? current.identifier,
                    path: path
                ))
            }
        }
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let open = line.lastIndex(of: "("), line.hasSuffix(")"), !line.contains(" = "), !line.contains(" ") {
                finish()
                current = (String(line[..<open]), String(line[line.index(after: open)...].dropLast()))
                path = nil
                name = nil
            } else if line.hasPrefix("Path = ") {
                path = String(line.dropFirst("Path = ".count))
            } else if line.hasPrefix("Display Name = ") {
                name = String(line.dropFirst("Display Name = ".count))
            }
        }
        finish()
        var seen: Set<String> = []
        return found.filter { seen.insert($0.identifier).inserted }
    }
}
