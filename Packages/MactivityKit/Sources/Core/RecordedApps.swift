import Foundation

/// An app Mactivity has seen run, from history's list of apps (D-282): how Old Versions and
/// Leftovers knows a folder named after an app that's gone is that app's.
public struct RecordedApp: Hashable, Sendable {
    public let name: String
    public let bundleID: String
    /// A bundled app, as opposed to a terminal or a command-line tool.
    public let isApp: Bool

    public init(name: String, bundleID: String, isApp: Bool = true) {
        self.name = name
        self.bundleID = bundleID
        self.isApp = isApp
    }
}

public protocol RecordedAppsStore: Sendable {
    /// Every app with a bundle ID that history has a row for.
    func recordedApps() async throws -> [RecordedApp]
}
