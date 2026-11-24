import Foundation
import os

/// Disables a user launch agent by moving its plist out of `~/Library/LaunchAgents`, and
/// enables it by moving it back. Nothing is deleted, nothing outside that one folder (and its
/// "Disabled by Mactivity" sibling) is touched, and `launchctl` is never run, so the change
/// takes effect at the next login.
///
/// Call it only after the user confirms in the system dialog (the Startup view does).
public struct UserLaunchAgentToggle: Sendable {
    private static let log = Logger(subsystem: "app.mactivity.startup", category: "toggle")

    public static let disabledFolderName = "LaunchAgents (Disabled by Mactivity)"

    /// `~/Library/LaunchAgents`, or a temporary stand-in in tests.
    public let agentsDirectory: URL

    public init(agentsDirectory: URL) {
        self.agentsDirectory = agentsDirectory.standardizedFileURL
    }

    public static var user: UserLaunchAgentToggle {
        UserLaunchAgentToggle(
            agentsDirectory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        )
    }

    /// The sibling folder disabled plists move to.
    public var disabledDirectory: URL {
        agentsDirectory.deletingLastPathComponent().appendingPathComponent(Self.disabledFolderName)
    }

    public enum ToggleError: Error, Equatable, LocalizedError {
        /// Only plists directly inside the expected folder can move.
        case notInFolder(String)
        /// A file with the same name is already where it would go.
        case alreadyExists(String)
        case moveFailed(String)

        public var errorDescription: String? {
            switch self {
            case let .notInFolder(name):
                String(
                    localized: "“\(name)” isn't in the folder Mactivity can change.",
                    bundle: .strings,
                    comment: "Error disabling a startup item; the argument is a file or item name"
                )
            case let .alreadyExists(name):
                String(
                    localized: "There's already a “\(name)” there, so Mactivity left both where they are.",
                    bundle: .strings,
                    comment: "Error moving a launch agent plist; the argument is its file name"
                )
            case let .moveFailed(reason): reason
            }
        }
    }

    /// Moves a plist from the agents folder to the disabled folder. Returns the new location.
    @discardableResult
    public func disable(plistAt url: URL) throws -> URL {
        try move(url, from: agentsDirectory, to: disabledDirectory)
    }

    /// Moves a plist from the disabled folder back to the agents folder. Returns the new location.
    @discardableResult
    public func enable(plistAt url: URL) throws -> URL {
        try move(url, from: disabledDirectory, to: agentsDirectory)
    }

    private func move(_ url: URL, from source: URL, to destinationFolder: URL) throws -> URL {
        let file = url.standardizedFileURL
        let name = file.lastPathComponent
        guard file.pathExtension == "plist", file.deletingLastPathComponent().path == source.standardizedFileURL.path else {
            throw ToggleError.notInFolder(name)
        }
        let manager = FileManager.default
        let destination = destinationFolder.appendingPathComponent(name)
        guard !manager.fileExists(atPath: destination.path) else {
            throw ToggleError.alreadyExists(name)
        }
        do {
            if !manager.fileExists(atPath: destinationFolder.path) {
                try manager.createDirectory(at: destinationFolder, withIntermediateDirectories: false)
            }
            try manager.moveItem(at: file, to: destination)
        } catch {
            Self.log.error("Couldn't move \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw ToggleError.moveFailed(error.localizedDescription)
        }
        Self.log.info("Moved \(name, privacy: .public) to \(destinationFolder.lastPathComponent, privacy: .public)")
        return destination
    }
}

extension UserLaunchAgentToggle: StartupItemToggling {
    public func disable(_ item: StartupItem) async throws {
        guard item.canDisable, let path = item.plistPath else {
            throw ToggleError.notInFolder(item.name)
        }
        try disable(plistAt: URL(fileURLWithPath: path))
    }

    public func enable(_ item: StartupItem) async throws {
        guard item.canEnable, let path = item.plistPath else {
            throw ToggleError.notInFolder(item.name)
        }
        try enable(plistAt: URL(fileURLWithPath: path))
    }
}
