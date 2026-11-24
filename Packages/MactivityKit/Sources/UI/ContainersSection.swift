import Core
import Docker
import SwiftUI

/// Docker containers in the Projects tab, under the dev-server table (expansion E5): the engine
/// and a count, then a table grouped by compose project with Stop… and Restart….
///
/// Stop… asks `confirmedAction`, whose dialog the host attaches (ProjectsView already does);
/// Restart… asks `model.restartAction`, whose dialog this view attaches. With no engine, the
/// section is one quiet line.
public struct ContainersSection: View {
    private let model: ContainersModel
    private let confirmedAction: ConfirmedAction

    public init(model: ContainersModel, confirmedAction: ConfirmedAction) {
        self.model = model
        self.confirmedAction = confirmedAction
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.gridGutter) {
            if let note = ContainerText.unavailable(model.availability) {
                Label(note, systemImage: ContainerLayout.symbol)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    // In line with the text inside the cards above.
                    .padding(.horizontal, Tokens.Spacing.cardPadding)
            } else if case let .available(engine) = model.availability {
                header(engine)
                let groups = model.groups
                if !groups.isEmpty {
                    table(groups)
                        // Its rows' height when there's room; shorter (it scrolls) in a short window,
                        // so the Projects page never needs more height than the window (D-175).
                        .frame(
                            minHeight: min(ContainerLayout.minTableHeight, ContainerLayout.tableHeight(groups)),
                            maxHeight: ContainerLayout.tableHeight(groups)
                        )
                        .clipShape(Tokens.Shapes.card)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(text: toast)
            }
        }
        .animation(Tokens.Motion.figure, value: model.toast)
        .onAppear { model.appeared() }
        .onDisappear { model.disappeared() }
        .confirmedActionDialog(model.restartAction)
    }

