import Foundation

/// The privileged helper's whole interface (spec 6.9): one read-only method. There is nothing
/// to kill, write, or configure through it.
@objc(MactivityHelperXPC)
public protocol MactivityHelperXPC {
    /// JSON-encoded `[ProcessReading]` for every process, complete (the helper runs as root).
    func sample(withReply reply: @escaping @Sendable (Data?) -> Void)
    /// The helper's build, so the app can tell when the installed helper is stale.
    func version(withReply reply: @escaping @Sendable (String) -> Void)
}

public enum HelperIdentity {
    public static let machServiceName = "app.mactivity.helper"
    public static let plistName = "app.mactivity.helper.plist"
    public static let appBundleID = "app.mactivity.Mactivity"
    public static let helperBundleID = "app.mactivity.helper"

    /// A code-signing requirement pinned to a team: the identifier, Apple-issued, and the
    /// team's OU. Nil without a team ID, in which case neither side connects (spec 6.9:
    /// "Code-signing requirements pinned on both sides").
    public static func requirement(identifier: String, teamID: String?) -> String? {
        guard let teamID, teamID.count == 10, teamID.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return nil
        }
        return "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}
