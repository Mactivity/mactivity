import Core
import Foundation

/// A running GUI app as `NSRunningApplication` describes it, captured as plain values.
public struct RunningApp: Hashable, Sendable {
    public let pid: Int32
    public let bundleID: String?
    public let name: String
    public let bundlePath: String?
    /// `activationPolicy == .regular`: has a Dock icon.
    public let isRegular: Bool

    public init(pid: Int32, bundleID: String?, name: String, bundlePath: String?, isRegular: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.bundlePath = bundlePath
        self.isRegular = isRegular
    }
}

/// What an app bundle's Info.plist says.
public struct BundleInfo: Hashable, Sendable {
    public let path: String
    public let bundleID: String?
    public let name: String

    public init(path: String, bundleID: String?, name: String) {
        self.path = path
        self.bundleID = bundleID
        self.name = name
    }
}

/// Process → app resolution (spec 6.2). Pure: all system state comes in as arguments.
public enum AppResolution {
    /// Terminals whose shell children group under the terminal (spec 5.1).
    public static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty",
        "com.github.wez.wezterm", "co.zeit.hyper", "com.raphaelamorim.rio", "app.tabby",
    ]

    /// Tools that live outside any `.app` but belong to one (D-106): the iOS Simulator's
    /// services, and the simulated devices' processes, are Simulator's.
    struct OwnedPath {
        let fragment: String
        let bundleID: String
        let name: String
        let path: String
    }

    static let ownedPaths: [OwnedPath] = [
        OwnedPath(
            fragment: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/", bundleID: "com.apple.iphonesimulator",
            name: "Simulator", path: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app"
        ),
        OwnedPath(
            fragment: "/Library/Developer/CoreSimulator/", bundleID: "com.apple.iphonesimulator",
            name: "Simulator", path: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app"
        ),
        // Xcode's device services (CoreDeviceService, the DevicesMenu extension), D-111.
        OwnedPath(
            fragment: "/Library/Developer/PrivateFrameworks/CoreDevice.framework/", bundleID: "com.apple.dt.Xcode",
            name: "Xcode", path: "/Applications/Xcode.app"
        ),
    ]

    /// Paths that belong to macOS itself.
    static let systemPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/private/var/db/"]

    /// Resolves each target process, first match wins:
    /// 1. its responsible process (private API; `responsible` is empty when unavailable),
    /// 2. the process itself, then its parents up to launchd, each matched against running apps
    ///    and then against the outermost `.app` in its executable path,
    /// 3. macOS itself for root processes, unreadable ones, and system paths,
    /// 4. "Other", keyed by executable name.
    ///
    /// Before all that, a process of another person signed in to this Mac is "Other users": their
    /// Slack isn't this user's Slack, to count in its row or to quit (D-221). Accounts are UIDs
    /// from 501; system accounts sit below, and nobody (-2) above.
    ///
    /// A bundle under a system path counts as macOS unless it's a regular running app (Finder
    /// stays Finder; ControlCenter's agents fold into macOS).
    public static func resolve(
        _ targets: [ProcessReading],
        all: [Int32: ProcessReading],
        responsible: [Int32: Int32],
        runningApps: [Int32: RunningApp],
        bundleAt: (String) -> BundleInfo?,
        ownUID: UInt32 = getuid()
    ) -> [Int32: AppIdentity] {
        var result: [Int32: AppIdentity] = [:]
        for process in targets {
            if process.uid != ownUID, (501 ..< 0x8000_0000).contains(process.uid) {
                result[process.pid] = .otherUsers
                continue
            }
            result[process.pid] = resolveOne(
                process, all: all, responsible: responsible, runningApps: runningApps, bundleAt: bundleAt
            )
        }
        return result
    }

    private static func resolveOne(
        _ process: ProcessReading,
        all: [Int32: ProcessReading],
        responsible: [Int32: Int32],
        runningApps: [Int32: RunningApp],
        bundleAt: (String) -> BundleInfo?
    ) -> AppIdentity {
        var chain: [Int32] = []
        if let owner = responsible[process.pid], owner != process.pid {
            chain.append(owner)
        }
        var current: Int32? = process.pid
        while let pid = current, pid > 1, chain.count < 64 {
            chain.append(pid)
            current = all[pid]?.parentPID
        }
        for pid in chain {
            if let identity = identify(pid, all: all, runningApps: runningApps, bundleAt: bundleAt) {
                return identity
            }
        }
        if process.uid == 0 || !process.isComplete || isSystemPath(process.executablePath) {
            return .system
        }
        return .other(executableName: process.name)
    }

    private static func identify(
        _ pid: Int32,
        all: [Int32: ProcessReading],
        runningApps: [Int32: RunningApp],
        bundleAt: (String) -> BundleInfo?
    ) -> AppIdentity? {
        if let owned = owner(of: runningApps[pid]?.bundlePath ?? all[pid]?.executablePath, runningApps: runningApps) {
            return owned
        }
        if let app = runningApps[pid] {
            if !app.isRegular, isSystemPath(app.bundlePath) {
                return .system
            }
            // A helper app nested in another bundle (a login item, a browser helper) belongs to
            // the outer app.
            if let path = app.bundlePath, let outer = outermostAppBundle(in: path), outer != path,
               let bundle = bundleAt(outer) {
                return identity(id: bundle.bundleID ?? bundle.path, name: bundle.name, bundleID: bundle.bundleID, path: bundle.path)
            }
            let key = app.bundleID ?? app.bundlePath ?? "pid:\(pid)"
            return identity(id: key, name: app.name, bundleID: app.bundleID, path: app.bundlePath ?? key)
        }
        guard let path = all[pid]?.executablePath, let bundlePath = outermostAppBundle(in: path),
              let bundle = bundleAt(bundlePath)
        else {
            return nil
        }
        if isSystemPath(bundlePath) {
            // A system bundle that is also a regular running app was caught above.
            return .system
        }
        return identity(id: bundle.bundleID ?? bundle.path, name: bundle.name, bundleID: bundle.bundleID, path: bundle.path)
    }

    private static func identity(id: String, name: String, bundleID: String?, path: String) -> AppIdentity {
        let kind: AppIdentity.Kind = bundleID.map { terminalBundleIDs.contains($0) } == true ? .terminal : .app
        return AppIdentity(id: id, name: name, bundleID: bundleID, iconKey: path, kind: kind)
    }

    /// The app an owned path belongs to, with the running copy's bundle for its icon when there is one.
    static func owner(of path: String?, runningApps: [Int32: RunningApp]) -> AppIdentity? {
        guard let path, let rule = ownedPaths.first(where: { path.contains($0.fragment) }) else {
            return nil
        }
        let running = runningApps.values.first { $0.bundleID == rule.bundleID }?.bundlePath
        return identity(id: rule.bundleID, name: rule.name, bundleID: rule.bundleID, path: running ?? rule.path)
    }

    /// "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper"
    /// → "/Applications/Slack.app".
    /// Pure: a bundle's name for people. Its display name or name, unless that's empty or just
    /// its bundle ID ("com.apple.CoreSimulator.CoreSimulatorService"), then its file name, or the
    /// ID's last part when the file is named after the ID too ("CoreSimulatorService"), D-111.
    static func bundleName(displayName: String?, name: String?, bundleID: String?, path: String) -> String {
        for candidate in [displayName, name] {
            if let candidate, !candidate.isEmpty, candidate != bundleID {
                return candidate
            }
        }
        let file = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        // An XPC service's file is often named after its bundle ID too: keep the last part.
        if file == bundleID, let last = file.split(separator: ".").last {
            return String(last)
        }
        return file
    }

    public static func outermostAppBundle(in path: String) -> String? {
        guard let range = path.range(of: ".app/") else {
            return path.hasSuffix(".app") ? path : nil
        }
        return String(path[..<range.lowerBound]) + ".app"
    }

    static func isSystemPath(_ path: String?) -> Bool {
        guard let path else {
            return false
        }
        return systemPrefixes.contains { path.hasPrefix($0) }
    }
}