    private func header(_ engine: DockerEngine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
            Label {
                Text(ContainerText.header(engine: engine, running: model.runningCount, stopped: model.stoppedCount))
                    .monospacedDigit()
            } icon: {
                RowSymbol(ContainerLayout.symbol, tint: Tokens.Colors.accent)
            }
            .font(Tokens.Typography.cardTitle)
            Spacer()
            if model.stoppedCount > 0 {
                Toggle(
                    String(localized: "Show Stopped", bundle: .strings, comment: "Shows stopped containers too"),
                    isOn: Binding(get: { model.showsStopped }, set: { model.showsStopped = $0 })
                )
                .toggleStyle(.checkbox)
            }
        }
        .cardStyle()
    }

    private func table(_ groups: [ContainerGrouping.Group]) -> some View {
        Table(of: Container.self) {
            identityColumns
            figureColumns
        } rows: {
            ForEach(groups) { group in
                Section {
                    ForEach(group.containers) { container in
                        TableRow(container)
                    }
                } header: {
                    ContainerGroupHeader(group: group)
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    /// Name and status, image, state, ports.
    @TableColumnBuilder<Container, Never>
    private var identityColumns: some TableColumnContent<Container, Never> {
        TableColumn(Text("Container", bundle: .strings)) { container in
            VStack(alignment: .leading, spacing: Tokens.Spacing.lineGap) {
                Text(container.name)
                    .font(Tokens.Typography.rowTitle)
                    .lineLimit(1)
                Text(container.status)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .width(min: 180, ideal: 240)
        TableColumn(Text("Image", bundle: .strings, comment: "Column: the container's Docker image")) { container in
            Text(container.image)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(container.image)
        }
        .width(min: 110, ideal: 170)
        TableColumn(Text(
            "State",
            bundle: .strings,
            comment: "Table column or detail label: a connection, container or startup item's state"
        )) { container in
            ContainerStateLabel(state: container.state)
                .help(container.status)
        }
        .width(ContainerLayout.stateWidth)
        TableColumn(Text("Ports", bundle: .strings)) { container in
            Text(ContainerText.ports(container.ports))
                .font(Tokens.Typography.code)
                .foregroundStyle(container.ports.isEmpty ? .secondary : .primary)
                .lineLimit(1)
        }
        .width(min: 70, ideal: 110)
    }

    /// CPU, memory, and the actions.
    @TableColumnBuilder<Container, Never>
    private var figureColumns: some TableColumnContent<Container, Never> {
        TableColumn(Text("CPU", bundle: .strings)) { container in
            Text(container.cpuPercent.map { Formatters.percent($0) } ?? "–")
                .monospacedDigit()
                .foregroundStyle(container.cpuPercent == nil ? .secondary : .primary)
        }
        .width(ContainerLayout.figureWidth)
        .alignment(.numeric)
        TableColumn(Text("Memory", bundle: .strings)) { container in
            Text(container.memoryUsedBytes.map { Formatters.memory($0) } ?? "–")
                .monospacedDigit()
                .foregroundStyle(container.memoryUsedBytes == nil ? .secondary : .primary)
                .help(container.memoryLimitBytes.map {
                    String(localized: "Limit \(Formatters.memory($0))", bundle: .strings, comment: "Help tag: the container's memory limit")
                } ?? "")
        }
        .width(ContainerLayout.figureWidth)
        .alignment(.numeric)
        TableColumn(Text(verbatim: "")) { container in
            HStack(spacing: Tokens.Spacing.xs) {
                Button(String(localized: "Restart…", bundle: .strings, comment: "Restarts it, after a confirmation")) {
                    model.restart(container)
                }
                if container.state.isActive {
                    Button(String(localized: "Stop…", bundle: .strings, comment: "Stops it, after a confirmation")) {
                        model.stop(container, through: confirmedAction)
                    }
                }
            }
            .controlSize(.small)
        }
        .width(ContainerLayout.actionsWidth)
    }
}

/// "storefront-web  ~/Developer/storefront-web", or "Other containers".
struct ContainerGroupHeader: View {
    let group: ContainerGrouping.Group

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xs) {
            Text(group.project ?? String(localized: "Other containers", bundle: .strings, comment: "Containers not in a compose project"))
                .font(Tokens.Typography.rowTitle)
            if let directory = group.workingDirectory {
                Text(Formatters.displayPath(directory, home: NSHomeDirectory()))
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

/// A status dot and the state word. Green while running, yellow while paused or restarting,
/// grey otherwise. Never red (spec 10.2).
struct ContainerStateLabel: View {
    let state: Container.State

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        StatusDotLabel(ContainerText.state(state), color: color, isProminent: state == .running)
    }

    private var color: Color {
        switch state {
        case .running: Tokens.Colors.status(.normal)
        case .paused, .restarting: Tokens.Colors.status(.elevated)
        case .created, .removing, .exited, .dead: Tokens.Colors.seriesRemainder(contrast)
        }
    }
}

/// Sizes for this section, next to the view that uses them.
enum ContainerLayout {
    static let symbol = "shippingbox"
    static let stateWidth: CGFloat = 96
    static let figureWidth: CGFloat = 64
    static let actionsWidth: CGFloat = 132
    /// Two-line rows, section headers, and the column header, as the inset table draws them.
    static let rowHeight: CGFloat = 43
    static let sectionHeaderHeight: CGFloat = 40
    static let columnHeaderHeight: CGFloat = 30
    static let maxTableHeight: CGFloat = 480
    /// The shortest it gets in a short window: the column header and about two rows.
    static let minTableHeight: CGFloat = 120

    /// Tall enough for every row without scrolling, up to a cap.
    static func tableHeight(_ groups: [ContainerGrouping.Group]) -> CGFloat {
        let rows = CGFloat(groups.reduce(0) { $0 + $1.containers.count })
        let height = columnHeaderHeight + CGFloat(groups.count) * sectionHeaderHeight + rows * rowHeight + Tokens.Spacing.s
        return min(maxTableHeight, height)
    }
}

#Preview("Containers") {
    let source = SimulatedContainerSource()
    let model = ContainersModel(source: source, restarter: source)
    ContainersSection(model: model, confirmedAction: ConfirmedAction(terminator: source))
        .padding(Tokens.Spacing.l)
        .frame(width: 1000)
}
