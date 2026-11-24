import Core
import Foundation
import os
import PrivateAPIs

/// Installed software on this Mac (D-252): Homebrew through its own `brew` command, the version
/// managers' folders, and Apple's Python and Ruby from their framework folders.
public struct LiveInstalledSoftware: InstalledSoftwareSource {
    private static let logger = Logger(subsystem: "app.mactivity.projects", category: "software")
    /// Apple silicon only (CLAUDE.md), so Homebrew is in /opt/homebrew.
    static let brew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")

    let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    public func installed() async -> [InstalledSoftware] {
        var items: [InstalledSoftware] = []
        if let data = await Self.run(["info", "--json=v2", "--installed"], timeout: .seconds(60))?.output {
            items += InstalledSoftwareParsing.homebrew(data)
        }
        items += versionManagers()
        items += Self.apple()
        // Known issues from the table that ships with Mactivity (D-257): Homebrew itself, and apps
        // carrying an old Sparkle.
        if let brew = await Self.run(["--version"], timeout: .seconds(30)), let version = Self.homebrewVersion(brew.output) {
            items.append(InstalledSoftware(
                name: "Homebrew", version: version, origin: .homebrewItself, vulnerabilities: KnownIssues.homebrew(version: version)
            ))
        }
        items += appsWithOldUpdaters(home: home)
        return items
    }

    public func vulnerabilities() async -> VulnerabilityScan? {
        // `brew vulns` exits 1 when it finds something; the JSON says what.
        guard let data = await Self.run(["vulns", "--json"], timeout: .seconds(300))?.output else {
            return nil
        }
        return InstalledSoftwareParsing.vulnerabilities(data)
    }

    public func upgradePlan(_ formulae: [String]) async -> [String] {
        guard !formulae.isEmpty, let result = await Self.run(["upgrade", "--dry-run"] + formulae, timeout: .seconds(60)) else {
            return []
        }
        return InstalledSoftwareParsing.upgradePlan(String(bytes: result.output, encoding: .utf8) ?? "")
    }

    public func upgrade(_ confirmation: UpgradeConfirmation) async -> UpgradeResult {
        // Homebrew's own update first, as when the person runs it; never with sudo.
        guard let result = await Self.run(["upgrade"] + confirmation.formulae, timeout: .seconds(1800), offline: false) else {
            return UpgradeResult(succeeded: false, output: "")
        }
        let text = String(bytes: result.output, encoding: .utf8) ?? ""
        Self.logger.info("brew upgrade \(confirmation.formulae.joined(separator: " "), privacy: .public): \(result.status)")
        return UpgradeResult(succeeded: result.status == 0, output: String(text.suffix(2000)))
    }

    // MARK: Reading

    func versionManagers() -> [InstalledSoftware] {
        let files = FileManager.default
        var items: [InstalledSoftware] = []
        for place in InstalledSoftwareParsing.places {
            let root = (home as NSString).appendingPathComponent(place.path)
            guard let entries = try? files.contentsOfDirectory(atPath: root) else {
                continue
            }
            if let kind = place.kind {
                items += entries.compactMap { InstalledSoftwareParsing.runtime(folder: $0, kind: kind, origin: place.origin) }
                continue
            }
            for tool in entries {
                guard let kind = InstalledSoftwareParsing.kind(tool: tool),
                      let versions = try? files.contentsOfDirectory(atPath: (root as NSString).appendingPathComponent(tool))
                else {
                    continue
                }
                items += versions.compactMap { folder in
                    // mise keeps "20" and "latest" as links to a real version.
                    let path = ((root as NSString).appendingPathComponent(tool) as NSString).appendingPathComponent(folder)
                    let isLink = (try? files.destinationOfSymbolicLink(atPath: path)) != nil
                    return isLink ? nil : InstalledSoftwareParsing.runtime(folder: folder, kind: kind, origin: place.origin)
                }
            }
        }
        return items
    }

