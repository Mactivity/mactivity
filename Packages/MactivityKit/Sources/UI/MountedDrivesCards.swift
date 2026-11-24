import AppKit
import Core
import Observation
import SwiftUI

/// External and network drives for the Disk tab (D-284, D-285). Read when a card shows and when
/// macOS says something mounted or unmounted; there's no timer unless an NFS share is mounted and
/// the card is showing, for its call counters.
@MainActor
@Observable
public final class MountedDrivesModel {
    private(set) var external: [ExternalDrive] = []
    private(set) var network: [NetworkDrive] = []
    /// Calls a second, NFS shares together; nil until there are two readings to compare.
    private(set) var nfsRate: (reads: Double, writes: Double)?
    @ObservationIgnored private var source: any MountedDriveSource
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var lastCounters: (counters: NFSCounters, at: Date)?

    public init(source: any MountedDriveSource) {
        self.source = source
    }

    /// Already loaded: render tests.
    init(
        source: any MountedDriveSource, external: [ExternalDrive], network: [NetworkDrive],
        nfsRate: (reads: Double, writes: Double)? = nil
    ) {
        self.source = source
        self.external = external
        self.network = network
        self.nfsRate = nfsRate
    }

    /// `watchesMounts`: also read when macOS says something mounted, so a drive plugged in while
    /// the window's closed is remembered. A notification costs nothing until it fires.
    public func replaceSource(_ source: any MountedDriveSource, watchesMounts: Bool) {
        self.source = source
        external = []
        network = []
        nfsRate = nil
        lastCounters = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        guard watchesMounts else {
            return
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            })
        }
    }

    func refresh() async {
        await refreshExternal()
        await refreshNetwork()
    }

    func refreshExternal() async {
        let source = source
        external = await source.externalDrives()
    }

    func refreshNetwork() async {
        let source = source
        network = await source.networkDrives()
    }

    func forget(_ drive: ExternalDrive) async {
        await source.forgetExternalDrive(id: drive.id)
        external.removeAll { $0.id == drive.id }
    }

    /// While the network card shows and an NFS share is mounted: its counters every 10 seconds.
    func watchNFS() async {
        while !Task.isCancelled {
            if network.contains(where: { $0.kind == .nfs }), let counters = await source.nfsCounters() {
                let now = Date()
                if let last = lastCounters {
                    nfsRate = NFSCounters.rate(from: last.counters, to: counters, seconds: now.timeIntervalSince(last.at))
                }
                lastCounters = (counters, now)
            } else {
                nfsRate = nil
                lastCounters = nil
            }
            try? await Task.sleep(for: .seconds(10))
        }
    }
}

/// "Space and health of the drives you plug in, remembered between visits."
struct ExternalDrivesCard: View {
    let model: MountedDrivesModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text("External drives", bundle: .strings)
                .font(Tokens.Typography.cardTitle)
            if model.external.isEmpty {
                Text(
                    "None seen yet. Drives you plug in are listed here with their space and health, and stay listed after you unplug them.",
                    bundle: .strings
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.external) { drive in
                row(drive)
            }
        }
        .cardStyle()
        .task { await model.refreshExternal() }
    }

    private func row(_ drive: ExternalDrive) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
            Image(systemName: "externaldrive")
                .foregroundStyle(.secondary)
                .frame(width: Tokens.IconSize.row)
            VStack(alignment: .leading, spacing: 2) {
                Text(drive.name).lineLimit(1)
                Text(Self.details(drive))
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Tokens.Spacing.s)
            VStack(alignment: .trailing, spacing: 2) {
                Text(DriveSpaceText.line(drive.space))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(Self.healthTitle(drive))
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(Self.healthTint(drive.health))
                    .help(Text(Self.healthHelp(drive)))
            }
        }
        .contextMenu {
            if !drive.isConnected {
                Button(String(localized: "Forget This Drive", bundle: .strings)) {
                    Task { await model.forget(drive) }
                }
            }
        }
    }

    /// "Plugged in · Samsung PSSD T7 · USB · APFS", or "Last seen Oct 3 · …".
    nonisolated static func details(_ drive: ExternalDrive) -> String {
        let when = drive.lastSeen.formatted(date: .abbreviated, time: .omitted)
        let state = drive.isConnected
            ? String(localized: "Plugged in", bundle: .strings, comment: "External drive: connected now")
            : String(localized: "Last seen \(when)", bundle: .strings, comment: "External drive, not plugged in: when it last was")
        return ([state] + [drive.model, drive.connection, drive.format].compactMap(\.self)).joined(separator: " · ")
    }

    nonisolated static func healthTitle(_ drive: ExternalDrive) -> String {
        switch drive.health {
        case .good:
            return String(localized: "Good", bundle: .strings, comment: "Drive health")
        case .wearing:
            return String(localized: "Wearing out", bundle: .strings, comment: "Drive health")
        case .failing:
            return String(localized: "Reports a problem", bundle: .strings, comment: "Drive health")
        case .notReported:
            return String(localized: "Health not reported", bundle: .strings, comment: "An external drive that doesn't report its health")
        }
    }

    nonisolated static func healthHelp(_ drive: ExternalDrive) -> String {
        switch drive.health {
        case .good, .wearing:
            if let used = drive.percentUsed {
                let percent = Formatters.percent(Double(used))
                return String(localized: "The drive's own report: \(percent) of its rated life used.", bundle: .strings)
            }
            return String(localized: "The drive's own SMART status, when it was last plugged in.", bundle: .strings)
        case .failing:
            return String(localized: "The drive itself says something's wrong. Back it up now.", bundle: .strings)
        case .notReported:
            return String(
                localized: "This connection doesn't pass on the drive's own report, which is usual for USB enclosures.",
                bundle: .strings
            )
        }
    }

    /// For the health words, so "wearing" is the amber that reads on a light card.
    private static func healthTint(_ health: ExternalDrive.Health) -> AnyShapeStyle {
        switch health {
        case .good, .notReported: AnyShapeStyle(.secondary)
        case .wearing: AnyShapeStyle(Tokens.Colors.strainLabel)
        case .failing: AnyShapeStyle(.red)
        }
    }
}

