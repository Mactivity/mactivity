import Core
import Observation
import Projects
import SwiftUI

/// Projects → Simulators' state (D-226): devices and what the running ones hold, every 10
/// seconds while the tab shows; folder sizes once, when it first shows.
@MainActor
@Observable
final class DevDevicesModel {
    private let source: any DevDeviceSource
    private(set) var devices: [DevDevice] = []
    private(set) var simulatorAppOpen = true
    private(set) var loaded = false
    @ObservationIgnored private var sizes: [String: UInt64] = [:]
    @ObservationIgnored private var sized = false
    @ObservationIgnored private var previous: (at: Date, cpu: [String: Double])?
    private(set) var leftRunning: Set<String> = []

    init(source: any DevDeviceSource) {
        self.source = source
    }

    /// The list first, without sizes, so the table fills at once; sizes in a second pass the
    /// first time (22 devices take 3 s here), kept for the session.
    func load(now: Date = Date()) async {
        let reading = await source.read(sizes: false)
        apply(reading, now: now)
        if !sized, !reading.devices.isEmpty, !Task.isCancelled {
            sized = true
            let measured = await source.read(sizes: true)
            sizes = Dictionary(
                measured.devices.compactMap { device in device.sizeBytes.map { (device.id, $0) } },
                uniquingKeysWith: { first, _ in first }
            )
            devices = devices.map { device in
                var device = device
                device.sizeBytes = sizes[device.id]
                return device
            }
        }
    }

    private func apply(_ reading: DevDeviceReading, now: Date) {
        var found = reading.devices
        for index in found.indices where found[index].sizeBytes == nil {
            found[index].sizeBytes = sizes[found[index].id]
        }
        let interval = previous.map { now.timeIntervalSince($0.at) } ?? 0
        leftRunning = Set(found.filter { device in
            DevDeviceRules.isLeftRunning(
                device, previousCPU: previous?.cpu[device.id], interval: interval, simulatorAppOpen: reading.simulatorAppOpen, now: now
            )
        }.map(\.id))
        previous = (now, Dictionary(found.map { ($0.id, $0.cpuSeconds) }, uniquingKeysWith: { first, _ in first }))
        devices = found
        simulatorAppOpen = reading.simulatorAppOpen
        loaded = true
    }
}

