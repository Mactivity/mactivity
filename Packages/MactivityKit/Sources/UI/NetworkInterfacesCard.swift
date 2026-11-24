import Core
import Observation
import SwiftUI

/// Every interface, read every 5 s while the list shows (D-264). Not read otherwise.
@MainActor
@Observable
public final class NetworkInterfacesModel {
    public private(set) var interfaces: [NetworkInterfaceInfo] = []
    @ObservationIgnored private var source: any NetworkInterfacesSource
    @ObservationIgnored private var loop: Task<Void, Never>?

    public init(source: any NetworkInterfacesSource) {
        self.source = source
    }

    public func replaceSource(_ source: any NetworkInterfacesSource) {
        self.source = source
        interfaces = []
        if loop != nil {
            start()
        }
    }

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func refresh() async {
        let source = source
        let found = await source.interfaces()
        // A source swapped while this read ran has started its own.
        if !Task.isCancelled {
            interfaces = found
        }
    }

    /// The groups on the card. Pure.
    nonisolated static func groups(_ all: [NetworkInterfaceInfo])
        -> (inUse: [NetworkInterfaceInfo], system: [NetworkInterfaceInfo], idle: [NetworkInterfaceInfo]) {
        let connected = all.filter { $0.status == .connected }
        return (
            connected.filter { $0.isPrimary || $0.isHardware },
            connected.filter { !$0.isPrimary && !$0.isHardware },
            all.filter { $0.status != .connected }
        )
    }
}

/// `ifconfig`, native (D-264): what each connection is, in plain words, and every fact about it.
struct NetworkInterfacesCard: View {
    let model: NetworkInterfacesModel
    /// Which are open; the connection in use opens on its own the first time.
    @State private var open: Set<String> = []
    @State private var openedPrimary = false

    var body: some View {
        let groups = NetworkInterfacesModel.groups(model.interfaces)
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text("Network interfaces", bundle: .strings)
                .font(Tokens.Typography.cardTitle)
                .help(String(
                    localized: "What the ifconfig command shows, in plain words. Read from this Mac; nothing is sent anywhere.",
                    bundle: .strings
                ))
            ForEach(groups.inUse) { row($0) }
            group(
                String(localized: "Used by macOS", bundle: .strings, comment: "Network interfaces macOS runs for itself"),
                groups.system,
                id: "system"
            )
            group(String(localized: "Not connected", bundle: .strings), groups.idle, id: "idle")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.interfaces.first { $0.isPrimary }?.name, initial: true) { _, primary in
            if let primary, !openedPrimary {
                openedPrimary = true
                open.insert(primary)
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [NetworkInterfaceInfo], id: String) -> some View {
        if !items.isEmpty {
            DisclosureGroup(isExpanded: binding(id)) {
                ForEach(items) { row($0) }
                    .padding(.leading, Tokens.Spacing.xs)
            } label: {
                Text(verbatim: "\(title) (\(items.count.formatted()))")
                    .font(Tokens.Typography.secondary.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ item: NetworkInterfaceInfo) -> some View {
        DisclosureGroup(isExpanded: binding(item.id)) {
            details(item)
        } label: {
            HStack(spacing: Tokens.Spacing.xs) {
                Image(systemName: NetworkInterfaceText.symbol(item.kind))
                    .foregroundStyle(.secondary)
                    .frame(width: Tokens.IconSize.row)
                Text(NetworkInterfaceText.title(item)).lineLimit(1)
                Text(verbatim: item.name).font(Tokens.Typography.codeSecondary).foregroundStyle(.secondary)
                Spacer(minLength: Tokens.Spacing.s)
                if let address = item.mainAddress {
                    Text(verbatim: address.value)
                        .font(Tokens.Typography.codeSecondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(NetworkInterfaceText.status(item.status))
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(item.status == .connected ? .primary : .secondary)
            }
            .help(NetworkInterfaceText.purpose(item.kind))
            .accessibilityElement(children: .combine)
        }
    }

    /// As many columns as fit. Filling the width keeps the facts at the card's left edge; left
    /// alone, SwiftUI centers them under the row.
    private func details(_ item: NetworkInterfaceInfo) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text(NetworkInterfaceText.purpose(item.kind))
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                columns(item, count: 3)
                columns(item, count: 2)
                columns(item, count: 1)
            }
            if let abilities = NetworkInterfaceText.abilities(item) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Tokens.Spacing.s) {
                    detail(abilities)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Tokens.Spacing.xs)
        .padding(.leading, Tokens.Spacing.m)
    }

    /// Room for a label and a full IPv4 address with its note.
    private static let columnWidth: CGFloat = 270

    /// Each column's ideal width is fixed, so a long DNS list can't talk `ViewThatFits` out of a
    /// layout that would fit once it wraps.
    private func columns(_ item: NetworkInterfaceInfo, count: Int) -> some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.l) {
            ForEach(NetworkInterfaceText.columns(item, count: count), id: \.first?.id) { sections in
                column(sections)
                    .frame(minWidth: Self.columnWidth, idealWidth: Self.columnWidth, maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    /// One grid per column, so its labels line up even across two groups.
    private func column(_ sections: [NetworkInterfaceText.Section]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Tokens.Spacing.s, verticalSpacing: Tokens.Spacing.xxs) {
            ForEach(sections) { section in
                GridRow {
                    Text(section.title)
                        .font(Tokens.Typography.secondary.weight(.semibold))
                        .padding(.top, section.id == sections.first?.id ? 0 : Tokens.Spacing.s)
                        .gridCellColumns(2)
                }
                ForEach(section.rows) { detail($0) }
            }
        }
    }

    private func detail(_ row: NetworkInterfaceText.Row) -> some View {
        GridRow {
            Text(row.label)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .help(row.help)
            // The note beside the value when there's room, under it when not.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xs) {
                    value(row)
                    note(row)
                }
                VStack(alignment: .leading, spacing: 0) {
                    value(row)
                    note(row)
                }
            }
            // Takes the column's remaining width, so a value wraps only when it has to.
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(row.help)
        }
        .accessibilityElement(children: .combine)
    }

    private func value(_ row: NetworkInterfaceText.Row) -> some View {
        Text(verbatim: row.value)
            .font(row.isCode ? Tokens.Typography.codeSecondary : Tokens.Typography.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func note(_ row: NetworkInterfaceText.Row) -> some View {
        if let note = row.note {
            Text(verbatim: note).font(Tokens.Typography.secondary).foregroundStyle(.secondary)
        }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { open.contains(id) },
            set: { isOpen in
                if isOpen {
                    open.insert(id)
                } else {
                    open.remove(id)
                }
            }
        )
    }
}