/// "Shared folders and NAS volumes you mount: their space and how busy they are."
struct NetworkDrivesCard: View {
    let model: MountedDrivesModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text("Network drives", bundle: .strings)
                .font(Tokens.Typography.cardTitle)
            if model.network.isEmpty {
                Text("No shared folder or NAS volume is mounted.", bundle: .strings)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.network) { drive in
                row(drive)
            }
            ForEach(Self.notes(model.network, nfsRate: model.nfsRate), id: \.self) { note in
                Text(note)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cardStyle()
        .task {
            await model.refreshNetwork()
            await model.watchNFS()
        }
    }

    private func row(_ drive: NetworkDrive) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .foregroundStyle(.secondary)
                .frame(width: Tokens.IconSize.row)
            VStack(alignment: .leading, spacing: 2) {
                Text(drive.name).lineLimit(1)
                Text(([drive.server, drive.kind.title].compactMap(\.self)).joined(separator: " · "))
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Tokens.Spacing.s)
            switch drive.status {
            case let .responding(space):
                Text(DriveSpaceText.line(space))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            case let .notResponding(lastKnown):
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Not responding", bundle: .strings, comment: "A network drive that doesn't answer")
                        .foregroundStyle(Tokens.Colors.strainLabel)
                    if let lastKnown {
                        Text(DriveSpaceText.lastKnown(lastKnown))
                            .font(Tokens.Typography.secondary)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .help(Text("The share didn't answer within 3 seconds. The server may be off or out of reach.", bundle: .strings))
            }
        }
    }

    /// Pure: what can be said about how busy they are, by kind of share. A sentence per fact:
    /// macOS counts NFS calls for all shares together, and nothing for the others.
    nonisolated static func notes(_ drives: [NetworkDrive], nfsRate: (reads: Double, writes: Double)?) -> [String] {
        var notes: [String] = []
        let kinds = Set(drives.map(\.kind))
        if kinds.contains(.nfs) {
            if let nfsRate {
                let reads = Int(nfsRate.reads.rounded()).formatted()
                let writes = Int(nfsRate.writes.rounded()).formatted()
                notes.append(String(
                    localized: "NFS shares together, calls a second: reads \(reads), writes \(writes). macOS doesn't count them per share.",
                    bundle: .strings
                ))
            } else {
                notes.append(String(
                    localized: "NFS activity shows after a second reading, about 10 seconds. macOS doesn't count it per share.",
                    bundle: .strings
                ))
            }
        }
        let silent = [NetworkDrive.Kind.smb, .afp, .webdav, .other].filter(kinds.contains).map(\.title)
        if !silent.isEmpty {
            let names = silent.formatted(.list(type: .and))
            notes.append(String(
                localized: "How busy they are can't be shown for \(names): macOS doesn't report activity for these shares.",
                bundle: .strings,
                comment: "Network drives: the kinds of share, e.g. SMB and AFP"
            ))
        }
        return notes
    }
}

enum DriveSpaceText {
    /// "812 GB free of 2 TB".
    nonisolated static func line(_ space: DriveSpace) -> String {
        let free = Formatters.bytes(space.availableBytes)
        let total = Formatters.bytes(space.totalBytes)
        return String(localized: "\(free) free of \(total)", bundle: .strings, comment: "A drive's space: free, then its size")
    }

    nonisolated static func lastKnown(_ space: DriveSpace) -> String {
        let free = Formatters.bytes(space.availableBytes)
        let total = Formatters.bytes(space.totalBytes)
        return String(
            localized: "Last known: \(free) free of \(total)",
            bundle: .strings,
            comment: "A drive's space from before it stopped answering"
        )
    }
}
