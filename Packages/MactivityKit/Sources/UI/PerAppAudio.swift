import AppKit
import Core
import Observation
import SwiftUI

/// Per-app audio state shared by the Volume tab and the menu bar window: one row per app (settings key), the
/// output devices, and whether Mactivity needs permission. Refreshed only while a view showing it is visible.
@MainActor
@Observable
final class PerAppAudioModel {
    /// One app's audio: every process with the same settings key, shown and changed together.
    struct Row: Identifiable, Equatable {
        let key: String
        let pids: [Int32]
        /// The first process's client. Settings are per app, so every process reports the same ones.
        var client: AudioClient

        var id: String {
            key
        }
    }

    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")

    private(set) var rows: [Row] = []
    private(set) var devices: [AudioOutputDevice] = []
    /// A change failed, or remembered settings couldn't be applied: Mactivity can't hear the app.
    private(set) var needsPermission = false
    /// The last change failed for another reason (the app stopped playing, the device went away).
    private(set) var failureMessage: String?
    private var source: any AudioSource = NoAudioSource()

    init() {}

    /// Groups clients by settings key, in pid order.
    nonisolated static func rows(from clients: [AudioClient]) -> [Row] {
        var rows: [Row] = []
        var index: [String: Int] = [:]
        for client in clients.sorted(by: { $0.pid < $1.pid }) {
            if let existing = index[client.settingsKey] {
                rows[existing] = Row(key: client.settingsKey, pids: rows[existing].pids + [client.pid], client: rows[existing].client)
            } else {
                index[client.settingsKey] = rows.count
                rows.append(Row(key: client.settingsKey, pids: [client.pid], client: client))
            }
        }
        return rows
    }

    /// The app a client belongs to: the snapshot's attribution of its pid, else an app with its bundle ID,
    /// else a name from its settings key.
    static func identity(for client: AudioClient, in snapshot: Snapshot?) -> AppIdentity {
        if let snapshot {
            if let appID = snapshot.processes.first(where: { $0.pid == client.pid })?.app,
               let app = snapshot.apps.first(where: { $0.app.id == appID })?.app {
                return app
            }
            // macOS's own processes aren't in `processes` while their row is collapsed (D-086).
            if snapshot.systemPIDs.contains(client.pid) {
                return snapshot.apps.first(where: { $0.app.kind == .system })?.app ?? .system
            }
            if let app = snapshot.apps.first(where: { $0.app.id == client.app || $0.app.bundleID == client.app })?.app {
                return app
            }
        }
        let name = client.settingsKey.hasPrefix("/")
            ? URL(fileURLWithPath: client.settingsKey).lastPathComponent
            : client.app.hasPrefix("other:") ? "PID \(client.pid)" : client.app
        return AppIdentity(id: client.app, name: name, bundleID: nil, iconKey: "", kind: .other)
    }

    /// Refreshes every `interval` until cancelled. `source` is read each time: simulated data swaps it.
    func poll(every interval: Duration = .seconds(2), source: @MainActor () -> any AudioSource) async {
        while !Task.isCancelled {
            await refresh(source())
            try? await Task.sleep(for: interval)
        }
    }

    func refresh(_ source: any AudioSource) async {
        self.source = source
        let clients = await (try? source.clients()) ?? []
        devices = await (try? source.outputDevices()) ?? []
        rows = Self.rows(from: clients)
        if rows.contains(where: \.client.needsPermission) {
            needsPermission = true
        }
    }

    /// Moving the level unmutes, as the source does.
    func setVolume(_ volume: Double, for row: Row) {
        apply(to: row, {
            $0.volume = volume
            $0.isMuted = false
        }, { try await $0.setVolume(volume, for: $1) })
    }

    func setMuted(_ muted: Bool, for row: Row) {
        apply(to: row, { $0.isMuted = muted }, { try await $0.setMuted(muted, for: $1) })
    }

    func setOutputDevice(_ uid: String?, for row: Row) {
        apply(to: row, { $0.outputDeviceUID = uid }, { try await $0.setOutputDevice(uid: uid, for: $1) })
    }

