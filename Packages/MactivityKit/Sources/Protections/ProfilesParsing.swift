import Core
import Foundation

/// Reading the `profiles` command's output (D-287). Pure, tested with what it prints.
public enum ProfilesParsing {
    /// `profiles show -type configuration`:
    ///
    ///     name[1] attribute: profileIdentifier: com.example.thing
    ///     name[1] payload count = 1
    ///     name[1]            payload[1] type			= com.apple.wifi.managed
    ///     There are 1 user configuration profiles installed for 'name'
    ///
    /// Nil when it says nothing a profile listing says: a refusal, or wording that moved.
    public static func profiles(_ output: String) -> [ConfigurationProfile]? {
        var parts: [Int: Part] = [:]
        var understood = output.lowercased().contains("configuration profiles")
        for line in output.split(whereSeparator: \.isNewline) {
            guard let (index, rest) = indexed(String(line)) else {
                continue
            }
            let trimmed = rest.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("attribute: ") {
                let attribute = trimmed.dropFirst("attribute: ".count)
                guard let separator = attribute.range(of: ": ") else {
                    continue
                }
                understood = true
                let key = String(attribute[..<separator.lowerBound])
                parts[index, default: Part()].attributes[key] = cleaned(attribute[separator.upperBound...])
            } else if let (payload, key, value) = payloadField(trimmed) {
                parts[index, default: Part()].payloads[payload, default: [:]][key] = value
            }
        }
        guard understood else {
            return nil
        }
        return parts.keys.sorted().compactMap { parts[$0]?.profile }
    }

    /// "payload[1] type			= com.apple.wifi.managed" as (1, "type", "com.apple.wifi.managed").
    private static func payloadField(_ text: String) -> (Int, String, String?)? {
        guard text.hasPrefix("payload["), let close = text.firstIndex(of: "]"),
              let index = Int(text[text.index(text.startIndex, offsetBy: "payload[".count) ..< close])
        else {
            return nil
        }
        let field = text[text.index(after: close)...]
        guard let equals = field.firstIndex(of: "=") else {
            return nil
        }
        return (index, field[..<equals].trimmingCharacters(in: .whitespaces), cleaned(field[field.index(after: equals)...]))
    }

    /// `profiles status -type enrollment`: "Enrolled via DEP: No", "MDM enrollment: Yes (User Approved)".
    public static func enrollment(_ output: String) -> ManagementEnrollment? {
        let automated = answer(output, "Enrolled via DEP:")
        let managed = answer(output, "MDM enrollment:")
        return automated == nil && managed == nil ? nil : ManagementEnrollment(automated: automated, managed: managed)
    }

    private static func answer(_ output: String, _ label: String) -> Bool? {
        guard let range = output.range(of: label) else {
            return nil
        }
        let rest = output[range.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
        if rest.hasPrefix("yes") {
            return true
        }
        return rest.hasPrefix("no") ? false : nil
    }

    /// One profile's lines so far.
    private struct Part {
        var attributes: [String: String] = [:]
        var payloads: [Int: [String: String]] = [:]

        var profile: ConfigurationProfile? {
            guard let identifier = attributes["profileIdentifier"] else {
                return nil
            }
            let payloadList = payloads.keys.sorted().compactMap { key -> ProfilePayload? in
                guard let fields = payloads[key], let type = fields["type"] else {
                    return nil
                }
                return ProfilePayload(type: type, name: fields["name"])
            }
            return ConfigurationProfile(
                identifier: identifier, name: attributes["name"], description: attributes["configurationDescription"],
                organization: attributes["organization"], installed: attributes["installationDate"].flatMap(date),
                installedByManagement: flag(attributes["installedByMDM"]), removalDisallowed: flag(attributes["removalDisallowed"]),
                isInternal: flag(attributes["internaldata"]), payloads: payloadList
            )
        }

        private func flag(_ value: String?) -> Bool {
            value?.uppercased() == "TRUE"
        }

        private func date(_ value: String) -> Date? {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            return formatter.date(from: value)
        }
    }

    /// "name[2] rest" as (2, "rest"): the first bracket holding a number, as a user's name can
    /// hold spaces.
    private static func indexed(_ line: String) -> (Int, String)? {
        guard let open = line.firstIndex(of: "["), let close = line[open...].firstIndex(of: "]"),
              let index = Int(line[line.index(after: open) ..< close])
        else {
            return nil
        }
        return (index, String(line[line.index(after: close)...]))
    }

    /// `(null)` is what it prints for a missing value.
    private static func cleaned(_ text: some StringProtocol) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == "(null)" ? nil : trimmed
    }
}
