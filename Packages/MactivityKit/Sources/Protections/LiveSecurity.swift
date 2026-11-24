import Core
import Foundation
import PrivateAPIs

/// The Security page's real source (1.9, D-261). Each read runs a few short commands or reads a
/// few files, only while the page is open.
public struct LiveSecurity: SecuritySource {
    private let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    public func settings() async -> SecuritySettings {
        async let fileVault = Command.output("/usr/bin/fdesetup", ["status"])
        async let integrity = Command.output("/usr/bin/csrutil", ["status"])
        async let gatekeeper = Command.output("/usr/sbin/spctl", ["--status"])
        async let firewall = Command.output("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"])
        let updates = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.SoftwareUpdate.plist") as? [String: Any] ?? [:]
        let automatic = SecurityParsing.updates(updates)
        return await SecuritySettings(
            fileVault: fileVault.flatMap(SecurityParsing.fileVault),
            firewall: firewall.flatMap(LiveSecurity.firewallState),
            gatekeeper: gatekeeper.flatMap(SecurityParsing.gatekeeper),
            systemIntegrity: integrity.flatMap(SecurityParsing.systemIntegrity),
            securityResponses: automatic.securityResponses,
            macOSUpdates: automatic.macOSUpdates
        )
    }

    /// "Firewall is enabled. (State = 1)", as Open to the network reads it (D-231).
    static func firewallState(_ output: String) -> Bool? {
        if output.contains("enabled") {
            return true
        }
        return output.contains("disabled") ? false : nil
    }

    public func permissions() async -> PermissionsReading {
        let home = home
        return await Task.detached(priority: .utility) { TCCDatabase.read(home: home) }.value
    }

    public func systemExtensions() async -> [SystemExtensionItem] {
        async let system = Command.output("/usr/bin/systemextensionsctl", ["list"])
        async let kernel = Command.output("/usr/bin/kmutil", ["showloaded", "--list-only"])
        return await SecurityParsing.systemExtensions(system ?? "") + SecurityParsing.kernelExtensions(kernel ?? "")
    }

    public func browserExtensions() async -> BrowserExtensionsReading {
        let home = home
        let safari = await safariExtensions()
        return await Task.detached(priority: .utility) {
            var found = safari
            var blocked: [Browser] = []
            for (browser, folder) in BrowserExtensionReading.chromiumRoots {
                switch Self.chromium(browser, root: (home as NSString).appendingPathComponent(folder)) {
                case let .some(extensions): found += extensions
                case .none: blocked.append(browser)
                }
            }
            switch Self.firefox(root: (home as NSString).appendingPathComponent("Library/Application Support/Firefox/Profiles")) {
            case let .some(extensions): found += extensions
            case .none: blocked.append(.firefox)
            }
            return BrowserExtensionsReading(extensions: found, blocked: blocked)
        }.value
    }

    private func safariExtensions() async -> [BrowserExtension] {
        let listing = await Command.output("/usr/bin/pluginkit", ["-mAvvv", "-p", "com.apple.Safari.web-extension"]) ?? ""
        return BrowserExtensionReading.safari(listing).map { item in
            let manifest = Self.json(URL(fileURLWithPath: item.path).appendingPathComponent("Contents/Resources/manifest.json"))
            return BrowserExtension(
                browser: .safari, identifier: item.identifier, name: item.name, version: item.version, isOn: nil,
                permissions: manifest.map(BrowserExtensionReading.permissions) ?? []
            )
        }
    }

    /// A Chromium browser's extensions across its profiles: an empty list when it isn't
    /// installed, nil when its folder is there but can't be read.
    static func chromium(_ browser: Browser, root: String) -> [BrowserExtension]? {
        let files = FileManager.default
        guard files.fileExists(atPath: root) else {
            return []
        }
        guard let names = try? files.contentsOfDirectory(atPath: root) else {
            return nil
        }
        var found: [String: BrowserExtension] = [:]
        for profile in names where profile == "Default" || profile.hasPrefix("Profile ") {
            let folder = URL(fileURLWithPath: root).appendingPathComponent(profile)
            let preferences = (json(folder.appendingPathComponent("Secure Preferences")) ?? [:])
                .merging(json(folder.appendingPathComponent("Preferences")) ?? [:]) { first, _ in first }
            let settings = ((preferences["extensions"] as? [String: Any])?["settings"] as? [String: Any]) ?? [:]
            let extensions = folder.appendingPathComponent("Extensions")
            for identifier in (try? files.contentsOfDirectory(atPath: extensions.path)) ?? [] where !identifier.hasPrefix(".") {
                // Each version in its own folder; the newest is the one in use.
                let versions = ((try? files.contentsOfDirectory(atPath: extensions.appendingPathComponent(identifier).path)) ?? [])
                    .filter { !$0.hasPrefix(".") }
                guard let version = versions.max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) else {
                    continue
                }
                let base = extensions.appendingPathComponent(identifier).appendingPathComponent(version)
                guard let manifest = json(base.appendingPathComponent("manifest.json")) else {
                    continue
                }
                let language = manifest["default_locale"] as? String ?? "en"
                let messages = json(base.appendingPathComponent("_locales/\(language)/messages.json"))
                guard let item = BrowserExtensionReading.chromium(
                    browser: browser, identifier: identifier, manifest: manifest, messages: messages,
                    settings: settings[identifier] as? [String: Any]
                ) else {
                    continue
                }
                // In two profiles: one row, on if it's on in either.
                if let existing = found[identifier], existing.isOn == true {
                    continue
                }
                found[identifier] = item
            }
        }
        return Array(found.values)
    }

    /// Firefox's profiles: empty when it isn't installed, nil when they can't be read.
    static func firefox(root: String) -> [BrowserExtension]? {
        let files = FileManager.default
        guard files.fileExists(atPath: root) else {
            return []
        }
        guard let profiles = try? files.contentsOfDirectory(atPath: root) else {
            return nil
        }
        var seen: Set<String> = []
        return profiles.flatMap { profile -> [BrowserExtension] in
            let file = URL(fileURLWithPath: root).appendingPathComponent(profile).appendingPathComponent("extensions.json")
            return (try? Data(contentsOf: file)).map(BrowserExtensionReading.firefox) ?? []
        }
        .filter { seen.insert($0.identifier).inserted }
    }

    static func json(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

/// Runs a short command and returns what it printed (1.9).
enum Command {
    static func output(_ path: String, _ arguments: [String], timeout: TimeInterval = 10) async -> String? {
        await Task.detached(priority: .utility) { run(path, arguments, timeout: timeout) }.value
    }

    /// Standard output and error together (`fdesetup` and `csrutil` print to either), or nil when
    /// it can't start or runs past the timeout.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else {
            return nil
        }
        let box = Box()
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        guard read.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return String(bytes: box.data, encoding: .utf8)
    }

    /// The output a reading thread hands back; written once, before the semaphore it waits on.
    private final class Box: @unchecked Sendable {
        var data = Data()
    }
}
