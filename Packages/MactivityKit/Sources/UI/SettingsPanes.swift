import Core
import Projects
import Storage
import SwiftUI

// Settings panes for the helper and privacy (spec 4.5).

struct HelperSettings: View {
    let controls: AppControls

    @State private var status: HelperStatus = .off

    var body: some View {
        Form {
            Section {
                Toggle(
                    String(localized: "Use the helper", bundle: .strings),
                    isOn: Binding(get: { status == .on || status == .needsApproval }, set: { wanted in
                        status = controls.setHelper(wanted)
                    })
                )
                .disabled(status == .needsSignedBuild)
                LabeledContent(String(
                    localized: "Status",
                    bundle: .strings,
                    comment: "Heading: the current state of the helper"
                )) {
                    Text(statusText).foregroundStyle(.secondary)
                }
                if status == .needsApproval {
                    Button(String(localized: "Login Items Settings…", bundle: .strings)) { controls.openLoginItemsSettings() }
                }
            } header: {
                Text("Privileged helper", bundle: .strings)
            } footer: {
                Text(
                    """
                    Without it, Mactivity reads your own processes and shows the rest of the system as one macOS row. \
                    The helper reads every process, including system ones. It's read-only: it can't stop, change, \
                    or send anything, and it quits 10 seconds after Mactivity does.
                    """,
                    bundle: .strings
                )
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { status = controls.helperStatus() }
        // Back from approving it in System Settings → Login Items: show the new state now (D-197).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = controls.helperStatus()
        }
    }

    private var statusText: String {
        switch status {
        case .needsSignedBuild: String(localized: "Needs a signed release build", bundle: .strings)
        case .off: String(
                localized: "helper.status.off",
                defaultValue: "Off",
                bundle: .strings,
                comment: "Helper status: the privileged helper is turned off"
            )
        case .needsApproval: String(localized: "Waiting for your approval in System Settings → Login Items", bundle: .strings)
        case .on: String(
                localized: "helper.status.on",
                defaultValue: "On",
                bundle: .strings,
                comment: "Helper status: the privileged helper is turned on"
            )
        }
    }
}

struct PrivacySettings: View {
    let controls: AppControls
    @State private var bluetooth: AccessoryBatteryAccess = .unavailable
    @State private var fullDiskAccess: FullDiskAccessStatus = .unknown
    @AppStorage(ReverseDNS.allowLookupsKey) private var allowsHostNameLookups = false
    @AppStorage(PreferenceKey.checksVulnerabilities) private var checksVulnerabilities = false

    var body: some View {
        Form {
            // Full Disk Access (D-119): what Storage's map and cleanups need, in one place.
            Section {
                LabeledContent(String(localized: "Full Disk Access", bundle: .strings)) {
                    if fullDiskAccess == .granted {
                        Text("On", bundle: .strings, comment: "Full Disk Access is on").foregroundStyle(.secondary)
                    } else {
                        Button(String(localized: "Open Privacy & Security…", bundle: .strings)) {
                            if let url = VolumeInfo.fullDiskAccessSettingsURL {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            } footer: {
                Text(
                    """
                    Lets Storage map every folder and find Messages attachments, device backups, Mail downloads and \
                    what's in the Trash. Mactivity only reads sizes and dates, and moves something to the Trash only \
                    when you ask.
                    """,
                    bundle: .strings
                )
                .foregroundStyle(.secondary)
            }
            if bluetooth != .unavailable {
                Section {
                    LabeledContent(String(localized: "AirPods and Bluetooth batteries", bundle: .strings)) {
                        switch bluetooth {
                        case .notAsked:
                            Button(String(localized: "Allow Bluetooth…", bundle: .strings)) {
                                Task { bluetooth = await controls.requestAccessoryBatteryAccess() }
                            }
                        case .allowed:
                            Text("Allowed", bundle: .strings, comment: "Bluetooth access is allowed").foregroundStyle(.secondary)
                        case .denied:
                            Button(String(localized: "Open Privacy Settings…", bundle: .strings)) { BluetoothPrivacy.open() }
                        case .unavailable:
                            EmptyView()
                        }
                    }
                } header: {
                    Text("On this Mac", bundle: .strings)
                } footer: {
                    Text("Mactivity only reads battery levels. It doesn't connect to or change your accessories.", bundle: .strings)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                // What it sends, under its name.
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    Text("Update check", bundle: .strings)
                    Text("At most once a day. Sends the app version.", bundle: .strings)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                }
                if let privacy = Links.privacy {
                    Link(String(localized: "Privacy details on mactivity.app", bundle: .strings), destination: privacy)
                }
            } header: {
                Text("On its own, Mactivity talks to the network for exactly one thing", bundle: .strings)
            } footer: {
                Text(
                    """
                    No analytics, no crash reports, no accounts. Your history stays on this Mac. \
                    The check is off until this build is set up for it.
                    """,
                    bundle: .strings
                )
                .foregroundStyle(.secondary)
            }
            Section {
                Toggle(String(localized: "Look up host names in Get Info", bundle: .strings), isOn: $allowsHostNameLookups)
            } footer: {
                Text(
                    """
                    Off by default. When on, Get Info and Connections show a Look Up Name button. \
                    Each click sends that one address to your DNS server to ask for its name, like any \
                    web request does. Nothing is looked up on its own.
                    """,
                    bundle: .strings
                )
                .foregroundStyle(.secondary)
            }
            // Outdated Software's vulnerability check (D-252).
            Section {
                Toggle(
                    String(localized: "Check Homebrew packages for known vulnerabilities", bundle: .strings),
                    isOn: $checksVulnerabilities
                )
            } footer: {
                Text(
                    """
                    Off by default. When on, Mactivity asks Homebrew to check once a day: Homebrew sends each \
                    installed package's name, source address and version to OSV.dev, Google's open vulnerability \
                    database. Nothing else is sent, and Mactivity itself connects to nothing. Without it, Checkup \
                    still says what's past its end of life.
                    """,
                    bundle: .strings
                )
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            bluetooth = controls.accessoryBatteryAccess()
            fullDiskAccess = VolumeInfo.fullDiskAccess()
        }
        // Back from System Settings: show the new state without reopening Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fullDiskAccess = VolumeInfo.fullDiskAccess()
        }
    }
}

/// System Settings → Privacy & Security → Bluetooth.
enum BluetoothPrivacy {
    static func open() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
            NSWorkspace.shared.open(url)
        }
    }
}
