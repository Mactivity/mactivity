import AppKit
import Storage
import SwiftUI

/// First-launch sheet (spec 10.2): what Mactivity does, what it sends, and how to find it in
/// the menu bar. One prominent button.
struct OnboardingView: View {
    let services: AppServices
    let done: () -> Void
    @State private var bluetooth: AccessoryBatteryAccess = .unavailable
    @State private var fullDiskAccess: FullDiskAccessStatus = .granted
    /// Ticked: a year of history means running from login, or it has gaps (D-129). Shown only
    /// when it's off; Get Started applies it.
    @State private var opensAtLogin = true
    @State private var alreadyOpensAtLogin = true

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
            HStack(spacing: Tokens.Spacing.m) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: Tokens.IconSize.shareCard, height: Tokens.IconSize.shareCard)
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    Text("Welcome to Mactivity", bundle: .strings)
                        .font(Tokens.Typography.sheetTitle)
                    Text("What your Mac is doing, one line at a time.", bundle: .strings)
                        .foregroundStyle(.secondary)
                }
            }
            // The features scroll when a long language makes them taller than the cap (D-175).
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                    point(
                        "square.stack.3d.up",
                        String(localized: "Apps, not processes", bundle: .strings),
                        String(localized: "Helpers and background processes add up under the app that started them.", bundle: .strings)
                    )
                    point(
                        "clock.arrow.circlepath",
                        String(localized: "A year of history", bundle: .strings),
                        String(localized: "So \"why was my Mac slow at 2 pm\" has an answer.", bundle: .strings)
                    )
                    point(
                        "bell.badge",
                        String(
                            localized: "It tells you", bundle: .strings,
                            comment: "Onboarding feature heading: Mactivity warns you (with a notification) when an app misbehaves"
                        ),
                        String(
                            localized: """
                            Find out the moment an app pins the processor, swells in memory, or floods the disk or network. \
                            Get Started asks macOS to let Mactivity notify you.
                            """,
                            bundle: .strings
                        )
                    )
                    point(
                        "lock",
                        String(localized: "It all stays here", bundle: .strings),
                        String(
                            localized: "On its own, Mactivity makes one network request: checking for updates.",
                            bundle: .strings
                        )
                    )
                    if bluetooth == .notAsked {
                        point(
                            "airpods",
                            String(localized: "AirPods batteries", bundle: .strings),
                            String(
                                localized: """
                                Mactivity can show your Bluetooth accessories' batteries. \
                                macOS asks for Bluetooth access first.
                                """,
                                bundle: .strings
                            )
                        )
                    }
                    // Optional, and only when it's off (D-121): Storage's cleanups need it.
                    if fullDiskAccess != .granted {
                        point(
                            "internaldrive",
                            String(localized: "Free up space, if you like", bundle: .strings),
                            String(
                                localized: """
                                Storage finds old Messages attachments, device backups and caches you can move to the Trash. \
                                That needs Full Disk Access; Settings → Privacy shows how.
                                """,
                                bundle: .strings
                            )
                        )
                    }
                    point(
                        "menubar.rectangle",
                        String(localized: "Look up at your menu bar", bundle: .strings),
                        String(localized: "If you don't see Mactivity there, allow it in System Settings → Menu Bar.", bundle: .strings)
                    )
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            if !alreadyOpensAtLogin {
                Toggle(isOn: $opensAtLogin) {
                    Text("Open Mactivity at login, so its history has no gaps", bundle: .strings)
                }
                .toggleStyle(.checkbox)
            }
            HStack {
                // It opens macOS's own settings, not Mactivity's Menu Bar pane: the name says so (D-196).
                Button(String(
                    localized: "Menu Bar in System Settings…",
                    bundle: .strings,
                    comment: "Onboarding: opens macOS's menu bar settings"
                )) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                if bluetooth == .notAsked {
                    Button(String(localized: "Allow Bluetooth…", bundle: .strings)) {
                        Task { bluetooth = await services.controls.requestAccessoryBatteryAccess() }
                    }
                }
                Spacer()
                Button(String(localized: "Get Started", bundle: .strings)) {
                    if opensAtLogin, !alreadyOpensAtLogin {
                        _ = services.controls.setLaunchAtLogin(true)
                    }
                    Task {
                        _ = await services.requestNotificationAuthorization()
                        await services.refreshNotificationPermission()
                        done()
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Tokens.Spacing.xl)
        .frame(width: Tokens.Layout.onboardingWidth)
        .frame(maxHeight: Tokens.Layout.onboardingMaxHeight)
        .onAppear {
            bluetooth = services.controls.accessoryBatteryAccess()
            fullDiskAccess = VolumeInfo.fullDiskAccess()
            alreadyOpensAtLogin = services.controls.isLaunchAtLoginEnabled()
        }
    }

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.s) {
            Image(systemName: symbol)
                .font(Tokens.Typography.featureSymbol)
                .foregroundStyle(Tokens.Colors.accent)
                .frame(width: Tokens.IconSize.card)
            VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                Text(title)
                    .font(Tokens.Typography.cardTitle)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
