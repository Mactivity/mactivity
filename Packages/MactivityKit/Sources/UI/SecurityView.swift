import AppKit
import Core
import Storage
import SwiftUI

/// Security (1.9, D-261): who can do what on this Mac. The protections that are on or off, the
/// apps allowed to use the camera, the screen, every file or the keyboard, the extensions that
/// run with the system's privileges, and the ones inside each browser. Read-only: every change
/// is made in System Settings or the browser, and this page links there.
struct SecurityView: View {
    let services: AppServices

    private var model: SecurityModel {
        services.security
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.gridGutter) {
                protections
                ProfilesCard(model: services.profiles)
                UnlocksCard(model: services.unlocks)
                permissions
                systemExtensions
                browsers
            }
            .padding(Tokens.Spacing.l)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task { await model.load() }
    }

    // MARK: Protections

    private var protections: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Protections", bundle: .strings, comment: "Security page: FileVault, Gatekeeper and the rest")
                    .font(Tokens.Typography.cardTitle)
                Spacer()
                Button(String(localized: "Refresh", bundle: .strings)) { Task { await model.load() } }
            }
            if let settings = model.settings {
                Grid(alignment: .leading, horizontalSpacing: Tokens.Spacing.m, verticalSpacing: Tokens.Spacing.xs) {
                    ForEach(SecurityText.settings(settings)) { setting in
                        GridRow {
                            Image(systemName: Self.symbol(setting))
                                .foregroundStyle(Self.color(setting))
                            Text(setting.title)
                            Text(SecurityText.state(setting.isOn))
                                .foregroundStyle(setting.isOn == false && setting
                                    .important ? AnyShapeStyle(Tokens.Colors.strainLabel) : AnyShapeStyle(.secondary))
                            if setting.isOn == false, let url = setting.settingsURL {
                                Button(String(localized: "Open Settings…", bundle: .strings)) { NSWorkspace.shared.open(url) }
                                    .buttonStyle(.link)
                            } else {
                                Color.clear.frame(width: 1, height: 1)
                            }
                        }
                        .help(setting.help)
                        .accessibilityElement(children: .combine)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .cardStyle()
    }

    static func symbol(_ setting: SecurityText.Setting) -> String {
        switch setting.isOn {
        case true?: "checkmark.shield.fill"
        case false?: setting.important ? "exclamationmark.shield.fill" : "shield.slash"
        case nil: "questionmark.circle"
        }
    }

    static func color(_ setting: SecurityText.Setting) -> Color {
        switch setting.isOn {
        case true?: .green
        case false?: setting.important ? Tokens.Colors.strain : .secondary
        case nil: .secondary
        }
    }

    // MARK: Permissions

    private var permissions: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text("What apps are allowed to do", bundle: .strings, comment: "Security page: the privacy permissions")
                .font(Tokens.Typography.cardTitle)
            switch model.permissions {
            case .noAccess?:
                noAccess
            case let .read(found, unreadable)?:
                let groups = SecurityModel.grouped(found, name: SecurityText.name)
                if groups.isEmpty, unreadable.isEmpty {
                    Text("No app has asked for any of these.", bundle: .strings).foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.0) { kind, items in
                    PermissionSection(kind: kind, items: items)
                }
                if !unreadable.isEmpty {
                    unreadableNote(unreadable)
                }
            case nil:
                ProgressView().controlSize(.small)
            }
        }
        .cardStyle()
    }

    /// Without Full Disk Access: why, and each kind's place in System Settings (the public path).
    private var noAccess: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text(
                """
                macOS keeps this list where only apps with Full Disk Access can read it. Turn it on to see here which \
                apps can record your screen, read every file or control your Mac. Mactivity only reads the list.
                """,
                bundle: .strings
            )
            .font(Tokens.Typography.secondary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(String(localized: "Open Full Disk Access Settings…", bundle: .strings)) {
                    if let url = VolumeInfo.fullDiskAccessSettingsURL {
                        NSWorkspace.shared.open(url)
                    }
                }
                settingsMenu(PermissionKind.allCases)
            }
        }
    }

    /// Kinds macOS won't let any other app read (macOS 27, D-263): named, so a short list never
    /// reads as "no app has these", with where to see them instead.
    private func unreadableNote(_ kinds: [PermissionKind]) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text(
                "macOS doesn't let other apps read who can use \(kinds.map(SecurityText.title).formatted(.list(type: .and))).",
                bundle: .strings,
                comment: "Security page: permissions macOS 27 keeps from other apps, e.g. Camera, Automation and Files and Folders"
            )
            .font(Tokens.Typography.secondary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if kinds.contains(.camera) {
                Text("Devices shows which apps actually used the camera and microphone.", bundle: .strings)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
            settingsMenu(kinds)
        }
        .padding(.top, Tokens.Spacing.xxs)
    }

    private func settingsMenu(_ kinds: [PermissionKind]) -> some View {
        Menu(String(localized: "See in System Settings", bundle: .strings)) {
            ForEach(kinds, id: \.self) { kind in
                Button(SecurityText.title(kind)) {
                    if let url = SecurityText.settingsURL(kind) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .fixedSize()
    }

    // MARK: Extensions

    private var systemExtensions: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text("System extensions", bundle: .strings, comment: "Security page: drivers and network filters")
                .font(Tokens.Typography.cardTitle)
            if let items = model.systemExtensions {
                if items.isEmpty {
                    Text("None. Nothing besides macOS runs with the system's own privileges.", bundle: .strings)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
                        Image(systemName: item.kind == .kernelExtension ? "cpu" : "puzzlepiece.extension")
                            .foregroundStyle(.secondary)
                            .frame(width: Tokens.IconSize.row)
                        VStack(alignment: .leading, spacing: Tokens.Spacing.lineGap) {
                            Text(item.name)
                            Text(verbatim: [SecurityText.kind(item), item.identifier, item.version].filter { !$0.isEmpty }
                                .joined(separator: " · "))
                                .font(Tokens.Typography.secondary)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(SecurityText.state(item.isOn)).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .cardStyle()
    }

    private var browsers: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text("Browser extensions", bundle: .strings, comment: "Security page").font(Tokens.Typography.cardTitle)
            if let reading = model.browsers {
                if reading.extensions.isEmpty, reading.blocked.isEmpty {
                    Text("No browser extensions installed.", bundle: .strings).font(Tokens.Typography.secondary).foregroundStyle(.secondary)
                }
                ForEach(Browser.allCases.filter { browser in
                    reading.extensions.contains { $0.browser == browser }
                }, id: \.self) { browser in
                    BrowserSection(browser: browser, items: reading.extensions.filter { $0.browser == browser })
                }
                if !reading.blocked.isEmpty {
                    let names = reading.blocked.map(\.title).formatted(.list(type: .and))
                    Text(
                        "Mactivity needs Full Disk Access to read \(names)'s extensions.",
                        bundle: .strings,
                        comment: "Security page: browsers whose folders macOS protects, e.g. Google Chrome and Microsoft Edge"
                    )
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .cardStyle()
    }
}

/// One permission: its apps, allowed ones first, and where to change it.
private struct PermissionSection: View {
    let kind: PermissionKind
    let items: [AppPermission]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(SecurityText.title(kind)).font(Tokens.Typography.secondary.weight(.semibold))
                    .help(SecurityText.help(kind))
                Spacer()
                Button(String(localized: "Change in System Settings…", bundle: .strings)) {
                    if let url = SecurityText.settingsURL(kind) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(Tokens.Typography.secondary)
            }
            ForEach(items) { item in
                HStack(spacing: Tokens.Spacing.xs) {
                    if item.clientIsPath {
                        Image(systemName: "terminal").frame(width: Tokens.IconSize.row).foregroundStyle(.secondary)
                    } else {
                        AppIconView(SensorText.identity(item.client), size: Tokens.IconSize.row)
                    }
                    Text(SecurityText.name(item)).lineLimit(1)
                    if let target = item.target {
                        Text(verbatim: "→ \(MutedAppsSection.displayName(target))").foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(item.allowed
                        ? String(localized: "Allowed", bundle: .strings, comment: "Security page: a permission granted")
                        : String(localized: "Not allowed", bundle: .strings, comment: "Security page: a permission refused"))
                        .foregroundStyle(item.allowed ? .primary : .secondary)
                }
                .font(Tokens.Typography.secondary)
                .help(item.clientIsPath ? item.client : SecurityText.help(kind))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.top, Tokens.Spacing.xxs)
    }
}

/// One browser's extensions: what each can reach.
private struct BrowserSection: View {
    let browser: Browser
    let items: [BrowserExtension]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            HStack(spacing: Tokens.Spacing.xs) {
                AppIconView(SensorText.identity(browser.bundleID), size: Tokens.IconSize.row)
                Text(verbatim: browser.title).font(Tokens.Typography.secondary.weight(.semibold))
            }
            ForEach(items.sorted { $0.name.lowercased() < $1.name.lowercased() }) { item in
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
                    Text(item.name).lineLimit(1)
                    if item.isOn == false {
                        Text("Off", bundle: .strings, comment: "Security page: a protection is off").foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(SecurityText.reach(item))
                        .foregroundStyle(item.access.contains(.everySite) ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(item.permissions.joined(separator: ", "))
                }
                .font(Tokens.Typography.secondary)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.top, Tokens.Spacing.xxs)
    }
}
