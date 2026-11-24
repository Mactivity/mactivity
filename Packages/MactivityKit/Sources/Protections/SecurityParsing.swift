import Core
import Foundation

/// Reading the security commands' output and Software Update's settings (1.9, D-261). Pure, so
/// each is tested with the text the commands print.
public enum SecurityParsing {
    /// `fdesetup status`: "FileVault is On." / "FileVault is Off."
    public static func fileVault(_ output: String) -> Bool? {
        if output.contains("FileVault is On") {
            return true
        }
        return output.contains("FileVault is Off") ? false : nil
    }

    /// `csrutil status`: "System Integrity Protection status: enabled." A custom configuration
    /// ("enabled (Custom Configuration)") counts as on.
    public static func systemIntegrity(_ output: String) -> Bool? {
        guard let range = output.range(of: "status: ") else {
            return nil
        }
        let rest = output[range.upperBound...]
        if rest.hasPrefix("enabled") {
            return true
        }
        return rest.hasPrefix("disabled") ? false : nil
    }

    /// `spctl --status`: "assessments enabled" / "assessments disabled".
    public static func gatekeeper(_ output: String) -> Bool? {
        if output.contains("assessments enabled") {
            return true
        }
        return output.contains("assessments disabled") ? false : nil
    }

    /// Software Update's settings (`/Library/Preferences/com.apple.SoftwareUpdate.plist`): a
    /// missing key is macOS's default, which is on.
    public static func updates(_ settings: [String: Any]) -> (securityResponses: Bool, macOSUpdates: Bool) {
        func on(_ key: String) -> Bool {
            (settings[key] as? Bool) ?? (settings[key] as? Int).map { $0 != 0 } ?? true
        }
        let checks = on("AutomaticCheckEnabled")
        return (checks && on("CriticalUpdateInstall") && on("ConfigDataInstall"), checks && on("AutomaticallyInstallMacOSUpdates"))
    }

    /// `systemextensionsctl list`: its rows, which look like
    /// `*\t*\tABCDE12345\tcom.example.filter (1.2/34)\tExample Filter\t[activated enabled]`
    /// under a `--- com.apple.system_extension.network_extension` heading.
    public static func systemExtensions(_ output: String) -> [SystemExtensionItem] {
        var category: String?
        var found: [SystemExtensionItem] = []
        for line in output.split(separator: "\n").map(String.init) {
            if line.hasPrefix("--- ") {
                category = line.dropFirst(4).split(separator: ".").last.map(String.init)
                continue
            }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            // The column headings ("enabled active teamID bundleID (version) name [state]") look like a row.
            guard fields.count >= 6, fields[0] != "enabled", let open = fields[3].lastIndex(of: "("), fields[3].hasSuffix(")") else {
                continue
            }
            let identifier = fields[3][..<open].trimmingCharacters(in: .whitespaces)
            let version = fields[3][fields[3].index(after: open)...].dropLast().split(separator: "/").first.map(String.init) ?? ""
            let state = fields[5]
            found.append(SystemExtensionItem(
                kind: .systemExtension, identifier: identifier, name: fields[4].isEmpty ? identifier : fields[4], version: version,
                teamID: fields[2].isEmpty || fields[2] == "-" ? nil : fields[2], category: category,
                isOn: state.contains("activated enabled")
            ))
        }
        return found
    }

    /// `kmutil showloaded --list-only`: the loaded kernel extensions not made by Apple. Each
    /// row ends with `com.example.driver (1.2.3) UUID <dependencies>`.
    public static func kernelExtensions(_ output: String) -> [SystemExtensionItem] {
        output.split(separator: "\n").compactMap { line in
            let words = line.split(separator: " ")
            guard let index = words.firstIndex(where: { $0.hasPrefix("(") && $0.hasSuffix(")") }), index > 0 else {
                return nil
            }
            let identifier = String(words[index - 1])
            guard identifier.contains("."), !identifier.hasPrefix("com.apple.") else {
                return nil
            }
            return SystemExtensionItem(
                kind: .kernelExtension, identifier: identifier, name: identifier, version: String(words[index].dropFirst().dropLast()),
                teamID: nil, category: nil, isOn: true
            )
        }
    }
}