struct DevDevicesView: View {
    let model: DevDevicesModel
    let services: AppServices
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.gridGutter) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
                Text(summary)
                    .font(Tokens.Typography.cardTitle)
                    .monospacedDigit()
                if !model.leftRunning.isEmpty {
                    Text(
                        "\(model.leftRunning.count) left running",
                        bundle: .strings,
                        comment: "Simulators: how many run with nothing to do, or without the Simulator app"
                    )
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(Tokens.Colors.strainLabel)
                }
                Spacer()
            }
            .cardStyle()
            if !model.loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.devices.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No simulators or emulators", bundle: .strings), systemImage: "iphone")
                } description: {
                    Text(
                        "Xcode's Simulator devices and Android Studio's emulators show here, with what each holds while it runs.",
                        bundle: .strings
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
                    .clipShape(Tokens.Shapes.card)
                    .fittedTable(TableFit.height(twoLineRows: model.devices.count))
                    .layoutPriority(1)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .task {
            while !Task.isCancelled {
                await model.load()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private var table: some View {
        Table(model.devices) {
            TableColumn(Text("Device", bundle: .strings)) { device in
                HStack(spacing: Tokens.Spacing.s) {
                    Image(systemName: Self.symbol(device.platform))
                        .foregroundStyle(.secondary)
                        .frame(width: Tokens.IconSize.row)
                    VStack(alignment: .leading, spacing: Tokens.Spacing.lineGap) {
                        Text(device.name).font(Tokens.Typography.rowTitle)
                        Text(device.runtime ?? device.platform.rawValue)
                            .font(Tokens.Typography.secondary)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 180, ideal: 220)
            TableColumn(Text("State", bundle: .strings, comment: "Simulators column: running, or when last used")) { device in
                Text(state(device))
                    .foregroundStyle(model.leftRunning
                        .contains(device.id) ? AnyShapeStyle(Tokens.Colors.strainLabel) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
            }
            .width(min: 130, ideal: 180)
            TableColumn(Text("Memory", bundle: .strings)) { device in
                Text(device.isRunning && device.memoryBytes > 0 ? Formatters.memory(device.memoryBytes) : "–").monospacedDigit()
            }
            .width(70)
            .alignment(.numeric)
            TableColumn(Text("On disk", bundle: .strings, comment: "Simulators column: the device folder's size")) { device in
                Text(device.sizeBytes.map { Formatters.bytes($0) } ?? "–").monospacedDigit()
            }
            .width(70)
            .alignment(.numeric)
            TableColumn(Text(verbatim: "")) { device in
                action(device)
            }
            .width(min: 120, ideal: 160)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    /// Shut down (a command to copy) for a running Simulator device, Quit for a running
    /// emulator, and for a device unused in three months the command that deletes it.
    @ViewBuilder private func action(_ device: DevDevice) -> some View {
        if device.isRunning, device.platform == .android {
            if let process = emulatorProcess(device) {
                Button(String(localized: "Quit…", bundle: .strings, comment: "Quits it, after a confirmation")) {
                    services.requestQuit(process, mode: .quit)
                }
                .controlSize(.small)
            }
        } else if device.isRunning, let command = device.shutdownCommand {
            copyButton(
                command,
                title: String(localized: "Copy Shutdown Command", bundle: .strings, comment: "Simulators: copies xcrun simctl shutdown …")
            )
        } else if let command = device.deleteCommand, Self.isUnused(device) {
            copyButton(
                command,
                title: String(localized: "Copy Delete Command", bundle: .strings, comment: "Simulators: copies xcrun simctl delete …")
            )
        }
    }

    /// The command is too long to show beside a UDID; the button copies it, its help shows it.
    private func copyButton(_ command: String, title: String) -> some View {
        Button {
            InspectorText.copy(command)
            copied = command
            Task {
                try? await Task.sleep(for: .seconds(2))
                if copied == command {
                    copied = nil
                }
            }
        } label: {
            Label(title, systemImage: copied == command ? "checkmark" : "doc.on.doc")
        }
        .controlSize(.small)
        .help(Text(verbatim: command))
    }

    private func emulatorProcess(_ device: DevDevice) -> ProcessSample? {
        guard let pid = device.pids.first else {
            return nil
        }
        return services.metrics.snapshot?.processes.first { $0.pid == pid }
    }

    /// Used once, not in three months, and holding 100 MB or more. A device never booted is one
    /// of the defaults Xcode creates for each runtime, about 18 MB each: not worth a command.
    static func isUnused(_ device: DevDevice, now: Date = Date()) -> Bool {
        guard let used = device.lastUsed, let size = device.sizeBytes else {
            return false
        }
        return now.timeIntervalSince(used) >= 90 * 86400 && size >= 100_000_000
    }

    private func state(_ device: DevDevice) -> String {
        if device.isRunning {
            guard let startedAt = device.startedAt else {
                return String(localized: "Running", bundle: .strings, comment: "Homebrew service or device state: running now")
            }
            let up = Formatters.duration(.seconds(max(0, Date().timeIntervalSince(startedAt))))
            if model.leftRunning.contains(device.id) {
                return device.platform != .android && !model.simulatorAppOpen
                    ? String(localized: "Running \(up) without the Simulator app", bundle: .strings, comment: "Simulator device state")
                    : String(
                        localized: "Running \(up), idle",
                        bundle: .strings,
                        comment: "Simulator or emulator state: up a while, doing nothing"
                    )
            }
            return String(
                localized: "Running \(up)",
                bundle: .strings,
                comment: "Homebrew service: how long it has run, e.g. Running 19d 4h"
            )
        }
        guard let used = device.lastUsed else {
            return String(localized: "Never used", bundle: .strings, comment: "Simulator device state")
        }
        return String(
            localized: "Used \(used.formatted(.relative(presentation: .named)))",
            bundle: .strings,
            comment: "Simulator device state: e.g. Used 4 days ago"
        )
    }

    private var summary: String {
        let running = model.devices.filter(\.isRunning)
        guard model.loaded, !model.devices.isEmpty else {
            return String(localized: "Simulators and emulators", bundle: .strings)
        }
        let disk = Formatters.bytes(model.devices.reduce(0) { $0 &+ ($1.sizeBytes ?? 0) })
        guard !running.isEmpty else {
            return String(
                localized: "\(model.devices.count) devices, none running, \(disk) on disk",
                bundle: .strings,
                comment: "Simulators summary: how many, space they take"
            )
        }
        let memory = Formatters.memory(running.reduce(0) { $0 &+ $1.memoryBytes })
        return String(
            localized: "\(running.count) of \(model.devices.count) devices running, \(memory), \(disk) on disk",
            bundle: .strings,
            comment: "Simulators summary: running, all, memory they hold, space they take"
        )
    }

    static func symbol(_ platform: DevDevice.Platform) -> String {
        switch platform {
        case .iOS: "iphone"
        case .watchOS: "applewatch"
        case .tvOS: "appletv"
        case .visionOS: "visionpro"
        case .android: "smartphone"
        }
    }
}
