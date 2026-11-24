import Core
import Darwin
import Foundation

/// Which support files are left behind (D-282).
extension OldApps {

    // MARK: What a name means

    /// What a Library item's name says, for each folder looked in. Containers and Group Containers
    /// aren't here on purpose: they hold people's documents, may be shared between apps, and
    /// macOS asks before another app reads them.
    enum Place: String, CaseIterable {
        case applicationSupport = "Application Support"
        case caches = "Caches"
        case logs = "Logs"
        case webKit = "WebKit"
        case httpStorages = "HTTPStorages"
        case cookies = "Cookies"
        case savedState = "Saved Application State"
        case preferences = "Preferences"
        case byHost = "Preferences/ByHost"

        var kind: UninstallItem.Kind {
            switch self {
            case .applicationSupport: .applicationSupport
            case .caches: .caches
            case .logs: .logs
            case .webKit, .httpStorages, .cookies: .webData
            case .savedState: .savedState
            case .preferences, .byHost: .preferences
            }
        }

        /// Folders apps name after themselves too (as in `AppLeftovers.candidates`).
        var allowsNames: Bool {
            self == .applicationSupport || self == .caches || self == .logs
        }
    }

    /// The name inside an item's file name, or nil when it isn't the shape this folder's items
    /// take: a `Foo.txt` in Preferences isn't anybody's settings file.
    static func ownerName(of item: String, in place: Place) -> String? {
        guard !item.hasPrefix("."), !item.contains("/") else {
            return nil
        }
        switch place {
        case .applicationSupport, .caches, .logs, .webKit:
            return item
        case .httpStorages:
            return item.hasSuffix(".binarycookies") ? String(item.dropLast(14)) : item
        case .cookies:
            return item.hasSuffix(".binarycookies") ? String(item.dropLast(14)) : nil
        case .savedState:
            return item.hasSuffix(".savedState") ? String(item.dropLast(11)) : nil
        case .preferences:
            return item.hasSuffix(".plist") ? String(item.dropLast(6)) : nil
        case .byHost:
            // "com.foo.App.3D2C1F00-….plist"
            guard item.hasSuffix(".plist") else {
                return nil
            }
            let base = String(item.dropLast(6))
            guard let dot = base.lastIndex(of: "."),
                  base[base.index(after: dot)...].range(of: #"^[0-9A-Fa-f-]{8,36}$"#, options: .regularExpression) != nil
            else {
                return nil
            }
            return String(base[..<dot])
        }
    }

    private static let topLevelDomains: Set<String> = [
        "com", "org", "net", "io", "co", "app", "dev", "ai", "me", "de", "fr", "uk", "jp", "cn", "ch", "nl", "se", "no", "fi", "dk",
        "us", "ca", "au", "nz", "ru", "pl", "it", "es", "cz", "at", "be", "eu", "tv", "cc", "ly", "sh", "so", "xyz", "info", "tech",
    ]

    /// A full bundle ID: a domain, a vendor and a product at least. `com.crashlytics`, `python3.11.5`
    /// and `data.backup.old` aren't.
    static func isFullBundleID(_ name: String) -> Bool {
        guard AppLeftovers.isSafeBundleID(name) else {
            return false
        }
        let parts = name.split(separator: ".")
        guard parts.count >= 3, let domain = parts.first, topLevelDomains.contains(String(domain)) else {
            return false
        }
        return parts.dropFirst().allSatisfy { $0.first?.isNumber == false }
    }

    /// Never listed, installed or not: Apple's and macOS's, shared groups, and libraries and
    /// runtimes that any number of apps and tools use under one name.
    static func isUntouchable(_ name: String) -> Bool {
        let id = name.lowercased()
        return untouchablePrefixes.contains { id.hasPrefix($0) }
    }

    private static let untouchablePrefixes = [
        "com.apple.", "apple.", "group.", "systemgroup.", "icloud.", "org.sparkle-project.", "com.crashlytics", "io.sentry.",
        "com.getsentry.", "com.plausiblelabs.", "net.hockeyapp.", "io.fabric.", "com.firebase.", "com.google.firebase.",
        "com.bugsnag.", "com.amplitude.", "com.mixpanel.", "com.segment.", "org.cocoapods.", "com.github.electron", "com.github.squirrel",
        "org.electronjs.", "org.chromium.", "org.python.", "com.oracle.", "net.java.", "org.openjdk.", "com.sun.", "org.llvm.",
        "org.swift.", "org.gnu.", "org.nodejs.", "sh.brew.", "org.homebrew.",
    ]

    /// IDs that start-ups and templates leave in place, shared by unrelated apps: two of them
    /// aren't copies of one app.
    private static let templateIDs: Set<String> = [
        "com.github.electron", "org.nwjs.nwjs", "com.tauri.dev", "com.electron.app", "com.electron.nativefier",
    ]

    static func isTemplateID(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return templateIDs.contains(id) || id.hasPrefix("com.example.") || id.hasPrefix("com.yourcompany.") || id.hasPrefix("org.example.")
    }

    // MARK: Leftovers

    /// What walking an item found. Nil from `facts` when part of it can't be read: what can't be
    /// read can't be said to be untouched.
    struct Facts {
        var size: UInt64 = 0
        var newest: Date = .distantPast
        var fileCount = 0
        var contents: [String] = []
    }

    static func facts(of url: URL) -> Facts? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .creationDateKey]
        let keySet = Set(keys)
        var facts = Facts()
        func note(_ values: URLResourceValues) {
            for date in [values.contentModificationDate, values.creationDate] {
                if let date, date > facts.newest {
                    facts.newest = date
                }
            }
            if values.isRegularFile == true {
                facts.size += UInt64(values.totalFileAllocatedSize ?? 0)
                facts.fileCount += 1
            }
        }
        guard let top = try? url.resourceValues(forKeys: keySet) else {
            return nil
        }
        note(top)
        if top.isRegularFile == true {
            return facts
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path))
        guard let names else {
            return nil
        }
        facts.contents = names.filter { !$0.hasPrefix(".") }.sorted().prefix(4).map(\.self)
        var unreadable = false
        let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: []) { _, _ in
            unreadable = true
            return true
        }
        while let file = walk?.nextObject() as? URL {
            if let values = try? file.resourceValues(forKeys: keySet) {
                note(values)
            } else {
                unreadable = true
            }
        }
        return unreadable ? nil : facts
    }

    static func isInUse(_ path: String, inUse: [String]) -> Bool {
        let path = path.lowercased()
        return inUse.contains { used in
            let used = used.lowercased()
            return used == path || used.hasPrefix(path + "/")
        }
    }

    /// One item judged against everything: nil unless it's clearly left behind.
    static func leftover(
        at url: URL, place: Place, env: OldAppsEnvironment, claims: Claims, inUse: [String], evidence: Set<String>
    ) -> AppSupportLeftover? {
        let item = url.lastPathComponent
        guard let owner = ownerName(of: item, in: place), !isUntouchable(owner), !isLink(url.path) else {
            return nil
        }
        let recorded = env.recordedApps
        var appName: String?
        var byName = false
        if isFullBundleID(owner) {
            let known = env.launchServicesCopies(owner)
            guard !claims.covers(bundleID: owner), known.isEmpty else {
                return nil
            }
            appName = recorded.first { $0.bundleID.caseInsensitiveCompare(owner) == .orderedSame }?.name
            // Command-line tools and parts of macOS name things this way too ("org.cups.…",
            // "com.charcoaldesign.swiftformat"), so the ID needs some sign an app with windows
            // ever used it. And an app of that name still here has only changed its ID.
            guard evidence.contains(owner.lowercased()) || hasWindowSettings(owner, library: env.home.appendingPathComponent("Library")),
                  !(appName.map { claims.names.contains($0.lowercased()) } ?? false)
            else {
                return nil
            }
        } else {
            // The exact name of an app Mactivity saw run, that isn't here any more, and nothing
            // else: a folder called "Google" or "Foo Helper" says nothing about who owns it.
            guard place.allowsNames, AppLeftovers.isSpecificName(owner), !claims.names.contains(owner.lowercased()),
                  // Exact to the letter: "ollama" in Caches is the command-line tool's, not Ollama's.
                  let app = recorded.first(where: { $0.isApp && $0.name == owner }),
                  !isUntouchable(app.bundleID), !claims.covers(bundleID: app.bundleID), env.launchServicesCopies(app.bundleID).isEmpty
            else {
                return nil
            }
            appName = app.name
            byName = true
        }
        guard !isInUse(url.path, inUse: inUse), let facts = facts(of: url),
              env.now.timeIntervalSince(facts.newest) >= env.minimumAge
        else {
            return nil
        }
        return AppSupportLeftover(
            path: url.path, kind: place.kind, owner: owner, appName: appName, matchedByName: byName, size: facts.size,
            lastChanged: facts.newest, fileCount: facts.fileCount, contents: facts.contents
        )
    }

    /// IDs with a sign that an app with windows used them: Mactivity saw it run, or macOS saved
    /// its windows' state, which only apps with windows have.
    static func appEvidence(_ env: OldAppsEnvironment, library: URL) -> Set<String> {
        var evidence = Set(env.recordedApps.filter { $0.isApp }.map { $0.bundleID.lowercased() })
        let states = library.appendingPathComponent(Place.savedState.rawValue)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: states.path)) ?? [] {
            if let owner = ownerName(of: name, in: .savedState) {
                evidence.insert(owner.lowercased())
            }
        }
        return evidence
    }

    /// Whether this ID's settings file remembers a window: AppKit writes these, a command-line
    /// tool has none.
    static func hasWindowSettings(_ bundleID: String, library: URL) -> Bool {
        let url = library.appendingPathComponent("\(Place.preferences.rawValue)/\(bundleID).plist")
        guard !isLink(url.path), let data = try? Data(contentsOf: url),
              let settings = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else {
            return false
        }
        return settings.keys.contains { $0.hasPrefix("NSWindow Frame") || $0.hasPrefix("NSSplitView Subview Frames") }
    }

    /// Everything left behind, largest first.
    public static func leftovers(_ env: OldAppsEnvironment) -> [AppSupportLeftover] {
        let inUse = env.inUsePaths()
        let claims = claims(env, inUse: inUse)
        let library = env.home.appendingPathComponent("Library")
        let evidence = appEvidence(env, library: library)
        var found: [AppSupportLeftover] = []
        for place in Place.allCases {
            let folder = library.appendingPathComponent(place.rawValue)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                if let item = leftover(
                    at: folder.appendingPathComponent(name), place: place, env: env, claims: claims, inUse: inUse, evidence: evidence
                ) {
                    found.append(item)
                }
            }
        }
        return found.sorted { ($0.size, $1.path) > ($1.size, $0.path) }
    }

    /// Everything judged again, right before the Trash: an app may have been installed, or the
    /// folder written to, since the list was made.
    public static func stillLeftover(_ path: String, env: OldAppsEnvironment) -> Bool {
        let url = URL(fileURLWithPath: path)
        let library = env.home.appendingPathComponent("Library")
        let parent = url.deletingLastPathComponent().path
        guard let place = Place.allCases.first(where: { library.appendingPathComponent($0.rawValue).path == parent }) else {
            return false
        }
        let inUse = env.inUsePaths()
        return leftover(
            at: url, place: place, env: env, claims: claims(env, inUse: inUse), inUse: inUse, evidence: appEvidence(env, library: library)
        ) != nil
    }
}
