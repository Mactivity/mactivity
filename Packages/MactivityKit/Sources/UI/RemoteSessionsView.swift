import Core
import Observation
import SwiftUI

/// Projects → SSH's state (D-280): sessions every 10 seconds while the view shows.
@MainActor
@Observable
final class RemoteSessionsModel {
    private let source: any RemoteSessionSource
    private(set) var sessions: [RemoteSession] = []
    private(set) var loaded = false

    init(source: any RemoteSessionSource) {
        self.source = source
    }

    func load() async {
        sessions = await source.sessions()
        loaded = true
    }
}

/// Projects → SSH (D-280): each ssh running on this Mac, where it went, how long it's been open
/// and what it forwards.
struct RemoteSessionsView: View {
    let model: RemoteSessionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.gridGutter) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text(summary)
                    .font(Tokens.Typography.cardTitle)
                    .monospacedDigit()
                Text(
                    """
                    From each ssh's arguments and its listening ports. A forward set in ~/.ssh/config shows only as the port it \
                    listens on: where it goes can't be seen, and a remote one can't be seen at all.
                    """,
                    bundle: .strings
                )
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
            if !model.loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.sessions.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No SSH sessions open", bundle: .strings), systemImage: "terminal")
                } description: {
                    Text(
                        "SSH sessions and tunnels open from this Mac show here while they run, with the ports they forward.",
                        bundle: .strings
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
                    .clipShape(Tokens.Shapes.card)
                    .fittedTable(TableFit.height(rows: model.sessions.reduce(0) { $0 + Self.rowHeight($1) }))
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

    /// Forwards take a line each, up to `shownForwards`.
    private static func rowHeight(_ session: RemoteSession) -> CGFloat {
        max(TableFit.twoLineRow, CGFloat(min(RemoteSessionText.lines(session).count, shownForwards + 1)) * 18 + 10)
    }

    private static let shownForwards = 3

    private var table: some View {
        Table(model.sessions) {
            TableColumn(Text("Host", bundle: .strings, comment: "SSH sessions column: where it's connected to")) { session in
                VStack(alignment: .leading, spacing: Tokens.Spacing.lineGap) {
                    Text(RemoteSessionText.host(session))
                        .font(Tokens.Typography.rowTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(RemoteSessionText.kind(session))
                        .help(RemoteSessionText.kind(session))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .width(min: 110, ideal: 140)
            TableColumn(Text("Open", bundle: .strings, comment: "SSH sessions column: how long it's been open")) { session in
                Text(session.startedAt.map { Formatters.duration(.seconds(max(0, Date().timeIntervalSince($0)))) } ?? "–")
                    .monospacedDigit()
            }
            .width(56)
            .alignment(.numeric)
            TableColumn(Text("Forwards", bundle: .strings, comment: "SSH sessions column: the ports it forwards")) { session in
                forwards(session)
            }
            .width(min: 180, ideal: 220)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    @ViewBuilder
    private func forwards(_ session: RemoteSession) -> some View {
        let lines = RemoteSessionText.lines(session)
        if lines.isEmpty {
            Text(verbatim: "–").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines.prefix(Self.shownForwards), id: \.self) { line in
                    Text(line)
                        .font(Tokens.Typography.codeSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if lines.count > Self.shownForwards {
                    Text(
                        "and \(lines.count - Self.shownForwards) more",
                        bundle: .strings,
                        comment: "After a list of dev servers"
                    )
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                }
            }
            .help(lines.joined(separator: "\n"))
        }
    }

    private var summary: String {
        guard model.loaded, !model.sessions.isEmpty else {
            return String(localized: "SSH sessions", bundle: .strings)
        }
        let forwards = model.sessions.reduce(0) { $0 + $1.forwards.count }
        return String(
            localized: "Sessions: \(model.sessions.count), forwards: \(forwards)",
            bundle: .strings,
            comment: "SSH sessions summary: how many sessions, how many forwards"
        )
    }
}

/// SSH sessions' words.
enum RemoteSessionText {
    static func host(_ session: RemoteSession) -> String {
        guard let host = session.host else {
            return String(localized: "Host not shown", bundle: .strings, comment: "SSH session whose host couldn't be read")
        }
        guard let port = session.port else {
            return host
        }
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// "Tunnel · via bastion", "Shell", "Running a command · from git".
    static func kind(_ session: RemoteSession) -> String {
        var parts: [String] = []
        switch session.kind {
        case .shell: parts.append(String(localized: "Shell", bundle: .strings, comment: "SSH session: a shell on the far side"))
        case .tunnel: parts.append(String(localized: "Tunnel", bundle: .strings, comment: "SSH session: only for its forwards"))
        case .command: parts.append(String(
                localized: "Running a command",
                bundle: .strings,
                comment: "SSH session: a remote command, never shown"
            ))
        case .shared: parts.append(String(
                localized: "Shared connection",
                bundle: .strings,
                comment: "SSH session: a ControlMaster connection"
            ))
        case .proxy: parts.append(String(
                localized: "Proxy for another connection",
                bundle: .strings,
                comment: "SSH session started with -W"
            ))
        }
        if let jump = session.jump {
            parts.append(String(localized: "via \(jump)", bundle: .strings, comment: "SSH session: the jump host it goes through"))
        }
        if let startedBy = session.startedBy {
            parts.append(String(
                localized: "from \(startedBy)",
                bundle: .strings,
                comment: "SSH session: the program that started it, e.g. from git"
            ))
        }
        return parts.joined(separator: " · ")
    }

    /// A line per forward, then what couldn't be read.
    static func lines(_ session: RemoteSession) -> [String] {
        var lines = session.forwards.map(line)
        if session.hasTunnelDevice {
            lines.append(String(localized: "Network tunnel device", bundle: .strings, comment: "SSH session started with -w"))
        }
        if session.unreadableForwards > 0 {
            lines.append(String(
                localized: "Forwards it couldn't read: \(session.unreadableForwards)",
                bundle: .strings,
                comment: "SSH session: forwards in its arguments that couldn't be understood"
            ))
        }
        return lines
    }

    /// ":15432 → db.internal:5432", "far side :9000 → localhost:3000", ":1080 SOCKS proxy",
    /// ":8443 → set elsewhere".
    static func line(_ forward: SSHForward) -> String {
        let listen = listenText(forward)
        let target = targetText(forward)
        var text: String = switch forward.kind {
        case .dynamic:
            String(
                localized: "\(listen) SOCKS proxy",
                bundle: .strings,
                comment: "SSH forward: a port on this Mac that's a SOCKS proxy"
            )
        case .remote:
            if target.isEmpty {
                String(
                    localized: "far side \(listen) SOCKS proxy",
                    bundle: .strings,
                    comment: "SSH forward: a port on the far side that's a SOCKS proxy"
                )
            } else {
                String(
                    localized: "far side \(listen) → \(target)",
                    bundle: .strings,
                    comment: "SSH forward: a port on the far side, and where it reaches"
                )
            }
        case .local:
            forward.isFromSocketOnly
                ? String(
                    localized: "\(listen) → set elsewhere",
                    bundle: .strings,
                    comment: "SSH forward seen only as a listening port: where it goes isn't in the arguments"
                )
                : "\(listen) → \(target)"
        }
        if forward.isListening == false {
            text += " " + String(localized: "(not listening)", bundle: .strings, comment: "SSH forward in the arguments with no port open")
        } else if forward.isOpenToNetwork {
            text += " " + String(
                localized: "(open to the network)",
                bundle: .strings,
                comment: "SSH forward that listens on more than this Mac"
            )
        }
        return text
    }

    private static func targetText(_ forward: SSHForward) -> String {
        if let socket = forward.targetSocket {
            return socket
        }
        guard let host = forward.targetHost, let port = forward.targetPort else {
            return ""
        }
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    private static func listenText(_ forward: SSHForward) -> String {
        if let socket = forward.listenSocket {
            return socket
        }
        let port = forward.listenPort.map { ":\($0)" } ?? ""
        guard let bind = forward.bindAddress else {
            return port
        }
        return (bind.contains(":") ? "[\(bind)]" : bind) + port
    }
}
