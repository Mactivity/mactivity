import Core
import Foundation

/// Reading Homebrew's JSON and the version managers' folders into `InstalledSoftware` (D-252).
/// Pure, so each is tested with fixtures.
public enum InstalledSoftwareParsing {
    /// `brew info --json=v2 --installed`: formulae and casks.
    public static func homebrew(_ data: Data) -> [InstalledSoftware] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let formulae = (root["formulae"] as? [[String: Any]] ?? []).compactMap(formula)
        let casks = (root["casks"] as? [[String: Any]] ?? []).compactMap(cask)
        return formulae + casks
    }

    static func formula(_ entry: [String: Any]) -> InstalledSoftware? {
        guard let name = entry["name"] as? String,
              let installed = entry["installed"] as? [[String: Any]], !installed.isEmpty
        else {
            return nil
        }
        // The linked version when there's one; otherwise the last installed.
        let linked = entry["linked_keg"] as? String
        let versions = installed.compactMap { $0["version"] as? String }
        guard let version = linked.flatMap({ versions.contains($0) ? $0 : nil }) ?? versions.last else {
            return nil
        }
        let stable = (entry["versions"] as? [String: Any])?["stable"] as? String
        let outdated = entry["outdated"] as? Bool ?? false
        return InstalledSoftware(
            name: name, version: version, latest: outdated ? stable : nil, origin: .homebrew,
            onRequest: installed.contains { $0["installed_on_request"] as? Bool ?? false },
            deprecation: deprecation(entry),
            runtime: Runtime.homebrew(formula: name, version: version)
        )
    }

    static func cask(_ entry: [String: Any]) -> InstalledSoftware? {
        guard let token = entry["token"] as? String, let version = entry["installed"] as? String else {
            return nil
        }
        // An app that updates itself is up to the app, as `brew outdated` treats it.
        let updatesItself = entry["auto_updates"] as? Bool ?? false
        let outdated = (entry["outdated"] as? Bool ?? false) && !updatesItself
        return InstalledSoftware(
            name: token, version: version, latest: outdated ? entry["version"] as? String : nil,
            origin: .homebrewCask, deprecation: deprecation(entry)
        )
    }

    static func deprecation(_ entry: [String: Any]) -> InstalledSoftware.Deprecation? {
        if entry["disabled"] as? Bool == true {
            return InstalledSoftware.Deprecation(disabled: true, reason: entry["disable_reason"] as? String)
        }
        if entry["deprecated"] as? Bool == true {
            return InstalledSoftware.Deprecation(disabled: false, reason: entry["deprecation_reason"] as? String)
        }
        return nil
    }

    /// `brew vulns --json`: each formula's vulnerabilities, and the ones it skipped.
    public static func vulnerabilities(_ data: Data) -> VulnerabilityScan? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let findings = root["findings"] as? [[String: Any]]
        else {
            return nil
        }
        var found: [String: [Vulnerability]] = [:]
        for finding in findings {
            guard let formula = finding["formula"] as? String else {
                continue
            }
            let list = (finding["vulnerabilities"] as? [[String: Any]] ?? []).compactMap { vulnerability -> Vulnerability? in
                guard let id = vulnerability["id"] as? String else {
                    return nil
                }
                return Vulnerability(
                    id: id, severity: Vulnerability.Severity(osv: vulnerability["severity"] as? String ?? ""),
                    summary: vulnerability["summary"] as? String ?? ""
                )
            }
            if !list.isEmpty {
                found[formula, default: []] += list
            }
        }
        return VulnerabilityScan(found: found, skipped: root["skipped_formulae"] as? [String] ?? [])
    }

    /// `brew upgrade --dry-run`: the "name old -> new" lines.
    public static func upgradePlan(_ text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ")
            guard parts.count >= 4, parts[parts.count - 2] == "->", !line.hasPrefix("==>"), !line.hasPrefix("Warning") else {
                return nil
            }
            return "\(parts[0]) \(parts[parts.count - 3]) → \(parts[parts.count - 1])"
        }
    }

    // MARK: Version managers

    /// Where each version manager keeps its runtimes, under the home folder, and how its folder
    /// names read: a runtime per folder ("3.11.9", "v20.11.1") or a tool per folder, each with
    /// its versions inside (asdf, mise).
    public struct Place: Sendable {
        public let origin: InstalledSoftware.Origin
        public let path: String
        /// Set for a folder of one runtime's versions; nil for a folder of tools.
        public let kind: Runtime.Kind?
    }

    public static let places: [Place] = [
        Place(origin: .pyenv, path: ".pyenv/versions", kind: .python),
        Place(origin: .nvm, path: ".nvm/versions/node", kind: .node),
        Place(origin: .fnm, path: ".local/share/fnm/node-versions", kind: .node),
        Place(origin: .fnm, path: "Library/Application Support/fnm/node-versions", kind: .node),
        Place(origin: .volta, path: ".volta/tools/image/node", kind: .node),
        Place(origin: .rbenv, path: ".rbenv/versions", kind: .ruby),
        Place(origin: .asdf, path: ".asdf/installs", kind: nil),
        Place(origin: .mise, path: ".local/share/mise/installs", kind: nil),
    ]

    /// Pure: a tool folder's runtime ("nodejs" and "node" are Node.js, "postgres" PostgreSQL).
    public static func kind(tool: String) -> Runtime.Kind? {
        switch tool {
        case "python": .python
        case "node", "nodejs": .node
        case "ruby": .ruby
        case "php": .php
        case "postgres", "postgresql": .postgresql
        case "mysql": .mysql
        default: nil
        }
    }

    /// Pure: a version folder's version, "v20.11.1" as "20.11.1"; nil for anything else
    /// ("miniconda3-latest", "system", "lts").
    public static func version(folder: String) -> String? {
        let text = folder.hasPrefix("v") ? String(folder.dropFirst()) : folder
        guard let first = text.first, first.isNumber, text.contains(".") else {
            return nil
        }
        return text
    }

    /// Pure: one runtime from a version manager's folder name.
    public static func runtime(folder: String, kind: Runtime.Kind, origin: InstalledSoftware.Origin) -> InstalledSoftware? {
        guard let version = version(folder: folder) else {
            return nil
        }
        return InstalledSoftware(
            name: kind == .node ? "node" : kind.rawValue, version: version, origin: origin,
            runtime: Runtime.cycle(of: version, kind: kind).map { Runtime(kind: kind, cycle: $0) }
        )
    }

    /// Pure: the command that gets a supported version, for the list.
    public static func command(for item: InstalledSoftware) -> String? {
        let kind = item.runtime?.kind
        switch item.origin {
        case .homebrew: return "brew upgrade \(item.name)"
        case .homebrewCask: return "brew upgrade --cask \(item.name)"
        case .pyenv: return "pyenv install 3"
        case .nvm: return "nvm install --lts"
        case .fnm: return "fnm install --lts"
        case .volta: return "volta install node@lts"
        case .rbenv: return "rbenv install --list"
        case .asdf: return kind.map { "asdf install \(tool(for: $0)) latest" }
        case .mise: return kind.map { "mise use --global \(tool(for: $0))@latest" }
        case .apple, .appUpdater: return nil
        case .homebrewItself: return "brew update"
        }
    }

    static func tool(for kind: Runtime.Kind) -> String {
        switch kind {
        case .node: "nodejs"
        case .postgresql: "postgres"
        default: kind.rawValue
        }
    }
}