    func reset(_ row: Row) {
        apply(to: row, { $0 = .untouched }, { try await $0.resetSettings(for: $1) })
    }

    /// Shows the change right away, then asks the source, which applies it to every process of the app. A failure
    /// puts the row back as the source reports it.
    private func apply(
        to row: Row,
        _ edit: (inout AudioAppSetting) -> Void,
        _ change: @escaping (any AudioSource, Int32) async throws -> Void
    ) {
        if let index = rows.firstIndex(where: { $0.key == row.key }) {
            let current = rows[index].client
            var setting = current.setting
            edit(&setting)
            rows[index].client = AudioClient(
                pid: current.pid, app: current.app, volume: setting.volume, isMuted: setting.isMuted,
                outputDeviceUID: setting.outputDeviceUID, settingsKey: current.settingsKey
            )
        }
        let source = source
        let pid = row.client.pid
        Task {
            do {
                try await change(source, pid)
                needsPermission = false
                failureMessage = nil
            } catch {
                // Only a permission failure asks for permission; anything else says what happened.
                if let failure = error as? AudioChangeFailure, !failure.needsPermission {
                    failureMessage = failure.message
                } else {
                    needsPermission = true
                    failureMessage = nil
                }
                await refresh(source)
            }
        }
    }
}

/// Stands in until the first refresh.
private struct NoAudioSource: AudioSource {
    func clients() async throws -> [AudioClient] {
        []
    }

    func setVolume(_: Double, for _: Int32) async throws {}
    func setMuted(_: Bool, for _: Int32) async throws {}
    func setOutputDevice(uid _: String?, for _: Int32) async throws {}
    func resetSettings(for _: Int32) async throws {}
    func outputDevices() async throws -> [AudioOutputDevice] {
        []
    }

    func setEnabled(_: Bool) async {}
}

/// One app's audio controls: icon, name, mute, level, output device, reset. `compact` stacks them on two lines
/// for the menu bar window.
struct AudioAppRow: View {
    let row: PerAppAudioModel.Row
    let identity: AppIdentity
    let devices: [AudioOutputDevice]
    let model: PerAppAudioModel
    var compact = false

    private var client: AudioClient {
        row.client
    }

    var body: some View {
        if compact {
            compactRow
        } else {
            // One line when it fits; the menu bar window's two-line row in a narrow main window
            // (D-175: one line widened the minimum window to 784 pt).
            ViewThatFits(in: .horizontal) {
                wideRow
                compactRow
            }
        }
    }

