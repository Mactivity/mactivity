import Core
import Foundation

/// An installed app, as far as owner resolution needs one.
public struct InstalledApp: Hashable, Sendable, Codable {
    public let name: String
    public let bundleID: String
    /// The `.app` directory.
    public let path: String

    public init(name: String, bundleID: String, path: String) {
        self.name = name
        self.bundleID = bundleID
        self.path = path
    }
}

/// Pure rules for turning a plist into a `StartupItem`: which executable, which app, which flags.
/// The file system comes in as closures so fixtures can stand in for it (CLAUDE.md rule 9).
public enum StartupResolution {
    /// What launchd searches for a bare command name (`_PATH_STDPATH`).
    static let standardPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// Executables macOS ships. Many plists share them (`/bin/sh -c …`), so their path alone
    /// can't say whether this item is the one running.
    static let systemPrefixes = ["/System/", "/usr/bin/", "/bin/", "/usr/sbin/", "/sbin/", "/usr/libexec/"]

    /// Where installed software is expected to live. Anything else is flagged as an unusual location.
    static func usualPrefixes(home: String) -> [String] {
        ["/Applications/", "/Library/", "/usr/local/", "/opt/homebrew/", "/opt/local/", "\(home)/Applications/"] + systemPrefixes
    }

    /// Interpreters whose first path argument is the real program.
    static let interpreters: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish",
        "python", "python3", "perl", "ruby", "node", "osascript", "php",
    ]

    /// Reverse-DNS prefixes shared by unrelated projects, never used to guess an owner.
    static let sharedLabelPrefixes: Set<String> = ["com.github", "io.github", "com.gitlab", "org.sourceforge", "com.apple"]

    // MARK: Executable

    /// The executable a plist names: `Program`, else `BundleProgram` inside `bundlePath`, else
    /// `ProgramArguments[0]`. Bare command names are looked up in launchd's standard path.
    ///
    /// - Returns: the declared string (nil when the plist names nothing) and the absolute path
    ///   it resolves to (nil when it can't be resolved).
    public static func executable(
        for plist: LaunchdPlist,
        bundlePath: String?,
        exists: (String) -> Bool
    ) -> (declared: String?, path: String?) {
        if let program = plist.program {
            return (program, absolute(program, exists: exists))
        }
        if let bundleProgram = plist.bundleProgram {
            guard let bundlePath else {
                return (bundleProgram, nil)
            }
            let trimmed = bundleProgram.hasPrefix("/") ? String(bundleProgram.dropFirst()) : bundleProgram
            return (bundleProgram, (bundlePath as NSString).appendingPathComponent(trimmed))
        }
        if let first = plist.declaredExecutable {
            return (first, absolute(first, exists: exists))
        }
        return (nil, nil)
    }

    private static func absolute(_ command: String, exists: (String) -> Bool) -> String? {
        if command.hasPrefix("/") {
            return (command as NSString).standardizingPath
        }
        guard !command.contains("/") else {
            // Relative paths depend on launchd's working directory: unresolvable.
            return nil
        }
        return standardPath.map { "\($0)/\(command)" }.first(where: exists)
    }

    /// For `/bin/sh /path/to/script.sh` or `python3 /path/tool.py`, the script is what matters.
    public static func scriptPath(executable: String?, arguments: [String]) -> String? {
        guard let executable, interpreters.contains((executable as NSString).lastPathComponent),
              let first = arguments.first(where: { !$0.hasPrefix("-") }), first.hasPrefix("/") else {
            return nil
        }
        // `sh -c "…"` runs a command string, not a file.
        if arguments.first == "-c" {
            return nil
        }
        return (first as NSString).standardizingPath
    }

    /// The outermost `.app` in a path: `/Applications/Foo.app/Contents/Helpers/Bar.app/…` → `/Applications/Foo.app`.
    public static func outermostApp(in path: String) -> String? {
        var components: [String] = []
        for component in (path as NSString).pathComponents {
            components.append(component)
            if component.lowercased().hasSuffix(".app") {
                return NSString.path(withComponents: components)
            }
        }
        return nil
    }

    // MARK: Owner

    /// `AssociatedBundleIdentifiers`, then the executable's outermost `.app` (or the app the plist
    /// ships in, or the name of the app it ran from if that app is gone), then the label's
    /// reverse-DNS prefix, then Unknown.
    ///
    /// - Parameter appAt: reads the app at a bundle path that isn't in `apps` (an app outside
    ///   /Applications, like an updater in Application Support).
    public static func owner(
        plist: LaunchdPlist?,
        label: String,
        executablePath: String?,
        containingAppPath: String?,
        apps: [InstalledApp],
        appAt: (String) -> InstalledApp? = { _ in nil }
    ) -> StartupOwner {
        for identifier in plist?.associatedBundleIdentifiers ?? [] {
            if let app = apps.first(where: { $0.bundleID.caseInsensitiveCompare(identifier) == .orderedSame }) {
                return owner(app, .associatedBundleIdentifier)
            }
        }
        let executableApp = executablePath.flatMap(outermostApp(in:))
        if let bundle = executableApp, let app = apps.first(where: { $0.path == bundle }) ?? appAt(bundle) {
            return owner(app, .executablePath)
        }
        if let containingAppPath, let app = apps.first(where: { $0.path == containingAppPath }) ?? appAt(containingAppPath) {
            return owner(app, .containingApp)
        }
        if let bundle = executableApp {
            // The app it ran from is gone: name it, so leftovers group under the app that left them.
            let name = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
            return StartupOwner(name: name, bundleID: nil, bundlePath: nil, evidence: .missingApp)
        }
        if let app = appMatching(label: label, in: apps) {
            return owner(app, .labelPrefix)
        }
        return .unknown
    }

    private static func owner(_ app: InstalledApp, _ evidence: StartupOwner.Evidence) -> StartupOwner {
        StartupOwner(name: app.name, bundleID: app.bundleID, bundlePath: app.path, evidence: evidence)
    }

    /// The app whose bundle ID shares the longest reverse-DNS prefix (at least two parts) with the label.
    static func appMatching(label: String, in apps: [InstalledApp]) -> InstalledApp? {
        let parts = label.lowercased().split(separator: ".").map(String.init)
        guard parts.count >= 2 else {
            return nil
        }
        for length in stride(from: parts.count, through: 2, by: -1) {
            let prefix = parts.prefix(length).joined(separator: ".")
            if length == 2, sharedLabelPrefixes.contains(prefix) {
                return nil
            }
            let matches = apps.filter {
                let id = $0.bundleID.lowercased()
                return id == prefix || id.hasPrefix(prefix + ".")
            }
            if let best = matches.min(by: { ($0.bundleID.count, $0.name) < ($1.bundleID.count, $1.name) }) {
                return best
            }
        }
        return nil
    }

    // MARK: Flags

    /// Broken when the plist names no program or the program is missing; unusual when it (or
    /// the script it runs) lives outside the usual install locations.
    public static func flags(
        declared: String?,
        executablePath: String?,
        scriptPath: String?,
        home: String,
        exists: (String) -> Bool
    ) -> [StartupFlag] {
        guard let declared else {
            return [StartupFlag(.broken, String(
                localized: "Its plist doesn't name a program to run, so launchd can't start it.",
                bundle: .strings,
                comment: "Startup flag reason"
            ))]
        }
        guard let executablePath else {
            return [StartupFlag(.broken, String(
                localized: "Can't find “\(declared)”.",
                bundle: .strings,
                comment: "Startup flag reason; the argument is the program its plist names"
            ))]
        }
        var flags: [StartupFlag] = []
        if !exists(executablePath) {
            flags.append(StartupFlag(.broken, String(
                localized: "Its program is missing, probably left behind by an app that was removed.",
                bundle: .strings,
                comment: "Startup flag reason"
            )))
        } else if let scriptPath, !exists(scriptPath) {
            flags.append(StartupFlag(
                .broken,
                String(localized: "The script it runs is missing.", bundle: .strings, comment: "Startup flag reason")
            ))
        }
        let usual = usualPrefixes(home: home)
        if let path = [executablePath, scriptPath].compactMap(\.self).first(where: { !usual.contains(where: $0.hasPrefix) }) {
            flags.append(StartupFlag(
                .unusualLocation,
                String(
                    localized: "It runs from \(folder(of: path, home: home)), not from Applications, Library, or Homebrew.",
                    bundle: .strings,
                    comment: "Startup flag reason; the argument is a folder like ~/Library/Application Support"
                )
            ))
        }
        return flags
    }

    /// The top folders a path sits in, for a one-line reason: `~/Library/Application Support`, `/tmp`.
    static func folder(of path: String, home: String) -> String {
        let abbreviated = Formatters.displayPath((path as NSString).deletingLastPathComponent, home: home)
        let parts = (abbreviated as NSString).pathComponents
        return NSString.path(withComponents: Array(parts.prefix(3)))
    }

    /// Whether the executable is one many items share, so its running process proves nothing.
    public static func isShared(_ path: String, scriptPath: String?) -> Bool {
        scriptPath != nil || systemPrefixes.contains(where: path.hasPrefix)
    }

    // MARK: State

    public static func state(plist: LaunchdPlist?, location: StartupLocation, loginItemsStatus: LoginItemsStatus?) -> StartupState {
        if location == .disabledByMactivity {
            return .disabledByMactivity
        }
        if plist?.disabled == true {
            return .disabledInPlist
        }
        switch loginItemsStatus {
        case .requiresApproval:
            return .turnedOffInSettings
        case .enabled:
            return .on
        case .notRegistered, .notFound, nil:
            // Legacy plists in the Library folders load whether or not Login Items lists them;
            // helpers inside an app load only once the app registers them.
            return location == .appBundle ? .notRegistered : .on
        }
    }
}
