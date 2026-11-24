import Core
import Projects
import SwiftUI

/// The Network tab: this process's connections and the ports it listens on.
struct InspectorNetwork: View {
    let details: ProcessDetails
    let names: HostNameLookup

    @AppStorage(ReverseDNS.allowLookupsKey) private var allowsLookups = false

    var body: some View {
        if !details.isReadable {
            UnreadableNotice(details: details, what: .sockets)
        } else {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                SectionTitle(title: String(localized: "Connections", bundle: .strings), detail: InspectorText.sockets(connections.count))
                Table(connections) {
                    TableColumn(Text("Remote", bundle: .strings, comment: "Column: the far end of a connection")) { socket in
                        RemoteCell(address: socket.remoteAddress, endpoint: socket.remoteEndpoint ?? "–", names: names)
                    }
                    .width(min: InspectorLayout.endpointColumnMinimum, ideal: InspectorLayout.endpointColumnIdeal)
                    TableColumn(Text("Protocol", bundle: .strings)) { socket in
                        Text(socket.transport.title + (socket.isIPv6 ? "6" : ""))
                    }
                    .width(InspectorLayout.protocolColumn)
                    TableColumn(Text(
                        "State",
                        bundle: .strings,
                        comment: "Table column or detail label: a connection, container or startup item's state"
                    )) { socket in
                        Text(socket.state?.title ?? "–")
                            .foregroundStyle(socket.state == .established || socket.state == nil ? .primary : .secondary)
                    }
                    .width(InspectorLayout.stateColumn)
                    TableColumn(Text("Local", bundle: .strings, comment: "Column: this Mac's end of a connection")) { socket in
                        Text(socket.localEndpoint)
                            .font(Tokens.Typography.code)
                            .foregroundStyle(.secondary)
                    }
                    if allowsLookups {
                        TableColumn(Text(verbatim: "")) { socket in
                            if let address = socket.remoteAddress {
                                LookUpButton(address: address, names: names)
                            }
                        }
                        .width(InspectorLayout.lookupColumn)
                    }
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .overlay {
                    if connections.isEmpty {
                        Text("No open connections", bundle: .strings)
                            .foregroundStyle(.secondary)
                    }
                }
                SectionTitle(
                    title: String(localized: "Listening", bundle: .strings, comment: "Section: ports this process accepts connections on"),
                    detail: InspectorText.ports(listening.count)
                )
                Table(listening) {
                    TableColumn(Text("Address", bundle: .strings)) { socket in
                        Text(socket.localEndpoint)
                            .font(Tokens.Typography.code)
                    }
                    TableColumn(Text("Protocol", bundle: .strings)) { socket in
                        Text(socket.transport.title + (socket.isIPv6 ? "6" : ""))
                    }
                    .width(InspectorLayout.protocolColumn)
                    TableColumn(Text("Reachable from", bundle: .strings)) { socket in
                        Text(Self.reach(socket))
                            .foregroundStyle(.secondary)
                    }
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .frame(maxHeight: InspectorLayout.listeningTableMaxHeight)
                .overlay {
                    if listening.isEmpty {
                        Text("Not listening on any port", bundle: .strings)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding([.horizontal, .bottom], Tokens.Spacing.m)
        }
    }

    private var connections: [SocketEntry] {
        details.connectedSockets
    }

    /// TCP listeners, plus UDP sockets bound to a port with no remote end.
    private var listening: [SocketEntry] {
        details.sockets
            .filter { $0.isListening || ($0.transport == .udp && !$0.hasRemote && $0.localPort != 0) }
            .sorted { ($0.localPort, $0.transport.rawValue) < ($1.localPort, $1.transport.rawValue) }
    }

    static func reach(_ socket: SocketEntry) -> String {
        guard let address = socket.localAddress else {
            return String(localized: "Every network", bundle: .strings, comment: "Listening socket reachable from any network")
        }
        return address == "::1" || address.hasPrefix("127.")
            ? String(localized: "This Mac only", bundle: .strings)
            : String(localized: "Networks on \(address)", bundle: .strings, comment: "The argument is an IP address")
    }
}

struct SectionTitle: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xs) {
            Text(title)
                .font(Tokens.Typography.cardTitle)
            Text(detail)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// An endpoint, with the host name under it once the user has looked it up.
struct RemoteCell: View {
    let address: String?
    let endpoint: String
    let names: HostNameLookup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(endpoint)
                .font(Tokens.Typography.code)
                .textSelection(.enabled)
            if let address, let name = names.names[address] {
                Text(name)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// "Look up name": one `getnameinfo` for one address, only when the flag allows it.
struct LookUpButton: View {
    let address: String
    let names: HostNameLookup

    var body: some View {
        if names.names[address] != nil {
            EmptyView()
        } else if names.inFlight.contains(address) {
            ProgressView()
                .controlSize(.small)
        } else if names.unnamed.contains(address) {
            Text("No name", bundle: .strings, comment: "Reverse DNS found no host name")
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
        } else {
            Button(String(localized: "Look Up Name", bundle: .strings)) {
                Task { await names.lookUp(address) }
            }
            .controlSize(.small)
            .help(Text("Asks your DNS server for this address's name. That request leaves your Mac.", bundle: .strings))
        }
    }
}
