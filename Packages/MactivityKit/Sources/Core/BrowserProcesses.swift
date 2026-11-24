import Foundation

/// What each of a browser's (or an Electron app's) processes is for (D-154): tabs, extensions,
/// the GPU process, networking, the rest. Safari and every Chromium browser name their helpers
/// by role; only a Chromium extension needs its arguments (`--extension-process`) to tell it
/// from a tab. Pure.
public enum BrowserProcessKind: String, CaseIterable, Hashable, Sendable {
    case main, pages, extensions, gpu, network, plugins, utility

    /// Renderers need their arguments read to find extensions, plain helpers to find the
    /// network service.
    public static func needsArguments(_ name: String) -> Bool {
        name.hasSuffix(" Helper (Renderer)") || name.hasSuffix(" Helper")
    }

    /// Nil for a process that isn't a browser part (an app's own tool, a crash reporter…).
    public static func classify(name: String, arguments: [String], appName: String) -> BrowserProcessKind? {
        switch name {
        case "com.apple.WebKit.WebContent", "Safari Web Content": return .pages
        case "com.apple.WebKit.GPU", "Safari Graphics and Media": return .gpu
        case "com.apple.WebKit.Networking", "Safari Networking": return .network
        default: break
        }
        if name == appName {
            return .main
        }
        if name.hasSuffix(" Helper (Renderer)") {
            return arguments.contains("--extension-process") ? .extensions : .pages
        }
        if name.hasSuffix(" Helper (GPU)") {
            return .gpu
        }
        if name.hasSuffix(" Helper (Plugin)") {
            return .plugins
        }
        if name.hasSuffix(" Helper") {
            return arguments.contains { $0.contains("network.mojom.NetworkService") } ? .network : .utility
        }
        return nil
    }

    /// The main process's name: the app's, or for an Electron app whose executable is named
    /// differently ("Visual Studio Code" runs "Code"), the name its helpers start with.
    public static func mainName(_ names: [String], appName: String) -> String {
        if names.contains(appName) {
            return appName
        }
        for name in names {
            if let helper = name.range(of: " Helper") {
                let prefix = String(name[..<helper.lowerBound])
                if names.contains(prefix) {
                    return prefix
                }
            }
        }
        return appName
    }

    /// Browsers say "Tabs"; Electron apps' renderers are their windows.
    public static let browserBundleIDs: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary",
        "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "org.chromium.Chromium", "com.openai.atlas", "ai.perplexity.comet",
    ]

    public struct Group: Hashable, Sendable, Identifiable {
        public var id: BrowserProcessKind {
            kind
        }

        public let kind: BrowserProcessKind
        public let count: Int
        public let value: Double
    }

    /// Each kind's process count and summed figure, largest first; nil when there's nothing to
    /// split (fewer than two kinds, or three processes or fewer).
    public static func groups(
        _ processes: [ProcessSample], appName: String, metric: Metric, arguments: [Int32: [String]]
    ) -> [Group]? {
        guard processes.count > 3 else {
            return nil
        }
        var counts: [BrowserProcessKind: Int] = [:]
        var values: [BrowserProcessKind: Double] = [:]
        let main = mainName(processes.map(\.name), appName: appName)
        for process in processes {
            let kind = classify(name: process.name, arguments: arguments[process.pid] ?? [], appName: main) ?? .utility
            counts[kind, default: 0] += 1
            values[kind, default: 0] += process.value(for: metric) ?? 0
        }
        guard counts.count >= 2, counts[.pages] != nil else {
            return nil
        }
        return counts.keys
            .map { Group(kind: $0, count: counts[$0] ?? 0, value: values[$0] ?? 0) }
            .sorted { ($0.value, $1.kind.rawValue) > ($1.value, $0.kind.rawValue) }
    }
}

/// Process arguments, for the browser split (D-154).
public protocol ProcessArgumentReading: Sendable {
    func arguments(_ pid: Int32) -> [String]
}
