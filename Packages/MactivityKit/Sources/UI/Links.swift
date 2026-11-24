import Export
import Foundation

/// Mactivity's web pages on mactivity.app.
public enum Links {
    public static let website = URL(string: "https://mactivity.app")
    public static let privacy = URL(string: "https://mactivity.app/privacy")
}

/// This build's version as people see it, and the feedback email draft (D-073).
public struct BuildInfo: Sendable {
    public let version: String
    public let build: String
    /// "beta" for tester builds; empty for releases.
    public let channel: String
    public let feedbackEmail: String?

    public init(version: String, build: String, channel: String, feedbackEmail: String?) {
        self.version = version
        self.build = build
        self.channel = channel
        self.feedbackEmail = feedbackEmail
    }

    /// From the app's Info.plist.
    public static func main(_ bundle: Bundle = .main) -> BuildInfo {
        let info = { (key: String) in (bundle.object(forInfoDictionaryKey: key) as? String) ?? "" }
        let email = info("MactivityFeedbackEmail")
        return BuildInfo(
            version: info("CFBundleShortVersionString"),
            build: info("CFBundleVersion"),
            channel: info("MactivityReleaseChannel"),
            feedbackEmail: email.isEmpty ? nil : email
        )
    }

    /// What people see, in About and Settings: "1.0.1", or "0.9.0 beta" for a tester build.
    /// The version goes up with every release, so the build number adds nothing there.
    public var displayVersion: String {
        channel.isEmpty ? version : "\(version) \(channel)"
    }

    /// With the build number, for feedback emails: "1.0.1 (11)" pins down the exact build.
    public var supportVersion: String {
        "\(displayVersion) (\(build))"
    }

    /// A `mailto:` draft with what identifies this Mac and build at the bottom, for the person to
    /// read, edit and send from their own mail app. Mactivity sends nothing itself (CLAUDE.md rule 3).
    public func feedbackURL(details: [String]) -> URL? {
        guard let feedbackEmail else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = feedbackEmail
        let footer = (["Mactivity \(supportVersion)"] + details).joined(separator: "\n")
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Mactivity \(displayVersion) feedback"),
            URLQueryItem(name: "body", value: "\n\n—\n\(footer)\n"),
        ]
        return components.url
    }
}

/// The lines at the bottom of a feedback draft (D-179): what a bug report needs to be
/// reproduced, read on this Mac and shown to the person before they send anything.
public enum FeedbackDraft {
    @MainActor
    public static func url(_ info: BuildInfo = .main(), services: AppServices? = nil) -> URL? {
        info.feedbackURL(details: details(simulated: services?.metrics.isSimulated ?? false))
    }

    /// "macOS 27.0.1", "MacBook Pro (Mac16,7) · Apple M5 Pro · 48 GB", "Language: English (en_US)".
    public static func details(simulated: Bool, bundle: Bundle = .main) -> [String] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let memory = Measurement(
            value: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
            unit: UnitInformationStorage.gigabytes
        )
        let memoryText = "\(Int(memory.value.rounded())) GB"
        let language = bundle.preferredLocalizations.first ?? "en"
        var lines = [
            "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "\(MacModel.name()) (\(hardwareModel())) · \(MacModel.chip()) · \(memoryText)",
            "Language: \(language) (\(Locale.current.identifier))",
        ]
        if simulated {
            lines.append("Simulated data is on")
        }
        return lines
    }

    /// `hw.model`, e.g. "Mac16,7".
    static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else {
            return "unknown"
        }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(bytes: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? "unknown"
    }
}
