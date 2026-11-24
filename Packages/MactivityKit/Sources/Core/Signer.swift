import Foundation

/// Who made a running program, from its code signature (1.5, D-232). Read as signed, not
/// re-verified: a check of the whole program on disk would cost seconds each.
public enum Signer: Hashable, Sendable, Codable {
    /// macOS's own: a platform binary, or anything in its sealed system folders.
    case apple
    /// From the Mac App Store.
    case appStore
    /// A developer Apple identified (Developer ID), by the name on the certificate.
    case developer(name: String, team: String)
    /// A development build signed with a developer's own certificate (Xcode's Run).
    case development(name: String)
    /// Signed on this Mac without an identity: a local build, or a package manager's (Homebrew).
    case adHoc
    case unsigned
    /// Couldn't be read: the file is gone, or belongs to another user.
    case unknown

    /// Unsigned or ad hoc: nobody's name is on it.
    public var isAnonymous: Bool {
        self == .unsigned || self == .adHoc
    }

    /// From what `SecCodeCopySigningInformation` gives: the platform identifier, the ad hoc
    /// flag, the leaf certificate's common name.
    public static func from(platform: Int?, adHoc: Bool, leaf: String?, team: String?) -> Signer {
        if let platform, platform > 0 {
            return .apple
        }
        if adHoc {
            return .adHoc
        }
        guard let leaf else {
            return .unsigned
        }
        if leaf == "Apple Mac OS Application Signing" {
            return .appStore
        }
        if leaf.hasPrefix("Software Signing") || leaf.hasPrefix("macOS Software Signing") || leaf.hasPrefix("Apple ") && team == nil {
            return .apple
        }
        if let range = leaf.range(of: "Developer ID Application: ") {
            return .developer(name: name(String(leaf[range.upperBound...])), team: team ?? "")
        }
        if let range = leaf.range(of: "Apple Development: ") ?? leaf.range(of: "Mac Developer: ") {
            return .development(name: name(String(leaf[range.upperBound...])))
        }
        return .developer(name: name(leaf), team: team ?? "")
    }

    /// "Google LLC (EQHXZ8M8AV)" → "Google LLC".
    static func name(_ text: String) -> String {
        guard let open = text.lastIndex(of: "("), text.hasSuffix(")") else {
            return text
        }
        return String(text[..<open]).trimmingCharacters(in: .whitespaces)
    }
}
