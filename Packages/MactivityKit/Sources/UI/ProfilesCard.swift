import AppKit
import Core
import Observation
import SwiftUI

/// Configuration profiles' state (D-287): read when the card shows. Short commands, not kept.
@MainActor
@Observable
public final class ProfilesModel {
    public private(set) var loaded = false
    public private(set) var reading: ProfilesReading?
    @ObservationIgnored private var source: any ProfilesSource

    public init(source: any ProfilesSource) {
        self.source = source
    }

    public func replaceSource(_ source: any ProfilesSource) {
        self.source = source
        loaded = false
        reading = nil
    }

    func load() async {
        let source = source
        reading = await source.read()
        loaded = true
    }
}

/// On the Security page (D-287): the profiles installed for this person, who put them there and
/// what they change, and what macOS keeps back without root.
struct ProfilesCard: View {
    let model: ProfilesModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text("Configuration profiles", bundle: .strings, comment: "Security page: installed configuration profiles")
                .font(Tokens.Typography.cardTitle)
            if !model.loaded {
                ProgressView().controlSize(.small)
            } else if let reading = model.reading {
                if let line = ProfileText.enrollment(reading.enrollment) {
                    Text(line)
                        .foregroundStyle(reading.enrollment?
                            .managed == true ? AnyShapeStyle(Tokens.Colors.strainLabel) : AnyShapeStyle(.primary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if reading.profiles.isEmpty {
                    secondary(String(localized: "No configuration profiles are installed for your account.", bundle: .strings))
                }
                ForEach(reading.profiles) { profile in
                    ProfileRow(profile: profile)
                }
            } else {
                secondary(String(localized: "macOS's profiles command didn't answer, so Mactivity can't list them here.", bundle: .strings))
            }
            secondary(String(
                localized: """
                macOS lists profiles for the whole Mac only to an administrator, and shows the kind of setting each one touches \
                but not its values. Mactivity doesn't ask to run as an administrator, so System Settings has the full list.
                """,
                bundle: .strings
            ))
            Button(String(localized: "Open Device Management…", bundle: .strings)) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Profiles-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .task { await model.load() }
    }

    private func secondary(_ text: String) -> some View {
        Text(text)
            .font(Tokens.Typography.secondary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ProfileRow: View {
    let profile: ConfigurationProfile

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline) {
                Text(profile.name ?? profile.identifier)
                    .fontWeight(.medium)
                Spacer()
                if let installed = profile.installed {
                    Text(installed.formatted(date: .abbreviated, time: .omitted))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                }
            }
            Text(ProfileText.origin(profile.origin))
                .font(Tokens.Typography.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(ProfileText.changes(profile.payloads))
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help(profile.payloads.map(\.type).joined(separator: "\n"))
            if profile.removalDisallowed {
                Text("You can't remove this one yourself.", bundle: .strings)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
        }
        .help(profile.identifier)
        .accessibilityElement(children: .combine)
    }
}

/// Configuration profiles' words (D-287). Pure.
enum ProfileText {
    static func enrollment(_ enrollment: ManagementEnrollment?) -> String? {
        switch enrollment?.managed {
        case true?:
            String(
                localized: "This Mac is enrolled in device management, so an organization can install profiles and change settings on it.",
                bundle: .strings
            )
        case false?:
            String(localized: "This Mac isn't enrolled in device management.", bundle: .strings)
        case nil:
            nil
        }
    }

    static func origin(_ origin: ConfigurationProfile.Origin) -> String {
        switch origin {
        case .screenTime:
            String(
                localized: """
                macOS wrote this itself for Screen Time, or for an app using Screen Time's controls. No management system put it \
                there.
                """,
                bundle: .strings
            )
        case .macOS:
            String(localized: "macOS wrote this itself. No management system put it there.", bundle: .strings)
        case let .management(organization?):
            String(localized: "Installed by device management, for \(organization).", bundle: .strings)
        case .management(nil):
            String(localized: "Installed by device management. It doesn't name an organization.", bundle: .strings)
        case let .named(organization):
            String(
                localized: "Installed by hand or by an installer. It says it's from \(organization), which anyone can write.",
                bundle: .strings
            )
        case .unnamed:
            String(localized: "Installed by hand or by an installer. It doesn't say who made it.", bundle: .strings)
        }
    }

    static func changes(_ payloads: [ProfilePayload]) -> String {
        guard !payloads.isEmpty else {
            return String(localized: "macOS doesn't say what this one changes.", bundle: .strings)
        }
        var seen: Set<String> = []
        let names = payloads.map { payload(type: $0.type) }.filter { seen.insert($0).inserted }
        return String(
            localized: "What it changes: \(names.formatted(.list(type: .and)))", bundle: .strings,
            comment: "Configuration profiles: the kinds of setting a profile touches"
        )
    }

    /// macOS's name for a kind of setting, in plain words. One this doesn't know keeps macOS's
    /// name, so nothing is ever hidden.
    static func payload(type: String) -> String {
        switch type {
        case "com.apple.familycontrols.contentfilter", "com.apple.webcontent-filter":
            String(localized: "a filter on web content", bundle: .strings)
        case "com.apple.applicationaccess", "com.apple.applicationaccess.new":
            String(localized: "restrictions on what's allowed", bundle: .strings)
        case "com.apple.wifi.managed":
            String(localized: "Wi-Fi networks", bundle: .strings)
        case "com.apple.vpn.managed", "com.apple.vpn.managed.applayer":
            String(localized: "a VPN", bundle: .strings)
        case "com.apple.dnsSettings.managed":
            String(localized: "DNS settings", bundle: .strings)
        case "com.apple.proxy.http.global":
            String(localized: "a web proxy", bundle: .strings)
        case "com.apple.security.root", "com.apple.security.pem", "com.apple.security.pkcs1", "com.apple.security.pkcs12":
            String(localized: "trusted certificates", bundle: .strings)
        case "com.apple.TCC.configuration-profile-policy":
            String(localized: "privacy permissions for apps", bundle: .strings)
        case "com.apple.mail.managed", "com.apple.eas.account":
            String(localized: "email accounts", bundle: .strings)
        case "com.apple.loginwindow", "com.apple.loginitems.managed", "com.apple.servicemanagement":
            String(localized: "what happens at login", bundle: .strings)
        case "com.apple.screensaver", "com.apple.mobiledevice.passwordpolicy":
            String(localized: "password and screen lock rules", bundle: .strings)
        case "com.apple.MCX.FileVault2", "com.apple.security.FDERecoveryKeyEscrow":
            String(localized: "FileVault", bundle: .strings)
        case "com.apple.security.firewall":
            String(localized: "the firewall", bundle: .strings)
        case "com.apple.systempolicy.control", "com.apple.systempolicy.managed":
            String(localized: "Gatekeeper", bundle: .strings)
        case "com.apple.SoftwareUpdate":
            String(localized: "software updates", bundle: .strings)
        case "com.apple.system-extension-policy", "com.apple.syspolicy.kernel-extension-policy":
            String(localized: "which system extensions may run", bundle: .strings)
        case "com.apple.notificationsettings":
            String(localized: "notification settings", bundle: .strings)
        case "com.apple.ManagedClient.preferences":
            String(localized: "app settings", bundle: .strings)
        default:
            type
        }
    }
}