    /// The Python that comes with Xcode's tools and the Ruby in macOS, read from their folders:
    /// running `/usr/bin/python3` without the tools opens an install dialog.
    static func apple() -> [InstalledSoftware] {
        var items: [InstalledSoftware] = []
        let pythons = [
            "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/Current/Resources/Info.plist",
            "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/Current/Resources/Info.plist",
        ]
        let python = pythons.lazy.compactMap { NSDictionary(contentsOfFile: $0)?["CFBundleShortVersionString"] as? String }.first
        if let python {
            items.append(InstalledSoftware(
                name: "python3", version: python, origin: .apple,
                runtime: Runtime.cycle(of: python, kind: .python).map { Runtime(kind: .python, cycle: $0) }
            ))
        }
        let rubies = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Frameworks/Ruby.framework/Versions")) ?? []
        if let ruby = rubies.filter({ $0.first?.isNumber == true }).max() {
            items.append(InstalledSoftware(
                name: "ruby", version: ruby, origin: .apple,
                runtime: Runtime.cycle(of: ruby, kind: .ruby).map { Runtime(kind: .ruby, cycle: $0) }
            ))
        }
        return items
    }

    /// "Homebrew 7.0.10-37-g1ef73bb" → "7.0.10-37-g1ef73bb".
    static func homebrewVersion(_ output: Data) -> String? {
        let first = String(bytes: output, encoding: .utf8)?.split(separator: "\n").first.map(String.init) ?? ""
        guard first.hasPrefix("Homebrew ") else {
            return nil
        }
        return String(first.dropFirst("Homebrew ".count))
    }

    /// Apps in /Applications, its Utilities and ~/Applications carrying a Sparkle with known
    /// vulnerabilities (D-257): one Info.plist read per app that has one, about 100 ms.
    func appsWithOldUpdaters(home: String) -> [InstalledSoftware] {
        let folders = ["/Applications", "/Applications/Utilities", (home as NSString).appendingPathComponent("Applications")]
        var found: [InstalledSoftware] = []
        for folder in folders {
            let apps = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".app") }
            for name in apps {
                let app = (folder as NSString).appendingPathComponent(name)
                let sparkle = (app as NSString).appendingPathComponent("Contents/Frameworks/Sparkle.framework/Resources/Info.plist")
                guard let version = NSDictionary(contentsOfFile: sparkle)?["CFBundleShortVersionString"] as? String else {
                    continue
                }
                let issues = KnownIssues.sparkle(version: version)
                guard !issues.isEmpty else {
                    continue
                }
                let info = NSDictionary(contentsOfFile: (app as NSString).appendingPathComponent("Contents/Info.plist"))
                found.append(InstalledSoftware(
                    name: (name as NSString).deletingPathExtension,
                    version: info?["CFBundleShortVersionString"] as? String ?? "",
                    origin: .appUpdater, vulnerabilities: issues, component: "Sparkle \(version)", path: app
                ))
            }
        }
        return found
    }

    // MARK: Running brew

    /// Runs `brew` with no terminal and nothing to answer, stopping it after `timeout`. Offline
    /// (the default) keeps Homebrew from updating itself or sending its analytics, so reading
    /// never goes online. Nil when Homebrew isn't installed or the run timed out. It runs on its
    /// own responsibility (D-263): anything running as this user can change `brew`, so it must
    /// never hold Mactivity's Full Disk Access.
    static func run(_ arguments: [String], timeout: Duration, offline: Bool = true) async -> DisclaimedProcess.Finished? {
        guard FileManager.default.isExecutableFile(atPath: brew.path) else {
            return nil
        }
        var environment = [
            "HOME": NSHomeDirectory(), "PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8", "HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_COLOR": "1", "HOMEBREW_NO_EMOJI": "1",
        ]
        if offline {
            environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            environment["HOMEBREW_NO_ANALYTICS"] = "1"
        }
        return await DisclaimedProcess.run(path: brew.path, arguments: arguments, environment: environment, timeout: timeout)
    }
}
