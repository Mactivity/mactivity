import AppKit
import Core
import Observation
import Projects
import SwiftUI

/// Open to the network's state (D-230): read when the Network tab shows, then every 30 seconds
/// while it does.
@MainActor
@Observable
final class OpenPortsModel {
    private let source: any OpenPortSource
    private(set) var reading: OpenPortsReading?

    init(source: any OpenPortSource) {
        self.source = source
    }

    /// The ports each time; the firewall the first time a visit reads, kept for the rest of it.
    func load(firewall: Bool) async {
        let read = await source.read(firewall: firewall)
        reading = OpenPortsReading(
            ports: read.ports,
            firewallOn: firewall ? read.firewallOn : reading?.firewallOn,
            stealthOn: firewall ? read.stealthOn : reading?.stealthOn
        )
    }
}

/// On the Network tab: what other devices on your network can reach, grouped by process, with
/// what a few of macOS's own are, and the firewall's state.
struct OpenPortsCard: View {
    let model: OpenPortsModel
    let services: AppServices

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
                Text("Open to the network", bundle: .strings, comment: "Network tab card: ports other devices can reach")
                    .font(Tokens.Typography.cardTitle)
                if let reading = model.reading {
                    Text(Self.summary(reading))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let reading = model.reading {
                ForEach(Self.groups(reading.ports), id: \.pid) { group in
                    row(group)
                }
                firewall(reading)
                // Root's listeners need the helper; macOS's sharing services are among them.
                Text(
                    "Your apps only. macOS's own sharing, like Remote Login or Screen Sharing, is in System Settings → General → Sharing.",
                    bundle: .strings
                )
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .task {
            var firstRead = true
            while !Task.isCancelled {
                await model.load(firewall: firstRead)
                firstRead = false
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func row(_ group: (pid: Int32, ports: [OpenPort])) -> some View {
        let first = group.ports[0]
        let app = appIdentity(group.pid)
        let note = group.ports.lazy.compactMap { OpenPortRules.known(processName: first.processName, port: $0.port) }.first
            ?? (isDevServer(group.pid)
                ? String(
                    localized: "A dev server. Start it on 127.0.0.1 to keep it on this Mac.",
                    bundle: .strings,
                    comment: "Open ports: a dev server listening on every interface"
                )
                : nil)
        return HStack(alignment: .top, spacing: Tokens.Spacing.s) {
            if let app {
                AppIconView(app)
            } else {
                Image(systemName: "network").frame(width: Tokens.IconSize.row, height: Tokens.IconSize.row)
            }
            VStack(alignment: .leading, spacing: Tokens.Spacing.lineGap) {
                HStack(spacing: Tokens.Spacing.xs) {
                    Text(app?.name ?? first.processName)
                    if let app, app.name != first.processName {
                        Text(verbatim: first.processName).foregroundStyle(.secondary)
                    }
                }
                if let note {
                    Text(note)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: Tokens.Spacing.lineGap) {
                Text(group.ports.map { ":\($0.port)" }.joined(separator: " "))
                    .font(Tokens.Typography.code)
                Text(Self.place(first.address))
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func firewall(_ reading: OpenPortsReading) -> some View {
        if let on = reading.firewallOn {
            HStack(spacing: Tokens.Spacing.s) {
                Image(systemName: on ? "checkmark.shield" : "shield.slash")
                    .foregroundStyle(on ? AnyShapeStyle(.secondary) : AnyShapeStyle(Tokens.Colors.strain))
                Text(on
                    ? (reading.stealthOn == true
                        ? String(localized: "The macOS firewall is on, in stealth mode.", bundle: .strings)
                        : String(localized: "The macOS firewall is on.", bundle: .strings))
                    : reading.ports.isEmpty
                    ? String(localized: "The macOS firewall is off.", bundle: .strings)
                    : String(
                        localized: "The macOS firewall is off: any of these accept connections from your network.",
                        bundle: .strings
                    ))
                    .font(Tokens.Typography.secondary)
                Spacer()
                Button(String(localized: "Firewall Settings…", bundle: .strings, comment: "Opens System Settings at the firewall")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private func appIdentity(_ pid: Int32) -> AppIdentity? {
        guard let snapshot = services.metrics.snapshot, let process = snapshot.processes.first(where: { $0.pid == pid }) else {
            return nil
        }
        return snapshot.apps.first { $0.id == process.app }?.app
    }

    private func isDevServer(_ pid: Int32) -> Bool {
        services.projects.projects.contains { $0.servers.contains { $0.pid == pid } }
    }

    /// One row per process, its ports together.
    static func groups(_ ports: [OpenPort]) -> [(pid: Int32, ports: [OpenPort])] {
        var order: [Int32] = []
        var byPID: [Int32: [OpenPort]] = [:]
        for port in ports {
            if byPID[port.pid] == nil {
                order.append(port.pid)
            }
            byPID[port.pid, default: []].append(port)
        }
        return order.map { ($0, byPID[$0] ?? []) }
    }

    static func place(_ address: String) -> String {
        address == "*"
            ? String(localized: "every network", bundle: .strings, comment: "Open ports: bound to every interface")
            : String(localized: "on \(address)", bundle: .strings, comment: "Open ports: bound to one address, e.g. on 192.168.1.24")
    }

    static func summary(_ reading: OpenPortsReading) -> String {
        let count = reading.ports.count
        switch count {
        case 0:
            return String(localized: "None of your apps listen beyond this Mac", bundle: .strings, comment: "Open ports: none")
        case 1:
            return String(localized: "1 port other devices can reach", bundle: .strings, comment: "Open ports: one")
        default:
            return String(localized: "\(count) ports other devices can reach", bundle: .strings, comment: "Open ports: how many")
        }
    }
}
