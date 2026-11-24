import Core
import Projects
import SwiftUI

/// Connections per app (expansion E1): every remote endpoint an app's processes are talking to,
/// aggregated, refreshed every 2 s while on screen. Shows addresses; names only on request, and
/// only when `ReverseDNS.allowLookupsKey` is set in Settings → Privacy (D-051).
public struct AppConnectionsView: View {
    private let appName: String
    private let pids: [Int32]
    private let source: any ProcessDetailsSource

    @State private var connections: [Connection] = []
    @State private var hasLoaded = false
    @State private var names: HostNameLookup
    @AppStorage(ReverseDNS.allowLookupsKey) private var allowsLookups = false

    public init(appName: String, pids: [Int32], source: any ProcessDetailsSource) {
        self.appName = appName
        self.pids = pids
        self.source = source
        _names = State(initialValue: HostNameLookup(source: source))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            SectionTitle(
                title: String(localized: "\(appName) connections", bundle: .strings, comment: "Sheet title: app name"),
                detail: summary
            )
            if hasLoaded, connections.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No connections", bundle: .strings), systemImage: "network.slash")
                } description: {
                    Text("\(appName) isn't connected to anything right now.", bundle: .strings)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
        }
        .padding(Tokens.Spacing.m)
        .frame(idealWidth: InspectorLayout.connectionsIdealSize.width, idealHeight: InspectorLayout.connectionsIdealSize.height)
        .task(id: pids) {
            while !Task.isCancelled {
                let fresh = await source.connections(pids: pids)
                connections = fresh
                hasLoaded = true
                try? await Task.sleep(for: InspectorModel.refreshInterval)
            }
        }
    }

    private var table: some View {
        Table(connections) {
            TableColumn(String(localized: "Remote", bundle: .strings, comment: "Table column: remote endpoint")) { connection in
                HStack(spacing: Tokens.Spacing.xs) {
                    RemoteCell(address: connection.remoteAddress, endpoint: connection.endpoint, names: names)
                    if connection.isLoopback {
                        Text("This Mac", bundle: .strings, comment: "Tag: a loopback connection")
                            .tagStyle()
                    }
                }
            }
            .width(min: InspectorLayout.endpointColumnMinimum, ideal: InspectorLayout.endpointColumnIdeal)
            TableColumn(String(localized: "Protocol", bundle: .strings, comment: "Table column: TCP or UDP")) { connection in
                Text(connection.transport.title)
            }
            .width(InspectorLayout.protocolColumn)
            TableColumn(String(
                localized: "State",
                bundle: .strings,
                comment: "Table column or detail label: a connection, container or startup item's state"
            )) { connection in
                Text(verbatim: connection.state?.title ?? "–")
                    .foregroundStyle(connection.state == .established || connection.state == nil ? .primary : .secondary)
            }
            .width(InspectorLayout.stateColumn)
            TableColumn(String(localized: "Sockets", bundle: .strings, comment: "Table column: socket count")) { connection in
                Text(String(connection.socketCount))
                    .monospacedDigit()
            }
            .width(InspectorLayout.countColumn)
            TableColumn(String(localized: "PIDs", bundle: .strings, comment: "Table column: process IDs")) { connection in
                Text(connection.pids.map(String.init).joined(separator: ", "))
                    .font(Tokens.Typography.code)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(connection.pids.map(String.init).joined(separator: ", "))
            }
            .width(min: InspectorLayout.pidsColumnMinimum)
            if allowsLookups {
                TableColumn("") { connection in
                    LookUpButton(address: connection.remoteAddress, names: names)
                }
                .width(InspectorLayout.lookupColumn)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    /// "7 endpoints on 6 hosts"
    private var summary: String {
        guard hasLoaded else {
            return String(localized: "Looking…", bundle: .strings, comment: "Connections not loaded yet")
        }
        // Each count is its own key, so each gets its own plural.
        let endpoints = String(localized: "\(connections.count) endpoints", bundle: .strings)
        let hosts = String(localized: "\(Set(connections.map(\.remoteAddress)).count) hosts", bundle: .strings)
        return String(
            localized: "\(endpoints) on \(hosts)",
            bundle: .strings,
            comment: "Connections summary: “7 endpoints” on “6 hosts”"
        )
    }
}

#Preview("Safari connections") {
    AppConnectionsView(appName: "Safari", pids: [400, 401, 402, 403], source: SimulatedProcessDetailsSource())
}