    private var compactRow: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
            HStack(spacing: Tokens.Spacing.xs) {
                AppIconView(identity)
                name
                    .layoutPriority(1)
                Spacer(minLength: 0)
                devicePicker
                    .controlSize(.small)
                    .frame(maxWidth: Tokens.Layout.audioDevicePickerCompactWidth, alignment: .trailing)
                resetButton
            }
            HStack(spacing: Tokens.Spacing.xs) {
                muteToggle
                slider
                level
            }
        }
    }

    private var wideRow: some View {
        HStack(spacing: Tokens.Spacing.s) {
            AppIconView(identity)
            name
                .frame(width: Tokens.Layout.headlineCardWidth / 2, alignment: .leading)
            muteToggle
            slider
            level
            // A menu keeps its own width: trailing, so every row's chevron lines up.
            devicePicker
                .frame(width: Tokens.Layout.audioDevicePickerWidth, alignment: .trailing)
            resetButton
        }
    }

    private var name: some View {
        Text(identity.name)
            .lineLimit(1)
            .help(row.pids.count > 1 ? Text("\(identity.name) (\(row.pids.count) processes)", bundle: .strings) : Text(identity.name))
    }

    private var muteToggle: some View {
        Toggle(isOn: Binding(get: { client.isMuted }, set: { model.setMuted($0, for: row) })) {
            Label {
                client.isMuted ? Text("Unmute", bundle: .strings) : Text("Mute", bundle: .strings)
            } icon: {
                // One width for both symbols, so the slider doesn't shift when the app is muted.
                Image(systemName: client.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: Tokens.IconSize.row)
            }
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .help(muteName)
        // VoiceOver says whose sound, not just "Mute".
        .accessibilityLabel(muteName)
    }

    private var muteName: Text {
        client.isMuted ? Text("Unmute \(identity.name)", bundle: .strings) : Text("Mute \(identity.name)", bundle: .strings)
    }

    private var slider: some View {
        Slider(value: Binding(get: { client.volume }, set: { model.setVolume($0, for: row) }), in: 0 ... 1) {
            Text("Volume", bundle: .strings)
        }
        .labelsHidden()
        .accessibilityValue(client.isMuted ? Self.muted : Formatters.percent(client.volume * 100))
    }

    private var level: some View {
        Text(client.isMuted ? Self.muted : Formatters.percent(client.volume * 100))
            .monospacedDigit()
            .foregroundStyle(client.isMuted ? .secondary : .primary)
            .frame(width: Tokens.Spacing.xl * 1.5, alignment: .trailing)
    }

    private static let muted = String(localized: "Muted", bundle: .strings, comment: "An app's audio is muted")

    private var chosenIsMissing: Bool {
        guard let uid = client.outputDeviceUID else {
            return false
        }
        return !devices.contains { $0.uid == uid }
    }

    private var devicePicker: some View {
        Picker(String(localized: "Output", bundle: .strings, comment: "Audio output device"), selection: Binding(
            get: { client.outputDeviceUID ?? "" },
            set: { model.setOutputDevice($0.isEmpty ? nil : $0, for: row) }
        )) {
            Text("System default", bundle: .strings, comment: "The system's default audio output").tag("")
            Divider()
            ForEach(devices) { device in
                Text(device.name).tag(device.uid)
            }
            if chosenIsMissing, let uid = client.outputDeviceUID {
                Text("Disconnected device", bundle: .strings).tag(uid)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .help(chosenIsMissing
            ? Text("That device isn't connected. \(identity.name) plays on the system default until it's back.", bundle: .strings)
            : Text("Where \(identity.name) plays", bundle: .strings))
    }

    private var resetButton: some View {
        Button {
            model.reset(row)
        } label: {
            Label(
                String(localized: "Reset", bundle: .strings, comment: "Reset an app's audio settings"),
                systemImage: "arrow.counterclockwise"
            )
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(client.setting.isUntouched)
        .help(Text("Back to 100%, unmuted, on the system default, and forget \(identity.name)", bundle: .strings))
    }
}

/// "Mactivity can't hear this app" with a link to the privacy pane.
struct AudioPermissionNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text(
                "Mactivity needs permission to listen to an app's audio before it can change it. Until then, apps play untouched.",
                bundle: .strings
            )
            .fixedSize(horizontal: false, vertical: true)
            Button(String(localized: "Open Privacy Settings…", bundle: .strings)) {
                if let url = PerAppAudioModel.privacySettingsURL {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

/// The menu bar window's per-app volume card: at most `limit` apps, the rest in the Volume tab.
struct CompactVolumeSection: View {
    let model: PerAppAudioModel
    let metrics: LiveMetrics
    var limit = 4

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            CardHeader(
                title: String(localized: "Apps playing audio", bundle: .strings),
                symbol: SidebarItem.volume.symbol, status: nil, tint: SidebarItem.volume.tint
            )
            ForEach(model.rows.prefix(limit)) { row in
                AudioAppRow(
                    row: row, identity: PerAppAudioModel.identity(for: row.client, in: metrics.snapshot),
                    devices: model.devices, model: model, compact: true
                )
            }
            if model.rows.count > limit {
                Text("\(model.rows.count - limit) more in the Sound tab", bundle: .strings)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
            if model.needsPermission {
                AudioPermissionNote()
                    .font(Tokens.Typography.secondary)
            } else if let message = model.failureMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }
}
